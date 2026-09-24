// Package tally is the arithmetic of a Gnoracle dispute ballot: the commit
// hash a voter posts, the per-address cap applied to revealed weight, the
// quorum and supermajority test that turns weights into an outcome, and the
// penalty and reward figures that follow from a voter's choice.
//
// The DAO realm owns the ballots; this package only computes. Weights are
// int64 amounts of staked PYTH (base units); basis points use Bps.
package tally

import (
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"strconv"
)

// Bps is the basis-point denominator.
const Bps = int64(10_000)

// Choices a voter may reveal. OVERTURN_MINOR is offered only when the disputer
// asked for the major tier; it lets voters agree the value was wrong but
// downgrade the slash.
const (
	ChoiceUphold        = "UPHOLD"
	ChoiceOverturn      = "OVERTURN"
	ChoiceOverturnMinor = "OVERTURN_MINOR"
	ChoiceVoid          = "VOID"
	ChoiceAbstain       = "ABSTAIN"
)

// Slash tiers named in a dispute and decided by the vote.
const (
	TierMinor = "minor"
	TierMajor = "major"
)

// Outcome of a resolved ballot round.
type Outcome string

const (
	OutcomeUphold   Outcome = "UPHOLD"
	OutcomeOverturn Outcome = "OVERTURN"
	OutcomeVoid     Outcome = "VOID"
	// OutcomeRoll: no quorum, or neither side reached the decision bar. The
	// dispute rolls to the next round (or voids after the last one).
	OutcomeRoll Outcome = "ROLL"
)

// Rules of one ballot round.
type Rules struct {
	QuorumBps        int64 // revealed weight (abstain included) over obligated weight
	DecisionBps      int64 // share of UPHOLD + OVERTURN(+MINOR) a side needs
	MaxVoterShareBps int64 // largest share of the obligated (sealed) weight one address's revealed weight may count for; the excess is clipped
	MajorRequested   bool  // whether OVERTURN_MINOR is a valid choice
}

// Weights are per-choice sums of revealed weight.
type Weights struct {
	Uphold        int64
	Overturn      int64
	OverturnMinor int64
	Void          int64
	Abstain       int64
}

// Total is the revealed weight including abstain.
func (w Weights) Total() int64 {
	return w.Uphold + w.Overturn + w.OverturnMinor + w.Void + w.Abstain
}

// Sides is UPHOLD plus every OVERTURN variant: the denominator of the
// decision bar.
func (w Weights) Sides() int64 { return w.Uphold + w.Overturn + w.OverturnMinor }

// Add credits weight to a choice. It panics on an unknown choice; validate
// with ValidChoice first.
func (w *Weights) Add(choice string, weight int64) {
	if weight < 0 {
		panic("tally: negative weight")
	}
	switch choice {
	case ChoiceUphold:
		w.Uphold += weight
	case ChoiceOverturn:
		w.Overturn += weight
	case ChoiceOverturnMinor:
		w.OverturnMinor += weight
	case ChoiceVoid:
		w.Void += weight
	case ChoiceAbstain:
		w.Abstain += weight
	default:
		panic("tally: unknown choice " + choice)
	}
}

// Sub removes weight from a choice (used by the clipping pass).
func (w *Weights) Sub(choice string, weight int64) {
	w.Add(choice, 0)
	switch choice {
	case ChoiceUphold:
		w.Uphold -= weight
	case ChoiceOverturn:
		w.Overturn -= weight
	case ChoiceOverturnMinor:
		w.OverturnMinor -= weight
	case ChoiceVoid:
		w.Void -= weight
	case ChoiceAbstain:
		w.Abstain -= weight
	}
}

// ValidChoice reports whether choice may be revealed under the rules.
func ValidChoice(choice string, majorRequested bool) bool {
	switch choice {
	case ChoiceUphold, ChoiceOverturn, ChoiceVoid, ChoiceAbstain:
		return true
	case ChoiceOverturnMinor:
		return majorRequested
	}
	return false
}

// Commitment is the hash a voter commits: hex(sha256 of a canonical string
// binding the dispute, the round, the choice, a salt and the voter). Binding
// the voter stops one address replaying another's commitment; binding the
// round stops a round-1 commitment being reused in round 2.
func Commitment(disputeID uint64, round int, choice, salt string, voter address) string {
	msg := "gnoracle|dispute|" + strconv.FormatUint(disputeID, 10) +
		"|" + strconv.Itoa(round) +
		"|" + choice +
		"|" + salt +
		"|" + string(voter)
	sum := sha256.Sum256([]byte(msg))
	return hex.EncodeToString(sum[:])
}

// Reveal is one voter's revealed ballot: the choice and the weight it carried
// before clipping.
type Reveal struct {
	Voter  address
	Choice string
	Weight int64
}

// TopK is the number of heaviest reveals a ballot keeps for the clipping pass.
// With a cap of at least 1/TopK of the revealed total, every voter above the
// cap is among the TopK heaviest, so clipping them is exact.
const TopK = 8

// InsertTop keeps top sorted by descending weight with at most TopK entries,
// inserting r if it belongs. It returns the updated slice.
func InsertTop(top []Reveal, r Reveal) []Reveal {
	if r.Weight <= 0 {
		return top
	}
	pos := len(top)
	for i := range top {
		if r.Weight > top[i].Weight {
			pos = i
			break
		}
	}
	if pos >= TopK {
		return top
	}
	top = append(top, Reveal{})
	copy(top[pos+1:], top[pos:])
	top[pos] = r
	if len(top) > TopK {
		top = top[:TopK]
	}
	return top
}

// ReplaceTop removes any earlier entry for r.Voter (a recommit that changed
// weight or choice) and inserts r.
func ReplaceTop(top []Reveal, r Reveal) []Reveal {
	out := make([]Reveal, 0, len(top))
	for _, e := range top {
		if e.Voter != r.Voter {
			out = append(out, e)
		}
	}
	return InsertTop(out, r)
}

// Clip applies the per-address cap: no reveal counts for more than capBps
// of the obligated (sealed) weight. The cap is fixed, so it is applied once
// to each of the heaviest reveals; capping against the revealed total would
// have no fixed point when few members vote. It returns the clipped weights
// and the total weight removed. capBps must be at least Bps/TopK, so that no
// voter outside the kept heaviest can exceed the cap; the DAO's parameter
// bounds enforce that.
func Clip(w Weights, top []Reveal, capBps, obligated int64) (Weights, int64) {
	if capBps <= 0 || capBps > Bps {
		panic("tally: cap out of range")
	}
	if capBps*int64(TopK) < Bps {
		panic("tally: cap below 1/TopK cannot be applied exactly")
	}
	if obligated <= 0 {
		return w, 0
	}
	limit := mulDiv(obligated, capBps, Bps)
	var removed int64
	for _, r := range top {
		if r.Weight > limit {
			excess := r.Weight - limit
			w.Sub(r.Choice, excess)
			removed += excess
		}
	}
	return w, removed
}

// Result of deciding one round.
type Result struct {
	Outcome   Outcome
	Tier      string // TierMajor or TierMinor when Outcome is OVERTURN, else ""
	Quorate   bool
	Revealed  int64
	Obligated int64
	Weights   Weights // as decided (after clipping)
}

// Decide applies the plan's rules (§7.3) to clipped weights:
//   - quorum: revealed (abstain included) >= QuorumBps of obligated;
//   - VOID wins with a strict majority of the non-abstain weight;
//   - otherwise a side needs DecisionBps of UPHOLD + OVERTURN(+MINOR);
//   - an OVERTURN win is major when OVERTURN outweighs OVERTURN_MINOR, else minor;
//   - anything else rolls.
func Decide(w Weights, obligated int64, r Rules) Result {
	if obligated < 0 || r.QuorumBps < 0 || r.QuorumBps > Bps || r.DecisionBps <= Bps/2 || r.DecisionBps > Bps {
		panic("tally: malformed rules")
	}
	res := Result{Outcome: OutcomeRoll, Revealed: w.Total(), Obligated: obligated, Weights: w}
	// quorum: revealed * Bps >= obligated * QuorumBps (128-bit safe)
	res.Quorate = geMul(res.Revealed, Bps, obligated, r.QuorumBps) && res.Revealed > 0
	if !res.Quorate {
		return res
	}
	nonAbstain := res.Revealed - w.Abstain
	if nonAbstain > 0 && w.Void*2 > nonAbstain {
		res.Outcome = OutcomeVoid
		return res
	}
	sides := w.Sides()
	if sides <= 0 {
		return res
	}
	overturn := w.Overturn + w.OverturnMinor
	switch {
	case geMul(w.Uphold, Bps, sides, r.DecisionBps):
		res.Outcome = OutcomeUphold
	case geMul(overturn, Bps, sides, r.DecisionBps):
		res.Outcome = OutcomeOverturn
		// major only when it was asked for and outweighs minor
		res.Tier = TierMinor
		if r.MajorRequested && w.Overturn > w.OverturnMinor {
			res.Tier = TierMajor
		}
	}
	return res
}

// Class of a member with respect to a decided round.
type Class string

const (
	ClassAbsent     Class = "absent"
	ClassAbstained  Class = "abstained"
	ClassCoherent   Class = "coherent"
	ClassIncoherent Class = "incoherent"
	ClassExempt     Class = "exempt" // not obligated, or no penalties apply
)

// Classify places a member's reveal against the outcome. On a VOID outcome or
// a roll nobody is incoherent (only absence counts); an OVERTURN_MINOR reveal
// is coherent with an OVERTURN outcome at either tier.
func Classify(revealed bool, choice string, res Result) Class {
	if !revealed {
		return ClassAbsent
	}
	if choice == ChoiceAbstain {
		return ClassAbstained
	}
	switch res.Outcome {
	case OutcomeUphold:
		if choice == ChoiceUphold {
			return ClassCoherent
		}
		return ClassIncoherent
	case OutcomeOverturn:
		if choice == ChoiceOverturn || choice == ChoiceOverturnMinor {
			return ClassCoherent
		}
		return ClassIncoherent
	case OutcomeVoid:
		if choice == ChoiceVoid {
			return ClassCoherent
		}
		return ClassExempt
	}
	return ClassExempt
}

// Rates are the DAO's voter penalty parameters.
type Rates struct {
	AbsenceBps     int64
	IncoherenceBps int64
	AbstainBps     int64
}

// Penalty is the amount taken from a member of the given class and weight.
// Coherent and exempt members pay nothing.
func Penalty(weight int64, class Class, rates Rates) int64 {
	if weight < 0 {
		panic("tally: negative weight")
	}
	switch class {
	case ClassAbsent:
		return mulDiv(weight, rates.AbsenceBps, Bps)
	case ClassAbstained:
		return mulDiv(weight, rates.AbstainBps, Bps)
	case ClassIncoherent:
		return mulDiv(weight, rates.IncoherenceBps, Bps)
	}
	return 0
}

// CoherentWeight is the weight that voted with the outcome.
func CoherentWeight(res Result) int64 {
	switch res.Outcome {
	case OutcomeUphold:
		return res.Weights.Uphold
	case OutcomeOverturn:
		return res.Weights.Overturn + res.Weights.OverturnMinor
	case OutcomeVoid:
		return res.Weights.Void
	}
	return 0
}

// ExpectedPenaltyPool is what the penalties of a decided round add up to,
// computed from the ballot alone at resolution: absent weight (obligated minus
// revealed), abstain weight and incoherent weight at their rates. It is what
// coherent members are paid against as they settle, before the penalised
// members have actually been processed (§8.4). Clipped-away weight counts as
// revealed, never as absent.
func ExpectedPenaltyPool(res Result, clippedAway int64, rates Rates) int64 {
	absent := res.Obligated - res.Revealed - clippedAway
	if absent < 0 {
		absent = 0
	}
	pool := mulDiv(absent, rates.AbsenceBps, Bps) + mulDiv(res.Weights.Abstain, rates.AbstainBps, Bps)
	var incoherent int64
	switch res.Outcome {
	case OutcomeUphold:
		incoherent = res.Weights.Overturn + res.Weights.OverturnMinor + res.Weights.Void
	case OutcomeOverturn:
		incoherent = res.Weights.Uphold + res.Weights.Void
	}
	return pool + mulDiv(incoherent, rates.IncoherenceBps, Bps)
}

// RewardShare is a coherent member's pro-rata share of a pool.
func RewardShare(pool, weight, coherentWeight int64) int64 {
	if coherentWeight <= 0 || weight <= 0 || pool <= 0 {
		return 0
	}
	if weight > coherentWeight {
		weight = coherentWeight
	}
	return mulDiv(pool, weight, coherentWeight)
}

// geMul reports a*b >= c*d for non-negative inputs without overflow.
func geMul(a, b, c, d int64) bool {
	if a < 0 || b < 0 || c < 0 || d < 0 {
		panic("tally: negative operand")
	}
	lhsHi, lhsLo := bits.Mul64(uint64(a), uint64(b))
	rhsHi, rhsLo := bits.Mul64(uint64(c), uint64(d))
	if lhsHi != rhsHi {
		return lhsHi > rhsHi
	}
	return lhsLo >= rhsLo
}

// mulDiv is floor(a*b/d) with a 128-bit intermediate.
func mulDiv(a, b, d int64) int64 {
	if a < 0 || b < 0 || d <= 0 {
		panic("tally: mulDiv needs non-negative factors and a positive divisor")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(d) {
		panic("tally: mulDiv overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(d))
	if q > uint64(1<<63-1) {
		panic("tally: mulDiv overflow")
	}
	return int64(q)
}
