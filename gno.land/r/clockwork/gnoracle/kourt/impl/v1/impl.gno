// Package impl is the first Kourt mirror release. It binds to kourtdev, the
// local stand-in; the release for a live network changes the import below to
// the deployed Kourt realm and nothing else.
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

// Kourt's own timings (kourt v3 court.gno, clock.gno).
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
		rec = st.NewRecord(disputeID, title(d))
	}
	t := now()
	switch rec.State {
	case kourt.StatePending:
		id := kv.OpenClaimP(cross(rlm), kourt.CourtSlug, rec.Title, body(d))
		st.Set(disputeID, kourt.StateFiled, id, t, 0, "", 0)
	case kourt.StateFiled:
		kv.Stake(cross(rlm), kourt.CourtSlug, rec.ClaimID, sideYES, stakeCC)
		st.Set(disputeID, kourt.StateStaked, 0, t, 0, "", stakeCC)
	case kourt.StateStaked:
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
	kv.WithdrawStake(cross(rlm), kourt.CourtSlug, rec.ClaimID, sideYES)
	state := kourt.StateSettled
	if route == "vote" {
		if verdict == sideYES {
			state = kourt.StateConfirmed
		} else {
			state = kourt.StateDissent
		}
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

// body is the JSON record (at most 2000 bytes).
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
		`,"resolvedAt":` + strconv.FormatInt(d.ResolvedAt, 10) + `,"source":"gno.land/r/clockwork/gnoracle/core:dispute/` + u(d.ID) + `"}`)
	s := b.String()
	if len(s) > 2000 {
		s = s[:2000]
	}
	return s
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }

// Render lists the mirror records with the attribution the licence asks for.
func (*implV1) Render(_ int, rlm realm, path string) string {
	if strings.HasPrefix(path, "json") {
		return renderJSON(strings.Split(strings.Trim(strings.TrimPrefix(path, "json"), "/"), "/"))
	}
	var b strings.Builder
	b.WriteString("# Gnoracle Kourt mirror\n\n")
	b.WriteString("[built on Kourt](https://kourt.xyz) · court `" + kourt.CourtSlug + "` on `" + kourtPath + "`\n\n")
	if path != "" {
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "dispute/"), 10, 64)
		if err == nil {
			if rec := kourt.GetRecord(id); rec != nil {
				b.WriteString("| | |\n|---|---|\n| dispute | " + u(rec.Dispute) + " |\n| state | " + rec.State + " |\n| claim | " + u(rec.ClaimID) + " |\n| title | " + rec.Title + " |\n| verdict | " + strconv.Itoa(rec.Verdict) + " (" + rec.Route + ") |\n| steps | " + strconv.FormatInt(rec.Steps, 10) + " |\n")
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

const kourtPath = "gno.land/r/clockwork/gnoracle/kourtdev"

// renderJSON serves `:json/now`, `:json/record/<dispute>` and
// `:json/records[/<from>[/<count>]]` for the bot's Kourt cranking.
func renderJSON(parts []string) string {
	head := func() *jsonw.Object {
		return jsonw.New().Int("now", now()).Str("live", kourt.LivePath()).Str("court", kourt.CourtSlug).Str("kourt", kourtPath).
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
	return jsonw.New().Int("now", now()).Uint("dispute", rec.Dispute).Bool("exists", true).Str("state", rec.State).Uint("claim", rec.ClaimID).
		Str("title", rec.Title).Int("openedAt", rec.OpenedAt).Int("stakedAt", rec.StakedAt).Int("answeredAt", rec.AnsweredAt).
		Int("settledAt", rec.SettledAt).Int("verdict", int64(rec.Verdict)).Str("route", rec.Route).Int("stake", rec.Stake).Int("steps", rec.Steps)
}
