package params_test

import (
	"testing"

	"gno.land/p/clockwork/gnoracle/params/v0"
	"gno.land/p/nt/uassert/v0"
)

func registry() *params.Registry {
	r := params.New()
	r.Define(params.Def{Name: "missSlashBps", Doc: "slash per missed round", Default: 50, Min: 0, Max: 500, MaxChangeBps: 5000})
	r.Define(params.Def{Name: "disputeQuorumBps", Doc: "quorum", Default: 3300, Min: 500, Max: 10000, MaxChangeBps: 5000})
	r.Define(params.Def{Name: "maxProviders", Doc: "fixed", Default: 15, Min: 15, Max: 15})
	r.DefineString("stakeDenom", "denomination of stakes", "ugnot")
	return r
}

func TestDefineAndRead(cur realm, t *testing.T) {
	r := registry()
	uassert.Equal(t, int64(50), r.Int("missSlashBps"))
	uassert.Equal(t, "ugnot", r.Str("stakeDenom"))
	uassert.True(t, r.Has("maxProviders"))
	uassert.False(t, r.Has("nope"))
	uassert.Equal(t, 4, len(r.Names()))
	uassert.Equal(t, "missSlashBps", r.Names()[0])
	uassert.Equal(t, int64(500), r.Def("missSlashBps").Max)
	uassert.PanicsWithMessage(t, cur, "params: unknown parameter: nope", func() { r.Int("nope") })
	uassert.PanicsWithMessage(t, cur, "params: not an integer parameter: stakeDenom", func() { r.Int("stakeDenom") })
	uassert.PanicsWithMessage(t, cur, "params: already defined: maxProviders", func() {
		r.Define(params.Def{Name: "maxProviders", Default: 1, Min: 1, Max: 1})
	})
	uassert.PanicsWithMessage(t, cur, "params: default out of bounds: bad", func() {
		r.Define(params.Def{Name: "bad", Default: 5, Min: 1, Max: 2})
	})
}

func TestSetWithinBoundsAndRateLimit(t *testing.T) {
	r := registry()
	old, err := r.Set("missSlashBps", 75) // +50%: exactly the limit
	uassert.NoError(t, err)
	uassert.Equal(t, int64(50), old)
	uassert.Equal(t, int64(75), r.Int("missSlashBps"))

	_, err = r.Set("missSlashBps", 113) // +50.6%: over
	uassert.Error(t, err)
	uassert.Equal(t, int64(75), r.Int("missSlashBps"))

	_, err = r.Set("missSlashBps", 600) // out of bounds
	uassert.Error(t, err)
	_, err = r.Set("missSlashBps", 38) // -49%: fine
	uassert.NoError(t, err)
	_, err = r.Set("missSlashBps", 0) // to zero is more than 50% down: refused
	uassert.Error(t, err)
	_, err = r.Set("missSlashBps", 19)
	uassert.NoError(t, err)

	// a fixed parameter (min == max) can only be set to itself
	_, err = r.Set("maxProviders", 16)
	uassert.Error(t, err)
	_, err = r.Set("maxProviders", 15)
	uassert.NoError(t, err)

	// from zero any in-bounds value is allowed (no ratio to measure)
	z := params.New()
	z.Define(params.Def{Name: "x", Default: 0, Min: 0, Max: 1000, MaxChangeBps: 5000})
	_, err = z.Set("x", 900)
	uassert.NoError(t, err)

	// unknown and string parameters
	_, err = r.Set("nope", 1)
	uassert.Error(t, err)
	_, err = r.Set("stakeDenom", 1)
	uassert.Error(t, err)
	old2, err := r.SetString("stakeDenom", "gno.land/r/gnoland/wugnot.wugnot")
	uassert.NoError(t, err)
	uassert.Equal(t, "ugnot", old2)
	uassert.Equal(t, "gno.land/r/gnoland/wugnot.wugnot", r.Str("stakeDenom"))
}

func TestParseAssignmentAndRender(t *testing.T) {
	n, v, err := params.ParseAssignment("disputeQuorumBps = 2500")
	uassert.NoError(t, err)
	uassert.Equal(t, "disputeQuorumBps", n)
	uassert.Equal(t, int64(2500), v)
	_, _, err = params.ParseAssignment("nonsense")
	uassert.Error(t, err)
	_, _, err = params.ParseAssignment("a=b")
	uassert.Error(t, err)
	_, _, err = params.ParseAssignment("=5")
	uassert.Error(t, err)

	r := registry()
	md := r.Markdown()
	uassert.True(t, len(md) > 0)
	js := r.JSON()
	uassert.Equal(t, `{"missSlashBps":50,"disputeQuorumBps":3300,"maxProviders":15,"stakeDenom":"ugnot"}`, js)
}
