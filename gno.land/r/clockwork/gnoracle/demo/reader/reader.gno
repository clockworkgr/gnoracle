// Package reader is an example consumer realm for the local demo (`make
// demo`): anyone may ask it to read a Gnoracle feed, and it keeps the values
// it was served together with the block height and chain time of each read,
// which its page lists. Reads cost nothing per call and change nothing. The
// core serves a recurring, non-sponsored feed only to subscribed realms, so
// someone pays periods for this realm with `SubscribeRealm`, the way any
// consumer realm on gno.land would be set up; a sponsored feed and a final
// one-off outcome are open to every realm and need no subscription. It is not
// part of a deployment.
package reader

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/clockwork/gnoracle/jsonw/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// Reading is one value the realm was served.
type Reading struct {
	Seq      int64
	Height   int64
	Time     int64
	Feed     uint64
	Round    uint64
	Value    int64
	Decimals int64
	Tier     string
	Caller   address
}

const (
	// maxKept bounds the stored history; older readings are dropped first.
	maxKept = 2000
	// shown is how many of the newest readings the page and the JSON view list.
	shown = 50
)

var (
	selfPath string
	readings = avl.NewTree() // seqKey(seq) -> *Reading
	seq      int64
)

func init(cur realm) {
	selfPath = cur.PkgPath()
}

// seqKey zero-pads a sequence number so the tree orders readings by it.
func seqKey(n int64) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < 19 {
		s = "0" + s
	}
	return s
}

// Address is this realm's account.
func Address() address { return chain.PackageAddress(selfPath) }

// Path is this realm's package path: what `SubscribeRealm` takes.
func Path() string { return selfPath }

// Poll reads feedID through the core's Read and stores the reading (a
// recurring, non-sponsored feed must have this realm subscribed; a sponsored
// feed or a final one-off outcome needs no subscription). Any account or
// realm may call it.
func Poll(cur realm, feedID uint64) (value int64, round uint64, tier string) {
	v, dec, rid, _, t := core.Read(cross(cur), feedID)
	seq++
	readings.Set(seqKey(seq), &Reading{
		Seq: seq, Height: runtime.ChainHeight(), Time: time.Now().Unix(), Feed: feedID,
		Round: rid, Value: v, Decimals: dec, Tier: t, Caller: cur.Previous().Address(),
	})
	if readings.Size() > maxKept {
		// sequence numbers are contiguous, so the oldest kept one is known
		readings.Remove(seqKey(seq - int64(maxKept)))
	}
	chain.Emit("ReaderPolled", "feed", strconv.FormatUint(feedID, 10), "round", strconv.FormatUint(rid, 10), "value", strconv.FormatInt(v, 10), "tier", t)
	return v, rid, t
}

// Count is the number of readings kept.
func Count() int { return readings.Size() }

// Last returns the most recent reading, or a zero Reading.
func Last() Reading {
	if v := readings.Get(seqKey(seq)); v != nil {
		return *v.(*Reading)
	}
	return Reading{}
}

// newest returns up to n readings, newest first.
func newest(n int) []*Reading {
	out := []*Reading{}
	readings.ReverseIterateByOffset(0, n, func(_ string, v any) bool {
		out = append(out, v.(*Reading))
		return false
	})
	return out
}

// cell makes a string safe for a markdown table cell.
func cell(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\r", " ")
	return strings.ReplaceAll(s, "\n", " ")
}

// Render lists the newest readings first; `json` serves them as a machine
// view.
func Render(path string) string {
	if strings.HasPrefix(path, "json") {
		return renderJSON()
	}
	var b strings.Builder
	b.WriteString("# Example consumer realm\n\n")
	b.WriteString("This realm reads a Gnoracle feed when anyone calls `Poll(feedID)` and keeps what it was served. ")
	b.WriteString("A read costs nothing and changes nothing; the core serves a recurring feed because this realm is subscribed to it ")
	b.WriteString("(a sponsored feed or a final one-off outcome needs no subscription).\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| realm | `" + selfPath + "` (address `" + string(Address()) + "`) |\n")
	n := readings.Size()
	if n > 0 {
		b.WriteString("| subscription | " + subscriptionLine(Last().Feed) + " |\n")
	}
	b.WriteString("| readings kept | " + strconv.Itoa(n) + " |\n")
	if n == 0 {
		b.WriteString("\n_No readings yet: nobody has called `Poll` since this realm was deployed._\n")
		return b.String()
	}
	// a page is a query, so it may show the stored readings, but it cannot
	// read the feed itself (that is a call)
	names := map[uint64]string{}
	name := func(feed uint64) string {
		if s, ok := names[feed]; ok {
			return s
		}
		s := strconv.FormatUint(feed, 10)
		if f := core.GetFeed(feed); f != nil && f.Spec != nil {
			s += " " + cell(f.Spec.Name)
		}
		names[feed] = s
		return s
	}
	last := Last()
	b.WriteString("| last reading | **" + fixed(last.Value, last.Decimals) + "** (" + cell(last.Tier) + ") for round " + strconv.FormatUint(last.Round, 10) +
		" of feed " + name(last.Feed) + ", read at height " + strconv.FormatInt(last.Height, 10) + ", " + stamp(last.Time) + " UTC |\n\n")
	list := newest(shown)
	if n > len(list) {
		b.WriteString("_The newest " + strconv.Itoa(len(list)) + " of " + strconv.Itoa(n) + " readings:_\n\n")
	}
	b.WriteString("| # | height | chain time | feed | round | value | tier |\n|---|---|---|---|---|---|---|\n")
	for _, r := range list {
		b.WriteString("| " + strconv.FormatInt(r.Seq, 10) + " | " + strconv.FormatInt(r.Height, 10) + " | " + stamp(r.Time) +
			" | " + name(r.Feed) + " | " + strconv.FormatUint(r.Round, 10) + " | " + fixed(r.Value, r.Decimals) + " | " + cell(r.Tier) + " |\n")
	}
	return b.String()
}

func stamp(t int64) string { return time.Unix(t, 0).UTC().Format("2006-01-02 15:04:05") }

// renderJSON serves the count of readings kept and the newest ones, newest
// first.
func renderJSON() string {
	a := jsonw.NewArray()
	for _, r := range newest(shown) {
		a.Raw(jsonw.New().Int("seq", r.Seq).Int("height", r.Height).Int("time", r.Time).Uint("feed", r.Feed).Uint("round", r.Round).
			Int("value", r.Value).Int("decimals", r.Decimals).Str("tier", r.Tier).Str("caller", string(r.Caller)).String())
	}
	until := int64(0)
	if readings.Size() > 0 {
		if s := core.GetSubscription(Last().Feed, selfPath); s != nil {
			until = s.PaidUntil
		}
	}
	return jsonw.New().Int("now", time.Now().Unix()).Int("height", runtime.ChainHeight()).Str("address", string(Address())).Str("path", selfPath).
		Int("subscribedUntil", until).Int("count", int64(readings.Size())).Raw("readings", a.String()).String()
}

// subscriptionLine describes this realm's subscription to a feed.
func subscriptionLine(feed uint64) string {
	if f := core.GetFeed(feed); f != nil && f.Spec != nil {
		if !f.Spec.IsRecurring() {
			return "not needed: feed " + strconv.FormatUint(feed, 10) + " is a one-off outcome, open to every realm once final"
		}
		if f.Spec.Sponsored {
			return "not needed: feed " + strconv.FormatUint(feed, 10) + " is sponsored, free for every realm"
		}
	}
	s := core.GetSubscription(feed, selfPath)
	if s == nil {
		return "none on feed " + strconv.FormatUint(feed, 10) + " (reads are refused until someone runs `SubscribeRealm`)"
	}
	state := "active"
	if s.PaidUntil <= time.Now().Unix() {
		state = "lapsed"
	}
	return "feed " + strconv.FormatUint(feed, 10) + ": " + state + " until " + stamp(s.PaidUntil) + " UTC, " + gnot(s.Paid) + " GNOT paid over " + strconv.FormatInt(s.Periods, 10) + " period(s)"
}

// fixed prints a value with the feed's decimals.
func fixed(v, dec int64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	s := strconv.FormatInt(v, 10)
	if dec > 0 {
		for int64(len(s)) <= dec {
			s = "0" + s
		}
		s = s[:int64(len(s))-dec] + "." + s[int64(len(s))-dec:]
	}
	if neg {
		return "-" + s
	}
	return s
}

func gnot(ugnot int64) string { return fixed(ugnot, 6) }
