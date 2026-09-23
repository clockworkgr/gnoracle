package bot

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
	"github.com/clockworkgr/gnoracle/internal/notify"
)

// Bot ties the watcher, the reminders and the cranks together.
type Bot struct {
	cfg      *Config
	p        *params
	client   *gnochain.Client
	notifier notify.Notifier
	state    *State
	pkgs     map[string]bool
	batch    map[uint64]int64 // adaptive CatchUp batch per feed
}

// New wires a bot. The client may be read-only when no crank is enabled.
func New(cfg *Config, client *gnochain.Client) (*Bot, error) {
	p, err := cfg.params()
	if err != nil {
		return nil, err
	}
	state, err := LoadState(cfg.State)
	if err != nil {
		return nil, fmt.Errorf("bot: state: %w", err)
	}
	pkgs := map[string]bool{cfg.Core: true, cfg.DAO: true}
	if cfg.Kourt != "" {
		pkgs[cfg.Kourt] = true
	}
	for _, p := range cfg.ProxyPaths {
		pkgs[p] = true
	}
	return &Bot{cfg: cfg, p: p, client: client, notifier: notify.New(cfg.Telegram.Token, cfg.Telegram.Echo), state: state, pkgs: pkgs, batch: map[uint64]int64{}}, nil
}

// Run loops until ctx ends.
func (b *Bot) Run(ctx context.Context) error {
	log.Printf("bot: watching %s, %s on %s; cranks finalize=%v resolve=%v kourt=%v settle=%v", b.cfg.Core, b.cfg.DAO, b.cfg.Remote, b.cfg.Crank.Finalize, b.cfg.Crank.Resolve, b.cfg.Crank.Kourt, b.cfg.Crank.Settle)
	t := time.NewTicker(b.p.poll)
	defer t.Stop()
	for {
		b.Tick(ctx)
		select {
		case <-ctx.Done():
			return b.state.Save()
		case <-t.C:
		}
	}
}

// Tick runs one pass: scan, remind, crank.
func (b *Bot) Tick(ctx context.Context) {
	if err := b.scan(ctx); err != nil && ctx.Err() == nil {
		log.Printf("scan: %v", err)
	}
	now := time.Now().Unix()
	if now-b.state.LastRemind >= int64(b.p.remindEvery/time.Second) {
		b.state.LastRemind = now
		if err := b.remind(ctx); err != nil && ctx.Err() == nil {
			log.Printf("remind: %v", err)
		}
	}
	if now-b.state.LastCrank >= int64(b.p.crankEvery/time.Second) {
		b.state.LastCrank = now
		b.crank(ctx)
	}
	if err := b.state.Save(); err != nil {
		log.Printf("state: %v", err)
	}
}

func (b *Bot) post(ctx context.Context, text string) {
	if err := b.notifier.Send(ctx, b.cfg.Telegram.Chat, text); err != nil {
		log.Printf("post: %v", err)
	}
}

func (b *Bot) dm(ctx context.Context, m MemberConfig, text string) {
	if m.Chat == 0 {
		return
	}
	if err := b.notifier.Send(ctx, m.Chat, text); err != nil {
		log.Printf("dm %s: %v", m.Addr, err)
	}
}

// link builds a gnoweb URL for a realm render path.
func (b *Bot) link(pkgPath, render string) string {
	if b.cfg.Gnoweb == "" {
		return ""
	}
	u := strings.TrimRight(b.cfg.Gnoweb, "/") + strings.TrimPrefix(pkgPath, "gno.land")
	if render != "" {
		u += ":" + render
	}
	return u
}

// when prints an absolute time and the distance from now.
func when(unix, now int64) string {
	t := time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
	d := time.Duration(unix-now) * time.Second
	switch {
	case d > 0:
		return fmt.Sprintf("%s (in %s)", t, short(d))
	case d < 0:
		return fmt.Sprintf("%s (%s ago)", t, short(-d))
	}
	return t
}

func short(d time.Duration) string {
	d = d.Round(time.Minute)
	h := int64(d / time.Hour)
	m := int64(d%time.Hour) / int64(time.Minute)
	switch {
	case h >= 48:
		return fmt.Sprintf("%dd %dh", h/24, h%24)
	case h > 0:
		return fmt.Sprintf("%dh %02dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}

func gnot(ugnot int64) string {
	return strconv.FormatFloat(float64(ugnot)/1e6, 'f', -1, 64) + " GNOT"
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }
