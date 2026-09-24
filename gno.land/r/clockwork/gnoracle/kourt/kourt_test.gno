// Package kourt_test drives a dispute through the core and the DAO and then
// mirrors it into the stand-in Kourt: file, stake, answer, settle, and the
// contested path where Kourt's vote disagrees.
package kourt_test

import (
	"strings"
	"testing"

	json "gno.land/p/onbloc/json/v0"

	"chain"
	"chain/banker"

	"gno.land/p/clockwork/gnoracle/tally/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
	coreimpl "gno.land/r/clockwork/gnoracle/core/impl/v1"
	"gno.land/r/clockwork/gnoracle/dao"
	"gno.land/r/clockwork/gnoracle/dao/exec"
	daoimpl "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	"gno.land/r/clockwork/gnoracle/kourt"
	kimpl "gno.land/r/clockwork/gnoracle/kourt/impl/v1"
	kv "gno.land/r/clockwork/gnoracle/kourtdev"
	"gno.land/r/clockwork/gnoracle/token"
)

const (
	corePath     = "gno.land/r/clockwork/gnoracle/core"
	coreImplPath = "gno.land/r/clockwork/gnoracle/core/impl/v1"
	daoPath      = "gno.land/r/clockwork/gnoracle/dao"
	daoImplPath  = "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	execPath     = "gno.land/r/clockwork/gnoracle/dao/exec"
	kourtImpl    = "gno.land/r/clockwork/gnoracle/kourt/impl/v1"
	pyth         = int64(1_000_000)
	gnot         = int64(1_000_000)
)

var (
	admin    = dao.Admin
	alice    = testutils.TestAddress("alice")
	bob      = testutils.TestAddress("bob")
	dave     = testutils.TestAddress("dave")
	erin     = testutils.TestAddress("erin")
	watcher  = testutils.TestAddress("watcher")
	holder   = testutils.TestAddress("holder")
	coreAddr = chain.PackageAddress(corePath)
	daoAddr  = chain.PackageAddress(daoPath)
	kAddr    = kourt.Address
)

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }
func nosend()                   { testing.SetOriginSend(nil) }
func pay(to address, n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(to, coins(n))
}

var maxHeight int64

func advance(h int64)    { testing.SkipHeights(h); maxHeight += h }
func skip(seconds int64) { advance(seconds / 5) }

var installed bool

func install(cur realm) {
	if ctx := testing.GetContext(); ctx.Height < maxHeight+123 {
		testing.SkipHeights(maxHeight + 123 - ctx.Height)
	}
	if diff := core.HeldTotal() - core.Balance(); diff > 0 {
		testing.IssueCoins(coreAddr, coins(diff))
	}
	_, _, _, _, _, _, known := dao.Held()
	if bal := banker.NewReadonlyBanker().GetCoin(daoAddr, "ugnot"); known > bal {
		testing.IssueCoins(daoAddr, coins(known-bal))
	}
	if installed {
		return
	}
	installed = true
	testing.SetRealm(testing.NewCodeRealm(coreImplPath))
	core.RegisterImpl(cross(cur), coreimpl.Instance())
	testing.SetRealm(testing.NewCodeRealm(daoImplPath))
	dao.RegisterImpl(cross(cur), daoimpl.Instance())
	testing.SetRealm(testing.NewCodeRealm(execPath))
	dao.RegisterTrampoline(cross(cur), exec.Instance())
	testing.SetRealm(testing.NewCodeRealm(daoPath))
	core.RegisterDAO(cross(cur), dao.Hooks())
	testing.SetRealm(testing.NewCodeRealm(kourtImpl))
	kourt.RegisterImpl(cross(cur), kimpl.Instance())
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), coreImplPath)
	dao.Accept(cross(cur), daoImplPath)
	kourt.Accept(cross(cur), kourtImpl)
	core.ProposeAuthority(cross(cur), "anyof:"+string(admin)+"|"+daoPath)
	skip(core.AuthorityTimelock + 5)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ExecuteAuthority(cross(cur))
	token.Transfer(cross(cur), alice, 1_000_000*pyth)
	token.Transfer(cross(cur), bob, 1_000_000*pyth)
	for _, v := range []int64{5_000 * gnot, 2_500 * gnot, 1_250 * gnot, 1_000 * gnot} {
		core.SetParam(cross(cur), "providerMinStakeFloor", v)
		testing.SkipHeights(1) // parameters change at most once per height
	}
	// members stake so disputes have an electorate
	for _, m := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(m))
		nosend()
		token.Approve(cross(cur), daoAddr, 500_000*pyth)
		dao.Stake(cross(cur), 500_000*pyth)
	}
	advance(720)
}

