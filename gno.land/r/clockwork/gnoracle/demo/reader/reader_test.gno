// Package reader_test drives a feed to a value and has the example consumer
// realm read and record it.
package reader_test

import (
	"strconv"
	"strings"
	"testing"

	json "gno.land/p/onbloc/json/v0"

	"chain"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/clockwork/gnoracle/core"
	coreimpl "gno.land/r/clockwork/gnoracle/core/impl/v1"
	"gno.land/r/clockwork/gnoracle/dao"
	"gno.land/r/clockwork/gnoracle/dao/exec"
	daoimpl "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	"gno.land/r/clockwork/gnoracle/demo/reader"
)

const (
	corePath     = "gno.land/r/clockwork/gnoracle/core"
	coreImplPath = "gno.land/r/clockwork/gnoracle/core/impl/v1"
	daoPath      = "gno.land/r/clockwork/gnoracle/dao"
	daoImplPath  = "gno.land/r/clockwork/gnoracle/dao/impl/v1"
	execPath     = "gno.land/r/clockwork/gnoracle/dao/exec"
	gnot         = int64(1_000_000)
)

var (
	admin    = dao.Admin
	dave     = testutils.TestAddress("dave")
	erin     = testutils.TestAddress("erin")
	watcher  = testutils.TestAddress("watcher")
	coreAddr = chain.PackageAddress(corePath)
)

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }
func nosend()                   { testing.SetOriginSend(nil) }
func pay(to address, n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(to, coins(n))
}
func skip(seconds int64) { testing.SkipHeights(seconds / 5) }

func install(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(coreImplPath))
	core.RegisterImpl(cross(cur), coreimpl.Instance())
	testing.SetRealm(testing.NewCodeRealm(daoImplPath))
	dao.RegisterImpl(cross(cur), daoimpl.Instance())
	testing.SetRealm(testing.NewCodeRealm(execPath))
	dao.RegisterTrampoline(cross(cur), exec.Instance())
	testing.SetRealm(testing.NewCodeRealm(daoPath))
	core.RegisterDAO(cross(cur), dao.Hooks())
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.Accept(cross(cur), coreImplPath)
	dao.Accept(cross(cur), daoImplPath)
	for _, v := range []int64{5_000 * gnot, 2_500 * gnot, 1_250 * gnot, 1_000 * gnot} {
		core.SetParam(cross(cur), "providerMinStakeFloor", v)
		testing.SkipHeights(1)
	}
}

func TestReaderRecordsWhatItIsServed(cur realm, t *testing.T) {
	install(cur)
	spec := `{"name":"DEMO/USD","kind":"recurring","valueType":"numeric","decimals":6,"interval":600,"submitWindow":300,"sources":"x","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,"toleranceBps":100,"quarantineBps":2000,"disputeWindow":7200,"subscriberPrice":20000,"subscriptionPrice":100000000}`
	testing.SetRealm(testing.NewUserRealm(watcher))
	pay(coreAddr, 105*gnot)
	id := core.ProposeFeed(cross(cur), spec)
	testing.SetRealm(testing.NewUserRealm(admin))
	nosend()
	core.ActivateFeed(cross(cur), id)
	for _, p := range []address{dave, erin} {
		testing.SetRealm(testing.NewUserRealm(p))
		pay(coreAddr, 1_000*gnot)
		core.Register(cross(cur), id, "")
	}

	// until someone subscribes the realm, the core refuses its reads
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	uassert.Equal(t, 0, reader.Count())
	uassert.True(t, strings.Contains(reader.Render(""), "No readings yet"))
	uassert.AbortsContains(t, cur, "not subscribed", func() { reader.Poll(cross(cur), id) })

	// anyone pays a period for the realm; before any value the read is
	// served as "none"
	testing.SetRealm(testing.NewUserRealm(watcher))
	pay(coreAddr, 1*gnot)
	core.SubscribeRealm(cross(cur), id, reader.Path(), 1)
	uassert.True(t, core.IsSubscribed(id, reader.Path(), core.Now()))
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	v, rid, tier := reader.Poll(cross(cur), id)
	uassert.Equal(t, int64(0), v)
	uassert.Equal(t, uint64(0), rid)
	uassert.Equal(t, "none", tier)
	uassert.Equal(t, 1, reader.Count())

	// the providers submit round 0; the realm reads and stores the value
	f := core.GetFeed(id)
	skip(f.StartAt - core.Now() + 1)
	testing.SetRealm(testing.NewUserRealm(dave))
	nosend()
	core.Submit(cross(cur), id, 0, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(erin))
	nosend()
	core.Submit(cross(cur), id, 0, 1_001_000)
	testing.SetRealm(testing.NewUserRealm(watcher))
	nosend()
	v, rid, tier = reader.Poll(cross(cur), id)
	uassert.True(t, v >= 1_000_000 && v <= 1_001_000)
	uassert.Equal(t, uint64(0), rid)
	uassert.True(t, tier != "none")
	uassert.Equal(t, 2, reader.Count())
	last := reader.Last()
	uassert.Equal(t, v, last.Value)
	uassert.Equal(t, testing.GetContext().Height, last.Height)
	uassert.Equal(t, watcher, last.Caller)
	uassert.Equal(t, int64(1*gnot), core.GetSubscription(id, reader.Path()).Paid) // nothing per read

	// the page lists newest first with the height, the machine view agrees
	page := reader.Render("")
	uassert.True(t, strings.Contains(page, "| 2 | "+strconv.FormatInt(last.Height, 10)+" | "))
	uassert.True(t, strings.Contains(page, "DEMO/USD"))
	uassert.True(t, strings.Contains(page, "| 1.00"))
	uassert.True(t, strings.Contains(page, "| last reading | **1.00"))
	uassert.True(t, strings.Contains(page, "read at height "+strconv.FormatInt(last.Height, 10)))
	node, err := json.Unmarshal([]byte(reader.Render("json")))
	uassert.NoError(t, err)
	n, _ := node.MustKey("count").GetNumeric()
	uassert.Equal(t, float64(2), n)
	until, _ := node.MustKey("subscribedUntil").GetNumeric()
	uassert.True(t, until > 0)
	uassert.True(t, strings.Contains(page, "| subscription | feed "+strconv.FormatUint(id, 10)+": active until"))
	recs, _ := node.MustKey("readings").GetArray()
	h, _ := recs[0].MustKey("height").GetNumeric()
	uassert.Equal(t, float64(last.Height), h)

	// the page and the machine view list the newest 50 readings only; the
	// count is of every reading kept
	for i := 0; i < 55; i++ {
		testing.SetRealm(testing.NewUserRealm(watcher))
		nosend()
		reader.Poll(cross(cur), id)
	}
	uassert.Equal(t, 57, reader.Count())
	uassert.Equal(t, int64(57), reader.Last().Seq)
	page = reader.Render("")
	uassert.True(t, strings.Contains(page, "The newest 50 of 57 readings"))
	uassert.True(t, strings.Contains(page, "\n| 57 | "))
	uassert.True(t, strings.Contains(page, "\n| 8 | "))
	uassert.False(t, strings.Contains(page, "\n| 7 | "))
	node, _ = json.Unmarshal([]byte(reader.Render("json")))
	n, _ = node.MustKey("count").GetNumeric()
	uassert.Equal(t, float64(57), n)
	recs, _ = node.MustKey("readings").GetArray()
	uassert.Equal(t, 50, len(recs))
	s, _ := recs[0].MustKey("seq").GetNumeric()
	uassert.Equal(t, float64(57), s)
}
