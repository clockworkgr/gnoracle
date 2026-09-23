package authspec

import (
	"strings"
	"testing"
)

const dao = "gno.land/r/clockwork/gnoracle/dao"

func TestParse(t *testing.T) {
	a, err := Parse("addr:g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	if err != nil || !strings.HasPrefix(a.String(), "addr:") {
		t.Fatalf("%v %v", a, err)
	}
	r, err := Parse("realms:" + dao + ", gno.land/r/clockwork/gnoracle/dao/exec")
	if err != nil || !strings.HasPrefix(r.String(), "realms:") {
		t.Fatalf("%v %v", r, err)
	}
	both, err := Parse("anyof:g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5|" + dao)
	if err != nil || !strings.HasPrefix(both.String(), "anyOf") {
		t.Fatalf("%v %v", both, err)
	}
	for _, bad := range []string{"", "addr:", "addr:nope", "realms:", "realms:gno.land/p/x", "anyof:g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", "keys:x"} {
		if _, err := Parse(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	if Kind("realms:x") != "realms" || Kind("junk") != "" {
		t.Fatal("kind")
	}
	if !Grants("anyof:g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5|"+dao, dao) || Grants("addr:g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", dao) {
		t.Fatal("grants")
	}
	if got := Realms("realms:a,b"); got != nil {
		t.Fatalf("invalid paths must yield nil, got %v", got)
	}
}
