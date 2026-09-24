package impl

import (
	"gno.land/p/clockwork/gnoracle/agg/v0"
	"gno.land/p/clockwork/gnoracle/spec/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

const (
	tierMinor = "minor"
	tierMajor = "major"
)

// Dispute challenges a finalised round: the disputer posts a bond, names the
// value the round should have had and the slash tier it asks for, and the DAO
// seals a ballot (plan §7.1).
func (*implV1) Dispute(_ int, rlm realm, disputer address, feedID, roundID uint64, proposedValue int64, tier, evidence string, sent int64) uint64 {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Status == core.FeedProposed {
		panic("gnoracle: feed is not active")
	}
	rd := core.GetRound(feedID, roundID)
	if rd == nil || rd.Status != core.RoundAggregated {
		panic("gnoracle: round has no aggregate to dispute")
	}
	if rd.DisputeID != 0 {
		if d := core.GetDispute(rd.DisputeID); d != nil && d.Status != core.DisputeResolved {
			panic("gnoracle: round is under dispute")
		}
		// a resolved dispute leaves the round open to another one while
		// its (restarted) window lasts
	}
	t := now()
	if t >= rd.FinalisedAt+f.Spec.DisputeWindow {
		panic("gnoracle: the dispute window has passed")
	}
	if tier != tierMinor && tier != tierMajor {
		panic("gnoracle: tier must be minor or major")
	}
	if len(evidence) > 1024 {
		panic("gnoracle: evidence is longer than 1024 bytes")
	}
	if !f.Spec.ValidValue(proposedValue) {
		panic("gnoracle: proposed value is not a valid option")
	}
	roundValue := st.RoundValue(feedID, roundID)
	if proposedValue == roundValue {
		panic("gnoracle: the proposed value equals the round value")
	}
	bond := disputeBond(f, t)
	if sent < bond {
		panic("gnoracle: bond is " + i(bond) + StakeUnit)
	}
	if sent > bond {
		st.CreditDeposit(disputer, sent-bond)
	}
	d := st.NewDispute(feedID, roundID, disputer, bond, proposedValue, tier, evidence, spec.HashText(evidence), roundValue, rd.Tier)
	st.RoundMarkDisputed(feedID, roundID, d.ID)
	inRow := f.DisputesInRow
	if t-f.LastDisputeAt >= param("disputeEscalationWindow") {
		inRow = 0
	}
	st.FeedSetDisputeCounters(feedID, f.OpenDisputes+1, inRow+1, t)
	summary := "feed " + u(feedID) + " round " + u(roundID) + ": value " + i(roundValue) + ", proposed " + i(proposedValue) + " (" + tier + ")"
	st.OpenBallot(d.ID, tier == tierMajor, summary)
	return d.ID
}

// disputeBond is max(minDisputeBond, disputeBondBps of the feed's active
// stake), doubled per recent dispute on the same feed (at most 16x).
func disputeBond(f *core.Feed, t int64) int64 {
	var stake int64
	for s := 0; s < core.MaxSlots; s++ {
		holder := f.SlotAt(s)
		if holder == "" {
			continue
		}
		if p := core.GetProvider(f.ID, holder); p != nil {
			stake += p.Stake
		}
	}
	bond := stake * param("disputeBondBps") / 10_000
	if minB := param("minDisputeBond"); bond < minB {
		bond = minB
	}
	if t-f.LastDisputeAt < param("disputeEscalationWindow") {
		n := f.DisputesInRow
		if n > 4 {
			n = 4
		}
		bond <<= uint(n)
	}
	return bond
}

// Appeal posts appealBondMultiple x the dispute bond inside the appeal window
// after a round-1 decision and sends the dispute to a second ballot round.
func (*implV1) Appeal(_ int, rlm realm, appellant address, disputeID uint64, sent int64) {
	st := core.Store(0, rlm)
	d := core.GetDispute(disputeID)
	if d == nil {
		panic("gnoracle: unknown dispute")
	}
	if d.Status != core.DisputeDecided {
		panic("gnoracle: only a decided dispute can be appealed")
	}
	t := now()
	if t >= d.DecidedAt+param("appealWindow") {
		panic("gnoracle: the appeal window has passed")
	}
	bond := d.Bond * param("appealBondMultiple")
	if sent < bond {
		panic("gnoracle: appeal bond is " + i(bond) + StakeUnit)
	}
	if sent > bond {
		st.CreditDeposit(appellant, sent-bond)
	}
	st.DisputeSetAppealed(disputeID, appellant, bond)
	st.OpenAppeal(disputeID)
}

// ResolveDispute drives a dispute through its states: read the round-1
// outcome, wait out the appeal window, read the round-2 outcome, apply.
func (*implV1) ResolveDispute(_ int, rlm realm, caller address, disputeID uint64) {
	st := core.Store(0, rlm)
	d := core.GetDispute(disputeID)
	if d == nil {
		panic("gnoracle: unknown dispute")
	}
	switch d.Status {
	case core.DisputeOpen:
		outcome, tier, coherent := st.FinishBallot(disputeID)
		switch outcome {
		case "PENDING":
			panic("gnoracle: the ballot is still running")
		case "ROLL":
			st.DisputeSetRolled(disputeID)
		default:
			st.DisputeSetDecided(disputeID, outcome, tier, coherent)
		}
	case core.DisputeDecided:
		if now() < d.DecidedAt+param("appealWindow") {
			panic("gnoracle: the appeal window is open until " + i(d.DecidedAt+param("appealWindow")))
		}
		apply(st, d, d.Outcome, d.TierDecided, d.CoherentW)
	case core.DisputeAppealed:
		outcome, tier, coherent := st.FinishBallot(disputeID)
		if outcome == "PENDING" {
			panic("gnoracle: the ballot is still running")
		}
		if outcome == "ROLL" {
			panic("gnoracle: a second round cannot roll")
		}
		apply(st, d, outcome, tier, coherent)
	default:
		panic("gnoracle: dispute is already resolved")
	}
}

// apply routes bonds and slashes for a final outcome (plan §7.3).
func apply(st *core.StateRef, d *core.DisputeRecord, outcome, tier string, coherent int64) {
	f := mustFeed(d.Feed)
	rd := core.GetRound(d.Feed, d.Round)
	if rd == nil {
		panic("gnoracle: round was pruned under an open dispute")
	}
	winnerBps := param("forfeitSplitWinnerBps")
	votersBps := param("forfeitSplitVotersBps")

	// the appeal bond: refunded in full when the appeal changed the outcome,
	// otherwise a share is consumed
	if d.AppealBond > 0 {
		if outcome != d.FirstOutcome {
			st.BondRelease(d.ID, d.Appellant, d.AppealBond)
		} else {
			consumed := d.AppealBond * param("appealConsumeBps") / 10_000
			half := consumed / 2
			st.BondToVoters(d.ID, half)
			st.BondToFees(d.ID, consumed-half)
			st.BondRelease(d.ID, d.Appellant, d.AppealBond-consumed)
		}
	}

	var slashed int64
	switch outcome {
	case "UPHOLD":
		toProviders := d.Bond * winnerBps / 10_000
		toVoters := d.Bond * votersBps / 10_000
		st.BondToPool(d.ID, d.Feed, toProviders)
		st.BondToVoters(d.ID, toVoters)
		st.BondToFees(d.ID, d.Bond-toProviders-toVoters)
		st.RoundRestartWindow(d.Feed, d.Round, d.PriorTier)
	case "OVERTURN":
		bps := param("minorSlashBps")
		if tier == tierMajor {
			bps = param("majorSlashBps")
		}
		for s := 0; s < core.MaxSlots; s++ {
			if rd.SubmittedMask&(1<<uint(s)) == 0 {
				continue
			}
			holder := core.SlotHolderAt(d.Feed, int64(s), d.Round)
			if holder == "" {
				continue
			}
			if agg.WithinTolerance(st.RoundValueAt(d.Feed, d.Round, s), d.ProposedValue, f.Spec.ToleranceBps) {
				continue
			}
			effTier, effBps := tier, bps
			if tier == tierMinor {
				if p := core.GetProvider(d.Feed, holder); p != nil {
					minors := p.MinorsEpoch
					if now()-p.EpochStart >= param("providerEpoch") {
						minors = 0 // the escalation counts within one provider epoch
					}
					if minors+1 >= param("minorsToMajor") {
						effTier, effBps = tierMajor, param("majorSlashBps")
					}
				}
			}
			// an ejection clears the slot from the next round on; the holders
			// of record of past rounds never change
			slashed += st.SlashProvider(d.Feed, holder, effBps, effTier, obligedFrom(f))
		}
		toDisputer := slashed * winnerBps / 10_000
		toVoters := slashed * votersBps / 10_000
		st.BondRelease(d.ID, d.Disputer, toDisputer)
		st.BondToVoters(d.ID, toVoters)
		st.BondToFees(d.ID, slashed-toDisputer-toVoters)
		st.BondRelease(d.ID, d.Disputer, d.Bond)
		st.RoundOverturn(d.Feed, d.Round, d.ProposedValue)
	case "VOID":
		consumed := d.Bond * param("voidConsumeBps") / 10_000
		half := consumed / 2
		st.BondToVoters(d.ID, half)
		st.BondToFees(d.ID, consumed-half)
		st.BondRelease(d.ID, d.Disputer, d.Bond-consumed)
		st.RoundVoid(d.Feed, d.Round)
	default:
		panic("gnoracle: unknown outcome " + outcome)
	}
	// tell the ballot house the outcome is applied even when nothing was
	// routed to voters, so the ballot becomes final and settlement may run
	st.FundVoters(d.ID, 0)
	f = mustFeed(d.Feed)
	st.FeedSetDisputeCounters(d.Feed, f.OpenDisputes-1, f.DisputesInRow, f.LastDisputeAt)
	st.DisputeSetResolved(d.ID, outcome, tier, coherent, slashed)
}

// ReopenOneOff gives a voided one-off feed a new resolve time (requester,
// once).
func (*implV1) ReopenOneOff(_ int, rlm realm, caller address, feedID uint64, resolveAt int64) {
	st := core.Store(0, rlm)
	f := mustFeed(feedID)
	if f.Spec.IsRecurring() {
		panic("gnoracle: only one-off feeds reopen")
	}
	if caller != f.Proposer {
		panic("gnoracle: only the requester may reopen")
	}
	if f.Reopened {
		panic("gnoracle: already reopened once")
	}
	rd := core.GetRound(feedID, 0)
	if rd == nil || (rd.Status != core.RoundVoid && rd.Status != core.RoundEmpty && rd.Status != core.RoundSkipped) {
		panic("gnoracle: only a voided or empty round reopens")
	}
	t := now()
	if resolveAt < t+spec.MinResolveLead || resolveAt > t+spec.MaxResolveLead {
		panic("gnoracle: resolveAt must be between 1 hour and 2 years ahead")
	}
	st.FeedResetForReopen(feedID, resolveAt)
}
