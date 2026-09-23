package impl

import (
	"strconv"
	"strings"

	"gno.land/r/clockwork/gnoracle/core"
	"gno.land/r/clockwork/gnoracle/dao"
	"gno.land/r/clockwork/gnoracle/token"
)

// rules of one proposal kind (plan §8.3).
type rules struct {
	quorumBps    int64
	thresholdBps int64
	voting       int64 // seconds
	timelock     int64 // seconds
}

const day = int64(24 * 3600)

func kindRules(kind string) (rules, bool) {
	switch kind {
	case "feed-accept", "feed-update", "feed-deprecate":
		return rules{1500, 5000, 3 * day, 0}, true
	case "provider-remove":
		return rules{2000, 5000, 3 * day, 0}, true
	case "param":
		return rules{2000, 5000, 5 * day, 2 * day}, true
	case "treasury":
		return rules{2000, 6600, 5 * day, 2 * day}, true
	case "mint":
		return rules{2500, 6600, 7 * day, 7 * day}, true
	case "upgrade-accept":
		return rules{2500, 6600, 7 * day, param("upgradeTimelock")}, true
	case "upgrade-rollback":
		return rules{1500, 5000, day, 0}, true
	case "freeze", "authority-transfer":
		return rules{3000, 7500, 14 * day, 7 * day}, true
	case "trusted-requester", "kourt-abandon":
		return rules{2000, 5000, 5 * day, 0}, true
	case "vesting":
		return rules{2500, 6600, 5 * day, 2 * day}, true
	case "text":
		return rules{1000, 5000, 5 * day, 0}, true
	}
	return rules{}, false
}

// Propose opens a proposal. The payload is validated up front so a malformed
// proposal never reaches a vote.
func (*implV1) Propose(_ int, rlm realm, proposer address, kind, payload, title string, sent int64) uint64 {
	st := dao.Store(0, rlm)
	r, ok := kindRules(kind)
	if !ok {
		panic("dao: unknown proposal kind " + strconv.Quote(kind))
	}
	if len(title) == 0 || len(title) > 128 {
		panic("dao: title must be 1 to 128 bytes")
	}
	if len(payload) > 2048 {
		panic("dao: payload is longer than 2048 bytes")
	}
	validatePayload(kind, payload)
	if countActive() >= param("maxActiveProposals") {
		panic("dao: too many active proposals")
	}
	// the proposer bar: a share of staked supply, or a deposit
	deposit := int64(0)
	m := dao.GetMember(proposer)
	staked := int64(0)
	if m != nil {
		staked = m.Staked
	}
	if staked == 0 || staked*10_000 < dao.TotalStaked()*param("proposeBps") {
		need := param("proposalDeposit")
		if sent < need {
			panic("dao: hold at least " + i(param("proposeBps")) + " bps of staked PYTH or attach a deposit of " + i(need) + " ugnot")
		}
		deposit = sent
	}
	t := now()
	p := st.NewProposal(kind, payload, title, proposer, dao.Epoch(), t+r.voting, r.timelock, t+r.voting+r.timelock+param("executionWindow"), r.quorumBps, r.thresholdBps, deposit)
	return p.ID
}

// countActive counts live proposals among the newest ones.
func countActive() int64 {
	var n int64
	t := now()
	dao.IterateProposals(0, int(param("maxActiveProposals"))*2, func(p *dao.Proposal) bool {
		if p.Status == dao.ProposalActive && p.VotingEnds > t {
			n++
		}
		return false
	})
	return n
}

