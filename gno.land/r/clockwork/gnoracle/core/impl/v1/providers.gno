package impl

import (
	"gno.land/r/clockwork/gnoracle/core"
)

// Register bonds a provider on a feed.
func (*implV1) Register(_ int, rlm realm, provider address, feedID uint64, memo string, sent int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if !isServing(f) {
		panic("gnoracle: feed is not active")
	}
	if len(memo) > 512 {
		panic("gnoracle: memo is longer than 512 bytes")
	}
	if sent < f.Spec.ProviderMinStake {
		panic("gnoracle: stake at least " + i(f.Spec.ProviderMinStake) + StakeUnit)
	}
	if old := core.GetProvider(feedID, provider); old != nil {
		if old.Status != core.ProviderWithdrawn || old.Stake != 0 || old.UnbondAmount != 0 || old.Rewards != 0 {
			panic("gnoracle: already a provider of this feed")
		}
		st.ProviderDelete(feedID, provider)
	}
	if f.ActiveCount >= int64(f.Spec.MaxProviders) {
		panic("gnoracle: the feed's provider set is full")
	}
	if !f.Spec.IsRecurring() {
		if _, started := schedule(f).Current(now()); started {
			panic("gnoracle: the one-off round is in progress; nothing is left to serve")
		}
	}
	slot := freeSlot(f)
	from := obligedFrom(f)
	st.NewProvider(feedID, provider, sent, int64(slot), memo, from)
	st.FeedAssignSlot(feedID, int64(slot), provider, from)
}

func freeSlot(f *core.Feed) int {
	for s := 0; s < core.MaxSlots; s++ {
		if f.SlotAt(s) == "" {
			return s
		}
	}
	panic("gnoracle: no free slot")
}

// obligedFrom is the first round a provider seated now owes: the round after
// the current one, or round 0 before the feed starts. A one-off feed whose
// round has opened returns 1, a round that never exists: slot changes after
// the opening then never rewrite round 0's holders of record, and a late
// joiner cannot submit to the round in progress.
func obligedFrom(f *core.Feed) uint64 {
	sched := schedule(f)
	cur, ok := sched.Current(now())
	if !ok {
		return 0
	}
	if sched.IsOneOff() {
		return 1
	}
	return cur + 1
}

// leave takes a provider out of the active set (its slot is cleared from
// the next round on) and starts its unbond period.
func leave(st *core.StateRef, f *core.Feed, p *core.Provider) {
	if p.Status == core.ProviderActive {
		st.FeedClearSlot(f.ID, p.Slot, obligedFrom(f))
	}
	st.ProviderStartUnbond(f.ID, p.Addr, now()+param("unbondPeriod"))
}

// TopUp adds stake.
func (*implV1) TopUp(_ int, rlm realm, provider address, feedID uint64, sent int64) {
	st := core.Store(0, rlm)
	p := core.GetProvider(feedID, provider)
	if p == nil || (p.Status != core.ProviderActive && p.Status != core.ProviderJailed) {
		panic("gnoracle: not an active or jailed provider of this feed")
	}
	if sent <= 0 {
		panic("gnoracle: send the stake with the call")
	}
	st.ProviderAddStake(feedID, provider, sent)
}

// RequestUnbond leaves the active set and starts the unbond period.
func (*implV1) RequestUnbond(_ int, rlm realm, provider address, feedID uint64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	p := core.GetProvider(feedID, provider)
	if p == nil || (p.Status != core.ProviderActive && p.Status != core.ProviderJailed) {
		panic("gnoracle: not an active or jailed provider of this feed")
	}
	leave(st, f, p)
}

// Withdraw pays out after the unbond period, plus any rewards.
func (*implV1) Withdraw(_ int, rlm realm, provider address, feedID uint64) int64 {
	st := core.Store(0, rlm)
	p := core.GetProvider(feedID, provider)
	if p == nil || p.Status != core.ProviderUnbonding {
		panic("gnoracle: nothing is unbonding")
	}
	if now() < p.UnbondReadyAt {
		panic("gnoracle: the unbond period has not passed")
	}
	out := st.ProviderPayUnbonded(feedID, provider)
	out += st.RewardPay(feedID, provider)
	st.ProviderDelete(feedID, provider)
	return out
}

// Unjail returns to the active set after the cooldown.
func (*implV1) Unjail(_ int, rlm realm, provider address, feedID uint64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	p := core.GetProvider(feedID, provider)
	if p == nil || p.Status != core.ProviderJailed {
		panic("gnoracle: not jailed")
	}
	if now() < p.JailedAt+param("jailCooldown") {
		panic("gnoracle: the jail cooldown has not passed")
	}
	if !isServing(f) {
		panic("gnoracle: feed is not active")
	}
	if f.ActiveCount >= int64(f.Spec.MaxProviders) {
		panic("gnoracle: the feed's provider set is full")
	}
	if p.Stake < f.Spec.ProviderMinStake {
		panic("gnoracle: top up to the minimum stake first")
	}
	slot := freeSlot(f)
	from := obligedFrom(f)
	st.ProviderSetStatus(feedID, provider, core.ProviderActive, int64(slot))
	st.ProviderSetCounters(feedID, provider, 0, 0, from, p.LastSubmitted, p.HasSubmitted)
	st.ProviderSetObligedFrom(feedID, provider, from)
	st.FeedAssignSlot(feedID, int64(slot), provider, from)
}

// ClaimRewards pays accrued rewards.
func (*implV1) ClaimRewards(_ int, rlm realm, provider address, feedID uint64) int64 {
	st := core.Store(0, rlm)
	if core.GetProvider(feedID, provider) == nil {
		panic("gnoracle: not a provider of this feed")
	}
	return st.RewardPay(feedID, provider)
}

// ForceUnbond ejects a provider (authority).
func (*implV1) ForceUnbond(_ int, rlm realm, feedID uint64, provider address) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	p := core.GetProvider(feedID, provider)
	if p == nil || (p.Status != core.ProviderActive && p.Status != core.ProviderJailed) {
		panic("gnoracle: not an active or jailed provider of this feed")
	}
	leave(st, f, p)
	st.Emit("ProviderEjected", "feed", u(feedID), "provider", string(provider))
}
