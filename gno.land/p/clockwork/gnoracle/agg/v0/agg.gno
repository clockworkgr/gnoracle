// Package agg holds the aggregation arithmetic of a Gnoracle round: the lower
// median of the numeric submissions, the plurality of the categorical ones,
// the tolerance test that decides which submissions are rewarded, and the
// status tier a finalised round is served under.
//
// Everything here is pure, integer-only and bounded by MaxSlots. A round has at
// most MaxSlots provider slots, so every loop is at most that long and the
// masks fit in a uint32. Nothing here reads realm state; the realm hands in
// the slot values and keeps the result.
package agg

import (
	"math/bits"
)

// MaxSlots is the largest number of provider slots a feed may have. It bounds
// every loop in this package and the width of the slot masks.
const MaxSlots = 15

// Bps is the basis-point denominator used by every relative quantity.
const Bps = int64(10_000)

// Tier is the status a finalised round is served under.
type Tier string

const (
	// TierConsensus: at least minProviders eligible, at least two thirds of the
	// active set eligible, and the aggregate moved at most quarantineBps from
	// the last final value. Usable immediately.
	TierConsensus Tier = "consensus"
	// TierProvisional: aggregated, but thin, divergent, or a large move. Usable
	// at the consumer's risk until the dispute window passes.
	TierProvisional Tier = "provisional"
	// TierEmpty: fewer than minProviders eligible submissions, or a categorical
	// tie. The round carries no value.
	TierEmpty Tier = "empty"
)

// Submissions is what the realm hands in: one value per slot, and whether the
// slot submitted this round. Slots that did not submit are ignored.
type Submissions struct {
	Values  []int64
	Present []bool
}

// count returns the number of present slots. It panics on malformed input, a
// programming error in the caller rather than a user-facing condition.
func (s Submissions) count() int {
	if len(s.Values) != len(s.Present) || len(s.Values) > MaxSlots {
		panic("agg: malformed submissions")
	}
	n := 0
	for i := range s.Present {
		if s.Present[i] {
			n++
		}
	}
	return n
}

// Count is the number of slots that submitted.
func (s Submissions) Count() int { return s.count() }

// LowerMedian returns the lower median of the present values: the element at
// index (n-1)/2 of the sorted values, so the result is always a value some
// provider actually submitted. ok is false when nothing was submitted.
//
// Why the lower median and not the mean of the middle pair: a value nobody
// submitted cannot be attributed to a provider, and the tolerance test and the
// slash logic both attribute.
func LowerMedian(s Submissions) (median int64, ok bool) {
	n := s.count()
	if n == 0 {
		return 0, false
	}
	buf := make([]int64, 0, n)
	for i := range s.Values {
		if s.Present[i] {
			buf = append(buf, s.Values[i])
		}
	}
	insertionSort(buf)
	return buf[(n-1)/2], true
}

// Plurality returns the option with the most present submissions among
// options in [0, numOptions). unique is false on a tie for first place, in
// which case the round is empty; a value outside the option range is treated
// as not submitted.
func Plurality(s Submissions, numOptions int) (winner int64, votes int, unique bool) {
	if numOptions <= 0 || numOptions > 64 {
		panic("agg: option count out of range")
	}
	s.count()
	counts := make([]int, numOptions)
	for i := range s.Values {
		if !s.Present[i] {
			continue
		}
		v := s.Values[i]
		if v < 0 || v >= int64(numOptions) {
			continue
		}
		counts[v]++
	}
	best, bestVotes, ties := 0, 0, 0
	for o, c := range counts {
		switch {
		case c > bestVotes:
			best, bestVotes, ties = o, c, 1
		case c == bestVotes && c > 0:
			ties++
		}
	}
	if bestVotes == 0 {
		return 0, 0, false
	}
	return int64(best), bestVotes, ties == 1
}

// WithinTolerance reports whether v lies within toleranceBps of ref, measured
// relative to |ref|. A zero reference tolerates only zero. The comparison is
// |v - ref| * Bps <= |ref| * toleranceBps, computed in 128 bits so no input
// can overflow it.
func WithinTolerance(v, ref, toleranceBps int64) bool {
	if toleranceBps < 0 {
		panic("agg: negative tolerance")
	}
	if ref == 0 {
		return v == 0
	}
	diff := absDiff(v, ref)
	lhsHi, lhsLo := bits.Mul64(diff, uint64(Bps))
	rhsHi, rhsLo := bits.Mul64(abs(ref), uint64(toleranceBps))
	return lessOrEqual128(lhsHi, lhsLo, rhsHi, rhsLo)
}

