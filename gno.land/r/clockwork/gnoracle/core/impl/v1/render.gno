package impl

import (
	"strconv"
	"strings"

	"gno.land/r/clockwork/gnoracle/core"
)

// Render serves the gnoweb pages. Values appear only once final and older
// than renderDelay, so the free view never leaks fresh data (plan §6.1).
func (*implV1) Render(_ int, rlm realm, path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "" || parts[0] == "feeds":
		return renderFeeds(parts)
	case parts[0] == "feed" && len(parts) >= 2:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "unknown feed"
		}
		if len(parts) >= 3 && parts[2] == "rounds" {
			return renderRounds(id)
		}
		return renderFeed(id)
	case parts[0] == "provider" && len(parts) >= 3:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "unknown feed"
		}
		return renderProvider(id, address(parts[2]))
	case parts[0] == "consumer" && len(parts) >= 2:
		return renderConsumer(address(parts[1]))
	case parts[0] == "health":
		return "# Health\n\n```\n" + core.Health() + "\n```\n"
	case parts[0] == "params":
		return "# Parameters\n\n```\n" + core.ParamsJSON() + "\n```\n"
	}
	return "not found"
}

func renderFeeds(parts []string) string {
	var b strings.Builder
	b.WriteString("# Gnoracle\n\nAn oracle DAO on gno.land. Serving `" + core.LivePath() + "`.\n\n")
	b.WriteString("Pages: [feeds](:feeds) · [health](:health) · [parameters](:params) · [releases](:releases)\n\n")
	b.WriteString("## Feeds\n\n| id | name | kind | status | providers | value (delayed) |\n|---|---|---|---|---|---|\n")
	page := 0
	if len(parts) >= 2 {
		if p, err := strconv.Atoi(parts[1]); err == nil && p >= 0 {
			page = p
		}
	}
	const size = 25
	core.IterateFeeds(page*size, size, func(f *core.Feed) bool {
		b.WriteString("| [" + u(f.ID) + "](:feed/" + u(f.ID) + ") | " + esc(f.Spec.Name) + " | " + f.Spec.Kind + " | " + f.Status +
			" | " + i(f.ActiveCount) + "/" + strconv.Itoa(f.Spec.MaxProviders) + " | " + delayedValue(f) + " |\n")
		return false
	})
	total := int(core.FeedCount())
	if total > (page+1)*size {
		b.WriteString("\n[next page](:feeds/" + strconv.Itoa(page+1) + ")\n")
	}
	return b.String()
}

// delayedValue shows the served value only once it is final and older than
// renderDelay.
func delayedValue(f *core.Feed) string {
	if !f.HaveValue {
		return "—"
	}
	t := now()
	if t < f.LastFinalAt+f.Spec.DisputeWindow+param("renderDelay") {
		return "(fresh; read on-chain)"
	}
	return formatValue(f, f.LastValue) + " @ round " + u(f.LastRound)
}

func formatValue(f *core.Feed, v int64) string {
	if !f.Spec.IsNumeric() {
		return esc(f.Spec.OptionLabel(v)) + " (#" + i(v) + ")"
	}
	s := strconv.FormatInt(v, 10)
	d := f.Spec.Decimals
	if d == 0 {
		return s
	}
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	for len(s) <= d {
		s = "0" + s
	}
	out := s[:len(s)-d] + "." + s[len(s)-d:]
	if neg {
		out = "-" + out
	}
	return out
}

func renderFeed(id uint64) string {
	f := core.GetFeed(id)
	if f == nil {
		return "unknown feed"
	}
	sp := f.Spec
	var b strings.Builder
	b.WriteString("# Feed " + u(id) + ": " + esc(sp.Name) + "\n\n")
	b.WriteString(esc(sp.Description) + "\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| status | " + f.Status + " |\n")
	b.WriteString("| kind | " + sp.Kind + " / " + sp.ValueType + " |\n")
	if sp.IsRecurring() {
		b.WriteString("| interval | " + i(sp.Interval) + " s, submit window " + i(sp.SubmitWindow) + " s |\n")
		b.WriteString("| subscription | " + i(sp.SubscriptionPrice) + " ugnot per period, paid until " + i(f.PaidUntil) + " |\n")
		b.WriteString("| pool | " + i(f.Pool) + " ugnot, drip " + i(f.Drip) + " per round |\n")
	} else {
		b.WriteString("| resolves at | " + i(f.StartAt) + " (window " + i(sp.SubmitWindow) + " s) |\n")
		b.WriteString("| bounty | " + i(f.Pool) + " ugnot |\n")
		b.WriteString("| options | " + esc(strings.Join(sp.Options, ", ")) + " |\n")
	}
	b.WriteString("| providers | " + i(f.ActiveCount) + " of " + strconv.Itoa(sp.MaxProviders) + " (min " + strconv.Itoa(sp.MinProviders) + "), min stake " + i(sp.ProviderMinStake) + " ugnot |\n")
	b.WriteString("| tolerance / quarantine | " + i(sp.ToleranceBps) + " / " + i(sp.QuarantineBps) + " bps |\n")
	b.WriteString("| dispute window | " + i(sp.DisputeWindow) + " s |\n")
	b.WriteString("| read price | " + i(sp.ReadPrice) + " ugnot |\n")
	b.WriteString("| value at risk | " + i(valueAtRisk(f)) + " ugnot |\n")
	b.WriteString("| last value | " + delayedValue(f) + " (tier " + servedTier(f, now()) + ") |\n")
	b.WriteString("| spec hash | `" + sp.Hash + "` |\n\n")
	b.WriteString("Sources: " + esc(sp.Sources) + "\n\n")
	b.WriteString("## Providers\n\n| slot | address | stake | misses | strikes | rewards |\n|---|---|---|---|---|---|\n")
	for s := 0; s < core.MaxSlots; s++ {
		if f.SlotAt(s) == "" {
			continue
		}
		p := core.GetProvider(id, f.SlotAt(s))
		if p == nil {
			continue
		}
		b.WriteString("| " + strconv.Itoa(s) + " | [" + string(p.Addr) + "](:provider/" + u(id) + "/" + string(p.Addr) + ") | " + i(p.Stake) + " | " + i(p.ConsecutiveMisses) + " | " + i(p.Strikes) + " | " + i(p.Rewards) + " |\n")
	}
	b.WriteString("\n[rounds](:feed/" + u(id) + "/rounds)\n")
	return b.String()
}

