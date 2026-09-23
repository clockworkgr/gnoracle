package agent

import (
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
)

// Sample is one source's answer for one round.
type Sample struct {
	Source string   `json:"source"`
	Raw    string   `json:"raw,omitempty"`
	Num    *big.Rat `json:"-"`
	Value  string   `json:"value,omitempty"` // Num as text, for the journal
	Label  string   `json:"label,omitempty"`
	Err    string   `json:"err,omitempty"`
}

func (s *Sample) finish() {
	if s.Num != nil {
		s.Value = s.Num.FloatString(12)
	}
}

// Aggregate reduces samples to one value: the lower median of the numeric
// samples, or the plurality label of the categorical ones. It fails when
// fewer than minSources samples succeeded or a categorical vote ties.
func Aggregate(samples []Sample, numeric bool, minSources int) (*big.Rat, string, error) {
	if minSources < 1 {
		minSources = 1
	}
	if numeric {
		var vals []*big.Rat
		for _, s := range samples {
			if s.Err == "" && s.Num != nil {
				vals = append(vals, s.Num)
			}
		}
		if len(vals) < minSources {
			return nil, "", fmt.Errorf("%d of %d sources answered, %d required", len(vals), len(samples), minSources)
		}
		sort.Slice(vals, func(i, j int) bool { return vals[i].Cmp(vals[j]) < 0 })
		return vals[(len(vals)-1)/2], "", nil
	}
	counts := map[string]int{}
	total := 0
	for _, s := range samples {
		if s.Err == "" && s.Label != "" {
			counts[s.Label]++
			total++
		}
	}
	if total < minSources {
		return nil, "", fmt.Errorf("%d of %d sources answered, %d required", total, len(samples), minSources)
	}
	best, bestN, tie := "", 0, false
	for l, n := range counts {
		switch {
		case n > bestN:
			best, bestN, tie = l, n, false
		case n == bestN:
			tie = true
		}
	}
	if tie {
		return nil, "", errors.New("categorical sources disagree with no plurality")
	}
	return nil, best, nil
}

var maxInt64 = big.NewRat(1<<63-1, 1)

// ScaleToInt converts v to the feed's integer representation, rounding half
// away from zero.
func ScaleToInt(v *big.Rat, decimals int) (int64, error) {
	if v == nil {
		return 0, errors.New("no value")
	}
	scaled := new(big.Rat).Mul(v, new(big.Rat).SetInt(pow10(decimals)))
	// round half away from zero
	num := new(big.Int).Set(scaled.Num())
	den := scaled.Denom()
	twice := new(big.Int).Mul(num, big.NewInt(2))
	q, r := new(big.Int).QuoRem(new(big.Int).Abs(twice), new(big.Int).Mul(den, big.NewInt(2)), new(big.Int))
	if r.Cmp(den) >= 0 {
		q.Add(q, big.NewInt(1))
	}
	if num.Sign() < 0 {
		q.Neg(q)
	}
	if !q.IsInt64() || new(big.Rat).SetInt(q).Cmp(maxInt64) > 0 {
		return 0, fmt.Errorf("value %s does not fit int64 at %d decimals", v.FloatString(6), decimals)
	}
	return q.Int64(), nil
}

// FormatScaled prints an integer value in feed units.
func FormatScaled(v int64, decimals int) string {
	if decimals <= 0 {
		return fmt.Sprintf("%d", v)
	}
	neg := v < 0
	if neg {
		v = -v
	}
	s := fmt.Sprintf("%0*d", decimals+1, v)
	out := s[:len(s)-decimals] + "." + s[len(s)-decimals:]
	if neg {
		out = "-" + out
	}
	return out
}

func pow10(n int) *big.Int {
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(n)), nil)
}

// WithinBps reports whether v is within bps basis points of ref. A zero
// reference accepts only zero.
func WithinBps(v, ref, bps int64) bool {
	if ref == 0 {
		return v == 0
	}
	diff := new(big.Int).Sub(big.NewInt(v), big.NewInt(ref))
	diff.Abs(diff).Mul(diff, big.NewInt(10_000))
	limit := new(big.Int).Abs(big.NewInt(ref))
	limit.Mul(limit, big.NewInt(bps))
	return diff.Cmp(limit) <= 0
}

// OptionIndex resolves a categorical label (after the optional mapping) to
// the feed's option index. Labels match case-insensitively; a bare index is
// accepted too.
func OptionIndex(options []string, label string, mapping map[string]string) (int64, error) {
	l := strings.TrimSpace(label)
	if m, ok := mapping[l]; ok {
		l = m
	}
	for i, o := range options {
		if strings.EqualFold(o, l) {
			return int64(i), nil
		}
	}
	var idx int64
	if _, err := fmt.Sscanf(l, "%d", &idx); err == nil && idx >= 0 && idx < int64(len(options)) {
		return idx, nil
	}
	return 0, fmt.Errorf("%q is not one of %v", label, options)
}

// ParseNumberOrLabel reads a source leaf: a number becomes Num, anything
// else a Label.
func ParseNumberOrLabel(s *Sample, text string) {
	t := strings.TrimSpace(text)
	if r, ok := new(big.Rat).SetString(t); ok && t != "" {
		s.Num = r
	} else {
		s.Label = t
	}
	s.finish()
}
