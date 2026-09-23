// Package kourt is the permanent realm of the Gnoracle Kourt mirror: every
// resolved dispute is filed as a claim in a Kourt court the DAO controls,
// staked, answered and settled, so the record of what the oracle decided
// lives on a court of record beside the oracle (plan §7.4).
//
// A Gno import is compile-time, so the realm that talks to Kourt must name
// one Kourt deployment. That realm is the implementation behind this one's
// proxy: impl/v1 binds to the local stand-in (kourtdev), a later release
// binds to the deployed Kourt. This permanent realm holds the mirror records
// and the identity that owns the court-coin float, so a release change
// moves neither.
package kourt

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/clockwork/upgradeable/v0"
	"gno.land/p/nt/bptree/v0"
)

// Admin is the bootstrap authority (the public test1 key for gnodev).
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

// DAOPath may also govern this realm's releases.
const DAOPath = "gno.land/r/clockwork/gnoracle/dao"

// CourtSlug is the DAO's court in whichever Kourt the release binds to.
const CourtSlug = "gnoracle"

// Mirror states.
const (
	StatePending   = "pending"   // dispute resolved on the core, nothing filed yet
	StateFiled     = "filed"     // claim opened
	StateStaked    = "staked"    // stake placed on the verdict side
	StateAnswered  = "answered"  // bonded answer posted
	StateSettled   = "settled"   // verdict final, route undisputed
	StateContested = "contested" // a Kourt holder disputed the answer
	StateDissent   = "dissent"   // Kourt's vote disagreed with the DAO
	StateConfirmed = "confirmed" // Kourt's vote agreed with the DAO
)

// Record is one dispute's mirror.
type Record struct {
	Dispute    uint64
	State      string
	ClaimID    uint64
	Title      string
	OpenedAt   int64
	StakedAt   int64
	AnsweredAt int64
	SettledAt  int64
	Verdict    int
	Route      string
	Stake      int64
	Steps      int64
}

// Mirror is the behaviour an implementation provides.
type Mirror interface {
	// Crank advances one dispute's mirror by one step and returns the new
	// state, or the current one when nothing was due.
	Crank(_ int, rlm realm, disputeID uint64) string
	// EnsureCourt founds the DAO's court when it does not exist yet.
	EnsureCourt(_ int, rlm realm) string
	// Float reports the court coin this realm holds.
	Float(_ int, rlm realm) int64
	// Redeem converts amount of court coin back to GNOT where the bound
	// Kourt allows it (two-way courts) and sends it to the treasury.
	Redeem(_ int, rlm realm, amount int64) int64
	Render(_ int, rlm realm, path string) string
}

var (
	proxy    *upgradeable.Proxy
	selfPath string
	records  = bptree.NewBPTree32() // disputeKey -> *Record
	count    uint64
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	proxy = upgradeable.New(upgradeable.NewAnyOf(
		upgradeable.NewAddrAuthority(Admin),
		upgradeable.NewRealmAuthority(DAOPath),
	))
}

func key(id uint64) string {
	return string([]byte{byte(id >> 56), byte(id >> 48), byte(id >> 40), byte(id >> 32), byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)})
}

// ---- entry points

// Crank advances a dispute's mirror. Anyone; the notifier bot runs it daily.
func Crank(cur realm, disputeID uint64) string { return live().Crank(0, cur, disputeID) }

// EnsureCourt founds the DAO's court if needed. Anyone.
func EnsureCourt(cur realm) string { return live().EnsureCourt(0, cur) }

// RedeemFloat converts court coin back to GNOT for the treasury. Authority.
func RedeemFloat(cur realm, amount int64) int64 {
	proxy.AssertAuthorized(0, cur)
	return live().Redeem(0, cur, amount)
}

// Float is the court coin this realm holds in the bound Kourt.
func Float(cur realm) int64 { return live().Float(0, cur) }

// ---- views

// GetRecord returns a dispute's mirror record or nil.
func GetRecord(disputeID uint64) *Record {
	v := records.Get(key(disputeID))
	if v == nil {
		return nil
	}
	return v.(*Record)
}

// Count is the number of mirror records.
func Count() uint64 { return count }

// Address is this realm's account (where court coin is sent).
func Address() address { return chain.PackageAddress(selfPath) }

// SelfPath is this realm's package path.
func SelfPath() string { return selfPath }

// ---- store

// StateRef is the gated write capability for the live implementation.
type StateRef struct{ rlm realm }

