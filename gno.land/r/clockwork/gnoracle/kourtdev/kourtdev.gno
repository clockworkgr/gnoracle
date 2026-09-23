// Package kourtdev is a stand-in for Kourt (github.com/jaekwon/kourt) with
// the entry points and timings the Gnoracle mirror uses, so the mirror can
// be developed and tested on gnodev without the real realm: courts with a
// coin, claims with a deposit, stakes with a 3-hour answerability window, a
// bonded answer, a 72-hour undisputed settle, disputes that hand the verdict
// to an admin-set fake vote. Nothing here is Kourt's code; the real mirror
// release binds to the deployed Kourt realm instead (plan §7.4).
package kourtdev

import (
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
)

const (
	sideYES = 0
	sideNO  = 1

	oneCC          = int64(1_000_000)
	claimDeposit   = oneCC
	claimFee       = oneCC / 10
	minAnswerStake = oneCC
	answerWindow   = int64(3 * 3600)
	settleDelay    = int64(72 * 3600)
)

type court struct {
	slug, name string
	admin      address
	coin       *avl.Tree // addr -> int64
	claims     *avl.Tree // id -> *claim
	nextID     uint64
}

type claim struct {
	id                uint64
	title, body       string
	author            address
	openedAt          int64
	yes, no           *avl.Tree // addr -> int64
	yesTotal, noTotal int64
	answerer          address
	answer            int
	answerBond        int64
	answeredAt        int64
	disputer          address
	disputeOpen       bool
	settled           bool
	verdict           int
	route             string
}

var courts = avl.NewTree() // slug -> *court

func now() int64 { return time.Now().Unix() }

func mustCourt(slug string) *court {
	v := courts.Get(slug)
	if v == nil {
		panic("kourtdev: unknown court " + slug)
	}
	return v.(*court)
}

func mustClaim(c *court, id uint64) *claim {
	v := c.claims.Get(strconv.FormatUint(id, 10))
	if v == nil {
		panic("kourtdev: unknown claim")
	}
	return v.(*claim)
}

func bal(t *avl.Tree, a address) int64 {
	v := t.Get(string(a))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func add(t *avl.Tree, a address, d int64) {
	n := bal(t, a) + d
	if n < 0 {
		panic("kourtdev: insufficient court coin")
	}
	t.Set(string(a), n)
}

// StartCourt founds a court; the caller is its admin.
func StartCourt(cur realm, slug, name string) string {
	if courts.Has(slug) {
		panic("kourtdev: slug is taken")
	}
	courts.Set(slug, &court{slug: slug, name: name, admin: cur.Previous().Address(), coin: avl.NewTree(), claims: avl.NewTree()})
	return slug
}

// Buy mints court coin 1:1 for the ugnot sent (a flat stand-in curve).
func Buy(cur realm, slug string, minUnits int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("kourtdev: Buy must be called directly by an account")
	}
	c := mustCourt(slug)
	sent := unsafe.OriginSend().AmountOf("ugnot")
	if sent <= 0 || sent < minUnits {
		panic("kourtdev: send ugnot to buy")
	}
	add(c.coin, cur.Previous().Address(), sent)
	return sent
}

// TransferCC moves court coin.
func TransferCC(cur realm, courtSlug string, to address, amount int64) {
	c := mustCourt(courtSlug)
	if amount <= 0 {
		panic("kourtdev: amount must be positive")
	}
	add(c.coin, cur.Previous().Address(), -amount)
	add(c.coin, to, amount)
}

// CoinBalanceOf returns an account's court coin.
func CoinBalanceOf(slug string, who address) int64 { return bal(mustCourt(slug).coin, who) }

// OpenClaimP files a claim with a body; the author escrows deposit + fee.
func OpenClaimP(cur realm, courtSlug, title, body string) uint64 {
	c := mustCourt(courtSlug)
	if len(title) == 0 || len(title) > 200 {
		panic("kourtdev: title must be 1 to 200 bytes")
	}
	if len(body) > 2000 {
		panic("kourtdev: body is longer than 2000 bytes")
	}
	who := cur.Previous().Address()
	add(c.coin, who, -(claimDeposit + claimFee))
	c.nextID++
	cl := &claim{id: c.nextID, title: title, body: body, author: who, openedAt: now(), yes: avl.NewTree(), no: avl.NewTree()}
	c.claims.Set(strconv.FormatUint(cl.id, 10), cl)
	return cl.id
}

// Stake backs one side of a claim.
func Stake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {
	c := mustCourt(courtSlug)
	cl := mustClaim(c, claimID)
	if cl.answeredAt != 0 {
		panic("kourtdev: staking is frozen; this claim has an answer")
	}
	if amount <= 0 {
		panic("kourtdev: stake must be positive")
	}
	who := cur.Previous().Address()
	add(c.coin, who, -amount)
	if side == sideYES {
		add(cl.yes, who, amount)
		cl.yesTotal += amount
	} else {
		add(cl.no, who, amount)
		cl.noTotal += amount
	}
}

