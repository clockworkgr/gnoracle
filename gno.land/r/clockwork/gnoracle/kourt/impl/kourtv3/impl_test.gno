// Package kourtv3_test drives a dispute through the core and the DAO and then
// mirrors it into the real Kourt v3 code (the deployed realm's source,
// mirrored under deps/): the court is founded, the float bought, a claim
// filed, staked, answered and settled; a contested claim decided by Kourt's
// coin vote; the float redeemed to the treasury.
package kourtv3_test

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
	kimpl "gno.land/r/clockwork/gnoracle/kourt/impl/kourtv3"
	"gno.land/r/clockwork/gnoracle/token"
	kv "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"
)

const (
	corePath     = "gno.land/r/clockwork/gnoracle/core"
	coreImplPath = "gno.land/r/clockwork/gnoracle/core/impl/v1"
	daoPath      = "gno.land/r/clockwork/gnoracle/dao"
	daoImplPath  = "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	execPath     = "gno.land/r/clockwork/gnoracle/dao/exec"
	kourtImpl    = "gno.land/r/clockwork/gnoracle/kourt/impl/kourtv3"
	kourtPath    = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"
	slug         = kourt.CourtSlug
	pyth         = int64(1_000_000)
	gnot         = int64(1_000_000)
	cc           = int64(1_000_000)
	epochBlocks  = int64(720)
	votingBlocks = int64(120_960) // Kourt's default dispute vote
	escrowMax    = int64(362_880) // Kourt's longest escrow after a vote
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
	kvAddr   = chain.PackageAddress(kourtPath)
	kAddr    = kourt.Address
)

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }
func nosend()                   { testing.SetOriginSend(nil) }
func pay(to address, n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(to, coins(n))
}
func gnotOf(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

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
	if bal := gnotOf(daoAddr); known > bal {
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

func crank(cur realm, did uint64) string {
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	return kourt.Crank(cross(cur), did)
}

// answered drives a fresh dispute's record to the answered state.
func answered(cur realm, t *testing.T, did uint64) *kourt.Record {
	uassert.Equal(t, kourt.StateFiled, crank(cur, did))
	uassert.Equal(t, kourt.StateStaked, crank(cur, did))
	advance(2*epochBlocks + 10)
	uassert.Equal(t, kourt.StateAnswered, crank(cur, did))
	return kourt.GetRecord(did)
}

func TestMirrorFoundsCourtAndSettlesUndisputed(cur realm, t *testing.T) {
	install(cur)
	did := resolvedDispute(cur, "MIRROR/USD")
	uassert.Equal(t, core.DisputeResolved, core.GetDispute(did).Status)

	// creation is free on Kourt v3 today, so the mirror realm founds its
	// own court; a holder buys coin on Kourt's curve and funds the float
	uassert.Equal(t, int64(0), kv.CourtCreationBurn())
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.Equal(t, slug, kourt.EnsureCourt(cross(cur)))
	uassert.True(t, kv.Exists(slug))
	uassert.Equal(t, slug, kourt.EnsureCourt(cross(cur))) // idempotent
	uassert.False(t, kv.CourtOneWay(slug))
	testing.SetRealm(testing.NewUserRealm(holder))
	pay(kvAddr, 50*gnot)
	minted := kv.Buy(cross(cur), slug, 0)
	uassert.True(t, minted > 300*cc) // the curve starts near zero: 50 GNOT mints about 316 CC
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.TransferCC(cross(cur), slug, kAddr(), 20*cc)
	uassert.Equal(t, int64(20*cc), kourt.Float(cross(cur)))

	// pending -> filed: the claim carries the verdict sentence and the record
	uassert.Equal(t, kourt.StateFiled, crank(cur, did))
	rec := kourt.GetRecord(did)
	uassert.True(t, rec.ClaimID > 0)
	uassert.Equal(t, kourtPath+"#"+slug, rec.Binding)
	uassert.True(t, strings.Contains(kv.ClaimTitle(slug, rec.ClaimID), "resolved UPHOLD"))
	uassert.True(t, strings.Contains(kv.ClaimBody(slug, rec.ClaimID), `"outcome":"UPHOLD"`))
	uassert.Equal(t, kAddr(), kv.ClaimAuthor(slug, rec.ClaimID))
	uassert.Equal(t, int64(20*cc-1_100_000), kourt.Float(cross(cur))) // 1 CC deposit + 10% fee in escrow

	// filed -> staked: twice the answerability floor (1 CC on a small court)
	uassert.Equal(t, kourt.StateStaked, crank(cur, did))
	yes, _ := kv.StakePools(slug, rec.ClaimID)
	uassert.Equal(t, int64(2*cc), yes)
	uassert.Equal(t, int64(2*cc), kourt.GetRecord(did).Stake)

	// the answer needs three epochs of stake history: nothing is due yet
	uassert.Equal(t, kourt.StateStaked, crank(cur, did))
	_, mature := kv.TrailingOI(slug, rec.ClaimID, 3*epochBlocks)
	uassert.False(t, mature)
	advance(epochBlocks)
	uassert.Equal(t, kourt.StateStaked, crank(cur, did))
	advance(epochBlocks + 10)
	// two epochs on, the mirror seals the history with a one-unit top-up and
	// posts the bonded answer in the same step
	uassert.Equal(t, kourt.StateAnswered, crank(cur, did))
	uassert.True(t, kv.HasAnswer(slug, rec.ClaimID))
	uassert.Equal(t, kAddr(), kv.Answerer(slug, rec.ClaimID))
	uassert.Equal(t, 0, kv.AnswerVerdict(slug, rec.ClaimID))
	bond := kv.AnswerBond(slug, rec.ClaimID)
	uassert.True(t, bond > 0)
	uassert.Equal(t, int64(2*cc+1), kourt.GetRecord(did).Stake)
	uassert.Equal(t, int64(20*cc-1_100_000-bond), kourt.Float(cross(cur)))
	uassert.Equal(t, kourt.StateAnswered, crank(cur, did)) // 72 h have not passed

	// after 72 h it settles undisputed; stake, deposit, fee and bond return
	skip(72*3600 + 10)
	uassert.Equal(t, kourt.StateSettled, crank(cur, did))
	rec = kourt.GetRecord(did)
	uassert.True(t, kv.Settled(slug, rec.ClaimID))
	uassert.Equal(t, "undisputed", rec.Route)
	uassert.Equal(t, 0, rec.Verdict)
	uassert.True(t, kv.RewardsOpened(slug, rec.ClaimID))
	uassert.Equal(t, int64(0), kv.StakeOf(slug, rec.ClaimID, 0, kAddr()))
	uassert.Equal(t, int64(20*cc), kourt.Float(cross(cur)))
	uassert.Equal(t, kourt.StateSettled, crank(cur, did)) // idempotent

	// the draw's slices are pulled into the float on request
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	out := kourt.Invoke(cross(cur), "reclaim", " "+strings.TrimSpace(u(did)))
	node, err := json.Unmarshal([]byte(out))
	uassert.NoError(t, err)
	uassert.True(t, node.HasKey("winner"))
	uassert.True(t, kourt.Float(cross(cur)) >= 20*cc)
	winnerPaid, authorPaid, answererPaid := kv.PullState(slug, rec.ClaimID, kAddr())
	uassert.True(t, winnerPaid && authorPaid && answererPaid)
	uassert.AbortsContains(t, cur, "unknown method", func() { kourt.Invoke(cross(cur), "nope", "") })
	uassert.AbortsContains(t, cur, "usage", func() { kourt.Invoke(cross(cur), "reclaim", "x") })

	page := kourt.Render(cross(cur), "")
	uassert.True(t, strings.Contains(page, "built on Kourt"))
	uassert.True(t, strings.Contains(page, kourtPath))
	uassert.True(t, strings.Contains(page, "settled"))
	detail := kourt.Render(cross(cur), "dispute/"+u(did))
	uassert.True(t, strings.Contains(detail, "every stake withdraws"))
}

func TestMirrorRecordsKourtDissent(cur realm, t *testing.T) {
	install(cur)
	did := resolvedDispute(cur, "DISSENT/USD")
	rec := answered(cur, t, did)
	before := kourt.Float(cross(cur))
	bond := kv.AnswerBond(slug, rec.ClaimID)

	// a holder disputes the mirror's answer inside the 72 h
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	pid := kv.OpenDispute(cross(cur), slug, rec.ClaimID)
	uassert.True(t, pid > 0)
	uassert.Equal(t, kourt.StateContested, crank(cur, did))
	uassert.Equal(t, kourt.StateContested, crank(cur, did)) // the vote is open
	// the coin vote overturns it ("yes" is to overturn); the holder's weight
	// is the coin held since before the round opened
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.VoteDispute(cross(cur), slug, rec.ClaimID, "yes")
	advance(votingBlocks + 1)
	// the mirror resolves the vote: a provisional verdict against the DAO,
	// held in escrow
	uassert.Equal(t, kourt.StateContested, crank(cur, did))
	uassert.False(t, kv.DisputeOpen(slug, rec.ClaimID))
	uassert.Equal(t, 1, kv.Provisional(slug, rec.ClaimID))
	uassert.False(t, kv.Settled(slug, rec.ClaimID))
	uassert.Equal(t, kourt.StateContested, crank(cur, did)) // escrow still open
	// after the escrow the mirror finalizes and records the dissent
	advance(escrowMax + 1)
	uassert.Equal(t, kourt.StateDissent, crank(cur, did))
	rec = kourt.GetRecord(did)
	uassert.Equal(t, "vote", rec.Route)
	uassert.Equal(t, 1, rec.Verdict)
	uassert.True(t, kv.Settled(slug, rec.ClaimID))
	// the stake principal, the deposit and the fee came back; the answer
	// bond (already out of the float when the answer was posted) burned with
	// the overturn instead of returning as it does on an upheld answer
	uassert.Equal(t, int64(0), kv.StakeOf(slug, rec.ClaimID, 0, kAddr()))
	uassert.True(t, bond > 0)
	uassert.Equal(t, before+1_100_000, kourt.Float(cross(cur)))
	uassert.Equal(t, kourt.StateDissent, crank(cur, did))
}

func TestMirrorRecordsKourtConfirmation(cur realm, t *testing.T) {
	install(cur)
	did := resolvedDispute(cur, "CONFIRM/USD")
	rec := answered(cur, t, did)
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.OpenDispute(cross(cur), slug, rec.ClaimID)
	uassert.Equal(t, kourt.StateContested, crank(cur, did))
	testing.SetRealm(testing.NewUserRealm(holder))
	nosend()
	kv.VoteDispute(cross(cur), slug, rec.ClaimID, "no") // uphold the answer
	advance(votingBlocks + 1)
	uassert.Equal(t, kourt.StateContested, crank(cur, did))
	uassert.Equal(t, 0, kv.Provisional(slug, rec.ClaimID))
	advance(escrowMax + 1)
	uassert.Equal(t, kourt.StateConfirmed, crank(cur, did))
	rec = kourt.GetRecord(did)
	uassert.Equal(t, "vote", rec.Route)
	uassert.Equal(t, 0, rec.Verdict)
}

func TestMirrorRefusesStrangersAndRedeemsForTreasury(cur realm, t *testing.T) {
	install(cur)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.AbortsContains(t, cur, "unknown dispute", func() { kourt.Crank(cross(cur), 999) })
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/intruder"))
	uassert.AbortsContains(t, cur, "state is reachable only through", func() { kourt.Store(0, cur) })
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { kourt.RedeemFloat(cross(cur), cc) })

	// the authority redeems part of the float; Kourt pays GNOT from the
	// court's reserve to the mirror realm, which forwards it to the DAO
	floatBefore := kourt.Float(cross(cur))
	daoBefore := gnotOf(daoAddr)
	testing.IssueCoins(kvAddr, coins(kv.ReserveGNOT(slug))) // the harness banker forgets balances between tests
	quote := kv.RedeemValue(slug, 5*cc)
	uassert.True(t, quote > 0)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	payout := kourt.RedeemFloat(cross(cur), 5*cc)
	uassert.Equal(t, quote, payout)
	uassert.Equal(t, floatBefore-5*cc, kourt.Float(cross(cur)))
	uassert.Equal(t, daoBefore+payout, gnotOf(daoAddr))
	uassert.Equal(t, int64(0), gnotOf(kAddr()))
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
	uassert.True(t, len(recs) >= 3)
	state, _ := recs[0].MustKey("state").GetString()
	uassert.Equal(t, kourt.StateSettled, state)
	status, _ := recs[0].MustKey("kourtStatus").GetString()
	uassert.True(t, strings.HasPrefix(status, "settled"))
	kpath, _ := all.MustKey("kourt").GetString()
	uassert.Equal(t, kourtPath, kpath)
	exists, _ := all.MustKey("courtExists").GetBool()
	uassert.True(t, exists)
	addr, _ := all.MustKey("address").GetString()
	uassert.Equal(t, string(kAddr()), addr)
}

func u(v uint64) string {
	if v == 0 {
		return "0"
	}
	var b []byte
	for v > 0 {
		b = append([]byte{byte('0' + v%10)}, b...)
		v /= 10
	}
	return string(b)
}
