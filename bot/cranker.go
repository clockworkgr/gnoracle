package bot

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

// crank runs the enabled cranks; each logs and continues on error.
func (b *Bot) crank(ctx context.Context) {
	if !b.client.CanSign() {
		return
	}
	if b.cfg.Crank.Finalize {
		if err := b.crankFinalize(ctx); err != nil {
			log.Printf("crank finalize: %v", err)
		}
	}
	if b.cfg.Crank.Resolve {
		if err := b.crankResolve(ctx); err != nil {
			log.Printf("crank resolve: %v", err)
		}
	}
	now := time.Now().Unix()
	if b.cfg.Crank.Kourt && now-b.state.LastKourt >= int64(b.p.kourtEvery/time.Second) {
		b.state.LastKourt = now
		if err := b.crankKourt(ctx); err != nil {
			log.Printf("crank kourt: %v", err)
		}
	}
	if b.cfg.Crank.Settle && now-b.state.LastSettle >= int64(b.p.settleEvery/time.Second) {
		b.state.LastSettle = now
		b.crankSettle(ctx)
	}
}

// crankFinalize writes off or finalises closed rounds after a grace period
// that leaves the feed's own agents the tip.
func (b *Bot) crankFinalize(ctx context.Context) error {
	feeds, err := b.client.AllFeeds(b.cfg.Core)
	if err != nil {
		return err
	}
	head, err := b.client.CoreNow(b.cfg.Core)
	if err != nil {
		return err
	}
	now := head.Now
	grace := int64(b.p.finalizeGrace / time.Second)
	for _, f := range feeds {
		if f.Status != "active" && f.Status != "unfunded" {
			continue
		}
		sched := f.Schedule()
		next := sched.Next(f.LastFinalized, f.HaveLast)
		if sched.IsOneOff() && next != 0 {
			continue
		}
		cur, ok := sched.Current(now)
		if !ok || next > cur || now < sched.CloseAt(next)+grace {
			continue
		}
		if !b.state.due("finalize:"+u(f.ID), b.p.crankEvery) {
			continue
		}
		if !b.p.catchUpEmpty {
			rd, err := b.client.Round(b.cfg.Core, f.ID, next)
			if err != nil || !rd.Exists {
				continue
			}
		}
		batch := b.batch[f.ID]
		if batch <= 0 {
			batch = b.p.catchUpBatch
		}
		for {
			res, err := b.client.Call(ctx, b.cfg.Core, "CatchUp", gnochain.CallOpts{}, u(f.ID), strconv.FormatInt(batch, 10))
			if err != nil {
				if strings.Contains(err.Error(), "out of gas") && batch > 1 {
					batch /= 2
					continue
				}
				log.Printf("feed %d CatchUp: %v", f.ID, err)
				break
			}
			n, _ := gnochain.Int64Result(res.Data)
			log.Printf("feed %d: finalised %d round(s) from %d (tx %s, gas %d, fee %s)", f.ID, n, next, res.Hash, res.GasUsed, res.Fee)
			if n >= batch && batch < b.p.catchUpBatch {
				batch *= 2
			}
			break
		}
		b.batch[f.ID] = batch
	}
	return nil
}

// crankResolve moves disputes on once their ballot or appeal window is over.
func (b *Bot) crankResolve(ctx context.Context) error {
	disputes, err := b.client.AllDisputes(b.cfg.Core)
	if err != nil {
		return err
	}
	for _, d := range disputes {
		var ready bool
		switch d.Status {
		case "open", "appealed":
			bl, err := b.client.BallotOfDispute(b.cfg.DAO, d.ID)
			if err != nil {
				log.Printf("dispute %d ballot: %v", d.ID, err)
				continue
			}
			ready = bl != nil && bl.ResolvedAt == 0 && d.Now >= bl.RevealEnds
		case "decided":
			ready = d.AppealWindowEnds > 0 && d.Now >= d.AppealWindowEnds
		}
		if !ready || !b.state.due(fmt.Sprintf("resolve:%d:%s", d.ID, d.Status), b.p.crankEvery) {
			continue
		}
		res, err := b.client.Call(ctx, b.cfg.Core, "ResolveDispute", gnochain.CallOpts{}, u(d.ID))
		if err != nil {
			log.Printf("dispute %d ResolveDispute: %v", d.ID, err)
			continue
		}
		log.Printf("dispute %d: resolved step from %s (tx %s, gas %d)", d.ID, d.Status, res.Hash, res.GasUsed)
	}
	return nil
}

// crankKourt advances the Kourt mirror of every resolved dispute.
func (b *Bot) crankKourt(ctx context.Context) error {
	disputes, err := b.client.AllDisputes(b.cfg.Core)
	if err != nil {
		return err
	}
	for _, d := range disputes {
		if d.Status != "resolved" {
			continue
		}
		rec, err := b.client.KourtRecord(b.cfg.Kourt, d.ID)
		if err != nil {
			log.Printf("kourt record %d: %v", d.ID, err)
			continue
		}
		if rec.Exists && rec.Terminal() {
			continue
		}
		res, err := b.client.Call(ctx, b.cfg.Kourt, "Crank", gnochain.CallOpts{}, u(d.ID))
		if err != nil {
			log.Printf("kourt crank %d: %v", d.ID, err)
			continue
		}
		state := ""
		if len(res.Results) > 0 {
			state = res.Results[0]
		}
		log.Printf("kourt: dispute %d mirror now %s (tx %s)", d.ID, state, res.Hash)
		if state == "dissent" {
			b.post(ctx, fmt.Sprintf("Kourt DISSENT on dispute %d: the court's vote disagreed with the DAO. %s", d.ID, b.link(b.cfg.Kourt, "dispute/"+u(d.ID))))
		}
	}
	return nil
}

// crankSettle applies pending ballot penalties and rewards for opted-in
// members.
func (b *Bot) crankSettle(ctx context.Context) {
	head, err := b.client.DAONow(b.cfg.DAO)
	if err != nil {
		log.Printf("settle: %v", err)
		return
	}
	for _, m := range b.cfg.Members {
		if !m.Settle {
			continue
		}
		mi, err := b.client.Member(b.cfg.DAO, m.Addr)
		if err != nil || !mi.Exists || mi.Cursor >= head.BallotCount {
			continue
		}
		next, err := b.client.Ballot(b.cfg.DAO, mi.Cursor+1)
		if err != nil || next.ResolvedAt == 0 {
			continue
		}
		res, err := b.client.Call(ctx, b.cfg.DAO, "SettleMember", gnochain.CallOpts{}, m.Addr, "0")
		if err != nil {
			log.Printf("settle %s: %v", m.Addr, err)
			continue
		}
		n, _ := gnochain.Int64Result(res.Data)
		log.Printf("settled %d ballot(s) for %s (tx %s)", n, displayName(m), res.Hash)
	}
}
