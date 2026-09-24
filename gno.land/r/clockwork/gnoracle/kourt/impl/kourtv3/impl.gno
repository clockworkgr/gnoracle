// Package kourtv3 is the Kourt mirror release bound to the deployed Kourt v3
// realm, gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3. It
// files every resolved Gnoracle dispute as a claim in the DAO's court there,
// stakes the DAO's side, posts the bonded answer, settles it and records
// Kourt's verdict on the permanent realm (plan §7.4).
//
// Kourt v3's clocks, which this release models rather than assumes:
//
//   - an answer needs three epochs (3 x 720 blocks) of stake history, and the
//     trailing average only advances when a stake is observed, so the mirror
//     seals its own history with a one-unit top-up two epochs after staking;
//   - the answerability floor is 0.10% of the court's supply (min 1 CC); the
//     mirror stakes twice the floor it sees and lifts the average if the
//     court grew in between;
//   - qualified answerers get a 24 h priority window once the court has
//     three of them; the mirror waits it out;
//   - an undisputed answer settles 72 h after it was posted; a disputed one
//     is decided by a one-week coin vote, then held in escrow (at least one
//     more week, reopenable by a new dispute) before Finalize;
//   - a new claim has a polish window (the court's stake-open delay) before
//     anyone may stake; the mirror waits it out;
//   - a claim nobody answers for twelve weeks dies; the mirror closes it on
//     Kourt, takes its stake back and records it as abandoned;
//   - a holder may answer before the mirror stakes, which freezes staking;
//     the mirror then follows the claim to its verdict without a position.
//
// Every wait is measured on Kourt's own clock (ClaimTimeline), so the mirror
// also follows a test clock armed on a development chain.
package kourtv3

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/clockwork/gnoracle/jsonw/v0"
	"gno.land/r/clockwork/gnoracle/core"
	"gno.land/r/clockwork/gnoracle/kourt"
	kv "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"
)

// kourtPath is the Kourt realm this release is compiled against.
const kourtPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"

// binding names the Kourt realm and court this release files into; records
// remember it so a release bound elsewhere never cranks another court's
// claims.
const binding = kourtPath + "#" + kourt.CourtSlug

const (
	courtName = "Gnoracle disputes"
	sideYES   = 0
	oneCC     = int64(1_000_000)

	// Kourt v3's own constants (court.gno, answer.gno, clock.gno).
	epochBlocks        = int64(720)
	answerWindow       = 3 * epochBlocks // blocks of stake history an answer needs
	settleSecs         = int64(72 * 3600)
	priorityWindowSecs = int64(24 * 3600)
	deadClaimSecs      = int64(12 * 7 * 86400) // an unanswered claim dies after this
	blockSecs          = int64(5)              // Kourt's blocks-to-seconds ratio
	ordAnswerXFloorBps = int64(10)

	// stakeMultiple is how many answerability floors the mirror stakes, so
	// that supply growth between staking and answering cannot undercut it.
	stakeMultiple = int64(2)
)

type implKourtV3 struct{}

var instance = &implKourtV3{}

// Instance returns the implementation object.
func Instance() kourt.Mirror { return instance }

func init(cur realm) {
	kourt.RegisterImpl(cross(cur), instance)
}

func now() int64 { return time.Now().Unix() }

// ---- court and float

// EnsureCourt founds the DAO's court when it is missing. Kourt only takes a
// court-creation burn from a direct user call, so while the burn is above
// zero an account has to found the court instead (any account; the mirror
// needs no right on the court).
func (*implKourtV3) EnsureCourt(_ int, rlm realm) string {
	kourt.Store(0, rlm)
	return ensureCourt(0, rlm)
}

func ensureCourt(_ int, rlm realm) string {
	if kv.Exists(kourt.CourtSlug) {
		return kourt.CourtSlug
	}
	if burn := kv.CourtCreationBurn(); burn > 0 {
		panic("kourt: Kourt charges " + strconv.FormatInt(burn, 10) + "ugnot to found a court and takes it only from a direct user call; found court '" +
			kourt.CourtSlug + "' with " + kourtPath + ".StartCourt from an account (the mirror needs no right on it), then crank again")
	}
	return kv.StartCourt(cross(rlm), kourt.CourtSlug, courtName)
}

