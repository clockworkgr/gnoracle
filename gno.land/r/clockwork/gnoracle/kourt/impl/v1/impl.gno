// Package impl is the development release of the Kourt mirror. It binds to
// kourtdev, the local stand-in, so the mirror can be exercised on a chain
// without Kourt; impl/kourtv3 is the release for a live network, bound to the
// deployed Kourt v3 realm and modelling its clocks.
package impl

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/clockwork/gnoracle/jsonw/v0"
	"gno.land/r/clockwork/gnoracle/core"
	"gno.land/r/clockwork/gnoracle/kourt"
	kv "gno.land/r/clockwork/gnoracle/kourtdev"
)

// The stand-in's timings (a flat 3 h answer wait and the 72 h settle).
const (
	answerWindow = int64(3 * 3600)
	settleDelay  = int64(72 * 3600)
	stakeCC      = int64(2_000_000) // 2 CC on the verdict side: clears the 1 CC answerability floor with margin
	sideYES      = 0
)

type implV1 struct{}

var instance = &implV1{}

// Instance returns the implementation object.
func Instance() kourt.Mirror { return instance }

func init(cur realm) {
	kourt.RegisterImpl(cross(cur), instance)
}

func now() int64 { return time.Now().Unix() }

// EnsureCourt founds the DAO's court on the stand-in when missing.
func (*implV1) EnsureCourt(_ int, rlm realm) string {
	kourt.Store(0, rlm)
	if kv.Exists(kourt.CourtSlug) {
		return kourt.CourtSlug
	}
	return kv.StartCourt(cross(rlm), kourt.CourtSlug, "Gnoracle disputes")
}

// Float is the court coin held by the mirror realm.
func (*implV1) Float(_ int, rlm realm) int64 {
	kourt.Store(0, rlm)
	if !kv.Exists(kourt.CourtSlug) {
		return 0
	}
	return kv.CoinBalanceOf(kourt.CourtSlug, kourt.Address())
}

// Redeem is not available on the stand-in (one-way).
func (*implV1) Redeem(_ int, rlm realm, amount int64) int64 {
	kourt.Store(0, rlm)
	panic("kourt: the stand-in court has no redeem; the live release binds a two-way court")
}

// Crank advances a dispute's mirror by one step.
func (*implV1) Crank(_ int, rlm realm, disputeID uint64) string {
	st := kourt.Store(0, rlm)
	d := core.GetDispute(disputeID)
	if d == nil {
		panic("kourt: unknown dispute")
	}
	if d.Status != core.DisputeResolved {
		panic("kourt: the dispute is not resolved yet")
	}
	if !kv.Exists(kourt.CourtSlug) {
		kv.StartCourt(cross(rlm), kourt.CourtSlug, "Gnoracle disputes")
	}
	rec := kourt.GetRecord(disputeID)
	if rec == nil {
		rec = st.NewRecord(disputeID, binding, title(d))
	}
	if rec.Binding != binding {
		panic("kourt: record " + u(disputeID) + " was filed under " + rec.Binding + "; this release binds " + binding + " (the authority may Abandon it)")
	}
	t := now()
	switch rec.State {
	case kourt.StatePending:
		id := kv.OpenClaimP(cross(rlm), kourt.CourtSlug, rec.Title, body(d))
		st.Set(disputeID, kourt.StateFiled, id, t, 0, "", 0)
	case kourt.StateFiled:
		if kv.HasAnswer(kourt.CourtSlug, rec.ClaimID) {
			// a holder answered before the mirror staked: staking is frozen,
			// so the mirror follows the claim to its verdict without a position
			st.Set(disputeID, kourt.StateAnswered, 0, t, 0, "", 0)
			return kourt.StateAnswered
		}
		kv.Stake(cross(rlm), kourt.CourtSlug, rec.ClaimID, sideYES, stakeCC)
		st.Set(disputeID, kourt.StateStaked, 0, t, 0, "", stakeCC)
	case kourt.StateStaked:
		// anyone may answer once the claim is answerable; a foreign answer
		// is recorded rather than fought, and finish judges the verdict
		if kv.HasAnswer(kourt.CourtSlug, rec.ClaimID) {
			st.Set(disputeID, kourt.StateAnswered, 0, t, 0, "", 0)
			return kourt.StateAnswered
		}
		if t < rec.OpenedAt+answerWindow {
			return rec.State
		}
		kv.PostAnswer(cross(rlm), kourt.CourtSlug, rec.ClaimID, sideYES)
		st.Set(disputeID, kourt.StateAnswered, 0, t, 0, "", 0)
	case kourt.StateAnswered:
		if kv.DisputeOpen(kourt.CourtSlug, rec.ClaimID) {
			st.Set(disputeID, kourt.StateContested, 0, t, 0, "", 0)
			return kourt.StateContested
		}
		if kv.Settled(kourt.CourtSlug, rec.ClaimID) {
			return finish(st, rlm, rec, t)
		}
		if t < rec.AnsweredAt+settleDelay {
			return rec.State
		}
		kv.SettleUndisputed(cross(rlm), kourt.CourtSlug, rec.ClaimID)
		return finish(st, rlm, rec, t)
	case kourt.StateContested:
		if !kv.Settled(kourt.CourtSlug, rec.ClaimID) {
			return rec.State
		}
		return finish(st, rlm, rec, t)
	default:
		return rec.State
	}
	return kourt.GetRecord(disputeID).State
}

