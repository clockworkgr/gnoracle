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
//   - a claim nobody answers for twelve weeks dies; its stake is taken back
//     and the record is closed as abandoned.
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
	blockSecs          = int64(5) // Kourt's blocks-to-seconds ratio
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

// Redeem converts court coin back to GNOT (the DAO's court is two-way) and
// forwards the proceeds to the treasury.
func (*implKourtV3) Redeem(_ int, rlm realm, amount int64) int64 {
	st := kourt.Store(0, rlm)
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
	openedT, openedH     int64
	answeredT, answeredH int64
	reopenT, reopenH     int64 // escrow end of a provisional verdict
	nowT, nowH           int64
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
		amount := stakeSize()
		kv.Stake(cross(rlm), slug, rec.ClaimID, sideYES, amount)
		st.Set(disputeID, kourt.StateStaked, 0, t, 0, "", amount)
		st.SetNote("record", u(disputeID), "stakedH", strconv.FormatInt(claimClock(rec.ClaimID).nowH, 10))
	case kourt.StateStaked:
		// anyone may answer once the claim is answerable; a foreign answer
		// is recorded rather than fought, and finish judges the verdict
		if kv.HasAnswer(slug, rec.ClaimID) {
			st.Set(disputeID, kourt.StateAnswered, 0, t, 0, "", 0)
			return kourt.StateAnswered
		}
		if kv.ClaimClosed(slug, rec.ClaimID) {
			return abandon(st, rlm, rec, t)
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
			closes := kv.DisputeVoteCloses(slug, rec.ClaimID)
			if closes == 0 || c.nowH < closes {
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
			top = 3*(floor-avg) + 3 // the average moves by a third of what the pool gains
		}
		kv.Stake(cross(rlm), slug, rec.ClaimID, sideYES, top)
		st.Set(rec.Dispute, kourt.StateStaked, 0, now(), 0, "", rec.Stake+top)
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

// body is the JSON record (at most 2000 characters).
func body(d *core.DisputeRecord) string {
	f := core.GetFeed(d.Feed)
	name := ""
	if f != nil && f.Spec != nil {
		name = f.Spec.Name
	}
	var b strings.Builder
	b.WriteString(`{"dispute":` + u(d.ID) + `,"feed":` + u(d.Feed) + `,"feedName":` + strconv.Quote(name) +
		`,"round":` + u(d.Round) + `,"outcome":` + strconv.Quote(d.Outcome) + `,"tier":` + strconv.Quote(d.TierDecided) +
		`,"priorValue":` + strconv.FormatInt(d.PriorValue, 10) + `,"proposedValue":` + strconv.FormatInt(d.ProposedValue, 10) +
		`,"disputer":` + strconv.Quote(string(d.Disputer)) + `,"bond":` + strconv.FormatInt(d.Bond, 10) +
		`,"slashed":` + strconv.FormatInt(d.Slashed, 10) + `,"coherentWeight":` + strconv.FormatInt(d.CoherentW, 10) +
		`,"ballotRound":` + strconv.FormatInt(d.BallotRound, 10) + `,"evidenceHash":` + strconv.Quote(d.EvidenceHash) +
		`,"resolvedAt":` + strconv.FormatInt(d.ResolvedAt, 10) + `,"source":` + strconv.Quote(core.SelfPath()+":dispute/"+u(d.ID)) + `}`)
	s := b.String()
	if len(s) > 2000 {
		s = s[:2000]
	}
	return s
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }

// ---- operations beyond the mirror API

// Invoke serves `reclaim <dispute>`: it pulls the emission slices Kourt
// grants a settled claim's winning stake, author and answerer into the
// float. Anyone may run it; it mints nothing when nothing is due.
func (*implKourtV3) Invoke(_ int, rlm realm, caller address, method, args string) string {
	kourt.Store(0, rlm)
	switch method {
	case "reclaim":
		id, err := strconv.ParseUint(strings.TrimSpace(args), 10, 64)
		if err != nil {
			panic("kourt: usage: reclaim <dispute>")
		}
		return reclaim(0, rlm, id)
	}
	panic("kourt: unknown method " + method)
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
	if !winnerPaid && kv.Provisional(slug, rec.ClaimID) == sideYES {
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

// Render lists the mirror records; the permanent realm prefixes the
// attribution the Kourt licence asks for.
func (*implKourtV3) Render(_ int, rlm realm, path string) string {
	if strings.HasPrefix(path, "json") {
		return renderJSON(strings.Split(strings.Trim(strings.TrimPrefix(path, "json"), "/"), "/"))
	}
	var b strings.Builder
	b.WriteString("# Gnoracle Kourt mirror\n\n")
	b.WriteString("court `" + kourt.CourtSlug + "` on `" + kourtPath + "`")
	if kv.Exists(kourt.CourtSlug) {
		b.WriteString(" · float " + cc(float()) + " CC (" + cc(spendable()) + " free)")
	} else {
		b.WriteString(" · court not founded yet (`EnsureCourt`)")
	}
	b.WriteString("\n\n")
	if path != "" {
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "dispute/"), 10, 64)
		if err == nil {
			if rec := kourt.GetRecord(id); rec != nil {
				b.WriteString("| | |\n|---|---|\n| dispute | " + u(rec.Dispute) + " |\n| state | " + rec.State + " |\n| claim | " + u(rec.ClaimID) + " |\n| title | " + rec.Title + " |\n| verdict | " + strconv.Itoa(rec.Verdict) + " (" + rec.Route + ") |\n| stake | " + cc(rec.Stake) + " CC |\n| steps | " + strconv.FormatInt(rec.Steps, 10) + " |\n")
				if rec.ClaimID != 0 && kv.Exists(kourt.CourtSlug) {
					b.WriteString("| Kourt | " + kv.ClaimStatus(kourt.CourtSlug, rec.ClaimID) + " |\n")
				}
				return b.String()
			}
		}
		return b.String() + "unknown record\n"
	}
	b.WriteString("| dispute | state | claim | title |\n|---|---|---|---|\n")
	for id := uint64(1); id <= core.DisputeCount(); id++ {
		rec := kourt.GetRecord(id)
		if rec == nil {
			continue
		}
		b.WriteString("| [" + u(id) + "](:dispute/" + u(id) + ") | " + rec.State + " | " + u(rec.ClaimID) + " | " + rec.Title + " |\n")
	}
	return b.String()
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
			Str("address", string(kourt.Address())).Bool("courtExists", exists).Int("float", float()).Int("spendable", spendable()).Int("creationBurn", kv.CourtCreationBurn()).
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
