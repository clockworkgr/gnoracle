package impl

import (
	"chain/runtime"
	"strconv"

	"gno.land/p/clockwork/gnoracle/jsonw/v0"
	"gno.land/r/clockwork/gnoracle/dao"
)

// renderJSON serves the DAO's machine views under `:json/...` (read by the
// bot for reminders and by the CLI for commit and reveal).
//
// Paths:
//
//	json/now
//	json/member/<addr>
//	json/members[/<offset>[/<count>]]
//	json/ballot/<seq>
//	json/ballot/dispute/<disputeID>
//	json/ballots[/<from>[/<count>]]
//	json/commit/<seq>/<addr>
//	json/reveal/<seq>/<addr>
//	json/proposal/<id>
//	json/proposals[/<offset>[/<count>]]
//	json/params
//	json/health
func renderJSON(parts []string) string {
	if len(parts) == 0 {
		return jsonw.Error("path: json/now | member/<addr> | members | ballot/<seq> | ballot/dispute/<id> | ballots | commit/<seq>/<addr> | reveal/<seq>/<addr> | proposal/<id> | proposals | params | health")
	}
	switch parts[0] {
	case "now":
		return jsonNow().String()
	case "member":
		if len(parts) < 2 {
			return jsonw.Error("address missing")
		}
		m := dao.GetMember(address(parts[1]))
		if m == nil {
			return jsonNow().Str("addr", parts[1]).Bool("exists", false).String()
		}
		return jsonMember(m).String()
	case "members":
		offset, count := pageArgs(parts[1:], 0, 25, 100)
		a := jsonw.NewArray()
		dao.IterateMembers(int(offset), int(count), func(m *dao.Member) bool {
			a.Raw(jsonMember(m).String())
			return false
		})
		return jsonNow().Raw("members", a.String()).String()
	case "ballot":
		if len(parts) < 2 {
			return jsonw.Error("ballot seq missing")
		}
		var seq uint64
		if parts[1] == "dispute" {
			if len(parts) < 3 {
				return jsonw.Error("dispute id missing")
			}
			id, err := strconv.ParseUint(parts[2], 10, 64)
			if err != nil {
				return jsonw.Error("bad dispute id")
			}
			seq = dao.BallotOf(id)
			if seq == 0 {
				return jsonNow().Uint("dispute", id).Bool("exists", false).String()
			}
		} else {
			var err error
			if seq, err = strconv.ParseUint(parts[1], 10, 64); err != nil {
				return jsonw.Error("bad ballot seq")
			}
		}
		b := dao.GetBallot(seq)
		if b == nil {
			return jsonw.Error("unknown ballot")
		}
		return jsonBallot(seq, b).String()
	case "ballots":
		total := dao.BallotCount()
		from, count := pageArgs(parts[1:], 0, 25, 100)
		if from == 0 {
			// default: the most recent page
			from = int64(total) - count + 1
			if from < 1 {
				from = 1
			}
		}
		a := jsonw.NewArray()
		for seq := uint64(from); seq <= total && int64(a.Len()) < count; seq++ {
			if b := dao.GetBallot(seq); b != nil {
				a.Raw(jsonBallot(seq, b).String())
			}
		}
		return jsonNow().Uint("total", total).Raw("ballots", a.String()).String()
	case "commit", "reveal":
		if len(parts) < 3 {
			return jsonw.Error("seq and address required")
		}
		seq, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return jsonw.Error("bad ballot seq")
		}
		o := jsonNow().Uint("seq", seq).Str("voter", parts[2])
		if parts[0] == "commit" {
			c := dao.CommitOf(seq, address(parts[2]))
			return o.Bool("committed", c != "").Str("commitment", c).String()
		}
		r := dao.RevealOf(seq, address(parts[2]))
		return o.Bool("revealed", r != "").Str("choice", r).String()
	case "proposal":
		if len(parts) < 2 {
			return jsonw.Error("proposal id missing")
		}
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return jsonw.Error("bad proposal id")
		}
		p := dao.GetProposal(id)
		if p == nil {
			return jsonw.Error("unknown proposal")
		}
		return jsonProposal(p).String()
	case "proposals":
		offset, count := pageArgs(parts[1:], 0, 25, 100)
		a := jsonw.NewArray()
		dao.IterateProposals(int(offset), int(count), func(p *dao.Proposal) bool {
			a.Raw(jsonProposal(p).String())
			return false
		})
		return jsonNow().Uint("total", dao.ProposalCount()).Raw("proposals", a.String()).String()
	case "params":
		return dao.ParamsJSON()
	case "health":
		return jsonNow().Str("health", dao.Health()).String()
	}
	return jsonw.Error("unknown json path")
}

