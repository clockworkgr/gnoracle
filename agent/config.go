// Package agent is the provider daemon: it watches the feeds an operator
// serves, fetches each round's value from the configured source, checks it
// against sanity bounds, submits it, finalises closed rounds for the tip,
// claims rewards and keeps an evidence journal (plan §12.1).
package agent

import (
	"errors"
	"fmt"
	"math/big"
	"os"
	"time"

	toml "github.com/pelletier/go-toml"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

// Config is agent.toml.
type Config struct {
	Remote       string `toml:"remote"`
	ChainID      string `toml:"chain_id"`
	Core         string `toml:"core"`
	KeyHome      string `toml:"key_home"`
	Key          string `toml:"key"`
	PasswordFile string `toml:"password_file"`
	State        string `toml:"state"`    // JSON file remembering what was submitted
	Journal      string `toml:"journal"`  // JSONL evidence log (raw source responses, values, tx hashes)
	Poll         string `toml:"poll"`     // how often each feed is checked (default 5s)
	DevTick      bool   `toml:"dev_tick"` // gnodev only: nudge chain time with a self-send when it lags the clock

	Gas    gnochain.GasConfig `toml:"gas"`
	Notify NotifyConfig       `toml:"notify"`
	Feeds  []FeedConfig       `toml:"feeds"`
}

// NotifyConfig routes alerts (jail, refused values, repeated failures).
type NotifyConfig struct {
	TelegramToken string `toml:"telegram_token"`
	TelegramChat  int64  `toml:"telegram_chat"`
}

// FeedConfig is one [[feeds]] table.
type FeedConfig struct {
	ID            uint64       `toml:"id"`
	Jitter        string       `toml:"jitter"`         // wait after the round opens before fetching (default 2s)
	SanityBps     int64        `toml:"sanity_bps"`     // refuse a value this far from the last reference (default 2000 = 20%; 0 disables)
	Min           string       `toml:"min"`            // absolute bounds in feed units, e.g. "0.01"
	Max           string       `toml:"max"`            //
	Override      bool         `toml:"override"`       // submit even when the sanity check fails (logged and alerted)
	SkipFinalize  bool         `toml:"skip_finalize"`  // do not crank CatchUp for closed rounds
	CatchUpEmpty  *bool        `toml:"catch_up_empty"` // also write off rounds nobody submitted to (default true)
	CatchUpBatch  int64        `toml:"catch_up_batch"` // rounds per CatchUp call; halved on out-of-gas (default 8)
	FinalizeDelay string       `toml:"finalize_delay"` // wait after a round closes before cranking (default 5s)
	ClaimEvery    string       `toml:"claim_every"`    // ClaimRewards cadence (default 168h; "0" disables)
	ClaimMin      int64        `toml:"claim_min"`      // only claim when at least this many ugnot accrued (default 1 GNOT)
	Source        SourceConfig `toml:"source"`
}

// SourceConfig picks and parameterises the adapter.
type SourceConfig struct {
	Adapter string `toml:"adapter"` // http | exec | file | gnoswap | qeval
	Timeout string `toml:"timeout"` // per fetch (default 10s)

	// http: GET each URL, extract Path from the JSON body, take the median.
	URLs       []string          `toml:"urls"`
	Path       string            `toml:"path"` // dotted path, e.g. data.amount or result[0].price
	Headers    map[string]string `toml:"headers"`
	MinSources int               `toml:"min_sources"` // default: all URLs for one URL, otherwise a majority
	Scale      string            `toml:"scale"`       // multiply the source value, e.g. "0.01" for cents

	// exec: run a command; stdout is the value (number or option label).
	Command []string `toml:"command"`

	// file: read the value from a file a human writes (one-off outcomes).
	File string `toml:"file"`

	// gnoswap: Gnoswap pool oracle, tick TWAP over seconds_ago.
	PkgPath    string `toml:"pkg_path"`    // default gno.land/r/gnoswap/pool
	Pool       string `toml:"pool"`        // pool path "token0:token1:fee"
	SecondsAgo uint32 `toml:"seconds_ago"` // default 1800
	Decimals0  int    `toml:"decimals0"`   // token0 decimals
	Decimals1  int    `toml:"decimals1"`   // token1 decimals
	Invert     bool   `toml:"invert"`      // quote token0 per token1 instead of token1 per token0

	// qeval: any integer-returning expression on any realm.
	Expr           string `toml:"expr"`            // e.g. Price("gnot")
	ResultDecimals int    `toml:"result_decimals"` // decimals of the returned integer

	// categorical: map raw source labels to the feed's option labels.
	Map map[string]string `toml:"map"`
}

// Load reads and validates agent.toml.
func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := toml.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &c, nil
}

// Validate applies defaults and rejects what cannot run.
func (c *Config) Validate() error {
	if c.Remote == "" {
		return errors.New("remote is required")
	}
	if c.ChainID == "" {
		return errors.New("chain_id is required")
	}
	if c.Core == "" {
		return errors.New("core realm path is required")
	}
	if c.Key == "" && os.Getenv("GNORACLE_MNEMONIC") == "" {
		return errors.New("key (or GNORACLE_MNEMONIC) is required: the agent signs Submit")
	}
	if c.Poll == "" {
		c.Poll = "5s"
	}
	if d, err := time.ParseDuration(c.Poll); err != nil || d <= 0 {
		return fmt.Errorf("poll must be a positive duration: %q", c.Poll)
	}
	if c.State == "" {
		c.State = "agent-state.json"
	}
	if len(c.Feeds) == 0 {
		return errors.New("at least one [[feeds]] table is required")
	}
	c.Gas.Defaults()
	seen := map[uint64]bool{}
	for i := range c.Feeds {
		f := &c.Feeds[i]
		if f.ID == 0 {
			return fmt.Errorf("feeds[%d]: id is required", i)
		}
		if seen[f.ID] {
			return fmt.Errorf("feeds[%d]: feed %d listed twice", i, f.ID)
		}
		seen[f.ID] = true
		if _, err := f.runtime(); err != nil {
			return fmt.Errorf("feeds[%d] (feed %d): %w", i, f.ID, err)
		}
	}
	return nil
}

