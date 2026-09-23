// Package rounds derives a feed's round calendar from block time. gno.land has
// no scheduler, so nothing here fires: the realm asks, at the moment of a
// transaction, which round is current, whether a given round is open, and how
// far behind the last finalised round is. All times are Unix seconds, which is
// the resolution of time.Now() on the chain.
//
// A recurring feed has rounds 0, 1, 2, ... opening at StartAt + id*Interval,
// each accepting submissions for SubmitWindow seconds. A one-off feed has the
// single round 0 opening at StartAt (its resolveAt).
package rounds

import (
	"math/overflow"
)

// Schedule is a feed's round calendar.
type Schedule struct {
	StartAt      int64 // first round opens here (recurring) or the resolve time (one-off)
	Interval     int64 // seconds between rounds; 0 means one-off
	SubmitWindow int64 // seconds a round accepts submissions after it opens
}

// Bounds enforced by Validate (fixed rules of the plan, §4.1).
const (
	MinInterval     = int64(60)
	MaxInterval     = int64(30 * 24 * 3600)
	MinSubmitWindow = int64(60)
)

// Recurring builds a recurring schedule.
func Recurring(startAt, interval, submitWindow int64) Schedule {
	return Schedule{StartAt: startAt, Interval: interval, SubmitWindow: submitWindow}
}

// OneOff builds a single-round schedule opening at resolveAt.
func OneOff(resolveAt, submitWindow int64) Schedule {
	return Schedule{StartAt: resolveAt, Interval: 0, SubmitWindow: submitWindow}
}

// IsOneOff reports whether the schedule has a single round.
func (s Schedule) IsOneOff() bool { return s.Interval == 0 }

// Validate checks the schedule against the fixed bounds. It returns a message
// suitable for a panic or an error string, or "" when valid.
func (s Schedule) Validate() string {
	switch {
	case s.StartAt <= 0:
		return "rounds: start time must be positive"
	case s.SubmitWindow < MinSubmitWindow:
		return "rounds: submit window is below the minimum"
	case s.Interval < 0:
		return "rounds: negative interval"
	case s.Interval == 0:
		return ""
	case s.Interval < MinInterval:
		return "rounds: interval is below the minimum"
	case s.Interval > MaxInterval:
		return "rounds: interval is above the maximum"
	case s.SubmitWindow > s.Interval:
		return "rounds: submit window is longer than the interval"
	}
	return ""
}

// Current returns the round whose open time is the latest at or before now.
// ok is false before the first round opens. For a one-off schedule the round
// is always 0.
func (s Schedule) Current(now int64) (id uint64, ok bool) {
	if now < s.StartAt {
		return 0, false
	}
	if s.IsOneOff() {
		return 0, true
	}
	return uint64((now - s.StartAt) / s.Interval), true
}

// OpenAt is the time round id opens.
func (s Schedule) OpenAt(id uint64) int64 {
	if s.IsOneOff() {
		if id != 0 {
			panic("rounds: a one-off feed has only round 0")
		}
		return s.StartAt
	}
	if id > uint64(1<<62) {
		panic("rounds: round id out of range")
	}
	return overflow.Add64p(s.StartAt, overflow.Mul64p(int64(id), s.Interval))
}

// CloseAt is the time round id stops accepting submissions.
func (s Schedule) CloseAt(id uint64) int64 {
	return overflow.Add64p(s.OpenAt(id), s.SubmitWindow)
}

// IsOpen reports whether round id accepts submissions at now:
// OpenAt <= now < CloseAt.
func (s Schedule) IsOpen(id uint64, now int64) bool {
	return now >= s.OpenAt(id) && now < s.CloseAt(id)
}

// IsClosed reports whether round id's submission window has passed.
func (s Schedule) IsClosed(id uint64, now int64) bool {
	return now >= s.CloseAt(id)
}

// Exists reports whether round id has opened by now.
func (s Schedule) Exists(id uint64, now int64) bool {
	if s.IsOneOff() && id != 0 {
		return false
	}
	return now >= s.OpenAt(id)
}

// Finalisable lists the rounds that are closed and not yet finalised, in
// order, starting after lastFinalised (or from 0 when none is finalised yet),
// at most limit of them. The realm finalises one per transaction and writes
// off long gaps with a bounded catch-up, which is what limit is for.
func (s Schedule) Finalisable(lastFinalised uint64, haveLast bool, now int64, limit int) []uint64 {
	if limit <= 0 {
		return nil
	}
	var next uint64
	if haveLast {
		if s.IsOneOff() {
			return nil
		}
		next = lastFinalised + 1
	}
	out := make([]uint64, 0, limit)
	for len(out) < limit {
		if s.IsOneOff() && next != 0 {
			break
		}
		if !s.IsClosed(next, now) {
			break
		}
		out = append(out, next)
		next++
	}
	return out
}

// Behind counts the closed rounds not yet finalised, capped at cap.
func (s Schedule) Behind(lastFinalised uint64, haveLast bool, now int64, cap uint64) uint64 {
	if s.IsOneOff() {
		if haveLast || !s.IsClosed(0, now) {
			return 0
		}
		return 1
	}
	cur, ok := s.Current(now)
	if !ok {
		return 0
	}
	// rounds 0..cur have opened; those with CloseAt <= now are closed
	lastClosed := cur
	if !s.IsClosed(cur, now) {
		if cur == 0 {
			return 0
		}
		lastClosed = cur - 1
	}
	var first uint64
	if haveLast {
		if lastFinalised >= lastClosed {
			return 0
		}
		first = lastFinalised + 1
	}
	n := lastClosed - first + 1
	if n > cap {
		return cap
	}
	return n
}

// Stale reports whether the newest possible round is more than maxAge seconds
// past the last final value's round. It is the consumer-facing staleness
// signal: true when no round has been finalised within maxAge of now.
func Stale(lastFinalOpenAt, now, maxAge int64) bool {
	return now-lastFinalOpenAt > maxAge
}