// Vote casts a choice with the member's sealed weight.
func (*implV1) Vote(_ int, rlm realm, voter address, proposalID uint64, choice string) {
	st := dao.Store(0, rlm)
	p := dao.GetProposal(proposalID)
	if p == nil {
		panic("dao: unknown proposal")
	}
	if p.Status != dao.ProposalActive || now() >= p.VotingEnds {
		panic("dao: voting is closed")
	}
	if choice != dao.ChoiceYes && choice != dao.ChoiceNo && choice != dao.ChoiceAbstain {
		panic("dao: choice must be YES, NO or ABSTAIN")
	}
	w := weightAt(voter, p.SealedEpoch)
	if w <= 0 {
		panic("dao: no voting weight at the proposal's epoch")
	}
	st.ProposalVote(proposalID, voter, choice, w)
}

// weightAt is min(sealed snapshot, live stake).
func weightAt(addr address, epoch uint32) int64 {
	w := dao.PowerAt(addr, epoch)
	m := dao.GetMember(addr)
	if m == nil {
		return 0
	}
	if m.Staked < w {
		w = m.Staked
	}
	return w
}

// Execute tallies a proposal after its voting period and applies it after
// its timelock.
func (*implV1) Execute(_ int, rlm realm, caller address, proposalID uint64) {
	st := dao.Store(0, rlm)
	p := dao.GetProposal(proposalID)
	if p == nil {
		panic("dao: unknown proposal")
	}
	t := now()
	if p.Status != dao.ProposalActive && p.Status != dao.ProposalPassed {
		panic("dao: proposal is " + p.Status)
	}
	if t < p.VotingEnds {
		panic("dao: voting is still open")
	}
	if p.Status == dao.ProposalActive {
		turnout := p.Yes + p.No + p.Abstain
		total := dao.TotalPowerAt(p.SealedEpoch)
		quorate := total > 0 && turnout*10_000 >= total*p.QuorumBps
		sides := p.Yes + p.No
		passed := quorate && p.Yes > 0 && sides > 0 && p.Yes*10_000 > sides*p.ThresholdBps // strictly more than the bar (plan §8.3)
		if !quorate {
			st.ProposalDepositForfeit(proposalID)
			st.ProposalSetStatus(proposalID, dao.ProposalRejected, "no quorum")
			return
		}
		st.ProposalDepositRefund(proposalID)
		if !passed {
			st.ProposalSetStatus(proposalID, dao.ProposalRejected, "not carried")
			return
		}
		st.ProposalSetStatus(proposalID, dao.ProposalPassed, "")
	}
	if t < p.Executable {
		return // tallied and recorded; execution waits for the timelock
	}
	if t > p.Expires {
		st.ProposalSetStatus(proposalID, dao.ProposalExpired, "not executed in time")
		return
	}
	apply(st, p)
	st.ProposalSetStatus(proposalID, dao.ProposalExecuted, "")
}

// Cancel withdraws the proposer's own proposal before voting ends.
func (*implV1) Cancel(_ int, rlm realm, caller address, proposalID uint64) {
	st := dao.Store(0, rlm)
	p := dao.GetProposal(proposalID)
	if p == nil || p.Proposer != caller {
		panic("dao: not your proposal")
	}
	if p.Status != dao.ProposalActive || now() >= p.VotingEnds {
		panic("dao: voting has ended")
	}
	st.ProposalDepositRefund(proposalID)
	st.ProposalSetStatus(proposalID, dao.ProposalCanceled, "withdrawn by the proposer")
}

// ---- payloads

// fields splits a payload on the first n-1 spaces; the last field takes the rest.
func fields(payload string, n int) []string {
	out := make([]string, 0, n)
	rest := strings.TrimSpace(payload)
	for len(out) < n-1 {
		k := strings.IndexByte(rest, ' ')
		if k < 0 {
			break
		}
		out = append(out, rest[:k])
		rest = strings.TrimSpace(rest[k+1:])
	}
	out = append(out, rest)
	return out
}

func parseUint(s, what string) uint64 {
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		panic("dao: " + what + " must be an unsigned integer")
	}
	return v
}

func parseInt(s, what string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("dao: " + what + " must be an integer")
	}
	return v
}