// Store hands out a StateRef to the live implementation or an extension.
func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("kourt: realm value is not the caller's live cur")
	}
	if caller := rlm.PkgPath(); caller != selfPath && !proxy.IsExtension(caller) {
		panic("kourt: state is reachable only through " + selfPath + " or a registered extension, not from " + caller)
	}
}

func (r *StateRef) check() { assertStateAccess(0, r.rlm) }

// Realm exposes the permanent realm's live cur to the implementation for the
// calls it makes into Kourt on this realm's behalf. It is the same value the
// implementation was handed; returning it here documents the intent.
func (r *StateRef) Realm() realm {
	r.check()
	return r.rlm
}

// NewRecord starts a mirror record for a dispute.
func (r *StateRef) NewRecord(disputeID uint64, title string) *Record {
	r.check()
	if GetRecord(disputeID) != nil {
		panic("kourt: record exists")
	}
	rec := &Record{Dispute: disputeID, State: StatePending, Title: title}
	records.Set(key(disputeID), rec)
	count++
	emit("KourtRecord", "dispute", strconv.FormatUint(disputeID, 10), "state", StatePending)
	return rec
}

// Set records a state transition.
func (r *StateRef) Set(disputeID uint64, state string, claimID uint64, at int64, verdict int, route string, stake int64) {
	r.check()
	rec := GetRecord(disputeID)
	if rec == nil {
		panic("kourt: unknown record")
	}
	rec.State = state
	rec.Steps++
	if claimID != 0 {
		rec.ClaimID = claimID
	}
	switch state {
	case StateFiled:
		rec.OpenedAt = at
	case StateStaked:
		rec.StakedAt = at
		rec.Stake = stake
	case StateAnswered:
		rec.AnsweredAt = at
	case StateSettled, StateConfirmed, StateDissent:
		rec.SettledAt = at
		rec.Verdict = verdict
		rec.Route = route
	}
	emit("KourtRecord", "dispute", strconv.FormatUint(disputeID, 10), "state", state, "claim", strconv.FormatUint(rec.ClaimID, 10))
	if state == StateDissent {
		emit("KourtDissent", "dispute", strconv.FormatUint(disputeID, 10), "claim", strconv.FormatUint(rec.ClaimID, 10))
	}
}

// Emit lets the implementation emit under this realm's path.
func (r *StateRef) Emit(typ string, attrs ...string) {
	r.check()
	emit(typ, attrs...)
}

func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }

// ---- proxy

// RegisterImpl records the calling realm as a candidate implementation.
func RegisterImpl(cur realm, impl Mirror) { proxy.Propose(0, cur, impl) }

// Accept makes the candidate at pkgPath live. Authority only.
func Accept(cur realm, pkgPath string) { proxy.Accept(0, cur, pkgPath) }

// Rollback restores the previous release. Authority only.
func Rollback(cur realm) { proxy.Rollback(0, cur) }

// Freeze ends upgradeability. Authority only.
func Freeze(cur realm) { proxy.Freeze(0, cur) }

// TransferAuthorityToRealms hands the authority to governance realm paths.
func TransferAuthorityToRealms(cur realm, csvPaths string) {
	parts := strings.Split(csvPaths, ",")
	paths := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			paths = append(paths, p)
		}
	}
	proxy.TransferAuthority(0, cur, upgradeable.NewRealmAuthority(paths...))
}

// LivePath is the implementation currently serving.
func LivePath() string { return proxy.LivePath() }

// PendingPaths lists candidates awaiting acceptance.
func PendingPaths() []string {
	out := []string{}
	for _, r := range proxy.Pending() {
		out = append(out, r.PkgPath())
	}
	return out
}

// Authority describes who may upgrade.
func Authority() string { return proxy.Authority().String() }

func live() Mirror {
	v, ok := proxy.TryImpl()
	if !ok {
		panic("kourt: no implementation has been accepted yet")
	}
	m, ok := v.(Mirror)
	if !ok {
		panic("kourt: live implementation does not satisfy Mirror")
	}
	return m
}

// Render shows the mirror records with the Kourt attribution the licence
// asks for on every page that displays a claim.
func Render(cur realm, path string) string {
	if _, ok := proxy.TryImpl(); !ok {
		return "# Gnoracle Kourt mirror\n\n_No implementation accepted yet._\n"
	}
	return live().Render(0, cur, path)
}
