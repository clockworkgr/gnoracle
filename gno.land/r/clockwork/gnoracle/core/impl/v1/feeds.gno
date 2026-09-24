package impl

import (
	"strconv"

	"gno.land/p/clockwork/gnoracle/spec/v0"
	json "gno.land/p/onbloc/json/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

func limits() spec.Limits {
	// unbonding must outlast a dispute opened at the end of the window: two
	// ballot rounds (24 h + 24 h, then 48 h + 24 h) plus the appeal window
	maxDispute := param("unbondPeriod") - 6*24*3600 - param("appealWindow")
	return spec.Limits{
		ProviderMinStakeFloor: param("providerMinStakeFloor"),
		SubscriberFloor:       param("subscriberFloor"),
		SubscriptionFloor:     param("subscriptionFloor"),
		BountyFloor:           param("bountyFloor"),
		MaxDisputeWindow:      maxDispute,
	}
}

// ProposeFeed parses and validates the spec, takes the deposit and the first
// funding, and either files the feed for a vote or, for a trusted requester's
// one-off feed under the cap, activates it at once.
func (*implV1) ProposeFeed(_ int, rlm realm, proposer address, callerPkg string, specJSON string, sent int64) uint64 {
	st := core.Store(0, rlm)
	sp, err := spec.Parse(specJSON, now(), limits())
	if err != nil {
		panic("gnoracle: " + err.Error())
	}
	deposit := param("feedDeposit")
	funding := sp.SubscriptionPrice
	if !sp.IsRecurring() {
		funding = sp.Bounty
	}
	required := deposit + funding
	fromRealm := callerPkg != ""
	f := st.NewFeed(proposer, fromRealm, sp, 0, sp.ValueAtStake)
	if fromRealm {
		if sent != 0 {
			panic("gnoracle: a realm cannot attach coins; its credit pays")
		}
		st.CreditSpendOnFeed(proposer, f.ID, deposit, funding)
	} else {
		if sent < required {
			panic("gnoracle: send at least " + i(required) + StakeUnit + " (deposit " + i(deposit) + " plus funding " + i(funding) + ")")
		}
		st.CreditDeposit(proposer, sent)
		st.CreditSpendOnFeed(proposer, f.ID, deposit, sent-deposit)
	}
	// trusted requesters self-activate one-off feeds under the cap
	if fromRealm && !sp.IsRecurring() {
		if limit := core.TrustedCap(callerPkg); limit > 0 && sp.ValueAtStake <= limit && sp.ValueAtStake <= param("trustedOneOffCap") {
			activate(st, f)
		}
	}
	return f.ID
}

// StakeUnit is the denomination suffix used in messages.
const StakeUnit = "ugnot"

// ActivateFeed accepts a proposed feed.
func (*implV1) ActivateFeed(_ int, rlm realm, feedID uint64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status != core.FeedProposed {
		panic("gnoracle: feed is not awaiting activation")
	}
	activate(st, f)
}

func activate(st *core.StateRef, f *core.Feed) {
	sp := f.Spec
	t := now()
	var startAt, drip int64
	if sp.IsRecurring() {
		startAt = t - t%sp.Interval + sp.Interval
		drip = dripFor(sp)
	} else {
		if sp.ResolveAt <= t {
			panic("gnoracle: the resolve time has passed; propose again")
		}
		startAt = sp.ResolveAt
	}
	st.FeedActivate(f.ID, startAt, drip)
	st.DepositRefund(f.ID)
	st.FeedSetPaidUntil(f.ID, t+param("subscriptionPeriod"))
}

// dripFor is the provider share of one subscription period spread over the
// period's rounds.
func dripFor(sp *spec.Spec) int64 {
	perRound := param("subscriptionPeriod") / sp.Interval
	if perRound < 1 {
		perRound = 1
	}
	share := core.MulBps(sp.SubscriptionPrice, param("feeSplitProvidersBps"))
	return share / perRound
}

// DeprecateFeed retires a feed. A proposed feed is rejected (deposit back,
// or to the treasury with reason "spam"); an active feed's remaining funds go
// to the fee pool.
func (*implV1) DeprecateFeed(_ int, rlm realm, feedID uint64, reason string) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedDeprecated {
		panic("gnoracle: already deprecated")
	}
	if f.Status == core.FeedProposed {
		if reason == "spam" {
			st.DepositToFees(feedID) // the deposit; the prepayment still goes back
		} else {
			st.DepositRefund(feedID)
		}
	}
	if f.Spec.IsRecurring() {
		st.FeedPoolToFees(feedID)
	} else {
		st.FeedPoolRefund(feedID) // an undistributed bounty is the requester's
	}
	retire(st, feedID, reason)
}

