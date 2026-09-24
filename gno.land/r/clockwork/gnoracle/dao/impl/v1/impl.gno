// Package impl is the first implementation of the Gnoracle DAO: staking with
// checkpointed voting power, fee sharing, governance proposals, the dispute
// ballots (commit, reveal, tally, appeal) and the member settlement that
// applies their penalties and rewards.
package impl

import (
	"strconv"

	"gno.land/p/clockwork/gnoracle/tally/v0"
	"gno.land/r/clockwork/gnoracle/dao"
)

type implV1 struct{}

var instance = &implV1{}

// Instance returns the implementation object.
func Instance() dao.DAO { return instance }

func init(cur realm) {
	dao.RegisterImpl(cross(cur), instance)
}

func now() int64 { return dao.Now() }

func param(name string) int64 { return dao.Param(name) }

func u(v uint64) string { return strconv.FormatUint(v, 10) }

func i(v int64) string { return strconv.FormatInt(v, 10) }

// ---- staking

// Stake pulls approved PYTH and stakes it; the member's pending settlements
// run first so weights and penalties stay consistent.
func (*implV1) Stake(_ int, rlm realm, member address, amount int64) {
	st := dao.Store(0, rlm)
	m := dao.GetMember(member)
	if m != nil {
		settle(st, m, param("settleMaxN"), true)
	}
	// a position (new, emptied, or penalised below the minimum) must end at
	// least at the minimum: dust positions would let the fee accumulator's
	// per-share value run away
	staked := int64(0)
	if m != nil {
		staked = m.Staked
	}
	if amount <= 0 || staked+amount < param("minStake") {
		panic("dao: stake at least " + i(param("minStake")) + " base units in total")
	}
	st.MemberStake(member, amount)
}

// RequestUnstake starts the cooldown on part of the stake.
func (*implV1) RequestUnstake(_ int, rlm realm, member address, amount int64) {
	st := dao.Store(0, rlm)
	m := dao.GetMember(member)
	if m == nil {
		panic("dao: not a member")
	}
	settle(st, m, param("settleMaxN"), true)
	if amount <= 0 || amount > m.Staked {
		panic("dao: amount exceeds the stake")
	}
	// leave nothing or at least the minimum: dust positions would let the fee
	// accumulator's per-share value run away
	if rest := m.Staked - amount; rest > 0 && rest < param("minStake") {
		panic("dao: unstake everything or keep at least " + i(param("minStake")) + " base units staked")
	}
	if now() < m.VestedUntil && m.Staked-amount < m.VestFloor {
		panic("dao: vesting keeps " + i(m.VestFloor) + " staked until " + i(m.VestedUntil))
	}
	st.MemberUnstake(member, amount, now()+param("unstakeCooldown"))
}

// Withdraw pays out unbonded stake once the cooldown has passed and every
// dispute the member was obligated in has been settled.
func (*implV1) Withdraw(_ int, rlm realm, member address) int64 {
	st := dao.Store(0, rlm)
	m := dao.GetMember(member)
	if m == nil || m.UnbondAmount == 0 {
		panic("dao: nothing is unbonding")
	}
	if now() < m.UnbondReadyAt {
		panic("dao: the cooldown has not passed")
	}
	settle(st, m, param("settleMaxN"), true)
	if seq := openObligation(m); seq != 0 {
		panic("dao: ballot " + u(seq) + " still obligates this stake; withdraw after its outcome is applied")
	}
	return st.MemberPayUnbonded(member)
}

// openObligation returns a ballot the member holds weight in that is not
// final yet (still running, or decided but not applied by the core), or 0.
// Ballots below the cursor are settled by construction.
func openObligation(m *dao.Member) uint64 {
	total := dao.BallotCount()
	for seq := m.Cursor + 1; seq <= total; seq++ {
		b := dao.GetBallot(seq)
		if b == nil || (b.Phase == dao.BallotResolved && b.Final) {
			continue
		}
		if dao.PowerAt(m.Addr, b.SealedEpoch) > 0 {
			return seq
		}
	}
	return 0
}

// SettleMember processes up to maxN final ballots for a member. Anyone may
// run it.
func (*implV1) SettleMember(_ int, rlm realm, member address, maxN int64) int64 {
	st := dao.Store(0, rlm)
	m := dao.GetMember(member)
	if m == nil {
		panic("dao: not a member")
	}
	if maxN <= 0 || maxN > param("settleMaxN") {
		maxN = param("settleMaxN")
	}
	return settle(st, m, maxN, false)
}

// ClaimFees pays the member's fee share.
func (*implV1) ClaimFees(_ int, rlm realm, member address) int64 {
	st := dao.Store(0, rlm)
	if dao.GetMember(member) == nil {
		panic("dao: not a member")
	}
	st.FeesSync()
	return st.MemberPayFees(member)
}

// ClaimRewards pays dispute rewards.
func (*implV1) ClaimRewards(_ int, rlm realm, member address) (int64, int64) {
	st := dao.Store(0, rlm)
	m := dao.GetMember(member)
	if m == nil {
		panic("dao: not a member")
	}
	settle(st, m, param("settleMaxN"), false)
	return st.MemberPayRewards(member)
}

