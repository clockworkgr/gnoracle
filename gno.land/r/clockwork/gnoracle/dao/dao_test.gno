// Package dao_test drives the DAO with the core and token realms: staking
// with checkpointed weight, fee sharing, proposals that act on the core,
// treasury and mint proposals, and a self-upgrade through the exec
// trampoline. Implementations and the trampoline are registered from the
// test, standing in for the deploy transactions whose init would do it.
package dao_test

import (
	"strconv"
	"strings"
	"testing"

	"chain"
	"chain/banker"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
	coreimpl "gno.land/r/clockwork/gnoracle/core/impl/v1"
	"gno.land/r/clockwork/gnoracle/dao"
	"gno.land/r/clockwork/gnoracle/dao/exec"
	daoimpl "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	daoimpl2 "gno.land/r/clockwork/gnoracle/dao/impl/v2"
	"gno.land/r/clockwork/gnoracle/token"
)

const (
	corePath     = "gno.land/r/clockwork/gnoracle/core"
	coreImplPath = "gno.land/r/clockwork/gnoracle/core/impl/v1"
	daoPath      = "gno.land/r/clockwork/gnoracle/dao"
	daoImplPath  = "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	daoImpl2Path = "gno.land/r/clockwork/gnoracle/dao/impl/v2"
	execPath     = "gno.land/r/clockwork/gnoracle/dao/exec"
	pyth         = int64(1_000_000)
	gnot         = int64(1_000_000)
	day          = int64(24 * 3600)
)

var (
	admin = dao.Admin
	// real bech32 addresses: the GRC20 ledger validates recipients
	alice    = testutils.TestAddress("alice")
	bob      = testutils.TestAddress("bob")
	carol    = testutils.TestAddress("carol")
	stranger = testutils.TestAddress("stranger")
	coreAddr = chain.PackageAddress(corePath)
	daoAddr  = chain.PackageAddress(daoPath)
)

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }

func nosend() { testing.SetOriginSend(nil) }

func payDAO(n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(daoAddr, coins(n))
}

func payCore(n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(coreAddr, coins(n))
}

// The harness starts every test function at the same height and time while
// realm state persists, so heights would run backwards between tests and
// checkpoints would refuse to write. advance keeps a high-water mark that
// install restores at the start of each test.
var maxHeight int64

func advance(heights int64) {
	testing.SkipHeights(heights)
	maxHeight += heights
}

func skip(seconds int64) { advance(seconds / 5) }

// epoch advances the chain by one voting-weight epoch so new stake counts.
func epoch() { advance(720) }

var installed bool

func install(cur realm) {
	if ctx := testing.GetContext(); ctx.Height < maxHeight+123 {
		testing.SkipHeights(maxHeight + 123 - ctx.Height)
	}
	// the harness also starts each test with a fresh coin banker: re-issue
	// the coins each realm's ledger says it holds
	_, _, _, _, _, _, known := dao.Held()
	if bal := banker.NewReadonlyBanker().GetCoin(daoAddr, "ugnot"); known > bal {
		testing.IssueCoins(daoAddr, coins(known-bal))
	}
	if diff := core.HeldTotal() - core.Balance(); diff > 0 {
		testing.IssueCoins(coreAddr, coins(diff))
	}
	if installed {
		return
	}
	installed = true
	// implementations register themselves (their init on chain)
	testing.SetRealm(testing.NewCodeRealm(coreImplPath))
	core.RegisterImpl(cross(cur), coreimpl.Instance())
	testing.SetRealm(testing.NewCodeRealm(daoImplPath))
	dao.RegisterImpl(cross(cur), daoimpl.Instance())
	testing.SetRealm(testing.NewCodeRealm(execPath))
	dao.RegisterTrampoline(cross(cur), exec.Instance())
	testing.SetRealm(testing.NewCodeRealm(daoPath))
	core.RegisterDAO(cross(cur), dao.Hooks())
	// the admin accepts both, hands the core's authority to the DAO (keeping
	// its own key for the bootstrap), and makes the DAO the token's minter
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), coreImplPath)
	dao.Accept(cross(cur), daoImplPath)
	core.ProposeAuthority(cross(cur), "anyof:"+string(admin)+"|"+daoPath)
	skip(core.AuthorityTimelock + 5)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ExecuteAuthority(cross(cur))
	token.TransferMinter(cross(cur), daoAddr)
	// genesis distribution: three members and a treasury
	token.Transfer(cross(cur), alice, 10_000_000*pyth)
	token.Transfer(cross(cur), bob, 5_000_000*pyth)
	token.Transfer(cross(cur), carol, 1_000_000*pyth)
	token.Transfer(cross(cur), daoAddr, 40_000_000*pyth)
	// lower the core stake floor for the feed stories (rate limited)
	for _, v := range []int64{5_000 * gnot, 2_500 * gnot, 1_250 * gnot, 1_000 * gnot} {
		core.SetParam(cross(cur), "providerMinStakeFloor", v)
		testing.SkipHeights(1) // parameters change at most once per height
	}
}

