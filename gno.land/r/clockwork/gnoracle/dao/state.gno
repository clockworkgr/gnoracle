package dao

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/clockwork/gnoracle/checkpoint/v0"
	"gno.land/p/clockwork/gnoracle/ledger/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
)

// Proposal and ballot status values.
const (
	ProposalActive   = "active"
	ProposalPassed   = "passed"
	ProposalRejected = "rejected"
	ProposalExecuted = "executed"
	ProposalFailed   = "failed"
	ProposalExpired  = "expired"
	ProposalCanceled = "canceled"

	ChoiceYes     = "YES"
	ChoiceNo      = "NO"
	ChoiceAbstain = "ABSTAIN"

	BallotCommit   = "commit"
	BallotReveal   = "reveal"
	BallotResolved = "resolved"
)

// Member is one staker.
type Member struct {
	Addr            address
	Staked          int64
	UnbondAmount    int64
	UnbondReadyAt   int64
	Cursor          uint64 // resolved dispute ballots processed so far
	PendingUgnot    int64  // dispute rewards in ugnot, unclaimed
	PendingPyth     int64  // dispute rewards in PYTH, unclaimed
	VestedUntil     int64
	VestFloor       int64 // stake that may not be withdrawn before VestedUntil
	PenaltyWindowAt int64
	PenaltyInWindow int64
	TotalPenalised  int64
	TotalRewarded   int64
	JoinedAt        int64
	fee             ledger.Position
}

// Proposal is one governance question.
type Proposal struct {
	ID           uint64
	Kind         string
	Payload      string
	Title        string
	Proposer     address
	CreatedAt    int64
	SealedEpoch  uint32
	VotingEnds   int64
	Timelock     int64
	Executable   int64 // VotingEnds + Timelock
	Expires      int64
	QuorumBps    int64
	ThresholdBps int64
	Status       string
	Yes          int64
	No           int64
	Abstain      int64
	Voters       int64
	Deposit      int64
	Reason       string
}

// Ballot is one dispute vote (the disputes release fills it).
type Ballot struct {
	Dispute        uint64
	Round          int64
	MajorRequested bool
	Summary        string
	SealedEpoch    uint32
	Obligated      int64
	Phase          string
	CommitEnds     int64
	RevealEnds     int64
	Uphold         int64
	Overturn       int64
	OverturnMinor  int64
	Void           int64
	Abstain        int64
	Revealed       int64
	Outcome        string
	Tier           string
	CoherentWeight int64
	ExpectedPool   int64
	BondShareUgnot int64
	ClippedAway    int64
	ResolvedAt     int64
	TopReveals     string // packed heaviest reveals for clipping (impl-defined encoding)
}

// ------------------------------------------------------------- tables ----

var (
	members   = bptree.NewBPTree32() // addr -> *Member
	proposals = bptree.NewBPTree32() // idKey -> *Proposal
	votes     = bptree.NewBPTree32() // idKey+addr -> choice string
	ballots   = bptree.NewBPTree32() // seqKey -> *Ballot (resolved ballots keep their index for settle cursors)
	commits   = bptree.NewBPTree32() // seqKey+addr -> commitment
	reveals   = bptree.NewBPTree32() // seqKey+addr -> "choice|weight"
	byDispute = bptree.NewBPTree32() // disputeKey -> ballot seq
	mints     = bptree.NewBPTree32() // yearKey -> minted int64

	power     = checkpoint.NewBook() // staked PYTH by member, checkpointed by epoch
	fees      ledger.Accumulator     // ugnot fee share over staked PYTH
	propSeq   seqid.ID
	ballotSeq seqid.ID

	held holdings
)

// holdings tracks what the realm's balances are made of.
type holdings struct {
	StakedPyth    int64 // in members' Staked
	UnbondingPyth int64
	RewardPyth    int64 // dispute rewards owed in PYTH
	FeeUgnot      int64 // accumulator pool owed to stakers (carry + credited)
	RewardUgnot   int64 // dispute rewards owed in ugnot
	DepositUgnot  int64 // proposal deposits held
	KnownUgnot    int64 // balance already attributed (fees synced)
}

func u64key(v uint64) string {
	return string([]byte{
		byte(v >> 56), byte(v >> 48), byte(v >> 40), byte(v >> 32),
		byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v),
	})
}

// Now is block time in seconds.
func Now() int64 { return time.Now().Unix() }

// Epoch is the current voting-weight epoch (height / epochBlocks).
func Epoch() uint32 { return uint32(runtime.ChainHeight()/Param("epochBlocks")) + 1 }

