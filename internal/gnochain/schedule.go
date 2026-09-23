package gnochain

// Schedule mirrors gno.land/p/clockwork/gnoracle/rounds/v0: round r of a
// recurring feed opens at StartAt + r*Interval and accepts submissions for
// SubmitWindow seconds; a one-off feed (Interval 0) has round 0 only.
type Schedule struct {
	StartAt      int64
	Interval     int64
	SubmitWindow int64
}

// IsOneOff reports whether the schedule has a single round.
func (s Schedule) IsOneOff() bool { return s.Interval == 0 }

// Current is the round open or most recently opened at now.
func (s Schedule) Current(now int64) (uint64, bool) {
	if now < s.StartAt {
		return 0, false
	}
	if s.IsOneOff() {
		return 0, true
	}
	return uint64((now - s.StartAt) / s.Interval), true
}

// OpenAt is when round id opens.
func (s Schedule) OpenAt(id uint64) int64 {
	if s.IsOneOff() {
		return s.StartAt
	}
	return s.StartAt + int64(id)*s.Interval
}

// CloseAt is when round id stops accepting submissions.
func (s Schedule) CloseAt(id uint64) int64 { return s.OpenAt(id) + s.SubmitWindow }

// IsOpen reports whether round id accepts submissions at now.
func (s Schedule) IsOpen(id uint64, now int64) bool {
	return now >= s.OpenAt(id) && now < s.CloseAt(id)
}

// IsClosed reports whether round id's window has passed.
func (s Schedule) IsClosed(id uint64, now int64) bool { return now >= s.CloseAt(id) }

// Next is the first round not yet finalised.
func (s Schedule) Next(lastFinalised uint64, haveLast bool) uint64 {
	if !haveLast {
		return 0
	}
	if s.IsOneOff() {
		return 1 // nothing left
	}
	return lastFinalised + 1
}