func parseAddr(s, what string) address {
	a := address(s)
	if !a.IsValid() {
		panic("dao: " + what + " must be a valid address")
	}
	return a
}

func parseRealm(s string) string {
	if s != "core" && s != "dao" && s != "kourt" {
		panic("dao: realm must be core, dao or kourt")
	}
	return s
}

// validatePayload panics on a malformed payload for its kind.
func validatePayload(kind, payload string) {
	switch kind {
	case "feed-accept":
		f := fields(payload, 1)
		parseUint(f[0], "feed id")
	case "feed-update":
		f := fields(payload, 2)
		parseUint(f[0], "feed id")
		if len(f) < 2 || !strings.HasPrefix(f[1], "{") {
			panic("dao: feed-update needs a feed id and a JSON object")
		}
	case "feed-deprecate":
		f := fields(payload, 2)
		parseUint(f[0], "feed id")
	case "provider-remove":
		f := fields(payload, 3)
		parseUint(f[0], "feed id")
		if len(f) < 2 {
			panic("dao: provider-remove needs a feed id and an address")
		}
		parseAddr(f[1], "provider")
	case "param":
		target, name, _, _ := parseParam(payload)
		if target == "core" && !strings.HasPrefix(name, "") {
			panic("dao: bad param")
		}
	case "treasury":
		f := fields(payload, 4)
		if len(f) < 3 || (f[0] != "ugnot" && f[0] != "pyth") {
			panic("dao: treasury needs <ugnot|pyth> <amount> <address> [memo]")
		}
		if parseInt(f[1], "amount") <= 0 {
			panic("dao: amount must be positive")
		}
		parseAddr(f[2], "recipient")
	case "mint":
		f := fields(payload, 2)
		if len(f) < 2 || parseInt(f[0], "amount") <= 0 {
			panic("dao: mint needs <amount> <address>")
		}
		parseAddr(f[1], "recipient")
	case "upgrade-accept":
		f := fields(payload, 2)
		parseRealm(f[0])
		if len(f) < 2 || !strings.HasPrefix(f[1], "gno.land/r/") {
			panic("dao: upgrade-accept needs <core|dao> <realm path>")
		}
	case "upgrade-rollback", "freeze":
		parseRealm(fields(payload, 1)[0])
	case "authority-transfer":
		f := fields(payload, 2)
		parseRealm(f[0])
		if (f[0] == "core" || f[0] == "kourt") && (len(f) < 2 || f[1] == "") {
			panic("dao: authority-transfer " + f[0] + " needs a comma-separated list of realm paths")
		}
	case "kourt-abandon":
		f := fields(payload, 2)
		parseUint(f[0], "dispute id")
	case "trusted-requester":
		f := fields(payload, 2)
		if len(f) < 2 || !strings.HasPrefix(f[0], "gno.land/r/") {
			panic("dao: trusted-requester needs <realm path> <cap>")
		}
		if parseInt(f[1], "cap") < 0 {
			panic("dao: cap must not be negative")
		}
	case "vesting":
		f := fields(payload, 3)
		parseAddr(f[0], "member")
		if parseInt(f[1], "until") < 0 || parseInt(f[2], "floor") < 0 {
			panic("dao: vesting terms must not be negative")
		}
	case "text":
	}
}

// parseParam reads "core.name=value", "dao.name=value" or "...=str:value".
func parseParam(payload string) (target, name string, value int64, str string) {
	s := strings.TrimSpace(payload)
	dot := strings.IndexByte(s, '.')
	eq := strings.IndexByte(s, '=')
	if dot <= 0 || eq <= dot+1 || eq == len(s)-1 {
		panic("dao: param needs core.<name>=<value> or dao.<name>=<value>")
	}
	target = s[:dot]
	if target != "core" && target != "dao" {
		panic("dao: param target must be core or dao")
	}
	name = s[dot+1 : eq]
	raw := s[eq+1:]
	if strings.HasPrefix(raw, "str:") {
		return target, name, 0, raw[4:]
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		panic("dao: param value must be an integer or str:<text>")
	}
	return target, name, v, ""
}