// retire unseats every active or jailed provider (nothing will be served
// again, so each starts unbonding) and marks the feed deprecated. The
// caller has already routed the feed's funds.
func retire(st *core.StateRef, feedID uint64, reason string) {
	var seated []*core.Provider
	core.IterateProviders(feedID, func(p *core.Provider) bool {
		if p.Status == core.ProviderActive || p.Status == core.ProviderJailed {
			seated = append(seated, p)
		}
		return false
	})
	for _, p := range seated {
		leave(st, mustFeed(feedID), p)
	}
	st.FeedSetStatus(feedID, core.FeedDeprecated)
	st.Emit("FeedDeprecated", "feed", u(feedID), "reason", reason)
}

// UpdateFeed changes the DAO-adjustable economics of a feed. The payload is a
// JSON object with any of subscriberPrice, subscriptionPrice,
// providerMinStake, toleranceBps, quarantineBps, disputeWindow.
func (*implV1) UpdateFeed(_ int, rlm realm, feedID uint64, changesJSON string) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedDeprecated {
		panic("gnoracle: feed is deprecated")
	}
	root, err := json.Unmarshal([]byte(changesJSON))
	if err != nil || !root.IsObject() {
		panic("gnoracle: changes must be a JSON object")
	}
	sp := f.Spec
	subscriberPrice, subPrice, minStake := sp.SubscriberPrice, sp.SubscriptionPrice, sp.ProviderMinStake
	tol, quar, window := sp.ToleranceBps, sp.QuarantineBps, sp.DisputeWindow
	get := func(key string, cur int64) int64 {
		if !root.HasKey(key) {
			return cur
		}
		n, err := root.GetKey(key)
		if err != nil || !n.IsNumber() {
			panic("gnoracle: " + key + " must be an integer")
		}
		v, perr := strconv.ParseInt(n.String(), 10, 64)
		if perr != nil || v < 0 {
			panic("gnoracle: " + key + " must be a non-negative integer")
		}
		return v
	}
	subscriberPrice = get("subscriberPrice", subscriberPrice)
	subPrice = get("subscriptionPrice", subPrice)
	minStake = get("providerMinStake", minStake)
	tol = get("toleranceBps", tol)
	quar = get("quarantineBps", quar)
	window = get("disputeWindow", window)
	lim := limits()
	// the same dispute-window ceiling spec.Parse applies to a new feed
	maxWindow := spec.MaxDisputeWindow
	if lim.MaxDisputeWindow > 0 && lim.MaxDisputeWindow < maxWindow {
		maxWindow = lim.MaxDisputeWindow
	}
	if maxWindow < spec.MinDisputeWindow {
		maxWindow = spec.MinDisputeWindow
	}
	switch {
	case subscriberPrice > spec.MaxAmount || subPrice > spec.MaxAmount || minStake > spec.MaxAmount:
		panic("gnoracle: prices and stakes must be at most " + i(spec.MaxAmount) + StakeUnit)
	case sp.IsRecurring() && !sp.Sponsored && subscriberPrice < lim.SubscriberFloor:
		panic("gnoracle: subscriberPrice is below the floor")
	case (!sp.IsRecurring() || sp.Sponsored) && subscriberPrice != 0:
		panic("gnoracle: only a recurring, non-sponsored feed has a subscriberPrice")
	case sp.IsRecurring() && subPrice < lim.SubscriptionFloor:
		panic("gnoracle: subscriptionPrice is below the floor")
	case minStake < lim.ProviderMinStakeFloor:
		panic("gnoracle: providerMinStake is below the floor")
	case tol < spec.MinToleranceBps || tol > spec.MaxToleranceBps:
		panic("gnoracle: toleranceBps out of range")
	case quar < tol || quar > spec.MaxQuarantineBps:
		panic("gnoracle: quarantineBps out of range")
	case window < spec.MinDisputeWindow || window > maxWindow:
		panic("gnoracle: disputeWindow must be between " + i(spec.MinDisputeWindow) + " and " + i(maxWindow) + " seconds")
	}
	st.FeedSetSpecEconomics(feedID, subscriberPrice, subPrice, minStake, tol, quar, window)
	if sp.IsRecurring() && subPrice != sp.SubscriptionPrice {
		st.FeedSetDrip(feedID, dripFor(mustFeed(feedID).Spec))
	}
}

