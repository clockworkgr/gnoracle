// Package spec parses and validates a feed specification: the JSON document a
// requester submits with ProposeFeed (plan §4.1). The text is kept verbatim
// and hashed; every later submission, dispute and Kourt claim references the
// hash, so the words a feed was accepted under can never drift.
//
// Integers are read from the JSON text with strconv, never through float64,
// so amounts in base units round-trip exactly.
package spec

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"

	json "gno.land/p/onbloc/json/v0"
)

// Kinds and value types.
const (
	KindRecurring = "recurring"
	KindOneOff    = "oneoff"

	TypeNumeric     = "numeric"
	TypeCategorical = "categorical"
)

// Fixed bounds (plan §4.1).
const (
	MaxTextLen        = 4096
	MaxNameLen        = 64
	MaxDescriptionLen = 512
	MaxSourcesLen     = 2000
	MaxOptionLen      = 64
	MinOptions        = 2
	MaxOptions        = 16
	MaxDecimals       = 18
	MaxProviders      = 15
	MinInterval       = int64(60)
	MaxInterval       = int64(30 * 24 * 3600)
	MinSubmitWindow   = int64(60)
	MinDisputeWindow  = int64(2 * 3600)
	MaxDisputeWindow  = int64(14 * 24 * 3600)
	MinResolveLead    = int64(3600)
	MaxResolveLead    = int64(2 * 365 * 24 * 3600)
	MinToleranceBps   = int64(1)
	MaxToleranceBps   = int64(5000)
	MaxQuarantineBps  = int64(10_000)
	MaxTags           = 8
	MaxTagLen         = 32
)

// Limits are the DAO-level floors the spec must clear; they live in the DAO's
// parameter registry and are handed in at parse time.
type Limits struct {
	ProviderMinStakeFloor int64 // base units of the stake denom
	ReadPriceFloor        int64 // per metered read
	SubscriptionFloor     int64 // per period, recurring feeds
	BountyFloor           int64 // one-off feeds
}

// Spec is a validated feed specification.
type Spec struct {
	Name        string
	Description string
	Kind        string
	ValueType   string
	Decimals    int
	Options     []string
	// recurring
	Interval     int64
	SubmitWindow int64
	// one-off
	ResolveAt int64
	Bounty    int64

	Sources           string
	MinProviders      int
	MaxProviders      int
	ProviderMinStake  int64
	ToleranceBps      int64
	QuarantineBps     int64
	DisputeWindow     int64
	ReadPrice         int64
	SubscriptionPrice int64
	Sponsored         bool
	ValueAtStake      int64 // optional: what the requester says the outcome controls (trusted-requester cap)
	Tags              []string

	Text string // the JSON as submitted
	Hash string // hex sha256 of Text
}

// IsRecurring reports the kind.
func (s *Spec) IsRecurring() bool { return s.Kind == KindRecurring }

// IsNumeric reports the value type.
func (s *Spec) IsNumeric() bool { return s.ValueType == TypeNumeric }

// OptionLabel returns the label of a categorical option, or "" when out of
// range.
func (s *Spec) OptionLabel(i int64) string {
	if i < 0 || i >= int64(len(s.Options)) {
		return ""
	}
	return s.Options[i]
}

// ValidValue reports whether v is a legal submission for this spec: any int64
// for numeric feeds, an option index for categorical ones.
func (s *Spec) ValidValue(v int64) bool {
	if s.IsNumeric() {
		return true
	}
	return v >= 0 && v < int64(len(s.Options))
}

