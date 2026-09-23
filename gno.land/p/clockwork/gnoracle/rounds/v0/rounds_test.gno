package rounds_test

import (
	"testing"

	"gno.land/p/clockwork/gnoracle/rounds/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	start  = int64(1_700_000_000)
	hour   = int64(3600)
	window = int64(600)
)

func TestValidate(t *testing.T) {
	uassert.Equal(t, "", rounds.Recurring(start, hour, window).Validate())
	uassert.Equal(t, "", rounds.OneOff(start, 86400).Validate())
	uassert.Equal(t, "rounds: submit window is longer than the interval", rounds.Recurring(start, 60, 61).Validate())
	uassert.Equal(t, "rounds: interval is below the minimum", rounds.Recurring(start, 59, 60).Validate())
	uassert.Equal(t, "rounds: interval is above the maximum", rounds.Recurring(start, 31*24*3600, 60).Validate())
	uassert.Equal(t, "rounds: submit window is below the minimum", rounds.Recurring(start, hour, 59).Validate())
	uassert.Equal(t, "rounds: start time must be positive", rounds.Recurring(0, hour, window).Validate())
	uassert.Equal(t, "rounds: negative interval", rounds.Schedule{StartAt: start, Interval: -1, SubmitWindow: 60}.Validate())
}

func TestCurrentOpenClose(t *testing.T) {
	s := rounds.Recurring(start, hour, window)
	_, ok := s.Current(start - 1)
	uassert.False(t, ok)

	id, ok := s.Current(start)
	uassert.True(t, ok)
	uassert.Equal(t, uint64(0), id)

	id, _ = s.Current(start + hour - 1)
	uassert.Equal(t, uint64(0), id)
	id, _ = s.Current(start + hour)
	uassert.Equal(t, uint64(1), id)
	id, _ = s.Current(start + 25*hour + 17)
	uassert.Equal(t, uint64(25), id)

	uassert.Equal(t, start+2*hour, s.OpenAt(2))
	uassert.Equal(t, start+2*hour+window, s.CloseAt(2))
	uassert.True(t, s.IsOpen(2, start+2*hour))
	uassert.True(t, s.IsOpen(2, start+2*hour+window-1))
	uassert.False(t, s.IsOpen(2, start+2*hour+window)) // close is exclusive
	uassert.False(t, s.IsOpen(2, start+2*hour-1))      // not yet open
	uassert.True(t, s.IsClosed(2, start+2*hour+window))
	uassert.False(t, s.IsClosed(2, start+2*hour+window-1))
	uassert.True(t, s.Exists(2, start+2*hour))
	uassert.False(t, s.Exists(3, start+2*hour))
}

func TestOneOff(cur realm, t *testing.T) {
	s := rounds.OneOff(start, 86400)
	uassert.True(t, s.IsOneOff())
	_, ok := s.Current(start - 1)
	uassert.False(t, ok)
	id, ok := s.Current(start + 10*86400) // still round 0, forever
	uassert.True(t, ok)
	uassert.Equal(t, uint64(0), id)
	uassert.True(t, s.IsOpen(0, start+86399))
	uassert.True(t, s.IsClosed(0, start+86400))
	uassert.False(t, s.Exists(1, start+10*86400))
	uassert.PanicsWithMessage(t, cur, "rounds: a one-off feed has only round 0", func() { s.OpenAt(1) })

	uassert.Equal(t, 0, len(s.Finalisable(0, false, start+100, 10)))
	f := s.Finalisable(0, false, start+86400, 10)
	uassert.Equal(t, 1, len(f))
	uassert.Equal(t, uint64(0), f[0])
	uassert.Equal(t, 0, len(s.Finalisable(0, true, start+90000, 10)))
	uassert.Equal(t, uint64(1), s.Behind(0, false, start+86400, 48))
	uassert.Equal(t, uint64(0), s.Behind(0, true, start+86400, 48))
}

func TestFinalisableAndBehind(t *testing.T) {
	s := rounds.Recurring(start, hour, window)
	now := start + 5*hour + 30 // rounds 0..4 closed, round 5 open

	f := s.Finalisable(0, false, now, 48)
	uassert.Equal(t, 5, len(f))
	uassert.Equal(t, uint64(0), f[0])
	uassert.Equal(t, uint64(4), f[4])
	uassert.Equal(t, uint64(5), s.Behind(0, false, now, 48))

	f = s.Finalisable(2, true, now, 48)
	uassert.Equal(t, 2, len(f)) // 3 and 4
	uassert.Equal(t, uint64(3), f[0])
	uassert.Equal(t, uint64(2), s.Behind(2, true, now, 48))

	f = s.Finalisable(0, false, now, 2) // limit binds
	uassert.Equal(t, 2, len(f))
	uassert.Equal(t, uint64(2), s.Behind(0, false, now, 2))

	uassert.Equal(t, 0, len(s.Finalisable(4, true, now, 48)))
	uassert.Equal(t, uint64(0), s.Behind(4, true, now, 48))

	// round 5 closes: it becomes finalisable
	f = s.Finalisable(4, true, start+5*hour+window, 48)
	uassert.Equal(t, 1, len(f))
	uassert.Equal(t, uint64(5), f[0])

	// before anything closed
	uassert.Equal(t, 0, len(s.Finalisable(0, false, start+window-1, 48)))
	uassert.Equal(t, uint64(0), s.Behind(0, false, start+window-1, 48))
	uassert.Equal(t, uint64(0), s.Behind(0, false, start-1, 48))
	uassert.Equal(t, 0, len(s.Finalisable(0, false, now, 0)))
}

func TestStale(t *testing.T) {
	uassert.False(t, rounds.Stale(start, start+2*hour, 2*hour))
	uassert.True(t, rounds.Stale(start, start+2*hour+1, 2*hour))
}
