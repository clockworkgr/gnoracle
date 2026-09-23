package tally_test

import (
	"testing"

	"gno.land/p/clockwork/gnoracle/tally/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = address("g1alice000000000000000000000000000000000")
	bob   = address("g1bob00000000000000000000000000000000000")
	carol = address("g1carol000000000000000000000000000000000")
)

func rules() tally.Rules {
	return tally.Rules{QuorumBps: 3300, DecisionBps: 6000, MaxVoterShareBps: 2000, MajorRequested: true}
}

func TestCommitmentBindsEverything(t *testing.T) {
	c := tally.Commitment(7, 1, tally.ChoiceUphold, "salt", alice)
	uassert.Equal(t, 64, len(c))
	uassert.Equal(t, c, tally.Commitment(7, 1, tally.ChoiceUphold, "salt", alice))
	uassert.NotEqual(t, c, tally.Commitment(8, 1, tally.ChoiceUphold, "salt", alice))
	uassert.NotEqual(t, c, tally.Commitment(7, 2, tally.ChoiceUphold, "salt", alice))
	uassert.NotEqual(t, c, tally.Commitment(7, 1, tally.ChoiceOverturn, "salt", alice))
	uassert.NotEqual(t, c, tally.Commitment(7, 1, tally.ChoiceUphold, "other", alice))
	uassert.NotEqual(t, c, tally.Commitment(7, 1, tally.ChoiceUphold, "salt", bob))
}

func TestValidChoice(t *testing.T) {
	uassert.True(t, tally.ValidChoice(tally.ChoiceUphold, false))
	uassert.True(t, tally.ValidChoice(tally.ChoiceVoid, false))
	uassert.True(t, tally.ValidChoice(tally.ChoiceAbstain, false))
	uassert.False(t, tally.ValidChoice(tally.ChoiceOverturnMinor, false))
	uassert.True(t, tally.ValidChoice(tally.ChoiceOverturnMinor, true))
	uassert.False(t, tally.ValidChoice("yes", true))
}

func TestDecideQuorumAndSupermajority(t *testing.T) {
	obligated := int64(1000)
	// below quorum: 320 of 1000 revealed
	res := tally.Decide(tally.Weights{Uphold: 320}, obligated, rules())
	uassert.False(t, res.Quorate)
	uassert.Equal(t, string(tally.OutcomeRoll), string(res.Outcome))

	// quorum met exactly at 330 (33%)
	res = tally.Decide(tally.Weights{Uphold: 330}, obligated, rules())
	uassert.True(t, res.Quorate)
	uassert.Equal(t, string(tally.OutcomeUphold), string(res.Outcome))

	// abstain counts to quorum, not to the decision
	res = tally.Decide(tally.Weights{Uphold: 100, Abstain: 300}, obligated, rules())
	uassert.True(t, res.Quorate)
	uassert.Equal(t, string(tally.OutcomeUphold), string(res.Outcome))

	// neither side at 60%: 59% overturn rolls
	res = tally.Decide(tally.Weights{Uphold: 410, Overturn: 590}, obligated, rules())
	uassert.Equal(t, string(tally.OutcomeRoll), string(res.Outcome))
	// exactly 60% overturn decides
	res = tally.Decide(tally.Weights{Uphold: 400, Overturn: 600}, obligated, rules())
	uassert.Equal(t, string(tally.OutcomeOverturn), string(res.Outcome))
	uassert.Equal(t, tally.TierMajor, res.Tier)
	// minor outweighs major: overturn at the minor tier
	res = tally.Decide(tally.Weights{Uphold: 100, Overturn: 200, OverturnMinor: 400}, obligated, rules())
	uassert.Equal(t, string(tally.OutcomeOverturn), string(res.Outcome))
	uassert.Equal(t, tally.TierMinor, res.Tier)
	// a tie between the two overturn variants is minor
	res = tally.Decide(tally.Weights{Overturn: 300, OverturnMinor: 300}, obligated, rules())
	uassert.Equal(t, tally.TierMinor, res.Tier)
	// minor requested only: tier is minor
	r := rules()
	r.MajorRequested = false
	res = tally.Decide(tally.Weights{Overturn: 600}, obligated, r)
	uassert.Equal(t, tally.TierMinor, res.Tier)
}

func TestDecideVoid(t *testing.T) {
	obligated := int64(1000)
	// VOID needs a strict majority of the non-abstain weight
	res := tally.Decide(tally.Weights{Uphold: 200, Void: 201, Abstain: 500}, obligated, rules())
	uassert.Equal(t, string(tally.OutcomeVoid), string(res.Outcome))
	res = tally.Decide(tally.Weights{Uphold: 200, Void: 200, Abstain: 500}, obligated, rules())
	uassert.NotEqual(t, string(tally.OutcomeVoid), string(res.Outcome))
	// all abstain: quorate, nothing decided, rolls
	res = tally.Decide(tally.Weights{Abstain: 400}, obligated, rules())
	uassert.True(t, res.Quorate)
	uassert.Equal(t, string(tally.OutcomeRoll), string(res.Outcome))
	// nothing revealed at all is never quorate, even with zero obligated weight
	res = tally.Decide(tally.Weights{}, 0, rules())
	uassert.False(t, res.Quorate)
}

func TestTopAndClip(t *testing.T) {
	var top []tally.Reveal
	top = tally.InsertTop(top, tally.Reveal{Voter: alice, Choice: tally.ChoiceOverturn, Weight: 500})
	top = tally.InsertTop(top, tally.Reveal{Voter: bob, Choice: tally.ChoiceUphold, Weight: 100})
	top = tally.InsertTop(top, tally.Reveal{Voter: carol, Choice: tally.ChoiceUphold, Weight: 300})
	uassert.Equal(t, 3, len(top))
	uassert.Equal(t, string(alice), string(top[0].Voter))
	uassert.Equal(t, string(carol), string(top[1].Voter))
	uassert.Equal(t, string(bob), string(top[2].Voter))

	// alice recommits with less weight: replaced, not duplicated
	top = tally.ReplaceTop(top, tally.Reveal{Voter: alice, Choice: tally.ChoiceOverturn, Weight: 350})
	uassert.Equal(t, 3, len(top))
	uassert.Equal(t, int64(350), top[0].Weight)

	// the list never grows past TopK and keeps the heaviest
	for i := 0; i < 20; i++ {
		top = tally.InsertTop(top, tally.Reveal{Voter: address("g1x" + string(rune('a'+i))), Choice: tally.ChoiceUphold, Weight: int64(10 + i)})
	}
	uassert.Equal(t, tally.TopK, len(top))
	uassert.Equal(t, int64(350), top[0].Weight)
	uassert.Equal(t, int64(300), top[1].Weight)
	uassert.Equal(t, int64(100), top[2].Weight)
	uassert.Equal(t, int64(29), top[3].Weight)

	// clipping: one whale with 60% of the revealed weight, cap 20% of the
	// obligated weight (1000)
	w := tally.Weights{Overturn: 600, Uphold: 400}
	whale := []tally.Reveal{{Voter: alice, Choice: tally.ChoiceOverturn, Weight: 600}}
	clipped, removed := tally.Clip(w, whale, 2000, 1000)
	uassert.Equal(t, int64(200), clipped.Overturn) // capped at 20% of 1000
	uassert.Equal(t, int64(400), clipped.Uphold)
	uassert.Equal(t, int64(400), removed)
	res := tally.Decide(clipped, 1000, rules())
	uassert.Equal(t, string(tally.OutcomeUphold), string(res.Outcome))

	// the cap is applied once per heavy voter, never iterated to nothing
	three := tally.Weights{Overturn: 1000, Uphold: 400}
	tops := []tally.Reveal{{Voter: alice, Choice: tally.ChoiceOverturn, Weight: 1000}, {Voter: bob, Choice: tally.ChoiceUphold, Weight: 300}, {Voter: carol, Choice: tally.ChoiceUphold, Weight: 100}}
	clipped, removed = tally.Clip(three, tops, 2000, 1400)
	uassert.Equal(t, int64(280), clipped.Overturn) // 20% of 1400
	uassert.Equal(t, int64(380), clipped.Uphold)   // bob 300 -> 280, carol 100
	uassert.Equal(t, int64(740), removed)

	// nobody above the cap: untouched
	clipped, removed = tally.Clip(tally.Weights{Uphold: 100, Overturn: 100}, []tally.Reveal{{Voter: bob, Choice: tally.ChoiceUphold, Weight: 30}}, 2000, 1000)
	uassert.Equal(t, int64(0), removed)
	uassert.Equal(t, int64(100), clipped.Uphold)
}

func TestClipRefusesInexactCap(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "tally: cap below 1/TopK cannot be applied exactly", func() {
		tally.Clip(tally.Weights{Uphold: 1}, nil, 1000, 1000)
	})
}

