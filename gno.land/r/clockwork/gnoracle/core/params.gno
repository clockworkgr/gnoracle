package core

import (
	"chain/runtime"
	"strconv"

	"gno.land/p/clockwork/gnoracle/params/v0"
)

// registry holds the DAO-tunable numbers of the core (plan Appendix C).
// Amounts are ugnot, durations seconds, rates basis points.
var registry = params.New()

// devChain is true on a development chain (chain id "dev": gnodev and the
// test harness), where waiting a day for a window is not an option. It
// relaxes only the floor of appealWindow; the defaults, and every bound on
// any other chain, are what the plan says.
var devChain = runtime.ChainID() == "dev"

func devFloor(prod, dev int64) int64 {
	if devChain {
		return dev
	}
	return prod
}

func defineParams() {
	r := registry
	def := func(name, doc string, v, lo, hi, change int64) {
		r.Define(params.Def{Name: name, Doc: doc, Default: v, Min: lo, Max: hi, MaxChangeBps: change})
	}
	gnot := int64(1_000_000)
	// feeds
	def("feedDeposit", "deposit attached to a feed proposal, refunded unless spam", 5*gnot, 1*gnot, 1000*gnot, 5000)
	def("providerMinStakeFloor", "smallest providerMinStake a spec may set", 10_000*gnot, 1_000*gnot, 1_000_000*gnot, 5000)
	def("subscriptionFloor", "smallest subscriptionPrice per period", 100*gnot, 10*gnot, 100_000*gnot, 5000)
	def("subscriberFloor", "smallest subscriberPrice per period a non-sponsored recurring spec may set", 2000, 0, 100_000*gnot, 5000)
	def("bountyFloor", "smallest one-off bounty", 50*gnot, 1*gnot, 100_000*gnot, 5000)
	def("subscriptionPeriod", "length of one subscription period", 30*24*3600, 7*24*3600, 90*24*3600, 5000)
	def("maxCatchUpRounds", "stale rounds written off per CatchUp call", 48, 1, 500, 5000)
	def("roundRetention", "seconds after finality before a round may be pruned", 30*24*3600, 7*24*3600, 365*24*3600, 5000)
	def("minRoundsKept", "rounds always kept per feed regardless of age", 64, 8, 10_000, 5000)
	def("retentionAfterDeprecate", "seconds after deprecation before a feed may be pruned", 90*24*3600, 30*24*3600, 730*24*3600, 5000)
	def("deadFeedRounds", "consecutive empty rounds after which a recurring feed is deprecated at finalisation", 168, 24, 10_000, 5000)
	def("maxIncentivePay", "largest fee-pool payment a release may make per call (tips, bounties)", 10*gnot, 0, 1000*gnot, 5000)
	def("trustedOneOffCap", "largest declared value at stake a trusted requester may self-activate", 50_000*gnot, 0, 10_000_000*gnot, 5000)
	// providers
	def("missSlashBps", "slash per missed round on a funded feed", 50, 0, 500, 5000)
	def("missSlashCapPerEpochBps", "largest total miss slash per provider per providerEpoch", 500, 0, 10_000, 5000)
	def("providerEpoch", "window of the miss slash cap and the minor-slash escalation", 7*24*3600, 24*3600, 90*24*3600, 5000)
	def("alerterShareBps", "share of a miss slash paid to whoever recorded it", 5000, 0, 10_000, 5000)
	def("jailAfterMisses", "consecutive misses that jail a provider", 3, 1, 20, 5000)
	def("jailCooldown", "seconds before a jailed provider may unjail", 24*3600, 3600, 30*24*3600, 5000)
	def("maxJailings", "jailings within 30 days that force unbonding", 3, 1, 20, 5000)
	def("strikesToJail", "out-of-tolerance submissions within strikeWindowRounds that jail", 5, 1, 100, 5000)
	def("strikeWindowRounds", "rounds over which strikes are counted", 100, 10, 10_000, 5000)
	def("minorSlashBps", "slash at the minor tier after a lost dispute", 500, 100, 2000, 5000)
	def("majorSlashBps", "slash at the major tier after a lost dispute (ejects)", 10_000, 5000, 10_000, 5000)
	def("minorsToMajor", "minor slashes within a providerEpoch that escalate to major", 3, 2, 10, 5000)
	def("unbondPeriod", "seconds between RequestUnbond and Withdraw", 14*24*3600, 7*24*3600, 60*24*3600, 5000)
	def("crankTipBps", "share of a round pool paid to whoever finalises it", 100, 0, 1000, 5000)
	// fees
	// the rest goes to the DAO, which gives stakers its stakerFeeShareBps of it
	def("feeSplitProvidersBps", "share of subscription payments (feed funding and realm subscriptions) to the feed pool", 7000, 0, 10_000, 5000)
	// disputes
	def("minDisputeBond", "smallest dispute bond", 2500*gnot, 100*gnot, 100_000*gnot, 5000)
	def("disputeBondBps", "dispute bond as a share of the feed's active stake", 1000, 100, 10_000, 5000)
	def("disputeEscalationWindow", "seconds within which repeat disputes on a feed double the bond", 7*24*3600, 24*3600, 90*24*3600, 5000)
	def("appealWindow", "seconds after a decided round in which an appeal may be posted", 24*3600, devFloor(3600, 10), 7*24*3600, 5000)
	def("appealBondMultiple", "appeal bond as a multiple of the dispute bond", 2, 1, 10, 5000)
	def("appealConsumeBps", "share of a losing appeal bond consumed", 2500, 0, 10_000, 5000)
	def("voidConsumeBps", "share of the bond consumed on a void outcome", 500, 0, 2000, 5000)
	def("forfeitSplitWinnerBps", "share of forfeitures to the prevailing party", 5000, 0, 10_000, 5000)
	def("forfeitSplitVotersBps", "share of forfeitures to coherent voters", 3000, 0, 10_000, 5000)
	r.DefineString("kourtRealm", "package path of the Kourt adapter realm", "")
}

// Param returns an integer parameter. Public: implementations and other
// realms read parameters without a gate.
func Param(name string) int64 { return registry.Int(name) }

// ParamStr returns a string parameter.
func ParamStr(name string) string { return registry.Str(name) }

// CheckParam reports the error SetParam would give for name=value (unknown
// name, a string parameter, out of bounds, more than its change limit)
// without changing anything, so a proposal can be refused when it is made
// rather than when it executes. The once-per-height limit is not checked:
// it depends on the height of execution.
func CheckParam(name string, value int64) error { return registry.Check(name, value) }

// CheckParamStr reports the error SetParamStr would give, without changing
// anything.
func CheckParamStr(name, value string) error { return registry.CheckString(name, value) }

// ParamsJSON renders every parameter.
func ParamsJSON() string { return registry.JSON() }

// SetParamStr changes a string parameter. Authority only.
func SetParamStr(cur realm, name, value string) {
	proxy.AssertAuthorized(0, cur)
	old, err := registry.SetString(name, value)
	if err != nil {
		panic(err.Error())
	}
	emit("ParamChanged", "name", name, "old", old, "new", value)
}

// DefineParam lets a release add a governed integer parameter with bounds
// (plan §3.2); an existing name is left as it is.
func (r *StateRef) DefineParam(name, doc string, def, lo, hi, changeBps int64) {
	r.check()
	if registry.Has(name) {
		return
	}
	registry.Define(params.Def{Name: name, Doc: doc, Default: def, Min: lo, Max: hi, MaxChangeBps: changeBps})
	emit("ParamDefined", "name", name, "default", strconv.FormatInt(def, 10))
}

// DefineParamStr lets a release add a governed text parameter.
func (r *StateRef) DefineParamStr(name, doc, def string) {
	r.check()
	if registry.Has(name) {
		return
	}
	registry.DefineString(name, doc, def)
	emit("ParamDefined", "name", name, "default", def)
}
