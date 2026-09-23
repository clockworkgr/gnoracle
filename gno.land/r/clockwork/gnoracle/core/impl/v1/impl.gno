// Package impl is the first implementation of the Gnoracle core: feeds,
// providers, rounds, sponsorships and metered reads. Disputes are refused
// here and arrive with a later release.
//
// Nothing in this realm is state. Every record lives in the core realm and is
// reached through core.Store with the core's own cur, so accepting a later
// release changes what these functions do and nothing else.
package impl

import (
	"strconv"

	"gno.land/p/clockwork/gnoracle/rounds/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

type implV1 struct{}

var instance = &implV1{}

// Instance returns the implementation object.
func Instance() core.Core { return instance }

func init(cur realm) {
	core.RegisterImpl(cross(cur), instance)
}

func now() int64 { return core.Now() }

func param(name string) int64 { return core.Param(name) }

func u(v uint64) string { return strconv.FormatUint(v, 10) }

func i(v int64) string { return strconv.FormatInt(v, 10) }

func mustFeed(id uint64) *core.Feed {
	f := core.GetFeed(id)
	if f == nil {
		panic("gnoracle: unknown feed " + u(id))
	}
	return f
}

func schedule(f *core.Feed) rounds.Schedule {
	if f.Spec.IsRecurring() {
		return rounds.Recurring(f.StartAt, f.Spec.Interval, f.Spec.SubmitWindow)
	}
	return rounds.OneOff(f.StartAt, f.Spec.SubmitWindow)
}

func isServing(f *core.Feed) bool {
	return f.Status == core.FeedActive || f.Status == core.FeedUnfunded
}

// Invoke: this release defines no operations beyond the core API.
func (*implV1) Invoke(_ int, rlm realm, caller address, userCall bool, sent int64, method, args string) string {
	core.Store(0, rlm)
	panic("gnoracle: unknown method " + method)
}
