package bot

import (
	"context"
	"fmt"
	"strings"
)

// remind posts deadline reminders for running ballots and nudges opted-in
// members who have not committed or revealed yet.
func (b *Bot) remind(ctx context.Context) error {
	list, err := b.client.Ballots(b.cfg.DAO, 0, 25)
	if err != nil {
		return err
	}
	now := list.Now
	for i := range list.Ballots {
		bl := &list.Ballots[i]
		phase := bl.LivePhase(now)
		var deadline int64
		var verb string
		switch phase {
		case "commit":
			deadline, verb = bl.CommitEnds, "commit"
		case "reveal":
			deadline, verb = bl.RevealEnds, "reveal"
			if b.state.once(fmt.Sprintf("open:%d:reveal", bl.Seq)) {
				b.post(ctx, fmt.Sprintf("Dispute %d: reveal phase is open until %s. Members who committed must now run `gnoracle reveal %d`.", bl.Dispute, when(bl.RevealEnds, now), bl.Dispute))
			}
		default:
			continue
		}
		left := deadline - now
		for _, h := range b.cfg.Remind.Hours {
			if left <= 0 || left > h*3600 {
				continue
			}
			key := fmt.Sprintf("remind:%d:%s:%d", bl.Seq, verb, h)
			if !b.state.once(key) {
				continue
			}
			missing := b.missing(bl.Seq, verb)
			msg := fmt.Sprintf("Reminder: dispute %d %s phase ends %s.", bl.Dispute, verb, when(deadline, now))
			if len(missing) > 0 {
				names := make([]string, 0, len(missing))
				for _, m := range missing {
					names = append(names, displayName(m))
				}
				msg += " Still to " + verb + ": " + strings.Join(names, ", ") + "."
			}
			msg += " Absence costs stake (UMA-style penalties)."
			b.post(ctx, msg)
			for _, m := range missing {
				b.dm(ctx, m, fmt.Sprintf("You have not %sed on dispute %d yet. The %s phase ends %s. Run `gnoracle %s %d ...`.", verb+"t", bl.Dispute, verb, when(deadline, now), verb, bl.Dispute))
			}
			break // one reminder per pass: the tightest threshold
		}
	}
	return nil
}

// missing lists opted-in members who still owe the action.
func (b *Bot) missing(seq uint64, verb string) []MemberConfig {
	var out []MemberConfig
	for _, m := range b.cfg.Members {
		var done bool
		if verb == "commit" {
			v, err := b.client.CommitOf(b.cfg.DAO, seq, m.Addr)
			done = err == nil && v.Committed
		} else {
			v, err := b.client.RevealOf(b.cfg.DAO, seq, m.Addr)
			c, cerr := b.client.CommitOf(b.cfg.DAO, seq, m.Addr)
			done = (err == nil && v.Revealed) || (cerr == nil && !c.Committed) // nothing to reveal without a commit
		}
		if !done {
			out = append(out, m)
		}
	}
	return out
}

func displayName(m MemberConfig) string {
	if m.Name != "" {
		return m.Name
	}
	if len(m.Addr) > 12 {
		return m.Addr[:12] + "…"
	}
	return m.Addr
}