// resolvedDispute runs a feed, a round and an upheld dispute to completion
// and returns the dispute id.
func resolvedDispute(cur realm, tag string) uint64 {
	spec := `{"name":"` + tag + `","kind":"recurring","valueType":"numeric","decimals":6,"interval":600,"submitWindow":300,"sources":"x","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,"toleranceBps":100,"quarantineBps":2000,"disputeWindow":43200,"subscriberPrice":20000,"subscriptionPrice":100000000}`
	testing.SetRealm(testing.NewUserRealm(watcher))
	pay(coreAddr, 105*gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	for _, p := range []address{dave, erin} {
		testing.SetRealm(testing.NewUserRealm(p))
		pay(coreAddr, 1_000*gnot)
		core.Register(cross(cur), id, "")
	}
	f := core.GetFeed(id)
	skip(f.StartAt - core.Now() + 1)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Submit(cross(cur), id, 0, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(erin))
	nosend()
	core.Submit(cross(cur), id, 0, 1_001_000)
	testing.SetRealm(testing.NewUserRealm(watcher))
	pay(coreAddr, 2_500*gnot)
	did := core.Dispute(cross(cur), id, 0, 900_000, "minor", "nope")
	for _, m := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(m))
		nosend()
		dao.CommitVote(cross(cur), did, tally.Commitment(did, 1, "UPHOLD", "s", m))
	}
	skip(dao.Param("commitPeriod") + 5)
	for _, m := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(m))
		nosend()
		dao.RevealVote(cross(cur), did, "UPHOLD", "s")
	}
	skip(dao.Param("revealPeriod") + 5)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	skip(core.Param("appealWindow") + 5)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	return did
}

func TestMirrorFilesStakesAnswersAndSettles(cur realm, t *testing.T) {
	install(cur)
	did := resolvedDispute(cur, "MIRROR/USD")
	uassert.Equal(t, core.DisputeResolved, core.GetDispute(did).Status)

	// the court is founded on demand; a holder buys coin and funds the float
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kourt.EnsureCourt(cross(cur))
	uassert.True(t, kv.Exists(kourt.CourtSlug))
	testing.SetRealm(testing.NewUserRealm(holder))
	pay(chain.PackageAddress("gno.land/r/clockwork/gnoracle/kourtdev"), 50_000_000)
	kv.Buy(cross(cur), kourt.CourtSlug, 0)
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.TransferCC(cross(cur), kourt.CourtSlug, kAddr(), 20_000_000) // 20 CC
	uassert.Equal(t, int64(20_000_000), kourt.Float(cross(cur)))

	// crank: pending -> filed -> staked
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.Equal(t, kourt.StateFiled, kourt.Crank(cross(cur), did))
	rec := kourt.GetRecord(did)
	uassert.True(t, rec.ClaimID > 0)
	uassert.True(t, strings.HasPrefix(rec.Title, "Gnoracle #"))
	uassert.True(t, strings.Contains(kv.ClaimTitle(kourt.CourtSlug, rec.ClaimID), "resolved UPHOLD"))
	uassert.Equal(t, kourt.StateStaked, kourt.Crank(cross(cur), did))
	uassert.Equal(t, kourt.StateStaked, kourt.Crank(cross(cur), did)) // too early to answer: no change
	yes, _ := kv.StakePools(kourt.CourtSlug, rec.ClaimID)
	uassert.Equal(t, int64(2_000_000), yes)
	// after the 3 h window the answer is posted; after 72 h it settles
	skip(3*3600 + 5)
	uassert.Equal(t, kourt.StateAnswered, kourt.Crank(cross(cur), did))
	uassert.True(t, kv.HasAnswer(kourt.CourtSlug, rec.ClaimID))
	uassert.Equal(t, kourt.StateAnswered, kourt.Crank(cross(cur), did))
	skip(72*3600 + 5)
	uassert.Equal(t, kourt.StateSettled, kourt.Crank(cross(cur), did))
	rec = kourt.GetRecord(did)
	uassert.True(t, kv.Settled(kourt.CourtSlug, rec.ClaimID))
	uassert.Equal(t, "undisputed", rec.Route)
	uassert.Equal(t, 0, rec.Verdict)
	// deposit, fee, bond and stake all came back to the float
	uassert.Equal(t, int64(20_000_000), kourt.Float(cross(cur)))
	uassert.Equal(t, kourt.StateSettled, kourt.Crank(cross(cur), did)) // idempotent
	page := kourt.Render(cross(cur), "")
	uassert.True(t, strings.Contains(page, "built on Kourt"))
	uassert.True(t, strings.Contains(page, "settled"))
}