func stake(cur realm, who address, amount int64) {
	testing.SetRealm(testing.NewUserRealm(who))
	nosend()
	token.Approve(cross(cur), daoAddr, amount)
	dao.Stake(cross(cur), amount)
}

func health(t *testing.T) {
	t.Helper()
	h := dao.Health()
	if !strings.Contains(h, `"status":"ok"`) {
		t.Fatalf("dao conservation broken: %s", h)
	}
}

func TestStakingWeightAndFees(cur realm, t *testing.T) {
	install(cur)
	uassert.Equal(t, daoImplPath, dao.LivePath())
	uassert.Equal(t, string(daoAddr), string(token.Minter()))

	// staking needs an allowance
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "approve the DAO realm", func() { dao.Stake(cross(cur), 100*pyth) })

	stake(cur, alice, 1_000_000*pyth)
	stake(cur, bob, 500_000*pyth)
	uassert.Equal(t, int64(1_500_000*pyth), dao.TotalStaked())
	uassert.Equal(t, int64(9_000_000*pyth), token.BalanceOf(alice))
	uassert.Equal(t, int64(1_000_000*pyth), dao.GetMember(alice).Staked)

	// weight activates at the next epoch
	e := dao.Epoch()
	uassert.Equal(t, int64(0), dao.PowerAt(alice, e))
	uassert.Equal(t, int64(0), dao.TotalPowerAt(e))
	epoch()
	e = dao.Epoch()
	uassert.Equal(t, int64(1_000_000*pyth), dao.PowerAt(alice, e))
	uassert.Equal(t, int64(1_500_000*pyth), dao.TotalPowerAt(e))
	health(t)

	// fees arrive as plain coins (the core forwards them); a sync splits them
	testing.IssueCoins(daoAddr, coins(300*gnot))
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.Equal(t, int64(300*gnot), dao.SyncFees(cross(cur)))
	// 50% to stakers pro rata (alice 2/3, bob 1/3), 50% treasury
	uassert.Equal(t, int64(100*gnot), dao.FeesOwed(alice))
	uassert.Equal(t, int64(50*gnot), dao.FeesOwed(bob))
	uassert.Equal(t, int64(150*gnot), dao.TreasuryUgnot())
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.Equal(t, int64(100*gnot), dao.ClaimFees(cross(cur)))
	uassert.Equal(t, int64(0), dao.FeesOwed(alice))
	health(t)

	// unstake: cooldown, then withdraw; weight drops next epoch
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.RequestUnstake(cross(cur), 200_000*pyth)
	m := dao.GetMember(bob)
	uassert.Equal(t, int64(300_000*pyth), m.Staked)
	uassert.Equal(t, int64(200_000*pyth), m.UnbondAmount)
	uassert.AbortsContains(t, cur, "cooldown", func() { dao.Withdraw(cross(cur)) })
	uassert.Equal(t, int64(500_000*pyth), dao.PowerAt(bob, dao.Epoch())) // still this epoch
	skip(7*day + 5)
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	uassert.Equal(t, int64(200_000*pyth), dao.Withdraw(cross(cur)))
	uassert.Equal(t, int64(4_700_000*pyth), token.BalanceOf(bob))
	uassert.Equal(t, int64(300_000*pyth), dao.PowerAt(bob, dao.Epoch()))
	// later fees split by the new stakes: alice 1000/1300, bob 300/1300
	testing.IssueCoins(daoAddr, coins(260*gnot))
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.SyncFees(cross(cur))
	uassert.Equal(t, int64(100*gnot), dao.FeesOwed(alice))
	uassert.Equal(t, int64(30*gnot+50*gnot), dao.FeesOwed(bob))
	health(t)
}

func TestProposalsActOnTheCore(cur realm, t *testing.T) {
	install(cur)
	stake(cur, carol, 100_000*pyth)
	epoch()

	// a feed is proposed on the core; the DAO accepts it by vote
	spec := `{"name":"GNOT/USD","kind":"recurring","valueType":"numeric","decimals":6,"interval":3600,"submitWindow":600,"sources":"exchanges","minProviders":2,"maxProviders":5,"providerMinStake":1000000000,"toleranceBps":100,"quarantineBps":1000,"disputeWindow":43200,"readPrice":20000,"subscriptionPrice":100000000}`
	testing.SetRealm(testing.NewUserRealm(stranger))
	payCore(105 * gnot)
	feedID := core.ProposeFeed(cross(cur), spec)
	uassert.Equal(t, core.FeedProposed, core.GetFeed(feedID).Status)

	// a non-member cannot propose without a deposit; a member above the bar can
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "attach a deposit", func() {
		dao.Propose(cross(cur), "feed-accept", strconv.FormatUint(feedID, 10), "Accept GNOT/USD")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	pid := dao.Propose(cross(cur), "feed-accept", strconv.FormatUint(feedID, 10), "Accept GNOT/USD")
	p := dao.GetProposal(pid)
	uassert.Equal(t, dao.ProposalActive, p.Status)
	uassert.Equal(t, int64(0), p.Deposit)

	// malformed payloads are refused at proposal time
	uassert.AbortsContains(t, cur, "must be an unsigned integer", func() {
		dao.Propose(cross(cur), "feed-accept", "not-a-number", "bad")
	})
	uassert.AbortsContains(t, cur, "unknown proposal kind", func() {
		dao.Propose(cross(cur), "nonsense", "", "bad")
	})

	// votes: alice yes, bob no, carol yes; weights are the sealed stakes
	dao.Vote(cross(cur), pid, "YES")
	uassert.AbortsContains(t, cur, "already voted", func() { dao.Vote(cross(cur), pid, "YES") })
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), pid, "NO")
	testing.SetRealm(testing.NewUserRealm(carol))
	nosend()
	dao.Vote(cross(cur), pid, "YES")
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "no voting weight", func() { dao.Vote(cross(cur), pid, "YES") })
	p = dao.GetProposal(pid)
	uassert.Equal(t, int64(1_100_000*pyth), p.Yes)
	uassert.Equal(t, int64(300_000*pyth), p.No)

	// not before the voting period ends
	uassert.AbortsContains(t, cur, "still open", func() { dao.Execute(cross(cur), pid) })
	skip(3*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), pid)
	uassert.Equal(t, dao.ProposalExecuted, dao.GetProposal(pid).Status)
	uassert.Equal(t, core.FeedActive, core.GetFeed(feedID).Status)

	// a parameter change on the core and on the DAO, with the timelock
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	p1 := dao.Propose(cross(cur), "param", "core.missSlashBps=60", "Miss slash 0.6%")
	p2 := dao.Propose(cross(cur), "param", "dao.proposeBps=30", "Proposer bar 0.3%")
	dao.Vote(cross(cur), p1, "YES")
	dao.Vote(cross(cur), p2, "YES")
	skip(5*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), p1) // before the timelock: tallies and records, executes nothing
	uassert.Equal(t, dao.ProposalPassed, dao.GetProposal(p1).Status)
	skip(2*day + 5)
	dao.Execute(cross(cur), p1)
	dao.Execute(cross(cur), p2)
	uassert.Equal(t, int64(60), core.Param("missSlashBps"))
	uassert.Equal(t, int64(30), dao.Param("proposeBps"))

	// a proposal the majority rejects, and one that fails quorum and loses its deposit
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	p3 := dao.Propose(cross(cur), "text", "Should we?", "Signal")
	dao.Vote(cross(cur), p3, "YES")
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	dao.Vote(cross(cur), p3, "NO")
	testing.SetRealm(testing.NewUserRealm(stranger))
	payDAO(20 * gnot)
	p4 := dao.Propose(cross(cur), "text", "Nobody votes", "Silence")
	uassert.Equal(t, int64(20*gnot), dao.GetProposal(p4).Deposit)
	skip(5*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), p3)
	dao.Execute(cross(cur), p4)
	uassert.Equal(t, dao.ProposalRejected, dao.GetProposal(p3).Status)
	uassert.Equal(t, "not carried", dao.GetProposal(p3).Reason)
	uassert.Equal(t, dao.ProposalRejected, dao.GetProposal(p4).Status)
	uassert.Equal(t, "no quorum", dao.GetProposal(p4).Reason)
	uassert.Equal(t, int64(0), dao.GetProposal(p4).Deposit) // forfeited to the treasury
	health(t)
}

func TestTreasuryMintAndSelfUpgrade(cur realm, t *testing.T) {
	install(cur)
	epoch()
	// treasury PYTH is what the DAO holds beyond stakes and rewards
	uassert.Equal(t, int64(40_000_000*pyth), dao.TreasuryPyth())

	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	tp := dao.Propose(cross(cur), "treasury", "pyth 1000000000000 "+string(carol)+" liquidity", "Fund liquidity")
	mp := dao.Propose(cross(cur), "mint", "500000000000 "+string(bob), "Mint 500k")
	dao.Vote(cross(cur), tp, "YES")
	dao.Vote(cross(cur), mp, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), tp, "YES")
	dao.Vote(cross(cur), mp, "YES")
	skip(7*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), tp)                                     // 5 d vote + 2 d lock have passed
	uassert.Equal(t, int64(1_900_000*pyth), token.BalanceOf(carol)) // 1M genesis - 100k staked + 1M from the treasury
	uassert.Equal(t, int64(39_000_000*pyth), dao.TreasuryPyth())
	dao.Execute(cross(cur), mp) // 7 d vote + 7 d lock: tallied, not yet executed
	uassert.Equal(t, dao.ProposalPassed, dao.GetProposal(mp).Status)
	skip(7*day + 5)
	supplyBefore := token.TotalSupply()
	dao.Execute(cross(cur), mp)
	uassert.Equal(t, supplyBefore+500_000*pyth, token.TotalSupply())
	// a second mint in the same year above 2% of supply is refused at execution
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	big := dao.Propose(cross(cur), "mint", "2000000000000 "+string(bob), "Mint 2M")
	dao.Vote(cross(cur), big, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), big, "YES")
	skip(14*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "mint exceeds", func() { dao.Execute(cross(cur), big) })
	health(t)

	// self-upgrade: register v2, pass an upgrade-accept proposal, execute
	// through the trampoline, then roll back the same way
	testing.SetRealm(testing.NewCodeRealm(daoImpl2Path))
	dao.RegisterImpl(cross(cur), daoimpl2.Instance())
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	up := dao.Propose(cross(cur), "upgrade-accept", "dao "+daoImpl2Path, "DAO v2")
	dao.Vote(cross(cur), up, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), up, "YES")
	skip(14*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), up)
	uassert.Equal(t, daoImpl2Path, dao.LivePath())
	uassert.True(t, strings.HasPrefix(dao.Render(cross(cur), ""), "<!-- release: dao/impl/v2 -->"))
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	back := dao.Propose(cross(cur), "upgrade-rollback", "dao", "Back to v1")
	dao.Vote(cross(cur), back, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), back, "YES")
	skip(day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), back)
	uassert.Equal(t, daoImplPath, dao.LivePath())

	// the trampoline refuses anyone but the DAO realm
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "only the DAO realm", func() { exec.Instance().Run(cross(cur), "accept", daoImpl2Path) })
	// and the core-side proposals go through the DAO's authority
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	tr := dao.Propose(cross(cur), "trusted-requester", "gno.land/r/demo/market 50000000000", "Trust the market")
	dao.Vote(cross(cur), tr, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), tr, "YES")
	skip(5*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), tr)
	uassert.Equal(t, int64(50_000*gnot), core.TrustedCap("gno.land/r/demo/market"))
	health(t)
}

// TestTreasuryUgnotAndDepositsStayAccounted pins the ugnot ledger: a proposal
// deposit is escrow, not fee income, and a treasury payout leaves no phantom
// coins for the next sync to hand to stakers.
func TestTreasuryUgnotAndDepositsStayAccounted(cur realm, t *testing.T) {
	install(cur)
	epoch()
	treasuryBefore := dao.TreasuryUgnot()
	testing.SetRealm(testing.NewUserRealm(stranger))
	payDAO(20 * gnot)
	dao.Propose(cross(cur), "text", "accounting check", "Deposit is escrow")
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.Equal(t, int64(0), dao.SyncFees(cross(cur))) // the deposit is not income
	uassert.Equal(t, treasuryBefore, dao.TreasuryUgnot())
	health(t)

	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	tp := dao.Propose(cross(cur), "treasury", "ugnot 10000000 "+string(carol)+" grant", "Grant 10 GNOT")
	dao.Vote(cross(cur), tp, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), tp, "YES")
	skip(7*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	before := dao.TreasuryUgnot()
	dao.Execute(cross(cur), tp)
	uassert.Equal(t, before-10*gnot, dao.TreasuryUgnot())
	uassert.Equal(t, int64(0), dao.SyncFees(cross(cur))) // no phantom income after the payout
	health(t)
}

