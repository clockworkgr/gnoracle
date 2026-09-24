package core_test

import (
	"strconv"
	"strings"
	"testing"

	"chain"

	json "gno.land/p/onbloc/json/v0"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// newPriceFeed proposes and activates a recurring feed from the requester
// account and returns its id.
func newPriceFeed(cur realm, spec string) uint64 {
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(105 * gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	return id
}

func oneOffSpec(resolveAt int64) string {
	return `{"name":"Match result","kind":"oneoff","valueType":"categorical","options":["Home","Away","Draw"],` +
		`"resolveAt":` + strconv.FormatInt(resolveAt, 10) + `,"submitWindow":600,"bounty":50000000,` +
		`"sources":"The league's results page.","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,` +
		`"disputeWindow":7200}`
}

func sponsoredSpec() string {
	return strings.Replace(priceSpec(600, 300, 1_000*gnot, 0, 100*gnot), `"subscriberPrice":0`, `"subscriberPrice":0,"sponsored":true`, 1)
}

// TestSubscriptionPaths covers the ways a realm gets and keeps the right to
// Read: extending a live subscription, renewing a lapsed one, a realm paying
// for another from its prepaid balance (with a -send on the transaction it
// cannot spend), the period count, and the refusals.
func TestSubscriptionPaths(cur realm, t *testing.T) {
	install(cur)
	period := core.Param("subscriptionPeriod")
	id := newPriceFeed(cur, priceSpec(3600, 600, 1_000*gnot, 20_000, 100*gnot))
	target := "gno.land/r/demo/subs_target"

	// an account pays one period, then extends the live subscription by two
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000)
	core.SubscribeRealm(cross(cur), id, target, 1)
	s := core.GetSubscription(id, target)
	firstUntil := s.PaidUntil
	uassert.Equal(t, core.Now()+period, firstUntil)
	uassert.Equal(t, int64(1), s.Periods)
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(40_000)
	core.SubscribeRealm(cross(cur), id, target, 2)
	s = core.GetSubscription(id, target)
	uassert.Equal(t, firstUntil+2*period, s.PaidUntil) // extended from the paid end, not from now
	uassert.Equal(t, int64(3), s.Periods)              // periods paid, not payments made
	uassert.Equal(t, int64(60_000), s.Paid)
	health(t)

	// underpayment is refused
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(39_999)
	uassert.AbortsContains(t, cur, "send at least", func() { core.SubscribeRealm(cross(cur), id, target, 2) })

	// after it lapses a renewal starts from now
	skip(3*period + 10)
	uassert.False(t, core.IsSubscribed(id, target, core.Now()))
	testing.SetRealm(testing.NewCodeRealm(target))
	uassert.AbortsContains(t, cur, "not subscribed", func() { core.Read(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000)
	core.SubscribeRealm(cross(cur), id, target, 1)
	uassert.Equal(t, core.Now()+period, core.GetSubscription(id, target).PaidUntil)
	uassert.Equal(t, int64(4), core.GetSubscription(id, target).Periods)

	// a realm pays for another realm from its prepaid balance; a -send on
	// the transaction is the signer's, not the realm's, and is ignored
	payer := "gno.land/r/demo/subs_payer"
	payerAddr := chain.PackageAddress(payer)
	other := "gno.land/r/demo/subs_other"
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(100_000)
	core.DepositFor(cross(cur), payerAddr)
	testing.SetRealm(testing.NewCodeRealm(payer))
	testing.SetOriginSend(coins(5_000))
	core.SubscribeRealm(cross(cur), id, other, 3)
	uassert.Equal(t, int64(100_000-60_000), core.GetCredit(payerAddr).Balance)
	uassert.Equal(t, int64(3), core.GetSubscription(id, other).Periods)
	uassert.True(t, core.IsSubscribed(id, other, core.Now()))
	uassert.False(t, core.IsSubscribed(id, payer, core.Now()))
	testing.SetRealm(testing.NewCodeRealm(payer))
	nosend()
	uassert.AbortsContains(t, cur, "insufficient prepaid balance", func() { core.SubscribeRealm(cross(cur), id, other, 3) })
	health(t)

	// realm paths are validated: gno.land/r/ and [a-z0-9_] segments
	for _, bad := range []string{
		"", "gno.land/r/", "gno.land/p/demo/x", "gno.land/r/Demo", "gno.land/r/demo//x", "gno.land/r/demo/",
		"gno.land/r/demo/x`y", "gno.land/r/demo/[x](y)", "gno.land/r/demo/x|y", "gno.land/r/demo/x y",
		"gno.land/r/" + strings.Repeat("a", 118),
	} {
		testing.SetRealm(testing.NewUserRealm(consumer))
		pay(20_000)
		uassert.AbortsContains(t, cur, "pkgPath must be a realm path", func() { core.SubscribeRealm(cross(cur), id, bad, 1) })
	}
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000)
	ok := "gno.land/r/" + strings.Repeat("a", 117) // 128 bytes
	core.SubscribeRealm(cross(cur), id, ok, 1)
	uassert.True(t, core.IsSubscribed(id, ok, core.Now()))

	// periods are bounded
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000 * 13)
	uassert.AbortsContains(t, cur, "between 1 and 12", func() { core.SubscribeRealm(cross(cur), id, target, 13) })
	testing.SetRealm(testing.NewUserRealm(consumer))
	nosend()
	uassert.AbortsContains(t, cur, "between 1 and 12", func() { core.SubscribeRealm(cross(cur), id, target, 0) })

	// refusals: sponsored, one-off, deprecated
	sponsored := newPriceFeed(cur, sponsoredSpec())
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000)
	uassert.AbortsContains(t, cur, "sponsored feed is free", func() { core.SubscribeRealm(cross(cur), sponsored, target, 1) })
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(55 * gnot)
	oneoff := core.ProposeFeed(cross(cur), oneOffSpec(core.Now()+4*3600))
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), oneoff)
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000)
	uassert.AbortsContains(t, cur, "one-off outcome is open to every realm", func() { core.SubscribeRealm(cross(cur), oneoff, target, 1) })
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.DeprecateFeed(cross(cur), id, "retired")
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(20_000)
	uassert.AbortsContains(t, cur, "not active", func() { core.SubscribeRealm(cross(cur), id, target, 1) })
	health(t)
}

