// Package core_test drives the permanent realm with its first implementation
// end to end: a recurring price feed from proposal to reads, liveness
// penalties, unbonding, a one-off feed from a trusted requester, and the
// gates that keep strangers out. The implementation is registered from the
// test the way the counter example does it, standing in for the deploy
// transaction whose init would do it on chain.
package core_test

import (
	"strconv"
	"strings"
	"testing"

	json "gno.land/p/onbloc/json/v0"

	"chain"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
	implv1 "gno.land/r/clockwork/gnoracle/core/impl/v1"
)

const (
	corePath = "gno.land/r/clockwork/gnoracle/core"
	implPath = "gno.land/r/clockwork/gnoracle/core/impl/v1"
	gnot     = int64(1_000_000)
)

var (
	admin     = core.Admin
	requester = address("g1requester00000000000000000000000000000")
	alice     = address("g1alice000000000000000000000000000000000")
	bob       = address("g1bob00000000000000000000000000000000000")
	carol     = address("g1carol000000000000000000000000000000000")
	dave      = address("g1dave0000000000000000000000000000000000")
	consumer  = address("g1consumer000000000000000000000000000000")
	stranger  = address("g1stranger000000000000000000000000000000")
	coreAddr  = chain.PackageAddress(corePath)
)

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }

// nosend clears the coin envelope for the next call. testing.SetRealm is
// scoped to the frame that calls it, so the realm switch itself is written
// inline in every test body.
func nosend() { testing.SetOriginSend(nil) }

// pay attaches n ugnot to the next call. The harness does not move coins for
// a MsgCall, so the realm's balance is topped up to what the chain would have
// delivered.
func pay(n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(coreAddr, coins(n))
}

func skip(seconds int64) { testing.SkipHeights(seconds / 5) }

var installed bool

// install registers and accepts the implementation once. The harness keeps
// realm state across test functions but starts each with a fresh banker, so
// it also re-issues the realm the coins its ledger says it holds.
func install(cur realm) {
	if diff := core.HeldTotal() - core.Balance(); diff > 0 {
		testing.IssueCoins(coreAddr, coins(diff))
	}
	if installed {
		return
	}
	installed = true
	testing.SetRealm(testing.NewCodeRealm(implPath))
	core.RegisterImpl(cross(cur), implv1.Instance())
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), implPath)
	// small floors so the stories can run with round numbers; each change is
	// limited to 50% of the current value, so step down in several calls
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	for _, v := range []int64{5_000 * gnot, 2_500 * gnot, 1_250 * gnot, 1_000 * gnot} {
		core.SetParam(cross(cur), "providerMinStakeFloor", v)
		testing.SkipHeights(1) // parameters change at most once per height
	}
	for _, v := range []int64{32, 16, 8} {
		core.SetParam(cross(cur), "minRoundsKept", v)
		testing.SkipHeights(1) // parameters change at most once per height
	}
}

func priceSpec(interval, window, minStake, price, sub int64) string {
	return `{"name":"GNOT/USD","description":"Spot price.","kind":"recurring","valueType":"numeric","decimals":6,` +
		`"interval":` + strconv.FormatInt(interval, 10) + `,"submitWindow":` + strconv.FormatInt(window, 10) + `,` +
		`"sources":"Median of three exchanges at round start.","minProviders":2,"maxProviders":5,` +
		`"providerMinStake":` + strconv.FormatInt(minStake, 10) + `,"toleranceBps":100,"quarantineBps":1000,` +
		`"disputeWindow":43200,"readPrice":` + strconv.FormatInt(price, 10) + `,"subscriptionPrice":` + strconv.FormatInt(sub, 10) + `}`
}

func health(t *testing.T) {
	t.Helper()
	h := core.Health()
	if !strings.Contains(h, `"status":"ok"`) {
		t.Fatalf("conservation broken: %s", h)
	}
}

