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

	// the new release serves; a read still works through it
	page := core.Render(cross(cur), "feeds")
	uassert.True(t, strings.HasPrefix(page, "<!-- release: impl/v2 -->"))
	testing.SetRealm(testing.NewUserRealm(consumer))
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
	uassert.AbortsContains(t, cur, "not the authority", func() { core.TransferAuthority(cross(cur), admin) }) // admin is a valid address; the caller is not the authority

	// re-accept v1b and hand the authority to a governance realm path
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), implPathB)
	core.TransferAuthorityToRealms(cross(cur), "gno.land/r/clockwork/gnoracle/dao")
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
	core.TransferAuthority(cross(cur), admin)
}