func originSend() int64 { return unsafe.OriginSend().AmountOf(FeeDenom) }

// ----------------------------------------------------------- read views ----

// GetMember returns a member record or nil.
func GetMember(addr address) *Member {
	v := members.Get(string(addr))
	if v == nil {
		return nil
	}
	return v.(*Member)
}

// GetProposal returns a proposal or nil.
func GetProposal(id uint64) *Proposal {
	v := proposals.Get(u64key(id))
	if v == nil {
		return nil
	}
	return v.(*Proposal)
}

// VoteOf returns a member's choice on a proposal, "" when none.
func VoteOf(id uint64, addr address) string {
	v := votes.Get(u64key(id) + string(addr))
	if v == nil {
		return ""
	}
	return v.(string)
}

// GetBallot returns a dispute ballot by sequence, or nil.
func GetBallot(seq uint64) *Ballot {
	v := ballots.Get(u64key(seq))
	if v == nil {
		return nil
	}
	return v.(*Ballot)
}

// BallotOf returns the ballot sequence for a dispute (0 when none).
func BallotOf(disputeID uint64) uint64 {
	v := byDispute.Get(u64key(disputeID))
	if v == nil {
		return 0
	}
	return v.(uint64)
}

// CommitOf returns a member's commitment on a ballot.
func CommitOf(seq uint64, addr address) string {
	v := commits.Get(u64key(seq) + string(addr))
	if v == nil {
		return ""
	}
	return v.(string)
}

// RevealOf returns a member's revealed "choice|weight" on a ballot.
func RevealOf(seq uint64, addr address) string {
	v := reveals.Get(u64key(seq) + string(addr))
	if v == nil {
		return ""
	}
	return v.(string)
}

// PowerAt is a member's staked weight as of an epoch.
func PowerAt(addr address, epoch uint32) int64 { return power.ValueAt(string(addr), epoch) }

// TotalPowerAt is the staked total as of an epoch.
func TotalPowerAt(epoch uint32) int64 { return power.TotalAt(epoch) }

// TotalStaked is the current staked total.
func TotalStaked() int64 { return power.Total() }

// MemberCount is the number of member records.
func MemberCount() int { return members.Size() }

// ProposalCount is the number of proposals ever opened.
func ProposalCount() uint64 { return uint64(propSeq) }

// BallotCount is the number of dispute ballots ever opened.
func BallotCount() uint64 { return uint64(ballotSeq) }

// MintedInYear returns what was minted in a 365-day bucket since genesis.
func MintedInYear(year int64) int64 {
	v := mints.Get(u64key(uint64(year)))
	if v == nil {
		return 0
	}
	return v.(int64)
}

// FeesOwed is what a member could claim from the fee accumulator now.
func FeesOwed(addr address) int64 {
	m := GetMember(addr)
	if m == nil {
		return 0
	}
	return fees.Owed(&m.fee)
}

// Held returns the holdings categories.
func Held() (stakedPyth, unbondingPyth, rewardPyth, feeUgnot, rewardUgnot, depositUgnot, knownUgnot int64) {
	return held.StakedPyth, held.UnbondingPyth, held.RewardPyth, held.FeeUgnot, held.RewardUgnot, held.DepositUgnot, held.KnownUgnot
}

// IterateProposals calls fn for count proposals from offset, newest first.
func IterateProposals(offset, count int, fn func(*Proposal) bool) {
	proposals.ReverseIterateByOffset(offset, count, func(_ string, v any) bool { return fn(v.(*Proposal)) })
}

// IterateMembers calls fn for count members from offset.
func IterateMembers(offset, count int, fn func(*Member) bool) {
	members.IterateByOffset(offset, count, func(_ string, v any) bool { return fn(v.(*Member)) })
}

// ------------------------------------------------------------- store ----

// StateRef is the gated write capability handed to the live implementation.
type StateRef struct{ rlm realm }

// Store hands out a StateRef to the live implementation or an extension.
func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("dao: realm value is not the caller's live cur")
	}
	if caller := rlm.PkgPath(); caller != selfPath && !proxy.IsExtension(caller) {
		panic("dao: state is reachable only through " + selfPath + " or a registered extension, not from " + caller)
	}
}

func (r *StateRef) check() { assertStateAccess(0, r.rlm) }

// Emit lets the implementation emit under this realm's path.
func (r *StateRef) Emit(typ string, attrs ...string) {
	r.check()
	emit(typ, attrs...)
}

// ---- members