// HashText is hex(sha256(text)).
func HashText(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// Parse validates text against the fixed rules and the limits. now is the
// block time, used for one-off resolve times.
func Parse(text string, now int64, lim Limits) (*Spec, error) {
	if len(text) == 0 || len(text) > MaxTextLen {
		return nil, errors.New("spec: text must be 1 to 4096 bytes")
	}
	root, err := json.Unmarshal([]byte(text))
	if err != nil {
		return nil, errors.New("spec: invalid JSON: " + err.Error())
	}
	if !root.IsObject() {
		return nil, errors.New("spec: top level must be an object")
	}
	p := &parser{root: root}
	var unknown string
	root.ObjectEach(func(key string, _ *json.Node) {
		if unknown == "" && !knownKeys[key] {
			unknown = key
		}
	})
	if unknown != "" {
		return nil, errors.New("spec: unknown field " + strconv.Quote(unknown))
	}

	s := &Spec{Text: text, Hash: HashText(text)}
	s.Name = p.str("name", true, MaxNameLen)
	s.Description = p.str("description", false, MaxDescriptionLen)
	s.Kind = p.str("kind", true, 16)
	s.ValueType = p.str("valueType", true, 16)
	s.Sources = p.str("sources", true, MaxSourcesLen)
	s.Decimals = int(p.int("decimals", false, 0))
	s.Options = p.strs("options", MaxOptions, MaxOptionLen)
	s.Interval = p.int("interval", false, 0)
	s.SubmitWindow = p.int("submitWindow", true, 0)
	s.ResolveAt = p.int("resolveAt", false, 0)
	s.Bounty = p.int("bounty", false, 0)
	s.MinProviders = int(p.int("minProviders", true, 0))
	s.MaxProviders = int(p.int("maxProviders", true, 0))
	s.ProviderMinStake = p.int("providerMinStake", true, 0)
	s.ToleranceBps = p.int("toleranceBps", false, 100)
	s.QuarantineBps = p.int("quarantineBps", false, 1000)
	s.DisputeWindow = p.int("disputeWindow", true, 0)
	s.ReadPrice = p.int("readPrice", false, 0)
	s.SubscriptionPrice = p.int("subscriptionPrice", false, 0)
	s.Sponsored = p.boolean("sponsored")
	s.ValueAtStake = p.int("valueAtStake", false, 0)
	s.Tags = p.strs("tags", MaxTags, MaxTagLen)
	if p.err != nil {
		return nil, p.err
	}
	if err := s.validate(now, lim); err != nil {
		return nil, err
	}
	return s, nil
}

var knownKeys = map[string]bool{
	"name": true, "description": true, "kind": true, "valueType": true, "decimals": true,
	"options": true, "interval": true, "submitWindow": true, "resolveAt": true, "bounty": true,
	"sources": true, "minProviders": true, "maxProviders": true, "providerMinStake": true,
	"toleranceBps": true, "quarantineBps": true, "disputeWindow": true, "readPrice": true,
	"subscriptionPrice": true, "sponsored": true, "valueAtStake": true, "tags": true,
}

func (s *Spec) validate(now int64, lim Limits) error {
	if strings.TrimSpace(s.Name) == "" {
		return errors.New("spec: name is required")
	}
	switch s.Kind {
	case KindRecurring:
		if s.Interval < MinInterval || s.Interval > MaxInterval {
			return errors.New("spec: interval must be between 60 seconds and 30 days")
		}
		if s.SubmitWindow < MinSubmitWindow || s.SubmitWindow > s.Interval {
			return errors.New("spec: submitWindow must be between 60 seconds and the interval")
		}
		if s.ResolveAt != 0 || s.Bounty != 0 {
			return errors.New("spec: resolveAt and bounty are one-off fields")
		}
		if s.SubscriptionPrice < lim.SubscriptionFloor {
			return errors.New("spec: subscriptionPrice is below the floor")
		}
	case KindOneOff:
		if s.Interval != 0 || s.SubscriptionPrice != 0 {
			return errors.New("spec: interval and subscriptionPrice are recurring fields")
		}
		if s.SubmitWindow < MinSubmitWindow {
			return errors.New("spec: submitWindow must be at least 60 seconds")
		}
		if s.ResolveAt < now+MinResolveLead || s.ResolveAt > now+MaxResolveLead {
			return errors.New("spec: resolveAt must be between 1 hour and 2 years ahead")
		}
		if s.Bounty < lim.BountyFloor {
			return errors.New("spec: bounty is below the floor")
		}
	default:
		return errors.New("spec: kind must be recurring or oneoff")
	}
	switch s.ValueType {
	case TypeNumeric:
		if s.Decimals < 0 || s.Decimals > MaxDecimals {
			return errors.New("spec: decimals must be between 0 and 18")
		}
		if len(s.Options) != 0 {
			return errors.New("spec: options apply to categorical feeds only")
		}
	case TypeCategorical:
		if s.Decimals != 0 {
			return errors.New("spec: decimals apply to numeric feeds only")
		}
		if len(s.Options) < MinOptions {
			return errors.New("spec: categorical feeds need 2 to 16 options")
		}
		seen := map[string]bool{}
		for _, o := range s.Options {
			if strings.TrimSpace(o) == "" {
				return errors.New("spec: empty option")
			}
			if seen[o] {
				return errors.New("spec: duplicate option " + strconv.Quote(o))
			}
			seen[o] = true
		}
	default:
		return errors.New("spec: valueType must be numeric or categorical")
	}
	if s.MaxProviders < 1 || s.MaxProviders > MaxProviders {
		return errors.New("spec: maxProviders must be between 1 and 15")
	}
	if s.MinProviders < 1 || s.MinProviders > s.MaxProviders {
		return errors.New("spec: minProviders must be between 1 and maxProviders")
	}
	if s.ProviderMinStake < lim.ProviderMinStakeFloor {
		return errors.New("spec: providerMinStake is below the floor")
	}
	if s.ToleranceBps < MinToleranceBps || s.ToleranceBps > MaxToleranceBps {
		return errors.New("spec: toleranceBps must be between 1 and 5000")
	}
	if s.QuarantineBps < s.ToleranceBps || s.QuarantineBps > MaxQuarantineBps {
		return errors.New("spec: quarantineBps must be between toleranceBps and 10000")
	}
	if s.DisputeWindow < MinDisputeWindow || s.DisputeWindow > MaxDisputeWindow {
		return errors.New("spec: disputeWindow must be between 2 hours and 14 days")
	}
	if s.Sponsored {
		if s.ReadPrice != 0 {
			return errors.New("spec: a sponsored feed has no readPrice")
		}
	} else if s.ReadPrice < lim.ReadPriceFloor {
		return errors.New("spec: readPrice is below the floor")
	}
	if strings.TrimSpace(s.Sources) == "" {
		return errors.New("spec: sources is required")
	}
	return nil
}

// parser reads fields off the root node, recording the first error.
type parser struct {
	root *json.Node
	err  error
}

func (p *parser) fail(msg string) {
	if p.err == nil {
		p.err = errors.New("spec: " + msg)
	}
}

func (p *parser) field(key string) *json.Node {
	if !p.root.HasKey(key) {
		return nil
	}
	n, err := p.root.GetKey(key)
	if err != nil {
		return nil
	}
	return n
}

func (p *parser) str(key string, required bool, maxLen int) string {
	n := p.field(key)
	if n == nil {
		if required {
			p.fail(key + " is required")
		}
		return ""
	}
	if !n.IsString() {
		p.fail(key + " must be a string")
		return ""
	}
	v, err := n.GetString()
	if err != nil {
		p.fail(key + " must be a string")
		return ""
	}
	if len(v) > maxLen {
		p.fail(key + " is longer than " + strconv.Itoa(maxLen) + " bytes")
	}
	return v
}

func (p *parser) int(key string, required bool, def int64) int64 {
	n := p.field(key)
	if n == nil {
		if required {
			p.fail(key + " is required")
		}
		return def
	}
	if !n.IsNumber() {
		p.fail(key + " must be an integer")
		return def
	}
	v, err := strconv.ParseInt(n.String(), 10, 64)
	if err != nil {
		p.fail(key + " must be an integer")
		return def
	}
	if v < 0 {
		p.fail(key + " must not be negative")
	}
	return v
}

func (p *parser) boolean(key string) bool {
	n := p.field(key)
	if n == nil {
		return false
	}
	v, err := n.GetBool()
	if err != nil {
		p.fail(key + " must be a boolean")
		return false
	}
	return v
}

func (p *parser) strs(key string, maxItems, maxLen int) []string {
	n := p.field(key)
	if n == nil {
		return nil
	}
	if !n.IsArray() {
		p.fail(key + " must be an array of strings")
		return nil
	}
	items, err := n.GetArray()
	if err != nil {
		p.fail(key + " must be an array of strings")
		return nil
	}
	if len(items) > maxItems {
		p.fail(key + " has more than " + strconv.Itoa(maxItems) + " items")
		return nil
	}
	out := make([]string, 0, len(items))
	for _, it := range items {
		v, err := it.GetString()
		if err != nil {
			p.fail(key + " must be an array of strings")
			return nil
		}
		if len(v) > maxLen {
			p.fail(key + " item is longer than " + strconv.Itoa(maxLen) + " bytes")
			return nil
		}
		out = append(out, v)
	}
	return out
}
