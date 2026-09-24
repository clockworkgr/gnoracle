// Package dao is the permanent realm of the Gnoracle DAO: staked PYTH,
// checkpointed voting power, governance proposals, the dispute ballots the
// oracle's disputes are decided by, and the treasury.
//
// Like the core realm it is a permanent path whose behaviour lives in nested
// implementation realms behind an upgradeable proxy. State, the token and
// coin primitives, and the effects a proposal may have on the core realm are
// declared here and cannot be upgraded; what a proposal kind means, how a
// ballot is tallied and how penalties are computed live in the
// implementation.
//
// Self-governance: the DAO's own proxy is authorized by the deployer during
// bootstrap and by the dao/exec trampoline realm afterwards, so a passed
// proposal can accept a release of this realm without a privileged key.
package dao

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/clockwork/gnoracle/authspec/v0"
	"gno.land/p/clockwork/upgradeable/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// Admin is the bootstrap authority (the public test1 key for gnodev;
// rewritten by `make build ADMIN=g1...`).
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

// Paths of the sibling realms this one acts on.
const (
	CorePath  = "gno.land/r/clockwork/gnoracle/core"
	TokenPath = "gno.land/r/clockwork/gnoracle/token"
	ExecPath  = "gno.land/r/clockwork/gnoracle/dao/exec"
)

// FeeDenom is the denomination fees arrive in.
const FeeDenom = "ugnot"

var (
	proxy    *upgradeable.Proxy
	selfPath string
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	proxy = upgradeable.New(upgradeable.NewAnyOf(
		upgradeable.NewAddrAuthority(Admin),
		upgradeable.NewRealmAuthority(ExecPath),
	))
	defineParams()
	core.RegisterDAO(cross(cur), hooks{})
}

// hooks is what this realm registers with the core as its ballot house. The
// methods are crossing, so the core is the caller the entry points gate on.
type hooks struct{}

func (hooks) OpenDisputeVote(cur realm, disputeID uint64, majorRequested bool, summary string) uint64 {
	return OpenDisputeVote(cur, disputeID, majorRequested, summary)
}

func (hooks) FinishDisputeVote(cur realm, disputeID uint64) (string, string, int64) {
	return FinishDisputeVote(cur, disputeID)
}

func (hooks) OpenAppealRound(cur realm, disputeID uint64) uint64 {
	return OpenAppealRound(cur, disputeID)
}

func (hooks) FundVoters(cur realm, disputeID uint64, amount int64) {
	FundVoters(cur, disputeID, amount)
}

// Hooks returns the ballot house object, for tests that stand in for init.
func Hooks() core.BallotHouse { return hooks{} }

// DAO is the behaviour this realm promises to its implementations.
type DAO interface {
	// Invoke runs an operation a release defines beyond this interface.
	Invoke(_ int, rlm realm, caller address, userCall bool, sent int64, method, args string) string
	// membership
	Stake(_ int, rlm realm, member address, amount int64)
	RequestUnstake(_ int, rlm realm, member address, amount int64)
	Withdraw(_ int, rlm realm, member address) int64
	SettleMember(_ int, rlm realm, member address, maxN int64) int64
	ClaimFees(_ int, rlm realm, member address) int64
	ClaimRewards(_ int, rlm realm, member address) (pyth int64, ugnot int64)
	SyncFees(_ int, rlm realm) int64
	// governance
	Propose(_ int, rlm realm, proposer address, kind, payload, title string, sent int64) uint64
	Vote(_ int, rlm realm, voter address, proposalID uint64, choice string)
	Execute(_ int, rlm realm, caller address, proposalID uint64)
	Cancel(_ int, rlm realm, caller address, proposalID uint64)
	// dispute ballots
	OpenDisputeVote(_ int, rlm realm, disputeID uint64, majorRequested bool, summary string) uint64
	CommitVote(_ int, rlm realm, voter address, disputeID uint64, commitment string)
	RevealVote(_ int, rlm realm, voter address, disputeID uint64, choice, salt string)
	FinishDisputeVote(_ int, rlm realm, disputeID uint64) (outcome, tier string, coherentWeight int64)
	OpenAppealRound(_ int, rlm realm, disputeID uint64) uint64
	FundVoters(_ int, rlm realm, disputeID uint64, amount int64)
	// rendering
	Render(_ int, rlm realm, path string) string
}