// TestFreeReads: a feed's own realm requester, a sponsored feed and a one-off
// outcome need no subscription; the pages serve people, not realms.
func TestFreeReads(cur realm, t *testing.T) {
	install(cur)
	// a realm requests a recurring feed and reads it without subscribing
	req := "gno.land/r/demo/subs_requester"
	reqAddr := chain.PackageAddress(req)
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(200 * gnot)
	core.DepositFor(cross(cur), reqAddr)
	testing.SetRealm(testing.NewCodeRealm(req))
	id := core.ProposeFeed(cross(cur), priceSpec(3600, 600, 1_000*gnot, 20_000, 100*gnot))
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	testing.SetRealm(testing.NewCodeRealm(req))
	_, _, _, _, tier := core.Read(cross(cur), id)
	uassert.Equal(t, "none", tier)
	testing.SetRealm(testing.NewCodeRealm(req))
	_, _, _, _, tier = core.ReadFinal(cross(cur), id)
	uassert.Equal(t, "none", tier)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/subs_stranger"))
	uassert.AbortsContains(t, cur, "not subscribed", func() { core.Read(cross(cur), id) })

	// a sponsored feed serves every realm
	sponsored := newPriceFeed(cur, sponsoredSpec())
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/subs_stranger"))
	_, _, _, _, tier = core.Read(cross(cur), sponsored)
	uassert.Equal(t, "none", tier)
	// accounts are sent to the pages
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "Read serves realms", func() { core.Read(cross(cur), sponsored) })

	// Render refuses realms (it would bypass the gate) and serves people.
	// (MsgRun scripts, gno.land/e/..., are served too; the harness cannot
	// impersonate one: NewCodeRealm accepts realm paths only.)
	path := "json/feed/" + strconv.FormatUint(id, 10)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/subs_stranger"))
	uassert.True(t, strings.Contains(core.Render(cross(cur), path), "realms read values through Read"))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/subs_stranger"))
	uassert.True(t, strings.Contains(core.Render(cross(cur), "releases"), "realms read values through Read"))
	testing.SetRealm(testing.NewUserRealm(stranger))
	_, err := json.Unmarshal([]byte(core.Render(cross(cur), path)))
	uassert.NoError(t, err)
}

