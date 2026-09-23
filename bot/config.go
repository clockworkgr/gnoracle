// Package bot is the notifier and cranker: it follows the chain's events,
// posts deadlines and reminders to Telegram, and drives the permissionless
// entry points the protocol needs someone to call (plan §12.2).
package bot

import (
	"errors"
	"fmt"
	"os"
	"time"

	toml "github.com/pelletier/go-toml"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

// Config is bot.toml.
type Config struct {
	Remote       string `toml:"remote"`
	ChainID      string `toml:"chain_id"`
	Core         string `toml:"core"`
	DAO          string `toml:"dao"`
	Kourt        string `toml:"kourt"`
	Gnoweb       string `toml:"gnoweb"` // base URL for links, e.g. https://gno.land
	KeyHome      string `toml:"key_home"`
	Key          string `toml:"key"` // optional: needed for cranking
	PasswordFile string `toml:"password_file"`
	State        string `toml:"state"`
	Poll         string `toml:"poll"`         // default 10s
	StartHeight  int64  `toml:"start_height"` // first block to scan when there is no state (0 = chain head)
	MaxBlocks    int    `toml:"max_blocks"`   // per tick (default 300)

	Gas      gnochain.GasConfig `toml:"gas"`
	Telegram TelegramConfig     `toml:"telegram"`
	Members  []MemberConfig     `toml:"members"`
	Remind   RemindConfig       `toml:"remind"`
	Crank    CrankConfig        `toml:"crank"`
	Events   []string           `toml:"events"` // event types to announce (default: the protocol's notable ones)
}

// TelegramConfig is the channel the bot posts to.
type TelegramConfig struct {
	Token string `toml:"token"`
	Chat  int64  `toml:"chat"` // channel or group id
	Echo  bool   `toml:"echo"` // also log every message
}

// MemberConfig is a DAO member who opted in to direct reminders and
// settlement.
type MemberConfig struct {
	Addr   string `toml:"addr"`
	Chat   int64  `toml:"chat"`   // direct chat id (0: channel only)
	Name   string `toml:"name"`   // shown in messages
	Settle bool   `toml:"settle"` // crank SettleMember for this member
}

// RemindConfig sets the reminder schedule.
type RemindConfig struct {
	Hours []int64 `toml:"hours"` // hours before a commit or reveal deadline (default 24, 2)
	Every string  `toml:"every"` // check cadence (default 10m)
}

// CrankConfig enables the cranks.
type CrankConfig struct {
	Finalize      bool   `toml:"finalize"`       // CatchUp closed rounds nobody finalised
	Resolve       bool   `toml:"resolve"`        // ResolveDispute after reveal / appeal window
	Kourt         bool   `toml:"kourt"`          // Crank the Kourt mirror
	Settle        bool   `toml:"settle"`         // SettleMember for opted-in members
	Every         string `toml:"every"`          // finalize/resolve cadence (default 60s)
	KourtEvery    string `toml:"kourt_every"`    // default 1h
	SettleEvery   string `toml:"settle_every"`   // default 24h
	FinalizeGrace string `toml:"finalize_grace"` // leave providers' agents the tip first (default 120s)
	CatchUpEmpty  *bool  `toml:"catch_up_empty"` // write off rounds without submissions (default true)
	CatchUpBatch  int64  `toml:"catch_up_batch"` // rounds per CatchUp call; halved on out-of-gas (default 8)
}

// DefaultEvents are announced when Events is empty.
var DefaultEvents = []string{
	"DisputeOpened", "DisputeBallotOpened", "DisputeRolled", "AppealOpened", "DisputeDecided", "DisputeResolved",
	"ProposalCreated", "ProposalStatus", "ProviderJailed", "ProviderSlashed", "ProviderEjected", "KourtDissent",
	"FeedProposed", "FeedActivated", "FeedDeprecated", "FeedUnfunded", "FeedReopened",
	"ReleaseAccepted", "ReleaseRolledBack", "Frozen", "AuthorityTransferred", "ParamChanged", "UpgradeProposed",
}

// Load reads and validates bot.toml.
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

// params is Config with durations parsed.
type params struct {
	poll, remindEvery, crankEvery, kourtEvery, settleEvery, finalizeGrace time.Duration
	catchUpEmpty                                                          bool
	catchUpBatch                                                          int64
	events                                                                map[string]bool
}

// Validate applies defaults and checks the durations.
func (c *Config) Validate() error {
	if c.Remote == "" || c.ChainID == "" {
		return errors.New("remote and chain_id are required")
	}
	if c.Core == "" || c.DAO == "" {
		return errors.New("core and dao realm paths are required")
	}
	if c.State == "" {
		c.State = "bot-state.json"
	}
	if c.MaxBlocks <= 0 {
		c.MaxBlocks = 300
	}
	if len(c.Remind.Hours) == 0 {
		c.Remind.Hours = []int64{24, 2}
	}
	if c.Poll == "" {
		c.Poll = "10s"
	}
	if c.Remind.Every == "" {
		c.Remind.Every = "10m"
	}
	if c.Crank.Every == "" {
		c.Crank.Every = "60s"
	}
	if c.Crank.KourtEvery == "" {
		c.Crank.KourtEvery = "1h"
	}
	if c.Crank.SettleEvery == "" {
		c.Crank.SettleEvery = "24h"
	}
	if c.Crank.FinalizeGrace == "" {
		c.Crank.FinalizeGrace = "120s"
	}
	if len(c.Events) == 0 {
		c.Events = DefaultEvents
	}
	c.Gas.Defaults()
	for _, m := range c.Members {
		if _, err := gnochain.ParseAddress(m.Addr); err != nil {
			return fmt.Errorf("members: %w", err)
		}
	}
	if (c.Crank.Finalize || c.Crank.Resolve || c.Crank.Kourt || c.Crank.Settle) && c.Key == "" && os.Getenv("GNORACLE_MNEMONIC") == "" {
		return errors.New("cranking needs a key (or GNORACLE_MNEMONIC)")
	}
	if c.Crank.Kourt && c.Kourt == "" {
		return errors.New("crank.kourt needs the kourt realm path")
	}
	_, err := c.params()
	return err
}

func (c *Config) params() (*params, error) {
	p := &params{catchUpEmpty: true, catchUpBatch: 8, events: map[string]bool{}}
	if c.Crank.CatchUpBatch > 0 {
		p.catchUpBatch = c.Crank.CatchUpBatch
	}
	for _, e := range c.Events {
		p.events[e] = true
	}
	if c.Crank.CatchUpEmpty != nil {
		p.catchUpEmpty = *c.Crank.CatchUpEmpty
	}
	var err error
	for _, d := range []struct {
		name string
		src  string
		dst  *time.Duration
	}{{"poll", c.Poll, &p.poll}, {"remind.every", c.Remind.Every, &p.remindEvery}, {"crank.every", c.Crank.Every, &p.crankEvery},
		{"crank.kourt_every", c.Crank.KourtEvery, &p.kourtEvery}, {"crank.settle_every", c.Crank.SettleEvery, &p.settleEvery}, {"crank.finalize_grace", c.Crank.FinalizeGrace, &p.finalizeGrace}} {
		if *d.dst, err = time.ParseDuration(d.src); err != nil {
			return nil, fmt.Errorf("%s: %w", d.name, err)
		}
	}
	return p, nil
}
