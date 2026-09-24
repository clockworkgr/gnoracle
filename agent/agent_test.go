package agent

import (
	"context"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

func rat(s string) *big.Rat { r, _ := new(big.Rat).SetString(s); return r }

func TestAggregateNumeric(t *testing.T) {
	samples := []Sample{{Num: rat("1.5")}, {Num: rat("1.2")}, {Err: "timeout"}, {Num: rat("9")}, {Num: rat("1.3")}}
	v, _, err := Aggregate(samples, true, 3)
	if err != nil || v.Cmp(rat("1.3")) != 0 {
		t.Fatalf("median %v %v", v, err)
	}
	if _, _, err := Aggregate(samples[:2], true, 3); err == nil {
		t.Fatal("expected too few sources")
	}
	// even count takes the lower middle, like agg.LowerMedian
	v, _, _ = Aggregate([]Sample{{Num: rat("1")}, {Num: rat("2")}, {Num: rat("3")}, {Num: rat("4")}}, true, 1)
	if v.Cmp(rat("2")) != 0 {
		t.Fatalf("lower median %v", v)
	}
}

func TestAggregateCategorical(t *testing.T) {
	_, l, err := Aggregate([]Sample{{Label: "YES"}, {Label: "NO"}, {Label: "YES"}}, false, 2)
	if err != nil || l != "YES" {
		t.Fatal(l, err)
	}
	if _, _, err := Aggregate([]Sample{{Label: "YES"}, {Label: "NO"}}, false, 1); err == nil {
		t.Fatal("tie must fail")
	}
}

func TestScaleToInt(t *testing.T) {
	cases := []struct {
		in   string
		dec  int
		want int64
	}{{"1.2345678", 6, 1234568}, {"1.2345675", 6, 1234568}, {"-1.2345675", 6, -1234568}, {"0.1", 0, 0}, {"0.5", 0, 1}, {"42", 2, 4200}}
	for _, c := range cases {
		got, err := ScaleToInt(rat(c.in), c.dec)
		if err != nil || got != c.want {
			t.Fatalf("%s@%d: got %d want %d (%v)", c.in, c.dec, got, c.want, err)
		}
	}
	if _, err := ScaleToInt(rat("1e30"), 6); err == nil {
		t.Fatal("overflow must fail")
	}
	if FormatScaled(1234568, 6) != "1.234568" || FormatScaled(-5, 2) != "-0.05" || FormatScaled(7, 0) != "7" {
		t.Fatal("format")
	}
}

func TestWithinBps(t *testing.T) {
	if !WithinBps(1020, 1000, 200) || WithinBps(1021, 1000, 200) || !WithinBps(0, 0, 100) || WithinBps(1, 0, 100) {
		t.Fatal("bps")
	}
}

func TestOptionIndex(t *testing.T) {
	opts := []string{"Home", "Draw", "Away"}
	if i, err := OptionIndex(opts, "draw", nil); err != nil || i != 1 {
		t.Fatal(i, err)
	}
	if i, err := OptionIndex(opts, "2", nil); err != nil || i != 2 {
		t.Fatal(i, err)
	}
	if i, err := OptionIndex(opts, "H", map[string]string{"H": "Home"}); err != nil || i != 0 {
		t.Fatal(i, err)
	}
	if _, err := OptionIndex(opts, "Tie", nil); err == nil {
		t.Fatal("unknown label")
	}
}

func TestExtractJSONPath(t *testing.T) {
	body := []byte(`{"data":{"amount":"12.34","list":[{"p":1.5},{"p":2}]},"ok":true,"n":null}`)
	for path, want := range map[string]string{"data.amount": "12.34", "data.list[1].p": "2", "data.list[0].p": "1.5", "ok": "true"} {
		got, err := ExtractJSONPath(body, path)
		if err != nil || got != want {
			t.Fatalf("%s: %q %v", path, got, err)
		}
	}
	if _, err := ExtractJSONPath(body, "data.nope"); err == nil {
		t.Fatal("missing key")
	}
	if _, err := ExtractJSONPath(body, "n"); err == nil {
		t.Fatal("null leaf")
	}
	if got, _ := ExtractJSONPath([]byte(`[{"x":7}]`), "[0].x"); got != "7" {
		t.Fatal(got)
	}
}

func TestHTTPAdapterMedian(t *testing.T) {
	mk := func(body string, code int) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(code)
			w.Write([]byte(body))
		}))
	}
	a := mk(`{"data":{"amount":"1.10"}}`, 200)
	b := mk(`{"data":{"amount":1.20}}`, 200)
	c := mk(`boom`, 500)
	defer a.Close()
	defer b.Close()
	defer c.Close()
	ad, err := NewAdapter(SourceConfig{Adapter: "http", URLs: []string{a.URL, b.URL, c.URL}, Path: "data.amount", MinSources: 2}, Deps{})
	if err != nil {
		t.Fatal(err)
	}
	samples := ad.Fetch(context.Background())
	if len(samples) != 3 || samples[2].Err == "" || samples[0].Num == nil {
		t.Fatalf("%+v", samples)
	}
	v, _, err := Aggregate(samples, true, ad.(*httpAdapter).MinSources())
	if err != nil || v.Cmp(rat("1.10")) != 0 {
		t.Fatalf("%v %v", v, err)
	}
	scaled, _ := ScaleToInt(v, 6)
	if scaled != 1_100_000 {
		t.Fatal(scaled)
	}
}

