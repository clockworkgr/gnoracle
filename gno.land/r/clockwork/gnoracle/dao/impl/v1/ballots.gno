package impl

import (
	"strconv"
	"strings"

	"gno.land/p/clockwork/gnoracle/tally/v0"
	"gno.land/r/clockwork/gnoracle/dao"
)

// Dispute ballots (plan §7.2, §7.3): sealed at the current epoch, commit then
// reveal, clipped per address, decided by a supermajority with a void
// fallback, rolled once, appealable once.

func ballotRules(round int64, major bool) tally.Rules {
	if round >= 2 {
		return tally.Rules{QuorumBps: param("disputeQuorumBps2"), DecisionBps: param("decisionBps2"), MaxVoterShareBps: param("maxVoterShareBps"), MajorRequested: major}
	}
	return tally.Rules{QuorumBps: param("disputeQuorumBps"), DecisionBps: param("decisionBps"), MaxVoterShareBps: param("maxVoterShareBps"), MajorRequested: major}
}

func openBallot(st *dao.StateRef, disputeID uint64, round int64, major bool, summary string, prev uint64) uint64 {
	sealed := dao.Epoch()
	obligated := dao.TotalPowerAt(sealed)
	t := now()
	commit, reveal := param("commitPeriod"), param("revealPeriod")
	if round >= 2 {
		commit, reveal = param("commitPeriod2"), param("revealPeriod2")
	}
	if len(summary) > 256 {
		summary = summary[:256]
	}
	return st.NewBallot(disputeID, round, major, summary, sealed, obligated, t+commit, t+commit+reveal, prev)
}

// OpenDisputeVote seals the round-1 ballot of a dispute.
func (*implV1) OpenDisputeVote(_ int, rlm realm, disputeID uint64, majorRequested bool, summary string) uint64 {
	st := dao.Store(0, rlm)
	if dao.BallotOf(disputeID) != 0 {
		panic("dao: dispute already has a ballot")
	}
	return openBallot(st, disputeID, 1, majorRequested, summary, 0)
}

// OpenAppealRound seals a round-2 ballot after a decided round 1. Round 2
// decides the dispute, so round 1 is re-resolved as a roll: no rewards, no
// incoherence, only absence and abstention charged (to the treasury), and it
// is final at once so settlement never waits on it.
func (*implV1) OpenAppealRound(_ int, rlm realm, disputeID uint64) uint64 {
	st := dao.Store(0, rlm)
	seq := dao.BallotOf(disputeID)
	b := dao.GetBallot(seq)
	if b == nil || b.Phase != dao.BallotResolved || b.Round != 1 || b.Final {
		panic("dao: no decided, unapplied round-1 ballot to appeal")
	}
	raw := tally.Weights{Uphold: b.Uphold, Overturn: b.Overturn, OverturnMinor: b.OverturnMinor, Void: b.Void, Abstain: b.Abstain}
	rolled := tally.Result{Outcome: tally.OutcomeRoll, Revealed: raw.Total(), Obligated: b.Obligated, Weights: raw}
	st.BallotSupersede(seq, tally.ExpectedPenaltyPool(rolled, 0, ballotRates()))
	return openBallot(st, disputeID, 2, b.MajorRequested, b.Summary, seq)
}

// FundVoters records coins the core sent for the dispute's latest ballot
// and marks it final (the core calls it when it applies the outcome). A
// round-2 ballot's round 1 is final already; marking it again is harmless
// and keeps a round 1 from ever blocking settlement.
func (*implV1) FundVoters(_ int, rlm realm, disputeID uint64, amount int64) {
	st := dao.Store(0, rlm)
	seq := dao.BallotOf(disputeID)
	b := dao.GetBallot(seq)
	if b == nil {
		panic("dao: unknown dispute")
	}
	if b.Phase != dao.BallotResolved {
		panic("dao: the dispute's ballot is still running")
	}
	st.BallotFund(seq, amount)
	if b.PrevSeq != 0 {
		if prev := dao.GetBallot(b.PrevSeq); prev != nil && !prev.Final {
			st.BallotFund(b.PrevSeq, 0)
		}
	}
}

func ballotRates() tally.Rates {
	return tally.Rates{AbsenceBps: param("absenceSlashBps"), IncoherenceBps: param("incoherenceSlashBps"), AbstainBps: param("abstainSlashBps")}
}

func memberWeight(voter address, sealed uint32) int64 {
	w := dao.PowerAt(voter, sealed)
	m := dao.GetMember(voter)
	if m == nil {
		return 0
	}
	if live := m.Staked + m.UnbondAmount; live < w {
		w = live
	}
	return w
}

// CommitVote posts a commitment during the commit phase.
func (*implV1) CommitVote(_ int, rlm realm, voter address, disputeID uint64, commitment string) {
	st := dao.Store(0, rlm)
	seq := dao.BallotOf(disputeID)
	b := dao.GetBallot(seq)
	if b == nil {
		panic("dao: unknown dispute")
	}
	if b.Phase != dao.BallotCommit || now() >= b.CommitEnds {
		panic("dao: the commit phase is over")
	}
	if len(commitment) != 64 {
		panic("dao: commitment must be 64 hex characters")
	}
	if memberWeight(voter, b.SealedEpoch) <= 0 {
		panic("dao: no voting weight at the ballot's epoch")
	}
	st.BallotCommit(seq, voter, commitment)
}

