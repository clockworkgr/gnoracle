package core

import (
	"chain"
	"chain/banker"
	"strconv"
)

// held tracks what the realm's coin balance is made of. Every StateRef
// mutator that moves value updates these categories, so Health can compare
// their sum with the actual balance: the conservation invariant of the plan
// (§10.2). An implementation can misjudge who gets what; it cannot make the
// categories exceed the balance, because the only way out is send, declared
// here, which is called only after a category has been reduced.
type holdings struct {
	Stakes      int64 // active and jailed provider stakes
	Unbonding   int64 // stakes waiting out the unbond period
	Credits     int64 // consumer prepaid balances
	Pools       int64 // feed pools, accrued fees and penalty carry
	Rewards     int64 // provider rewards accrued and unclaimed
	Bonds       int64 // dispute and appeal bonds held
	FeesPending int64 // staker and treasury shares awaiting forward to the DAO
	Deposits    int64 // feed proposal deposits
}

var held holdings

// Held returns the current category totals.
func Held() (stakes, unbonding, credits, pools, rewards, bonds, feesPending, deposits int64) {
	return held.Stakes, held.Unbonding, held.Credits, held.Pools, held.Rewards, held.Bonds, held.FeesPending, held.Deposits
}

// HeldTotal is the sum of every category.
func HeldTotal() int64 {
	return held.Stakes + held.Unbonding + held.Credits + held.Pools + held.Rewards + held.Bonds + held.FeesPending + held.Deposits
}

// Balance is the realm's actual coin balance in the stake denom.
func Balance() int64 {
	return banker.NewReadonlyBanker().GetCoin(chain.PackageAddress(selfPath), StakeDenom)
}

// Health reports the conservation invariant: the categories never exceed the
// balance. Coins sent to the realm outside the entry points (a plain
// transfer) show up as surplus, which is harmless.
func Health() string {
	bal := Balance()
	tot := HeldTotal()
	status := "ok"
	if tot > bal {
		status = "BROKEN"
	}
	return `{"status":"` + status + `","balance":` + strconv.FormatInt(bal, 10) +
		`,"held":` + strconv.FormatInt(tot, 10) +
		`,"stakes":` + strconv.FormatInt(held.Stakes, 10) +
		`,"unbonding":` + strconv.FormatInt(held.Unbonding, 10) +
		`,"credits":` + strconv.FormatInt(held.Credits, 10) +
		`,"pools":` + strconv.FormatInt(held.Pools, 10) +
		`,"rewards":` + strconv.FormatInt(held.Rewards, 10) +
		`,"bonds":` + strconv.FormatInt(held.Bonds, 10) +
		`,"feesPending":` + strconv.FormatInt(held.FeesPending, 10) +
		`,"deposits":` + strconv.FormatInt(held.Deposits, 10) + `}`
}

// send moves coins out of the realm. It is the only outflow and is reachable
// only through StateRef methods that have already reduced a category. The
// banker is built from the realm's own live cur, so it is never handed to
// anyone.
func (r *StateRef) send(to address, amount int64) {
	if amount <= 0 {
		panic("core: send needs a positive amount")
	}
	if r.rlm.PkgPath() != selfPath {
		panic("core: only the core realm may move coins")
	}
	if amount > Balance() {
		panic("core: insufficient realm balance")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, r.rlm)
	b.SendCoins(r.rlm.Address(), to, chain.NewCoins(chain.NewCoin(StakeDenom, amount)))
}

// FeesPay pays an incentive (a tip, a bounty) from the pending fee pool,
// bounded per call by maxIncentivePay, so releases can fund new incentives
// without a new money primitive.
func (r *StateRef) FeesPay(to address, amount int64) {
	r.check()
	if amount <= 0 || amount > Param("maxIncentivePay") {
		panic("core: incentive must be positive and at most maxIncentivePay")
	}
	if amount > held.FeesPending {
		panic("core: the fee pool cannot cover this incentive")
	}
	held.FeesPending -= amount
	r.send(to, amount)
	emit("IncentivePaid", "to", string(to), "amount", strconv.FormatInt(amount, 10))
}

// ForwardFees sends the pending staker and treasury shares to the DAO realm
// once it has registered (RegisterDAO). Anyone may call it; until the DAO is
// registered nothing moves and it returns 0.
func ForwardFees(cur realm) int64 {
	dao := DAOPath
	if house == nil || held.FeesPending == 0 {
		return 0
	}
	amount := held.FeesPending
	held.FeesPending = 0
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(dao), chain.NewCoins(chain.NewCoin(StakeDenom, amount)))
	emit("FeesForwarded", "to", dao, "amount", strconv.FormatInt(amount, 10))
	return amount
}
