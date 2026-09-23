package bot

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

func TestConfigDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bot.toml")
	os.WriteFile(path, []byte(`
remote = "http://127.0.0.1:26657"
chain_id = "dev"
core = "gno.land/r/clockwork/gnoracle/core"
dao = "gno.land/r/clockwork/gnoracle/dao"
kourt = "gno.land/r/clockwork/gnoracle/kourt"
key_home = ".dev-keys"
key = "test1"
[telegram]
token = ""
chat = 0
[[members]]
addr = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
name = "test1"
settle = true
[crank]
finalize = true
resolve = true
kourt = true
settle = true
`), 0o600)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.Poll != "10s" || len(c.Remind.Hours) != 2 || len(c.Events) == 0 || c.MaxBlocks != 300 {
		t.Fatalf("%+v", c)
	}
	p, _ := c.params()
	if p.finalizeGrace != 120*time.Second || !p.catchUpEmpty || !p.events["DisputeOpened"] {
		t.Fatalf("%+v", p)
	}
	os.WriteFile(path, []byte("remote='x'\nchain_id='dev'\ncore='c'\ndao='d'\n[crank]\nfinalize=true\n"), 0o600)
	if _, err := Load(path); err == nil {
		t.Fatal("cranking without a key must fail")
	}
}

func TestStateOnceAndDue(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.json")
	s, _ := LoadState(path)
	if !s.once("a") || s.once("a") {
		t.Fatal("once")
	}
	if !s.due("f", time.Minute) || s.due("f", time.Minute) {
		t.Fatal("due")
	}
	s.Height = 77
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	s2, _ := LoadState(path)
	if s2.Height != 77 || s2.once("a") {
		t.Fatal("persisted")
	}
}

func TestWhenAndLink(t *testing.T) {
	if got := when(3600*25, 0); got != "1970-01-02 01:00 UTC (in 25h 00m)" {
		t.Fatal(got)
	}
	if got := when(3600*73, 0); got != "1970-01-04 01:00 UTC (in 3d 1h)" {
		t.Fatal(got)
	}
	if got := when(0, 90*60); got != "1970-01-01 00:00 UTC (1h 30m ago)" {
		t.Fatal(got)
	}
	b := &Bot{cfg: &Config{Gnoweb: "https://gno.land/", Core: "gno.land/r/x/core"}}
	if l := b.link(b.cfg.Core, "dispute/3"); l != "https://gno.land/r/x/core:dispute/3" {
		t.Fatal(l)
	}
	if gnot(1_500_000) != "1.5 GNOT" {
		t.Fatal(gnot(1_500_000))
	}
}

func TestFormatGenericEvent(t *testing.T) {
	cfg := &Config{Core: "c", DAO: "d"}
	b := &Bot{cfg: cfg, p: &params{events: map[string]bool{}}}
	ev := gnochain.Event{Type: "ParamChanged", PkgPath: "d", Attrs: map[string]string{"name": "x", "new": "2"}, Order: []string{"name", "new"}}
	if got := b.format(ev); got != "[dao] ParamChanged name=x new=2" {
		t.Fatal(got)
	}
	_ = context.Background()
}
