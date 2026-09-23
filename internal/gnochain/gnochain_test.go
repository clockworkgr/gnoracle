package gnochain

import "testing"

func TestCommitmentMatchesTally(t *testing.T) {
	// vectors produced by tally.Commitment on gno v1.2.0
	got := Commitment(1, 1, "UPHOLD", "s", "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	if got != "6188d967b2bbecabcc9601bf848b8490d14a5cd96ce8da01c5636e8e5740e2c9" {
		t.Fatalf("vector 1: %s", got)
	}
	got = Commitment(42, 2, "OVERTURN_MINOR", "salt-with-ünïcode", "g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434")
	if got != "70f28bcc80fb86bfc210a39aeed7808238a4fc37bae4a7656394dec25911e219" {
		t.Fatalf("vector 2: %s", got)
	}
}

func TestSchedule(t *testing.T) {
	s := Schedule{StartAt: 1000, Interval: 60, SubmitWindow: 20}
	if _, ok := s.Current(999); ok {
		t.Fatal("before start")
	}
	if id, _ := s.Current(1000); id != 0 {
		t.Fatal("round 0 at start")
	}
	if id, _ := s.Current(1179); id != 2 {
		t.Fatalf("round at 1179: %d", id)
	}
	if s.OpenAt(3) != 1180 || s.CloseAt(3) != 1200 {
		t.Fatal("open/close")
	}
	if !s.IsOpen(3, 1180) || s.IsOpen(3, 1200) || !s.IsClosed(3, 1200) {
		t.Fatal("open/closed flags")
	}
	if s.Next(4, true) != 5 || s.Next(0, false) != 0 {
		t.Fatal("next")
	}
	o := Schedule{StartAt: 5000, SubmitWindow: 600}
	if !o.IsOneOff() || o.OpenAt(0) != 5000 || o.CloseAt(0) != 5600 {
		t.Fatal("one-off")
	}
	if id, ok := o.Current(9999); !ok || id != 0 {
		t.Fatal("one-off current")
	}
	if o.Next(0, true) != 1 {
		t.Fatal("one-off next after finalise")
	}
}

func TestDecodeResults(t *testing.T) {
	rs := DecodeResults("(5 int64)\n(\"gno.land/r/x\" string)\n(true bool)\n(\"g1abc\" .uverse.address)\n")
	want := []string{"5", "gno.land/r/x", "true", "g1abc"}
	if len(rs) != len(want) {
		t.Fatalf("got %v", rs)
	}
	for i := range want {
		if rs[i] != want[i] {
			t.Fatalf("%d: got %q want %q", i, rs[i], want[i])
		}
	}
	if v, ok := Int64Result("(-7 int64)"); !ok || v != -7 {
		t.Fatal("int64 result")
	}
	if DecodeResult("plain") != "plain" {
		t.Fatal("plain")
	}
}

func TestGasPrice(t *testing.T) {
	p, d, err := parseGasPrice("0.001ugnot")
	if err != nil || p != 0.001 || d != "ugnot" {
		t.Fatalf("%v %v %v", p, d, err)
	}
	if _, _, err := parseGasPrice("ugnot"); err == nil {
		t.Fatal("expected error")
	}
	c := &Client{price: 0.001, denom: "ugnot"}
	if c.fee(15_000_001) != "15001ugnot" {
		t.Fatalf("fee %s", c.fee(15_000_001))
	}
}

func TestLivePhase(t *testing.T) {
	b := &BallotInfo{Phase: "commit", CommitEnds: 100, RevealEnds: 200}
	if b.LivePhase(50) != "commit" || b.LivePhase(150) != "reveal" || b.LivePhase(250) != "finished" {
		t.Fatal("phases")
	}
	b.ResolvedAt = 260
	if b.LivePhase(300) != "resolved" {
		t.Fatal("resolved")
	}
}

func TestEventString(t *testing.T) {
	e := Event{Type: "DisputeOpened", Attrs: map[string]string{"dispute": "3", "feed": "1"}, Order: []string{"dispute", "feed"}}
	if e.String() != "DisputeOpened dispute=3 feed=1" {
		t.Fatal(e.String())
	}
}
