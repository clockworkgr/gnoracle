package core

import (
	"chain"
	"chain/banker"
	"strconv"
)

// DAOPath is the governance realm. The DAO imports this realm to act on it,
// so this realm cannot import the DAO back; the DAO instead registers a
// BallotHouse at its init and every call from here to it goes through that
// value, the way the DAO reaches its own exec trampoline.
const DAOPath = "gno.land/r/clockwork/gnoracle/dao"

// BallotHouse is what the DAO provides to disputes: sealed ballots, their
// outcomes, appeal rounds, and a place to credit the voters' share of
// forfeitures. Methods are crossing (declared in the DAO realm), so the DAO
// sees this realm as the caller and gates on it.
type BallotHouse interface {
	OpenDisputeVote(cur realm, disputeID uint64, majorRequested bool, summary string) uint64
	FinishDisputeVote(cur realm, disputeID uint64) (outcome, tier string, coherentWeight int64)
	OpenAppealRound(cur realm, disputeID uint64) uint64
	FundVoters(cur realm, disputeID uint64, amount int64)
}

var house BallotHouse

// RegisterDAO is called by the DAO realm's init.
func RegisterDAO(cur realm, h BallotHouse) {
	if !cur.IsCurrent() || cur.Previous().PkgPath() != DAOPath {
		panic("core: only the DAO realm may register the ballot house")
	}
	house = h
	emit("DAORegistered", "path", DAOPath)
}

// HasDAO reports whether a ballot house is registered.
func HasDAO() bool { return house != nil }

func mustHouse() BallotHouse {
	if house == nil {
		panic("core: no DAO is registered; disputes need one")
	}
	return house
}

// OpenBallot asks the DAO to seal a ballot for a dispute.
func (r *StateRef) OpenBallot(disputeID uint64, majorRequested bool, summary string) uint64 {
	r.check()
	rlm := r.rlm
	return mustHouse().OpenDisputeVote(cross(rlm), disputeID, majorRequested, summary)
}

// FinishBallot asks the DAO for a ballot's outcome ("PENDING" while it runs).
func (r *StateRef) FinishBallot(disputeID uint64) (string, string, int64) {
	r.check()
	rlm := r.rlm
	return mustHouse().FinishDisputeVote(cross(rlm), disputeID)
}

// OpenAppeal asks the DAO to run a second ballot round for a dispute.
func (r *StateRef) OpenAppeal(disputeID uint64) uint64 {
	r.check()
	rlm := r.rlm
	return mustHouse().OpenAppealRound(cross(rlm), disputeID)
}

// FundVoters sends amount of a dispute's held bonds to the DAO for its
// coherent voters, taking it out of the Bonds category first.
func (r *StateRef) FundVoters(disputeID uint64, amount int64) {
	r.check()
	if amount < 0 {
		panic("core: amount must not be negative")
	}
	rlm := r.rlm
	if amount > 0 {
		if amount > held.Bonds {
			panic("core: bond accounting short")
		}
		if amount > Balance() {
			panic("core: insufficient realm balance")
		}
		held.Bonds -= amount
		b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
		b.SendCoins(rlm.Address(), chain.PackageAddress(DAOPath), chain.NewCoins(chain.NewCoin(StakeDenom, amount)))
	}
	// a zero amount still tells the DAO the outcome is applied (its ballot
	// becomes final and settlement may run)
	mustHouse().FundVoters(cross(rlm), disputeID, amount)
	emit("VotersFunded", "dispute", strconv.FormatUint(disputeID, 10), "amount", strconv.FormatInt(amount, 10))
}
