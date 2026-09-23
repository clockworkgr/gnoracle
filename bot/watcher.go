package bot

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

// scan announces the events of the blocks since the last tick.
func (b *Bot) scan(ctx context.Context) error {
	head, err := b.client.LatestHeight()
	if err != nil {
		return err
	}
	if b.state.Height == 0 {
		start := b.cfg.StartHeight
		if start <= 0 || start > head {
			start = head
		}
		b.state.Height = start - 1
	}
	if head < b.state.Height {
		log.Printf("chain head %d is below the saved cursor %d (a new chain?); rescanning from the head", head, b.state.Height)
		b.state.Height = head - 1
	}
	to := head
	if to-b.state.Height > int64(b.cfg.MaxBlocks) {
		to = b.state.Height + int64(b.cfg.MaxBlocks)
	}
	for h := b.state.Height + 1; h <= to; h++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		events, err := b.client.BlockEvents(ctx, h, b.pkgs)
		if err != nil {
			return fmt.Errorf("block %d: %w", h, err)
		}
		for _, ev := range events {
			if !b.p.events[ev.Type] {
				continue
			}
			if !b.state.once(fmt.Sprintf("ev:%d:%d:%d:%s", ev.Height, ev.TxIndex, ev.Index, ev.Type)) {
				continue
			}
			b.post(ctx, b.format(ev))
		}
		b.state.Height = h
	}
	return nil
}

// format renders one event as a message with the deadlines that matter.
func (b *Bot) format(ev gnochain.Event) string {
	var sb strings.Builder
	realm := "core"
	switch ev.PkgPath {
	case b.cfg.Core:
	case b.cfg.DAO:
		realm = "dao"
	case b.cfg.Kourt:
		realm = "kourt"
	default:
		realm = "proxy" // the upgrade package: its events name the implementation path
	}
	fmt.Fprintf(&sb, "[%s] %s", realm, ev.String())
	switch ev.Type {
	case "DisputeOpened", "DisputeBallotOpened", "DisputeRolled", "AppealOpened", "DisputeDecided", "DisputeResolved", "KourtDissent":
		id, _ := strconv.ParseUint(ev.Attr("dispute"), 10, 64)
		if id == 0 {
			break
		}
		d, err := b.client.Dispute(b.cfg.Core, id)
		if err == nil {
			fmt.Fprintf(&sb, "\nfeed %d round %d, disputer %s, bond %s, asks %s, status %s", d.Feed, d.Round, d.Disputer, gnot(d.Bond), d.TierAsked, d.Status)
			if d.Outcome != "" {
				fmt.Fprintf(&sb, ", outcome %s", d.Outcome)
			}
			if d.Status == "decided" && d.AppealWindowEnds > 0 {
				fmt.Fprintf(&sb, "\nappeal window ends %s", when(d.AppealWindowEnds, d.Now))
			}
			if bl, err := b.client.BallotOfDispute(b.cfg.DAO, id); err == nil && bl != nil && bl.ResolvedAt == 0 {
				fmt.Fprintf(&sb, "\nballot round %d: commit until %s, reveal until %s\nvote: gnoracle commit %d <UPHOLD|OVERTURN|OVERTURN_MINOR|VOID|ABSTAIN>, then gnoracle reveal %d after the commit phase",
					bl.Round, when(bl.CommitEnds, d.Now), when(bl.RevealEnds, d.Now), id, id)
			}
		}
		if l := b.link(b.cfg.Core, "dispute/"+u(id)); l != "" {
			sb.WriteString("\n" + l)
		}
	case "ProposalCreated", "ProposalStatus":
		id, _ := strconv.ParseUint(ev.Attr("id"), 10, 64)
		if p, err := b.client.Proposal(b.cfg.DAO, id); err == nil {
			fmt.Fprintf(&sb, "\n#%d %s: %s (%s) — voting ends %s", p.ID, p.Kind, p.Title, p.Status, when(p.VotingEnds, p.Now))
			if p.Status == "passed" && p.Executable > 0 {
				fmt.Fprintf(&sb, ", executable from %s", when(p.Executable, p.Now))
			}
		}
		if l := b.link(b.cfg.DAO, "proposal/"+u(id)); l != "" {
			sb.WriteString("\n" + l)
		}
	case "ProviderJailed", "ProviderSlashed", "ProviderEjected", "FeedProposed", "FeedActivated", "FeedDeprecated", "FeedUnfunded", "FeedReopened":
		id, _ := strconv.ParseUint(ev.Attr("feed"), 10, 64)
		if f, err := b.client.Feed(b.cfg.Core, id); err == nil {
			fmt.Fprintf(&sb, "\nfeed %d %q (%s, %s), %d active provider(s)", f.ID, f.Spec.Name, f.Spec.Kind, f.Status, f.ActiveCount)
		}
		if l := b.link(b.cfg.Core, "feed/"+u(id)); l != "" {
			sb.WriteString("\n" + l)
		}
	}
	return sb.String()
}
