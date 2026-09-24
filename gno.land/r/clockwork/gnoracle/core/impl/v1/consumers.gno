package impl

import (
	"strings"

	"gno.land/p/clockwork/gnoracle/rounds/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// DepositFor adds to an account's prepaid balance (a realm requester's
// operator funds it this way; reads never touch it).
func (*implV1) DepositFor(_ int, rlm realm, account address, sent int64) {
	st := core.Store(0, rlm)
	if sent <= 0 {
		panic("gnoracle: send the amount with the call")
	}
	st.CreditDeposit(account, sent)
}

// WithdrawCredit returns unspent prepaid balance.
func (*implV1) WithdrawCredit(_ int, rlm realm, account address, amount int64) {
	st := core.Store(0, rlm)
	st.CreditWithdraw(account, amount)
}

// SubscribeRealm pays periods of a recurring feed's subscriberPrice for a
// realm. The whole payment, overpayment included, is split like a sponsor's:
// feeSplitProvidersBps (70%) to the feed's pool, the rest (30%) to the fees
// forwarded to the DAO.
func (*implV1) SubscribeRealm(_ int, rlm realm, payer address, payerPkg string, feedID uint64, pkgPath string, periods int64, sent int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if !isServing(f) {
		panic("gnoracle: feed is not active")
	}
	if !f.Spec.IsRecurring() {
		panic("gnoracle: a one-off outcome is open to every realm; there is nothing to subscribe to")
	}
	if f.Spec.Sponsored {
		panic("gnoracle: a sponsored feed is free for every realm; there is nothing to subscribe to")
	}
	if !validRealmPath(pkgPath) {
		panic("gnoracle: pkgPath must be a realm path: gno.land/r/ then lowercase segments of a-z, 0-9 and _ separated by single slashes, at most 128 bytes")
	}
	if periods < 1 || periods > 12 {
		panic("gnoracle: periods must be between 1 and 12")
	}
	// subscriberPrice is at most spec.MaxAmount (1e15) and periods at most
	// 12, so the product cannot overflow
	required := f.Spec.SubscriberPrice * periods
	t := now()
	base := t
	if s := core.GetSubscription(feedID, pkgPath); s != nil && s.PaidUntil > t {
		base = s.PaidUntil
	}
	until := base + periods*param("subscriptionPeriod")
	if payerPkg != "" {
		if sent != 0 {
			panic("gnoracle: a realm cannot attach coins; its prepaid balance pays")
		}
		st.SubscribeFromCredit(payer, feedID, pkgPath, required, periods, until)
	} else {
		if sent < required {
			panic("gnoracle: send at least " + i(required) + StakeUnit + " (" + i(periods) + " x subscriberPrice " + i(f.Spec.SubscriberPrice) + ")")
		}
		st.SubscribePay(feedID, pkgPath, sent, periods, until)
	}
	// the provider share may have refilled an unfunded feed's pool
	if f = mustFeed(feedID); f.Status == core.FeedUnfunded && f.Pool >= f.Drip {
		st.FeedSetStatus(feedID, core.FeedActive)
	}
}

// validRealmPath reports whether p is gno.land/r/ followed by one or more
// segments of [a-z0-9_], separated by single slashes, at most 128 bytes: the
// shape of a realm path, and nothing a page could render as markup.
func validRealmPath(p string) bool {
	const prefix = "gno.land/r/"
	if len(p) > 128 || !strings.HasPrefix(p, prefix) {
		return false
	}
	rest := p[len(prefix):]
	if rest == "" {
		return false
	}
	segLen := 0
	for k := 0; k < len(rest); k++ {
		c := rest[k]
		switch {
		case c == '/':
			if segLen == 0 {
				return false
			}
			segLen = 0
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_':
			segLen++
		default:
			return false
		}
	}
	return segLen > 0
}

// servedTier is the tier a feed's latest value is served under at time t.
// A consensus or provisional value is labelled final only once it is the
// last final round, the one ReadFinal returns: its own dispute window having
// passed is not enough while an earlier round's dispute holds promotion back.
func servedTier(st *core.StateRef, f *core.Feed, t int64) string {
	if !f.HaveValue {
		return "none"
	}
	tier := f.LastTier
	if (tier == "consensus" || tier == "provisional") && t >= f.LastFinalAt+f.Spec.DisputeWindow {
		if _, fr, _, ok := latestFinal(st, f, t); ok && fr == f.LastRound {
			tier = "final"
		}
	}
	if f.Spec.IsRecurring() && rounds.Stale(f.LastRoundAt, t, 2*f.Spec.Interval) {
		tier = "stale"
	}
	if f.Status == core.FeedUnfunded {
		tier += ",unfunded"
	}
	return tier
}

// mayRead is the on-chain gate. Reads serve realms (people have the pages,
// which show everything); a one-off outcome and a sponsored feed serve every
// realm; a feed's own realm requester always may read it; any other realm
// needs a subscription that covers now.
func mayRead(f *core.Feed, caller address, callerPkg string, t int64) {
	if callerPkg == "" {
		panic("gnoracle: Read serves realms; accounts and people use the pages and the :json views, which show every value")
	}
	if !f.Spec.IsRecurring() || f.Spec.Sponsored {
		return
	}
	if f.FromRealm && f.Proposer == caller {
		return
	}
	if !core.IsSubscribed(f.ID, callerPkg, t) {
		panic("gnoracle: " + callerPkg + " is not subscribed to feed " + u(f.ID) + " (SubscribeRealm)")
	}
}

func mustServing(f *core.Feed) {
	if f.Status == core.FeedProposed || f.Status == core.FeedDeprecated {
		panic("gnoracle: feed is not active")
	}
}

// Read returns the latest served value.
//
// The latest aggregate is served with its tier. While the latest round is
// disputed, and after it was voided, the last final round is served instead
// (a captured vote can freeze the feed but not inject a value, plan §7.1).
// Nothing is written: the last final round is computed as of now.
func (*implV1) Read(_ int, rlm realm, caller address, callerPkg string, feedID uint64) (int64, int64, uint64, int64, string) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	mustServing(f)
	t := now()
	mayRead(f, caller, callerPkg, t)
	dec := int64(f.Spec.Decimals)
	tier := servedTier(st, f, t)
	suffix := ""
	if f.Status == core.FeedUnfunded {
		suffix = ",unfunded"
	}
	switch {
	case !f.HaveValue:
		return 0, dec, 0, 0, tier
	case f.LastTier == "disputed" || f.LastTier == "void":
		fv, fr, fa, ok := latestFinal(st, f, t)
		if !ok {
			return 0, dec, 0, 0, tier
		}
		// the void round is replaced by the last final round, served as
		// final unless the feed has gone stale
		if f.LastTier == "void" && !strings.HasPrefix(tier, "stale") {
			tier = "final" + suffix
		}
		return fv, dec, fr, fa, tier
	}
	last, _ := st.FeedValues(feedID)
	return last, dec, f.LastRound, f.LastRoundAt, tier
}

// ReadFinal returns the latest final round, whatever later rounds are doing.
func (*implV1) ReadFinal(_ int, rlm realm, caller address, callerPkg string, feedID uint64) (int64, int64, uint64, int64, string) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	mustServing(f)
	t := now()
	mayRead(f, caller, callerPkg, t)
	dec := int64(f.Spec.Decimals)
	fv, fr, fa, ok := latestFinal(st, f, t)
	if !ok {
		return 0, dec, 0, 0, "none"
	}
	tier := "final"
	if f.Status == core.FeedUnfunded {
		tier += ",unfunded"
	}
	return fv, dec, fr, fa, tier
}

// latestFinal is the last final round as of t, computed without writing:
// the promoted value, then any rounds past the cursor whose dispute window
// has closed with no dispute standing (the write paths promote them later).
func latestFinal(st *core.StateRef, f *core.Feed, t int64) (value int64, round uint64, at int64, ok bool) {
	_, value = st.FeedValues(f.ID)
	round, at, ok = f.FinalRound, f.FinalAt, f.HaveFinal
	if !f.HaveLast {
		return
	}
	rid := f.FinalCursor
	for k := 0; k < 64 && rid <= f.LastFinalized; k++ {
		rd := core.GetRound(f.ID, rid)
		if rd == nil {
			rid++
			continue
		}
		if rd.Status == core.RoundOpen {
			break
		}
		if rd.Status == core.RoundAggregated {
			if rd.FinalisedAt+f.Spec.DisputeWindow > t {
				break
			}
			if rd.DisputeID != 0 {
				if d := core.GetDispute(rd.DisputeID); d != nil && d.Status != core.DisputeResolved {
					break
				}
			}
			value, round, at, ok = st.RoundValue(f.ID, rid), rid, rd.FinalisedAt, true
		}
		rid++
	}
	return
}

// ReadRound returns one round.
func (*implV1) ReadRound(_ int, rlm realm, caller address, callerPkg string, feedID, roundID uint64) (int64, string, int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	mustServing(f)
	t := now()
	mayRead(f, caller, callerPkg, t)
	rd := core.GetRound(feedID, roundID)
	if rd == nil || rd.Status == core.RoundOpen {
		return 0, "none", 0
	}
	tier := rd.Tier
	if rd.Status == core.RoundAggregated && (tier == "consensus" || tier == "provisional") && t >= rd.FinalisedAt+f.Spec.DisputeWindow {
		tier = "final"
	}
	if rd.Status != core.RoundAggregated {
		tier = rd.Status
	}
	return st.RoundValue(feedID, roundID), tier, rd.FinalisedAt
}
