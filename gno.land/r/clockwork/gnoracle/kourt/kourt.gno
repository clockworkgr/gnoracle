// Package kourt is the permanent realm of the Gnoracle Kourt mirror: every
// resolved dispute is filed as a claim in a Kourt court the DAO controls,
// staked, answered and settled, so the record of what the oracle decided
// lives on a court of record beside the oracle (plan §7.4).
//
// A Gno import is compile-time, so the realm that talks to Kourt must name
// one Kourt deployment. That realm is the implementation behind this one's
// proxy: impl/kourtv3 binds the deployed Kourt v3 realm
// (gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3) and is the
// production release; impl/v1 binds the local stand-in (kourtdev) for
// development chains. This permanent realm holds the mirror records and the
// identity that owns the court-coin float, so a release change moves
// neither.
package kourt

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"time"

	"gno.land/p/clockwork/gnoracle/authspec/v0"
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
	StateSettled   = "settled"   // verdict final and agreeing with the DAO without a vote, or closed with no decision (Verdict -1)
	StateContested = "contested" // a Kourt holder disputed the answer
	StateDissent   = "dissent"   // Kourt's vote disagreed with the DAO
	StateConfirmed = "confirmed" // Kourt's vote agreed with the DAO
	StateAbandoned = "abandoned" // closed with no decision (Verdict -1): the claim died unanswered, or the authority closed a record the release cannot advance
)

// Record is one dispute's mirror.
type Record struct {
	Dispute    uint64
	Binding    string // the Kourt realm and court the claim lives in ("<realm path>#<slug>")
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
	// Invoke runs an operation a release defines beyond this interface.
	Invoke(_ int, rlm realm, caller address, method, args string) string
	Render(_ int, rlm realm, path string) string
}

var (
	proxy    *upgradeable.Proxy
	selfPath string
	records  = bptree.NewBPTree32() // disputeKey -> *Record
	notes    = bptree.NewBPTree32() // kind+id+key -> string: release-defined data
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

// Crank advances a dispute's mirror. Anyone; the notifier bot runs it hourly.
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

// NewestRecords returns up to count records (at most 100), newest dispute
// first, after skipping offset of them.
func NewestRecords(offset, count int) []*Record {
	if count > 100 {
		count = 100
	}
	out := []*Record{}
	if offset < 0 || count <= 0 {
		return out
	}
	records.ReverseIterateByOffset(offset, count, func(_ string, v any) bool {
		out = append(out, v.(*Record))
		return false
	})
	return out
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

// Store hands out a StateRef to the live implementation (the calls it makes
// run under this realm's cur, so the StateRef is this realm's own).
func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("kourt: realm value is not the caller's live cur")
	}
	if caller := rlm.PkgPath(); caller != selfPath {
		panic("kourt: state is reachable only through " + selfPath + ", not from " + caller)
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

// NewRecord starts a mirror record for a dispute in the release's binding.
func (r *StateRef) NewRecord(disputeID uint64, binding, title string) *Record {
	r.check()
	if GetRecord(disputeID) != nil {
		panic("kourt: record exists")
	}
	rec := &Record{Dispute: disputeID, Binding: binding, State: StatePending, Title: title}
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
	case StateSettled, StateConfirmed, StateDissent, StateAbandoned:
		rec.SettledAt = at
		rec.Verdict = verdict
		rec.Route = route
	}
	emit("KourtRecord", "dispute", strconv.FormatUint(disputeID, 10), "state", state, "claim", strconv.FormatUint(rec.ClaimID, 10))
	if state == StateDissent {
		emit("KourtDissent", "dispute", strconv.FormatUint(disputeID, 10), "claim", strconv.FormatUint(rec.ClaimID, 10))
	}

}

// Abandon closes a record the current release cannot advance, typically one
// filed under a previous binding (a release closes the claims that die on
// its own court by itself). Authority only; the court coin staked on it
// stays where Kourt left it.
func Abandon(cur realm, disputeID uint64, reason string) {
	proxy.AssertAuthorized(0, cur)
	rec := GetRecord(disputeID)
	if rec == nil {
		panic("kourt: unknown record")
	}
	switch rec.State {
	case StateSettled, StateConfirmed, StateDissent, StateAbandoned:
		panic("kourt: record is already closed")
	}
	rec.State = StateAbandoned
	rec.Route = reason
	rec.Verdict = -1 // no decision recorded
	rec.SettledAt = time.Now().Unix()
	rec.Steps++
	emit("KourtRecord", "dispute", strconv.FormatUint(disputeID, 10), "state", StateAbandoned, "claim", strconv.FormatUint(rec.ClaimID, 10))
}

// SendToTreasury moves GNOT this realm holds (a redeemed float) to the DAO.
// The implementation reports the amount; the permanent realm moves the coins.
func (r *StateRef) SendToTreasury(amount int64) {
	r.check()
	if amount <= 0 {
		panic("kourt: amount must be positive")
	}
	if r.rlm.PkgPath() != selfPath {
		panic("kourt: only the kourt realm may move coins")
	}
	rlm := r.rlm
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), chain.PackageAddress(DAOPath), chain.NewCoins(chain.NewCoin("ugnot", amount)))
	emit("FloatRedeemed", "amount", strconv.FormatInt(amount, 10))
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