// Float is the court coin held by the mirror realm, staked or not.
func (*implKourtV3) Float(_ int, rlm realm) int64 {
	kourt.Store(0, rlm)
	return float()
}

func float() int64 {
	if !kv.Exists(kourt.CourtSlug) {
		return 0
	}
	return kv.CoinBalanceOf(kourt.CourtSlug, kourt.Address())
}

func spendable() int64 {
	if !kv.Exists(kourt.CourtSlug) {
		return 0
	}
	return kv.SpendableOf(kourt.CourtSlug, kourt.Address())
}

// Redeem converts court coin back to GNOT and forwards the proceeds to the
// treasury. Only a two-way court redeems; whoever founded the court under the
// slug chose, and the page and JSON view say which it is.
func (*implKourtV3) Redeem(_ int, rlm realm, amount int64) int64 {
	st := kourt.Store(0, rlm)
	if kv.Exists(kourt.CourtSlug) && kv.CourtOneWay(kourt.CourtSlug) {
		panic("kourt: court '" + kourt.CourtSlug + "' on " + kourtPath + " is one-way: its coin never returns GNOT, so the float cannot be redeemed")
	}
	payout := kv.Redeem(cross(rlm), kourt.CourtSlug, amount)
	if payout > 0 {
		st.SendToTreasury(payout)
	}
	return payout
}

// ---- Kourt's clock

// clock is a claim's timeline as Kourt reports it: instants and heights on
// Kourt's own clock, which a development chain may fabricate.
type clock struct {
	openedT, openedH       int64
	answeredT, answeredH   int64
	reopenT, reopenH       int64 // escrow end of a provisional verdict
	voteCloseT, voteCloseH int64 // close of the open dispute vote (time 0: gated on height)
	nowT, nowH             int64
}

