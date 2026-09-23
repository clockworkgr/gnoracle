// Package impl (v2) is the DAO's rehearsal release: v1 with a marker in
// Render, so a proposal that upgrades the DAO itself can be exercised end to
// end through the exec trampoline.
package impl

import (
	"gno.land/r/clockwork/gnoracle/dao"
	implv1 "gno.land/r/clockwork/gnoracle/dao/impl/v1"
)

type implV2 struct {
	dao.DAO
}

var instance = &implV2{DAO: implv1.Instance()}

// Instance returns the implementation object.
func Instance() dao.DAO { return instance }

// Render adds a release marker to every page.
func (v *implV2) Render(_ int, rlm realm, path string) string {
	return "<!-- release: dao/impl/v2 -->\n" + v.DAO.Render(0, rlm, path)
}

func init(cur realm) {
	dao.RegisterImpl(cross(cur), instance)
}
