package ledger_test

import (
	"testing"

	"gno.land/p/clockwork/gnoracle/ledger/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestAddSub(cur realm, t *testing.T) {
	uassert.Equal(t, int64(5), ledger.Add(2, 3))
	uassert.Equal(t, int64(2), ledger.Sub(5, 3))
	uassert.PanicsWithMessage(t, cur, "ledger: balance overflow", func() { ledger.Add(9223372036854775807, 1) })
	uassert.PanicsWithMessage(t, cur, "ledger: insufficient balance", func() { ledger.Sub(1, 2) })
	uassert.PanicsWithMessage(t, cur, "ledger: negative amount", func() { ledger.Sub(1, -1) })
	uassert.Equal(t, int64(4611686018427387903), ledger.MulDiv(9223372036854775807, 5000, 10_000))
}

func TestAccumulatorProRata(t *testing.T) {
	var a ledger.Accumulator
	var alice, bob ledger.Position
	a.Deposit(&alice, 100)
	a.Deposit(&bob, 300)
	a.Bump(4000) // alice 1000, bob 3000
	uassert.Equal(t, int64(1000), a.Owed(&alice))
	uassert.Equal(t, int64(3000), a.Owed(&bob))
	uassert.Equal(t, int64(1000), a.Claim(&alice))
	uassert.Equal(t, int64(0), a.Claim(&alice)) // nothing twice
	uassert.Equal(t, int64(3000), a.Owed(&bob))

	// bob leaves half; later rewards split by the new shares
	a.Withdraw(&bob, 150)
	a.Bump(2500) // alice 100/250 -> 1000, bob 150/250 -> 1500
	uassert.Equal(t, int64(1000), a.Owed(&alice))
	uassert.Equal(t, int64(4500), a.Owed(&bob)) // 3000 pending + 1500
	uassert.Equal(t, int64(4500), a.Claim(&bob))
	uassert.Equal(t, int64(250), a.TotalShares())

	// conservation: received == paid out + carry + still owed
	owed := a.Owed(&alice) + a.Owed(&bob)
	uassert.Equal(t, a.Received(), a.PaidOut()+a.Carry()+owed)
}

func TestAccumulatorCarriesWhenNobodyHoldsShares(t *testing.T) {
	var a ledger.Accumulator
	a.Bump(500)
	uassert.Equal(t, int64(500), a.Carry())
	var p ledger.Position
	a.Deposit(&p, 10)
	uassert.Equal(t, int64(0), a.Owed(&p)) // carry is not retroactive
	a.Bump(0)                              // a zero bump releases the carry to current shares
	uassert.Equal(t, int64(500), a.Owed(&p))
	uassert.Equal(t, int64(0), a.Carry())
}

func TestAccumulatorDustStaysInCarry(t *testing.T) {
	var a ledger.Accumulator
	var p ledger.Position
	a.Deposit(&p, 3)
	a.Bump(10) // 10/3 per share: 3 each credited, 1 dust carried
	uassert.Equal(t, int64(9), a.Owed(&p))
	uassert.Equal(t, int64(1), a.Carry())
	a.Bump(2) // carry 1 + 2 = 3 -> exactly 1 per share
	uassert.Equal(t, int64(12), a.Owed(&p))
	uassert.Equal(t, int64(0), a.Carry())
	uassert.Equal(t, a.Received(), a.PaidOut()+a.Carry()+a.Owed(&p)-p.Pending+p.Pending)
}

func TestAccumulatorLargeScaleDoesNotOverflow(t *testing.T) {
	// 100M PYTH at 6 decimals staked, 10 GNOT (1e7 ugnot) fee bumps, repeated.
	var a ledger.Accumulator
	var whale, minnow ledger.Position
	a.Deposit(&whale, 99_000_000_000_000)
	a.Deposit(&minnow, 1_000_000_000_000)
	for i := 0; i < 1000; i++ {
		a.Bump(10_000_000)
	}
	uassert.Equal(t, int64(9_900_000_000), a.Owed(&whale)) // 99% of 1e10
	uassert.Equal(t, int64(100_000_000), a.Owed(&minnow))
	uassert.Equal(t, a.Received(), a.Owed(&whale)+a.Owed(&minnow)+a.Carry())
}

func TestAccumulatorTinyShareCountIsCarriedNotBroken(t *testing.T) {
	var a ledger.Accumulator
	var p ledger.Position
	a.Deposit(&p, 1)
	a.Bump(9_000_000_000_000_000) // 9e18 * 1e12 / 1 overflows the accumulator: carried
	uassert.Equal(t, int64(9_000_000_000_000_000), a.Carry())
	uassert.Equal(t, int64(0), a.Owed(&p))
	a.Deposit(&p, 999_999) // now 1e6 shares: 9e18*1e12/1e6 = 9e24 still too big; stays carried
	a.Bump(0)
	uassert.Equal(t, int64(9_000_000_000_000_000), a.Carry())
}

func TestUnbondingQueue(cur realm, t *testing.T) {
	var u ledger.Unbonding
	uassert.True(t, u.Add(100, 1000))
	uassert.True(t, u.Add(50, 1000)) // merged into the same entry
	uassert.True(t, u.Add(25, 2000))
	uassert.Equal(t, 2, len(u.Entries))
	uassert.Equal(t, int64(175), u.Total())
	uassert.Equal(t, int64(0), u.PeekReady(999))
	uassert.Equal(t, int64(150), u.PeekReady(1000))
	uassert.Equal(t, int64(150), u.Ready(1000))
	uassert.Equal(t, int64(25), u.Total())
	uassert.Equal(t, int64(25), u.Ready(5000))
	uassert.Equal(t, int64(0), u.Total())
	uassert.PanicsWithMessage(t, cur, "ledger: unbonding amount must be positive", func() { u.Add(0, 1) })

	// the queue is bounded
	var f ledger.Unbonding
	for i := int64(1); i <= ledger.MaxUnbondingEntries; i++ {
		uassert.True(t, f.Add(1, i))
	}
	uassert.False(t, f.Add(1, 99))
	uassert.True(t, f.Add(1, ledger.MaxUnbondingEntries)) // merging into the newest still works
}

func TestSlashTakesStakeThenUnbondingOldestFirst(t *testing.T) {
	var u ledger.Unbonding
	u.Add(100, 10)
	u.Add(100, 20)
	stake, taken := ledger.SlashStakeThenUnbonding(50, &u, 30)
	uassert.Equal(t, int64(20), stake)
	uassert.Equal(t, int64(30), taken)
	uassert.Equal(t, int64(200), u.Total())

	stake, taken = ledger.SlashStakeThenUnbonding(20, &u, 150) // 20 stake + 130 from the queue
	uassert.Equal(t, int64(0), stake)
	uassert.Equal(t, int64(150), taken)
	uassert.Equal(t, int64(70), u.Total())
	uassert.Equal(t, 1, len(u.Entries)) // the oldest entry was consumed whole
	uassert.Equal(t, int64(20), u.Entries[0].ReadyAt)

	stake, taken = ledger.SlashStakeThenUnbonding(0, &u, 500) // more than exists: takes what there is
	uassert.Equal(t, int64(70), taken)
	uassert.Equal(t, int64(0), u.Total())
}

func TestAccumulatorCapCarriesInsteadOfWedging(t *testing.T) {
	var a ledger.Accumulator
	var tiny, whale ledger.Position
	a.Deposit(&tiny, 1)
	a.Bump(9_000_000) // 9 GNOT on one share: uncapped, accPerShare would be 9e18
	owedTiny := a.Owed(&tiny)
	if owedTiny >= 9_000_000 {
		t.Fatalf("the cap must hold part of the bump in carry, tiny owed %d", owedTiny)
	}
	// a large position joins and settles without overflow
	a.Deposit(&whale, 2_000_000_000_000)
	a.Bump(1_000)
	sum := a.Owed(&tiny) + a.Owed(&whale)
	if sum < 0 || sum > 9_001_000 {
		t.Fatalf("owed %d beyond what was bumped", sum)
	}
	if a.Owed(&whale) <= 0 {
		t.Fatal("the carried remainder must reach the new shares")
	}
}
