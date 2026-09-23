package jsonw

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestObject(t *testing.T) {
	got := New().Str("a", "x\"y").Int("b", -5).Uint("c", 7).Bool("d", true).Null("e").
		Strs("f", []string{"p", "q"}).Ints("g", []int64{1, 2}).Raw("h", "{\"z\":1}").Raw("i", "").String()
	uassert.Equal(t, `{"a":"x\"y","b":-5,"c":7,"d":true,"e":null,"f":["p","q"],"g":[1,2],"h":{"z":1},"i":null}`, got)
}

func TestEmpty(t *testing.T) {
	uassert.Equal(t, "{}", New().String())
	uassert.Equal(t, "[]", NewArray().String())
	uassert.Equal(t, `{"error":"boom"}`, Error("boom"))
}

func TestQuote(t *testing.T) {
	uassert.Equal(t, `"tab\tnl\ncr\rq\"bs\\ctl\u0001é"`, Quote("tab\tnl\ncr\rq\"bs\\ctl\x01é"))
	uassert.Equal(t, `""`, Quote(""))
}

func TestArray(t *testing.T) {
	a := NewArray().Str("s").Int(-1).Uint(2).Raw("true")
	uassert.Equal(t, 4, a.Len())
	uassert.Equal(t, `["s",-1,2,true]`, a.String())
}
