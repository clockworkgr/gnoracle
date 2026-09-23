package dao

import (
	"chain/runtime"
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/r/clockwork/gnoracle/core"
	"gno.land/r/clockwork/gnoracle/kourt"
	"gno.land/r/clockwork/gnoracle/token"
)

// The primitives below are the only ways value or authority leave this realm.
// They are declared here, on the permanent path, and take the realm's own
// live cur, so an implementation can decide amounts but never obtain a teller
// or a banker of its own.

func selfAddr() address { return chain.PackageAddress(selfPath) }

func pythBalance() int64 { return token.BalanceOf(selfAddr()) }

func ugnotBalance() int64 {
	return banker.NewReadonlyBanker().GetCoin(selfAddr(), FeeDenom)
}

// pullPyth moves amount PYTH from a member who approved this realm.
func (r *StateRef) pullPyth(from address, amount int64) {
	t := token.Token.RealmTeller(0, r.rlm)
	if err := t.TransferFrom(0, r.rlm, from, selfAddr(), amount); err != nil {
		panic("dao: " + err.Error() + " (approve the DAO realm on the token first)")
	}
}

// sendPyth pays PYTH out of the realm.
func (r *StateRef) sendPyth(to address, amount int64) {
	t := token.Token.RealmTeller(0, r.rlm)
	if err := t.Transfer(0, r.rlm, to, amount); err != nil {
		panic("dao: " + err.Error())
	}
}

// mintPyth mints through the token realm (this realm must be its minter).
func (r *StateRef) mintPyth(to address, amount int64) {
	rlm := r.rlm
	token.Mint(cross(rlm), to, amount)
}

// sendUgnot pays coins out of the realm.
func (r *StateRef) sendUgnot(to address, amount int64) {
	if amount <= 0 {
		panic("dao: send needs a positive amount")
	}
	if r.rlm.PkgPath() != selfPath {
		panic("dao: extensions may read and write state but not move coins")
	}
	if amount > ugnotBalance() {
		panic("dao: insufficient realm balance")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, r.rlm)
	b.SendCoins(r.rlm.Address(), to, chain.NewCoins(chain.NewCoin(FeeDenom, amount)))
	if held.KnownUgnot >= amount {
		held.KnownUgnot -= amount
	} else {
		held.KnownUgnot = 0
	}
}

// Health reports the conservation invariants of both ledgers.
func Health() string {
	pyth := pythBalance()
	ugnot := ugnotBalance()
	owedPyth := held.StakedPyth + held.UnbondingPyth + held.RewardPyth
	owedUgnot := held.FeeUgnot + held.RewardUgnot + held.DepositUgnot
	status := "ok"
	if owedPyth > pyth || owedUgnot > ugnot || held.KnownUgnot > ugnot {
		status = "BROKEN"
	}
	return `{"status":"` + status + `","pyth":` + strconv.FormatInt(pyth, 10) +
		`,"owedPyth":` + strconv.FormatInt(owedPyth, 10) +
		`,"treasuryPyth":` + strconv.FormatInt(TreasuryPyth(), 10) +
		`,"ugnot":` + strconv.FormatInt(ugnot, 10) +
		`,"owedUgnot":` + strconv.FormatInt(owedUgnot, 10) +
		`,"treasuryUgnot":` + strconv.FormatInt(TreasuryUgnot(), 10) +
		`,"staked":` + strconv.FormatInt(held.StakedPyth, 10) + `}`
}

// ---- effects on the core realm, executed by passed proposals

// CoreActivateFeed executes a feed-accept proposal.
func (r *StateRef) CoreActivateFeed(feedID uint64) {
	r.check()
	rlm := r.rlm
	core.ActivateFeed(cross(rlm), feedID)
}

// CoreDeprecateFeed executes a feed-deprecate proposal.
func (r *StateRef) CoreDeprecateFeed(feedID uint64, reason string) {
	r.check()
	rlm := r.rlm
	core.DeprecateFeed(cross(rlm), feedID, reason)
}

// CoreUpdateFeed executes a feed-update proposal.
func (r *StateRef) CoreUpdateFeed(feedID uint64, changesJSON string) {
	r.check()
	rlm := r.rlm
	core.UpdateFeed(cross(rlm), feedID, changesJSON)
}

// CoreForceUnbond executes a provider-remove proposal.
func (r *StateRef) CoreForceUnbond(feedID uint64, provider address) {
	r.check()
	rlm := r.rlm
	core.ForceUnbond(cross(rlm), feedID, provider)
}