// SyncFees attributes newly arrived coins.
func (*implV1) SyncFees(_ int, rlm realm) int64 {
	st := dao.Store(0, rlm)
	return st.FeesSync()
}

// settle walks resolved ballots from the member's cursor, applying the
// penalty or reward each one implies (plan §8.4). With strict it refuses to
// leave work behind, which is what stake changes need.
func settle(st *dao.StateRef, m *dao.Member, maxN int64, strict bool) int64 {
	total := dao.BallotCount()
	if m.Cursor >= total {
		return 0
	}
	rates := tally.Rates{AbsenceBps: param("absenceSlashBps"), IncoherenceBps: param("incoherenceSlashBps"), AbstainBps: param("abstainSlashBps")}
	var done int64
	cursor := m.Cursor
	for cursor < total && done < maxN {
		seq := cursor + 1
		b := dao.GetBallot(seq)
		if b == nil || b.Phase != dao.BallotResolved || !b.Final {
			break // an open or not yet funded ballot blocks the cursor until the core applies it
		}
		cursor = seq
		done++
		w := dao.PowerAt(m.Addr, b.SealedEpoch)
		if live := m.Staked + m.UnbondAmount; live < w {
			w = live
		}
		if w <= 0 {
			continue
		}
		outcome := tally.Outcome(b.Outcome)
		if b.Appealed {
			outcome = tally.OutcomeRoll // round 2 decides; round 1 settles like a roll
		}
		res := tally.Result{Outcome: outcome, Tier: b.Tier, Quorate: outcome != tally.OutcomeRoll,
			Revealed: b.Revealed, Obligated: b.Obligated,
			Weights: tally.Weights{Uphold: b.Uphold, Overturn: b.Overturn, OverturnMinor: b.OverturnMinor, Void: b.Void, Abstain: b.Abstain}}
		rev := dao.RevealOf(seq, m.Addr)
		revealed := rev != ""
		choice := ""
		if revealed {
			choice = rev[:indexByte(rev, '|')]
		}
		class := tally.Classify(revealed, choice, res)
		switch class {
		case tally.ClassCoherent:
			// the coherent weight was summed from the revealed weights, so a
			// share is paid on the weight the member revealed with (never
			// more), or the pool could be overpaid
			if rw := revealedWeight(rev); rw < w {
				w = rw
			}
			pyth := tally.RewardShare(b.ExpectedPool, w, b.CoherentWeight)
			ugnot := tally.RewardShare(b.BondShareUgnot, w, b.CoherentWeight)
			st.MemberCreditReward(m.Addr, pyth, ugnot)
		case tally.ClassAbsent, tally.ClassAbstained, tally.ClassIncoherent:
			penalty := tally.Penalty(w, class, rates)
			penalty = capPenalty(st, m, penalty, b.ResolvedAt)
			if penalty > 0 {
				// a ballot without coherent voters (a rolled round) has no
				// claimant for its penalties: they go to the treasury
				st.MemberPenalise(m.Addr, penalty, b.CoherentWeight == 0)
			}
		}
	}
	if done > 0 {
		st.MemberSetCursor(m.Addr, cursor)
	}
	// strict callers must not leave processable ballots behind; a ballot
	// that is still running or not yet funded is not processable and must
	// not block stake changes (weights are sealed per epoch anyway)
	if strict && cursor < total {
		if next := dao.GetBallot(cursor + 1); next != nil && next.Phase == dao.BallotResolved && next.Final {
			panic("dao: settle pending disputes first (SettleMember)")
		}
	}
	return done
}

// capPenalty applies the per-window penalty cap and records the window. The
// window is keyed on when the ballot resolved, not on when the member is
// settled, so settling late neither resets nor stretches the cap.
func capPenalty(st *dao.StateRef, m *dao.Member, penalty int64, resolvedAt int64) int64 {
	t := resolvedAt
	window := param("penaltyWindow")
	at, inWindow := m.PenaltyWindowAt, m.PenaltyInWindow
	if t-at >= window {
		at, inWindow = t, 0
	}
	limit := (m.Staked+m.UnbondAmount+inWindow)*param("maxPenaltyPerWindowBps")/10_000 - inWindow
	if limit < 0 {
		limit = 0
	}
	if penalty > limit {
		st.Emit("PenaltyCapped", "member", string(m.Addr), "forgiven", i(penalty-limit))
		penalty = limit
	}
	st.MemberSetPenaltyWindow(m.Addr, at, inWindow+penalty)
	return penalty
}

// revealedWeight reads the weight of a "choice|weight" reveal (0 if none).
func revealedWeight(rev string) int64 {
	k := indexByte(rev, '|')
	if k >= len(rev) {
		return 0
	}
	w, err := strconv.ParseInt(rev[k+1:], 10, 64)
	if err != nil || w < 0 {
		return 0
	}
	return w
}

func indexByte(s string, c byte) int {
	for k := 0; k < len(s); k++ {
		if s[k] == c {
			return k
		}
	}
	return len(s)
}

// Invoke: this release defines no operations beyond the DAO API.
func (*implV1) Invoke(_ int, rlm realm, caller address, userCall bool, sent int64, method, args string) string {
	dao.Store(0, rlm)
	panic("dao: unknown method " + method)
}
