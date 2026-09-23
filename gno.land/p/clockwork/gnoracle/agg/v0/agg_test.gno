package agg_test

import (
	"testing"

	"gno.land/p/clockwork/gnoracle/agg/v0"
	"gno.land/p/nt/uassert/v0"
)

func subs(present []bool, values ...int64) agg.Submissions {
	if present == nil {
		present = make([]bool, len(values))
		for i := range present {
			present[i] = true
		}
	}
	return agg.Submissions{Values: values, Present: present}
}

func TestLowerMedianIsAlwaysASubmittedValue(t *testing.T) {
	m, ok := agg.LowerMedian(subs(nil, 5, 3, 1, 9))
	uassert.True(t, ok)
	uassert.Equal(t, int64(3), m) // even count: the lower of the middle pair

	m, ok = agg.LowerMedian(subs(nil, 5, 3, 1))
	uassert.True(t, ok)
	uassert.Equal(t, int64(3), m)

	m, ok = agg.LowerMedian(subs(nil, 42))
	uassert.True(t, ok)
	uassert.Equal(t, int64(42), m)

	_, ok = agg.LowerMedian(subs([]bool{false, false}, 1, 2))
	uassert.False(t, ok)
}

func TestLowerMedianIgnoresAbsentSlotsAndDoesNotMutateInput(t *testing.T) {
	values := []int64{100, 1, 50, 7}
	present := []bool{true, false, true, false}
	m, ok := agg.LowerMedian(agg.Submissions{Values: values, Present: present})
	uassert.True(t, ok)
	uassert.Equal(t, int64(50), m)
	uassert.Equal(t, int64(100), values[0]) // caller's slice untouched
	uassert.Equal(t, int64(1), values[1])
}

func TestLowerMedianWithNegativesAndExtremes(t *testing.T) {
	m, _ := agg.LowerMedian(subs(nil, -5, -1, -3))
	uassert.Equal(t, int64(-3), m)
	m, _ = agg.LowerMedian(subs(nil, 9223372036854775807, -9223372036854775808))
	uassert.Equal(t, int64(-9223372036854775808), m)
}

func TestPluralityAndTies(t *testing.T) {
	w, votes, unique := agg.Plurality(subs(nil, 1, 1, 0, 2, 1), 3)
	uassert.True(t, unique)
	uassert.Equal(t, int64(1), w)
	uassert.Equal(t, 3, votes)

	_, _, unique = agg.Plurality(subs(nil, 0, 1), 2)
	uassert.False(t, unique) // tie for first: empty round

	_, votes, unique = agg.Plurality(subs(nil, 7, -1), 3) // out of range: not counted
	uassert.False(t, unique)
	uassert.Equal(t, 0, votes)

	w, votes, unique = agg.Plurality(subs([]bool{true, false, true}, 2, 0, 2), 3)
	uassert.True(t, unique)
	uassert.Equal(t, int64(2), w)
	uassert.Equal(t, 2, votes)
}

func TestWithinTolerance(t *testing.T) {
	uassert.True(t, agg.WithinTolerance(1010, 1000, 100))  // exactly 1%
	uassert.False(t, agg.WithinTolerance(1011, 1000, 100)) // just over
	uassert.True(t, agg.WithinTolerance(990, 1000, 100))
	uassert.True(t, agg.WithinTolerance(-1010, -1000, 100)) // sign-symmetric
	uassert.True(t, agg.WithinTolerance(0, 0, 100))
	uassert.False(t, agg.WithinTolerance(1, 0, 10000)) // zero reference tolerates only zero
	uassert.True(t, agg.WithinTolerance(5, 5, 0))      // zero tolerance: equality
	uassert.False(t, agg.WithinTolerance(6, 5, 0))
	// No overflow at the extremes: the difference spans the whole int64 range.
	uassert.False(t, agg.WithinTolerance(9223372036854775807, -9223372036854775808, 10000))
	uassert.True(t, agg.WithinTolerance(9223372036854775807, 9223372036854775807, 0))
}

