package impl

import (
	"gno.land/p/clockwork/gnoracle/agg/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// Submit records a provider's value for an open round, and finalises the
// round early when every obliged provider has submitted.
func (*implV1) Submit(_ int, rlm realm, provider address, feedID, roundID uint64, value int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if !isServing(f) {
		panic("gnoracle: feed is not active")
	}
	p := core.GetProvider(feedID, provider)
	if p == nil || p.Status != core.ProviderActive || p.Slot < 0 {
		panic("gnoracle: not an active provider of this feed")
	}
	if !f.Spec.ValidValue(value) {
		panic("gnoracle: value is not a valid option")
	}
	sched := schedule(f)
	t := now()
	if !sched.Exists(roundID, t) {
		panic("gnoracle: round has not opened")
	}
	if !sched.IsOpen(roundID, t) {
		panic("gnoracle: round is closed")
	}
	// A provider owes and may serve rounds from ObligedFrom on: the round in
	// progress at registration is not its to serve, and a submission outside
	// the obliged set would break the round's eligible-versus-active count.
	if p.ObligedFrom > roundID {
		panic("gnoracle: obligations start at round " + u(p.ObligedFrom))
	}
	if f.HaveLast && roundID <= f.LastFinalized {
		panic("gnoracle: round is finalised")
	}
	rd := core.GetRound(feedID, roundID)
	if rd == nil {
		rd = st.NewRound(feedID, roundID, sched.OpenAt(roundID))
	} else if rd.Status != core.RoundOpen {
		panic("gnoracle: round is finalised")
	}
	st.RoundSetSubmission(feedID, roundID, p.Slot, value)
	st.ProviderSetCounters(feedID, provider, p.ConsecutiveMisses, p.Strikes, p.StrikeWindowStart, roundID, true)
	st.Emit("Submitted", "feed", u(feedID), "round", u(roundID), "provider", string(provider), "value", i(value))

	// early finalisation once every obliged slot has submitted, in order
	if allSubmitted(f, rd, roundID) && (!f.HaveLast && roundID == 0 || f.HaveLast && roundID == f.LastFinalized+1) {
		finalise(st, rlm, f, roundID, provider)
	}
}

func allSubmitted(f *core.Feed, rd *core.Round, roundID uint64) bool {
	for s := 0; s < core.MaxSlots; s++ {
		if obligedHolder(f, s, roundID) == nil {
			continue
		}
		if rd.SubmittedMask&(1<<uint(s)) == 0 {
			return false
		}
	}
	return true
}

// obligedHolder returns the provider that held slot s for round id and owed
// it a submission, or nil. The slot log answers "who held it then", so a
// provider that left after submitting is still counted and paid for that
// round, and a newcomer whose obligations start later is not.
func obligedHolder(f *core.Feed, s int, id uint64) *core.Provider {
	holder := core.SlotHolderAt(f.ID, int64(s), id)
	if holder == "" {
		return nil
	}
	p := core.GetProvider(f.ID, holder)
	if p == nil || p.ObligedFrom > id {
		return nil
	}
	return p
}

// Finalize closes the next round once its window has passed.
func (*implV1) Finalize(_ int, rlm realm, caller address, feedID, roundID uint64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedProposed {
		panic("gnoracle: feed is not active")
	}
	next := uint64(0)
	if f.HaveLast {
		next = f.LastFinalized + 1
	}
	if roundID != next {
		panic("gnoracle: rounds finalise in order; next is " + u(next))
	}
	sched := schedule(f)
	t := now()
	if !sched.Exists(roundID, t) {
		panic("gnoracle: round has not opened")
	}
	rd := core.GetRound(feedID, roundID)
	if !sched.IsClosed(roundID, t) {
		if rd == nil || !allSubmitted(f, rd, roundID) {
			panic("gnoracle: round is still open")
		}
	}
	finalise(st, rlm, f, roundID, caller)
}

// CatchUp finalises up to maxRounds closed rounds in one call; rounds with
// no submissions are written off as skipped without penalties.
func (*implV1) CatchUp(_ int, rlm realm, caller address, feedID uint64, maxRounds int64) int64 {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedProposed {
		panic("gnoracle: feed is not active")
	}
	limit := param("maxCatchUpRounds")
	if maxRounds > 0 && maxRounds < limit {
		limit = maxRounds
	}
	sched := schedule(f)
	ids := sched.Finalisable(f.LastFinalized, f.HaveLast, now(), int(limit))
	var n int64
	for _, id := range ids {
		f = mustFeed(feedID)
		if f.Status == core.FeedDeprecated {
			break
		}
		rd := core.GetRound(feedID, id)
		if rd == nil {
			skip(st, f, id, sched.OpenAt(id))
		} else {
			finalise(st, rlm, f, id, caller)
		}
		n++
	}
	return n
}

// skip writes off a round nobody submitted to.
func skip(st *core.StateRef, f *core.Feed, id uint64, openedAt int64) {
	st.NewRound(f.ID, id, openedAt)
	st.RoundFinalise(f.ID, id, core.RoundSkipped, "", 0, 0, 0)
	st.FeedSetCursor(f.ID, id)
	st.FeedSetEmptyStreak(f.ID, f.EmptyStreak+1)
	afterEmpty(st, mustFeed(f.ID))
}

// finalise aggregates a round, applies liveness penalties, pays the pool and
// records the served value. It is the one place a round changes status.
func finalise(st *core.StateRef, rlm realm, f *core.Feed, id uint64, cranker address) {
	sched := schedule(f)
	rd := core.GetRound(f.ID, id)
	if rd == nil {
		rd = st.NewRound(f.ID, id, sched.OpenAt(id))
	}
	if rd.Status != core.RoundOpen {
		panic("gnoracle: round already finalised")
	}
	sp := f.Spec
	funded := f.Status == core.FeedActive

	// gather submissions and the obliged set
	var subs agg.Submissions
	subs.Values = make([]int64, core.MaxSlots)
	subs.Present = make([]bool, core.MaxSlots)
	obliged := 0
	holders := make([]*core.Provider, core.MaxSlots)
	for s := 0; s < core.MaxSlots; s++ {
		p := obligedHolder(f, s, id)
		if p == nil {
			continue // an empty slot, or a submission from outside the obliged set: not counted
		}
		holders[s] = p
		obliged++
		if rd.SubmittedMask&(1<<uint(s)) != 0 {
			subs.Values[s] = rd.ValueAt(s)
			subs.Present[s] = true
		}
	}

	// aggregate
	var (
		value    int64
		eligible uint32
		count    int
		ok       bool
	)
	if sp.IsNumeric() {
		value, ok = agg.LowerMedian(subs)
		if ok {
			eligible, count = agg.EligibleNumeric(subs, value, sp.ToleranceBps)
		}
	} else {
		var votes int
		value, votes, ok = agg.Plurality(subs, len(sp.Options))
		if ok && votes > 0 {
			eligible, count = agg.EligibleCategorical(subs, value)
		} else {
			ok = false
		}
	}
	tier := agg.TierEmpty
	if ok {
		tier = agg.DecideTier(agg.TierInput{
			Eligible: count, Active: obliged, MinProviders: sp.MinProviders,
			Value: value, LastFinal: f.LastValue, HaveLast: f.HaveValue, QuarantineBps: sp.QuarantineBps,
		})
	}

	// liveness: misses, strikes, jail (for the holders of record)
	for s := 0; s < core.MaxSlots; s++ {
		p := holders[s]
		if p == nil {
			continue
		}
		holder := p.Addr
		submitted := rd.SubmittedMask&(1<<uint(s)) != 0
		if submitted {
			strikes, windowStart := p.Strikes, p.StrikeWindowStart
			if id-windowStart >= uint64(param("strikeWindowRounds")) {
				strikes, windowStart = 0, id
			}
			if ok && eligible&(1<<uint(s)) == 0 {
				strikes++
			}
			st.ProviderSetCounters(f.ID, holder, 0, strikes, windowStart, p.LastSubmitted, p.HasSubmitted)
			if strikes >= param("strikesToJail") && f.SlotAt(s) == holder {
				jail(st, f, holder, s, id)
			}
			continue
		}
		misses := p.ConsecutiveMisses + 1
		st.ProviderSetCounters(f.ID, holder, misses, p.Strikes, p.StrikeWindowStart, p.LastSubmitted, p.HasSubmitted)
		if funded {
			missSlash(st, f, p, cranker)
		}
		if misses >= param("jailAfterMisses") && f.SlotAt(s) == holder {
			jail(st, f, holder, s, id)
		}
	}

	// payout and record
	status := core.RoundEmpty
	var addrs []address
	if tier != agg.TierEmpty {
		status = core.RoundAggregated
		for s := 0; s < core.MaxSlots; s++ {
			if eligible&(1<<uint(s)) != 0 && holders[s] != nil {
				addrs = append(addrs, holders[s].Addr)
			}
		}
	}
	pool, _, _ := st.RoundPayout(f.ID, addrs, cranker)
	st.RoundFinalise(f.ID, id, status, string(tier), value, eligible, pool)
	st.FeedSetCursor(f.ID, id)
	if status == core.RoundAggregated {
		st.FeedSetValue(f.ID, id, value, string(tier), rd.OpenedAt)
		st.FeedSetEmptyStreak(f.ID, 0)
	} else {
		st.FeedSetEmptyStreak(f.ID, f.EmptyStreak+1)
	}
	f = mustFeed(f.ID)
	if sp.IsRecurring() {
		if f.Status == core.FeedActive && f.Pool < f.Drip {
			st.FeedSetStatus(f.ID, core.FeedUnfunded)
			st.Emit("FeedUnfunded", "feed", u(f.ID))
		} else if f.Status == core.FeedUnfunded && f.Pool >= f.Drip {
			st.FeedSetStatus(f.ID, core.FeedActive)
		}
	}
	afterEmpty(st, mustFeed(f.ID))
}

// afterEmpty deprecates a feed that has produced nothing for deadFeedRounds.
func afterEmpty(st *core.StateRef, f *core.Feed) {
	if f.Status == core.FeedDeprecated {
		return
	}
	if f.Spec.IsRecurring() && f.EmptyStreak >= param("deadFeedRounds") {
		st.FeedPoolToFees(f.ID)
		st.FeedSetStatus(f.ID, core.FeedDeprecated)
	}
}

// missSlash takes the per-miss slash within the per-epoch cap.
func missSlash(st *core.StateRef, f *core.Feed, p *core.Provider, alerter address) {
	t := now()
	epoch := param("providerEpoch")
	epochStart, slashed, minors := p.EpochStart, p.MissSlashedEpoch, p.MinorsEpoch
	if t-epochStart >= epoch {
		epochStart, slashed, minors = t, 0, 0
		st.ProviderSetEpoch(f.ID, p.Addr, epochStart, 0, 0)
	}
	base := p.Stake + slashed // stake at the start of the epoch, approximately
	amount := base * param("missSlashBps") / 10_000
	room := base*param("missSlashCapPerEpochBps")/10_000 - slashed
	if amount > room {
		amount = room
	}
	if amount <= 0 {
		return
	}
	st.MissSlash(f.ID, p.Addr, amount, alerter)
	st.ProviderSetEpoch(f.ID, p.Addr, epochStart, slashed+amount, minors)
}

// jail removes a provider from the active set until it unjails.
func jail(st *core.StateRef, f *core.Feed, addr address, slot int, id uint64) {
	p := core.GetProvider(f.ID, addr)
	if p == nil || p.Status != core.ProviderActive {
		return
	}
	t := now()
	jailings, since := p.Jailings, p.JailingsSince
	if t-since >= 30*24*3600 {
		jailings, since = 0, t
	}
	jailings++
	st.FeedClearSlot(f.ID, int64(slot), id+1)
	st.ProviderSetStatus(f.ID, addr, core.ProviderJailed, -1)
	st.ProviderSetJailings(f.ID, addr, jailings, since)
	st.Emit("ProviderJailed", "feed", u(f.ID), "provider", string(addr), "jailings", i(jailings))
	if jailings >= param("maxJailings") {
		st.ProviderStartUnbond(f.ID, addr, t+param("unbondPeriod"))
	}
}
