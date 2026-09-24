package impl

import (
	"strconv"
	"strings"

	"gno.land/r/clockwork/gnoracle/core"
)

// Render serves the gnoweb pages. Everything the chain holds is public, so
// the pages show every value at once; what a subscription buys is a realm's
// right to use a value inside its own logic (plan §6.1).
func (*implV1) Render(_ int, rlm realm, path string) string {
	st := core.Store(0, rlm)
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case parts[0] == "json":
		return renderJSON(st, parts[1:])
	case path == "" || parts[0] == "feeds":
		return renderFeeds(st, parts)
	case parts[0] == "disputes":
		return renderDisputes()
	case parts[0] == "dispute" && len(parts) >= 2:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "unknown dispute"
		}
		return renderDispute(id)
	case parts[0] == "feed" && len(parts) >= 2:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "unknown feed"
		}
		if len(parts) >= 3 && parts[2] == "rounds" {
			return renderRounds(st, id)
		}
		if len(parts) >= 3 && parts[2] == "subscribers" {
			offset, count := pageArgs(parts[3:], 0, 50, 100)
			return renderSubscribers(id, offset, count)
		}
		return renderFeed(st, id)
	case parts[0] == "provider" && len(parts) >= 3:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "unknown feed"
		}
		return renderProvider(id, address(parts[2]))
	case (parts[0] == "account" || parts[0] == "consumer") && len(parts) >= 2:
		return renderAccount(address(parts[1]))
	case parts[0] == "health":
		return "# Health\n\n```\n" + core.Health() + "\n```\n"
	case parts[0] == "params":
		return "# Parameters\n\n```\n" + core.ParamsJSON() + "\n```\n"
	}
	return "not found"
}

func renderFeeds(st *core.StateRef, parts []string) string {
	var b strings.Builder
	b.WriteString("# Gnoracle\n\nAn oracle DAO on gno.land. Serving `" + core.LivePath() + "`.\n\n")
	b.WriteString("Pages: [feeds](:feeds) · [disputes](:disputes) · [health](:health) · [parameters](:params) · [releases](:releases)\n\n")
	b.WriteString("## Feeds\n\n| id | name | kind | status | providers | value |\n|---|---|---|---|---|---|\n")
	page := 0
	if len(parts) >= 2 {
		if p, err := strconv.Atoi(parts[1]); err == nil && p >= 0 {
			page = p
		}
	}
	const size = 25
	core.IterateFeeds(page*size, size, func(f *core.Feed) bool {
		b.WriteString("| [" + u(f.ID) + "](:feed/" + u(f.ID) + ") | " + esc(f.Spec.Name) + " | " + f.Spec.Kind + " | " + f.Status +
			" | " + i(f.ActiveCount) + "/" + strconv.Itoa(f.Spec.MaxProviders) + " | " + lastValue(st, f) + " |\n")
		return false
	})
	total := int(core.FeedCount())
	if total > (page+1)*size {
		b.WriteString("\n[next page](:feeds/" + strconv.Itoa(page+1) + ")\n")
	}
	return b.String()
}