// ------------------------------------------------------------ members ----

// Stake pulls amount PYTH the caller approved to this realm and stakes it.
func Stake(cur realm, amount int64) { live().Stake(0, cur, cur.Previous().Address(), amount) }

// RequestUnstake starts the cooldown on amount of the caller's stake.
func RequestUnstake(cur realm, amount int64) {
	live().RequestUnstake(0, cur, cur.Previous().Address(), amount)
}

// Withdraw pays out unstaked PYTH whose cooldown has passed.
func Withdraw(cur realm) int64 { return live().Withdraw(0, cur, cur.Previous().Address()) }

// SettleMember processes up to maxN resolved disputes for a member. Anyone.
func SettleMember(cur realm, member address, maxN int64) int64 {
	return live().SettleMember(0, cur, member, maxN)
}

// ClaimFees pays the caller's share of protocol fees.
func ClaimFees(cur realm) int64 { return live().ClaimFees(0, cur, cur.Previous().Address()) }

// ClaimRewards pays the caller's dispute rewards.
func ClaimRewards(cur realm) (int64, int64) {
	return live().ClaimRewards(0, cur, cur.Previous().Address())
}

// SyncFees attributes coins that arrived from the core since the last sync
// to stakers and the treasury. Anyone.
func SyncFees(cur realm) int64 { return live().SyncFees(0, cur) }

// --------------------------------------------------------- governance ----

// Propose opens a proposal of a kind with a string payload. A proposer below
// the stake bar attaches the proposal deposit as -send.
func Propose(cur realm, kind, payload, title string) uint64 {
	prev := cur.Previous()
	sent := int64(0)
	if prev.IsUserCall() {
		sent = originSend()
	}
	return live().Propose(0, cur, prev.Address(), kind, payload, title, sent)
}

// Vote casts YES, NO or ABSTAIN with the caller's sealed voting weight.
func Vote(cur realm, proposalID uint64, choice string) {
	live().Vote(0, cur, cur.Previous().Address(), proposalID, choice)
}

// Execute applies a passed proposal after its timelock. Anyone.
func Execute(cur realm, proposalID uint64) {
	live().Execute(0, cur, cur.Previous().Address(), proposalID)
}

// Cancel withdraws the caller's own proposal before voting ends.
func Cancel(cur realm, proposalID uint64) {
	live().Cancel(0, cur, cur.Previous().Address(), proposalID)
}

// ----------------------------------------------------------- disputes ----

// OpenDisputeVote seals a ballot for a dispute. Core only.
func OpenDisputeVote(cur realm, disputeID uint64, majorRequested bool, summary string) uint64 {
	assertCore(cur)
	return live().OpenDisputeVote(0, cur, disputeID, majorRequested, summary)
}

// CommitVote posts a commitment for a dispute ballot.
func CommitVote(cur realm, disputeID uint64, commitment string) {
	live().CommitVote(0, cur, cur.Previous().Address(), disputeID, commitment)
}

// RevealVote reveals a committed choice.
func RevealVote(cur realm, disputeID uint64, choice, salt string) {
	live().RevealVote(0, cur, cur.Previous().Address(), disputeID, choice, salt)
}

// FinishDisputeVote closes a ballot and returns its outcome. Core only.
func FinishDisputeVote(cur realm, disputeID uint64) (string, string, int64) {
	assertCore(cur)
	return live().FinishDisputeVote(0, cur, disputeID)
}

// OpenAppealRound runs a second ballot round for a dispute. Core only.
func OpenAppealRound(cur realm, disputeID uint64) uint64 {
	assertCore(cur)
	return live().OpenAppealRound(0, cur, disputeID)
}