func pageArgs(parts []string, defOffset, defCount, maxCount int64) (offset, count int64) {
	offset, count = defOffset, defCount
	if len(parts) >= 1 {
		if n, err := strconv.ParseInt(parts[0], 10, 64); err == nil && n >= 0 {
			offset = n
		}
	}
	if len(parts) >= 2 {
		if n, err := strconv.ParseInt(parts[1], 10, 64); err == nil && n > 0 {
			count = n
		}
	}
	if count > maxCount {
		count = maxCount
	}
	return
}

func jsonNow() *jsonw.Object {
	return jsonw.New().Int("now", now()).Int("height", runtime.ChainHeight()).Int("epoch", int64(dao.Epoch())).
		Int("epochBlocks", param("epochBlocks")).Str("live", dao.LivePath()).Int("totalStaked", dao.TotalStaked()).
		Int("memberCount", int64(dao.MemberCount())).Uint("proposalCount", dao.ProposalCount()).Uint("ballotCount", dao.BallotCount())
}

func jsonMember(m *dao.Member) *jsonw.Object {
	return jsonNow().Str("addr", string(m.Addr)).Bool("exists", true).Int("staked", m.Staked).Int("power", dao.PowerAt(m.Addr, dao.Epoch())).
		Int("unbondAmount", m.UnbondAmount).Int("unbondReadyAt", m.UnbondReadyAt).Uint("cursor", m.Cursor).
		Int("pendingUgnot", m.PendingUgnot).Int("pendingPyth", m.PendingPyth).Int("feesOwed", dao.FeesOwed(m.Addr)).
		Int("vestedUntil", m.VestedUntil).Int("vestFloor", m.VestFloor).Int("penaltyWindowAt", m.PenaltyWindowAt).
		Int("penaltyInWindow", m.PenaltyInWindow).Int("totalPenalised", m.TotalPenalised).Int("totalRewarded", m.TotalRewarded).Int("joinedAt", m.JoinedAt)
}

func jsonBallot(seq uint64, b *dao.Ballot) *jsonw.Object {
	return jsonNow().Uint("seq", seq).Uint("dispute", b.Dispute).Int("round", b.Round).Bool("majorRequested", b.MajorRequested).
		Str("summary", b.Summary).Int("sealedEpoch", int64(b.SealedEpoch)).Int("obligated", b.Obligated).Str("phase", b.Phase).
		Int("commitEnds", b.CommitEnds).Int("revealEnds", b.RevealEnds).Int("uphold", b.Uphold).Int("overturn", b.Overturn).
		Int("overturnMinor", b.OverturnMinor).Int("void", b.Void).Int("abstain", b.Abstain).Int("revealed", b.Revealed).
		Str("outcome", b.Outcome).Str("tier", b.Tier).Int("coherentWeight", b.CoherentWeight).Int("expectedPool", b.ExpectedPool).
		Int("bondShareUgnot", b.BondShareUgnot).Int("clippedAway", b.ClippedAway).Int("resolvedAt", b.ResolvedAt).Uint("prevSeq", b.PrevSeq)
}

func jsonProposal(p *dao.Proposal) *jsonw.Object {
	return jsonNow().Uint("id", p.ID).Str("kind", p.Kind).Str("payload", p.Payload).Str("title", p.Title).Str("proposer", string(p.Proposer)).
		Int("createdAt", p.CreatedAt).Int("sealedEpoch", int64(p.SealedEpoch)).Int("votingEnds", p.VotingEnds).Int("timelock", p.Timelock).
		Int("executable", p.Executable).Int("expires", p.Expires).Int("quorumBps", p.QuorumBps).Int("thresholdBps", p.ThresholdBps).
		Str("status", p.Status).Int("yes", p.Yes).Int("no", p.No).Int("abstain", p.Abstain).Int("voters", p.Voters).Int("deposit", p.Deposit).Str("reason", p.Reason)
}
