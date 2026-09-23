// Package impl (v2) is a rehearsal release: the v1 behaviour with a marker
// in Render, so accepting it, rolling it back and freezing can be exercised
// against real state without a second copy of the logic. It is the shape a
// hotfix release takes: embed the previous implementation, override what
// changed.
package impl

import (
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

func init(cur realm) {
	core.RegisterImpl(cross(cur), instance)
}