// PostAnswer posts the bonded answer once the claim is answerable.
func PostAnswer(cur realm, courtSlug string, claimID uint64, verdict int) {
	c := mustCourt(courtSlug)
	cl := mustClaim(c, claimID)
	if cl.answeredAt != 0 {
		panic("kourtdev: this claim already has an answer")
	}
	if now() < cl.openedAt+answerWindow {
		panic("kourtdev: not enough stake history to answer yet")
	}
	if cl.yesTotal+cl.noTotal < minAnswerStake {
		panic("kourtdev: trailing stake is below the minimum to answer")
	}
	bond := (cl.yesTotal + cl.noTotal) * 6 / 100
	if bond < oneCC {
		bond = oneCC
	}
	who := cur.Previous().Address()
	add(c.coin, who, -bond)
	cl.answerer = who
	cl.answer = verdict
	cl.answerBond = bond
	cl.answeredAt = now()
}

// OpenDispute contests the answer with a 1 CC bond (stand-in).
func OpenDispute(cur realm, courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cl := mustClaim(c, claimID)
	if cl.answeredAt == 0 || cl.settled || cl.disputeOpen {
		panic("kourtdev: nothing to dispute")
	}
	if now() >= cl.answeredAt+settleDelay {
		panic("kourtdev: the dispute window has passed")
	}
	who := cur.Previous().Address()
	add(c.coin, who, -oneCC)
	cl.disputer = who
	cl.disputeOpen = true
	return int64(claimID)
}

// SetVoteVerdict stands in for Kourt's coin vote: anyone records the verdict
// of a disputed claim (this is a development stand-in, not a court).
func SetVoteVerdict(cur realm, courtSlug string, claimID uint64, verdict int) {
	c := mustCourt(courtSlug)
	cl := mustClaim(c, claimID)
	if !cl.disputeOpen {
		panic("kourtdev: no dispute open")
	}
	cl.disputeOpen = false
	cl.settled = true
	cl.verdict = verdict
	cl.route = "vote"
	if verdict == cl.answer {
		add(c.coin, cl.answerer, cl.answerBond)
	} else {
		add(c.coin, cl.disputer, oneCC)
	}
	add(c.coin, cl.author, claimDeposit+claimFee)
}

// SettleUndisputed records the answer as final after the 72-hour delay.
func SettleUndisputed(cur realm, courtSlug string, claimID uint64) {
	c := mustCourt(courtSlug)
	cl := mustClaim(c, claimID)
	if cl.answeredAt == 0 {
		panic("kourtdev: there is no answer to settle")
	}
	if cl.disputeOpen || cl.route == "vote" {
		panic("kourtdev: this claim was disputed; it settles by vote")
	}
	if cl.settled {
		panic("kourtdev: already settled")
	}
	if now() < cl.answeredAt+settleDelay {
		panic("kourtdev: the answer has not aged the 72h settlement minimum")
	}
	cl.settled = true
	cl.verdict = cl.answer
	cl.route = "undisputed"
	add(c.coin, cl.answerer, cl.answerBond)
	add(c.coin, cl.author, claimDeposit+claimFee)
}

// WithdrawStake returns a staker's principal after the verdict.
func WithdrawStake(cur realm, courtSlug string, claimID uint64, side int) int64 {
	c := mustCourt(courtSlug)
	cl := mustClaim(c, claimID)
	if !cl.settled {
		panic("kourtdev: no verdict yet")
	}
	who := cur.Previous().Address()
	t := cl.yes
	if side != sideYES {
		t = cl.no
	}
	amount := bal(t, who)
	if amount <= 0 {
		panic("kourtdev: nothing staked on that side")
	}
	t.Set(string(who), int64(0))
	add(c.coin, who, amount)
	return amount
}

// ---- reads

func Exists(slug string) bool { return courts.Has(slug) }

func ClaimCount(courtSlug string) uint64 { return mustCourt(courtSlug).nextID }

func ClaimTitle(courtSlug string, claimID uint64) string {
	return mustClaim(mustCourt(courtSlug), claimID).title
}

func HasAnswer(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).answeredAt != 0
}

func AnswerVerdict(courtSlug string, claimID uint64) int {
	return mustClaim(mustCourt(courtSlug), claimID).answer
}

func DisputeOpen(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).disputeOpen
}

func Settled(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).settled
}

func Verdict(courtSlug string, claimID uint64) int {
	return mustClaim(mustCourt(courtSlug), claimID).verdict
}

func VerdictRoute(courtSlug string, claimID uint64) string {
	return mustClaim(mustCourt(courtSlug), claimID).route
}

func StakePools(courtSlug string, claimID uint64) (yes, no int64) {
	cl := mustClaim(mustCourt(courtSlug), claimID)
	return cl.yesTotal, cl.noTotal
}

// Render lists a court's claims.
func Render(path string) string {
	if path == "" {
		out := "# kourtdev (stand-in for Kourt)\n\n"
		courts.Iterate("", "", func(k string, v any) bool {
			c := v.(*court)
			out += "- " + c.slug + " (" + c.name + "): " + strconv.FormatUint(c.nextID, 10) + " claims\n"
			return false
		})
		return out
	}
	c := mustCourt(path)
	out := "# " + c.name + "\n\n| id | title | answered | settled | verdict | route |\n|---|---|---|---|---|---|\n"
	c.claims.Iterate("", "", func(k string, v any) bool {
		cl := v.(*claim)
		out += "| " + strconv.FormatUint(cl.id, 10) + " | " + cl.title + " | " + strconv.FormatBool(cl.answeredAt != 0) + " | " + strconv.FormatBool(cl.settled) + " | " + strconv.Itoa(cl.verdict) + " | " + cl.route + " |\n"
		return false
	})
	return out
}