// RevealVote opens a commitment during the reveal phase.
func (*implV1) RevealVote(_ int, rlm realm, voter address, disputeID uint64, choice, salt string) {
	st := dao.Store(0, rlm)
	seq := dao.BallotOf(disputeID)
	b := dao.GetBallot(seq)
	if b == nil {
		panic("dao: unknown dispute")
	}
	t := now()
	if t < b.CommitEnds {
		panic("dao: the commit phase has not ended")
	}
	if b.Phase == dao.BallotResolved || t >= b.RevealEnds {
		panic("dao: the reveal phase is over")
	}
	if b.Phase == dao.BallotCommit {
		st.BallotSetPhase(seq, dao.BallotReveal, b.CommitEnds, b.RevealEnds)
	}
	if !tally.ValidChoice(choice, b.MajorRequested) {
		panic("dao: choice must be UPHOLD, OVERTURN, VOID or ABSTAIN" + minorHint(b.MajorRequested))
	}
	c := dao.CommitOf(seq, voter)
	if c == "" {
		panic("dao: no commitment to reveal")
	}
	if c != tally.Commitment(disputeID, int(b.Round), choice, salt, voter) {
		panic("dao: reveal does not match the commitment")
	}
	w := memberWeight(voter, b.SealedEpoch)
	if w <= 0 {
		panic("dao: no voting weight at the ballot's epoch")
	}
	top := tally.ReplaceTop(decodeTop(b.TopReveals), tally.Reveal{Voter: voter, Choice: choice, Weight: w})
	st.BallotReveal(seq, voter, choice, w, encodeTop(top))
}

func minorHint(major bool) string {
	if major {
		return " (or OVERTURN_MINOR)"
	}
	return ""
}

// FinishDisputeVote decides a ballot once its reveal phase has ended. It
// returns "PENDING" while the ballot runs, "ROLL" when round 1 reached no
// decision (a round 2 is opened), and the outcome otherwise.
func (*implV1) FinishDisputeVote(_ int, rlm realm, disputeID uint64) (string, string, int64) {
	st := dao.Store(0, rlm)
	seq := dao.BallotOf(disputeID)
	b := dao.GetBallot(seq)
	if b == nil {
		panic("dao: unknown dispute")
	}
	if b.Phase == dao.BallotResolved {
		return b.Outcome, b.Tier, b.CoherentWeight
	}
	if now() < b.RevealEnds {
		return "PENDING", "", 0
	}
	raw := tally.Weights{Uphold: b.Uphold, Overturn: b.Overturn, OverturnMinor: b.OverturnMinor, Void: b.Void, Abstain: b.Abstain}
	clipped, removed := tally.Clip(raw, decodeTop(b.TopReveals), param("maxVoterShareBps"), b.Obligated)
	res := tally.Decide(clipped, b.Obligated, ballotRules(b.Round, b.MajorRequested))
	rates := ballotRates()
	// penalties and rewards follow members' real weights, so the pool and the
	// coherent weight are computed on the raw tally under the decided outcome
	rawRes := tally.Result{Outcome: res.Outcome, Tier: res.Tier, Quorate: res.Quorate, Revealed: raw.Total(), Obligated: b.Obligated, Weights: raw}
	if res.Outcome == tally.OutcomeRoll && b.Round == 1 {
		pool := tally.ExpectedPenaltyPool(rawRes, 0, rates)
		st.BallotResolve(seq, string(tally.OutcomeRoll), "", raw.Uphold, raw.Overturn, raw.OverturnMinor, raw.Void, raw.Abstain, 0, pool, removed, 0)
		openBallot(st, disputeID, 2, b.MajorRequested, b.Summary, seq)
		return "ROLL", "", 0
	}
	if res.Outcome == tally.OutcomeRoll {
		// a second round that decides nothing voids the dispute
		res.Outcome = tally.OutcomeVoid
		res.Tier = ""
		rawRes.Outcome = tally.OutcomeVoid
		rawRes.Tier = ""
	}
	coherent := tally.CoherentWeight(rawRes)
	pool := tally.ExpectedPenaltyPool(rawRes, 0, rates)
	st.BallotResolve(seq, string(res.Outcome), res.Tier, raw.Uphold, raw.Overturn, raw.OverturnMinor, raw.Void, raw.Abstain, coherent, pool, removed, 0)
	return string(res.Outcome), res.Tier, coherent
}

// The heaviest reveals are kept packed in the ballot as "addr|choice|weight;..."

func encodeTop(top []tally.Reveal) string {
	parts := make([]string, 0, len(top))
	for _, r := range top {
		parts = append(parts, string(r.Voter)+"|"+r.Choice+"|"+strconv.FormatInt(r.Weight, 10))
	}
	return strings.Join(parts, ";")
}

func decodeTop(s string) []tally.Reveal {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ";")
	out := make([]tally.Reveal, 0, len(parts))
	for _, p := range parts {
		f := strings.Split(p, "|")
		if len(f) != 3 {
			continue
		}
		w, err := strconv.ParseInt(f[2], 10, 64)
		if err != nil {
			continue
		}
		out = append(out, tally.Reveal{Voter: address(f[0]), Choice: f[1], Weight: w})
	}
	return out
}