// TestSubscriberViews pages the subscriber list (page and JSON) and checks
// the feed page's bounded count, the single-subscription view, and that
// PruneFeed reclaims a feed with more index entries than one batch across
// several calls.
func TestSubscriberViews(cur realm, t *testing.T) {
	install(cur)
	id := newPriceFeed(cur, priceSpec(3600, 600, 1_000*gnot, 2_000, 100*gnot))
	n := core.PruneBatch + 20
	for k := 0; k < n; k++ {
		testing.SetRealm(testing.NewUserRealm(consumer))
		pay(2_000)
		core.SubscribeRealm(cross(cur), id, "gno.land/r/demo/v"+strconv.Itoa(1000+k), 1)
	}
	health(t)
	sid := strconv.FormatUint(id, 10)

	testing.SetRealm(testing.NewUserRealm(stranger))
	page := core.Render(cross(cur), "feed/"+sid)
	uassert.True(t, strings.Contains(page, "100+ subscribed"))

	testing.SetRealm(testing.NewUserRealm(stranger))
	page = core.Render(cross(cur), "feed/"+sid+"/subscribers")
	uassert.True(t, strings.Contains(page, "`gno.land/r/demo/v1000`"))
	uassert.True(t, strings.Contains(page, "`gno.land/r/demo/v1049`"))
	uassert.False(t, strings.Contains(page, "`gno.land/r/demo/v1050`"))
	uassert.True(t, strings.Contains(page, "[next page](:feed/"+sid+"/subscribers/50/50)"))
	testing.SetRealm(testing.NewUserRealm(stranger))
	page = core.Render(cross(cur), "feed/"+sid+"/subscribers/250/100")
	uassert.True(t, strings.Contains(page, "`gno.land/r/demo/v1275`"))
	uassert.False(t, strings.Contains(page, "next page"))
	uassert.True(t, strings.Contains(page, "previous page"))

	testing.SetRealm(testing.NewUserRealm(stranger))
	node, err := json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/"+sid+"/subscribers")))
	uassert.NoError(t, err)
	list, _ := node.MustKey("subscribers").GetArray()
	uassert.Equal(t, 50, len(list))
	more, _ := node.MustKey("more").GetBool()
	uassert.True(t, more)
	testing.SetRealm(testing.NewUserRealm(stranger))
	node, _ = json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/"+sid+"/subscribers/250/100")))
	list, _ = node.MustKey("subscribers").GetArray()
	uassert.Equal(t, n-250, len(list))
	more, _ = node.MustKey("more").GetBool()
	uassert.False(t, more)
	first, _ := list[0].MustKey("realm").GetString()
	uassert.Equal(t, "gno.land/r/demo/v1250", first)

	testing.SetRealm(testing.NewUserRealm(stranger))
	node, _ = json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/"+sid+"/subscription/gno.land/r/demo/v1007")))
	periods, _ := node.MustKey("periods").GetNumeric()
	uassert.Equal(t, float64(1), periods)
	active, _ := node.MustKey("active").GetBool()
	uassert.True(t, active)
	testing.SetRealm(testing.NewUserRealm(stranger))
	node, _ = json.Unmarshal([]byte(core.Render(cross(cur), "json/feed/"+sid+"/subscription/gno.land/r/demo/none")))
	exists, _ := node.MustKey("exists").GetBool()
	uassert.False(t, exists)

	// sponsored and one-off feeds say there is nothing to subscribe to
	sponsored := newPriceFeed(cur, sponsoredSpec())
	testing.SetRealm(testing.NewUserRealm(stranger))
	page = core.Render(cross(cur), "feed/"+strconv.FormatUint(sponsored, 10)+"/subscribers")
	uassert.True(t, strings.Contains(page, "nothing to subscribe to"))

	// the account page refuses what is not an address
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.Equal(t, "unknown account", core.Render(cross(cur), "account/[x](javascript:y)"))

	// prune: a retired feed's entries go in batches, the record with the last
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.DeprecateFeed(cross(cur), id, "retired")
	skip(core.Param("retentionAfterDeprecate") + 10)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.PruneFeed(cross(cur), id)
	uassert.True(t, core.GetFeed(id) != nil) // more than one batch
	uassert.True(t, core.GetSubscription(id, "gno.land/r/demo/v1000") == nil)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.PruneFeed(cross(cur), id)
	uassert.True(t, core.GetFeed(id) == nil)
	uassert.True(t, core.GetSubscription(id, "gno.land/r/demo/v1275") == nil)
	health(t)
}

