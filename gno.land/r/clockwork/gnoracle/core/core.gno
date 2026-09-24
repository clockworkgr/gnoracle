// Package core is the permanent realm of the Gnoracle oracle: the path every
// consumer realm imports, the owner of every feed, provider, round, credit
// and dispute record, and the custodian of the GNOT behind them.
//
// Its behaviour is not permanent. Every entry point forwards to the live
// implementation held by an upgradeable proxy; implementations live in realms
// nested under this one (core/impl/v1, ...) and reach the state only through
// Store, a gated accessor that carries this realm's own live cur. State never
// moves between versions and money never leaves except through the primitives
// in money.gno, which are declared here and therefore cannot be upgraded.
//
// Authority: the address in Admin until the DAO realm takes over through
// TransferAuthorityToRealms; the same authority accepts releases, activates
// feeds and changes parameters. See docs/IMPLEMENTATION_PLAN.md §3.2.
package core

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/clockwork/gnoracle/authspec/v0"
	"gno.land/p/clockwork/upgradeable/v0"
)

// Admin is the bootstrap authority. It is the public test1 key so that gnodev
// and the tests work unedited; `make build ADMIN=g1...` rewrites it for a real
// deployment (scripts/deploy.sh).
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

// StakeDenom is the denomination of stakes, bonds, credits and payouts.
const StakeDenom = "ugnot"

var (
	proxy    *upgradeable.Proxy
	selfPath string
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	proxy = upgradeable.New(upgradeable.NewAddrAuthority(Admin))
	defineParams()
}

// Core is the behaviour this realm promises. It is declared here so every
// implementation agrees on one type identity and the contract outlives them
// all. Methods take (_ int, rlm realm): the realm threads its own cur in as
// data, so an implementation calling Store is seen as this realm.
//
// Money never travels as a parameter the implementation controls: entry
// points that receive coins read the amount off the transaction here and hand
// it in as `sent`; the implementation decides what it buys and the store
// records where it went.
type Core interface {
	// Invoke runs an operation a release defines beyond this interface, so
	// new user-facing operations ship as release code (args is release-defined
	// text, usually JSON).
	Invoke(_ int, rlm realm, caller address, userCall bool, sent int64, method, args string) string
	// feeds
	ProposeFeed(_ int, rlm realm, proposer address, callerPkg string, specJSON string, sent int64) uint64
	ActivateFeed(_ int, rlm realm, feedID uint64)
	DeprecateFeed(_ int, rlm realm, feedID uint64, reason string)
	UpdateFeed(_ int, rlm realm, feedID uint64, changesJSON string)
	Sponsor(_ int, rlm realm, sponsor address, feedID uint64, periods int64, sent int64)
	FundBounty(_ int, rlm realm, feedID uint64, sent int64)
	Finalize(_ int, rlm realm, caller address, feedID, roundID uint64)
	CatchUp(_ int, rlm realm, caller address, feedID uint64, maxRounds int64) int64
	PruneRounds(_ int, rlm realm, caller address, feedID uint64, maxRounds int64) int64
	PruneFeed(_ int, rlm realm, caller address, feedID uint64)
	ReopenOneOff(_ int, rlm realm, caller address, feedID uint64, resolveAt int64)
	// providers
	Register(_ int, rlm realm, provider address, feedID uint64, memo string, sent int64)
	TopUp(_ int, rlm realm, provider address, feedID uint64, sent int64)
	Submit(_ int, rlm realm, provider address, feedID, roundID uint64, value int64)
	RequestUnbond(_ int, rlm realm, provider address, feedID uint64)
	Withdraw(_ int, rlm realm, provider address, feedID uint64) int64
	Unjail(_ int, rlm realm, provider address, feedID uint64)
	ClaimRewards(_ int, rlm realm, provider address, feedID uint64) int64
	ForceUnbond(_ int, rlm realm, feedID uint64, provider address)
	// consumers
	DepositFor(_ int, rlm realm, account address, sent int64)
	WithdrawCredit(_ int, rlm realm, account address, amount int64)
	SubscribeRealm(_ int, rlm realm, payer address, payerPkg string, feedID uint64, pkgPath string, periods int64, sent int64)
	Read(_ int, rlm realm, caller address, callerPkg string, feedID uint64) (value int64, decimals int64, roundID uint64, updatedAt int64, tier string)
	ReadFinal(_ int, rlm realm, caller address, callerPkg string, feedID uint64) (value int64, decimals int64, roundID uint64, finalisedAt int64, tier string)
	ReadRound(_ int, rlm realm, caller address, callerPkg string, feedID, roundID uint64) (value int64, tier string, finalisedAt int64)
	// disputes (plan §7)
	Dispute(_ int, rlm realm, disputer address, feedID, roundID uint64, proposedValue int64, tier, evidence string, sent int64) uint64
	Appeal(_ int, rlm realm, appellant address, disputeID uint64, sent int64)
	ResolveDispute(_ int, rlm realm, caller address, disputeID uint64)
	// rendering
	Render(_ int, rlm realm, path string) string
}

// ---------------------------------------------------------------- feeds ----

// ProposeFeed submits a feed spec (JSON, see p/clockwork/gnoracle/spec) with
// the feed deposit and the first subscription period or the one-off bounty
// attached as -send. A trusted requester realm cannot attach coins; its
// bounty is taken from its credit balance instead.
func ProposeFeed(cur realm, specJSON string) uint64 {
	prev := cur.Previous()
	sent := int64(0)
	if prev.IsUserCall() {
		sent = unsafe.OriginSend().AmountOf(StakeDenom)
	}
	return live().ProposeFeed(0, cur, prev.Address(), prev.PkgPath(), specJSON, sent)
}

// ActivateFeed accepts a proposed feed. Authority only (the DAO executing a
// feed-accept proposal, or the admin during bootstrap).
func ActivateFeed(cur realm, feedID uint64) {
	proxy.AssertAuthorized(0, cur)
	live().ActivateFeed(0, cur, feedID)
}

// DeprecateFeed retires a feed. Authority only.
func DeprecateFeed(cur realm, feedID uint64, reason string) {
	proxy.AssertAuthorized(0, cur)
	live().DeprecateFeed(0, cur, feedID, reason)
}

// UpdateFeed changes a feed's economic fields (a JSON object of the fields to
// change; the spec text is never edited). Authority only.
func UpdateFeed(cur realm, feedID uint64, changesJSON string) {
	proxy.AssertAuthorized(0, cur)
	live().UpdateFeed(0, cur, feedID, changesJSON)
}

// Sponsor pays periods x subscriptionPrice into a feed's pool (-send) so the
// feed stays funded; anyone may, several may for the same feed.
func Sponsor(cur realm, feedID uint64, periods int64) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: Sponsor takes coins and must be called directly by an account")
	}
	live().Sponsor(0, cur, prev.Address(), feedID, periods, unsafe.OriginSend().AmountOf(StakeDenom))
}

// FundBounty adds -send to a one-off feed's bounty.
func FundBounty(cur realm, feedID uint64) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: FundBounty takes coins and must be called directly by an account")
	}
	live().FundBounty(0, cur, feedID, unsafe.OriginSend().AmountOf(StakeDenom))
}

// Finalize closes a round once its submission window has passed (or once
// every active provider has submitted). Anyone; the caller earns the cranker
// tip and the alerter share of miss penalties.
func Finalize(cur realm, feedID, roundID uint64) {
	live().Finalize(0, cur, cur.Previous().Address(), feedID, roundID)
}

// CatchUp writes off up to maxRounds stale rounds of a feed nobody finalised.
func CatchUp(cur realm, feedID uint64, maxRounds int64) int64 {
	return live().CatchUp(0, cur, cur.Previous().Address(), feedID, maxRounds)
}

// PruneRounds deletes up to maxRounds settled rounds past retention; the
// storage refund goes to the caller's transaction.
func PruneRounds(cur realm, feedID uint64, maxRounds int64) int64 {
	return live().PruneRounds(0, cur, cur.Previous().Address(), feedID, maxRounds)
}

// PruneFeed deletes a deprecated feed once its rounds are gone.
func PruneFeed(cur realm, feedID uint64) {
	live().PruneFeed(0, cur, cur.Previous().Address(), feedID)
}

// ReopenOneOff gives a voided one-off feed a new resolve time (requester only,
// once).
func ReopenOneOff(cur realm, feedID uint64, resolveAt int64) {
	live().ReopenOneOff(0, cur, cur.Previous().Address(), feedID, resolveAt)
}

// ------------------------------------------------------------ providers ----

// Register bonds the caller as a provider of a feed with -send as stake.
func Register(cur realm, feedID uint64, memo string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: Register takes coins and must be called directly by an account")
	}
	live().Register(0, cur, prev.Address(), feedID, memo, unsafe.OriginSend().AmountOf(StakeDenom))
}

// TopUp adds -send to the caller's stake on a feed.
func TopUp(cur realm, feedID uint64) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: TopUp takes coins and must be called directly by an account")
	}
	live().TopUp(0, cur, prev.Address(), feedID, unsafe.OriginSend().AmountOf(StakeDenom))
}

// Submit records the caller's value for an open round.
func Submit(cur realm, feedID, roundID uint64, value int64) {
	live().Submit(0, cur, cur.Previous().Address(), feedID, roundID, value)
}

// RequestUnbond leaves the active set and starts the unbonding clock.
func RequestUnbond(cur realm, feedID uint64) {
	live().RequestUnbond(0, cur, cur.Previous().Address(), feedID)
}

// Withdraw pays out unbonded stake once the period has passed.
func Withdraw(cur realm, feedID uint64) int64 {
	return live().Withdraw(0, cur, cur.Previous().Address(), feedID)
}

// Unjail returns a jailed provider to the active set after the cooldown.
func Unjail(cur realm, feedID uint64) {
	live().Unjail(0, cur, cur.Previous().Address(), feedID)
}

// ClaimRewards pays the caller's accrued rewards on a feed.
func ClaimRewards(cur realm, feedID uint64) int64 {
	return live().ClaimRewards(0, cur, cur.Previous().Address(), feedID)
}

// ForceUnbond ejects a provider. Authority only.
func ForceUnbond(cur realm, feedID uint64, provider address) {
	proxy.AssertAuthorized(0, cur)
	live().ForceUnbond(0, cur, feedID, provider)
}

// ------------------------------------------------------------ consumers ----

// DepositFor adds -send to an account's prepaid balance on the core. A realm
// cannot attach coins to its own calls, so a realm that requests feeds or
// subscribes is funded this way by its operator; refunds owed to a realm land
// in the same balance. Reads never touch it.
func DepositFor(cur realm, account address) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: DepositFor takes coins and must be called directly by an account")
	}
	live().DepositFor(0, cur, account, unsafe.OriginSend().AmountOf(StakeDenom))
}

// WithdrawCredit returns unspent prepaid balance to the caller.
func WithdrawCredit(cur realm, amount int64) {
	live().WithdrawCredit(0, cur, cur.Previous().Address(), amount)
}

// SubscribeRealm pays periods (1 to 12) of a feed's subscriberPrice for the
// realm at pkgPath, which may then Read the feed until the paid time ends.
// An account pays with -send for any realm; a realm caller pays from its
// prepaid balance. Sponsored feeds and one-off outcomes need no
// subscription, nor does a feed's own realm requester.
func SubscribeRealm(cur realm, feedID uint64, pkgPath string, periods int64) {
	prev := cur.Previous()
	live().SubscribeRealm(0, cur, prev.Address(), prev.PkgPath(), feedID, pkgPath, periods, unsafe.OriginSend().AmountOf(StakeDenom))
}

// Read returns the latest served value of a feed to a subscribed realm. It
// is a crossing call so the reader is known, changes no state and costs
// nothing per call. tier is consensus, provisional, final, disputed, stale
// or none, with ",unfunded" appended while the feed's pool is empty. People
// and off-chain readers use the pages and the :json views, which show every
// value: what a subscription buys is the right to use a value inside a
// realm's own logic.
func Read(cur realm, feedID uint64) (value int64, decimals int64, roundID uint64, updatedAt int64, tier string) {
	prev := cur.Previous()
	return live().Read(0, cur, prev.Address(), prev.PkgPath(), feedID)
}

// ReadFinal returns the latest final round of a feed to a subscribed realm,
// whatever the state of later rounds.
func ReadFinal(cur realm, feedID uint64) (value int64, decimals int64, roundID uint64, finalisedAt int64, tier string) {
	prev := cur.Previous()
	return live().ReadFinal(0, cur, prev.Address(), prev.PkgPath(), feedID)
}

// ReadRound returns one specific round to a subscribed realm.
func ReadRound(cur realm, feedID, roundID uint64) (value int64, tier string, finalisedAt int64) {
	prev := cur.Previous()
	return live().ReadRound(0, cur, prev.Address(), prev.PkgPath(), feedID, roundID)
}

// ------------------------------------------------------------- disputes ----

// Dispute challenges a round with a bond (-send), a proposed value and a
// slash tier ("minor" or "major").
func Dispute(cur realm, feedID, roundID uint64, proposedValue int64, tier, evidence string) uint64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: Dispute takes coins and must be called directly by an account")
	}
	return live().Dispute(0, cur, prev.Address(), feedID, roundID, proposedValue, tier, evidence, unsafe.OriginSend().AmountOf(StakeDenom))
}

// Appeal forces a second ballot round with a doubled bond (-send).
func Appeal(cur realm, disputeID uint64) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("core: Appeal takes coins and must be called directly by an account")
	}
	live().Appeal(0, cur, prev.Address(), disputeID, unsafe.OriginSend().AmountOf(StakeDenom))
}

// ResolveDispute applies the DAO's verdict once the ballot has closed. Anyone.
func ResolveDispute(cur realm, disputeID uint64) {
	live().ResolveDispute(0, cur, cur.Previous().Address(), disputeID)
}

// ---------------------------------------------------------- parameters ----

// SetParam changes an integer parameter within its bounds and rate limit.
// Authority only.
func SetParam(cur realm, name string, value int64) {
	proxy.AssertAuthorized(0, cur)
	old, err := registry.SetAt(name, value, runtime.ChainHeight())
	if err != nil {
		panic(err.Error())
	}
	emit("ParamChanged", "name", name, "old", strconv.FormatInt(old, 10), "new", strconv.FormatInt(value, 10))
}

// SetTrustedRequester allows (cap > 0) or removes (cap == 0) a realm whose
// one-off feeds activate without a vote while under cap. Authority only.
func SetTrustedRequester(cur realm, pkgPath string, cap int64) {
	proxy.AssertAuthorized(0, cur)
	setTrusted(pkgPath, cap)
}

// ------------------------------------------------------------- proxy ----

// Register records the calling realm as a candidate implementation. An
// implementation realm calls it from its own init.
func RegisterImpl(cur realm, impl Core) { proxy.Propose(0, cur, impl) }

// Accept makes the candidate at pkgPath live. Authority only.
func Accept(cur realm, pkgPath string) {
	proxy.Accept(0, cur, pkgPath)
	emit("ReleaseAccepted", "path", pkgPath)
}

// Withdraw drops a candidate. Authority, or the candidate realm itself.
func WithdrawImpl(cur realm, pkgPath string) { proxy.Withdraw(0, cur, pkgPath) }

// Rollback restores the previous release. Authority only.
func Rollback(cur realm) {
	proxy.Rollback(0, cur)
	emit("ReleaseRolledBack", "path", proxy.LivePath())
}

// Forget drops the rollback history. Authority only.
func Forget(cur realm) { proxy.Forget(0, cur) }

// Freeze ends upgradeability for good. Authority only.
// Freezing also fixes the authority for good, and the same authority governs
// parameters, activations and ejections, so it refuses while a key still
// holds it: hand over to the DAO first.
func Freeze(cur realm) {
	proxy.AssertAuthorized(0, cur)
	if !strings.HasPrefix(proxy.Authority().String(), "realms:") {
		panic("core: hand the authority to the DAO realm before freezing")
	}
	proxy.Freeze(0, cur)
	emit("Frozen")
}

// AuthorityTimelock is the delay between proposing and executing an
// authority transfer. It is a constant, not a parameter, so whoever holds the
// authority cannot shorten it before a transfer.
const AuthorityTimelock = int64(7 * 24 * 3600)

type pendingAuthority struct {
	Spec    string
	ReadyAt int64
}

var pendingAuth *pendingAuthority

// ProposeAuthority starts a two-step, timelocked transfer of this realm's
// authority to the authority spec describes (authspec: `addr:<address>`,
// `realms:<paths>`, `anyof:<address>|<paths>`). Any spec that names realms
// must include the DAO, so a typo cannot leave the realm ungoverned. The
// pending transfer is public and cancellable until it is executed.
func ProposeAuthority(cur realm, spec string) int64 {
	proxy.AssertAuthorized(0, cur)
	if _, err := authspec.Parse(spec); err != nil {
		panic("core: " + err.Error())
	}
	if authspec.Kind(spec) != "addr" && !authspec.Grants(spec, DAOPath) {
		panic("core: a realm authority must include " + DAOPath)
	}
	readyAt := Now() + AuthorityTimelock
	pendingAuth = &pendingAuthority{Spec: spec, ReadyAt: readyAt}
	emit("AuthorityProposed", "spec", spec, "readyAt", strconv.FormatInt(readyAt, 10))
	return readyAt
}

// ExecuteAuthority applies the pending transfer once its delay has passed.
// The current authority executes it (the proxy admits nobody else), which
// for the DAO means a second proposal.
func ExecuteAuthority(cur realm) {
	if pendingAuth == nil {
		panic("core: no authority transfer is pending")
	}
	if Now() < pendingAuth.ReadyAt {
		panic("core: the authority transfer is timelocked until " + strconv.FormatInt(pendingAuth.ReadyAt, 10))
	}
	auth, err := authspec.Parse(pendingAuth.Spec)
	if err != nil {
		panic("core: " + err.Error())
	}
	spec := pendingAuth.Spec
	pendingAuth = nil
	proxy.TransferAuthority(0, cur, auth)
	emit("AuthorityTransferred", "authority", spec)
}

// CancelAuthority drops the pending transfer. Authority only.
func CancelAuthority(cur realm) {
	proxy.AssertAuthorized(0, cur)
	if pendingAuth == nil {
		panic("core: no authority transfer is pending")
	}
	spec := pendingAuth.Spec
	pendingAuth = nil
	emit("AuthorityCancelled", "spec", spec)
}

// PendingAuthority reports the proposed transfer, or "" and 0.
func PendingAuthority() (spec string, readyAt int64) {
	if pendingAuth == nil {
		return "", 0
	}
	return pendingAuth.Spec, pendingAuth.ReadyAt
}

// Invoke runs an operation the live release defines beyond this API (plan
// §3.2): the release decides what method and args mean and what it costs.
func Invoke(cur realm, method, args string) string {
	prev := cur.Previous()
	sent := int64(0)
	if prev.IsUserCall() {
		sent = unsafe.OriginSend().AmountOf(StakeDenom)
	}
	return live().Invoke(0, cur, prev.Address(), prev.IsUserCall(), sent, method, args)
}

// LiveImpl returns the live implementation as an untyped value, the hook
// that lets extension realms grow the API.
func LiveImpl() any {
	v, ok := proxy.TryImpl()
	if !ok {
		return nil
	}
	return v
}

// LivePath is the realm path of the implementation currently serving.
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

// Authority describes who may upgrade and govern.
func Authority() string { return proxy.Authority().String() }

// SelfPath is this realm's package path.
func SelfPath() string { return selfPath }

func live() Core {
	v, ok := proxy.TryImpl()
	if !ok {
		panic("core: no implementation has been accepted yet")
	}
	c, ok := v.(Core)
	if !ok {
		panic("core: live implementation does not satisfy Core")
	}
	return c
}

// Render delegates to the live implementation under a permanent header.
func Render(cur realm, path string) string {
	var b strings.Builder
	if path == "releases" {
		b.WriteString("# Gnoracle core: releases\n\n")
		b.WriteString("Serving: `" + proxy.LivePath() + "`\n\n")
		b.WriteString("Authority: `" + proxy.Authority().String() + "`\n\n")
		if proxy.Frozen() {
			b.WriteString("**Frozen.**\n\n")
		}
		if pendingAuth != nil {
			b.WriteString("Pending authority transfer: `" + pendingAuth.Spec + "` executable from " + strconv.FormatInt(pendingAuth.ReadyAt, 10) + "\n\n")
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
		return "# Gnoracle core\n\n_No implementation accepted yet._ See `:releases`.\n"
	}
	return live().Render(0, cur, path)
}