func TestPriceFeedLifecycle(cur realm, t *testing.T) {
	install(cur)
	uassert.Equal(t, implPath, core.LivePath())

	// --- propose: deposit 5 GNOT + first period 100 GNOT
	spec := priceSpec(3600, 600, 1_000*gnot, 20_000, 100*gnot)
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(105 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	f := core.GetFeed(id)
	uassert.Equal(t, core.FeedProposed, f.Status)
	uassert.Equal(t, int64(5*gnot), f.Deposit)
	uassert.Equal(t, int64(100*gnot), f.Prepaid) // the first period waits in escrow until activation
	uassert.Equal(t, int64(0), f.Pool)
	health(t)

	// under-funded proposals are refused
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(50 * gnot)
	uassert.AbortsContains(t, cur, "send at least", func() { core.ProposeFeed(cross(cur), spec) })

	// only the authority activates
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { core.ActivateFeed(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	f = core.GetFeed(id)
	uassert.Equal(t, core.FeedActive, f.Status)
	uassert.Equal(t, int64(0), f.Deposit) // refunded on activation
	uassert.Equal(t, int64(0), f.Prepaid)
	uassert.Equal(t, int64(70*gnot), f.Pool) // 70% of the prepaid period, split at activation
	uassert.True(t, f.StartAt > core.Now())
	uassert.Equal(t, int64(0), f.StartAt%3600)
	// drip: 70 GNOT over 720 hourly rounds
	uassert.Equal(t, int64(70*gnot/720), f.Drip)
	health(t)

	// --- providers register; the minimum binds
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(500 * gnot)
	uassert.AbortsContains(t, cur, "stake at least", func() { core.Register(cross(cur), id, "alice") })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "alice: coinbase, kraken, binance")
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(2_000 * gnot)
	core.Register(cross(cur), id, "carol")
	f = core.GetFeed(id)
	uassert.Equal(t, int64(3), f.ActiveCount)
	uassert.Equal(t, string(alice), string(f.SlotAt(0)))
	uassert.Equal(t, string(carol), string(f.SlotAt(2)))
	uassert.Equal(t, uint64(0), core.GetProvider(id, alice).ObligedFrom)
	health(t)

	// --- round 0: nothing before it opens
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "has not opened", func() { core.Submit(cross(cur), id, 0, 1_000_000) })
	skip(f.StartAt - core.Now() + 1)

	// nothing is served yet, so nothing is charged, credit or not
	testing.SetRealm(testing.NewUserRealm(consumer))
	nosend()
	_, _, _, _, tier0 := core.Read(cross(cur), id)
	uassert.Equal(t, "none", tier0)
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(1 * gnot)
	core.DepositFor(cross(cur), consumer)
	testing.SetRealm(testing.NewUserRealm(consumer))
	nosend()
	v, dec, rid, _, tier := core.Read(cross(cur), id)
	uassert.Equal(t, "none", tier)
	uassert.Equal(t, int64(6), dec)
	uassert.Equal(t, int64(0), v)
	uassert.Equal(t, uint64(0), rid)
	uassert.Equal(t, int64(1*gnot), core.GetCredit(consumer).Balance)

	// submissions: alice and bob agree, carol is 5% off (outside 1% tolerance)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 0, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Submit(cross(cur), id, 0, 1_005_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "round is still open", func() { core.Finalize(cross(cur), id, 0) })
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	core.Submit(cross(cur), id, 0, 1_050_000) // last obliged provider: finalises early

	rd := core.GetRound(id, 0)
	uassert.Equal(t, core.RoundAggregated, rd.Status)
	uassert.Equal(t, int64(1_005_000), rd.Value) // lower median of 3 is the middle value
	uassert.Equal(t, uint32(0b011), rd.EligibleMask)
	uassert.Equal(t, "consensus", rd.Tier) // 2 of 3 eligible, no last value
	f = core.GetFeed(id)
	uassert.True(t, f.HaveValue)
	uassert.Equal(t, int64(1_005_000), f.LastValue)
	uassert.Equal(t, uint64(0), f.LastFinalized)
	// carol earned a strike, no reward; alice and bob split the pool
	uassert.Equal(t, int64(1), core.GetProvider(id, carol).Strikes)
	uassert.Equal(t, int64(0), core.GetProvider(id, carol).Rewards)
	uassert.True(t, core.GetProvider(id, alice).Rewards > 0)
	uassert.Equal(t, core.GetProvider(id, alice).Rewards, core.GetProvider(id, bob).Rewards)
	health(t)

	// the consumer now reads a consensus value and pays the read price
	testing.SetRealm(testing.NewUserRealm(consumer))
	nosend()
	v, _, rid, at, tier := core.Read(cross(cur), id)
	uassert.Equal(t, int64(1_005_000), v)
	uassert.Equal(t, uint64(0), rid)
	uassert.Equal(t, f.StartAt, at)
	uassert.Equal(t, "consensus", tier)
	uassert.Equal(t, int64(1*gnot-20_000), core.GetCredit(consumer).Balance)
	// a reader without credit is refused once there is something to serve
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "insufficient credit", func() { core.Read(cross(cur), id) })

	// --- round 1: only alice submits; window closes; anyone finalises
	skip(3600)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 1, 1_010_000)
	skip(600)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Finalize(cross(cur), id, 1)
	rd = core.GetRound(id, 1)
	uassert.Equal(t, core.RoundEmpty, rd.Status) // 1 eligible < minProviders 2
	uassert.Equal(t, int64(1), core.GetProvider(id, bob).ConsecutiveMisses)
	uassert.Equal(t, int64(1), core.GetProvider(id, carol).ConsecutiveMisses)
	uassert.Equal(t, int64(0), core.GetProvider(id, alice).ConsecutiveMisses)
	// misses cost 0.5% of stake: bob 5 GNOT, carol 10 GNOT
	uassert.Equal(t, int64(995*gnot), core.GetProvider(id, bob).Stake)
	uassert.Equal(t, int64(1_990*gnot), core.GetProvider(id, carol).Stake)
	health(t)

	// the served value is still round 0, now aging toward final
	testing.SetRealm(testing.NewUserRealm(consumer))
	nosend()
	v, _, rid, _, tier = core.Read(cross(cur), id)
	uassert.Equal(t, uint64(0), rid)
	uassert.Equal(t, "consensus", tier)

	// --- round 2: all three submit close together; the median moves 20%
	skip(3600 - 600)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 2, 1_200_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Submit(cross(cur), id, 2, 1_201_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	core.Submit(cross(cur), id, 2, 1_199_000)
	rd = core.GetRound(id, 2)
	uassert.Equal(t, "consensus", rd.Tier) // no final value exists yet (round 0's window is 12 h), so there is no quarantine reference
	uassert.Equal(t, int64(1_200_000), rd.Value)
	uassert.Equal(t, int64(0), core.GetProvider(id, bob).ConsecutiveMisses) // reset on submit
	health(t)

	// --- after the dispute window the value is final; the free view then shows it
	rendered := core.Render(cross(cur), "feed/"+strconv.FormatUint(id, 10))
	uassert.True(t, strings.Contains(rendered, "(fresh; read on-chain)"))
	skip(43200 + 601)
	testing.SetRealm(testing.NewUserRealm(consumer))
	nosend()
	_, _, _, _, tier = core.Read(cross(cur), id)
	uassert.Equal(t, "stale", tier) // final, but no round for 12 h: staleness wins
	rendered = core.Render(cross(cur), "feed/"+strconv.FormatUint(id, 10))
	uassert.True(t, strings.Contains(rendered, "1.200000"))

	// --- rewards are claimable; conservation holds
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	got := core.ClaimRewards(cross(cur), id)
	uassert.True(t, got > 0)
	uassert.Equal(t, int64(0), core.GetProvider(id, alice).Rewards)
	health(t)

	// --- catch-up writes off the rounds nobody submitted to, without penalties
	stakeBefore := core.GetProvider(id, bob).Stake
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	n := core.CatchUp(cross(cur), id, 10)
	uassert.True(t, n >= 10)
	uassert.Equal(t, stakeBefore, core.GetProvider(id, bob).Stake)
	f = core.GetFeed(id)
	uassert.Equal(t, core.RoundSkipped, core.GetRound(id, 5).Status)
	health(t)
}