// finish reads the final verdict, withdraws the stake and records agreement
// or dissent.
func finish(st *kourt.StateRef, rlm realm, rec *kourt.Record, t int64) string {
	verdict := kv.Verdict(kourt.CourtSlug, rec.ClaimID)
	route := kv.VerdictRoute(kourt.CourtSlug, rec.ClaimID)
	if rec.Stake > 0 {
		kv.WithdrawStake(cross(rlm), kourt.CourtSlug, rec.ClaimID, sideYES)
	}
	// the DAO's position is YES; whoever answered and however it settled,
	// a verdict against it is dissent
	state := kourt.StateSettled
	switch {
	case verdict != sideYES:
		state = kourt.StateDissent
	case route == "vote":
		state = kourt.StateConfirmed
	}
	st.Set(rec.Dispute, state, 0, t, verdict, route, 0)
	return state
}

// title is the claim's fixed-format sentence (at most 200 bytes).
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

// pageSize is how many records a page of the index lists.
const pageSize = 50

// Render lists the mirror records, newest first and paged (`:page/<n>`);
// `:dispute/<id>` shows one.
func (*implV1) Render(_ int, rlm realm, path string) string {
	if strings.HasPrefix(path, "json") {
		return renderJSON(strings.Split(strings.Trim(strings.TrimPrefix(path, "json"), "/"), "/"))
	}
	var b strings.Builder
	b.WriteString("# Gnoracle Kourt mirror\n\n")
	b.WriteString("Court `" + kourt.CourtSlug + "` on the stand-in `" + kourtPath + "` (one-way: no redeem)\n\n")
	page := 1
	switch {
	case path == "":
	case strings.HasPrefix(path, "dispute/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "dispute/"), 10, 64)
		if err == nil {
			if rec := kourt.GetRecord(id); rec != nil {
				b.WriteString("| | |\n|---|---|\n| dispute | " + u(rec.Dispute) + " |\n| state | " + rec.State + " |\n| claim | " + u(rec.ClaimID) + " |\n| title | " + cell(rec.Title) + " |\n| verdict | " + strconv.Itoa(rec.Verdict) + " (" + cell(rec.Route) + ") |\n| steps | " + strconv.FormatInt(rec.Steps, 10) + " |\n")
				return b.String()
			}
		}
		b.WriteString("_No mirror record there; records live at `:dispute/<id>`._\n\n")
	case strings.HasPrefix(path, "page/"):
		if n, err := strconv.Atoi(strings.TrimPrefix(path, "page/")); err == nil && n >= 1 {
			page = n
		}
	default:
		b.WriteString("_No such page; records live at `:dispute/<id>`, the index at `:page/<n>`._\n\n")
	}
	total := int(kourt.Count())
	b.WriteString("| dispute | state | claim | title |\n|---|---|---|---|\n")
	for _, rec := range kourt.NewestRecords((page-1)*pageSize, pageSize) {
		b.WriteString("| [" + u(rec.Dispute) + "](:dispute/" + u(rec.Dispute) + ") | " + rec.State + " | " + u(rec.ClaimID) + " | " + cell(rec.Title) + " |\n")
	}
	var links []string
	if page > 1 {
		links = append(links, "[newer](:page/"+strconv.Itoa(page-1)+")")
	}
	if page*pageSize < total {
		links = append(links, "[older](:page/"+strconv.Itoa(page+1)+")")
	}
	if len(links) > 0 {
		b.WriteString("\nPage " + strconv.Itoa(page) + " · " + strings.Join(links, " · ") + "\n")
	}
	return b.String()
}

// cell makes a string safe for a markdown table cell.
func cell(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\r", " ")
	return strings.ReplaceAll(s, "\n", " ")
}

const kourtPath = "gno.land/r/clockwork/gnoracle/kourtdev"

// binding names the Kourt realm and court this release files into; records
// remember it so a rebinding release never cranks another court's claims.
const binding = kourtPath + "#" + kourt.CourtSlug

// renderJSON serves `:json/now`, `:json/record/<dispute>` and
// `:json/records[/<from>[/<count>]]` for the bot's Kourt cranking.
func renderJSON(parts []string) string {
	head := func() *jsonw.Object {
		return jsonw.New().Int("now", now()).Str("live", kourt.LivePath()).Str("court", kourt.CourtSlug).Str("kourt", kourtPath).Bool("oneWay", true).
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
	return jsonw.New().Int("now", now()).Uint("dispute", rec.Dispute).Bool("exists", true).Str("binding", rec.Binding).Str("state", rec.State).Uint("claim", rec.ClaimID).
		Str("title", rec.Title).Int("openedAt", rec.OpenedAt).Int("stakedAt", rec.StakedAt).Int("answeredAt", rec.AnsweredAt).
		Int("settledAt", rec.SettledAt).Int("verdict", int64(rec.Verdict)).Str("route", rec.Route).Int("stake", rec.Stake).Int("steps", rec.Steps)
}

// Invoke: this release defines no operations beyond the mirror API.
func (*implV1) Invoke(_ int, rlm realm, caller address, method, args string) string {
	kourt.Store(0, rlm)
	panic("kourt: unknown method " + method)
}