// CoreSetParam executes a core parameter change.
func (r *StateRef) CoreSetParam(name string, value int64) {
	r.check()
	rlm := r.rlm
	core.SetParam(cross(rlm), name, value)
}

// CoreSetParamStr executes a core string parameter change.
func (r *StateRef) CoreSetParamStr(name, value string) {
	r.check()
	rlm := r.rlm
	core.SetParamStr(cross(rlm), name, value)
}

// CoreSetTrustedRequester executes a trusted-requester proposal.
func (r *StateRef) CoreSetTrustedRequester(path string, cap int64) {
	r.check()
	rlm := r.rlm
	core.SetTrustedRequester(cross(rlm), path, cap)
}

// CoreAccept executes an upgrade-accept proposal on the core realm.
func (r *StateRef) CoreAccept(path string) {
	r.check()
	rlm := r.rlm
	core.Accept(cross(rlm), path)
}

// CoreRollback executes an upgrade-rollback proposal on the core realm.
func (r *StateRef) CoreRollback() {
	r.check()
	rlm := r.rlm
	core.Rollback(cross(rlm))
}

// CoreFreeze executes a freeze proposal on the core realm.
func (r *StateRef) CoreFreeze() {
	r.check()
	rlm := r.rlm
	core.Freeze(cross(rlm))
}

// CoreTransferAuthority executes an authority-transfer proposal on the core
// realm: to this DAO alone (csv empty) or to an address plus realm paths.
func (r *StateRef) CoreTransferAuthority(csvPaths string) {
	r.check()
	rlm := r.rlm
	core.TransferAuthorityToRealms(cross(rlm), csvPaths)
}

// ---- the Kourt mirror realm's releases and authority (proposals)

// KourtAccept executes an upgrade-accept proposal on the mirror realm.
func (r *StateRef) KourtAccept(path string) {
	r.check()
	rlm := r.rlm
	kourt.Accept(cross(rlm), path)
}

// KourtRollback executes an upgrade-rollback proposal on the mirror realm.
func (r *StateRef) KourtRollback() {
	r.check()
	rlm := r.rlm
	kourt.Rollback(cross(rlm))
}

// KourtFreeze executes a freeze proposal on the mirror realm.
func (r *StateRef) KourtFreeze() {
	r.check()
	rlm := r.rlm
	kourt.Freeze(cross(rlm))
}

// KourtTransferAuthority executes an authority-transfer proposal on the
// mirror realm.
func (r *StateRef) KourtTransferAuthority(csvPaths string) {
	r.check()
	rlm := r.rlm
	kourt.TransferAuthorityToRealms(cross(rlm), csvPaths)
}

// KourtAbandon closes a mirror record the current release cannot advance.
func (r *StateRef) KourtAbandon(disputeID uint64, reason string) {
	r.check()
	rlm := r.rlm
	kourt.Abandon(cross(rlm), disputeID, reason)
}

// ---- own-realm parameters and releases

// SetOwnParam changes one of this realm's parameters (a passed proposal).
func (r *StateRef) SetOwnParam(name string, value int64) {
	r.check()
	old, err := registry.SetAt(name, value, runtime.ChainHeight())
	if err != nil {
		panic(err.Error())
	}
	emit("ParamChanged", "name", name, "old", strconv.FormatInt(old, 10), "new", strconv.FormatInt(value, 10))
}

// SetOwnParamStr changes one of this realm's string parameters.
func (r *StateRef) SetOwnParamStr(name, value string) {
	r.check()
	old, err := registry.SetString(name, value)
	if err != nil {
		panic(err.Error())
	}
	emit("ParamChanged", "name", name, "old", old, "new", value)
}

// ExecOwn hands a self-upgrade instruction to the exec trampoline realm,
// which calls back into this realm's proxy as an authorized realm. op is
// "accept", "rollback" or "freeze".
func (r *StateRef) ExecOwn(op, path string) {
	r.check()
	exec := execTrampoline
	if exec == nil {
		panic("dao: the exec trampoline is not registered")
	}
	rlm := r.rlm
	exec.Run(cross(rlm), op, path)
}

// Trampoline is what the dao/exec realm registers so this realm can call it
// without importing it (the exec realm imports this one).
type Trampoline interface {
	Run(cur realm, op, path string)
}

var execTrampoline Trampoline

// RegisterTrampoline is called by the exec realm's init.
func RegisterTrampoline(cur realm, t Trampoline) {
	if !cur.IsCurrent() || cur.Previous().PkgPath() != ExecPath {
		panic("dao: only the exec realm may register the trampoline")
	}
	execTrampoline = t
}