// feedParams is FeedConfig with strings parsed.
type feedParams struct {
	jitter        time.Duration
	finalizeDelay time.Duration
	claimEvery    time.Duration
	claimMin      int64
	sanityBps     int64
	min, max      *big.Rat
	catchUpEmpty  bool
	catchUpBatch  int64
	timeout       time.Duration
}

func (f *FeedConfig) runtime() (*feedParams, error) {
	p := &feedParams{jitter: 2 * time.Second, finalizeDelay: 5 * time.Second, claimEvery: 168 * time.Hour, claimMin: 1_000_000, sanityBps: 2000, catchUpEmpty: true, catchUpBatch: 8, timeout: 10 * time.Second}
	var err error
	if f.Jitter != "" {
		if p.jitter, err = time.ParseDuration(f.Jitter); err != nil {
			return nil, fmt.Errorf("jitter: %w", err)
		}
	}
	if f.FinalizeDelay != "" {
		if p.finalizeDelay, err = time.ParseDuration(f.FinalizeDelay); err != nil {
			return nil, fmt.Errorf("finalize_delay: %w", err)
		}
	}
	if f.ClaimEvery != "" {
		if p.claimEvery, err = time.ParseDuration(f.ClaimEvery); err != nil {
			return nil, fmt.Errorf("claim_every: %w", err)
		}
	}
	if f.ClaimMin > 0 {
		p.claimMin = f.ClaimMin
	}
	if f.SanityBps != 0 {
		p.sanityBps = f.SanityBps
		if p.sanityBps < 0 {
			p.sanityBps = 0
		}
	}
	if f.CatchUpEmpty != nil {
		p.catchUpEmpty = *f.CatchUpEmpty
	}
	if f.CatchUpBatch > 0 {
		p.catchUpBatch = f.CatchUpBatch
	}
	if f.Min != "" {
		if p.min, err = parseRat(f.Min); err != nil {
			return nil, fmt.Errorf("min: %w", err)
		}
	}
	if f.Max != "" {
		if p.max, err = parseRat(f.Max); err != nil {
			return nil, fmt.Errorf("max: %w", err)
		}
	}
	if f.Source.Timeout != "" {
		if p.timeout, err = time.ParseDuration(f.Source.Timeout); err != nil {
			return nil, fmt.Errorf("source.timeout: %w", err)
		}
	}
	if p.jitter < 0 || p.finalizeDelay < 0 || p.claimEvery < 0 || p.timeout <= 0 {
		return nil, errors.New("jitter, finalize_delay and claim_every must not be negative and source.timeout must be positive")
	}
	if err := f.Source.validate(); err != nil {
		return nil, err
	}
	return p, nil
}

func (s *SourceConfig) validate() error {
	switch s.Adapter {
	case "http":
		if len(s.URLs) == 0 {
			return errors.New("source.urls is required for the http adapter")
		}
		if s.MinSources > len(s.URLs) {
			return errors.New("source.min_sources exceeds the number of urls")
		}
		if s.Scale != "" {
			if _, err := parseRat(s.Scale); err != nil {
				return fmt.Errorf("source.scale: %w", err)
			}
		}
		for k, v := range s.Headers {
			for _, name := range envRefs(v) {
				if _, ok := os.LookupEnv(name); !ok {
					return fmt.Errorf("source.headers[%s] refers to $%s, which is not set", k, name)
				}
			}
		}
	case "exec":
		if len(s.Command) == 0 {
			return errors.New("source.command is required for the exec adapter")
		}
	case "file":
		if s.File == "" {
			return errors.New("source.file is required for the file adapter")
		}
	case "gnoswap":
		if s.Pool == "" {
			return errors.New("source.pool is required for the gnoswap adapter")
		}
	case "qeval":
		if s.PkgPath == "" || s.Expr == "" {
			return errors.New("source.pkg_path and source.expr are required for the qeval adapter")
		}
	case "":
		return errors.New("source.adapter is required (http | exec | file | gnoswap | qeval)")
	default:
		return fmt.Errorf("unknown adapter %q", s.Adapter)
	}
	return nil
}

func parseRat(s string) (*big.Rat, error) {
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return nil, fmt.Errorf("%q is not a decimal number", s)
	}
	return r, nil
}

// envRefs lists the $VAR and ${VAR} names a header value expands.
func envRefs(v string) []string {
	var out []string
	for i := 0; i < len(v); i++ {
		if v[i] != '$' {
			continue
		}
		j := i + 1
		braced := j < len(v) && v[j] == '{'
		if braced {
			j++
		}
		k := j
		for k < len(v) && (v[k] == '_' || v[k] >= 'A' && v[k] <= 'Z' || v[k] >= 'a' && v[k] <= 'z' || v[k] >= '0' && v[k] <= '9') {
			k++
		}
		if k > j {
			out = append(out, v[j:k])
		}
		i = k
	}
	return out
}