// EligibleNumeric marks the present slots whose value is within toleranceBps
// of the median. The mask has bit i set for slot i.
func EligibleNumeric(s Submissions, median, toleranceBps int64) (mask uint32, count int) {
	s.count()
	for i := range s.Values {
		if s.Present[i] && WithinTolerance(s.Values[i], median, toleranceBps) {
			mask |= 1 << uint(i)
			count++
		}
	}
	return mask, count
}

// EligibleCategorical marks the present slots that submitted the winning
// option.
func EligibleCategorical(s Submissions, winner int64) (mask uint32, count int) {
	s.count()
	for i := range s.Values {
		if s.Present[i] && s.Values[i] == winner {
			mask |= 1 << uint(i)
			count++
		}
	}
	return mask, count
}

// PresentMask is the mask of slots that submitted.
func PresentMask(s Submissions) uint32 {
	s.count()
	var mask uint32
	for i := range s.Present {
		if s.Present[i] {
			mask |= 1 << uint(i)
		}
	}
	return mask
}

// TierInput is everything DecideTier needs.
type TierInput struct {
	Eligible      int   // eligible submissions this round
	Active        int   // size of the active provider set
	MinProviders  int   // the feed's minimum for an aggregate
	Value         int64 // this round's aggregate
	LastFinal     int64 // the last final value, if HaveLast
	HaveLast      bool
	QuarantineBps int64 // largest move from LastFinal that still counts as consensus
}

// DecideTier applies the consensus rule of the plan (§4.3): at least
// MinProviders eligible, at least two thirds of the active set eligible, and
// the value within QuarantineBps of the last final value (or no last value).
// Fewer than MinProviders eligible is an empty round.
func DecideTier(in TierInput) Tier {
	if in.MinProviders < 1 || in.Active < 0 || in.Eligible < 0 || in.Eligible > in.Active {
		panic("agg: malformed tier input")
	}
	if in.Eligible < in.MinProviders {
		return TierEmpty
	}
	if 3*in.Eligible < 2*in.Active {
		return TierProvisional
	}
	if in.HaveLast && !WithinTolerance(in.Value, in.LastFinal, in.QuarantineBps) {
		return TierProvisional
	}
	return TierConsensus
}

// MulDiv returns floor(a * b / d) for non-negative a and b and positive d,
// using a 128-bit intermediate so a * b may exceed int64. It panics when the
// quotient does not fit in an int64; callers hand in amounts and basis points,
// for which that is a programming error.
func MulDiv(a, b, d int64) int64 {
	if a < 0 || b < 0 || d <= 0 {
		panic("agg: MulDiv needs non-negative factors and a positive divisor")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(d) {
		panic("agg: MulDiv overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(d))
	if q > uint64(1<<63-1) {
		panic("agg: MulDiv overflow")
	}
	return int64(q)
}

// Share returns floor(amount * bps / Bps).
func Share(amount, bps int64) int64 {
	if bps < 0 || bps > Bps {
		panic("agg: basis points out of range")
	}
	return MulDiv(amount, bps, Bps)
}

// SplitEqual divides amount into n equal shares, rounding down, and returns
// the share and the dust left over. n must be positive.
func SplitEqual(amount int64, n int) (share, dust int64) {
	if n <= 0 || amount < 0 {
		panic("agg: SplitEqual needs a positive count and a non-negative amount")
	}
	share = amount / int64(n)
	return share, amount - share*int64(n)
}

// PopCount returns the number of set bits in a slot mask.
func PopCount(mask uint32) int { return bits.OnesCount32(mask) }

// insertionSort sorts in place. The slices here have at most MaxSlots
// elements, for which this is the cheapest correct sort, and the stdlib of the
// pinned toolchain has no sort.Slice.
func insertionSort(xs []int64) {
	for i := 1; i < len(xs); i++ {
		for j := i; j > 0 && xs[j-1] > xs[j]; j-- {
			xs[j-1], xs[j] = xs[j], xs[j-1]
		}
	}
}

// abs returns |x| as a uint64; it is exact for MinInt64 too.
func abs(x int64) uint64 {
	if x < 0 {
		return uint64(-(x + 1)) + 1
	}
	return uint64(x)
}

// absDiff returns |a - b| as a uint64 without overflowing.
func absDiff(a, b int64) uint64 {
	if a >= b {
		return uint64(a) - uint64(b)
	}
	return uint64(b) - uint64(a)
}

func lessOrEqual128(aHi, aLo, bHi, bLo uint64) bool {
	if aHi != bHi {
		return aHi < bHi
	}
	return aLo <= bLo
}