// lastValue shows the served value and its round.
func lastValue(st *core.StateRef, f *core.Feed) string {
	if !f.HaveValue {
		return "—"
	}
	last, _ := st.FeedValues(f.ID)
	return formatValue(f, last) + " @ round " + u(f.LastRound)
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

func renderFeed(st *core.StateRef, id uint64) string {
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
	switch {
	case !sp.IsRecurring():
		b.WriteString("| realm access | every realm may read a one-off outcome |\n")
	case sp.Sponsored:
		b.WriteString("| realm access | sponsored: every realm may read |\n")
	default:
		n, more := subscriberCount(id, now())
		count := strconv.Itoa(n)
		if more {
			count += "+"
		}
		b.WriteString("| realm access | " + i(sp.SubscriberPrice) + " ugnot per period per realm, " + count + " subscribed ([subscribers](:feed/" + u(id) + "/subscribers)) |\n")
	}
	b.WriteString("| value at risk | " + i(valueAtRisk(f)) + " ugnot |\n")
	b.WriteString("| last value | " + lastValue(st, f) + " (tier " + servedTier(st, f, now()) + ") |\n")
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
	budget := core.MulBps(stake, param("majorSlashBps"))
	threshold := (n + 1) / 2
	return budget / 2 * threshold / n
}

func renderRounds(st *core.StateRef, id uint64) string {
	f := core.GetFeed(id)
	if f == nil {
		return "unknown feed"
	}
	var b strings.Builder
	b.WriteString("# Feed " + u(id) + " rounds\n\n| round | status | tier | value | eligible | pool | finalised |\n|---|---|---|---|---|---|---|\n")
	core.ReverseIterateRounds(id, 50, func(rd *core.Round) bool {
		val := "—"
		if rd.Status == core.RoundAggregated {
			val = formatValue(f, st.RoundValue(id, rd.ID))
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

func renderAccount(addr address) string {
	if !addr.IsValid() {
		return "unknown account"
	}
	c := core.GetCredit(addr)
	if c == nil {
		return "no prepaid balance for " + esc(string(addr))
	}
	return "# Prepaid balance of " + esc(string(addr)) + "\n\nA realm cannot attach coins to its own calls; this balance pays its feed requests, bounties and subscriptions, and receives its refunds.\n\n| | |\n|---|---|\n| balance | " + i(c.Balance) + " ugnot |\n| spent | " + i(c.Spent) + " ugnot |\n"
}

// subscriberScan is how many subscription records the feed page looks at to
// count the active ones; the page shows "n+" past it.
const subscriberScan = 100

// subscriberCount is the number of realms whose subscription covers t among
// the first subscriberScan records, and whether more records exist.
func subscriberCount(feed uint64, t int64) (n int, more bool) {
	seen := 0
	core.IterateSubscriptions(feed, func(s *core.Subscription) bool {
		if seen == subscriberScan {
			more = true
			return true
		}
		seen++
		if s.PaidUntil > t {
			n++
		}
		return false
	})
	return n, more
}

// renderSubscribers lists count subscription records from offset, in realm
// path order: `feed/<id>/subscribers[/<offset>[/<count>]]`.
func renderSubscribers(id uint64, offset, count int64) string {
	f := core.GetFeed(id)
	if f == nil {
		return "unknown feed"
	}
	var b strings.Builder
	b.WriteString("# Feed " + u(id) + " subscribers\n\n")
	switch {
	case !f.Spec.IsRecurring():
		b.WriteString("A one-off outcome is open to every realm; there is nothing to subscribe to.\n")
		return b.String()
	case f.Spec.Sponsored:
		b.WriteString("A sponsored feed is free for every realm; there is nothing to subscribe to.\n")
		return b.String()
	}
	b.WriteString("Realms that may `Read` this feed, and until when (chain time). `SubscribeRealm <feed> <realm path> <periods>` with " + i(f.Spec.SubscriberPrice) + " ugnot per period adds or extends one.\n\n| realm | since | paid until | paid | periods | active |\n|---|---|---|---|---|---|\n")
	t := now()
	shown := int64(0)
	more := false
	core.IterateSubscriptionsFrom(id, int(offset), int(count)+1, func(s *core.Subscription) bool {
		if shown == count {
			more = true
			return true
		}
		shown++
		b.WriteString("| `" + esc(s.Realm) + "` | " + i(s.Since) + " | " + i(s.PaidUntil) + " | " + i(s.Paid) + " | " + i(s.Periods) + " | " + strconv.FormatBool(s.PaidUntil > t) + " |\n")
		return false
	})
	if offset > 0 {
		prev := offset - count
		if prev < 0 {
			prev = 0
		}
		b.WriteString("\n[previous page](:feed/" + u(id) + "/subscribers/" + i(prev) + "/" + i(count) + ")")
	}
	if more {
		b.WriteString("\n[next page](:feed/" + u(id) + "/subscribers/" + i(offset+count) + "/" + i(count) + ")")
	}
	b.WriteString("\n")
	return b.String()
}

func popcount(m uint32) int {
	n := 0
	for m != 0 {
		m &= m - 1
		n++
	}
	return n
}

// esc neutralises markdown control characters in user text. The replacer
// works in one pass, so the backslashes it adds are never escaped again.
func esc(s string) string {
	r := strings.NewReplacer("\\", "\\\\", "`", "\\`", "|", "\\|", "<", "&lt;", ">", "&gt;", "[", "\\[", "]", "\\]", "\n", " ", "\r", " ")
	return r.Replace(s)
}