// FundVoters records coins the core sent for a dispute's coherent voters.
// Core only.
func FundVoters(cur realm, disputeID uint64, amount int64) {
	assertCore(cur)
	live().FundVoters(0, cur, disputeID, amount)
}

func assertCore(cur realm) {
	if !cur.IsCurrent() || cur.Previous().PkgPath() != CorePath {
		panic("dao: only the core realm may call this")
	}
}

// -------------------------------------------------------------- proxy ----

// RegisterImpl records the calling realm as a candidate implementation.
func RegisterImpl(cur realm, impl DAO) { proxy.Propose(0, cur, impl) }

// Accept makes the candidate at pkgPath live. Authority only.
func Accept(cur realm, pkgPath string) {
	proxy.Accept(0, cur, pkgPath)
	emit("ReleaseAccepted", "realm", "dao", "path", pkgPath)
}

// Rollback restores the previous release. Authority only.
func Rollback(cur realm) {
	proxy.Rollback(0, cur)
	emit("ReleaseRolledBack", "realm", "dao", "path", proxy.LivePath())
}

// WithdrawImpl drops a candidate. Authority, or the candidate realm itself.
func WithdrawImpl(cur realm, pkgPath string) { proxy.Withdraw(0, cur, pkgPath) }

// Forget drops the rollback history. Authority only.
func Forget(cur realm) { proxy.Forget(0, cur) }

// Freeze ends upgradeability for good. Authority only.
func Freeze(cur realm) {
	proxy.AssertAuthorized(0, cur)
	if !strings.HasPrefix(proxy.Authority().String(), "realms:") {
		panic("dao: hand the authority to the exec trampoline (an `authority-transfer dao realms:" + ExecPath + "` proposal) before freezing")
	}
	proxy.Freeze(0, cur)
	emit("Frozen", "realm", "dao")
}

// DevSetParam changes one of the DAO's own parameters directly, within its
// bounds and rate limit. Development chains only (chain id "dev"): on any
// other chain the DAO's parameters change by `param` proposal alone and this
// entry point refuses, whoever calls it. Authority only.
func DevSetParam(cur realm, name string, value int64) {
	if id := runtime.ChainID(); id != "dev" {
		panic("dao: parameters change by proposal; DevSetParam works on development chains only (this chain is " + strconv.Quote(id) + ")")
	}
	proxy.AssertAuthorized(0, cur)
	old, err := registry.SetAt(name, value, runtime.ChainHeight())
	if err != nil {
		panic(err.Error())
	}
	emit("ParamChanged", "name", name, "old", strconv.FormatInt(old, 10), "new", strconv.FormatInt(value, 10))
}

// AuthorityTimelock is the delay between proposing and executing a transfer
// of this realm's authority (a constant, so the authority cannot shorten it).
const AuthorityTimelock = int64(7 * 24 * 3600)

type pendingAuthority struct {
	Spec    string
	ReadyAt int64
}

var pendingAuth *pendingAuthority

// ProposeAuthority starts a two-step, timelocked transfer of the DAO's own
// authority. Every spec must grant the exec trampoline, or the DAO could no
// longer act on itself; the guardian key is dropped with
// `realms:<exec path>`.
func ProposeAuthority(cur realm, spec string) int64 {
	proxy.AssertAuthorized(0, cur)
	if _, err := authspec.Parse(spec); err != nil {
		panic("dao: " + err.Error())
	}
	if !authspec.Grants(spec, ExecPath) {
		panic("dao: the authority must include " + ExecPath)
	}
	readyAt := Now() + AuthorityTimelock
	pendingAuth = &pendingAuthority{Spec: spec, ReadyAt: readyAt}
	emit("AuthorityProposed", "realm", "dao", "spec", spec, "readyAt", strconv.FormatInt(readyAt, 10))
	return readyAt
}