func TestMissesJailAndUnbond(cur realm, t *testing.T) {
	install(cur)
	spec := priceSpec(600, 300, 1_000*gnot, 0, 100*gnot)
	spec = strings.Replace(spec, `"readPrice":0`, `"readPrice":0,"sponsored":true`, 1)
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(105 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "")
	f := core.GetFeed(id)
	skip(f.StartAt - core.Now() + 1)

	// bob never shows up: three misses jail him
	for r := uint64(0); r < 3; r++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		nosend()
		core.Submit(cross(cur), id, r, 100)
		skip(300)
		testing.SetRealm(testing.NewUserRealm(dave))
		nosend()
		core.Finalize(cross(cur), id, r)
		skip(300)
	}
	p := core.GetProvider(id, bob)
	uassert.Equal(t, core.ProviderJailed, p.Status)
	uassert.Equal(t, int64(3), p.ConsecutiveMisses)
	uassert.Equal(t, int64(-1), p.Slot)
	uassert.Equal(t, int64(1), core.GetFeed(id).ActiveCount)
	uassert.True(t, p.Stake < 1_000*gnot)
	uassert.True(t, p.Stake >= 985*gnot) // three misses of 0.5%
	health(t)

	// jailed providers cannot submit; unjail needs the cooldown
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	uassert.AbortsContains(t, cur, "not an active provider", func() { core.Submit(cross(cur), id, 3, 100) })
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	uassert.AbortsContains(t, cur, "cooldown", func() { core.Unjail(cross(cur), id) })
	skip(24*3600 + 5)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	uassert.AbortsContains(t, cur, "top up", func() { core.Unjail(cross(cur), id) }) // slashed below the minimum
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(20 * gnot)
	core.TopUp(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Unjail(cross(cur), id)
	p = core.GetProvider(id, bob)
	uassert.Equal(t, core.ProviderActive, p.Status)
	uassert.Equal(t, int64(0), p.ConsecutiveMisses)
	uassert.Equal(t, int64(2), core.GetFeed(id).ActiveCount)

	// alice leaves: unbonding takes 14 days and pays out with rewards
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.RequestUnbond(cross(cur), id)
	p = core.GetProvider(id, alice)
	uassert.Equal(t, core.ProviderUnbonding, p.Status)
	uassert.Equal(t, int64(1_000*gnot), p.UnbondAmount)
	uassert.Equal(t, int64(1), core.GetFeed(id).ActiveCount)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "has not passed", func() { core.Withdraw(cross(cur), id) })
	skip(14*24*3600 + 5)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	out := core.Withdraw(cross(cur), id)
	uassert.True(t, out >= 1_000*gnot)
	uassert.True(t, core.GetProvider(id, alice) == nil)
	health(t)
}

