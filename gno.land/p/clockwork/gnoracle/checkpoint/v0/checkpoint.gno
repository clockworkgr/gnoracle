// Package checkpoint remembers what an int64 was at every past epoch, so a
// dispute can weigh a member's stake as of the epoch sealed when the dispute
// opened rather than as of the vote.
//
// A Series is an append-only list of points (epoch, value): a point set at
// epoch e is the value for every query at an epoch >= e until a later point.
// Points must be written in non-decreasing epoch order; writing at the newest
// epoch again overwrites it, which is how several changes inside one epoch
// collapse into one point. The two newest points are kept inline so an
// account that rarely changes answers without touching its archive; older
// points live in a B+ tree keyed by epoch.
//
// The DAO writes every stake change at (current epoch + 1), so a change never
// counts for an epoch that has already been sealed (plan §8.2).
package checkpoint

import (
	"gno.land/p/nt/bptree/v0"
)

// Series is one account's (or one total's) history.
type Series struct {
	curE  uint32 // epoch of the newest point; 0 means no point yet
	cur   int64  // value of the newest point
	prevE uint32 // epoch of the previous point; 0 means none
	prev  int64
	older *bptree.BPTree // points older than prev, key = epochKey(e) -> int64
}

// Value is the newest value (the value at any epoch >= Since()).
func (s *Series) Value() int64 { return s.cur }

// Since is the epoch of the newest point, 0 when nothing was ever set.
func (s *Series) Since() uint32 { return s.curE }

// Len is the number of points kept.
func (s *Series) Len() int {
	n := 0
	if s.curE != 0 {
		n++
	}
	if s.prevE != 0 {
		n++
	}
	if s.older != nil {
		n += s.older.Size()
	}
	return n
}

// SetAt records value v as of epoch e. e must be at least 1 and not older
// than the newest point.
func (s *Series) SetAt(e uint32, v int64) {
	if e == 0 {
		panic("checkpoint: epoch 0 is reserved")
	}
	if e < s.curE {
		panic("checkpoint: cannot write in the past")
	}
	if e == s.curE || s.curE == 0 {
		if s.curE == 0 {
			s.curE = e
		}
		s.cur = v
		return
	}
	// shift: cur -> prev, prev -> older
	if s.prevE != 0 {
		if s.older == nil {
			s.older = bptree.NewBPTree32()
		}
		s.older.Set(epochKey(s.prevE), s.prev)
	}
	s.prevE, s.prev = s.curE, s.cur
	s.curE, s.cur = e, v
}

// ValueAt is the value as of epoch e: the newest point whose epoch is <= e,
// or 0 when there is none.
func (s *Series) ValueAt(e uint32) int64 {
	if s.curE == 0 || e < s.oldest() {
		return 0
	}
	if e >= s.curE {
		return s.cur
	}
	if s.prevE != 0 && e >= s.prevE {
		return s.prev
	}
	if s.older == nil {
		return 0
	}
	var found int64
	s.older.ReverseIterate("", epochKey(e), func(_ string, v any) bool {
		found = v.(int64)
		return true
	})
	return found
}

// oldest is the epoch of the oldest point kept, 0 when none.
func (s *Series) oldest() uint32 {
	if s.older != nil && s.older.Size() > 0 {
		k, _ := s.older.GetByIndex(0)
		return keyEpoch(k)
	}
	if s.prevE != 0 {
		return s.prevE
	}
	return s.curE
}

// Trim drops archived points older than keepFrom, keeping the newest point
// at or before keepFrom so ValueAt(keepFrom) still answers. It removes at most
// limit points and returns how many it removed, so a prune can be paced. The
// two inline points are never trimmed.
func (s *Series) Trim(keepFrom uint32, limit int) int {
	if s.older == nil || limit <= 0 {
		return 0
	}
	// find the newest archived point at or before keepFrom; everything strictly
	// older than it can go.
	var boundary string
	s.older.ReverseIterate("", epochKey(keepFrom), func(k string, _ any) bool {
		boundary = k
		return true
	})
	if boundary == "" {
		return 0
	}
	victims := make([]string, 0, limit)
	s.older.Iterate("", boundary, func(k string, _ any) bool {
		victims = append(victims, k)
		return len(victims) >= limit
	})
	for _, k := range victims {
		s.older.Remove(k)
	}
	return len(victims)
}

// Book is a set of series keyed by a string (an address), plus a total series
// that the caller keeps in step with the members it changes.
type Book struct {
	series *bptree.BPTree // key -> *Series
	total  Series
}

// NewBook returns an empty book.
func NewBook() *Book {
	return &Book{series: bptree.NewBPTree32()}
}

// Set records key's value as of epoch e and moves the total by the change.
func (b *Book) Set(key string, e uint32, v int64) {
	if v < 0 {
		panic("checkpoint: negative value")
	}
	s := b.get(key)
	old := int64(0)
	if s != nil {
		old = s.Value()
	} else {
		s = &Series{}
		b.series.Set(key, s)
	}
	s.SetAt(e, v)
	b.total.SetAt(e, b.total.Value()-old+v)
}

// Value is key's newest value.
func (b *Book) Value(key string) int64 {
	if s := b.get(key); s != nil {
		return s.Value()
	}
	return 0
}

// ValueAt is key's value as of epoch e.
func (b *Book) ValueAt(key string, e uint32) int64 {
	if s := b.get(key); s != nil {
		return s.ValueAt(e)
	}
	return 0
}

// Total is the newest sum over all keys.
func (b *Book) Total() int64 { return b.total.Value() }

// TotalAt is the sum over all keys as of epoch e.
func (b *Book) TotalAt(e uint32) int64 { return b.total.ValueAt(e) }

// Has reports whether key has ever been set.
func (b *Book) Has(key string) bool { return b.series.Has(key) }

// Size is the number of keys.
func (b *Book) Size() int { return b.series.Size() }

// Trim prunes one key's archive (see Series.Trim).
func (b *Book) Trim(key string, keepFrom uint32, limit int) int {
	if s := b.get(key); s != nil {
		return s.Trim(keepFrom, limit)
	}
	return 0
}

// TrimTotal prunes the total's archive.
func (b *Book) TrimTotal(keepFrom uint32, limit int) int { return b.total.Trim(keepFrom, limit) }

func (b *Book) get(key string) *Series {
	v := b.series.Get(key)
	if v == nil {
		return nil
	}
	return v.(*Series)
}

// epochKey is a 4-byte big-endian key so epochs sort numerically.
func epochKey(e uint32) string {
	return string([]byte{byte(e >> 24), byte(e >> 16), byte(e >> 8), byte(e)})
}

func keyEpoch(k string) uint32 {
	if len(k) != 4 {
		panic("checkpoint: malformed key")
	}
	return uint32(k[0])<<24 | uint32(k[1])<<16 | uint32(k[2])<<8 | uint32(k[3])
}