func TestExecAndFileAdapters(t *testing.T) {
	ex, _ := NewAdapter(SourceConfig{Adapter: "exec", Command: []string{"sh", "-c", "echo 3.25"}}, Deps{})
	s := ex.Fetch(context.Background())
	if len(s) != 1 || s[0].Err != "" || s[0].Num.Cmp(rat("3.25")) != 0 {
		t.Fatalf("%+v", s)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "answer.txt")
	fa, _ := NewAdapter(SourceConfig{Adapter: "file", File: path}, Deps{})
	if s := fa.Fetch(context.Background()); s[0].Err == "" {
		t.Fatal("missing file must be an error")
	}
	os.WriteFile(path, []byte(" Away \n"), 0o600)
	if s := fa.Fetch(context.Background()); s[0].Label != "Away" {
		t.Fatalf("%+v", s)
	}
}

func TestTickToPrice(t *testing.T) {
	// tick 0 is price 1 in raw units; with 6/6 decimals still 1
	if p := TickToPrice(0, 6, 6, false); p.Cmp(rat("1")) != 0 {
		t.Fatal(p)
	}
	// 10 vs 18 decimals shifts by 1e8 when going raw → human
	p := TickToPrice(0, 6, 18, false)
	if p.Cmp(rat("0.000000000001")) != 0 {
		t.Fatal(p.FloatString(15))
	}
	inv := TickToPrice(0, 6, 18, true)
	if inv.Cmp(rat("1000000000000")) != 0 {
		t.Fatal(inv.FloatString(3))
	}
	// 1.0001^6931 ≈ 2
	two := TickToPrice(6931, 6, 6, false)
	f, _ := two.Float64()
	if f < 1.999 || f > 2.001 {
		t.Fatal(f)
	}
}

func TestConfigValidate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.toml")
	os.WriteFile(path, []byte(`
remote = "http://127.0.0.1:26657"
chain_id = "dev"
core = "gno.land/r/clockwork/gnoracle/core"
key_home = ".dev-keys"
key = "prov2"
poll = "3s"
[gas]
mode = "estimate"
[[feeds]]
id = 1
jitter = "1s"
sanity_bps = 1500
[feeds.source]
adapter = "http"
urls = ["http://a", "http://b"]
path = "price"
[[feeds]]
id = 7
[feeds.source]
adapter = "file"
file = "answers/7.txt"
`), 0o600)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Feeds) != 2 || c.Feeds[0].SanityBps != 1500 || c.Gas.Wanted == 0 || c.Feeds[1].Source.File != "answers/7.txt" {
		t.Fatalf("%+v", c)
	}
	p, _ := c.Feeds[0].runtime()
	if p.jitter.Seconds() != 1 || !p.catchUpEmpty {
		t.Fatal(p)
	}
	os.WriteFile(path, []byte("remote='x'\nchain_id='dev'\ncore='c'\nkey='k'\n[[feeds]]\nid=1\n[feeds.source]\nadapter='nope'\n"), 0o600)
	if _, err := Load(path); err == nil {
		t.Fatal("unknown adapter must fail")
	}
}

func TestStateRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.json")
	s, _ := LoadState(path)
	fs := s.Feed(3)
	fs.HasRound, fs.LastRound, fs.LastValue = true, 9, 42
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	s2, err := LoadState(path)
	if err != nil || !s2.Feed(3).HasRound || s2.Feed(3).LastRound != 9 {
		t.Fatal(err)
	}
	j := NewJournal(filepath.Join(t.TempDir(), "j.jsonl"))
	v := int64(1)
	j.Write(Entry{Feed: 1, Kind: "submit", Value: &v})
	b, _ := os.ReadFile(j.path)
	if len(b) == 0 {
		t.Fatal("journal empty")
	}
}

func TestSanityRefLatest(t *testing.T) {
	v := func(x int64) *int64 { return &x }
	cases := []struct {
		name  string
		st    FeedState
		f     gnochain.FeedInfo
		want  int64
		wantK bool
	}{
		{"nothing", FeedState{}, gnochain.FeedInfo{}, 0, false},
		{"public only", FeedState{}, gnochain.FeedInfo{Value: v(100), LastRound: 4}, 100, true},
		{"own only", FeedState{HasValue: true, LastValue: 90, ValueRound: 3}, gnochain.FeedInfo{}, 90, true},
		{"own later", FeedState{HasValue: true, LastValue: 90, ValueRound: 9}, gnochain.FeedInfo{Value: v(100), LastRound: 8}, 90, true},
		{"public later", FeedState{HasValue: true, LastValue: 90, ValueRound: 3}, gnochain.FeedInfo{Value: v(100), LastRound: 8}, 100, true},
		{"same round", FeedState{HasValue: true, LastValue: 90, ValueRound: 8}, gnochain.FeedInfo{Value: v(100), LastRound: 8}, 100, true},
		{"own of unknown round", FeedState{HasValue: true, LastValue: 90}, gnochain.FeedInfo{Value: v(100), LastRound: 1}, 100, true},
	}
	for _, c := range cases {
		got, ok := sanityRef(c.st, &c.f)
		if got != c.want || ok != c.wantK {
			t.Errorf("%s: sanityRef = %d, %v; want %d, %v", c.name, got, ok, c.want, c.wantK)
		}
	}
}