func TestOneOffFeedFromTrustedRequester(cur realm, t *testing.T) {
	install(cur)
	market := "gno.land/r/demo/market"
	marketAddr := chain.PackageAddress(market)
	resolveAt := core.Now() + 2*3600
	spec := `{"name":"Election 2026","kind":"oneoff","valueType":"categorical","options":["Yes","No","Invalid"],` +
		`"resolveAt":` + strconv.FormatInt(resolveAt, 10) + `,"submitWindow":600,"bounty":50000000,` +
		`"sources":"Official results page.","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,` +
		`"disputeWindow":259200,"readPrice":2000,"valueAtStake":1000000000}`

	// a realm proposes without coins: it needs credit and, to self-activate, trust
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(200 * gnot)
	core.DepositFor(cross(cur), marketAddr)
	testing.SetRealm(testing.NewCodeRealm(market))
	id := core.ProposeFeed(cross(cur), spec)
	uassert.Equal(t, core.FeedProposed, core.GetFeed(id).Status)
	uassert.Equal(t, int64(145*gnot), core.GetCredit(marketAddr).Balance) // 5 deposit + 50 bounty

	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.SetTrustedRequester(cross(cur), market, 10_000*gnot)
	testing.SetRealm(testing.NewCodeRealm(market))
	id2 := core.ProposeFeed(cross(cur), spec)
	f := core.GetFeed(id2)
	uassert.Equal(t, core.FeedActive, f.Status) // self-activated
	uassert.Equal(t, resolveAt, f.StartAt)
	uassert.Equal(t, int64(50*gnot), f.Pool)
	uassert.Equal(t, int64(0), f.Deposit) // refunded to the realm's credit
	uassert.Equal(t, int64(145*gnot-55*gnot+5*gnot), core.GetCredit(marketAddr).Balance)
	health(t)

	testing.SetRealm(testing.NewUserRealm(alice))
	pay(1_000 * gnot)
	core.Register(cross(cur), id2, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(1_000 * gnot)
	core.Register(cross(cur), id2, "")
	skip(resolveAt - core.Now() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "not a valid option", func() { core.Submit(cross(cur), id2, 0, 3) })
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id2, 0, 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Submit(cross(cur), id2, 0, 1) // unanimous: finalises

	rd := core.GetRound(id2, 0)
	uassert.Equal(t, core.RoundAggregated, rd.Status)
	uassert.Equal(t, int64(1), rd.Value)
	uassert.Equal(t, "consensus", rd.Tier)
	// the whole bounty minus the 1% tip is split between the two
	uassert.Equal(t, int64(50*gnot-50*gnot/100)/2, core.GetProvider(id2, alice).Rewards)

	// the market realm reads its outcome (charged 2000 from its credit)
	testing.SetRealm(testing.NewCodeRealm(market))
	v, _, _, _, tier := core.Read(cross(cur), id2)
	uassert.Equal(t, int64(1), v)
	uassert.Equal(t, "consensus", tier)
	uassert.Equal(t, int64(95*gnot-2000), core.GetCredit(marketAddr).Balance)
	health(t)
}

func TestGates(cur realm, t *testing.T) {
	install(cur)
	// a foreign realm cannot obtain the store
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/intruder"))
	uassert.AbortsContains(t, cur, "state is reachable only through", func() {
		core.Store(0, cur)
	})
	// parameters respect bounds and the rate limit
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "out of bounds", func() { core.SetParam(cross(cur), "missSlashBps", 501) })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "more than", func() { core.SetParam(cross(cur), "missSlashBps", 100) })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.SetParam(cross(cur), "missSlashBps", 75)
	testing.SkipHeights(1) // parameters change at most once per height
	uassert.Equal(t, int64(75), core.Param("missSlashBps"))
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { core.SetParam(cross(cur), "missSlashBps", 50) })
	// coins are required where coins are taken
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/intruder"))
	uassert.AbortsContains(t, cur, "must be called directly", func() { core.Register(cross(cur), 1, "") })
	health(t)
}

