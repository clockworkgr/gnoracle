package impl

import (
	"strconv"
	"strings"

	"gno.land/r/clockwork/gnoracle/dao"
)

// Render serves the DAO pages.
func (*implV1) Render(_ int, rlm realm, path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case parts[0] == "json":
		return renderJSON(parts[1:])
	case path == "" || parts[0] == "proposals":
		return renderHome()
	case parts[0] == "proposal" && len(parts) >= 2:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "unknown proposal"
		}
		return renderProposal(id)
	case parts[0] == "member" && len(parts) >= 2:
		return renderMember(address(parts[1]))
	case parts[0] == "members":
		return renderMembers()
	case parts[0] == "health":
		return "# Health\n\n```\n" + dao.Health() + "\n```\n"
	case parts[0] == "params":
		return "# Parameters\n\n```\n" + dao.ParamsJSON() + "\n```\n"
	}
	return "not found"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Gnoracle DAO\n\nStaked PYTH: **" + i(dao.TotalStaked()) + "** across " + strconv.Itoa(dao.MemberCount()) + " members. Serving `" + dao.LivePath() + "`.\n\n")
	b.WriteString("Pages: [members](:members) · [health](:health) · [parameters](:params) · [releases](:releases)\n\n")
	b.WriteString("## Proposals\n\n| id | kind | title | status | yes | no | abstain | voting ends |\n|---|---|---|---|---|---|---|---|\n")
	dao.IterateProposals(0, 25, func(p *dao.Proposal) bool {
		b.WriteString("| [" + u(p.ID) + "](:proposal/" + u(p.ID) + ") | " + p.Kind + " | " + esc(p.Title) + " | " + p.Status + " | " + i(p.Yes) + " | " + i(p.No) + " | " + i(p.Abstain) + " | " + i(p.VotingEnds) + " |\n")
		return false
	})
	return b.String()
}

func renderProposal(id uint64) string {
	p := dao.GetProposal(id)
	if p == nil {
		return "unknown proposal"
	}
	var b strings.Builder
	b.WriteString("# Proposal " + u(id) + ": " + esc(p.Title) + "\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| kind | " + p.Kind + " |\n| status | " + p.Status + " " + esc(p.Reason) + " |\n| proposer | " + string(p.Proposer) + " |\n")
	b.WriteString("| sealed epoch | " + strconv.FormatUint(uint64(p.SealedEpoch), 10) + " (obligated weight " + i(dao.TotalPowerAt(p.SealedEpoch)) + ") |\n")
	b.WriteString("| voting ends | " + i(p.VotingEnds) + " |\n| executable | " + i(p.Executable) + " |\n| expires | " + i(p.Expires) + " |\n")
	b.WriteString("| quorum / threshold | " + i(p.QuorumBps) + " / " + i(p.ThresholdBps) + " bps |\n")
	b.WriteString("| yes / no / abstain | " + i(p.Yes) + " / " + i(p.No) + " / " + i(p.Abstain) + " (" + i(p.Voters) + " voters) |\n")
	b.WriteString("| deposit | " + i(p.Deposit) + " |\n\n")
	b.WriteString("Payload:\n\n```\n" + strings.ReplaceAll(p.Payload, "`", "'") + "\n```\n")
	return b.String()
}

func renderMember(addr address) string {
	m := dao.GetMember(addr)
	if m == nil {
		return "not a member"
	}
	var b strings.Builder
	b.WriteString("# Member " + string(addr) + "\n\n| | |\n|---|---|\n")
	b.WriteString("| staked | " + i(m.Staked) + " |\n| unbonding | " + i(m.UnbondAmount) + " (ready " + i(m.UnbondReadyAt) + ") |\n")
	b.WriteString("| voting weight now | " + i(dao.PowerAt(addr, dao.Epoch())) + " |\n")
	b.WriteString("| fees claimable | " + i(dao.FeesOwed(addr)) + " ugnot |\n")
	b.WriteString("| dispute rewards | " + i(m.PendingPyth) + " PYTH, " + i(m.PendingUgnot) + " ugnot |\n")
	b.WriteString("| ballots settled | " + u(m.Cursor) + " of " + u(dao.BallotCount()) + " |\n")
	b.WriteString("| penalised total | " + i(m.TotalPenalised) + " |\n| rewarded total | " + i(m.TotalRewarded) + " |\n")
	if m.VestedUntil > 0 {
		b.WriteString("| vesting | " + i(m.VestFloor) + " locked until " + i(m.VestedUntil) + " |\n")
	}
	return b.String()
}

func renderMembers() string {
	var b strings.Builder
	b.WriteString("# Members\n\n| address | staked | unbonding | settled |\n|---|---|---|---|\n")
	dao.IterateMembers(0, 50, func(m *dao.Member) bool {
		b.WriteString("| [" + string(m.Addr) + "](:member/" + string(m.Addr) + ") | " + i(m.Staked) + " | " + i(m.UnbondAmount) + " | " + u(m.Cursor) + " |\n")
		return false
	})
	return b.String()
}

func esc(s string) string {
	// the backslash first, so the escapes added below stay escapes
	r := strings.NewReplacer("\\", "\\\\", "|", "\\|", "<", "&lt;", ">", "&gt;", "[", "\\[", "]", "\\]", "\r", " ", "\n", " ")
	return r.Replace(s)
}