// WithdrawImpl removes a pending candidate. Authority only.
func WithdrawImpl(cur realm, pkgPath string) { proxy.Withdraw(0, cur, pkgPath) }

// Forget drops the rollback history. Authority only.
func Forget(cur realm) { proxy.Forget(0, cur) }

// Freeze ends upgradeability. Authority only, and only once a realm (the
// DAO) holds the authority: freezing also fixes the authority for good.
func Freeze(cur realm) {
	proxy.AssertAuthorized(0, cur)
	if !strings.HasPrefix(proxy.Authority().String(), "realms:") {
		panic("kourt: hand the authority to the DAO realm before freezing")
	}
	proxy.Freeze(0, cur)
}

// AuthorityTimelock is the delay between proposing and executing a transfer
// of this realm's authority.
const AuthorityTimelock = int64(7 * 24 * 3600)

type pendingAuthority struct {
	Spec    string
	ReadyAt int64
}

var (
	pendingAuth *pendingAuthority
	attribution = "[built on Kourt](https://kourt.xyz)"
)

// ProposeAuthority starts a two-step, timelocked transfer; a realm authority
// must include the DAO.
func ProposeAuthority(cur realm, spec string) int64 {
	proxy.AssertAuthorized(0, cur)
	if _, err := authspec.Parse(spec); err != nil {
		panic("kourt: " + err.Error())
	}
	if authspec.Kind(spec) != "addr" && !authspec.Grants(spec, DAOPath) {
		panic("kourt: a realm authority must include " + DAOPath)
	}
	readyAt := time.Now().Unix() + AuthorityTimelock
	pendingAuth = &pendingAuthority{Spec: spec, ReadyAt: readyAt}
	emit("AuthorityProposed", "realm", "kourt", "spec", spec, "readyAt", strconv.FormatInt(readyAt, 10))
	return readyAt
}

// ExecuteAuthority applies the pending transfer after its delay; the current
// authority executes it.
func ExecuteAuthority(cur realm) {
	if pendingAuth == nil {
		panic("kourt: no authority transfer is pending")
	}
	if time.Now().Unix() < pendingAuth.ReadyAt {
		panic("kourt: the authority transfer is timelocked until " + strconv.FormatInt(pendingAuth.ReadyAt, 10))
	}
	auth, err := authspec.Parse(pendingAuth.Spec)
	if err != nil {
		panic("kourt: " + err.Error())
	}
	spec := pendingAuth.Spec
	pendingAuth = nil
	proxy.TransferAuthority(0, cur, auth)
	emit("AuthorityTransferred", "realm", "kourt", "authority", spec)
}

// CancelAuthority drops the pending transfer. Authority only.
func CancelAuthority(cur realm) {
	proxy.AssertAuthorized(0, cur)
	if pendingAuth == nil {
		panic("kourt: no authority transfer is pending")
	}
	spec := pendingAuth.Spec
	pendingAuth = nil
	emit("AuthorityCancelled", "realm", "kourt", "spec", spec)
}

// PendingAuthority reports the proposed transfer, or "" and 0.
func PendingAuthority() (spec string, readyAt int64) {
	if pendingAuth == nil {
		return "", 0
	}
	return pendingAuth.Spec, pendingAuth.ReadyAt
}

// SetAttribution changes the notice shown at the top of every page (the
// Kourt licence asks for one; its exact form may be adjusted without a
// release). Authority only.
func SetAttribution(cur realm, text string) {
	proxy.AssertAuthorized(0, cur)
	if len(text) == 0 || len(text) > 512 {
		panic("kourt: attribution must be 1 to 512 bytes")
	}
	attribution = text
}

// Invoke runs an operation the live release defines beyond this API.
func Invoke(cur realm, method, args string) string {
	return live().Invoke(0, cur, cur.Previous().Address(), method, args)
}

// Note returns release-defined data attached to an object, or "".
func Note(kind, id, key string) string {
	v := notes.Get(kind + "\x00" + id + "\x00" + key)
	if v == nil {
		return ""
	}
	return v.(string)
}

// SetNote attaches release-defined data to an object; an empty value removes it.
func (r *StateRef) SetNote(kind, id, key, value string) {
	r.check()
	if kind == "" || key == "" || len(kind) > 32 || len(id) > 64 || len(key) > 64 || len(value) > 4096 {
		panic("kourt: note kind and key must be 1 to 32 and 64 bytes, id at most 64, value at most 4096")
	}
	k := kind + "\x00" + id + "\x00" + key
	if value == "" {
		notes.Remove(k)
		return
	}
	notes.Set(k, value)
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
	// the attribution the Kourt licence asks for lives in the permanent
	// realm, so no release can drop it
	head := attribution + "\n\n"
	if strings.HasPrefix(path, "json") {
		head = "" // machine views stay pure JSON
	}
	if _, ok := proxy.TryImpl(); !ok {
		return head + "# Gnoracle Kourt mirror\n\n_No implementation accepted yet._\n"
	}
	return head + live().Render(0, cur, path)
}