// TestUnfundedFeedRefilledBySubscription: a subscription's provider share
// can refill an unfunded feed's pool, which then serves as funded again.
// Also pins UpdateFeed's bounds.
func TestUnfundedFeedRefilledBySubscription(cur realm, t *testing.T) {
	install(cur)
	id := newPriceFeed(cur, priceSpec(600, 300, 1_000*gnot, 20_000, 100*gnot))
	// raise the price so the drip outruns the pool
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "at most", func() {
		core.UpdateFeed(cross(cur), id, `{"subscriptionPrice":1000000000000001}`)
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	// the ceiling a new spec meets: unbondPeriod - 6 days - appealWindow
	uassert.AbortsContains(t, cur, "disputeWindow must be between", func() {
		core.UpdateFeed(cross(cur), id, `{"disputeWindow":864000}`)
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.UpdateFeed(cross(cur), id, `{"subscriptionPrice":1000000000000000}`)
	f := core.GetFeed(id)
	uassert.True(t, f.Drip > f.Pool)
	skip(f.StartAt - core.Now() + 301)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Finalize(cross(cur), id, 0)
	uassert.Equal(t, core.FeedUnfunded, core.GetFeed(id).Status)

	// a subscription large enough to cover a drip reactivates it
	f = core.GetFeed(id)
	need := (f.Drip-f.Pool)*10_000/7_000 + 1
	testing.SetRealm(testing.NewUserRealm(consumer))
	pay(need)
	core.SubscribeRealm(cross(cur), id, "gno.land/r/demo/refill", 1)
	uassert.Equal(t, core.FeedActive, core.GetFeed(id).Status)
	health(t)
}

// TestDeadFeedUnseatsProviders: a recurring feed that stays empty for
// deadFeedRounds is deprecated at finalisation and its providers are
// unseated and unbonding, as DeprecateFeed does.
func TestDeadFeedUnseatsProviders(cur realm, t *testing.T) {
	install(cur)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	for _, v := range []int64{84, 42, 24} {
		core.SetParam(cross(cur), "deadFeedRounds", v)
		testing.SkipHeights(1) // parameters change at most once per height
	}
	id := newPriceFeed(cur, priceSpec(600, 300, 1_000*gnot, 20_000, 100*gnot))
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "")
	f := core.GetFeed(id)
	skip(f.StartAt - core.Now() + 30*600)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.CatchUp(cross(cur), id, 48)
	f = core.GetFeed(id)
	uassert.Equal(t, core.FeedDeprecated, f.Status)
	uassert.Equal(t, int64(0), f.ActiveCount)
	uassert.Equal(t, int64(0), f.Pool)
	p := core.GetProvider(id, alice)
	uassert.Equal(t, core.ProviderUnbonding, p.Status)
	uassert.Equal(t, int64(1_000*gnot), p.UnbondAmount)
	health(t)
	// restore the default for the other stories
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	for _, v := range []int64{36, 54, 81, 121, 168} {
		core.SetParam(cross(cur), "deadFeedRounds", v)
		testing.SkipHeights(1)
	}
}

// TestReopenRebasesObligations: after a one-off's round comes back empty,
// the reopened round 0 is owed by the providers seated now. A provider
// jailed for missing the first round is not obliged to it, so the seated
// ones can finalise it early without him.
func TestReopenRebasesObligations(cur realm, t *testing.T) {
	install(cur)
	resolveAt := core.Now() + 2*3600
	testing.SetRealm(testing.NewUserRealm(requester))
	pay(55 * gnot)
	id := core.ProposeFeed(cross(cur), oneOffSpec(resolveAt))
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	for _, who := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(who))
		pay(1_000 * gnot)
		core.Register(cross(cur), id, "")
	}
	skip(resolveAt - core.Now() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 0, 1)
	skip(601)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Finalize(cross(cur), id, 0)
	uassert.Equal(t, core.RoundEmpty, core.GetRound(id, 0).Status) // one of two
	uassert.Equal(t, core.ProviderJailed, core.GetProvider(id, bob).Status)

	// only the requester reopens
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "only the requester", func() { core.ReopenOneOff(cross(cur), id, core.Now()+3*3600) })
	newAt := core.Now() + 3*3600
	testing.SetRealm(testing.NewUserRealm(requester))
	nosend()
	core.ReopenOneOff(cross(cur), id, newAt)
	uassert.Equal(t, uint64(0), core.GetProvider(id, alice).ObligedFrom)
	uassert.Equal(t, uint64(1), core.GetProvider(id, bob).ObligedFrom)
	uassert.Equal(t, "", string(core.SlotHolderAt(id, 1, 0))) // bob's old seat is no longer round 0's

	// a newcomer is seated for the new round; alice and carol complete it
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(1_000 * gnot)
	core.Register(cross(cur), id, "")
	uassert.Equal(t, uint64(0), core.GetProvider(id, carol).ObligedFrom)
	skip(newAt - core.Now() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	core.Submit(cross(cur), id, 0, 2)
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	core.Submit(cross(cur), id, 0, 2) // every obliged provider in: finalises early
	uassert.Equal(t, core.RoundAggregated, core.GetRound(id, 0).Status)
	health(t)
}

// TestMoneyEdges pins the overflow-safe basis-point product and that fees
// wait in the realm until a DAO is registered.
func TestMoneyEdges(cur realm, t *testing.T) {
	install(cur)
	uassert.Equal(t, int64(700_000_000_000_000), core.MulBps(1_000_000_000_000_000, 7000))
	uassert.Equal(t, int64(9_223_372_036_854_775_807), core.MulBps(9_223_372_036_854_775_807, 10_000))
	uassert.Equal(t, int64(3), core.MulBps(7, 5000))
	if !core.HasDAO() {
		_, _, _, _, _, _, before, _ := core.Held()
		testing.SetRealm(testing.NewUserRealm(stranger))
		nosend()
		uassert.Equal(t, int64(0), core.ForwardFees(cross(cur)))
		_, _, _, _, _, _, after, _ := core.Held()
		uassert.Equal(t, before, after)
	}
	uassert.True(t, core.IsAuthority(admin))
	uassert.False(t, core.IsAuthority(stranger))
	uassert.NoError(t, core.CheckParam("missSlashBps", core.Param("missSlashBps")))
	uassert.Error(t, core.CheckParam("missSlashBps", 100_000))
	uassert.Error(t, core.CheckParam("nope", 1))
	uassert.NoError(t, core.CheckParamStr("kourtRealm", "gno.land/r/demo/kourt"))
	uassert.Error(t, core.CheckParamStr("missSlashBps", "x"))
}