func TestEligibleMasks(t *testing.T) {
	s := subs([]bool{true, true, false, true}, 1000, 1005, 999999, 1200)
	median, _ := agg.LowerMedian(s) // present: 1000, 1005, 1200 -> 1005
	uassert.Equal(t, int64(1005), median)
	mask, n := agg.EligibleNumeric(s, median, 100)
	uassert.Equal(t, 2, n)
	uassert.Equal(t, uint32(0b0011), mask) // slots 0 and 1; slot 3 is 19% off; slot 2 absent
	uassert.Equal(t, uint32(0b1011), agg.PresentMask(s))
	uassert.Equal(t, 2, agg.PopCount(mask))

	c := subs(nil, 1, 0, 1)
	mask, n = agg.EligibleCategorical(c, 1)
	uassert.Equal(t, 2, n)
	uassert.Equal(t, uint32(0b101), mask)
}

func TestDecideTier(t *testing.T) {
	base := agg.TierInput{Eligible: 5, Active: 5, MinProviders: 3, Value: 1000, LastFinal: 995, HaveLast: true, QuarantineBps: 1000}
	uassert.Equal(t, string(agg.TierConsensus), string(agg.DecideTier(base)))

	thin := base
	thin.Eligible = 2
	uassert.Equal(t, string(agg.TierEmpty), string(agg.DecideTier(thin)))

	divergent := base
	divergent.Eligible = 3 // 3 of 5 is below two thirds
	uassert.Equal(t, string(agg.TierProvisional), string(agg.DecideTier(divergent)))

	twoThirds := base
	twoThirds.Eligible, twoThirds.Active = 4, 6 // exactly two thirds passes
	uassert.Equal(t, string(agg.TierConsensus), string(agg.DecideTier(twoThirds)))

	bigMove := base
	bigMove.Value = 1200 // 20% from last final, quarantine is 10%
	uassert.Equal(t, string(agg.TierProvisional), string(agg.DecideTier(bigMove)))

	first := base
	first.HaveLast = false
	first.Value = 1_000_000
	uassert.Equal(t, string(agg.TierConsensus), string(agg.DecideTier(first)))
}

func TestMulDivShareSplit(t *testing.T) {
	uassert.Equal(t, int64(7000), agg.Share(10_000, 7000))
	uassert.Equal(t, int64(0), agg.Share(1, 5000)) // rounds down
	// a*b exceeds int64 but the quotient fits
	uassert.Equal(t, int64(9223372036854775807), agg.MulDiv(9223372036854775807, 10_000, 10_000))
	uassert.Equal(t, int64(4611686018427387903), agg.MulDiv(9223372036854775807, 5000, 10_000))

	share, dust := agg.SplitEqual(100, 3)
	uassert.Equal(t, int64(33), share)
	uassert.Equal(t, int64(1), dust)
	share, dust = agg.SplitEqual(0, 5)
	uassert.Equal(t, int64(0), share)
	uassert.Equal(t, int64(0), dust)
}

func TestMulDivRefusesOverflowAndBadDivisor(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "agg: MulDiv overflow", func() {
		agg.MulDiv(9223372036854775807, 10_000, 1)
	})
	uassert.PanicsWithMessage(t, cur, "agg: MulDiv needs non-negative factors and a positive divisor", func() {
		agg.MulDiv(1, 1, 0)
	})
	uassert.PanicsWithMessage(t, cur, "agg: malformed submissions", func() {
		agg.LowerMedian(agg.Submissions{Values: []int64{1}, Present: []bool{true, true}})
	})
}

func TestCategoricalTierIgnoresTheMoveTest(t *testing.T) {
	in := agg.TierInput{Eligible: 3, Active: 3, MinProviders: 2, Value: 2, LastFinal: 0, HaveLast: true, QuarantineBps: 1000, Categorical: true}
	if got := agg.DecideTier(in); got != agg.TierConsensus {
		t.Fatalf("categorical change of option must stay consensus, got %s", got)
	}
	in.Categorical = false
	if got := agg.DecideTier(in); got != agg.TierProvisional {
		t.Fatalf("numeric jump from 0 must be provisional, got %s", got)
	}
}
