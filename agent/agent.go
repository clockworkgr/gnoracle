package agent

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/big"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
	"github.com/clockworkgr/gnoracle/internal/notify"
)

// Agent runs one loop per configured feed.
type Agent struct {
	cfg      *Config
	client   *gnochain.Client
	notifier notify.Notifier
	state    *State
	journal  *Journal
	poll     time.Duration
	runners  []*feedRunner
	tickMu   sync.Mutex
	lastTick time.Time
}

// New wires the agent; the client must sign.
func New(cfg *Config, client *gnochain.Client) (*Agent, error) {
	if !client.CanSign() {
		return nil, errors.New("agent: the client has no signing key")
	}
	state, err := LoadState(cfg.State)
	if err != nil {
		return nil, fmt.Errorf("agent: state: %w", err)
	}
	poll, _ := time.ParseDuration(cfg.Poll)
	if state.ForChain(cfg.ChainID) {
		log.Printf("agent: state file was for another chain; starting fresh")
	}
	a := &Agent{cfg: cfg, client: client, notifier: notify.New(cfg.Notify.TelegramToken, false), state: state, journal: NewJournal(cfg.Journal), poll: poll}
	for i := range cfg.Feeds {
		fc := cfg.Feeds[i]
		params, err := fc.runtime()
		if err != nil {
			return nil, err
		}
		adapter, err := NewAdapter(fc.Source, Deps{Client: client})
		if err != nil {
			return nil, fmt.Errorf("feed %d: %w", fc.ID, err)
		}
		a.runners = append(a.runners, &feedRunner{a: a, fc: fc, p: params, adapter: adapter, log: log.New(log.Writer(), fmt.Sprintf("[feed %d] ", fc.ID), log.LstdFlags), warned: map[string]time.Time{}})
	}
	return a, nil
}

// Run serves every feed until ctx ends.
func (a *Agent) Run(ctx context.Context) error {
	log.Printf("agent: %s on %s as %s, %d feed(s), poll %s", a.cfg.Core, a.cfg.Remote, a.client.Bech32(), len(a.runners), a.poll)
	var wg sync.WaitGroup
	for _, r := range a.runners {
		wg.Add(1)
		go func(r *feedRunner) {
			defer wg.Done()
			r.loop(ctx)
		}(r)
	}
	wg.Wait()
	return a.state.Save()
}

