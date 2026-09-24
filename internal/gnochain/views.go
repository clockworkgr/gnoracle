package gnochain

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// The structs below mirror the realms' `:json/...` views (core/impl/v1
// json.gno, dao/impl/v1 json.gno, and the kourt mirror's record view from
// kourt/impl/kourtv3, or kourt/impl/v1 on dev chains with the stand-in court).
// Unknown fields are ignored so a newer release may add members without
// breaking older tools.

// Head is on every core object.
type Head struct {
	Now    int64  `json:"now"`
	Height int64  `json:"height"`
	Live   string `json:"live"`
}

// FeedSpec is the accepted specification.
type FeedSpec struct {
	Name              string   `json:"name"`
	Description       string   `json:"description"`
	Kind              string   `json:"kind"`
	ValueType         string   `json:"valueType"`
	Decimals          int      `json:"decimals"`
	Options           []string `json:"options"`
	Interval          int64    `json:"interval"`
	SubmitWindow      int64    `json:"submitWindow"`
	ResolveAt         int64    `json:"resolveAt"`
	Bounty            int64    `json:"bounty"`
	Sources           string   `json:"sources"`
	MinProviders      int      `json:"minProviders"`
	MaxProviders      int      `json:"maxProviders"`
	ProviderMinStake  int64    `json:"providerMinStake"`
	ToleranceBps      int64    `json:"toleranceBps"`
	QuarantineBps     int64    `json:"quarantineBps"`
	DisputeWindow     int64    `json:"disputeWindow"`
	SubscriberPrice   int64    `json:"subscriberPrice"`
	SubscriptionPrice int64    `json:"subscriptionPrice"`
	Sponsored         bool     `json:"sponsored"`
	ValueAtStake      int64    `json:"valueAtStake"`
	Tags              []string `json:"tags"`
	Hash              string   `json:"hash"`
}

// IsNumeric reports a numeric value type.
func (s FeedSpec) IsNumeric() bool { return s.ValueType == "numeric" }

// FeedInfo is json/feed/<id>.
type FeedInfo struct {
	Head
	ID             uint64   `json:"id"`
	Proposer       string   `json:"proposer"`
	FromRealm      bool     `json:"fromRealm"`
	Status         string   `json:"status"`
	CreatedAt      int64    `json:"createdAt"`
	StartAt        int64    `json:"startAt"`
	Pool           int64    `json:"pool"`
	Drip           int64    `json:"drip"`
	PaidUntil      int64    `json:"paidUntil"`
	ActiveCount    int64    `json:"activeCount"`
	Slots          []string `json:"slots"`
	HaveLast       bool     `json:"haveLast"`
	LastFinalized  uint64   `json:"lastFinalized"`
	OldestRound    uint64   `json:"oldestRound"`
	EmptyStreak    int64    `json:"emptyStreak"`
	HaveValue      bool     `json:"haveValue"`
	LastRound      uint64   `json:"lastRound"`
	LastRoundAt    int64    `json:"lastRoundAt"`
	LastFinalAt    int64    `json:"lastFinalAt"`
	LastTier       string   `json:"lastTier"`
	Value          *int64   `json:"value"` // nil before the first value
	ServedTier     string   `json:"servedTier"`
	CurrentRound   *uint64  `json:"currentRound"`
	CurrentOpenAt  int64    `json:"currentOpenAt"`
	CurrentCloseAt int64    `json:"currentCloseAt"`
	Reopened       bool     `json:"reopened"`
	DeprecatedAt   int64    `json:"deprecatedAt"`
	OpenDisputes   int64    `json:"openDisputes"`
	RoundsFinal    int64    `json:"roundsFinal"`
	Spec           FeedSpec `json:"spec"`
}

// Schedule derives the round schedule.
func (f *FeedInfo) Schedule() Schedule {
	return Schedule{StartAt: f.StartAt, Interval: f.Spec.Interval, SubmitWindow: f.Spec.SubmitWindow}
}

// SlotOf returns the slot index an address holds, or -1.
func (f *FeedInfo) SlotOf(addr string) int {
	for i, s := range f.Slots {
		if s != "" && s == addr {
			return i
		}
	}
	return -1
}

// FeedSummary is an element of json/feeds.
type FeedSummary struct {
	ID            uint64 `json:"id"`
	Name          string `json:"name"`
	Kind          string `json:"kind"`
	ValueType     string `json:"valueType"`
	Status        string `json:"status"`
	StartAt       int64  `json:"startAt"`
	Interval      int64  `json:"interval"`
	SubmitWindow  int64  `json:"submitWindow"`
	Decimals      int    `json:"decimals"`
	ActiveCount   int64  `json:"activeCount"`
	MaxProviders  int    `json:"maxProviders"`
	HaveLast      bool   `json:"haveLast"`
	LastFinalized uint64 `json:"lastFinalized"`
	OpenDisputes  int64  `json:"openDisputes"`
}

// Schedule derives the round schedule.
func (f FeedSummary) Schedule() Schedule {
	return Schedule{StartAt: f.StartAt, Interval: f.Interval, SubmitWindow: f.SubmitWindow}
}

// FeedList is json/feeds.
type FeedList struct {
	Head
	Total uint64        `json:"total"`
	Feeds []FeedSummary `json:"feeds"`
}

// RoundSubmission is one slot's entry in a round.
type RoundSubmission struct {
	Slot     int    `json:"slot"`
	Addr     string `json:"addr"`
	Value    int64  `json:"value"`
	Eligible bool   `json:"eligible"`
}

// RoundInfo is json/feed/<id>/round/<r>.
type RoundInfo struct {
	Head
	Feed          uint64            `json:"feed"`
	ID            uint64            `json:"id"`
	Status        string            `json:"status"` // none | open | aggregated | empty | skipped | void
	Exists        bool              `json:"exists"`
	OpensAt       int64             `json:"opensAt"`
	ClosesAt      int64             `json:"closesAt"`
	Open          bool              `json:"open"`
	Closed        bool              `json:"closed"`
	OpenedAt      int64             `json:"openedAt"`
	FinalisedAt   int64             `json:"finalisedAt"`
	Tier          string            `json:"tier"`
	Pool          int64             `json:"pool"`
	DisputeID     uint64            `json:"disputeID"`
	Overturned    bool              `json:"overturned"`
	SubmittedMask int64             `json:"submittedMask"`
	Submitted     []RoundSubmission `json:"submitted"`
	Value         *int64            `json:"value"` // nil while the round is open
	Values        []RoundSubmission `json:"values"`
	Started       *bool             `json:"started"` // round/current before StartAt
}

// HasSubmitted reports whether slot has a submission in the round.
func (r *RoundInfo) HasSubmitted(slot int) bool {
	return slot >= 0 && r.SubmittedMask&(1<<uint(slot)) != 0
}

// ProviderInfo is json/feed/<id>/provider/<addr>.
type ProviderInfo struct {
	Head
	Feed              uint64 `json:"feed"`
	Addr              string `json:"addr"`
	Stake             int64  `json:"stake"`
	Status            string `json:"status"` // active | jailed | unbonding | withdrawn
	Slot              int64  `json:"slot"`
	Memo              string `json:"memo"`
	JoinedAt          int64  `json:"joinedAt"`
	ObligedFrom       uint64 `json:"obligedFrom"`
	ConsecutiveMisses int64  `json:"consecutiveMisses"`
	Strikes           int64  `json:"strikes"`
	Jailings          int64  `json:"jailings"`
	JailedAt          int64  `json:"jailedAt"`
	LastSubmitted     uint64 `json:"lastSubmitted"`
	HasSubmitted      bool   `json:"hasSubmitted"`
	UnbondAmount      int64  `json:"unbondAmount"`
	UnbondReadyAt     int64  `json:"unbondReadyAt"`
	Rewards           int64  `json:"rewards"`
	TotalEarned       int64  `json:"totalEarned"`
	TotalSlashed      int64  `json:"totalSlashed"`
}

// ProviderList is json/feed/<id>/providers.
type ProviderList struct {
	Head
	Feed      uint64         `json:"feed"`
	Providers []ProviderInfo `json:"providers"`
}

// DisputeInfo is json/dispute/<id>.
type DisputeInfo struct {
	Head
	ID               uint64 `json:"id"`
	Feed             uint64 `json:"feed"`
	Round            uint64 `json:"round"`
	Disputer         string `json:"disputer"`
	Bond             int64  `json:"bond"`
	ProposedValue    int64  `json:"proposedValue"`
	TierAsked        string `json:"tierAsked"`
	Evidence         string `json:"evidence"`
	EvidenceHash     string `json:"evidenceHash"`
	OpenedAt         int64  `json:"openedAt"`
	Status           string `json:"status"` // open | decided | appealed | resolved
	BallotRound      int64  `json:"ballotRound"`
	Outcome          string `json:"outcome"`
	FirstOutcome     string `json:"firstOutcome"`
	TierDecided      string `json:"tierDecided"`
	DecidedAt        int64  `json:"decidedAt"`
	ResolvedAt       int64  `json:"resolvedAt"`
	Appellant        string `json:"appellant"`
	AppealBond       int64  `json:"appealBond"`
	AppealAt         int64  `json:"appealAt"`
	Slashed          int64  `json:"slashed"`
	AppealWindowEnds int64  `json:"appealWindowEnds"`
}

// DisputeList is json/disputes.
type DisputeList struct {
	Head
	Total    uint64        `json:"total"`
	Disputes []DisputeInfo `json:"disputes"`
}

// CoreHealth is json/health.
type CoreHealth struct {
	Head
	Health  string `json:"health"`
	Balance int64  `json:"balance"`
	Held    int64  `json:"held"`
}

// DAOHead is on every DAO object.
type DAOHead struct {
	Now           int64  `json:"now"`
	Height        int64  `json:"height"`
	Address       string `json:"address"`
	Epoch         int64  `json:"epoch"`
	EpochBlocks   int64  `json:"epochBlocks"`
	Live          string `json:"live"`
	TotalStaked   int64  `json:"totalStaked"`
	MemberCount   int64  `json:"memberCount"`
	ProposalCount uint64 `json:"proposalCount"`
	BallotCount   uint64 `json:"ballotCount"`
}

// BallotInfo is json/ballot/<seq>.
type BallotInfo struct {
	DAOHead
	Seq            uint64 `json:"seq"`
	Dispute        uint64 `json:"dispute"`
	Round          int64  `json:"round"`
	MajorRequested bool   `json:"majorRequested"`
	Summary        string `json:"summary"`
	SealedEpoch    int64  `json:"sealedEpoch"`
	Obligated      int64  `json:"obligated"`
	Phase          string `json:"phase"` // commit | reveal | resolved (as last written on chain)
	CommitEnds     int64  `json:"commitEnds"`
	RevealEnds     int64  `json:"revealEnds"`
	Uphold         int64  `json:"uphold"`
	Overturn       int64  `json:"overturn"`
	OverturnMinor  int64  `json:"overturnMinor"`
	Void           int64  `json:"void"`
	Abstain        int64  `json:"abstain"`
	Revealed       int64  `json:"revealed"`
	Outcome        string `json:"outcome"`
	Tier           string `json:"tier"`
	ResolvedAt     int64  `json:"resolvedAt"`
	PrevSeq        uint64 `json:"prevSeq"`
	Final          bool   `json:"final"`  // the core applied the outcome: settlement may run
	Exists         *bool  `json:"exists"` // false on json/ballot/dispute/<id> without a ballot
}

// LivePhase derives the phase from block time: the chain only rewrites
// Phase when a transaction touches the ballot.
func (b *BallotInfo) LivePhase(now int64) string {
	if b.ResolvedAt > 0 || b.Phase == "resolved" {
		return "resolved"
	}
	switch {
	case now < b.CommitEnds:
		return "commit"
	case now < b.RevealEnds:
		return "reveal"
	}
	return "finished" // reveal over, waiting for ResolveDispute
}

// BallotList is json/ballots.
type BallotList struct {
	DAOHead
	Total   uint64       `json:"total"`
	Ballots []BallotInfo `json:"ballots"`
}

// MemberInfo is json/member/<addr>.
type MemberInfo struct {
	DAOHead
	Addr            string `json:"addr"`
	Exists          bool   `json:"exists"`
	Staked          int64  `json:"staked"`
	Power           int64  `json:"power"`
	UnbondAmount    int64  `json:"unbondAmount"`
	UnbondReadyAt   int64  `json:"unbondReadyAt"`
	Cursor          uint64 `json:"cursor"`
	PendingUgnot    int64  `json:"pendingUgnot"`
	PendingPyth     int64  `json:"pendingPyth"`
	FeesOwed        int64  `json:"feesOwed"`
	PenaltyInWindow int64  `json:"penaltyInWindow"`
	TotalPenalised  int64  `json:"totalPenalised"`
	TotalRewarded   int64  `json:"totalRewarded"`
}

// VoteStatus is json/commit|reveal/<seq>/<addr>.
type VoteStatus struct {
	DAOHead
	Seq        uint64 `json:"seq"`
	Voter      string `json:"voter"`
	Committed  bool   `json:"committed"`
	Commitment string `json:"commitment"`
	Revealed   bool   `json:"revealed"`
	Choice     string `json:"choice"`
}

// ProposalInfo is json/proposal/<id>.
type ProposalInfo struct {
	DAOHead
	ID         uint64 `json:"id"`
	Kind       string `json:"kind"`
	Payload    string `json:"payload"`
	Title      string `json:"title"`
	Proposer   string `json:"proposer"`
	CreatedAt  int64  `json:"createdAt"`
	VotingEnds int64  `json:"votingEnds"`
	Executable int64  `json:"executable"`
	Expires    int64  `json:"expires"`
	Status     string `json:"status"`
	Yes        int64  `json:"yes"`
	No         int64  `json:"no"`
	Abstain    int64  `json:"abstain"`
	Voters     int64  `json:"voters"`
}

// SubscriptionInfo is json/feed/<id>/subscription/<realm>, and an element of
// json/feed/<id>/subscribers.
type SubscriptionInfo struct {
	Now       int64  `json:"now"`
	Feed      uint64 `json:"feed"`
	Realm     string `json:"realm"`
	Exists    bool   `json:"exists"`
	Since     int64  `json:"since"`
	PaidUntil int64  `json:"paidUntil"`
	Paid      int64  `json:"paid"`
	Periods   int64  `json:"periods"`
	Active    bool   `json:"active"`
}

// SubscribersInfo is json/feed/<id>/subscribers.
type SubscribersInfo struct {
	Now             int64              `json:"now"`
	Feed            uint64             `json:"feed"`
	SubscriberPrice int64              `json:"subscriberPrice"`
	Sponsored       bool               `json:"sponsored"`
	Recurring       bool               `json:"recurring"`
	Offset          int64              `json:"offset"`
	Count           int64              `json:"count"`
	More            bool               `json:"more"` // another page follows
	Subscribers     []SubscriptionInfo `json:"subscribers"`
}

// KourtRecord is the mirror's json/record/<dispute>.
type KourtRecord struct {
	Now        int64  `json:"now"`
	Dispute    uint64 `json:"dispute"`
	Exists     bool   `json:"exists"`
	Binding    string `json:"binding"`
	State      string `json:"state"`
	Claim      uint64 `json:"claim"`
	Title      string `json:"title"`
	OpenedAt   int64  `json:"openedAt"`
	StakedAt   int64  `json:"stakedAt"`
	AnsweredAt int64  `json:"answeredAt"`
	SettledAt  int64  `json:"settledAt"`
	Verdict    int64  `json:"verdict"`
	Route      string `json:"route"`
	Steps      int64  `json:"steps"`
}

// Terminal reports whether the mirror needs no more cranking.
func (r *KourtRecord) Terminal() bool {
	switch r.State {
	case "settled", "confirmed", "dissent", "abandoned":
		return true
	}
	return false
}

// Due reports whether a crank at chain time now can advance the record:
// Kourt v3 needs three epochs (about 3 h) of stake history before an
// answer and 72 h after the answer before an undisputed settlement; the
// stand-in uses the same waits. It is a lower bound: once a court has
// qualified answerers, Kourt v3 also holds the mirror's answer back for their
// 24 h priority window, and the record view does not say whether that gate is
// active, so a staked record can be due here for up to a day before a crank
// moves it. A crank that is due may still find nothing to do (that priority
// window, a vote in progress) and returns the same state.
func (r *KourtRecord) Due(now int64) bool {
	switch r.State {
	case "staked":
		return now >= r.OpenedAt+3*3600
	case "answered":
		return now >= r.AnsweredAt+72*3600
	}
	return !r.Terminal()
}

// ViewError is the realm's {"error": ...} answer.
type ViewError struct {
	Path string
	Msg  string
}

func (e *ViewError) Error() string { return "view " + e.Path + ": " + e.Msg }

// JSONView renders `json/<path>` on a realm into v.
func (c *Client) JSONView(pkgPath, path string, v any) error {
	out, err := c.Render(pkgPath, "json/"+strings.TrimPrefix(path, "/"))
	if err != nil {
		return err
	}
	var probe struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(out), &probe); err != nil {
		return fmt.Errorf("view %s: not JSON: %.120s", path, out)
	}
	if probe.Error != "" {
		return &ViewError{Path: path, Msg: probe.Error}
	}
	if v == nil {
		return nil
	}
	return json.Unmarshal([]byte(out), v)
}

// IsViewError reports whether err is a realm-side view error (unknown id...).
func IsViewError(err error) bool {
	_, ok := err.(*ViewError)
	return ok
}

// ---- core readers

func (c *Client) CoreNow(core string) (*Head, error) {
	var h Head
	return &h, c.JSONView(core, "now", &h)
}

func (c *Client) Feed(core string, id uint64) (*FeedInfo, error) {
	var f FeedInfo
	return &f, c.JSONView(core, "feed/"+u(id), &f)
}

func (c *Client) Feeds(core string, offset, count int) (*FeedList, error) {
	var l FeedList
	return &l, c.JSONView(core, fmt.Sprintf("feeds/%d/%d", offset, count), &l)
}

// AllFeeds pages through every feed.
func (c *Client) AllFeeds(core string) ([]FeedSummary, error) {
	var out []FeedSummary
	for offset := 0; ; offset += 100 {
		l, err := c.Feeds(core, offset, 100)
		if err != nil {
			return nil, err
		}
		out = append(out, l.Feeds...)
		if len(l.Feeds) < 100 || uint64(len(out)) >= l.Total {
			return out, nil
		}
	}
}

func (c *Client) Round(core string, feed, round uint64) (*RoundInfo, error) {
	var r RoundInfo
	return &r, c.JSONView(core, "feed/"+u(feed)+"/round/"+u(round), &r)
}

func (c *Client) CurrentRound(core string, feed uint64) (*RoundInfo, error) {
	var r RoundInfo
	return &r, c.JSONView(core, "feed/"+u(feed)+"/round/current", &r)
}

func (c *Client) Provider(core string, feed uint64, addr string) (*ProviderInfo, error) {
	var p ProviderInfo
	return &p, c.JSONView(core, "feed/"+u(feed)+"/provider/"+addr, &p)
}

func (c *Client) Providers(core string, feed uint64) (*ProviderList, error) {
	var l ProviderList
	return &l, c.JSONView(core, "feed/"+u(feed)+"/providers", &l)
}

func (c *Client) Dispute(core string, id uint64) (*DisputeInfo, error) {
	var d DisputeInfo
	return &d, c.JSONView(core, "dispute/"+u(id), &d)
}

func (c *Client) Disputes(core string, from uint64, count int) (*DisputeList, error) {
	var l DisputeList
	return &l, c.JSONView(core, fmt.Sprintf("disputes/%d/%d", from, count), &l)
}

// AllDisputes pages through every dispute.
func (c *Client) AllDisputes(core string) ([]DisputeInfo, error) {
	var out []DisputeInfo
	for from := uint64(1); ; from += 100 {
		l, err := c.Disputes(core, from, 100)
		if err != nil {
			return nil, err
		}
		out = append(out, l.Disputes...)
		if len(l.Disputes) < 100 || from+100 > l.Total {
			return out, nil
		}
	}
}

func (c *Client) CoreHealth(core string) (*CoreHealth, error) {
	var h CoreHealth
	return &h, c.JSONView(core, "health", &h)
}

// ---- dao readers

func (c *Client) DAONow(dao string) (*DAOHead, error) {
	var h DAOHead
	return &h, c.JSONView(dao, "now", &h)
}

func (c *Client) Ballot(dao string, seq uint64) (*BallotInfo, error) {
	var b BallotInfo
	return &b, c.JSONView(dao, "ballot/"+u(seq), &b)
}

// BallotOfDispute returns the dispute's current ballot, or nil when none.
func (c *Client) BallotOfDispute(dao string, dispute uint64) (*BallotInfo, error) {
	var b BallotInfo
	if err := c.JSONView(dao, "ballot/dispute/"+u(dispute), &b); err != nil {
		return nil, err
	}
	if b.Exists != nil && !*b.Exists {
		return nil, nil
	}
	return &b, nil
}

func (c *Client) Ballots(dao string, from uint64, count int) (*BallotList, error) {
	var l BallotList
	return &l, c.JSONView(dao, fmt.Sprintf("ballots/%d/%d", from, count), &l)
}

func (c *Client) Member(dao, addr string) (*MemberInfo, error) {
	var m MemberInfo
	return &m, c.JSONView(dao, "member/"+addr, &m)
}

func (c *Client) CommitOf(dao string, seq uint64, addr string) (*VoteStatus, error) {
	var v VoteStatus
	return &v, c.JSONView(dao, "commit/"+u(seq)+"/"+addr, &v)
}

func (c *Client) RevealOf(dao string, seq uint64, addr string) (*VoteStatus, error) {
	var v VoteStatus
	return &v, c.JSONView(dao, "reveal/"+u(seq)+"/"+addr, &v)
}

func (c *Client) Proposal(dao string, id uint64) (*ProposalInfo, error) {
	var p ProposalInfo
	return &p, c.JSONView(dao, "proposal/"+u(id), &p)
}

// ---- subscription readers

// Subscribers reads every page of json/feed/<id>/subscribers (100 per
// page) and returns them as one list.
func (c *Client) Subscribers(core string, feed uint64) (*SubscribersInfo, error) {
	var all *SubscribersInfo
	for offset := 0; ; offset += 100 {
		var s SubscribersInfo
		if err := c.JSONView(core, fmt.Sprintf("feed/%d/subscribers/%d/100", feed, offset), &s); err != nil {
			return nil, err
		}
		if all == nil {
			all = &s
		} else {
			all.Subscribers = append(all.Subscribers, s.Subscribers...)
		}
		if !s.More || len(s.Subscribers) == 0 {
			all.More, all.Offset, all.Count = false, 0, int64(len(all.Subscribers))
			return all, nil
		}
	}
}

func (c *Client) Subscription(core string, feed uint64, realmPath string) (*SubscriptionInfo, error) {
	var s SubscriptionInfo
	return &s, c.JSONView(core, "feed/"+u(feed)+"/subscription/"+realmPath, &s)
}

// ---- kourt readers

func (c *Client) KourtRecord(kourt string, dispute uint64) (*KourtRecord, error) {
	var r KourtRecord
	return &r, c.JSONView(kourt, "record/"+u(dispute), &r)
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }
