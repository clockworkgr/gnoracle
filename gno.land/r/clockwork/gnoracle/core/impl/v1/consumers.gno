package impl

import (
	"gno.land/p/clockwork/gnoracle/rounds/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// DepositFor credits a consumer.
func (*implV1) DepositFor(_ int, rlm realm, consumer address, sent int64) {
	st := core.Store(0, rlm)
	if sent <= 0 {
		panic("gnoracle: send the credit with the call")
	}
	st.CreditDeposit(consumer, sent)
}

// WithdrawCredit returns unspent credit.
func (*implV1) WithdrawCredit(_ int, rlm realm, consumer address, amount int64) {
	st := core.Store(0, rlm)
	st.CreditWithdraw(consumer, amount)
}

// SetFinalOnly toggles a consumer's read mode.
func (*implV1) SetFinalOnly(_ int, rlm realm, consumer address, on bool) {
	st := core.Store(0, rlm)
	st.CreditSetFinalOnly(consumer, on)
}

// servedTier is the tier a feed's latest value is served under at time t.
func servedTier(f *core.Feed, t int64) string {
	if !f.HaveValue {
		return "none"
	}
	tier := f.LastTier
	if tier == "consensus" || tier == "provisional" {
		if t >= f.LastFinalAt+f.Spec.DisputeWindow {
			tier = "final"
		}
	}
	if f.OpenDisputes > 0 {
		tier = "disputed"
	}
	if f.Spec.IsRecurring() && rounds.Stale(f.LastRoundAt, t, 2*f.Spec.Interval) {
		tier = "stale"
	}
	if f.Status == core.FeedUnfunded {
		tier += ",unfunded"
	}
	return tier
}

// charge debits the read fee unless a sponsor or the spec covers it.
func charge(st *core.StateRef, consumer address, f *core.Feed, finalOnly bool, t int64) {
	if f.Spec.Sponsored || f.Spec.ReadPrice == 0 {
		st.CreditCountRead(consumer)
		return
	}
	if s := core.SponsorOf(f.ID, consumer); s != nil && s.PaidUntil >= t {
		st.CreditCountRead(consumer)
		return
	}
	fee := f.Spec.ReadPrice
	if finalOnly {
		fee = fee * param("readPriceFinalBps") / 10_000
	}
	if fee == 0 {
		st.CreditCountRead(consumer)
		return
	}
	st.CreditCharge(consumer, f.ID, fee)
}

// Read returns the latest served value.
func (*implV1) Read(_ int, rlm realm, consumer address, feedID uint64) (int64, int64, uint64, int64, string) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedProposed {
		panic("gnoracle: feed is not active")
	}
	t := now()
	c := core.GetCredit(consumer)
	finalOnly := c != nil && c.FinalOnly
	charge(st, consumer, f, finalOnly, t)
	tier := servedTier(f, t)
	if !f.HaveValue {
		return 0, int64(f.Spec.Decimals), 0, 0, tier
	}
	if finalOnly && !hasPrefix(tier, "final") {
		return 0, int64(f.Spec.Decimals), 0, 0, "none"
	}
	return f.LastValue, int64(f.Spec.Decimals), f.LastRound, f.LastRoundAt, tier
}

// ReadRound returns one round.
func (*implV1) ReadRound(_ int, rlm realm, consumer address, feedID, roundID uint64) (int64, string, int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedProposed {
		panic("gnoracle: feed is not active")
	}
	t := now()
	charge(st, consumer, f, false, t)
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
	return rd.Value, tier, rd.FinalisedAt
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }
