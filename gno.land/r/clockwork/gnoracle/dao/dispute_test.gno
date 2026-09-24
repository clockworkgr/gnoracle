package dao_test

import (
	"strconv"
	"strings"
	"testing"

	json "gno.land/p/onbloc/json/v0"

	"gno.land/p/clockwork/gnoracle/tally/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
	"gno.land/r/clockwork/gnoracle/dao"
	"gno.land/r/clockwork/gnoracle/token"
)

// Providers and a disputer, distinct from the DAO members.
var (
	dave     = testutils.TestAddress("dave")
	erin     = testutils.TestAddress("erin")
	frank    = testutils.TestAddress("frank")
	watcher  = testutils.TestAddress("watcher")
	sponsorA = testutils.TestAddress("sponsor")
)

// ensureStake tops a member up to target so the dispute stories start from
// known weights regardless of earlier tests.
func ensureStake(cur realm, who address, target int64) {
	m := dao.GetMember(who)
	have := int64(0)
	if m != nil {
		have = m.Staked
	}
	if have >= target {
		return
	}
	stake(cur, who, target-have)
}

// newFeed proposes and activates a 10-minute numeric feed with three
// providers and returns its id.
func newFeed(cur realm, tag string) uint64 {
	spec := `{"name":"` + tag + `","kind":"recurring","valueType":"numeric","decimals":6,"interval":600,"submitWindow":300,"sources":"three exchanges","minProviders":2,"maxProviders":5,"providerMinStake":1000000000,"toleranceBps":100,"quarantineBps":2000,"disputeWindow":43200,"subscriberPrice":20000,"subscriptionPrice":100000000}`
	testing.SetRealm(testing.NewUserRealm(sponsorA))
	payCore(105 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	for _, p := range []address{dave, erin, frank} {
		testing.SetRealm(testing.NewUserRealm(p))
		payCore(1_000 * gnot)
		core.Register(cross(cur), id, "")
	}
	return id
}

// runRound submits three values to the next round and returns the round id.
func runRound(cur realm, id uint64, v1, v2, v3 int64) uint64 {
	f := core.GetFeed(id)
	round := uint64(0)
	if f.HaveLast {
		round = f.LastFinalized + 1
	}
	open := f.StartAt + int64(round)*600
	if now := core.Now(); now < open {
		skip(open - now + 1)
	}
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Submit(cross(cur), id, round, v1)
	testing.SetRealm(testing.NewUserRealm(erin))
	nosend()
	core.Submit(cross(cur), id, round, v2)
	testing.SetRealm(testing.NewUserRealm(frank))
	nosend()
	core.Submit(cross(cur), id, round, v3) // third submission finalises
	return round
}

func commitReveal(cur realm, disputeID uint64, round int, votes map[address]string) {
	for who, choice := range votes {
		testing.SetRealm(testing.NewUserRealm(who))
		nosend()
		dao.CommitVote(cross(cur), disputeID, tally.Commitment(disputeID, round, choice, "salt-"+string(who), who))
	}
	skip(dao.Param("commitPeriod") + 5)
	for who, choice := range votes {
		testing.SetRealm(testing.NewUserRealm(who))
		nosend()
		dao.RevealVote(cross(cur), disputeID, choice, "salt-"+string(who))
	}
	skip(dao.Param("revealPeriod") + 5)
}

func TestDisputeUpheldPaysProvidersAndVoters(cur realm, t *testing.T) {
	install(cur)
	ensureStake(cur, alice, 1_000_000*pyth)
	ensureStake(cur, bob, 300_000*pyth)
	ensureStake(cur, carol, 200_000*pyth)
	epoch()
	id := newFeed(cur, "UPHOLD/USD")
	round := runRound(cur, id, 1_000_000, 1_001_000, 1_002_000)
	uassert.Equal(t, int64(1_001_000), roundValue(cur, id, round))

	// a watcher disputes with the minimum bond (2500 GNOT); the round is quarantined
	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(2_500 * gnot)
	did := core.Dispute(cross(cur), id, round, 900_000, "major", "ipfs://evidence")
	d := core.GetDispute(did)
	uassert.Equal(t, core.DisputeOpen, d.Status)
	uassert.Equal(t, int64(2_500*gnot), d.Bond)
	uassert.Equal(t, "disputed", core.GetRound(id, round).Tier)
	// the ballot exists in the DAO, sealed at the current epoch
	seq := dao.BallotOf(did)
	b := dao.GetBallot(seq)
	uassert.True(t, seq > 0)
	uassert.Equal(t, int64(1_500_000*pyth), b.Obligated)
	uassert.True(t, b.MajorRequested)

	// an open ballot no longer freezes stake changes (weights are sealed per
	// epoch): alice adds one PYTH and starts unbonding it again
	stake(cur, alice, 1*pyth)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	dao.RequestUnstake(cross(cur), 1*pyth)
	uassert.Equal(t, int64(1_000_000*pyth), dao.GetMember(alice).Staked)
	// the disputed value is not served: a subscribed realm gets no value
	// under the disputed tier (there is no earlier final round yet)
	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(1 * gnot)
	core.SubscribeRealm(cross(cur), id, readerPath, 1)
	testing.SetRealm(testing.NewCodeRealm(readerPath))
	nosend()
	dv, _, _, _, dtier := core.Read(cross(cur), id)
	uassert.Equal(t, int64(0), dv)
	uassert.Equal(t, "disputed", dtier)

	// not resolvable while the ballot runs
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.AbortsContains(t, cur, "still running", func() { core.ResolveDispute(cross(cur), did) })

	// alice (whale, 1M of 1.5M) votes OVERTURN, bob and carol UPHOLD: the cap
	// counts her for at most 20% of the obligated weight (300k)
	commitReveal(cur, did, 1, map[address]string{alice: "OVERTURN", bob: "UPHOLD", carol: "UPHOLD"})
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	d = core.GetDispute(did)
	uassert.Equal(t, core.DisputeDecided, d.Status)
	uassert.Equal(t, "UPHOLD", d.Outcome)
	b = dao.GetBallot(seq)
	uassert.Equal(t, int64(500_000*pyth), b.Uphold)      // raw: bob 300k + carol 200k
	uassert.Equal(t, int64(1_000_000*pyth), b.Overturn)  // raw; decided as 300k after the cap
	uassert.Equal(t, int64(700_000*pyth), b.ClippedAway) // 500k uphold vs 300k overturn: 62.5% upholds

	// the appeal window must pass before the outcome applies
	uassert.AbortsContains(t, cur, "appeal window is open", func() { core.ResolveDispute(cross(cur), did) })
	skip(core.Param("appealWindow") + 5)
	poolBefore := core.GetFeed(id).PenaltyCarry
	_, _, _, _, _, _, feesBefore, _ := core.Held()
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	d = core.GetDispute(did)
	uassert.Equal(t, core.DisputeResolved, d.Status)
	f := core.GetFeed(id)
	uassert.Equal(t, poolBefore+1_250*gnot, f.PenaltyCarry) // 50% to the feed's providers
	_, _, _, _, _, bonds, feesAfter, _ := core.Held()
	uassert.Equal(t, int64(0), bonds)
	uassert.Equal(t, feesBefore+500*gnot, feesAfter) // 20% treasury
	uassert.Equal(t, "consensus", core.GetRound(id, round).Tier)
	uassert.Equal(t, int64(0), f.OpenDisputes)
	// 30% went to the DAO for the coherent voters
	b = dao.GetBallot(seq)
	uassert.Equal(t, int64(750*gnot), b.BondShareUgnot)
	health(t)
	uassert.True(t, strings.Contains(core.Health(), `"status":"ok"`))

	// settlement: bob and carol coherent split 750 GNOT 3:2 and earn the
	// penalty pool; alice incoherent loses 0.5% of her real weight
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	uassert.Equal(t, int64(1), dao.SettleMember(cross(cur), bob, 10))
	uassert.Equal(t, int64(1), dao.SettleMember(cross(cur), carol, 10))
	uassert.Equal(t, int64(1), dao.SettleMember(cross(cur), alice, 10))
	uassert.Equal(t, int64(0), dao.SettleMember(cross(cur), alice, 10))
	ma := dao.GetMember(alice)
	uassert.Equal(t, int64(1_000_000*pyth-5_000*pyth), ma.Staked) // 0.5% of 1M
	uassert.Equal(t, int64(5_000*pyth), ma.TotalPenalised)
	mb := dao.GetMember(bob)
	mc := dao.GetMember(carol)
	uassert.Equal(t, int64(450_000_000), mb.PendingUgnot) // 750 GNOT x 300/500
	uassert.Equal(t, int64(300_000_000), mc.PendingUgnot)
	// expected penalty pool: alice 1M x 0.5% = 5000 PYTH, split 3:2
	uassert.Equal(t, int64(3_000*pyth), mb.PendingPyth)
	uassert.Equal(t, int64(2_000*pyth), mc.PendingPyth)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	gotP, gotU := dao.ClaimRewards(cross(cur))
	uassert.Equal(t, int64(3_000*pyth), gotP)
	uassert.Equal(t, int64(450_000_000), gotU)
	health(t)
}

func TestDisputeOverturnSlashesAndEjects(cur realm, t *testing.T) {
	install(cur)
	ensureStake(cur, alice, 995_000*pyth)
	ensureStake(cur, bob, 300_000*pyth)
	ensureStake(cur, carol, 200_000*pyth)
	epoch()
	id := newFeed(cur, "OVERTURN/USD")
	// dave and erin collude at 1.0; frank reports the true 1.5 and is the outlier
	round := runRound(cur, id, 1_000_000, 1_001_000, 1_500_000)
	uassert.Equal(t, int64(1_001_000), roundValue(cur, id, round))
	uassert.Equal(t, int64(1), core.GetProvider(id, frank).Strikes)

	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(2_500 * gnot)
	did := core.Dispute(cross(cur), id, round, 1_500_000, "major", "true price was 1.5")
	commitReveal(cur, did, 1, map[address]string{alice: "OVERTURN", bob: "OVERTURN", carol: "UPHOLD"})
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did) // decided
	uassert.Equal(t, "OVERTURN", core.GetDispute(did).Outcome)
	uassert.Equal(t, "major", core.GetDispute(did).TierDecided)
	skip(core.Param("appealWindow") + 5)
	watcherBefore := core.Balance()
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	d := core.GetDispute(did)
	uassert.Equal(t, core.DisputeResolved, d.Status)
	// dave and erin lose 100% (1000 GNOT each) and are ejected; frank untouched
	uassert.Equal(t, int64(2_000*gnot), d.Slashed)
	uassert.Equal(t, core.ProviderUnbonding, core.GetProvider(id, dave).Status)
	uassert.Equal(t, int64(0), core.GetProvider(id, dave).Stake)
	uassert.Equal(t, int64(0), core.GetProvider(id, dave).UnbondAmount)
	uassert.Equal(t, core.ProviderActive, core.GetProvider(id, frank).Status)
	uassert.Equal(t, int64(1_000*gnot), core.GetProvider(id, frank).Stake)
	uassert.Equal(t, int64(1), core.GetFeed(id).ActiveCount)
	// the round now carries the corrected value, final
	rd := core.GetRound(id, round)
	uassert.Equal(t, int64(1_500_000), roundValue(cur, id, round))
	uassert.Equal(t, "final", rd.Tier)
	uassert.True(t, rd.Overturned)
	uassert.Equal(t, int64(1_500_000), feedValue(cur, id))
	// the disputer got the bond back plus 50% of the slash (1000 GNOT)
	uassert.Equal(t, watcherBefore-2_500*gnot-1_000*gnot-600*gnot, core.Balance()) // 600 = 30% voters sent to the DAO
	uassert.Equal(t, int64(600*gnot), dao.GetBallot(dao.BallotOf(did)).BondShareUgnot)
	_ = strconv.Itoa
	health(t)
	uassert.True(t, strings.Contains(core.Health(), `"status":"ok"`))
}

func TestDisputeRollsThenVoidsAndReopens(cur realm, t *testing.T) {
	install(cur)
	ensureStake(cur, alice, 990_000*pyth)
	epoch()
	// a one-off categorical feed so the void path can be reopened
	resolveAt := core.Now() + 2*3600
	spec := `{"name":"Match result","kind":"oneoff","valueType":"categorical","options":["Home","Away","Draw"],"resolveAt":` + strconv.FormatInt(resolveAt, 10) + `,"submitWindow":600,"bounty":50000000,"sources":"the league site","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,"disputeWindow":43200}`
	testing.SetRealm(testing.NewUserRealm(sponsorA))
	payCore(55 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	for _, p := range []address{dave, erin} {
		testing.SetRealm(testing.NewUserRealm(p))
		payCore(1_000 * gnot)
		core.Register(cross(cur), id, "")
	}
	skip(resolveAt - core.Now() + 1)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Submit(cross(cur), id, 0, 0)
	testing.SetRealm(testing.NewUserRealm(erin))
	nosend()
	core.Submit(cross(cur), id, 0, 0) // Home, unanimous
	uassert.Equal(t, core.RoundAggregated, core.GetRound(id, 0).Status)

	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(2_500 * gnot)
	did := core.Dispute(cross(cur), id, 0, 2, "minor", "the match was abandoned")
	// round 1: nobody reveals -> no quorum -> rolls to round 2
	skip(dao.Param("commitPeriod") + dao.Param("revealPeriod") + 10)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	d := core.GetDispute(did)
	uassert.Equal(t, core.DisputeAppealed, d.Status)
	uassert.Equal(t, int64(2), d.BallotRound)
	b2 := dao.GetBallot(dao.BallotOf(did))
	uassert.Equal(t, int64(2), b2.Round)
	// round 2: everyone says VOID
	for who, choice := range map[address]string{alice: "VOID", bob: "VOID", carol: "VOID"} {
		testing.SetRealm(testing.NewUserRealm(who))
		nosend()
		dao.CommitVote(cross(cur), did, tally.Commitment(did, 2, choice, "s", who))
	}
	skip(dao.Param("commitPeriod2") + 5)
	for who, choice := range map[address]string{alice: "VOID", bob: "VOID", carol: "VOID"} {
		testing.SetRealm(testing.NewUserRealm(who))
		nosend()
		dao.RevealVote(cross(cur), did, choice, "s")
	}
	skip(dao.Param("revealPeriod2") + 5)
	watcherBefore := core.Balance()
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	d = core.GetDispute(did)
	uassert.Equal(t, core.DisputeResolved, d.Status)
	uassert.Equal(t, "VOID", d.Outcome)
	uassert.Equal(t, core.RoundVoid, core.GetRound(id, 0).Status)
	// 95% of the bond came back, 5% consumed
	uassert.Equal(t, watcherBefore-2_375*gnot-62_500_000, core.Balance()) // 2.5% (62.5 GNOT) to voters left the realm too
	// the requester reopens once with a new resolve time
	testing.SetRealm(testing.NewUserRealm(sponsorA))
	nosend()
	uassert.AbortsContains(t, cur, "between 1 hour", func() { core.ReopenOneOff(cross(cur), id, core.Now()) })
	newAt := core.Now() + 3*3600
	core.ReopenOneOff(cross(cur), id, newAt)
	f := core.GetFeed(id)
	uassert.True(t, f.Reopened)
	uassert.Equal(t, newAt, f.StartAt)
	uassert.False(t, f.HaveLast)
	testing.SetRealm(testing.NewUserRealm(sponsorA))
	nosend()
	uassert.AbortsContains(t, cur, "already reopened", func() { core.ReopenOneOff(cross(cur), id, newAt+3600) })
	health(t)
}

func TestAppealReversesRoundOne(cur realm, t *testing.T) {
	install(cur)
	ensureStake(cur, alice, 985_000*pyth)
	epoch()
	id := newFeed(cur, "APPEAL/USD")
	round := runRound(cur, id, 2_000_000, 2_001_000, 2_002_000)
	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(2_500 * gnot)
	did := core.Dispute(cross(cur), id, round, 2_100_000, "minor", "off by five percent")
	// round 1 upholds (bob and carol) against alice's overturn
	commitReveal(cur, did, 1, map[address]string{alice: "OVERTURN", bob: "UPHOLD", carol: "UPHOLD"})
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	uassert.Equal(t, "UPHOLD", core.GetDispute(did).Outcome)
	// an appeal costs 2x the bond and opens round 2
	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(4_000 * gnot)
	uassert.AbortsContains(t, cur, "appeal bond is", func() { core.Appeal(cross(cur), did) })
	testing.SetRealm(testing.NewUserRealm(watcher))
	payCore(5_000 * gnot)
	core.Appeal(cross(cur), did)
	d := core.GetDispute(did)
	uassert.Equal(t, core.DisputeAppealed, d.Status)
	uassert.Equal(t, int64(5_000*gnot), d.AppealBond)
	// round 2: bob and carol change their minds
	votes := map[address]string{alice: "OVERTURN", bob: "OVERTURN", carol: "OVERTURN"}
	for who, choice := range votes {
		testing.SetRealm(testing.NewUserRealm(who))
		nosend()
		dao.CommitVote(cross(cur), did, tally.Commitment(did, 2, choice, "x", who))
	}
	skip(dao.Param("commitPeriod2") + 5)
	for who, choice := range votes {
		testing.SetRealm(testing.NewUserRealm(who))
		nosend()
		dao.RevealVote(cross(cur), did, choice, "x")
	}
	skip(dao.Param("revealPeriod2") + 5)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	core.ResolveDispute(cross(cur), did)
	d = core.GetDispute(did)
	uassert.Equal(t, core.DisputeResolved, d.Status)
	uassert.Equal(t, "OVERTURN", d.Outcome)
	uassert.Equal(t, "UPHOLD", d.FirstOutcome)
	uassert.Equal(t, "minor", d.TierDecided)
	// all three providers were outside 1% of 2.1 and lose 5% each at the minor tier
	uassert.Equal(t, int64(150*gnot), d.Slashed)
	uassert.Equal(t, int64(950*gnot), core.GetProvider(id, dave).Stake)
	uassert.Equal(t, core.ProviderActive, core.GetProvider(id, dave).Status)
	uassert.Equal(t, int64(2_100_000), roundValue(cur, id, round))
	_, _, _, _, _, bonds, _, _ := core.Held()
	uassert.Equal(t, int64(0), bonds) // both bonds returned, slash routed
	health(t)
	uassert.True(t, strings.Contains(core.Health(), `"status":"ok"`))
	uassert.True(t, token.TotalSupply() > 0)
}

// TestJSONBallots checks the DAO machine views the bot and CLI read.
func TestJSONBallots(cur realm, t *testing.T) {
	for _, path := range []string{"json", "json/now", "json/member/" + string(alice), "json/member/" + string(stranger), "json/members",
		"json/ballot/1", "json/ballot/dispute/1", "json/ballot/dispute/999", "json/ballots", "json/ballots/1/2",
		"json/commit/1/" + string(alice), "json/reveal/1/" + string(alice), "json/proposals", "json/params", "json/health", "json/ballot/x"} {
		out := dao.Render(cross(cur), path)
		if _, err := json.Unmarshal([]byte(out)); err != nil {
			t.Fatalf("%s: not JSON: %v\n%s", path, err, out)
		}
	}
	b, _ := json.Unmarshal([]byte(dao.Render(cross(cur), "json/ballot/dispute/1")))
	phase, _ := b.MustKey("phase").GetString()
	uassert.Equal(t, dao.BallotResolved, phase)
	d, _ := b.MustKey("dispute").GetNumeric()
	uassert.Equal(t, float64(1), d)
	uassert.True(t, b.HasKey("revealEnds"))

	// the voters are the DAO members staked by the staking stories
	m, _ := json.Unmarshal([]byte(dao.Render(cross(cur), "json/member/"+string(alice))))
	exists, _ := m.MustKey("exists").GetBool()
	uassert.True(t, exists)
	uassert.True(t, m.HasKey("power"))
	none, _ := json.Unmarshal([]byte(dao.Render(cross(cur), "json/member/"+string(dave))))
	daveExists, _ := none.MustKey("exists").GetBool()
	uassert.False(t, daveExists)

	committedVoters := 0
	for _, who := range []address{alice, bob, carol} {
		c, _ := json.Unmarshal([]byte(dao.Render(cross(cur), "json/commit/1/"+string(who))))
		if committed, _ := c.MustKey("committed").GetBool(); committed {
			committedVoters++
		}
	}
	uassert.True(t, committedVoters >= 1)
}

// readerPath is the consumer realm the stories subscribe when they read.
const readerPath = "gno.land/r/demo/reader"

// roundValue and feedValue read values off the public machine views, which
// show everything (a realm's Read is gated, the pages are not).
func roundValue(cur realm, feed, round uint64) int64 {
	node, err := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/"+strconv.FormatUint(feed, 10)+"/round/"+strconv.FormatUint(round, 10))))
	if err != nil {
		panic(err)
	}
	v, _ := node.MustKey("value").GetNumeric()
	return int64(v)
}

func feedValue(cur realm, feed uint64) int64 {
	node, err := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/"+strconv.FormatUint(feed, 10))))
	if err != nil {
		panic(err)
	}
	v, _ := node.MustKey("value").GetNumeric()
	return int64(v)
}