func claimClock(claimID uint64) clock {
	var c clock
	for _, part := range strings.Split(kv.ClaimTimeline(kourt.CourtSlug, claimID), ";") {
		f := strings.Split(part, ":")
		if len(f) != 3 {
			continue
		}
		t, err1 := strconv.ParseInt(f[1], 10, 64)
		h, err2 := strconv.ParseInt(f[2], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		switch f[0] {
		case "opened":
			c.openedT, c.openedH = t, h
		case "answered":
			c.answeredT, c.answeredH = t, h
		case "reopen":
			c.reopenT, c.reopenH = t, h
		case "voteclose":
			c.voteCloseT, c.voteCloseH = t, h
		case "now":
			c.nowT, c.nowH = t, h
		}
	}
	return c
}

// ---- crank

// Crank advances a dispute's mirror by one step.
func (*implKourtV3) Crank(_ int, rlm realm, disputeID uint64) string {
	st := kourt.Store(0, rlm)
	d := core.GetDispute(disputeID)
	if d == nil {
		panic("kourt: unknown dispute")
	}
	if d.Status != core.DisputeResolved {
		panic("kourt: the dispute is not resolved yet")
	}
	ensureCourt(0, rlm)
	rec := kourt.GetRecord(disputeID)
	if rec == nil {
		rec = st.NewRecord(disputeID, binding, title(d))
	}
	if rec.Binding != binding {
		panic("kourt: record " + u(disputeID) + " was filed under " + rec.Binding + "; this release binds " + binding + " (the authority may Abandon it)")
	}
	slug := kourt.CourtSlug
	t := now()
	switch rec.State {
	case kourt.StatePending:
		id := kv.OpenClaimP(cross(rlm), slug, rec.Title, body(d))
		st.Set(disputeID, kourt.StateFiled, id, t, 0, "", 0)
	case kourt.StateFiled:
		if kv.ClaimClosed(slug, rec.ClaimID) {
			return abandon(st, rlm, rec, t)
		}
		c := claimClock(rec.ClaimID)
		if kv.HasAnswer(slug, rec.ClaimID) {
			// a holder answered before the mirror staked: staking is frozen,
			// so the mirror follows the claim to its verdict without a position
			st.Set(disputeID, kourt.StateAnswered, 0, c.answeredT, 0, "", 0)
			return kourt.StateAnswered
		}
		if c.nowT >= c.openedT+deadClaimSecs {
			return closeDead(st, rlm, rec, t)
		}
		if c.nowT < c.openedT+kv.CourtStakeOpenDelay(slug)*blockSecs {
			return rec.State // the polish window: staking has not started
		}
		amount := stakeSize()
		kv.Stake(cross(rlm), slug, rec.ClaimID, sideYES, amount)
		st.Set(disputeID, kourt.StateStaked, 0, t, 0, "", amount)
		st.SetNote("record", u(disputeID), "stakedH", strconv.FormatInt(claimClock(rec.ClaimID).nowH, 10))
	case kourt.StateStaked:
		// anyone may answer once the claim is answerable; a foreign answer
		// is recorded rather than fought, and finish judges the verdict
		if kv.HasAnswer(slug, rec.ClaimID) {
			st.Set(disputeID, kourt.StateAnswered, 0, claimClock(rec.ClaimID).answeredT, 0, "", 0)
			return kourt.StateAnswered
		}
		if kv.ClaimClosed(slug, rec.ClaimID) {
			return abandon(st, rlm, rec, t)
		}
		if c := claimClock(rec.ClaimID); c.nowT >= c.openedT+deadClaimSecs {
			return closeDead(st, rlm, rec, t)
		}
		if !answerable(st, rlm, rec) {
			return kourt.StateStaked
		}
		kv.PostAnswer(cross(rlm), slug, rec.ClaimID, sideYES)
		st.Set(disputeID, kourt.StateAnswered, 0, t, 0, "", 0)
	case kourt.StateAnswered:
		if kv.Settled(slug, rec.ClaimID) {
			return finish(st, rlm, rec, t)
		}
		if kv.DisputeOpen(slug, rec.ClaimID) || kv.Provisional(slug, rec.ClaimID) >= 0 {
			st.Set(disputeID, kourt.StateContested, 0, t, 0, "", 0)
			return kourt.StateContested
		}
		c := claimClock(rec.ClaimID)
		if c.nowT < c.answeredT+settleSecs {
			return rec.State
		}
		kv.SettleUndisputed(cross(rlm), slug, rec.ClaimID)
		return finish(st, rlm, rec, t)
	case kourt.StateContested:
		if kv.Settled(slug, rec.ClaimID) {
			return finish(st, rlm, rec, t)
		}
		c := claimClock(rec.ClaimID)
		if kv.DisputeOpen(slug, rec.ClaimID) {
			if !voteClosed(c, rec.ClaimID) {
				return rec.State // the vote is open
			}
			kv.ResolveDispute(cross(rlm), slug, rec.ClaimID)
			if kv.Settled(slug, rec.ClaimID) {
				return finish(st, rlm, rec, t)
			}
			// a provisional verdict, held in escrow and reopenable
			st.Set(disputeID, kourt.StateContested, 0, t, 0, "", 0)
			return kourt.StateContested
		}
		if kv.Provisional(slug, rec.ClaimID) < 0 || c.reopenT == 0 || c.nowT < c.reopenT {
			return rec.State // escrow still open
		}
		kv.Finalize(cross(rlm), slug, rec.ClaimID)
		return finish(st, rlm, rec, t)
	default:
		return rec.State
	}
	return kourt.GetRecord(disputeID).State
}

// voteClosed reports whether the open dispute vote has reached its close on
// Kourt's clock: its governor closes on wall time when the proposal carries a
// closing instant, on height otherwise.
func voteClosed(c clock, claimID uint64) bool {
	if c.voteCloseT != 0 {
		return c.nowT >= c.voteCloseT
	}
	closes := c.voteCloseH
	if closes == 0 {
		closes = kv.DisputeVoteCloses(kourt.CourtSlug, claimID)
	}
	return closes != 0 && c.nowH >= closes
}

// answerFloor approximates Kourt's answerability floor for the court:
// 0.10% of the supply, at least 1 CC (Kourt measures last epoch's supply).
func answerFloor() int64 {
	f := kv.CoinSupply(kourt.CourtSlug) / 10000 * ordAnswerXFloorBps
	if f < oneCC {
		f = oneCC
	}
	return f
}

func stakeSize() int64 { return stakeMultiple * answerFloor() }

// answerable makes sure Kourt will take the answer: the trailing stake
// average must be mature and at or above the floor (a top-up in a later
// epoch seals the history and lifts the average), and the qualified
// answerers' priority window, when the court has one, must have passed.
func answerable(st *kourt.StateRef, rlm realm, rec *kourt.Record) bool {
	slug := kourt.CourtSlug
	c := claimClock(rec.ClaimID)
	floor := answerFloor()
	avg, mature := kv.TrailingOI(slug, rec.ClaimID, answerWindow)
	if !mature || avg < floor {
		stakedH, _ := strconv.ParseInt(kourt.Note("record", u(rec.Dispute), "stakedH"), 10, 64)
		if stakedH == 0 {
			stakedH = c.openedH
		}
		if c.nowH/epochBlocks < stakedH/epochBlocks+2 {
			return false // the ring cannot hold three epochs of history yet
		}
		top := int64(1)
		if avg < floor {
			// aim at the stake the mirror sizes for (the average moves by a
			// third of what the pool gains), not at the bare floor
			top = 3*(stakeMultiple*floor-avg) + 3
		}
		kv.Stake(cross(rlm), slug, rec.ClaimID, sideYES, top)
		st.Set(rec.Dispute, kourt.StateStaked, 0, rec.StakedAt, 0, "", rec.Stake+top)
		avg, mature = kv.TrailingOI(slug, rec.ClaimID, answerWindow)
		if !mature || avg < floor {
			return false
		}
	}
	if kv.PriorityGateActive(slug) {
		open := c.openedT + (kv.CourtStakeOpenDelay(slug)+answerWindow)*blockSecs + priorityWindowSecs
		if c.nowT < open {
			return false
		}
	}
	return true
}

// closeDead closes a claim that passed Kourt's dead-claim timeout without an
// answer (anyone may; Kourt returns the deposit to the author and burns the
// fee), then abandons the record.
func closeDead(st *kourt.StateRef, rlm realm, rec *kourt.Record, t int64) string {
	kv.CloseDeadClaim(cross(rlm), kourt.CourtSlug, rec.ClaimID)
	return abandon(st, rlm, rec, t)
}

// abandon closes the record of a claim that died unanswered on Kourt and
// takes the stake back (a dead claim's stakes exit freely).
func abandon(st *kourt.StateRef, rlm realm, rec *kourt.Record, t int64) string {
	slug := kourt.CourtSlug
	if s := kv.StakeOf(slug, rec.ClaimID, sideYES, kourt.Address()); s > 0 {
		kv.Unstake(cross(rlm), slug, rec.ClaimID, sideYES, s)
	}
	st.Set(rec.Dispute, kourt.StateAbandoned, 0, t, -1, "dead", 0)
	return kourt.StateAbandoned
}

// finish reads the final verdict, takes the stake back, opens the draw (which
// returns the deposit, the fee and the answer bond to this realm, the
// author) and records agreement or dissent.
func finish(st *kourt.StateRef, rlm realm, rec *kourt.Record, t int64) string {
	slug := kourt.CourtSlug
	route := kv.VerdictRoute(slug, rec.ClaimID)
	verdict := -1 // closed without a decision
	if !kv.ProvClose(slug, rec.ClaimID) {
		verdict = kv.Verdict(slug, rec.ClaimID)
	}
	if s := kv.StakeOf(slug, rec.ClaimID, sideYES, kourt.Address()); s > 0 {
		kv.WithdrawStake(cross(rlm), slug, rec.ClaimID, sideYES)
	}
	if !kv.RewardsOpened(slug, rec.ClaimID) {
		kv.OpenRewards(cross(rlm), slug, rec.ClaimID)
	}
	// the DAO's position is YES; whoever answered and however it settled,
	// a verdict against it is dissent
	state := kourt.StateSettled
	switch {
	case verdict < 0:
	case verdict != sideYES:
		state = kourt.StateDissent
	case route == "vote":
		state = kourt.StateConfirmed
	}
	st.Set(rec.Dispute, state, 0, t, verdict, route, 0)
	if verdict < 0 {
		// closed without a decision (failed dispute rounds or a spam
		// discard): settled, but nothing on Kourt agreed with the DAO
		st.Emit("KourtNoVerdict", "dispute", u(rec.Dispute), "claim", u(rec.ClaimID), "route", route)
	}
	return state
}

// ---- claim text

// title is the claim's fixed-format sentence (at most 200 characters).
func title(d *core.DisputeRecord) string {
	s := "Gnoracle #" + u(d.ID) + ": feed " + u(d.Feed) + " round " + u(d.Round) + " resolved " + d.Outcome
	if d.TierDecided != "" {
		s += "/" + d.TierDecided
	}
	s += "; value " + strconv.FormatInt(finalValue(d), 10) + "; " + strconv.FormatInt(d.ResolvedAt, 10)
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func finalValue(d *core.DisputeRecord) int64 {
	if d.Outcome == "OVERTURN" {
		return d.ProposedValue
	}
	return d.PriorValue
}

// body is the JSON record (at most 2000 bytes): a long evidence string, then
// a long feed name, is cut to fit, and the record then says it was truncated.
func body(d *core.DisputeRecord) string {
	name := ""
	if f := core.GetFeed(d.Feed); f != nil && f.Spec != nil {
		name = f.Spec.Name
	}
	ev := d.EvidenceHash
	cut := false
	for {
		o := jsonw.New().Uint("dispute", d.ID).Uint("feed", d.Feed).Str("feedName", name).Uint("round", d.Round).
			Str("outcome", d.Outcome).Str("tier", d.TierDecided).Int("priorValue", d.PriorValue).Int("proposedValue", d.ProposedValue).
			Str("disputer", string(d.Disputer)).Int("bond", d.Bond).Int("slashed", d.Slashed).Int("coherentWeight", d.CoherentW).
			Int("ballotRound", d.BallotRound).Str("evidenceHash", ev).Int("resolvedAt", d.ResolvedAt).
			Str("source", core.SelfPath()+":dispute/"+u(d.ID))
		if cut {
			o.Bool("truncated", true)
		}
		s := o.String()
		if len(s) <= 2000 || (ev == "" && name == "") {
			return s
		}
		cut = true
		if ev != "" {
			ev = ev[:len(ev)/2]
		} else {
			name = name[:len(name)/2]
		}
	}
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }

// ---- operations beyond the mirror API

// Invoke serves two operations; anyone may run either, since each only moves
// coin Kourt owes this realm into the float:
//
//   - `reclaim <dispute>` pulls the emission slices Kourt grants a settled
//     claim's winning stake, author and answerer; it mints nothing when
//     nothing is due;
//   - `withdraw <dispute>` recovers what an abandoned record of this binding
//     left on Kourt: the stake (withdrawn after a verdict, unstaked while the
//     claim has no answer) and, once the claim is settled, the deposit, fee
//     and answer bond the draw returns to its author.
func (*implKourtV3) Invoke(_ int, rlm realm, caller address, method, args string) string {
	kourt.Store(0, rlm)
	switch method {
	case "reclaim", "withdraw":
		id, err := strconv.ParseUint(strings.TrimSpace(args), 10, 64)
		if err != nil {
			panic("kourt: usage: " + method + " <dispute>")
		}
		if method == "withdraw" {
			return withdraw(0, rlm, id)
		}
		return reclaim(0, rlm, id)
	}
	panic("kourt: unknown method " + method)
}

func withdraw(_ int, rlm realm, disputeID uint64) string {
	rec := kourt.GetRecord(disputeID)
	if rec == nil || rec.Binding != binding || rec.ClaimID == 0 {
		panic("kourt: no claim for dispute " + u(disputeID) + " in " + binding)
	}
	if rec.State != kourt.StateAbandoned {
		panic("kourt: record " + u(disputeID) + " is " + rec.State + "; withdraw serves abandoned records (crank the others)")
	}
	slug, me := kourt.CourtSlug, kourt.Address()
	settled := kv.Settled(slug, rec.ClaimID)
	var withdrawn, unstaked int64
	opened := false
	if s := kv.StakeOf(slug, rec.ClaimID, sideYES, me); s > 0 {
		switch {
		case settled:
			withdrawn = kv.WithdrawStake(cross(rlm), slug, rec.ClaimID, sideYES)
		case !kv.HasAnswer(slug, rec.ClaimID):
			kv.Unstake(cross(rlm), slug, rec.ClaimID, sideYES, s)
			unstaked = s
		}
	}
	if settled && !kv.RewardsOpened(slug, rec.ClaimID) && !kv.ClaimClosed(slug, rec.ClaimID) {
		kv.OpenRewards(cross(rlm), slug, rec.ClaimID)
		opened = true
	}
	return jsonw.New().Uint("dispute", disputeID).Uint("claim", rec.ClaimID).Int("withdrawn", withdrawn).Int("unstaked", unstaked).
		Bool("opened", opened).Int("float", float()).String()
}

func reclaim(_ int, rlm realm, disputeID uint64) string {
	rec := kourt.GetRecord(disputeID)
	if rec == nil || rec.Binding != binding || rec.ClaimID == 0 {
		panic("kourt: no claim for dispute " + u(disputeID) + " in " + binding)
	}
	slug, me := kourt.CourtSlug, kourt.Address()
	if !kv.RewardsOpened(slug, rec.ClaimID) {
		panic("kourt: the draw of claim " + u(rec.ClaimID) + " is not open; crank the record to its verdict first")
	}
	winnerPaid, authorPaid, answererPaid := kv.PullState(slug, rec.ClaimID, me)
	var winner, author, answerer int64
	// only a position the mirror actually holds draws (a record that followed
	// a foreign answer never staked, and Kourt refuses a missing position)
	held := rec.Stake > 0 || kv.StakeOf(slug, rec.ClaimID, sideYES, me) > 0
	if !winnerPaid && held && kv.Provisional(slug, rec.ClaimID) == sideYES {
		winner = kv.WithdrawBonus(cross(rlm), slug, rec.ClaimID, sideYES)
	}
	if !authorPaid {
		author = kv.AuthorBonus(cross(rlm), slug, rec.ClaimID)
	}
	if !answererPaid && kv.Answerer(slug, rec.ClaimID) == me {
		answerer = kv.AnswererBonus(cross(rlm), slug, rec.ClaimID)
	}
	return jsonw.New().Uint("dispute", disputeID).Uint("claim", rec.ClaimID).Int("winner", winner).Int("author", author).
		Int("answerer", answerer).Int("float", float()).String()
}

// ---- pages

// pageSize is how many records a page of the index lists.
const pageSize = 50

// Render lists the mirror records, newest first and paged (`:page/<n>`);
// `:dispute/<id>` shows one. The permanent realm prefixes the attribution
// the Kourt licence asks for.
func (*implKourtV3) Render(_ int, rlm realm, path string) string {
	if strings.HasPrefix(path, "json") {
		return renderJSON(strings.Split(strings.Trim(strings.TrimPrefix(path, "json"), "/"), "/"))
	}
	var b strings.Builder
	b.WriteString("# Gnoracle Kourt mirror\n\n")
	b.WriteString("Every resolved dispute is filed as a claim in the DAO's court [" + kourt.CourtSlug + "](" + courtURL + ") on Kourt v3 (`" + kourtPath + "`)")
	if kv.Exists(kourt.CourtSlug) {
		b.WriteString(" · float " + cc(float()) + " CC (" + cc(spendable()) + " free)")
		if kv.CourtOneWay(kourt.CourtSlug) {
			b.WriteString(" · **one-way court**: its coin never returns GNOT, so the float cannot be redeemed")
		} else {
			b.WriteString(" · two-way court")
		}
	} else {
		b.WriteString(" · court not founded yet (`EnsureCourt`)")
	}
	b.WriteString("\n\n")
	page := 1
	switch {
	case path == "":
	case strings.HasPrefix(path, "dispute/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "dispute/"), 10, 64)
		if err == nil {
			if rec := kourt.GetRecord(id); rec != nil {
				b.WriteString("| | |\n|---|---|\n| dispute | [" + u(rec.Dispute) + "](" + disputeURL(rec.Dispute) + ") |\n| state | " + rec.State + " |\n| claim | " + claimLink(rec) + " |\n| title | " + cell(rec.Title) + " |\n| verdict | " + verdictLabel(rec) + " |\n| stake | " + cc(rec.Stake) + " CC |\n| steps | " + strconv.FormatInt(rec.Steps, 10) + " |\n")
				if rec.ClaimID != 0 && rec.Binding == binding && kv.Exists(kourt.CourtSlug) {
					b.WriteString("| Kourt says | " + cell(kv.ClaimStatus(kourt.CourtSlug, rec.ClaimID)) + " |\n")
				}
				return b.String()
			}
		}
		b.WriteString("_No mirror record there; records live at `:dispute/<id>`, the court's own pages at [" + courtURL + "](" + courtURL + ")._\n\n")
	case strings.HasPrefix(path, "page/"):
		if n, err := strconv.Atoi(strings.TrimPrefix(path, "page/")); err == nil && n >= 1 {
			page = n
		}
	default:
		b.WriteString("_No such page; records live at `:dispute/<id>`, the index at `:page/<n>`._\n\n")
	}
	recs := kourt.NewestRecords((page-1)*pageSize, pageSize)
	total := int(kourt.Count())
	b.WriteString("| dispute | state | claim | title |\n|---|---|---|---|\n")
	for _, rec := range recs {
		b.WriteString("| [" + u(rec.Dispute) + "](:dispute/" + u(rec.Dispute) + ") | " + rec.State + " | " + claimLink(rec) + " | " + cell(rec.Title) + " |\n")
	}
	if total == 0 {
		b.WriteString("\n_No records yet: a record appears when a resolved dispute is cranked._\n")
	}
	b.WriteString(pager(page, total))
	return b.String()
}

// pager links the neighbouring pages of the record index.
func pager(page, total int) string {
	var links []string
	if page > 1 {
		links = append(links, "[newer](:page/"+strconv.Itoa(page-1)+")")
	}
	if page*pageSize < total {
		links = append(links, "[older](:page/"+strconv.Itoa(page+1)+")")
	}
	if len(links) == 0 {
		return ""
	}
	return "\nPage " + strconv.Itoa(page) + " of " + strconv.Itoa((total+pageSize-1)/pageSize) + " · " + strings.Join(links, " · ") + "\n"
}

// cell makes a string safe for a markdown table cell.
func cell(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\r", " ")
	return strings.ReplaceAll(s, "\n", " ")
}

// courtURL is the court's page on gnoweb.
const courtURL = "/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:" + kourt.CourtSlug

func disputeURL(id uint64) string { return "/r/clockwork/gnoracle/core:dispute/" + u(id) }

// claimLink is the claim's page on the court, for records of this binding.
func claimLink(rec *kourt.Record) string {
	if rec.ClaimID == 0 {
		return "none yet"
	}
	if rec.Binding != binding {
		return u(rec.ClaimID) + " (" + rec.Binding + ")"
	}
	return "[" + u(rec.ClaimID) + "](" + courtURL + "/" + u(rec.ClaimID) + ")"
}

// cc formats micro court coin as a decimal.
func cc(n int64) string {
	neg := n < 0
	if neg {
		n = -n
	}
	s := strconv.FormatInt(n/oneCC, 10)
	if frac := n % oneCC; frac != 0 {
		f := strconv.FormatInt(frac, 10)
		for len(f) < 6 {
			f = "0" + f
		}
		s += "." + strings.TrimRight(f, "0")
	}
	if neg {
		return "-" + s
	}
	return s
}

// renderJSON serves `:json/now`, `:json/record/<dispute>` and
// `:json/records[/<from>[/<count>]]` for the bot's Kourt cranking.
func renderJSON(parts []string) string {
	head := func() *jsonw.Object {
		exists := kv.Exists(kourt.CourtSlug)
		return jsonw.New().Int("now", now()).Str("live", kourt.LivePath()).Str("court", kourt.CourtSlug).Str("kourt", kourtPath).
			Str("address", string(kourt.Address())).Bool("courtExists", exists).Bool("oneWay", exists && kv.CourtOneWay(kourt.CourtSlug)).Int("float", float()).Int("spendable", spendable()).Int("creationBurn", kv.CourtCreationBurn()).
			Uint("count", kourt.Count()).Uint("disputes", core.DisputeCount())
	}
	if len(parts) == 0 || parts[0] == "" || parts[0] == "now" {
		return head().String()
	}
	switch parts[0] {
	case "record":
		if len(parts) < 2 {
			return jsonw.Error("dispute id missing")
		}
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return jsonw.Error("bad dispute id")
		}
		rec := kourt.GetRecord(id)
		if rec == nil {
			return head().Uint("dispute", id).Bool("exists", false).String()
		}
		return jsonRecord(rec).String()
	case "records":
		from, count := int64(1), int64(25)
		if len(parts) >= 2 {
			if n, err := strconv.ParseInt(parts[1], 10, 64); err == nil && n >= 1 {
				from = n
			}
		}
		if len(parts) >= 3 {
			if n, err := strconv.ParseInt(parts[2], 10, 64); err == nil && n > 0 && n <= 100 {
				count = n
			}
		}
		a := jsonw.NewArray()
		total := core.DisputeCount()
		for id := uint64(from); id <= total && int64(a.Len()) < count; id++ {
			if rec := kourt.GetRecord(id); rec != nil {
				a.Raw(jsonRecord(rec).String())
			}
		}
		return head().Raw("records", a.String()).String()
	}
	return jsonw.Error("unknown json path")
}

func jsonRecord(rec *kourt.Record) *jsonw.Object {
	o := jsonw.New().Int("now", now()).Uint("dispute", rec.Dispute).Bool("exists", true).Str("binding", rec.Binding).Str("state", rec.State).Uint("claim", rec.ClaimID).
		Str("title", rec.Title).Int("openedAt", rec.OpenedAt).Int("stakedAt", rec.StakedAt).Int("answeredAt", rec.AnsweredAt).
		Int("settledAt", rec.SettledAt).Int("verdict", int64(rec.Verdict)).Str("route", rec.Route).Int("stake", rec.Stake).Int("steps", rec.Steps)
	if rec.ClaimID != 0 && rec.Binding == binding && kv.Exists(kourt.CourtSlug) {
		o.Str("kourtStatus", kv.ClaimStatus(kourt.CourtSlug, rec.ClaimID)).Str("kourtTimeline", kv.ClaimTimeline(kourt.CourtSlug, rec.ClaimID))
	}
	return o
}

// verdictLabel names a record's verdict for the pages: YES agrees with the
// DAO, NO is Kourt's dissent, none while pending or when closed undecided.
func verdictLabel(rec *kourt.Record) string {
	switch rec.State {
	case kourt.StateSettled, kourt.StateConfirmed, kourt.StateDissent, kourt.StateAbandoned:
	default:
		return "pending"
	}
	v := "none"
	switch rec.Verdict {
	case 0:
		v = "YES"
	case 1:
		v = "NO"
	}
	if rec.Route != "" {
		v += " (" + cell(rec.Route) + ")"
	}
	return v
}