// TestAuthorityHandoverIsTwoStep drives the DAO's own authority through the
// proposal kinds: a transfer is proposed, waits its timelock, and executes
// in a second proposal; the exec trampoline must stay in every spec.
func TestAuthorityHandoverIsTwoStep(cur realm, t *testing.T) {
	install(cur)
	epoch()
	exec := "gno.land/r/clockwork/gnoracle/dao/exec"
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "must include", func() { dao.Propose(cross(cur), "authority-transfer", "dao addr:"+string(admin), "drop exec?") })
	uassert.AbortsContains(t, cur, "authspec", func() { dao.Propose(cross(cur), "authority-transfer", "dao nonsense", "bad spec") })
	p1 := dao.Propose(cross(cur), "authority-transfer", "dao realms:"+exec, "Hand the DAO to itself")
	dao.Vote(cross(cur), p1, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), p1, "YES")
	skip(14*day + 7*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), p1)
	spec, readyAt := dao.PendingAuthority()
	uassert.Equal(t, "realms:"+exec, spec)
	uassert.Equal(t, dao.Now()+dao.AuthorityTimelock, readyAt)
	// the realm's own timelock holds even for the guardian, who is still an authority
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "timelocked", func() { dao.ExecuteAuthority(cross(cur)) })
	// once the timelock passed, the DAO executes it through a second proposal
	skip(dao.AuthorityTimelock + 5)
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	p2 := dao.Propose(cross(cur), "authority-execute", "dao", "Execute the handover")
	dao.Vote(cross(cur), p2, "YES")
	testing.SetRealm(testing.NewUserRealm(bob))
	nosend()
	dao.Vote(cross(cur), p2, "YES")
	skip(3*day + 5)
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	dao.Execute(cross(cur), p2)
	uassert.True(t, strings.HasPrefix(dao.Authority(), "realms:"))
	spec, _ = dao.PendingAuthority()
	uassert.Equal(t, "", spec)
	// the guardian key is a stranger to the DAO's proxy now
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { dao.ProposeAuthority(cross(cur), "anyof:"+string(admin)+"|"+exec) })
	health(t)
}

func TestGates(cur realm, t *testing.T) {
	install(cur)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/intruder"))
	uassert.AbortsContains(t, cur, "state is reachable only through", func() { dao.Store(0, cur) })
	uassert.AbortsContains(t, cur, "only the core realm", func() { dao.OpenDisputeVote(cross(cur), 1, false, "x") })
	uassert.AbortsContains(t, cur, "only the exec realm", func() { dao.RegisterTrampoline(cross(cur), exec.Instance()) })
	testing.SetRealm(testing.NewUserRealm(stranger))
	nosend()
	uassert.AbortsContains(t, cur, "not the authority", func() { dao.Accept(cross(cur), daoImplPath) })
	uassert.AbortsContains(t, cur, "not a member", func() { dao.ClaimFees(cross(cur)) })
}

// TestDevSetParamIsInertOffDevChains: DevSetParam and the relaxed timing
// floors exist for chain id "dev" (gnodev), which `make demo` exercises. The
// harness runs realm calls under an empty chain id, so here the entry point
// refuses everyone, authority included, and the production floors hold.
func TestDevSetParamIsInertOffDevChains(cur realm, t *testing.T) {
	install(cur)
	before := dao.Param("commitPeriod")
	uassert.Equal(t, int64(24*3600), before)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	uassert.AbortsContains(t, cur, "development chains only", func() { dao.DevSetParam(cross(cur), "commitPeriod", before/2) })
	testing.SetRealm(testing.NewUserRealm(alice))
	nosend()
	uassert.AbortsContains(t, cur, "development chains only", func() { dao.DevSetParam(cross(cur), "commitPeriod", before/2) })
	uassert.Equal(t, before, dao.Param("commitPeriod"))
	uassert.Equal(t, int64(720), dao.Param("epochBlocks"))
}
