package spec_test

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/clockwork/gnoracle/spec/v0"
	"gno.land/p/nt/uassert/v0"
)

const now = int64(1_700_000_000)

func limits() spec.Limits {
	return spec.Limits{ProviderMinStakeFloor: 10_000_000_000, SubscriberFloor: 2000, SubscriptionFloor: 100_000_000, BountyFloor: 50_000_000}
}

const priceFeed = `{
  "name": "GNOT/USD",
  "description": "Spot price of GNOT in USD.",
  "kind": "recurring",
  "valueType": "numeric",
  "decimals": 6,
  "interval": 3600,
  "submitWindow": 600,
  "sources": "Median of Gnoswap TWAP and two of Coinbase, Kraken, Binance at round start.",
  "minProviders": 3,
  "maxProviders": 9,
  "providerMinStake": 25000000000,
  "toleranceBps": 100,
  "quarantineBps": 1000,
  "disputeWindow": 43200,
  "subscriberPrice": 20000,
  "subscriptionPrice": 1000000000,
  "tags": ["price", "gnot"]
}`

const outcomeFeed = `{"name":"Election 2026","kind":"oneoff","valueType":"categorical","options":["Yes","No","Invalid"],"resolveAt":1700100000,"submitWindow":86400,"bounty":50000000,"sources":"Official results page of the electoral commission.","minProviders":3,"maxProviders":5,"providerMinStake":10000000000,"disputeWindow":259200}`

func TestParsePriceFeed(t *testing.T) {
	s, err := spec.Parse(priceFeed, now, limits())
	uassert.NoError(t, err)
	uassert.Equal(t, "GNOT/USD", s.Name)
	uassert.True(t, s.IsRecurring())
	uassert.True(t, s.IsNumeric())
	uassert.Equal(t, 6, s.Decimals)
	uassert.Equal(t, int64(3600), s.Interval)
	uassert.Equal(t, int64(600), s.SubmitWindow)
	uassert.Equal(t, 3, s.MinProviders)
	uassert.Equal(t, 9, s.MaxProviders)
	uassert.Equal(t, int64(25_000_000_000), s.ProviderMinStake) // exact, no float
	uassert.Equal(t, int64(100), s.ToleranceBps)
	uassert.Equal(t, int64(1000), s.QuarantineBps)
	uassert.Equal(t, int64(43200), s.DisputeWindow)
	uassert.Equal(t, int64(20000), s.SubscriberPrice)
	uassert.Equal(t, int64(1_000_000_000), s.SubscriptionPrice)
	uassert.Equal(t, 2, len(s.Tags))
	uassert.Equal(t, priceFeed, s.Text)
	uassert.Equal(t, spec.HashText(priceFeed), s.Hash)
	uassert.Equal(t, 64, len(s.Hash))
	uassert.True(t, s.ValidValue(-5))
}

func TestParseOutcomeFeed(t *testing.T) {
	s, err := spec.Parse(outcomeFeed, now, limits())
	uassert.NoError(t, err)
	uassert.False(t, s.IsRecurring())
	uassert.False(t, s.IsNumeric())
	uassert.Equal(t, 3, len(s.Options))
	uassert.Equal(t, "No", s.OptionLabel(1))
	uassert.Equal(t, "", s.OptionLabel(3))
	uassert.Equal(t, int64(1_700_100_000), s.ResolveAt)
	uassert.Equal(t, int64(50_000_000), s.Bounty)
	uassert.True(t, s.ValidValue(2))
	uassert.False(t, s.ValidValue(3))
	uassert.False(t, s.ValidValue(-1))
	uassert.Equal(t, int64(100), s.ToleranceBps)   // defaults apply
	uassert.Equal(t, int64(1000), s.QuarantineBps) // defaults apply
}

func mutate(base, field, value string) string {
	// replace the value of the first `"field":` occurrence; the scan skips
	// commas inside quoted strings and arrays.
	i := strings.Index(base, "\""+field+"\"")
	if i < 0 {
		return base
	}
	j := i + len(field) + 2 // after the closing quote of the key
	for j < len(base) && (base[j] == ' ' || base[j] == ':' || base[j] == '\n') {
		j++
	}
	valueStart := j
	depth := 0
	inStr := false
	for j < len(base) {
		c := base[j]
		switch {
		case inStr:
			if c == '\\' {
				j++
			} else if c == '"' {
				inStr = false
			}
		case c == '"':
			inStr = true
		case c == '[':
			depth++
		case c == ']':
			depth--
		case depth == 0 && (c == ',' || c == '}') && j > valueStart:
			return base[:valueStart] + value + base[j:]
		}
		j++
	}
	return base
}

func expectErr(t *testing.T, text, contains string) {
	t.Helper()
	_, err := spec.Parse(text, now, limits())
	if err == nil {
		t.Fatalf("expected error containing %q, got nil", contains)
	}
	if !strings.Contains(err.Error(), contains) {
		t.Fatalf("expected error containing %q, got %q", contains, err.Error())
	}
}

func TestValidationRules(t *testing.T) {
	expectErr(t, "", "1 to 4096 bytes")
	expectErr(t, strings.Repeat("x", 5000), "1 to 4096 bytes")
	expectErr(t, "not json", "invalid JSON")
	expectErr(t, `[1,2]`, "top level must be an object")
	expectErr(t, `{"name":"x","extra":1}`, "unknown field")
	expectErr(t, mutate(priceFeed, "name", `""`), "name is required")
	expectErr(t, mutate(priceFeed, "name", `12`), "name must be a string")
	expectErr(t, mutate(priceFeed, "kind", `"weekly"`), "kind must be recurring or oneoff")
	expectErr(t, mutate(priceFeed, "interval", `59`), "interval must be between")
	expectErr(t, mutate(priceFeed, "interval", `2592001`), "interval must be between")
	expectErr(t, mutate(priceFeed, "submitWindow", `3601`), "submitWindow must be between")
	expectErr(t, mutate(priceFeed, "submitWindow", `59`), "submitWindow must be between")
	expectErr(t, mutate(priceFeed, "decimals", `19`), "decimals must be between")
	expectErr(t, mutate(priceFeed, "decimals", `-1`), "must not be negative")
	expectErr(t, mutate(priceFeed, "decimals", `1.5`), "must be an integer")
	expectErr(t, mutate(priceFeed, "decimals", `"6"`), "must be an integer")
	expectErr(t, mutate(priceFeed, "minProviders", `0`), "minProviders must be between")
	expectErr(t, mutate(priceFeed, "minProviders", `10`), "minProviders must be between")
	expectErr(t, mutate(priceFeed, "maxProviders", `16`), "maxProviders must be between")
	expectErr(t, mutate(priceFeed, "providerMinStake", `9999999999`), "providerMinStake is below the floor")
	expectErr(t, mutate(priceFeed, "toleranceBps", `0`), "toleranceBps must be between")
	expectErr(t, mutate(priceFeed, "toleranceBps", `5001`), "toleranceBps must be between")
	expectErr(t, mutate(priceFeed, "quarantineBps", `50`), "quarantineBps must be between")
	expectErr(t, mutate(priceFeed, "disputeWindow", `7199`), "disputeWindow must be between")
	expectErr(t, mutate(priceFeed, "disputeWindow", `1209601`), "disputeWindow must be between")
	expectErr(t, mutate(priceFeed, "subscriberPrice", `1999`), "subscriberPrice is below the floor")
	expectErr(t, mutate(priceFeed, "subscriptionPrice", `1`), "subscriptionPrice is below the floor")
	expectErr(t, mutate(priceFeed, "sources", `"   "`), "sources is required")
	expectErr(t, mutate(priceFeed, "sources", `"`+strings.Repeat("s", 2001)+`"`), "longer than 2000")
	expectErr(t, mutate(priceFeed, "tags", `["a","b","c","d","e","f","g","h","i"]`), "more than 8 items")
	expectErr(t, mutate(priceFeed, "tags", `"price"`), "must be an array of strings")
	expectErr(t, mutate(priceFeed, "tags", `[1]`), "must be an array of strings")
	expectErr(t, mutate(priceFeed, "valueType", `"categorical"`), "decimals apply to numeric feeds only")
	expectErr(t, mutate(mutate(priceFeed, "valueType", `"categorical"`), "decimals", `0`), "categorical feeds need 2 to 16 options")
	expectErr(t, strings.Replace(priceFeed, `"tags"`, `"resolveAt": 1700100000, "tags"`, 1), "one-off fields")

	// sponsored feeds have no subscriber price
	sponsored := mutate(priceFeed, "subscriberPrice", `0`)
	expectErr(t, sponsored, "subscriberPrice is below the floor")
	sponsored = strings.Replace(sponsored, `"tags"`, `"sponsored": true, "tags"`, 1)
	s, err := spec.Parse(sponsored, now, limits())
	uassert.NoError(t, err)
	uassert.True(t, s.Sponsored)
	expectErr(t, strings.Replace(priceFeed, `"tags"`, `"sponsored": true, "tags"`, 1), "sponsored feed has no subscriberPrice")
	expectErr(t, strings.Replace(priceFeed, `"tags"`, `"sponsored": "yes", "tags"`, 1), "sponsored must be a boolean")

	// numeric feeds may not carry options
	expectErr(t, strings.Replace(priceFeed, `"tags"`, `"options": ["a","b"], "tags"`, 1), "options apply to categorical feeds only")
}