// TestJSONViews checks the machine views parse and carry the fields the
// off-chain tools depend on (the earlier stories left feed 1 in place).
func TestJSONViews(cur realm, t *testing.T) {
	for _, path := range []string{"json", "json/now", "json/feeds", "json/feeds/0/2", "json/feed/1", "json/feed/1/round/0", "json/feed/1/round/current",
		"json/feed/1/rounds/5", "json/feed/1/providers", "json/feed/1/provider/" + string(alice), "json/disputes", "json/credit/" + string(consumer),
		"json/health", "json/params", "json/feed/999", "json/feed/x", "json/nothing"} {
		out := core.Render(cross(cur), path)
		if _, err := json.Unmarshal([]byte(out)); err != nil {
			t.Fatalf("%s: not JSON: %v\n%s", path, err, out)
		}
	}
	feed, err := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/1")))
	uassert.NoError(t, err)
	id, _ := feed.MustKey("id").GetNumeric()
	uassert.Equal(t, float64(1), id)
	slots, _ := feed.MustKey("slots").GetArray()
	uassert.Equal(t, 15, len(slots))
	dec, _ := feed.MustKey("spec").MustKey("decimals").GetNumeric()
	uassert.Equal(t, float64(6), dec)
	now, _ := feed.MustKey("now").GetNumeric()
	uassert.True(t, now > 0)
	// the harness clock sits before the feed's start here, so the schedule
	// view reports the feed as not started rather than a current round
	current, _ := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/1/round/current")))
	uassert.True(t, current.HasKey("started") || current.HasKey("id"))

	missing, _ := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/999")))
	uassert.True(t, missing.HasKey("error"))

	rounds, _ := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/1/rounds/3")))
	list, _ := rounds.MustKey("rounds").GetArray()
	uassert.True(t, len(list) >= 1)
	uassert.True(t, list[0].HasKey("closesAt"))

	uassert.True(t, strings.HasPrefix(core.Render(cross(cur), "disputes"), "# Disputes"))
	uassert.Equal(t, "unknown dispute", core.Render(cross(cur), "dispute/999"))
}

