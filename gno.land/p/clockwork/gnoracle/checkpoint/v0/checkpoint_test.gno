package checkpoint_test

import (
	"testing"

	"gno.land/p/clockwork/gnoracle/checkpoint/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestSeriesAnswersAsOfEveryEpoch(t *testing.T) {
	var s checkpoint.Series
	uassert.Equal(t, int64(0), s.Value())
	uassert.Equal(t, uint32(0), s.Since())
	uassert.Equal(t, int64(0), s.ValueAt(100))

	s.SetAt(10, 100)
	s.SetAt(20, 200)
	s.SetAt(30, 300)
	s.SetAt(40, 400) // 10 and 20 are now archived
	uassert.Equal(t, 4, s.Len())
	uassert.Equal(t, int64(400), s.Value())
	uassert.Equal(t, uint32(40), s.Since())

	uassert.Equal(t, int64(0), s.ValueAt(9))     // before the first point
	uassert.Equal(t, int64(100), s.ValueAt(10))  // archived, exact epoch
	uassert.Equal(t, int64(100), s.ValueAt(15))  // archived, between points
	uassert.Equal(t, int64(200), s.ValueAt(29))  // archived
	uassert.Equal(t, int64(300), s.ValueAt(30))  // inline prev
	uassert.Equal(t, int64(300), s.ValueAt(39))  // inline prev
	uassert.Equal(t, int64(400), s.ValueAt(40))  // inline cur
	uassert.Equal(t, int64(400), s.ValueAt(999)) // future
}

func TestSameEpochOverwritesAndPastIsRefused(cur realm, t *testing.T) {
	var s checkpoint.Series
	s.SetAt(5, 1)
	s.SetAt(5, 2)
	s.SetAt(5, 3)
	uassert.Equal(t, 1, s.Len())
	uassert.Equal(t, int64(3), s.ValueAt(5))
	s.SetAt(6, 4)
	s.SetAt(6, 5)
	uassert.Equal(t, 2, s.Len())
	uassert.Equal(t, int64(3), s.ValueAt(5))
	uassert.Equal(t, int64(5), s.ValueAt(6))
	uassert.PanicsWithMessage(t, cur, "checkpoint: cannot write in the past", func() { s.SetAt(4, 9) })
	uassert.PanicsWithMessage(t, cur, "checkpoint: epoch 0 is reserved", func() { s.SetAt(0, 9) })
}

func TestTwoPointsNeverTouchTheArchive(t *testing.T) {
	var s checkpoint.Series
	s.SetAt(1, 10)
	s.SetAt(2, 20)
	uassert.Equal(t, 2, s.Len())
	uassert.Equal(t, int64(10), s.ValueAt(1))
	uassert.Equal(t, int64(20), s.ValueAt(2))
	uassert.Equal(t, 0, s.Trim(2, 10)) // nothing archived to trim
}

func TestTrimKeepsTheAnswerAtTheHorizon(t *testing.T) {
	var s checkpoint.Series
	for e := uint32(1); e <= 10; e++ {
		s.SetAt(e*10, int64(e)) // points at 10,20,...,100
	}
	uassert.Equal(t, 10, s.Len())
	// keep from epoch 55: the newest archived point at or before 55 is 50; 10..40 go
	n := s.Trim(55, 100)
	uassert.Equal(t, 4, n)
	uassert.Equal(t, 6, s.Len())
	uassert.Equal(t, int64(5), s.ValueAt(55))
	uassert.Equal(t, int64(5), s.ValueAt(50))
	uassert.Equal(t, int64(0), s.ValueAt(45)) // trimmed history reads as nothing
	uassert.Equal(t, int64(6), s.ValueAt(60))
	uassert.Equal(t, int64(10), s.ValueAt(100))

	// pacing: a limit removes at most that many
	var p checkpoint.Series
	for e := uint32(1); e <= 10; e++ {
		p.SetAt(e*10, int64(e))
	}
	uassert.Equal(t, 2, p.Trim(95, 2))
	uassert.Equal(t, 2, p.Trim(95, 2))
	uassert.Equal(t, 2, p.Trim(95, 2))
	uassert.Equal(t, 1, p.Trim(95, 2)) // archive is 10..80; keep 80; 7 victims total
	uassert.Equal(t, 0, p.Trim(95, 2))
	uassert.Equal(t, int64(9), p.ValueAt(95)) // the inline point at 90
	uassert.Equal(t, int64(8), p.ValueAt(85)) // the kept archived point at 80
	uassert.Equal(t, int64(0), p.ValueAt(75)) // trimmed
}

func TestBookKeepsTheTotalInStep(t *testing.T) {
	b := checkpoint.NewBook()
	b.Set("alice", 11, 100)
	b.Set("bob", 11, 50)
	uassert.Equal(t, int64(150), b.Total())
	uassert.Equal(t, int64(150), b.TotalAt(11))
	uassert.Equal(t, int64(0), b.TotalAt(10))
	uassert.Equal(t, 2, b.Size())
	uassert.True(t, b.Has("alice"))
	uassert.False(t, b.Has("carol"))

	b.Set("alice", 12, 70) // alice unstakes 30 as of epoch 12
	uassert.Equal(t, int64(120), b.Total())
	uassert.Equal(t, int64(150), b.TotalAt(11)) // the sealed epoch is unchanged
	uassert.Equal(t, int64(100), b.ValueAt("alice", 11))
	uassert.Equal(t, int64(70), b.ValueAt("alice", 12))
	uassert.Equal(t, int64(70), b.Value("alice"))
	uassert.Equal(t, int64(0), b.Value("carol"))
	uassert.Equal(t, int64(0), b.ValueAt("carol", 12))

	b.Set("bob", 12, 0) // bob leaves
	uassert.Equal(t, int64(70), b.Total())
	uassert.Equal(t, int64(50), b.ValueAt("bob", 11))
	uassert.Equal(t, int64(0), b.ValueAt("bob", 12))

	// three changes in one epoch collapse into one point
	b.Set("alice", 13, 71)
	b.Set("alice", 13, 72)
	b.Set("alice", 13, 73)
	uassert.Equal(t, int64(73), b.Total())
	uassert.Equal(t, int64(70), b.TotalAt(12))
}

func TestBookRefusesNegativeValues(cur realm, t *testing.T) {
	b := checkpoint.NewBook()
	uassert.PanicsWithMessage(t, cur, "checkpoint: negative value", func() { b.Set("x", 1, -1) })
}

func TestLongHistoryStaysCorrect(t *testing.T) {
	// A member changing stake every epoch for 300 epochs: every past epoch
	// must still answer exactly.
	var s checkpoint.Series
	for e := uint32(1); e <= 300; e++ {
		s.SetAt(e, int64(e)*7)
	}
	for e := uint32(1); e <= 300; e += 7 {
		uassert.Equal(t, int64(e)*7, s.ValueAt(e))
	}
	uassert.Equal(t, int64(300*7), s.ValueAt(1000))
	// with gaps
	var g checkpoint.Series
	for e := uint32(3); e <= 3000; e += 97 {
		g.SetAt(e, int64(e))
	}
	uassert.Equal(t, int64(3), g.ValueAt(99))
	uassert.Equal(t, int64(100), g.ValueAt(100))
	uassert.Equal(t, int64(100), g.ValueAt(196))
	uassert.Equal(t, int64(197), g.ValueAt(197))
	uassert.Equal(t, int64(0), g.ValueAt(2))
}
