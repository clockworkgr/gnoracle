// Package impl (v2) is a rehearsal release: the v1 behaviour with a marker
// in Render, so accepting it, rolling it back and freezing can be exercised
// against real state without a second copy of the logic. It is the shape a
// hotfix release takes: embed the previous implementation, override what
// changed.
package impl

import (
	"strconv"
	"strings"

	"gno.land/r/clockwork/gnoracle/core"
	implv1 "gno.land/r/clockwork/gnoracle/core/impl/v1"
)

type implV2 struct {
	core.Core
}

var instance = &implV2{Core: implv1.Instance()}

// Instance returns the implementation object.
func Instance() core.Core { return instance }

// Render adds a release marker to every page.
func (v *implV2) Render(_ int, rlm realm, path string) string {
	return "<!-- release: impl/v2 -->\n" + v.Core.Render(0, rlm, path)
}

// Invoke shows how a release adds operations without permanent changes:
//
//	echo <text>                 returns the text
//	note <id> <key> <value>     stores release data on object kind "v2"
//	define <name> <default>     adds a governed parameter (authority only)
//	tip <amount>                pays the caller an incentive from the fee pool (authority only)
func (v *implV2) Invoke(_ int, rlm realm, caller address, userCall bool, sent int64, method, args string) string {
	st := core.Store(0, rlm)
	f := strings.Fields(args)
	if (method == "define" || method == "tip") && !core.IsAuthority(caller) {
		panic("v2: " + method + " is reserved to the core authority")
	}
	switch method {
	case "echo":
		return args
	case "note":
		if len(f) < 2 {
			panic("v2: note <id> <key> [value]")
		}
		st.SetNote("v2", f[0], f[1], strings.Join(f[2:], " ")) // no value removes the note
		return core.Note("v2", f[0], f[1])
	case "define":
		if len(f) < 2 {
			panic("v2: define <name> <default>")
		}
		d, err := strconv.ParseInt(f[1], 10, 64)
		if err != nil {
			panic("v2: bad default")
		}
		st.DefineParam(f[0], "added by impl/v2", d, 0, d*10+1, 5000)
		return strconv.FormatInt(core.Param(f[0]), 10)
	case "tip":
		if len(f) < 1 {
			panic("v2: tip <amount>")
		}
		a, err := strconv.ParseInt(f[0], 10, 64)
		if err != nil {
			panic("v2: bad amount")
		}
		st.FeesPay(caller, a)
		return "paid"
	}
	return v.Core.Invoke(0, rlm, caller, userCall, sent, method, args)
}

func init(cur realm) {
	core.RegisterImpl(cross(cur), instance)
}