// ExecuteAuthority applies the pending transfer after its delay; the current
// authority executes it.
func ExecuteAuthority(cur realm) {
	if pendingAuth == nil {
		panic("dao: no authority transfer is pending")
	}
	if Now() < pendingAuth.ReadyAt {
		panic("dao: the authority transfer is timelocked until " + strconv.FormatInt(pendingAuth.ReadyAt, 10))
	}
	auth, err := authspec.Parse(pendingAuth.Spec)
	if err != nil {
		panic("dao: " + err.Error())
	}
	spec := pendingAuth.Spec
	pendingAuth = nil
	proxy.TransferAuthority(0, cur, auth)
	emit("AuthorityTransferred", "realm", "dao", "authority", spec)
}

// CancelAuthority drops the pending transfer. Authority only.
func CancelAuthority(cur realm) {
	proxy.AssertAuthorized(0, cur)
	if pendingAuth == nil {
		panic("dao: no authority transfer is pending")
	}
	spec := pendingAuth.Spec
	pendingAuth = nil
	emit("AuthorityCancelled", "realm", "dao", "spec", spec)
}

// PendingAuthority reports the proposed transfer, or "" and 0.
func PendingAuthority() (spec string, readyAt int64) {
	if pendingAuth == nil {
		return "", 0
	}
	return pendingAuth.Spec, pendingAuth.ReadyAt
}

// Invoke runs an operation the live release defines beyond this API.
func Invoke(cur realm, method, args string) string {
	prev := cur.Previous()
	sent := int64(0)
	if prev.IsUserCall() {
		sent = originSend()
	}
	return live().Invoke(0, cur, prev.Address(), prev.IsUserCall(), sent, method, args)
}

// LiveImpl returns the live implementation as an untyped value.
func LiveImpl() any {
	v, ok := proxy.TryImpl()
	if !ok {
		return nil
	}
	return v
}

// LivePath is the path of the implementation currently serving.
func LivePath() string { return proxy.LivePath() }

// PendingPaths lists candidates awaiting acceptance.
func PendingPaths() []string {
	out := []string{}
	for _, r := range proxy.Pending() {
		out = append(out, r.PkgPath())
	}
	return out
}

// HistoryPaths lists previously served implementations, oldest first.
func HistoryPaths() []string {
	out := []string{}
	for _, r := range proxy.History() {
		out = append(out, r.PkgPath())
	}
	return out
}

// Frozen reports whether upgradeability has ended.
func Frozen() bool { return proxy.Frozen() }

// Authority describes who may upgrade.
func Authority() string { return proxy.Authority().String() }

// SelfPath is this realm's package path.
func SelfPath() string { return selfPath }

// Address is this realm's account address (the token spender to approve).
func Address() address { return selfAddr() }

func live() DAO {
	v, ok := proxy.TryImpl()
	if !ok {
		panic("dao: no implementation has been accepted yet")
	}
	d, ok := v.(DAO)
	if !ok {
		panic("dao: live implementation does not satisfy DAO")
	}
	return d
}

// Render delegates to the live implementation under a permanent header.
func Render(cur realm, path string) string {
	if path == "releases" {
		var b strings.Builder
		b.WriteString("# Gnoracle DAO: releases\n\n")
		b.WriteString("Serving: `" + proxy.LivePath() + "`\n\nAuthority: `" + proxy.Authority().String() + "`\n\n")
		if proxy.Frozen() {
			b.WriteString("**Frozen.**\n\n")
		}
		if pending := proxy.Pending(); len(pending) > 0 {
			b.WriteString("Awaiting acceptance:\n\n")
			for _, r := range pending {
				b.WriteString("- `" + r.PkgPath() + "` (registered at height " + strconv.FormatInt(r.Height(), 10) + ")\n")
			}
			b.WriteString("\n")
		}
		if past := proxy.History(); len(past) > 0 {
			b.WriteString("Previously:\n\n")
			for _, r := range past {
				b.WriteString("- `" + r.PkgPath() + "`\n")
			}
			b.WriteString("\n")
		}
		b.WriteString("## Parameters\n\n" + registry.Markdown())
		return b.String()
	}
	if _, ok := proxy.TryImpl(); !ok {
		return "# Gnoracle DAO\n\n_No implementation accepted yet._ See `:releases`.\n"
	}
	return live().Render(0, cur, path)
}