// TestObligationsAndDepartures pins the rule that a round counts the slot
// holders of record that owed it a submission: a newcomer cannot submit to
// the round in progress at registration (its obligations start at the next
// one), and a provider that leaves after submitting is still counted and
// paid for that round. Before this rule a stray submission made the round
// unfinalisable ("agg: malformed tier input") and stalled the feed.
func TestObligationsAndDepartures(cur realm, t *testing.T) {
	install(cur)
	spec := priceSpec(600, 300, 1_000*gnot, 20_000, 100*gnot)
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(105 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	for _, who := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(who))
		pay(1_000 * gnot)
		core.Register(cross(cur), id, "early bird")
	}
	f := core.GetFeed(id)
	skip(f.StartAt - core.Now() + 1) // round 0 is open

	// carol registers during round 0: obliged from round 1, and round 0 is not hers to serve
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "latecomer")
	uassert.Equal(t, uint64(1), core.GetProvider(id, carol).ObligedFrom)
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	uassert.AbortsContains(t, cur, "obligations start at round 1", func() { core.Submit(cross(cur), id, 0, 1_000_000) })

	// the two obliged providers complete round 0 and it finalises early
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 0, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Submit(cross(cur), id, 0, 1_001_000)
	rd := core.GetRound(id, 0)
	uassert.Equal(t, core.RoundAggregated, rd.Status)
	uassert.Equal(t, "consensus", rd.Tier)
	aliceBefore := core.GetProvider(id, alice).Rewards

	// round 1: alice submits, then leaves; bob and carol complete the round
	skip(600)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 1, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.RequestUnbond(cross(cur), id)
	uassert.Equal(t, core.ProviderUnbonding, core.GetProvider(id, alice).Status)
	uassert.Equal(t, int64(2), core.GetFeed(id).ActiveCount)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Submit(cross(cur), id, 1, 1_001_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	core.Submit(cross(cur), id, 1, 1_002_000)
	rd = core.GetRound(id, 1)
	uassert.Equal(t, core.RoundAggregated, rd.Status)
	uassert.Equal(t, "consensus", rd.Tier)
	uassert.Equal(t, uint64(1), core.GetFeed(id).LastFinalized)
	uassert.True(t, core.GetProvider(id, alice).Rewards > aliceBefore) // paid as the holder of record
	uassert.Equal(t, int64(0), core.GetProvider(id, alice).ConsecutiveMisses)

	// round 2: alice is gone; bob and carol alone complete it
	skip(600)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	core.Submit(cross(cur), id, 2, 1_001_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	core.Submit(cross(cur), id, 2, 1_001_500)
	uassert.Equal(t, core.RoundAggregated, core.GetRound(id, 2).Status)
	uassert.Equal(t, int64(0), core.GetProvider(id, alice).ConsecutiveMisses) // not obliged any more
	uassert.True(t, strings.Contains(core.Health(), `"status":"ok"`))
}

// TestRejectedRequestRefundsPrepayment pins the escrow: a request's prepaid
// period waits with the deposit until activation; a rejection returns both,
// a spam rejection forfeits the deposit only.
func TestRejectedRequestRefundsPrepayment(cur realm, t *testing.T) {
	install(cur)
	spec := priceSpec(3600, 600, 1_000*gnot, 20_000, 100*gnot)
	heldBefore := core.HeldTotal()
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(105 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	f := core.GetFeed(id)
	uassert.Equal(t, int64(5*gnot), f.Deposit)
	uassert.Equal(t, int64(100*gnot), f.Prepaid)
	uassert.Equal(t, int64(0), f.Pool)
	uassert.Equal(t, heldBefore+105*gnot, core.HeldTotal())

	_, _, _, _, _, _, feesBefore, _ := core.Held()
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.DeprecateFeed(cross(cur), id, "not needed")
	f = core.GetFeed(id)
	uassert.Equal(t, int64(0), f.Deposit)
	uassert.Equal(t, int64(0), f.Prepaid)
	uassert.Equal(t, heldBefore, core.HeldTotal()) // everything went back to the requester
	_, _, _, _, _, _, feesAfter, _ := core.Held()
	uassert.Equal(t, feesBefore, feesAfter)

	testing.SetRealm(testing.NewUserRealm(requester))
	pay(105 * gnot)
	id2 := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.DeprecateFeed(cross(cur), id2, "spam")
	_, _, _, _, _, _, feesSpam, _ := core.Held()
	uassert.Equal(t, feesAfter+5*gnot, feesSpam)        // the deposit is forfeited
	uassert.Equal(t, heldBefore+5*gnot, core.HeldTotal()) // the prepayment still returned
	uassert.True(t, strings.Contains(core.Health(), `"status":"ok"`))
}