func TestClassifyAndPenalties(t *testing.T) {
	rates := tally.Rates{AbsenceBps: 50, IncoherenceBps: 50, AbstainBps: 5}
	up := tally.Decide(tally.Weights{Uphold: 700, Overturn: 300}, 1000, rules())
	uassert.Equal(t, string(tally.ClassAbsent), string(tally.Classify(false, "", up)))
	uassert.Equal(t, string(tally.ClassAbstained), string(tally.Classify(true, tally.ChoiceAbstain, up)))
	uassert.Equal(t, string(tally.ClassCoherent), string(tally.Classify(true, tally.ChoiceUphold, up)))
	uassert.Equal(t, string(tally.ClassIncoherent), string(tally.Classify(true, tally.ChoiceOverturn, up)))
	uassert.Equal(t, string(tally.ClassIncoherent), string(tally.Classify(true, tally.ChoiceVoid, up)))

	ov := tally.Decide(tally.Weights{Uphold: 100, Overturn: 300, OverturnMinor: 400}, 1000, rules())
	uassert.Equal(t, string(tally.ClassCoherent), string(tally.Classify(true, tally.ChoiceOverturnMinor, ov)))
	uassert.Equal(t, string(tally.ClassCoherent), string(tally.Classify(true, tally.ChoiceOverturn, ov)))
	uassert.Equal(t, string(tally.ClassIncoherent), string(tally.Classify(true, tally.ChoiceUphold, ov)))

	vd := tally.Decide(tally.Weights{Uphold: 200, Void: 500}, 1000, rules())
	uassert.Equal(t, string(tally.ClassExempt), string(tally.Classify(true, tally.ChoiceUphold, vd))) // no incoherence on VOID
	uassert.Equal(t, string(tally.ClassCoherent), string(tally.Classify(true, tally.ChoiceVoid, vd)))
	uassert.Equal(t, string(tally.ClassAbsent), string(tally.Classify(false, "", vd))) // absence still counts

	roll := tally.Decide(tally.Weights{Uphold: 100}, 1000, rules())
	uassert.Equal(t, string(tally.ClassExempt), string(tally.Classify(true, tally.ChoiceUphold, roll)))

	uassert.Equal(t, int64(5), tally.Penalty(1000, tally.ClassAbsent, rates))
	uassert.Equal(t, int64(5), tally.Penalty(1000, tally.ClassIncoherent, rates))
	uassert.Equal(t, int64(0), tally.Penalty(1000, tally.ClassAbstained, rates)) // 0.05% of 1000 rounds to 0
	uassert.Equal(t, int64(50), tally.Penalty(100_000, tally.ClassAbstained, rates))
	uassert.Equal(t, int64(0), tally.Penalty(1000, tally.ClassCoherent, rates))
	uassert.Equal(t, int64(0), tally.Penalty(1000, tally.ClassExempt, rates))
}

func TestExpectedPoolAndRewards(t *testing.T) {
	rates := tally.Rates{AbsenceBps: 50, IncoherenceBps: 50, AbstainBps: 5}
	// obligated 10_000: 6_000 uphold, 2_000 overturn, 1_000 abstain, 1_000 absent
	res := tally.Decide(tally.Weights{Uphold: 6000, Overturn: 2000, Abstain: 1000}, 10_000, rules())
	uassert.Equal(t, string(tally.OutcomeUphold), string(res.Outcome))
	pool := tally.ExpectedPenaltyPool(res, 0, rates)
	// absent 1000*0.5% = 5, abstain 1000*0.05% = 0 (floor), incoherent 2000*0.5% = 10
	uassert.Equal(t, int64(15), pool)
	uassert.Equal(t, int64(6000), tally.CoherentWeight(res))
	uassert.Equal(t, int64(7), tally.RewardShare(pool, 3000, 6000)) // floor(15*3000/6000)
	uassert.Equal(t, int64(0), tally.RewardShare(pool, 0, 6000))
	uassert.Equal(t, int64(15), tally.RewardShare(pool, 9000, 6000)) // capped at the whole pool

	// clipped-away weight is not absent
	pool2 := tally.ExpectedPenaltyPool(res, 1000, rates)
	uassert.Equal(t, int64(10), pool2)

	// a void outcome charges only absence and abstain
	vd := tally.Decide(tally.Weights{Uphold: 2000, Void: 5000}, 10_000, rules())
	uassert.Equal(t, int64(15), tally.ExpectedPenaltyPool(vd, 0, rates)) // absent 3000 -> 15
}