func TestMirrorRecordsKourtDissent(cur realm, t *testing.T) {
	install(cur)
	did := resolvedDispute(cur, "DISSENT/USD")
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	kourt.Crank(cross(cur), did) // filed
	kourt.Crank(cross(cur), did) // staked
	skip(3*3600 + 5)
	uassert.Equal(t, kourt.StateAnswered, kourt.Crank(cross(cur), did))
	rec := kourt.GetRecord(did)
	// a Kourt holder disputes the mirror's answer inside the 72 h
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.OpenDispute(cross(cur), kourt.CourtSlug, rec.ClaimID)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.Equal(t, kourt.StateContested, kourt.Crank(cross(cur), did))
	uassert.Equal(t, kourt.StateContested, kourt.Crank(cross(cur), did)) // waits for Kourt's vote
	// Kourt's vote (the stand-in's admin) says NO: dissent is recorded
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.SetVoteVerdict(cross(cur), kourt.CourtSlug, rec.ClaimID, 1)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.Equal(t, kourt.StateDissent, kourt.Crank(cross(cur), did))
	rec = kourt.GetRecord(did)
	uassert.Equal(t, "vote", rec.Route)
	uassert.Equal(t, 1, rec.Verdict)
	// the stake came back; the answer bond was lost to the vote
	uassert.True(t, kourt.Float(cross(cur)) < 20_000_000)
	uassert.True(t, kourt.Float(cross(cur)) > 15_000_000)
}

func TestMirrorRefusesUnresolvedAndStrangers(cur realm, t *testing.T) {
	install(cur)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.AbortsContains(t, cur, "unknown dispute", func() { kourt.Crank(cross(cur), 999) })
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/intruder"))
	uassert.AbortsContains(t, cur, "state is reachable only through", func() { kourt.Store(0, cur) })
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { kourt.RedeemFloat(cross(cur), 1) })
}

// TestJSONRecords checks the mirror's machine views.
func TestJSONRecords(cur realm, t *testing.T) {
	for _, path := range []string{"json", "json/now", "json/record/1", "json/record/999", "json/records", "json/records/1/5", "json/record/x", "json/other"} {
		out := kourt.Render(cross(cur), path)
		if _, err := json.Unmarshal([]byte(out)); err != nil {
			t.Fatalf("%s: not JSON: %v\n%s", path, err, out)
		}
	}
	all, _ := json.Unmarshal([]byte(kourt.Render(cross(cur), "json/records")))
	recs, _ := all.MustKey("records").GetArray()
	uassert.True(t, len(recs) >= 1)
	state, _ := recs[0].MustKey("state").GetString()
	uassert.True(t, state != "")
	court, _ := all.MustKey("court").GetString()
	uassert.Equal(t, kourt.CourtSlug, court)
}