// valueAtRisk is the plan's published figure (§5.3): half the major-slash
// security budget times the corruption threshold over the active count.
func valueAtRisk(f *core.Feed) int64 {
	var stake int64
	for s := 0; s < core.MaxSlots; s++ {
		if f.SlotAt(s) == "" {
			continue
		}
		if p := core.GetProvider(f.ID, f.SlotAt(s)); p != nil {
			stake += p.Stake
		}
	}
	n := f.ActiveCount
	if n == 0 {
		return 0
	}
	budget := stake * param("majorSlashBps") / 10_000
	threshold := (n + 1) / 2
	return budget / 2 * threshold / n
}

func renderRounds(id uint64) string {
	f := core.GetFeed(id)
	if f == nil {
		return "unknown feed"
	}
	var b strings.Builder
	b.WriteString("# Feed " + u(id) + " rounds\n\n| round | status | tier | value (delayed) | eligible | pool | finalised |\n|---|---|---|---|---|---|---|\n")
	t := now()
	core.ReverseIterateRounds(id, 50, func(rd *core.Round) bool {
		val := "(fresh)"
		if rd.Status != core.RoundAggregated {
			val = "—"
		} else if t >= rd.FinalisedAt+f.Spec.DisputeWindow+param("renderDelay") {
			val = formatValue(f, rd.Value)
		}
		b.WriteString("| " + u(rd.ID) + " | " + rd.Status + " | " + rd.Tier + " | " + val + " | " + strconv.Itoa(popcount(rd.EligibleMask)) + "/" + strconv.Itoa(popcount(rd.SubmittedMask)) + " | " + i(rd.Pool) + " | " + i(rd.FinalisedAt) + " |\n")
		return false
	})
	return b.String()
}

func renderProvider(id uint64, addr address) string {
	p := core.GetProvider(id, addr)
	if p == nil {
		return "unknown provider"
	}
	var b strings.Builder
	b.WriteString("# Provider " + string(addr) + " on feed " + u(id) + "\n\n| | |\n|---|---|\n")
	b.WriteString("| status | " + p.Status + " |\n| stake | " + i(p.Stake) + " |\n| unbonding | " + i(p.UnbondAmount) + " (ready " + i(p.UnbondReadyAt) + ") |\n")
	b.WriteString("| rewards unclaimed | " + i(p.Rewards) + " |\n| total earned | " + i(p.TotalEarned) + " |\n| total slashed | " + i(p.TotalSlashed) + " |\n")
	b.WriteString("| consecutive misses | " + i(p.ConsecutiveMisses) + " |\n| strikes | " + i(p.Strikes) + " |\n| jailings | " + i(p.Jailings) + " |\n")
	b.WriteString("| memo | " + esc(p.Memo) + " |\n")
	return b.String()
}

func renderConsumer(addr address) string {
	c := core.GetCredit(addr)
	if c == nil {
		return "no credit record"
	}
	return "# Consumer " + string(addr) + "\n\n| | |\n|---|---|\n| balance | " + i(c.Balance) + " |\n| spent | " + i(c.Spent) + " |\n| reads | " + i(c.Reads) + " |\n| final only | " + strconv.FormatBool(c.FinalOnly) + " |\n"
}

func popcount(m uint32) int {
	n := 0
	for m != 0 {
		m &= m - 1
		n++
	}
	return n
}

// esc neutralises markdown control characters in user text.
func esc(s string) string {
	r := strings.NewReplacer("|", "\\|", "<", "&lt;", ">", "&gt;", "[", "\\[", "]", "\\]", "\n", " ")
	return r.Replace(s)
}
