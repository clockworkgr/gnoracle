// Package token is Pythia (PYTH), the Gnoracle DAO's token: a plain GRC20
// registered in the token registry so wallets and Gnoswap can find it. The
// realm is deliberately not upgradeable; a ledger's value is its permanence.
//
// Supply: Genesis (100,000,000 PYTH) is minted once to the deployer, who
// distributes it per the plan's allocation table (§9.1). The minter is an
// ownable authority, handed to the DAO realm at bootstrap; it may mint up to
// MaxSupply, and the DAO's own rules rate-limit it further.
package token

import (
	"strconv"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	Name     = "Pythia"
	Symbol   = "PYTH"
	Decimals = 6

	// Genesis is minted at deployment; MaxSupply caps every later mint (fixed).
	Genesis   = int64(100_000_000_000_000) // 100M PYTH
	MaxSupply = int64(120_000_000_000_000) // 120M PYTH
)

// Admin is the deployer and first minter (the public test1 key for gnodev;
// rewritten by `make build ADMIN=g1...`).
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

var (
	// Token is the public, read-only handle other realms use (tellers, balances).
	Token  *grc20.Token
	ledger *grc20.PrivateLedger
	teller grc20.Teller
	minter = ownable.NewWithAddress(Admin)
)

func init(cur realm) {
	Token, ledger = grc20.NewToken(Name, Symbol, Decimals, 0, cur)
	teller = ledger.CallerTeller()
	if err := ledger.Mint(Admin, Genesis); err != nil {
		panic(err.Error())
	}
	grc20reg.Register(cross(cur), Token, "")
}

// TotalSupply is the current supply.
func TotalSupply() int64 { return Token.TotalSupply() }

// BalanceOf returns an account's balance.
func BalanceOf(owner address) int64 { return Token.BalanceOf(owner) }

// Allowance returns what spender may move on owner's behalf.
func Allowance(owner, spender address) int64 { return Token.Allowance(owner, spender) }

// Transfer moves tokens from the caller.
func Transfer(cur realm, to address, amount int64) {
	if err := teller.Transfer(0, cur, to, amount); err != nil {
		panic(err.Error())
	}
}

// Approve lets spender move up to amount of the caller's tokens.
func Approve(cur realm, spender address, amount int64) {
	if err := teller.Approve(0, cur, spender, amount); err != nil {
		panic(err.Error())
	}
}

// TransferFrom moves tokens the caller was approved to move.
func TransferFrom(cur realm, from, to address, amount int64) {
	if err := teller.TransferFrom(0, cur, from, to, amount); err != nil {
		panic(err.Error())
	}
}

// Mint creates tokens up to MaxSupply. Minter only (the DAO after bootstrap).
func Mint(cur realm, to address, amount int64) {
	minter.AssertOwnedBy(cur.Previous().Address())
	if amount <= 0 {
		panic("token: amount must be positive")
	}
	if Token.TotalSupply()+amount > MaxSupply {
		panic("token: mint would exceed the maximum supply of " + strconv.FormatInt(MaxSupply, 10))
	}
	if err := ledger.Mint(to, amount); err != nil {
		panic(err.Error())
	}
}

// Burn destroys the caller's own tokens.
func Burn(cur realm, amount int64) {
	if err := ledger.Burn(cur.Previous().Address(), amount); err != nil {
		panic(err.Error())
	}
}

// TransferMinter hands the mint authority to another address (the DAO realm's
// address at bootstrap). Minter only.
func TransferMinter(cur realm, newMinter address) {
	if err := minter.TransferOwnership(0, cur, newMinter); err != nil {
		panic(err.Error())
	}
}

// Minter is the current mint authority.
func Minter() address { return minter.Owner() }

// Render shows the token page.
func Render(path string) string {
	return Token.RenderHome() + "\nMinter: `" + string(minter.Owner()) + "`, maximum supply " +
		strconv.FormatInt(MaxSupply, 10) + " base units.\n"
}
