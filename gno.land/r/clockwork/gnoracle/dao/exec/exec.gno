// Package exec is the DAO's self-upgrade trampoline. The upgradeable proxy
// authorizes callers by the realm that crossed into the permanent realm, and
// a realm cannot cross into itself, so a passed proposal that changes the
// DAO's own release goes out through this realm and straight back in: the
// DAO calls Run, Run calls the DAO's proxy entry points, and the proxy sees
// this realm as the caller. This realm does nothing unless the DAO realm
// itself is calling it.
package exec

import (
	"gno.land/r/clockwork/gnoracle/dao"
)

type trampoline struct{}

// Instance returns the trampoline object (for tests that stand in for init).
func Instance() dao.Trampoline { return trampoline{} }

// Run applies op ("accept", "rollback", "freeze", "authority") to the DAO's
// own proxy. Only the DAO realm may call it.
func (trampoline) Run(cur realm, op, path string) {
	if !cur.IsCurrent() || cur.Previous().PkgPath() != dao.SelfPath() {
		panic("exec: only the DAO realm may use the trampoline")
	}
	switch op {
	case "accept":
		dao.Accept(cross(cur), path)
	case "rollback":
		dao.Rollback(cross(cur))
	case "freeze":
		dao.Freeze(cross(cur))
	case "authority":
		dao.TransferAuthorityToExec(cross(cur))
	default:
		panic("exec: unknown op " + op)
	}
}

func init(cur realm) {
	dao.RegisterTrampoline(cross(cur), trampoline{})
}
