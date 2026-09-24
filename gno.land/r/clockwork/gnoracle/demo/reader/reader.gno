// Package reader is an example consumer realm for the local demo (`make
// demo`): anyone may ask it to read a Gnoracle feed, and it keeps every value
// it was served together with the block height and chain time of the read,
// which its page lists. It pays for each read from the credit an operator
// deposits for its address on the core (`DepositFor`), the way any consumer
// realm on gno.land would. It is not part of a deployment.
package reader

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/clockwork/gnoracle/jsonw/v0"
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

// maxKept bounds the stored history; older readings are dropped first.
const maxKept = 2000

var (
	selfPath string
	readings []Reading
	seq      int64
)

func init(cur realm) {
	selfPath = cur.PkgPath()
}

// Address is this realm's account: deposit read credit for it on the core
// with `DepositFor`.
func Address() address { return chain.PackageAddress(selfPath) }

// Poll reads feedID through the core's paid Read and stores the reading. Any
// account or realm may call it; the read is charged to this realm's credit.
func Poll(cur realm, feedID uint64) (value int64, round uint64, tier string) {
	v, dec, rid, _, t := core.Read(cross(cur), feedID)
	seq++
	readings = append(readings, Reading{
		Seq: seq, Height: runtime.ChainHeight(), Time: time.Now().Unix(), Feed: feedID,
		Round: rid, Value: v, Decimals: dec, Tier: t, Caller: cur.Previous().Address(),
	})
	if len(readings) > maxKept {
		readings = readings[len(readings)-maxKept:]
	}
	chain.Emit("ReaderPolled", "feed", strconv.FormatUint(feedID, 10), "round", strconv.FormatUint(rid, 10), "value", strconv.FormatInt(v, 10), "tier", t)
	return v, rid, t
}

// Count is the number of readings kept.
func Count() int { return len(readings) }

// Last returns the most recent reading, or a zero Reading.
func Last() Reading {
	if len(readings) == 0 {
		return Reading{}
	}
	return readings[len(readings)-1]
}

// Render lists the readings, newest first; `json` serves them as a machine
// view.
func Render(path string) string {
	if strings.HasPrefix(path, "json") {
		return renderJSON()
	}
	var b strings.Builder
	b.WriteString("# Example consumer realm\n\n")
	b.WriteString("This realm reads a Gnoracle feed when anyone calls `Poll(feedID)` and keeps what it was served. ")
	b.WriteString("Each read is paid from the credit deposited for its address on the core.\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| realm address | `" + string(Address()) + "` |\n")
	credit, spent, reads := int64(0), int64(0), int64(0)
	if c := core.GetCredit(Address()); c != nil {
		credit, spent, reads = c.Balance, c.Spent, c.Reads
	}
	b.WriteString("| read credit | " + gnot(credit) + " GNOT left, " + gnot(spent) + " GNOT spent over " + strconv.FormatInt(reads, 10) + " reads |\n")
	b.WriteString("| readings kept | " + strconv.Itoa(len(readings)) + " |\n\n")
	if len(readings) == 0 {
		b.WriteString("_No readings yet._\n")
		return b.String()
	}
	b.WriteString("| # | height | chain time | feed | round | value | tier |\n|---|---|---|---|---|---|---|\n")
	for i := len(readings) - 1; i >= 0; i-- {
		r := readings[i]
		name := strconv.FormatUint(r.Feed, 10)
		if f := core.GetFeed(r.Feed); f != nil && f.Spec != nil {
			name += " " + f.Spec.Name
		}
		b.WriteString("| " + strconv.FormatInt(r.Seq, 10) + " | " + strconv.FormatInt(r.Height, 10) + " | " + time.Unix(r.Time, 0).UTC().Format("2006-01-02 15:04:05") +
			" | " + name + " | " + strconv.FormatUint(r.Round, 10) + " | " + fixed(r.Value, r.Decimals) + " | " + r.Tier + " |\n")
	}
	return b.String()
}

func renderJSON() string {
	a := jsonw.NewArray()
	for i := len(readings) - 1; i >= 0; i-- {
		r := readings[i]
		a.Raw(jsonw.New().Int("seq", r.Seq).Int("height", r.Height).Int("time", r.Time).Uint("feed", r.Feed).Uint("round", r.Round).
			Int("value", r.Value).Int("decimals", r.Decimals).Str("tier", r.Tier).Str("caller", string(r.Caller)).String())
	}
	credit := int64(0)
	if c := core.GetCredit(Address()); c != nil {
		credit = c.Balance
	}
	return jsonw.New().Int("now", time.Now().Unix()).Int("height", runtime.ChainHeight()).Str("address", string(Address())).
		Int("credit", credit).Int("count", int64(len(readings))).Raw("readings", a.String()).String()
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