func mustMember(addr address) *Member {
	m := GetMember(addr)
	if m == nil {
		panic("dao: not a member")
	}
	return m
}

// MemberStake records staked PYTH already pulled into the realm and
// checkpoints the new weight at the next epoch.
func (r *StateRef) MemberStake(addr address, amount int64) *Member {
	r.check()
	if amount <= 0 {
		panic("dao: amount must be positive")
	}
	m := GetMember(addr)
	if m == nil {
		m = &Member{Addr: addr, JoinedAt: Now(), PenaltyWindowAt: Now()}
		members.Set(string(addr), m)
	}
	r.pullPyth(addr, amount)
	fees.Deposit(&m.fee, amount)
	m.Staked += amount
	held.StakedPyth += amount
	power.Set(string(addr), Epoch()+1, m.Staked)
	emit("MemberStaked", "member", string(addr), "amount", strconv.FormatInt(amount, 10), "staked", strconv.FormatInt(m.Staked, 10))
	return m
}

// MemberUnstake moves amount from staked to unbonding.
func (r *StateRef) MemberUnstake(addr address, amount int64, readyAt int64) {
	r.check()
	m := mustMember(addr)
	if amount <= 0 || amount > m.Staked {
		panic("dao: amount exceeds the stake")
	}
	fees.Withdraw(&m.fee, amount)
	m.Staked -= amount
	m.UnbondAmount += amount
	m.UnbondReadyAt = readyAt
	held.StakedPyth -= amount
	held.UnbondingPyth += amount
	power.Set(string(addr), Epoch()+1, m.Staked)
	emit("MemberUnstakeRequested", "member", string(addr), "amount", strconv.FormatInt(amount, 10), "readyAt", strconv.FormatInt(readyAt, 10))
}

// MemberPayUnbonded sends the unbonding PYTH back to the member.
func (r *StateRef) MemberPayUnbonded(addr address) int64 {
	r.check()
	m := mustMember(addr)
	amount := m.UnbondAmount
	if amount == 0 {
		return 0
	}
	m.UnbondAmount = 0
	held.UnbondingPyth -= amount
	r.sendPyth(addr, amount)
	return amount
}

// MemberPenalise takes amount from stake first, then from unbonding, and
// credits it to the PYTH reward pool for coherent voters. Returns the amount
// actually taken.
func (r *StateRef) MemberPenalise(addr address, amount int64) int64 {
	r.check()
	m := mustMember(addr)
	if amount <= 0 {
		return 0
	}
	taken := int64(0)
	fromStake := amount
	if fromStake > m.Staked {
		fromStake = m.Staked
	}
	if fromStake > 0 {
		fees.Withdraw(&m.fee, fromStake)
		m.Staked -= fromStake
		held.StakedPyth -= fromStake
		taken += fromStake
	}
	rest := amount - fromStake
	if rest > 0 && m.UnbondAmount > 0 {
		if rest > m.UnbondAmount {
			rest = m.UnbondAmount
		}
		m.UnbondAmount -= rest
		held.UnbondingPyth -= rest
		taken += rest
	}
	held.RewardPyth += taken
	m.TotalPenalised += taken
	if taken > 0 {
		power.Set(string(addr), Epoch()+1, m.Staked)
	}
	return taken
}

// MemberCreditReward credits dispute rewards to a member.
func (r *StateRef) MemberCreditReward(addr address, pyth, ugnot int64) {
	r.check()
	m := mustMember(addr)
	if pyth > 0 {
		m.PendingPyth += pyth
		m.TotalRewarded += pyth
	}
	if ugnot > 0 {
		m.PendingUgnot += ugnot
	}
}

// MemberPayRewards pays a member's pending dispute rewards.
func (r *StateRef) MemberPayRewards(addr address) (pyth, ugnot int64) {
	r.check()
	m := mustMember(addr)
	pyth, ugnot = m.PendingPyth, m.PendingUgnot
	m.PendingPyth, m.PendingUgnot = 0, 0
	if pyth > 0 {
		if pyth > held.RewardPyth {
			panic("dao: reward pool short")
		}
		held.RewardPyth -= pyth
		r.sendPyth(addr, pyth)
	}
	if ugnot > 0 {
		held.RewardUgnot -= ugnot
		r.sendUgnot(addr, ugnot)
	}
	return pyth, ugnot
}

// MemberSetCursor records how many resolved ballots a member has processed.
func (r *StateRef) MemberSetCursor(addr address, cursor uint64) {
	r.check()
	mustMember(addr).Cursor = cursor
}

// MemberSetPenaltyWindow records the per-window penalty bookkeeping.
func (r *StateRef) MemberSetPenaltyWindow(addr address, at, inWindow int64) {
	r.check()
	m := mustMember(addr)
	m.PenaltyWindowAt = at
	m.PenaltyInWindow = inWindow
}

// MemberSetVesting records a founder's vesting terms.
func (r *StateRef) MemberSetVesting(addr address, until, floor int64) {
	r.check()
	m := mustMember(addr)
	m.VestedUntil = until
	m.VestFloor = floor
}

// MemberPayFees pays a member's fee share.
func (r *StateRef) MemberPayFees(addr address) int64 {
	r.check()
	m := mustMember(addr)
	amount := fees.Claim(&m.fee)
	if amount == 0 {
		return 0
	}
	held.FeeUgnot -= amount
	r.sendUgnot(addr, amount)
	return amount
}

// FeesSync attributes coins that arrived since the last sync: the stakers'
// share bumps the accumulator, the rest stays as treasury. Returns the
// amount attributed.
func (r *StateRef) FeesSync() int64 {
	r.check()
	bal := ugnotBalance()
	known := held.KnownUgnot
	if bal <= known {
		return 0
	}
	delta := bal - known
	toStakers := delta * Param("stakerFeeShareBps") / 10_000
	fees.Bump(toStakers)
	held.FeeUgnot += toStakers
	held.KnownUgnot = bal
	emit("FeesSynced", "amount", strconv.FormatInt(delta, 10), "stakers", strconv.FormatInt(toStakers, 10))
	return delta
}

// TreasuryUgnot is what the treasury may spend in ugnot.
func TreasuryUgnot() int64 {
	return held.KnownUgnot - held.FeeUgnot - held.RewardUgnot - held.DepositUgnot
}

// TreasuryPyth is what the treasury may spend in PYTH.
func TreasuryPyth() int64 {
	return pythBalance() - held.StakedPyth - held.UnbondingPyth - held.RewardPyth
}

// ---- proposals

// NewProposal creates a proposal record.
func (r *StateRef) NewProposal(kind, payload, title string, proposer address, sealed uint32, votingEnds, timelock, expires, quorumBps, thresholdBps, deposit int64) *Proposal {
	r.check()
	id := uint64(propSeq.Next())
	p := &Proposal{ID: id, Kind: kind, Payload: payload, Title: title, Proposer: proposer, CreatedAt: Now(),
		SealedEpoch: sealed, VotingEnds: votingEnds, Timelock: timelock, Executable: votingEnds + timelock, Expires: expires,
		QuorumBps: quorumBps, ThresholdBps: thresholdBps, Status: ProposalActive, Deposit: deposit}
	proposals.Set(u64key(id), p)
	held.DepositUgnot += deposit
	emit("ProposalCreated", "id", strconv.FormatUint(id, 10), "kind", kind, "proposer", string(proposer))
	return p
}

func mustProposal(id uint64) *Proposal {
	p := GetProposal(id)
	if p == nil {
		panic("dao: unknown proposal")
	}
	return p
}

// ProposalVote records a vote and its weight.
func (r *StateRef) ProposalVote(id uint64, voter address, choice string, weight int64) {
	r.check()
	p := mustProposal(id)
	key := u64key(id) + string(voter)
	if votes.Has(key) {
		panic("dao: already voted")
	}
	votes.Set(key, choice)
	switch choice {
	case ChoiceYes:
		p.Yes += weight
	case ChoiceNo:
		p.No += weight
	case ChoiceAbstain:
		p.Abstain += weight
	default:
		panic("dao: unknown choice")
	}
	p.Voters++
	emit("ProposalVoted", "id", strconv.FormatUint(id, 10), "voter", string(voter), "choice", choice, "weight", strconv.FormatInt(weight, 10))
}

// ProposalSetStatus records an outcome.
func (r *StateRef) ProposalSetStatus(id uint64, status, reason string) {
	r.check()
	p := mustProposal(id)
	p.Status = status
	p.Reason = reason
	emit("ProposalStatus", "id", strconv.FormatUint(id, 10), "status", status)
}

// ProposalDepositRefund returns the proposer's deposit.
func (r *StateRef) ProposalDepositRefund(id uint64) {
	r.check()
	p := mustProposal(id)
	if p.Deposit == 0 {
		return
	}
	amount := p.Deposit
	p.Deposit = 0
	held.DepositUgnot -= amount
	r.sendUgnot(p.Proposer, amount)
}

// ProposalDepositForfeit keeps the deposit in the treasury.
func (r *StateRef) ProposalDepositForfeit(id uint64) {
	r.check()
	p := mustProposal(id)
	held.DepositUgnot -= p.Deposit
	p.Deposit = 0
}

// ---- treasury effects (declared here so an implementation cannot invent new outflows)

// TreasurySendUgnot pays from the treasury's ugnot.
func (r *StateRef) TreasurySendUgnot(to address, amount int64) {
	r.check()
	if amount <= 0 || amount > TreasuryUgnot() {
		panic("dao: treasury ugnot insufficient")
	}
	held.KnownUgnot -= amount
	r.sendUgnot(to, amount)
}

// TreasurySendPyth pays from the treasury's PYTH.
func (r *StateRef) TreasurySendPyth(to address, amount int64) {
	r.check()
	if amount <= 0 || amount > TreasuryPyth() {
		panic("dao: treasury PYTH insufficient")
	}
	r.sendPyth(to, amount)
}

// RecordMint records a mint in its year bucket and mints through the token.
func (r *StateRef) Mint(to address, amount int64, year int64) {
	r.check()
	if amount <= 0 {
		panic("dao: amount must be positive")
	}
	mints.Set(u64key(uint64(year)), MintedInYear(year)+amount)
	r.mintPyth(to, amount)
}

// ---- dispute ballots (records only; the disputes release drives them)

// NewBallot opens a ballot record and returns its sequence.
func (r *StateRef) NewBallot(disputeID uint64, round int64, majorRequested bool, summary string, sealed uint32, obligated int64, commitEnds, revealEnds int64) uint64 {
	r.check()
	seq := uint64(ballotSeq.Next())
	b := &Ballot{Dispute: disputeID, Round: round, MajorRequested: majorRequested, Summary: summary, SealedEpoch: sealed,
		Obligated: obligated, Phase: BallotCommit, CommitEnds: commitEnds, RevealEnds: revealEnds}
	ballots.Set(u64key(seq), b)
	byDispute.Set(u64key(disputeID), seq)
	emit("DisputeBallotOpened", "dispute", strconv.FormatUint(disputeID, 10), "ballot", strconv.FormatUint(seq, 10), "round", strconv.FormatInt(round, 10))
	return seq
}

// BallotCommit records a commitment.
func (r *StateRef) BallotCommit(seq uint64, voter address, commitment string) {
	r.check()
	commits.Set(u64key(seq)+string(voter), commitment)
}

// BallotReveal records a reveal and adds its weight to the tally.
func (r *StateRef) BallotReveal(seq uint64, voter address, choice string, weight int64, top string) {
	r.check()
	b := GetBallot(seq)
	if b == nil {
		panic("dao: unknown ballot")
	}
	key := u64key(seq) + string(voter)
	if reveals.Has(key) {
		panic("dao: already revealed")
	}
	reveals.Set(key, choice+"|"+strconv.FormatInt(weight, 10))
	switch choice {
	case "UPHOLD":
		b.Uphold += weight
	case "OVERTURN":
		b.Overturn += weight
	case "OVERTURN_MINOR":
		b.OverturnMinor += weight
	case "VOID":
		b.Void += weight
	case "ABSTAIN":
		b.Abstain += weight
	default:
		panic("dao: unknown choice")
	}
	b.Revealed += weight
	b.TopReveals = top
}

// BallotSetPhase changes a ballot's phase and deadlines.
func (r *StateRef) BallotSetPhase(seq uint64, phase string, commitEnds, revealEnds int64) {
	r.check()
	b := GetBallot(seq)
	if b == nil {
		panic("dao: unknown ballot")
	}
	b.Phase = phase
	b.CommitEnds = commitEnds
	b.RevealEnds = revealEnds
}

// BallotResolve records the decided tally.
func (r *StateRef) BallotResolve(seq uint64, outcome, tier string, uphold, overturn, minor, void, abstain, coherent, expectedPool, clipped, bondShare int64) {
	r.check()
	b := GetBallot(seq)
	if b == nil {
		panic("dao: unknown ballot")
	}
	b.Phase = BallotResolved
	b.Outcome = outcome
	b.Tier = tier
	b.Uphold, b.Overturn, b.OverturnMinor, b.Void, b.Abstain = uphold, overturn, minor, void, abstain
	b.CoherentWeight = coherent
	b.ExpectedPool = expectedPool
	b.ClippedAway = clipped
	b.BondShareUgnot = bondShare
	b.ResolvedAt = Now()
	held.RewardUgnot += bondShare
}

// ---- helpers

func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }
