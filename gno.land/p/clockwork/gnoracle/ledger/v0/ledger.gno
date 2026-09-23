// Package ledger holds the money arithmetic the realms share: checked
// balances, a reward-per-share accumulator for pull-based distribution, and a
// small unbonding queue. Everything is int64 with overflow checks; products
// that may exceed int64 go through a 128-bit intermediate.
//
// The accumulator is the MasterChef/Synthetix shape: a pool credited to all
// current shares bumps accPerShare by pool * Scale / totalShares; a position
// owes shares * accPerShare / Scale minus what it has already been credited.
// Rewards that arrive while nobody holds shares, or that would overflow the
// accumulator, are carried and released with the next bump.
package ledger

import (
	"math/bits"
	"math/overflow"
)

// Scale is the fixed-point scale of accPerShare.
const Scale = int64(1_000_000_000_000) // 1e12

// Add returns a + b or panics with a stable message on overflow or a negative
// result.
func Add(a, b int64) int64 {
	v, ok := overflow.Add64(a, b)
	if !ok || v < 0 {
		panic("ledger: balance overflow")
	}
	return v
}

// Sub returns a - b or panics when the result would be negative.
func Sub(a, b int64) int64 {
	if b < 0 {
		panic("ledger: negative amount")
	}
	if b > a {
		panic("ledger: insufficient balance")
	}
	return a - b
}

// MulDiv is floor(a * b / d) with a 128-bit intermediate.
func MulDiv(a, b, d int64) int64 {
	if a < 0 || b < 0 || d <= 0 {
		panic("ledger: MulDiv needs non-negative factors and a positive divisor")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(d) {
		panic("ledger: MulDiv overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(d))
	if q > uint64(1<<63-1) {
		panic("ledger: MulDiv overflow")
	}
	return int64(q)
}

// Accumulator distributes pools to shares pro rata over time.
type Accumulator struct {
	accPerShare int64 // scaled by Scale
	totalShares int64
	carry       int64 // rewards not yet attributable to any share
	paidOut     int64 // total ever credited to positions (for invariants)
	received    int64 // total ever bumped (for invariants)
}

// Position is one account's stake in an Accumulator.
type Position struct {
	Shares  int64
	debt    int64 // shares * accPerShare / Scale at the last settle
	Pending int64 // credited, not yet claimed
}

// TotalShares is the current share count.
func (a *Accumulator) TotalShares() int64 { return a.totalShares }

// Carry is the reward amount waiting for shares.
func (a *Accumulator) Carry() int64 { return a.carry }

// Received is the total ever bumped into the accumulator.
func (a *Accumulator) Received() int64 { return a.received }

// PaidOut is the total ever credited to positions' Pending.
func (a *Accumulator) PaidOut() int64 { return a.paidOut }

// AccPerShare exposes the raw accumulator for rendering and tests.
func (a *Accumulator) AccPerShare() int64 { return a.accPerShare }

// Bump credits amount to all current shares. With no shares the amount is
// carried. An increment that would overflow the accumulator is carried too;
// with realistic totals (shares in base units of a token with 6 decimals) that
// never happens, but the guard keeps a tiny share count from breaking the
// realm.
func (a *Accumulator) Bump(amount int64) {
	if amount < 0 {
		panic("ledger: negative bump")
	}
	a.received = Add(a.received, amount)
	total := Add(a.carry, amount)
	a.carry = 0
	if a.totalShares <= 0 || total == 0 {
		a.carry = total
		return
	}
	hi, lo := bits.Mul64(uint64(total), uint64(Scale))
	if hi >= uint64(a.totalShares) {
		a.carry = total
		return
	}
	inc, _ := bits.Div64(hi, lo, uint64(a.totalShares))
	if inc > uint64(1<<63-1) {
		a.carry = total
		return
	}
	next, ok := overflow.Add64(a.accPerShare, int64(inc))
	if !ok {
		a.carry = total
		return
	}
	a.accPerShare = next
	// dust below one unit per share stays in carry so it is never lost
	credited := MulDiv(int64(inc), a.totalShares, Scale)
	if credited < total {
		a.carry = total - credited
	}
}

// Settle credits the position's earned amount to Pending and resets its debt.
// It must be called before Shares change.
func (a *Accumulator) Settle(p *Position) {
	if p.Shares < 0 {
		panic("ledger: negative shares")
	}
	owed := MulDiv(p.Shares, a.accPerShare, Scale)
	if owed > p.debt {
		earned := owed - p.debt
		p.Pending = Add(p.Pending, earned)
		a.paidOut = Add(a.paidOut, earned)
	}
	p.debt = owed
}

// Deposit adds shares to a position (settling first).
func (a *Accumulator) Deposit(p *Position, shares int64) {
	if shares < 0 {
		panic("ledger: negative amount")
	}
	a.Settle(p)
	p.Shares = Add(p.Shares, shares)
	a.totalShares = Add(a.totalShares, shares)
	p.debt = MulDiv(p.Shares, a.accPerShare, Scale)
}

// Withdraw removes shares from a position (settling first).
func (a *Accumulator) Withdraw(p *Position, shares int64) {
	a.Settle(p)
	p.Shares = Sub(p.Shares, shares)
	a.totalShares = Sub(a.totalShares, shares)
	p.debt = MulDiv(p.Shares, a.accPerShare, Scale)
}

// Claim settles and returns the position's Pending, zeroing it.
func (a *Accumulator) Claim(p *Position) int64 {
	a.Settle(p)
	out := p.Pending
	p.Pending = 0
	return out
}

// Owed is what a settle would credit now, without changing anything.
func (a *Accumulator) Owed(p *Position) int64 {
	owed := MulDiv(p.Shares, a.accPerShare, Scale)
	if owed > p.debt {
		return p.Pending + owed - p.debt
	}
	return p.Pending
}

// MaxUnbondingEntries bounds the queue per account so every walk is short.
const MaxUnbondingEntries = 8

// UnbondingEntry is an amount that becomes withdrawable at ReadyAt.
type UnbondingEntry struct {
	Amount  int64
	ReadyAt int64
}

// Unbonding is one account's queue of pending withdrawals, oldest first.
type Unbonding struct {
	Entries []UnbondingEntry
}

// Total is the amount still queued.
func (u *Unbonding) Total() int64 {
	var t int64
	for _, e := range u.Entries {
		t = Add(t, e.Amount)
	}
	return t
}

// Add queues amount until readyAt. It merges into the newest entry when that
// entry has the same ReadyAt, and refuses (returns false) when the queue is
// full, so the caller can tell the account to withdraw first.
func (u *Unbonding) Add(amount, readyAt int64) bool {
	if amount <= 0 {
		panic("ledger: unbonding amount must be positive")
	}
	n := len(u.Entries)
	if n > 0 && u.Entries[n-1].ReadyAt == readyAt {
		u.Entries[n-1].Amount = Add(u.Entries[n-1].Amount, amount)
		return true
	}
	if n >= MaxUnbondingEntries {
		return false
	}
	u.Entries = append(u.Entries, UnbondingEntry{Amount: amount, ReadyAt: readyAt})
	return true
}

// Ready removes and returns the total of every entry whose ReadyAt has
// passed at now (ReadyAt <= now).
func (u *Unbonding) Ready(now int64) int64 {
	var out int64
	keep := u.Entries[:0]
	for _, e := range u.Entries {
		if e.ReadyAt <= now {
			out = Add(out, e.Amount)
		} else {
			keep = append(keep, e)
		}
	}
	u.Entries = keep
	return out
}

// PeekReady returns what Ready(now) would pay, without changing the queue.
func (u *Unbonding) PeekReady(now int64) int64 {
	var out int64
	for _, e := range u.Entries {
		if e.ReadyAt <= now {
			out = Add(out, e.Amount)
		}
	}
	return out
}

// Slash removes up to amount from the queue, oldest entries first, and
// returns how much it took. Unbonding stake stays slashable until withdrawn.
func (u *Unbonding) Slash(amount int64) int64 {
	if amount < 0 {
		panic("ledger: negative amount")
	}
	var taken int64
	keep := u.Entries[:0]
	for _, e := range u.Entries {
		if taken >= amount {
			keep = append(keep, e)
			continue
		}
		need := amount - taken
		if e.Amount <= need {
			taken += e.Amount
			continue
		}
		e.Amount -= need
		taken += need
		keep = append(keep, e)
	}
	u.Entries = keep
	return taken
}

// SlashStakeThenUnbonding takes amount from stake first, then from the
// unbonding queue, and returns the new stake and the total taken.
func SlashStakeThenUnbonding(stake int64, u *Unbonding, amount int64) (newStake, taken int64) {
	if amount < 0 {
		panic("ledger: negative amount")
	}
	if amount <= stake {
		return stake - amount, amount
	}
	taken = stake
	taken += u.Slash(amount - stake)
	return 0, taken
}
