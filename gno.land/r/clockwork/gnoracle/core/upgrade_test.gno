package core_test

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
	implv2 "gno.land/r/clockwork/gnoracle/core/impl/v2"
)

const implPathB = "gno.land/r/clockwork/gnoracle/core/impl/v2"

// TestUpgradeRollbackKeepsState accepts a second release over live state,
// checks the state and the money are untouched, rolls back, and shows that a
// stranger cannot do any of it.
func TestUpgradeRollbackKeepsState(cur realm, t *testing.T) {
	install(cur)
	// a subscribed reader realm, so a read can be tried through each release
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(1 * gnot)
	core.SubscribeRealm(cross(cur), 1, readerPath, 1)
	feedsBefore := core.FeedCount()
	heldBefore := core.HeldTotal()
	uassert.True(t, feedsBefore > 0) // earlier stories left feeds behind

	// the candidate registers from its own realm (its init on chain)
	testing.SetRealm(testing.NewCodeRealm(implPathB))
	core.RegisterImpl(cross(cur), implv2.Instance())
	uassert.Equal(t, 1, len(core.PendingPaths()))
	uassert.Equal(t, implPathB, core.PendingPaths()[0])

	// only the authority accepts
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { core.Accept(cross(cur), implPathB) })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), implPathB)
	uassert.Equal(t, implPathB, core.LivePath())
	uassert.Equal(t, 1, len(core.HistoryPaths()))
	uassert.Equal(t, implPath, core.HistoryPaths()[0])

	// state and money did not move
	uassert.Equal(t, feedsBefore, core.FeedCount())
	uassert.Equal(t, heldBefore, core.HeldTotal())
	health(t)

	// the new release serves; a subscribed realm's read still works through it
	page := core.Render(cross(cur), "feeds")
	uassert.True(t, strings.HasPrefix(page, "<!-- release: impl/v2 -->"))
	testing.SetRealm(testing.NewCodeRealm(readerPath))
	nosend()
	_, _, _, _, tier := core.Read(cross(cur), 1)
	uassert.True(t, tier != "")

	// roll back: the old release serves again, the new one is pending
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Rollback(cross(cur))
	uassert.Equal(t, implPath, core.LivePath())
	uassert.Equal(t, 1, len(core.PendingPaths()))
	page = core.Render(cross(cur), "feeds")
	uassert.False(t, strings.HasPrefix(page, "<!-- release"))
	uassert.Equal(t, heldBefore, core.HeldTotal())
	health(t)

	// a stranger cannot roll back, freeze or transfer
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { core.Rollback(cross(cur)) })
	uassert.AbortsContains(t, cur, "not the authority", func() { core.Freeze(cross(cur)) })
	uassert.AbortsContains(t, cur, "not the authority", func() { core.ProposeAuthority(cross(cur), "addr:"+string(admin)) })

	// re-accept v1b and hand the authority to a governance realm path
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), implPathB)
	// authority moves in two timelocked steps, and a realm list must include the DAO
	uassert.AbortsContains(t, cur, "must include", func() { core.ProposeAuthority(cross(cur), "realms:gno.land/r/clockwork/gnoracle/dao/exec") })
	core.ProposeAuthority(cross(cur), "realms:gno.land/r/clockwork/gnoracle/dao")
	spec, readyAt := core.PendingAuthority()
	uassert.Equal(t, "realms:gno.land/r/clockwork/gnoracle/dao", spec)
	uassert.True(t, readyAt > core.Now())
	uassert.AbortsContains(t, cur, "timelocked", func() { core.ExecuteAuthority(cross(cur)) })
	core.CancelAuthority(cross(cur))
	uassert.AbortsContains(t, cur, "no authority transfer", func() { core.ExecuteAuthority(cross(cur)) })
	core.ProposeAuthority(cross(cur), "realms:gno.land/r/clockwork/gnoracle/dao")
	skip(core.AuthorityTimelock + 5)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ExecuteAuthority(cross(cur))
	uassert.True(t, strings.Contains(core.Authority(), "gno.land/r/clockwork/gnoracle/dao"))
	// the old admin key is now a stranger
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { core.Rollback(cross(cur)) })
	// the governance realm can act
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/clockwork/gnoracle/dao"))
	core.Rollback(cross(cur))
	uassert.Equal(t, implPath, core.LivePath())
	// and hand it back so later tests keep working
	core.ProposeAuthority(cross(cur), "addr:"+string(admin))
	skip(core.AuthorityTimelock + 5)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/clockwork/gnoracle/dao"))
	core.ExecuteAuthority(cross(cur))
}

// TestReleaseHooks exercises what a release can add without a permanent
// change: operations through Invoke, per-object notes, governed parameters
// and bounded incentives from the fee pool.
func TestReleaseHooks(cur realm, t *testing.T) {
	install(cur)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), implPathB)
	uassert.Equal(t, implPathB, core.LivePath())

	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.Equal(t, "hello", core.Invoke(cross(cur), "echo", "hello"))
	uassert.AbortsContains(t, cur, "unknown method", func() { core.Invoke(cross(cur), "nope", "") })

	// release data beside the permanent structs
	uassert.Equal(t, "", core.Note("v2", "7", "source"))
	uassert.Equal(t, "kraken spot", core.Invoke(cross(cur), "note", "7 source kraken spot"))
	uassert.Equal(t, "kraken spot", core.Note("v2", "7", "source"))
	core.Invoke(cross(cur), "note", "7 source ")
	uassert.Equal(t, "", core.Note("v2", "7", "source")) // empty value removes

	// a governed parameter added by a release (authority only), then tuned
	uassert.AbortsContains(t, cur, "reserved to the core authority", func() { core.Invoke(cross(cur), "define", "v2Knob 40") })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.Equal(t, "40", core.Invoke(cross(cur), "define", "v2Knob 40"))
	uassert.Equal(t, int64(40), core.Param("v2Knob"))
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.SetParam(cross(cur), "v2Knob", 60)
	uassert.Equal(t, int64(60), core.Param("v2Knob"))

	// a bounded incentive from the fee pool, paid only at the authority's call
	_, _, _, _, _, _, fees, _ := core.Held()
	uassert.True(t, fees > 0)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "reserved to the core authority", func() { core.Invoke(cross(cur), "tip", "1000") })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "maxIncentivePay", func() { core.Invoke(cross(cur), "tip", "999999999999") })
	uassert.Equal(t, "paid", core.Invoke(cross(cur), "tip", "1000"))
	_, _, _, _, _, _, feesAfter, _ := core.Held()
	uassert.Equal(t, fees-1000, feesAfter)
	uassert.True(t, strings.Contains(core.Health(), `"status":"ok"`))

	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Rollback(cross(cur))
	uassert.Equal(t, implPath, core.LivePath())
	uassert.Equal(t, int64(60), core.Param("v2Knob")) // definitions and data outlive the release
}