func TestOneOffRules(t *testing.T) {
	expectErr(t, mutate(outcomeFeed, "resolveAt", `1700003599`), "resolveAt must be between") // less than 1 h ahead
	expectErr(t, mutate(outcomeFeed, "resolveAt", `1800000000`), "resolveAt must be between") // more than 2 y ahead
	expectErr(t, mutate(outcomeFeed, "bounty", `1`), "bounty is below the floor")
	expectErr(t, mutate(outcomeFeed, "options", `["Yes"]`), "categorical feeds need 2 to 16 options")
	expectErr(t, mutate(outcomeFeed, "options", `["Yes","Yes"]`), "duplicate option")
	expectErr(t, mutate(outcomeFeed, "options", `["Yes"," "]`), "empty option")
	expectErr(t, mutate(outcomeFeed, "options", `["Yes","`+strings.Repeat("o", 65)+`"]`), "longer than 64")
	expectErr(t, strings.Replace(outcomeFeed, `"bounty"`, `"interval": 3600, "bounty"`, 1), "recurring fields")
	expectErr(t, strings.Replace(outcomeFeed, `"bounty"`, `"decimals": 2, "bounty"`, 1), "decimals apply to numeric feeds only")
	seventeen := `["a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q"]`
	expectErr(t, mutate(outcomeFeed, "options", seventeen), "more than 16 items")
	// a one-off numeric feed is fine (e.g. a settlement price)
	numeric := strings.Replace(mutate(outcomeFeed, "valueType", `"numeric"`), `"options":["Yes","No","Invalid"],`, `"decimals": 2,`, 1)
	_, err := spec.Parse(numeric, now, limits())
	uassert.NoError(t, err)
}

func TestAmountBoundsDuplicatesAndWindows(t *testing.T) {
	now := int64(1_700_000_000)
	lim := spec.Limits{ProviderMinStakeFloor: 1_000_000_000, SubscriberFloor: 2000, SubscriptionFloor: 100_000_000, BountyFloor: 50_000_000}
	base := `{"name":"X","kind":"recurring","valueType":"numeric","decimals":6,"interval":3600,"submitWindow":600,"sources":"s","minProviders":2,"maxProviders":5,"providerMinStake":1000000000,"disputeWindow":7200,"subscriberPrice":%s,"subscriptionPrice":100000000}`
	_, err := spec.Parse(strings.Replace(base, "%s", "1844674407370957", 1), now, lim)
	if err == nil || !strings.Contains(err.Error(), "subscriberPrice must be between") {
		t.Fatalf("huge subscriberPrice accepted: %v", err)
	}
	_, err = spec.Parse(strings.Replace(base, "%s", "2000", 1), now, lim)
	if err != nil {
		t.Fatalf("valid spec rejected: %v", err)
	}
	// a duplicated top-level key is rejected even when a nested string repeats it
	dup := `{"name":"X","sources":"the \"name\" field","name":"Y","kind":"recurring","valueType":"numeric","decimals":6,"interval":3600,"submitWindow":600,"minProviders":2,"maxProviders":5,"providerMinStake":1000000000,"disputeWindow":7200,"subscriberPrice":2000,"subscriptionPrice":100000000,"tags":["name","name"]}`
	_, err = spec.Parse(dup, now, lim)
	if err == nil || !strings.Contains(err.Error(), `"name" appears twice`) {
		t.Fatalf("duplicate key accepted: %v", err)
	}
	// one-off windows are bounded
	oneOff := `{"name":"O","kind":"oneoff","valueType":"categorical","options":["A","B"],"resolveAt":` + strconv.FormatInt(now+7200, 10) + `,"submitWindow":9223372036854775807,"bounty":50000000,"sources":"s","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,"disputeWindow":7200}`
	_, err = spec.Parse(oneOff, now, lim)
	if err == nil || !strings.Contains(err.Error(), "submitWindow must be between 60 seconds and 30 days") {
		t.Fatalf("huge one-off window accepted: %v", err)
	}
	// the realm may lower the dispute window ceiling
	tight := spec.Limits{ProviderMinStakeFloor: 1_000_000_000, SubscriberFloor: 2000, SubscriptionFloor: 100_000_000, BountyFloor: 50_000_000, MaxDisputeWindow: 10800}
	wide := strings.Replace(strings.Replace(base, "%s", "2000", 1), `"disputeWindow":7200`, `"disputeWindow":43200`, 1)
	_, err = spec.Parse(wide, now, tight)
	if err == nil || !strings.Contains(err.Error(), "disputeWindow must be between 2 hours and 3 hours") {
		t.Fatalf("dispute window ceiling not applied: %v", err)
	}
	if _, err = spec.Parse(wide, now, lim); err != nil {
		t.Fatalf("12 h window within the package default rejected: %v", err)
	}
}