// apply performs a passed proposal's effect through the permanent realm.
func apply(st *dao.StateRef, p *dao.Proposal) {
	switch p.Kind {
	case "feed-accept":
		st.CoreActivateFeed(parseUint(fields(p.Payload, 1)[0], "feed id"))
	case "feed-update":
		f := fields(p.Payload, 2)
		st.CoreUpdateFeed(parseUint(f[0], "feed id"), f[1])
	case "feed-deprecate":
		f := fields(p.Payload, 2)
		reason := ""
		if len(f) > 1 {
			reason = f[1]
		}
		st.CoreDeprecateFeed(parseUint(f[0], "feed id"), reason)
	case "provider-remove":
		f := fields(p.Payload, 3)
		st.CoreForceUnbond(parseUint(f[0], "feed id"), parseAddr(f[1], "provider"))
	case "param":
		target, name, v, str := parseParam(p.Payload)
		isStr := strings.Contains(p.Payload, "=str:")
		switch {
		case target == "core" && isStr:
			st.CoreSetParamStr(name, str)
		case target == "core":
			st.CoreSetParam(name, v)
		case isStr:
			st.SetOwnParamStr(name, str)
		default:
			st.SetOwnParam(name, v)
		}
	case "treasury":
		f := fields(p.Payload, 4)
		amount := parseInt(f[1], "amount")
		to := parseAddr(f[2], "recipient")
		if f[0] == "ugnot" {
			st.TreasurySendUgnot(to, amount)
		} else {
			st.TreasurySendPyth(to, amount)
		}
	case "mint":
		f := fields(p.Payload, 2)
		amount := parseInt(f[0], "amount")
		to := parseAddr(f[1], "recipient")
		year := now() / (365 * day)
		allowed := token.TotalSupply() * param("maxMintPerYearBps") / 10_000
		if dao.MintedInYear(year)+amount > allowed {
			panic("dao: mint exceeds " + i(param("maxMintPerYearBps")) + " bps of supply for this year")
		}
		st.Mint(to, amount, year)
	case "upgrade-accept":
		f := fields(p.Payload, 2)
		switch f[0] {
		case "core":
			st.CoreAccept(f[1])
		case "kourt":
			st.KourtAccept(f[1])
		default:
			st.ExecOwn("accept", f[1])
		}
	case "upgrade-rollback":
		switch fields(p.Payload, 1)[0] {
		case "core":
			st.CoreRollback()
		case "kourt":
			st.KourtRollback()
		default:
			st.ExecOwn("rollback", "")
		}
	case "freeze":
		switch fields(p.Payload, 1)[0] {
		case "core":
			st.CoreFreeze()
		case "kourt":
			st.KourtFreeze()
		default:
			st.ExecOwn("freeze", "")
		}
	case "authority-transfer":
		f := fields(p.Payload, 2)
		switch f[0] {
		case "core":
			st.CoreTransferAuthority(f[1])
		case "kourt":
			st.KourtTransferAuthority(f[1])
		default:
			st.ExecOwn("authority", "")
		}
	case "kourt-abandon":
		f := fields(p.Payload, 2)
		st.KourtAbandon(parseUint(f[0], "dispute id"), f[1])
	case "trusted-requester":
		f := fields(p.Payload, 2)
		st.CoreSetTrustedRequester(f[0], parseInt(f[1], "cap"))
	case "vesting":
		f := fields(p.Payload, 3)
		st.MemberSetVesting(parseAddr(f[0], "member"), parseInt(f[1], "until"), parseInt(f[2], "floor"))
	case "text":
		// nothing to apply
	default:
		panic("dao: unknown kind")
	}
	// keep the compiler honest about the core import in builds without effects
	_ = core.SelfPath
}
