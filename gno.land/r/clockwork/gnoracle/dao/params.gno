package dao

import (
	"chain/runtime"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/clockwork/gnoracle/params/v0"
)

// registry holds the DAO-tunable numbers of the DAO itself (plan §8, Appendix C).
// PYTH amounts are base units (6 decimals), durations seconds, rates basis
// points.
var registry = params.New()

// devChain is true on a development chain (chain id "dev": gnodev), where
// waiting a day for a ballot is not an option. It relaxes only the floors of
// the timing parameters below, which DevSetParam may then lower, and fixes a
// shorter epoch; the defaults, and every bound on any other chain, are what
// the plan says. The test harness runs package init under chain id "dev"
// (so tests see these dev bounds and the short epoch) but realm calls under
// an empty one, so DevSetParam refuses in tests.
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
	pyth := int64(1_000_000)
	gnot := int64(1_000_000)
	// membership
	// fixed on every chain: a change would renumber epochs (Epoch() could run
	// backwards) and break the checkpointed weights keyed by them
	def("epochBlocks", "blocks per voting-weight epoch (fixed; 10 on a development chain)", devFloor(720, 10), devFloor(720, 10), devFloor(720, 10), 0)
	def("unstakeCooldown", "seconds between RequestUnstake and Withdraw", 7*24*3600, 3*24*3600, 60*24*3600, 5000)
	def("settleMaxN", "resolved disputes processed per member per settle", 20, 1, 200, 5000)
	def("stakerFeeShareBps", "share of forwarded fees credited to stakers (rest to the treasury)", 5000, 0, 10_000, 5000)
	// penalties (dispute ballots)
	def("absenceSlashBps", "penalty per dispute a member did not reveal in", 50, 0, 1000, 5000)
	def("incoherenceSlashBps", "penalty per dispute a member voted against the outcome", 50, 0, 2000, 5000)
	def("abstainSlashBps", "penalty per dispute a member abstained in", 5, 0, 500, 5000)
	def("maxPenaltyPerWindowBps", "largest total penalty per member per penaltyWindow", 500, 0, 10_000, 5000)
	def("penaltyWindow", "window of the penalty cap", 30*24*3600, 7*24*3600, 365*24*3600, 5000)
	def("maxVoterShareBps", "largest share of obligated weight one address may hold", 2000, 1250, 3300, 5000)
	def("disputeQuorumBps", "round-1 quorum of obligated weight", 3300, 500, 10_000, 5000)
	def("decisionBps", "round-1 share of the two sides a side needs", 6000, 5001, 10_000, 5000)
	def("disputeQuorumBps2", "round-2 quorum", 2500, 500, 10_000, 5000)
	def("decisionBps2", "round-2 decision bar", 5500, 5001, 10_000, 5000)
	def("commitPeriod", "round-1 commit phase", 24*3600, devFloor(6*3600, 30), 14*24*3600, 5000)
	def("revealPeriod", "round-1 reveal phase", 24*3600, devFloor(6*3600, 30), 14*24*3600, 5000)
	def("commitPeriod2", "round-2 commit phase", 48*3600, devFloor(6*3600, 30), 14*24*3600, 5000)
	def("revealPeriod2", "round-2 reveal phase", 24*3600, devFloor(6*3600, 30), 14*24*3600, 5000)
	// governance
	def("proposeBps", "share of staked supply a proposer must hold to skip the deposit", 25, 0, 1000, 5000)
	def("proposalDeposit", "deposit for a proposer below proposeBps, refunded on quorum", 20*gnot, 0, 1000*gnot, 5000)
	def("maxActiveProposals", "live proposals at once", 32, 8, 128, 5000)
	def("executionWindow", "seconds after the timelock in which a passed proposal may execute", 7*24*3600, devFloor(24*3600, 60), 90*24*3600, 5000)
	def("minStake", "smallest stake that makes a member", 1*pyth, 1, 1_000_000*pyth, 5000)
	def("maxMintPerYearBps", "largest mint per 365 days as a share of supply", 200, 0, 1000, 5000)
	def("upgradeTimelock", "timelock of upgrade-accept proposals", 7*24*3600, devFloor(24*3600, 30), 30*24*3600, 5000)
}

// Param returns an integer parameter.
func Param(name string) int64 { return registry.Int(name) }

// ParamStr returns a string parameter.
func ParamStr(name string) string { return registry.Str(name) }

// CheckParam reports whether a `param` proposal could set name to value,
// without setting anything. value is what follows "=" in the payload: an
// integer for an integer parameter, or "str:<text>" for a text parameter.
// Bounds and the per-change rate limit are checked against the current
// value; the once-per-height rule is checked when the change is applied.
func CheckParam(name, value string) error {
	if !registry.Has(name) {
		return errors.New("dao: unknown parameter " + strconv.Quote(name))
	}
	if strings.HasPrefix(value, "str:") {
		if !isStrParam(name) {
			return errors.New("dao: " + name + " is an integer parameter")
		}
		if len(value)-4 > 256 {
			return errors.New("dao: " + name + " is at most 256 bytes")
		}
		return nil
	}
	if isStrParam(name) {
		return errors.New("dao: " + name + " is a text parameter (use str:<text>)")
	}
	v, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return errors.New("dao: " + name + " needs an integer value")
	}
	return registry.Check(name, v)
}

// isStrParam reports whether name is a text parameter.
func isStrParam(name string) (ok bool) {
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	registry.Str(name)
	return true
}

// ParamsJSON renders every parameter.
func ParamsJSON() string { return registry.JSON() }