// Once runs a single tick for every feed (for tests and `-once`).
func (a *Agent) Once(ctx context.Context) error {
	var firstErr error
	for _, r := range a.runners {
		if err := r.tick(ctx); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if err := a.state.Save(); err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
}

// devTick nudges gnodev's lazy clock with a one-ugnot self-send at most once
// per poll interval.
func (a *Agent) devTick(ctx context.Context, chainNow int64) {
	if !a.cfg.DevTick || time.Now().Unix()-chainNow < 5 {
		return
	}
	a.tickMu.Lock()
	defer a.tickMu.Unlock()
	if time.Since(a.lastTick) < a.poll {
		return
	}
	a.lastTick = time.Now()
	if _, err := a.client.SendCoins(ctx, a.client.Address(), "1ugnot"); err != nil {
		log.Printf("dev tick: %v", err)
	}
}

func (a *Agent) alert(ctx context.Context, text string) {
	log.Printf("ALERT %s", text)
	if a.cfg.Notify.TelegramChat != 0 {
		if err := a.notifier.Send(ctx, a.cfg.Notify.TelegramChat, "gnoracle agent "+a.client.Bech32()[:12]+"…: "+text); err != nil {
			log.Printf("alert delivery: %v", err)
		}
	}
}

type feedRunner struct {
	a       *Agent
	fc      FeedConfig
	p       *feedParams
	adapter Adapter
	log     *log.Logger
	warned  map[string]time.Time
	refused map[uint64]bool
	batch   int64     // current CatchUp batch (adaptive)
	backoff time.Time // no crank attempts before this
	obliged *uint64   // first round this provider owes (from the provider record)
	slot    int       // slot the obligation was read for
}

func (r *feedRunner) loop(ctx context.Context) {
	t := time.NewTicker(r.a.poll)
	defer t.Stop()
	for {
		if err := r.tick(ctx); err != nil && ctx.Err() == nil {
			r.log.Printf("tick: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// warnOnce logs a condition at most every 10 minutes per key.
func (r *feedRunner) warnOnce(key, msg string) {
	if t, ok := r.warned[key]; ok && time.Since(t) < 10*time.Minute {
		return
	}
	r.warned[key] = time.Now()
	r.log.Print(msg)
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }
func i(v int64) string  { return strconv.FormatInt(v, 10) }

// submitFinaliseHeadroom is the gas a Submit needs on top of a plain one
// when it also finalises the round (measured 18.5M vs 31.8M on v1.2.0 with
// three providers).
const submitFinaliseHeadroom = 14_000_000

// tick is one pass over the feed: submit if a round is open and ours is
// missing, crank closed rounds, claim rewards.
func (r *feedRunner) tick(ctx context.Context) error {
	core := r.a.cfg.Core
	me := r.a.client.Bech32()
	f, err := r.a.client.Feed(core, r.fc.ID)
	if err != nil {
		return err
	}
	now := f.Now
	r.a.devTick(ctx, now)
	switch f.Status {
	case "active", "unfunded":
	case "proposed":
		r.warnOnce("status", "feed is not activated yet")
		return nil
	default:
		r.warnOnce("status", "feed is "+f.Status+"; nothing to do")
		return nil
	}
	slot := f.SlotOf(me)
	if slot < 0 {
		p, err := r.a.client.Provider(core, r.fc.ID, me)
		switch {
		case err != nil && gnochain.IsViewError(err):
			r.warnOnce("register", "not registered on this feed: `gnoracle register "+u(r.fc.ID)+" <stake>` first")
		case err != nil:
			return err
		case p.Status == "jailed":
			if _, ok := r.warned["jailed"]; !ok {
				r.a.alert(ctx, fmt.Sprintf("feed %d: provider is JAILED since %d (%d jailings). Fix the source, then `gnoracle unjail %d`.", r.fc.ID, p.JailedAt, p.Jailings, r.fc.ID))
			}
			r.warnOnce("jailed", "jailed; waiting for Unjail")
		default:
			r.warnOnce("slot", "registered ("+p.Status+") but not in the active set")
		}
		return nil
	}
	delete(r.warned, "jailed")
	sched := f.Schedule()
	cur, started := sched.Current(now)
	if !started {
		r.warnOnce("start", fmt.Sprintf("first round opens at %d (in %s)", f.StartAt, time.Duration(f.StartAt-now)*time.Second))
		return nil
	}
	// obligations start at the round after registration; the realm rejects
	// earlier submissions and the finalisation only counts obliged slots
	if r.obliged == nil || r.slot != slot {
		p, err := r.a.client.Provider(core, r.fc.ID, me)
		if err != nil {
			return err
		}
		from := p.ObligedFrom
		r.obliged, r.slot = &from, slot
	}
	// a new schedule (a reopened one-off, a re-created dev chain) makes the
	// remembered rounds meaningless
	r.a.state.Update(r.fc.ID, func(fs *FeedState) {
		if fs.StartAt != f.StartAt {
			if fs.StartAt != 0 {
				r.log.Printf("schedule changed (start %d -> %d); forgetting remembered rounds", fs.StartAt, f.StartAt)
			}
			fs.StartAt, fs.HasRound, fs.LastRound, fs.HasValue, fs.LastValue, fs.ValueRound = f.StartAt, false, 0, false, 0, 0
		}
	})
	st := r.a.state.Snapshot(r.fc.ID)
	if cur < *r.obliged {
		r.warnOnce("obliged", fmt.Sprintf("obligations start at round %d (current %d); waiting", *r.obliged, cur))
		if !r.fc.SkipFinalize {
			if err := r.crank(ctx, f, sched, cur, now, slot); err != nil {
				r.log.Printf("crank: %v", err)
			}
		}
		return nil
	}

	// 1. crank rounds that closed before the current one (or the current one
	//    once closed) so the feed keeps moving and the tip is ours
	submittedNow := false
	if !r.fc.SkipFinalize {
		if err := r.crank(ctx, f, sched, cur, now, slot); err != nil {
			r.log.Printf("crank: %v", err)
		}
	}

	// 2. submit to the open round
	if !(st.HasRound && st.LastRound >= cur) {
		openAt, closeAt := sched.OpenAt(cur), sched.CloseAt(cur)
		jitter := int64(r.p.jitter / time.Second)
		// a submission assembled in the last seconds lands after the close
		margin := int64(r.p.timeout/time.Second) + 2
		if now >= openAt+jitter && now < closeAt-margin {
			rd, err := r.a.client.Round(core, r.fc.ID, cur)
			switch {
			case err != nil:
				// never submit blind: the mask is the only double-submission guard
				r.log.Printf("round %d: cannot read the round yet: %v", cur, err)
			case rd.HasSubmitted(slot):
				r.a.state.Update(r.fc.ID, func(fs *FeedState) { fs.HasRound, fs.LastRound = true, cur })
				_ = r.a.state.Save()
			default:
				// headroom only when exactly one other provider is still to
				// submit: then a race can make this call the finalising one
				// after the simulation measured a plain submission
				others := int(f.ActiveCount) - 1 - len(rd.Submitted)
				var headroom int64
				if others == 1 {
					headroom = submitFinaliseHeadroom
				}
				if err := r.submit(ctx, f, cur, &st, headroom); err != nil {
					r.log.Printf("round %d: %v", cur, err)
				} else {
					submittedNow = true
				}
			}
		} else if now >= closeAt-margin && now < closeAt {
			r.warnOnce("late-"+u(cur), fmt.Sprintf("round %d: too close to the window's end to submit safely", cur))
		}
	}
	_ = submittedNow

	// 3. claim rewards on the cadence
	if r.p.claimEvery > 0 && now-st.LastClaimAt >= int64(r.p.claimEvery/time.Second) {
		p, err := r.a.client.Provider(core, r.fc.ID, me)
		if err == nil {
			claimed := true
			if p.Rewards >= r.p.claimMin {
				res, err := r.a.client.Call(ctx, core, "ClaimRewards", gnochain.CallOpts{}, u(r.fc.ID))
				if err != nil {
					claimed = false
					r.log.Printf("claim: %v", err)
					r.a.journal.Write(Entry{Feed: r.fc.ID, Kind: "error", Text: "claim", Err: err.Error()})
				} else {
					paid, _ := gnochain.Int64Result(res.Data)
					r.log.Printf("claimed %s ugnot (tx %s)", i(paid), res.Hash)
					r.a.journal.Write(Entry{Feed: r.fc.ID, Kind: "claim", Value: &paid, Tx: res.Hash, GasUsed: res.GasUsed, Fee: res.Fee})
				}
			}
			if claimed {
				r.a.state.Update(r.fc.ID, func(fs *FeedState) { fs.LastClaimAt = now })
				_ = r.a.state.Save()
			}
		}
	}
	return nil
}

// crank calls CatchUp when a closed round waits for finalisation. The batch
// size adapts: an out-of-gas simulation halves it, success grows it back.
func (r *feedRunner) crank(ctx context.Context, f *gnochain.FeedInfo, sched gnochain.Schedule, cur uint64, now int64, slot int) error {
	if time.Now().Before(r.backoff) {
		return nil
	}
	next := sched.Next(f.LastFinalized, f.HaveLast)
	if sched.IsOneOff() && next != 0 {
		return nil
	}
	// agents on the same feed stagger by slot so only one usually pays for a
	// CatchUp that another already did (a lost race costs the full fee)
	delay := int64(r.p.finalizeDelay/time.Second) + int64(slot)*2
	if next > cur || now < sched.CloseAt(next)+delay {
		return nil
	}
	// re-read right before spending: another agent may have finalised
	if fresh, err := r.a.client.Feed(r.a.cfg.Core, r.fc.ID); err == nil {
		if sched.Next(fresh.LastFinalized, fresh.HaveLast) != next {
			return nil
		}
	}
	if next == cur || !r.p.catchUpEmpty {
		rd, err := r.a.client.Round(r.a.cfg.Core, r.fc.ID, next)
		if err != nil {
			return err
		}
		if !rd.Exists && !r.p.catchUpEmpty {
			return nil
		}
		if rd.Exists && rd.Status != "open" {
			return nil
		}
	}
	if r.batch <= 0 {
		r.batch = r.p.catchUpBatch
	}
	for {
		res, err := r.a.client.Call(ctx, r.a.cfg.Core, "CatchUp", gnochain.CallOpts{}, u(r.fc.ID), i(r.batch))
		if err != nil {
			if strings.Contains(err.Error(), "out of gas") && r.batch > 1 {
				r.batch /= 2
				r.log.Printf("catch-up: out of gas, retrying with a batch of %d", r.batch)
				continue
			}
			r.backoff = time.Now().Add(30 * time.Second)
			r.a.journal.Write(Entry{Feed: r.fc.ID, Round: next, Kind: "error", Text: "catch-up", Err: err.Error()})
			return err
		}
		n, _ := gnochain.Int64Result(res.Data)
		r.log.Printf("finalised %d round(s) from %d (tx %s, gas %d, fee %s)", n, next, res.Hash, res.GasUsed, res.Fee)
		r.a.journal.Write(Entry{Feed: r.fc.ID, Round: next, Kind: "finalize", Value: &n, Tx: res.Hash, GasUsed: res.GasUsed, Fee: res.Fee})
		if n >= r.batch && r.batch < r.p.catchUpBatch {
			r.batch *= 2
		}
		return nil
	}
}

// submit fetches, validates and broadcasts the round's value.
func (r *feedRunner) submit(ctx context.Context, f *gnochain.FeedInfo, round uint64, st *FeedState, headroom int64) error {
	fctx, cancel := context.WithTimeout(ctx, r.p.timeout)
	samples := r.adapter.Fetch(fctx)
	cancel()
	minSources := 1
	if h, ok := r.adapter.(*httpAdapter); ok {
		minSources = h.MinSources()
	}
	num, label, err := Aggregate(samples, f.Spec.IsNumeric(), minSources)
	if err != nil {
		r.a.journal.Write(Entry{Feed: r.fc.ID, Round: round, Kind: "error", Text: "fetch", Samples: samples, Err: err.Error()})
		if _, ok := r.adapter.(*fileAdapter); ok {
			r.warnOnce("answer", "waiting for the answer file "+r.fc.Source.File)
			return nil
		}
		return fmt.Errorf("fetch: %w", err)
	}
	var value int64
	if f.Spec.IsNumeric() {
		if r.p.min != nil && num.Cmp(r.p.min) < 0 || r.p.max != nil && num.Cmp(r.p.max) > 0 {
			return r.refuse(ctx, f, round, samples, fmt.Sprintf("%s is outside the configured bounds [%s, %s]", num.FloatString(6), ratText(r.p.min), ratText(r.p.max)))
		}
		if value, err = ScaleToInt(num, f.Spec.Decimals); err != nil {
			return err
		}
	} else {
		if value, err = OptionIndex(f.Spec.Options, label, r.fc.Source.Map); err != nil {
			return r.refuse(ctx, f, round, samples, err.Error())
		}
	}
	r.a.journal.Write(Entry{Feed: r.fc.ID, Round: round, Kind: "fetch", Value: &value, Samples: samples})

	// sanity against the latest of the public value and our last submission
	if f.Spec.IsNumeric() && r.p.sanityBps > 0 {
		if ref, have := sanityRef(*st, f); have && !WithinBps(value, ref, r.p.sanityBps) {
			msg := fmt.Sprintf("%s deviates more than %d bps from the reference %s", FormatScaled(value, f.Spec.Decimals), r.p.sanityBps, FormatScaled(ref, f.Spec.Decimals))
			if !r.fc.Override {
				return r.refuse(ctx, f, round, samples, msg)
			}
			r.log.Printf("override: submitting although %s", msg)
			r.a.journal.Write(Entry{Feed: r.fc.ID, Round: round, Kind: "alert", Value: &value, Text: "override: " + msg})
		}
	}

	// A submission that completes the round finalises it in the same call
	// (about 13M gas more than a plain Submit on v1.2.0); when the simulation
	// may run before the last other submission lands, the caller passes that
	// headroom rather than pay for a failed transaction.
	res, err := r.a.client.Call(ctx, r.a.cfg.Core, "Submit", gnochain.CallOpts{ExtraGas: headroom}, u(r.fc.ID), u(round), i(value))
	if err != nil {
		if strings.Contains(err.Error(), "obligations start at round") {
			r.obliged = nil // re-read the provider record next tick
		}
		r.a.journal.Write(Entry{Feed: r.fc.ID, Round: round, Kind: "error", Text: "submit", Value: &value, Err: err.Error()})
		return fmt.Errorf("submit: %w", err)
	}
	r.a.state.Update(r.fc.ID, func(fs *FeedState) {
		fs.HasRound, fs.LastRound, fs.HasValue, fs.LastValue, fs.ValueRound, fs.LastTxHash = true, round, true, value, round, res.Hash
	})
	_ = r.a.state.Save()
	r.log.Printf("round %d: submitted %s (tx %s, gas %d, fee %s)", round, FormatScaled(value, f.Spec.Decimals), res.Hash, res.GasUsed, res.Fee)
	r.a.journal.Write(Entry{Feed: r.fc.ID, Round: round, Kind: "submit", Value: &value, Tx: res.Hash, GasUsed: res.GasUsed, Fee: res.Fee})
	return nil
}

// sanityRef is the reference a fresh value is checked against: the latest
// public value, unless the agent's own last submission is to a later round
// than the one that value comes from (the public value lags a round or more
// behind the submissions). An own value of unknown round (a state written
// before ValueRound was kept) yields to the public one.
func sanityRef(st FeedState, f *gnochain.FeedInfo) (int64, bool) {
	switch {
	case f.Value != nil && (!st.HasValue || f.LastRound >= st.ValueRound):
		return *f.Value, true
	case st.HasValue:
		return st.LastValue, true
	}
	return 0, false
}

func (r *feedRunner) refuse(ctx context.Context, f *gnochain.FeedInfo, round uint64, samples []Sample, why string) error {
	r.a.journal.Write(Entry{Feed: r.fc.ID, Round: round, Kind: "refused", Text: why, Samples: samples})
	if r.refused == nil {
		r.refused = map[uint64]bool{}
	}
	if !r.refused[round] {
		r.refused[round] = true
		r.a.alert(ctx, fmt.Sprintf("feed %d round %d: REFUSED to submit: %s. Check the sources; set override = true to force.", f.ID, round, why))
	}
	return errors.New("refused: " + why)
}

func ratText(r *big.Rat) string {
	if r == nil {
		return "-"
	}
	return r.FloatString(6)
}