// Sponsor pays periods of a feed's subscription so it stays funded.
func (*implV1) Sponsor(_ int, rlm realm, sponsor address, feedID uint64, periods int64, sent int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if !isServing(f) {
		panic("gnoracle: feed is not active")
	}
	if !f.Spec.IsRecurring() {
		panic("gnoracle: one-off feeds take bounties, not subscriptions")
	}
	if periods < 1 || periods > 12 {
		panic("gnoracle: periods must be between 1 and 12")
	}
	required := f.Spec.SubscriptionPrice * periods
	if sent < required {
		panic("gnoracle: send at least " + i(required) + StakeUnit)
	}
	t := now()
	base := t
	if s := core.GetSponsor(feedID, sponsor); s != nil && s.PaidUntil > t {
		base = s.PaidUntil
	}
	until := base + periods*param("subscriptionPeriod")
	st.SponsorPay(feedID, sponsor, sent, until)
	if until > f.PaidUntil {
		st.FeedSetPaidUntil(feedID, until)
	}
	if f.Status == core.FeedUnfunded {
		st.FeedSetStatus(feedID, core.FeedActive)
	}
}

// FundBounty adds to a one-off feed's bounty.
func (*implV1) FundBounty(_ int, rlm realm, feedID uint64, sent int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Spec.IsRecurring() {
		panic("gnoracle: recurring feeds take subscriptions, not bounties")
	}
	if f.Status == core.FeedDeprecated {
		panic("gnoracle: feed is deprecated")
	}
	if sent <= 0 {
		panic("gnoracle: send the bounty with the call")
	}
	st.BountyIn(feedID, sent)
}

// PruneRounds deletes settled rounds past retention, oldest first. It first
// promotes what has become final, and never deletes a round the last-final
// cursor has not passed: an aggregated round must be considered for
// promotion before it can go.
func (*implV1) PruneRounds(_ int, rlm realm, caller address, feedID uint64, maxRounds int64) int64 {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if maxRounds <= 0 || maxRounds > 200 {
		maxRounds = 50
	}
	if !f.HaveLast {
		return 0
	}
	st.FeedPromoteFinal(feedID)
	f = mustFeed(feedID)
	retention := param("roundRetention")
	keep := uint64(param("minRoundsKept"))
	t := now()
	if f.Status == core.FeedDeprecated && t >= f.DeprecatedAt+param("retentionAfterDeprecate") {
		keep = 0 // a retired feed past its retention keeps nothing
	}
	var deleted int64
	next := f.OldestRound
	for deleted < maxRounds && next <= f.LastFinalized && next < f.FinalCursor {
		if f.LastFinalized-next < keep {
			break
		}
		rd := core.GetRound(feedID, next)
		if rd != nil {
			if rd.FinalisedAt == 0 || rd.FinalisedAt+retention > t || rd.FinalisedAt+f.Spec.DisputeWindow > t {
				break
			}
			if rd.DisputeID != 0 {
				if d := core.GetDispute(rd.DisputeID); d != nil && d.Status != core.DisputeResolved {
					break // a dispute still needs this round
				}
			}
			st.RoundDelete(feedID, next)
			deleted++
		}
		next++
	}
	if next != f.OldestRound {
		st.FeedSetOldest(feedID, next)
	}
	return deleted
}

// PruneFeed deletes a deprecated feed once its rounds and providers are gone.
// The feed's index entries are removed core.PruneBatch per call; call again
// until the feed is gone (the FeedPruned event).
func (*implV1) PruneFeed(_ int, rlm realm, caller address, feedID uint64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status != core.FeedDeprecated {
		panic("gnoracle: only a deprecated feed can be pruned")
	}
	if now() < f.DeprecatedAt+param("retentionAfterDeprecate") {
		panic("gnoracle: retention has not passed")
	}
	if f.HaveLast && f.OldestRound <= f.LastFinalized {
		if core.GetRound(feedID, f.OldestRound) != nil || f.OldestRound < f.LastFinalized {
			panic("gnoracle: prune the rounds first")
		}
	}
	// providers: unclaimed rewards forfeit (plan §5.2), ready unbonds are paid
	// out, records with nothing left are removed (collected first: the tree
	// must not change while it is iterated)
	var all []*core.Provider
	core.IterateProviders(feedID, func(p *core.Provider) bool {
		all = append(all, p)
		return false
	})
	t := now()
	left := false
	for _, p := range all {
		if p.Rewards > 0 {
			st.RewardForfeit(feedID, p.Addr)
		}
		if p.Status == core.ProviderUnbonding && p.UnbondAmount > 0 && t >= p.UnbondReadyAt {
			st.ProviderPayUnbonded(feedID, p.Addr)
		}
		p = core.GetProvider(feedID, p.Addr)
		if p.Stake != 0 || p.UnbondAmount != 0 {
			left = true
			continue
		}
		st.ProviderDelete(feedID, p.Addr)
	}
	if left {
		panic("gnoracle: providers still hold stake on this feed")
	}
	// anything that reached the pool after deprecation (bond shares routed
	// by a dispute resolved late) goes to the fees
	st.FeedPoolToFees(feedID)
	st.FeedDelete(feedID)
}
