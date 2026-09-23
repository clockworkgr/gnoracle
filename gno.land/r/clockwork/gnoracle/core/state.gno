package core

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/clockwork/gnoracle/spec/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
)

// MaxSlots is the number of provider slots a feed has. It fixes the width of
// the per-round value strings and masks, so it cannot change after deployment.
const MaxSlots = 15

// Slots and per-round values are packed into fixed-width strings rather than
// arrays: on chain every array element is a separately stored value with its
// own overhead (measured about 150 bytes each), so a 15-element array costs
// more than 2 kB where a packed string costs its own length.
const (
	slotWidth  = 40 // bech32 length of a gno address
	valueWidth = 8  // big-endian int64
)

var blankSlots = strings.Repeat(" ", MaxSlots*slotWidth)

// Feed, provider and round status values.
const (
	FeedProposed   = "proposed"
	FeedActive     = "active"
	FeedUnfunded   = "unfunded"
	FeedDeprecated = "deprecated"

	ProviderActive    = "active"
	ProviderJailed    = "jailed"
	ProviderUnbonding = "unbonding"
	ProviderWithdrawn = "withdrawn"

	RoundOpen       = "open"
	RoundAggregated = "aggregated"
	RoundEmpty      = "empty"
	RoundSkipped    = "skipped"
	RoundVoid       = "void"

	DisputeOpen     = "open"     // round-1 ballot running
	DisputeDecided  = "decided"  // round-1 outcome recorded; appeal window open
	DisputeAppealed = "appealed" // round-2 ballot running
	DisputeResolved = "resolved" // outcome applied
)

// Feed is one oracle feed. Fields are read by implementations; they change
// only through StateRef methods, which is what makes the store a gate rather
// than a pointer.
type Feed struct {
	ID        uint64
	Proposer  address
	FromRealm bool
	Spec      *spec.Spec
	Status    string
	CreatedAt int64
	StartAt   int64 // first round opens (recurring) / resolve time (one-off)
	Deposit   int64 // proposal deposit held until activation or rejection

	// funding
	Prepaid      int64 // the requester's first period or bounty, escrowed until activation
	Pool         int64 // long-lived funds: subscriptions, bounty
	Drip         int64 // paid from Pool per round (0 for one-off: the whole pool)
	FeeAccrued   int64 // metered fees (provider share) since the last finalisation
	PenaltyCarry int64 // miss slashes waiting for the next round pool
	PaidUntil    int64 // subscription coverage end (informational)

	// providers: MaxSlots cells of slotWidth bytes; a blank cell is spaces
	Slots       string
	ActiveCount int64

	// finalisation cursor and the served value
	HaveLast      bool
	LastFinalized uint64
	HaveValue     bool
	LastValue     int64
	LastTier      string
	LastRound     uint64
	LastRoundAt   int64 // open time of the round that produced LastValue
	LastFinalAt   int64 // block time LastValue's round was finalised
	// the last final value: the newest aggregated round whose dispute window
	// passed without a dispute standing against it. Served while the latest
	// round is disputed or voided, and the quarantine reference (plan §4.3, §7.1).
	HaveFinal     bool
	FinalValue    int64
	FinalRound    uint64
	FinalAt       int64
	FinalCursor   uint64 // next round to examine for promotion
	OldestRound   uint64
	EmptyStreak   int64
	Reopened      bool
	DeprecatedAt  int64
	OpenDisputes  int64
	LastDisputeAt int64
	DisputesInRow int64
	SubsidyPerRnd int64
	SubsidyRemain int64
	TotalPaidOut  int64
	RoundsFinal   int64
	DeclaredValue int64 // trusted requester's declared value at stake
}

// Provider is one account's stake on one feed.
type Provider struct {
	Feed              uint64
	Addr              address
	Stake             int64
	Status            string
	Slot              int64 // -1 when not in the active set
	Memo              string
	JoinedAt          int64
	ObligedFrom       uint64 // first round this provider owes a submission for
	ConsecutiveMisses int64
	Strikes           int64
	StrikeWindowStart uint64
	MissSlashedEpoch  int64 // miss slash taken in the current provider epoch
	MinorsEpoch       int64
	EpochStart        int64
	Jailings          int64
	JailingsSince     int64
	JailedAt          int64
	LastSubmitted     uint64
	HasSubmitted      bool
	UnbondAmount      int64
	UnbondReadyAt     int64
	Rewards           int64 // accrued, unclaimed
	TotalEarned       int64
	TotalSlashed      int64
}

// Round is one aggregation round of a feed. Submissions live inline, packed
// into Values (MaxSlots big-endian int64 cells), so a round is one small
// object to read and write.
type Round struct {
	Feed          uint64
	ID            uint64
	Values        string
	SubmittedMask uint32
	EligibleMask  uint32
	Status        string
	Tier          string
	Value         int64
	Pool          int64
	OpenedAt      int64
	FinalisedAt   int64
	DisputeID     uint64
	Overturned    bool
}

// SlotAt returns the provider seated in slot i, or "" when the slot is empty.
func (f *Feed) SlotAt(i int) address {
	if i < 0 || i >= MaxSlots || len(f.Slots) < (i+1)*slotWidth {
		return ""
	}
	cell := f.Slots[i*slotWidth : (i+1)*slotWidth]
	if cell[0] == ' ' {
		return ""
	}
	return address(cell)
}

// ValueAt returns the value submitted in slot i (meaningful only when the
// slot's bit is set in SubmittedMask).
func (r *Round) ValueAt(i int) int64 {
	if i < 0 || i >= MaxSlots || len(r.Values) < (i+1)*valueWidth {
		return 0
	}
	b := r.Values[i*valueWidth : (i+1)*valueWidth]
	var u uint64
	for k := 0; k < valueWidth; k++ {
		u = u<<8 | uint64(b[k])
	}
	return int64(u)
}

func packValue(v int64) string {
	u := uint64(v)
	b := make([]byte, valueWidth)
	for k := valueWidth - 1; k >= 0; k-- {
		b[k] = byte(u)
		u >>= 8
	}
	return string(b)
}

func setCell(s string, i, width int, cell string) string {
	if len(cell) != width {
		panic("core: cell width mismatch")
	}
	return s[:i*width] + cell + s[(i+1)*width:]
}

// Credit is a consumer realm's prepaid balance.
type Credit struct {
	Addr      address
	Balance   int64
	Spent     int64
	Reads     int64
	FinalOnly bool
}

// Sponsorship is one account's subscription on one feed.
type Sponsorship struct {
	Feed      uint64
	Addr      address
	PaidUntil int64
	Paid      int64
	Consumers []address
}

// DisputeRecord is a challenge to one round (logic arrives with the disputes
// release; the record lives here so it survives that upgrade).
type DisputeRecord struct {
	ID            uint64
	Feed          uint64
	Round         uint64
	Disputer      address
	Bond          int64
	ProposedValue int64
	TierAsked     string
	Evidence      string
	EvidenceHash  string
	OpenedAt      int64
	Status        string
	BallotRound   int64
	Outcome       string // the standing outcome (round 1 until an appeal replaces it)
	FirstOutcome  string
	TierDecided   string
	DecidedAt     int64
	ResolvedAt    int64
	Appellant     address
	AppealBond    int64
	AppealAt      int64
	CoherentW     int64
	Slashed       int64 // total taken from providers on an overturn
	PriorValue    int64 // the round's value before an overturn
	PriorTier     string
}

// ------------------------------------------------------------- tables ----

var (
	feeds     = bptree.NewBPTree32() // feedKey -> *Feed
	providers = bptree.NewBPTree32() // feedKey+addr -> *Provider
	rounds    = bptree.NewBPTree32() // feedKey+roundKey -> *Round
	credits   = bptree.NewBPTree32() // addr -> *Credit
	sponsors  = bptree.NewBPTree32() // feedKey+addr -> *Sponsorship
	sponsored = bptree.NewBPTree32() // feedKey+consumer -> *Sponsorship (who covers a consumer's reads)
	slotlog   = bptree.NewBPTree32() // feedKey+slot+fromRound -> address
	notes     = bptree.NewBPTree32() // kind+id+key -> string: release-defined data (plan §3.2)
	disputes  = bptree.NewBPTree32() // disputeKey -> *DisputeRecord
	trusted   = bptree.NewBPTree32() // pkgPath -> int64 cap

	feedSeq    seqid.ID
	disputeSeq seqid.ID
)

func feedKey(id uint64) string { return u64key(id) }

func roundKey(feed, round uint64) string { return u64key(feed) + u64key(round) }

func providerKey(feed uint64, addr address) string { return u64key(feed) + string(addr) }

func u64key(v uint64) string {
	return string([]byte{
		byte(v >> 56), byte(v >> 48), byte(v >> 40), byte(v >> 32),
		byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v),
	})
}

func slotKey(feed uint64, slot int64, fromRound uint64) string {
	return u64key(feed) + string([]byte{byte(slot)}) + u64key(fromRound)
}

// Now is block time in seconds.
func Now() int64 { return time.Now().Unix() }

// ----------------------------------------------------------- read views ----
// Reads are ungated: anyone may inspect the state. What comes back is
// read-only to every realm but this one.

// GetFeed returns a feed or nil.
func GetFeed(id uint64) *Feed {
	v := feeds.Get(feedKey(id))
	if v == nil {
		return nil
	}
	return v.(*Feed)
}

// GetProvider returns a provider record or nil.
func GetProvider(feed uint64, addr address) *Provider {
	v := providers.Get(providerKey(feed, addr))
	if v == nil {
		return nil
	}
	return v.(*Provider)
}

// GetRound returns a round or nil.
func GetRound(feed, round uint64) *Round {
	v := rounds.Get(roundKey(feed, round))
	if v == nil {
		return nil
	}
	return v.(*Round)
}

// GetCredit returns a consumer's credit or nil.
func GetCredit(addr address) *Credit {
	v := credits.Get(string(addr))
	if v == nil {
		return nil
	}
	return v.(*Credit)
}

// GetSponsor returns a sponsor record or nil.
func GetSponsor(feed uint64, addr address) *Sponsorship {
	v := sponsors.Get(providerKey(feed, addr))
	if v == nil {
		return nil
	}
	return v.(*Sponsorship)
}

// SponsorOf returns the sponsor covering a consumer's reads on a feed, or nil.
func SponsorOf(feed uint64, consumer address) *Sponsorship {
	v := sponsored.Get(providerKey(feed, consumer))
	if v == nil {
		return nil
	}
	return v.(*Sponsorship)
}

// GetDispute returns a dispute or nil.
func GetDispute(id uint64) *DisputeRecord {
	v := disputes.Get(u64key(id))
	if v == nil {
		return nil
	}
	return v.(*DisputeRecord)
}

// TrustedCap returns a trusted requester's cap, 0 when not trusted.
func TrustedCap(pkgPath string) int64 {
	v := trusted.Get(pkgPath)
	if v == nil {
		return 0
	}
	return v.(int64)
}

// SlotHolderAt returns the provider that held slot at round r of a feed.
func SlotHolderAt(feed uint64, slot int64, r uint64) address {
	var holder address
	slotlog.ReverseIterate(slotKey(feed, slot, 0), slotKey(feed, slot, r), func(_ string, v any) bool {
		holder = v.(address)
		return true
	})
	return holder
}

// Note returns release-defined data attached to an object, or "".
func Note(kind, id, key string) string {
	v := notes.Get(noteKey(kind, id, key))
	if v == nil {
		return ""
	}
	return v.(string)
}

func noteKey(kind, id, key string) string { return kind + "\x00" + id + "\x00" + key }

// FeedCount is the number of feeds ever created.
func FeedCount() uint64 { return uint64(feedSeq) }

// DisputeCount is the number of disputes ever opened.
func DisputeCount() uint64 { return uint64(disputeSeq) }

// IterateFeeds calls fn for count feeds from offset, in id order.
func IterateFeeds(offset, count int, fn func(*Feed) bool) {
	feeds.IterateByOffset(offset, count, func(_ string, v any) bool { return fn(v.(*Feed)) })
}

// IterateProviders calls fn for every provider record of a feed.
func IterateProviders(feed uint64, fn func(*Provider) bool) {
	providers.Iterate(u64key(feed), u64key(feed+1), func(_ string, v any) bool { return fn(v.(*Provider)) })
}

// IterateRounds calls fn for rounds of a feed from start, at most count.
func IterateRounds(feed, start uint64, count int, fn func(*Round) bool) {
	n := 0
	rounds.Iterate(roundKey(feed, start), u64key(feed+1), func(_ string, v any) bool {
		n++
		if fn(v.(*Round)) {
			return true
		}
		return n >= count
	})
}

// ReverseIterateRounds calls fn for rounds of a feed newest first, at most count.
func ReverseIterateRounds(feed uint64, count int, fn func(*Round) bool) {
	n := 0
	rounds.ReverseIterate(u64key(feed), u64key(feed)+u64key(^uint64(0)), func(_ string, v any) bool {
		n++
		if fn(v.(*Round)) {
			return true
		}
		return n >= count
	})
}

// ------------------------------------------------------------- store ----

// StateRef is a permission to change the state, handed to code running on
// this realm's live cur (the accepted implementation, or a registered
// extension). It carries the realm value and re-checks it on every write, so
// it cannot be stashed or replayed.
type StateRef struct{ rlm realm }

// Store hands out a StateRef to the live implementation or an extension.
func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("core: realm value is not the caller's live cur")
	}
	if caller := rlm.PkgPath(); caller != selfPath {
		panic("core: state is reachable only through " + selfPath + ", not from " + caller)
	}
}

func (r *StateRef) check() { assertStateAccess(0, r.rlm) }

// inflow is asserted by every setter that books coins as received: the
// realm's actual balance must cover everything it already owes plus the new
// amount, so an implementation cannot book coins that did not arrive with
// the call (the -send of a user transaction is on the account before the
// call runs).
func (r *StateRef) inflow(amount int64) {
	if amount <= 0 {
		panic("core: amount must be positive")
	}
	if HeldTotal()+amount > Balance() {
		panic("core: the coins for this operation were not received")
	}
}

// SetNote attaches release-defined data to an object (kind and id are the
// release's naming, e.g. "feed", "12"); an empty value removes the entry.
// Releases use it for fields the permanent structs do not have.
func (r *StateRef) SetNote(kind, id, key, value string) {
	r.check()
	if kind == "" || key == "" || len(kind) > 32 || len(id) > 64 || len(key) > 64 || len(value) > 4096 {
		panic("core: note kind and key must be 1 to 32 and 64 bytes, id at most 64, value at most 4096")
	}
	k := noteKey(kind, id, key)
	if value == "" {
		notes.Remove(k)
		return
	}
	notes.Set(k, value)
}

// ClearNotes removes every note of one object.
func (r *StateRef) ClearNotes(kind, id string) {
	r.check()
	removeByPrefix(notes, kind+"\x00"+id+"\x00")
}

// Emit lets the live implementation emit an event under this realm's path.
func (r *StateRef) Emit(typ string, attrs ...string) {
	r.check()
	emit(typ, attrs...)
}

// ---- feeds

// NewFeed creates a proposed feed and returns it.
func (r *StateRef) NewFeed(proposer address, fromRealm bool, sp *spec.Spec, deposit, declared int64) *Feed {
	r.check()
	id := uint64(feedSeq.Next())
	f := &Feed{ID: id, Proposer: proposer, FromRealm: fromRealm, Spec: sp, Status: FeedProposed, CreatedAt: Now(), Deposit: deposit, DeclaredValue: declared, Slots: blankSlots}
	feeds.Set(feedKey(id), f)
	if deposit > 0 {
		r.inflow(deposit)
		held.Deposits += deposit
	} else if deposit < 0 {
		panic("core: deposit must not be negative")
	}
	emit("FeedProposed", "feed", u(id), "proposer", string(proposer), "specHash", sp.Hash)
	return f
}

func mustFeed(id uint64) *Feed {
	f := GetFeed(id)
	if f == nil {
		panic("core: unknown feed " + u(id))
	}
	return f
}

// FeedSetStatus changes a feed's status.
func (r *StateRef) FeedSetStatus(id uint64, status string) {
	r.check()
	f := mustFeed(id)
	f.Status = status
	if status == FeedDeprecated {
		f.DeprecatedAt = Now()
	}
}

// FeedActivate marks a feed active with its first round time and drip.
func (r *StateRef) FeedActivate(id uint64, startAt, drip int64) {
	r.check()
	if drip < 0 {
		panic("core: drip must not be negative")
	}
	f := mustFeed(id)
	f.Status = FeedActive
	f.StartAt = startAt
	f.Drip = drip
	// the escrowed prepayment becomes the pool (one-off) or takes the fee
	// split (recurring) only now; a rejected request gets it back
	if pre := f.Prepaid; pre > 0 {
		f.Prepaid = 0
		held.Deposits -= pre
		if f.Spec != nil && !f.Spec.IsRecurring() {
			f.Pool += pre
			held.Pools += pre
		} else {
			r.splitSubscription(id, pre)
		}
	}
	emit("FeedActivated", "feed", u(id), "startAt", strconv.FormatInt(startAt, 10))
}

// FeedSetStart changes the first-round time (reopening a one-off).
func (r *StateRef) FeedSetStart(id uint64, startAt int64, reopened bool) {
	r.check()
	f := mustFeed(id)
	f.StartAt = startAt
	f.Reopened = reopened
}

// FeedResetForReopen restarts a voided one-off feed at a new resolve time.
func (r *StateRef) FeedResetForReopen(id uint64, startAt int64) {
	r.check()
	f := mustFeed(id)
	f.StartAt = startAt
	f.Reopened = true
	f.HaveLast = false
	f.LastFinalized = 0
	f.HaveValue = false
	f.LastTier = ""
	f.EmptyStreak = 0
	rounds.Remove(roundKey(id, 0))
	emit("FeedReopened", "feed", u(id), "resolveAt", strconv.FormatInt(startAt, 10))
}

// FeedSetDrip changes the per-round drip.
func (r *StateRef) FeedSetDrip(id uint64, drip int64) {
	r.check()
	mustFeed(id).Drip = drip
}

// FeedSetPaidUntil records subscription coverage.
func (r *StateRef) FeedSetPaidUntil(id uint64, until int64) {
	r.check()
	mustFeed(id).PaidUntil = until
}

// FeedSetCursor records the finalisation cursor.
func (r *StateRef) FeedSetCursor(id uint64, lastFinalized uint64) {
	r.check()
	f := mustFeed(id)
	f.HaveLast = true
	f.LastFinalized = lastFinalized
}

// FeedSetValue records the served value.
func (r *StateRef) FeedSetValue(id uint64, round uint64, value int64, tier string, roundAt int64) {
	r.check()
	f := mustFeed(id)
	f.HaveValue = true
	f.LastValue = value
	f.LastTier = tier
	f.LastRound = round
	f.LastRoundAt = roundAt
	f.LastFinalAt = Now()
}

// FeedSetTier updates the tier of the served value (e.g. provisional -> final).
func (r *StateRef) FeedSetTier(id uint64, tier string) {
	r.check()
	mustFeed(id).LastTier = tier
}

// FeedSetEmptyStreak records consecutive empty rounds.
func (r *StateRef) FeedSetEmptyStreak(id uint64, n int64) {
	r.check()
	mustFeed(id).EmptyStreak = n
}

// FeedSetOldest records the prune cursor.
func (r *StateRef) FeedSetOldest(id uint64, oldest uint64) {
	r.check()
	mustFeed(id).OldestRound = oldest
}

// FeedSetSpecEconomics changes the DAO-adjustable fields of a spec.
func (r *StateRef) FeedSetSpecEconomics(id uint64, readPrice, subscriptionPrice, providerMinStake, toleranceBps, quarantineBps, disputeWindow int64) {
	r.check()
	f := mustFeed(id)
	sp := *f.Spec
	sp.ReadPrice = readPrice
	sp.SubscriptionPrice = subscriptionPrice
	sp.ProviderMinStake = providerMinStake
	sp.ToleranceBps = toleranceBps
	sp.QuarantineBps = quarantineBps
	sp.DisputeWindow = disputeWindow
	f.Spec = &sp
	emit("FeedUpdated", "feed", u(id))
}

// FeedAssignSlot seats a provider in a slot from a round on.
func (r *StateRef) FeedAssignSlot(id uint64, slot int64, addr address, fromRound uint64) {
	r.check()
	f := mustFeed(id)
	if slot < 0 || slot >= MaxSlots {
		panic("core: slot out of range")
	}
	if len(addr) != slotWidth {
		panic("core: address must be " + strconv.Itoa(slotWidth) + " bytes")
	}
	if f.SlotAt(int(slot)) != "" {
		panic("core: slot is taken")
	}
	f.Slots = setCell(f.Slots, int(slot), slotWidth, string(addr))
	f.ActiveCount++
	slotlog.Set(slotKey(id, slot, fromRound), addr)
}

// FeedClearSlot empties a slot from a round on.
func (r *StateRef) FeedClearSlot(id uint64, slot int64, fromRound uint64) {
	r.check()
	f := mustFeed(id)
	if slot < 0 || slot >= MaxSlots || f.SlotAt(int(slot)) == "" {
		panic("core: slot is empty")
	}
	f.Slots = setCell(f.Slots, int(slot), slotWidth, strings.Repeat(" ", slotWidth))
	f.ActiveCount--
	slotlog.Set(slotKey(id, slot, fromRound), address(""))
}

// FeedSetDisputeCounters records dispute bookkeeping.
func (r *StateRef) FeedSetDisputeCounters(id uint64, open, inRow int64, lastAt int64) {
	r.check()
	f := mustFeed(id)
	f.OpenDisputes = open
	f.DisputesInRow = inRow
	f.LastDisputeAt = lastAt
}

// FeedDelete removes a feed record (after its rounds and providers are gone).
func (r *StateRef) FeedDelete(id uint64) {
	r.check()
	f := mustFeed(id)
	if f.Pool != 0 || f.FeeAccrued != 0 || f.PenaltyCarry != 0 || f.Deposit != 0 || f.Prepaid != 0 {
		panic("core: feed still holds funds")
	}
	// reclaim the feed's index entries: slot log, sponsorships, sponsored consumers
	removeByPrefix(slotlog, u64key(id))
	removeByPrefix(sponsors, u64key(id))
	removeByPrefix(sponsored, u64key(id))
	feeds.Remove(feedKey(id))
	emit("FeedPruned", "feed", u(id))
}

// removeByPrefix deletes every entry whose key starts with prefix (the
// tree must not be modified while iterating, so keys are collected first).
func removeByPrefix(t *bptree.BPTree, prefix string) {
	for {
		keys := []string{}
		t.Iterate(prefix, prefix+"\xff", func(k string, _ any) bool {
			keys = append(keys, k)
			return len(keys) >= 256
		})
		if len(keys) == 0 {
			return
		}
		for _, k := range keys {
			t.Remove(k)
		}
		if len(keys) < 256 {
			return
		}
	}
}

// FeedPromoteFinal advances the feed's last-final cursor: rounds finalise in
// order, so it walks from the cursor while rounds have passed their dispute
// window with no dispute standing, at most 64 per call.
func (r *StateRef) FeedPromoteFinal(id uint64) {
	r.check()
	f := mustFeed(id)
	if f.Spec == nil || !f.HaveLast {
		return
	}
	t := Now()
	for k := 0; k < 64 && f.FinalCursor <= f.LastFinalized; k++ {
		rid := f.FinalCursor
		rd := GetRound(id, rid)
		if rd == nil { // pruned or never recorded: long past
			f.FinalCursor++
			continue
		}
		if rd.Status == RoundOpen {
			return
		}
		if rd.Status == RoundAggregated {
			if rd.FinalisedAt+f.Spec.DisputeWindow > t {
				return
			}
			if rd.DisputeID != 0 {
				if d := GetDispute(rd.DisputeID); d != nil && d.Status != DisputeResolved {
					return
				}
			}
			f.HaveFinal = true
			f.FinalValue = rd.Value
			f.FinalRound = rid
			f.FinalAt = rd.FinalisedAt
		}
		f.FinalCursor++
	}
}

// ---- providers

// NewProvider creates a provider record with its stake already received.
func (r *StateRef) NewProvider(feed uint64, addr address, stake int64, slot int64, memo string, obligedFrom uint64) *Provider {
	r.check()
	if GetProvider(feed, addr) != nil {
		panic("core: provider record exists")
	}
	if stake <= 0 {
		panic("core: stake must be positive")
	}
	now := Now()
	p := &Provider{Feed: feed, Addr: addr, Stake: stake, Status: ProviderActive, Slot: slot, Memo: memo, JoinedAt: now, ObligedFrom: obligedFrom, EpochStart: now, JailingsSince: now}
	providers.Set(providerKey(feed, addr), p)
	r.inflow(stake)
	held.Stakes += stake
	emit("ProviderRegistered", "feed", u(feed), "provider", string(addr), "stake", strconv.FormatInt(stake, 10))
	return p
}

func mustProvider(feed uint64, addr address) *Provider {
	p := GetProvider(feed, addr)
	if p == nil {
		panic("core: not a provider of this feed")
	}
	return p
}

// ProviderAddStake records received stake.
func (r *StateRef) ProviderAddStake(feed uint64, addr address, amount int64) {
	r.check()
	if amount <= 0 {
		panic("core: amount must be positive")
	}
	p := mustProvider(feed, addr)
	p.Stake += amount
	r.inflow(amount)
	held.Stakes += amount
}

// ProviderSetStatus changes status and slot.
func (r *StateRef) ProviderSetStatus(feed uint64, addr address, status string, slot int64) {
	r.check()
	p := mustProvider(feed, addr)
	p.Status = status
	p.Slot = slot
	if status == ProviderJailed {
		p.JailedAt = Now()
	}
}

// ProviderSetObligedFrom records the first round a (re)seated provider owes.
func (r *StateRef) ProviderSetObligedFrom(feed uint64, addr address, from uint64) {
	r.check()
	mustProvider(feed, addr).ObligedFrom = from
}

// ProviderSetCounters records liveness bookkeeping.
func (r *StateRef) ProviderSetCounters(feed uint64, addr address, misses, strikes int64, strikeWindowStart uint64, lastSubmitted uint64, hasSubmitted bool) {
	r.check()
	p := mustProvider(feed, addr)
	p.ConsecutiveMisses = misses
	p.Strikes = strikes
	p.StrikeWindowStart = strikeWindowStart
	p.LastSubmitted = lastSubmitted
	p.HasSubmitted = hasSubmitted
}

// ProviderSetEpoch records the per-epoch slash bookkeeping.
func (r *StateRef) ProviderSetEpoch(feed uint64, addr address, epochStart, missSlashed, minors int64) {
	r.check()
	p := mustProvider(feed, addr)
	p.EpochStart = epochStart
	p.MissSlashedEpoch = missSlashed
	p.MinorsEpoch = minors
}

// ProviderSetJailings records jailing counts.
func (r *StateRef) ProviderSetJailings(feed uint64, addr address, jailings int64, since int64) {
	r.check()
	p := mustProvider(feed, addr)
	p.Jailings = jailings
	p.JailingsSince = since
}

// ProviderStartUnbond moves the whole stake to unbonding.
func (r *StateRef) ProviderStartUnbond(feed uint64, addr address, readyAt int64) {
	r.check()
	p := mustProvider(feed, addr)
	if p.Stake > 0 {
		held.Stakes -= p.Stake
		held.Unbonding += p.Stake
		p.UnbondAmount += p.Stake
		p.Stake = 0
	}
	p.Status = ProviderUnbonding
	p.Slot = -1
	p.UnbondReadyAt = readyAt
	emit("ProviderUnbonding", "feed", u(feed), "provider", string(addr), "readyAt", strconv.FormatInt(readyAt, 10))
}

// ProviderPayUnbonded pays the unbonded amount to the provider and marks it
// withdrawn. Returns the amount.
func (r *StateRef) ProviderPayUnbonded(feed uint64, addr address) int64 {
	r.check()
	p := mustProvider(feed, addr)
	if p.Status != ProviderUnbonding {
		panic("core: not unbonding")
	}
	amount := p.UnbondAmount
	p.UnbondAmount = 0
	p.Status = ProviderWithdrawn
	if amount > 0 {
		held.Unbonding -= amount
		r.send(addr, amount)
	}
	emit("ProviderWithdrawn", "feed", u(feed), "provider", string(addr), "amount", strconv.FormatInt(amount, 10))
	return amount
}

// RewardForfeit moves a provider's unclaimed rewards to the fee pool (a
// pruned feed after its retention, plan §5.2).
func (r *StateRef) RewardForfeit(feed uint64, addr address) int64 {
	r.check()
	p := mustProvider(feed, addr)
	amount := p.Rewards
	if amount == 0 {
		return 0
	}
	p.Rewards = 0
	held.Rewards -= amount
	held.FeesPending += amount
	emit("RewardsForfeited", "feed", u(feed), "provider", string(addr), "amount", strconv.FormatInt(amount, 10))
	return amount
}

// ProviderDelete removes a withdrawn provider record with nothing owed.
func (r *StateRef) ProviderDelete(feed uint64, addr address) {
	r.check()
	p := mustProvider(feed, addr)
	if p.Stake != 0 || p.UnbondAmount != 0 || p.Rewards != 0 {
		panic("core: provider still holds funds")
	}
	providers.Remove(providerKey(feed, addr))
}

// ---- rounds

// NewRound opens a round record.
func (r *StateRef) NewRound(feed, id uint64, openedAt int64) *Round {
	r.check()
	if GetRound(feed, id) != nil {
		panic("core: round exists")
	}
	rd := &Round{Feed: feed, ID: id, Status: RoundOpen, OpenedAt: openedAt, Values: strings.Repeat("\x00", MaxSlots*valueWidth)}
	rounds.Set(roundKey(feed, id), rd)
	return rd
}

// RoundSetSubmission records a slot's value.
func (r *StateRef) RoundSetSubmission(feed, id uint64, slot int64, value int64) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	if slot < 0 || slot >= MaxSlots {
		panic("core: slot out of range")
	}
	rd.Values = setCell(rd.Values, int(slot), valueWidth, packValue(value))
	rd.SubmittedMask |= 1 << uint(slot)
}

// RoundFinalise records a round's result.
func (r *StateRef) RoundFinalise(feed, id uint64, status, tier string, value int64, eligibleMask uint32, pool int64) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.Status = status
	rd.Tier = tier
	rd.Value = value
	rd.EligibleMask = eligibleMask
	rd.Pool = pool
	rd.FinalisedAt = Now()
	emit("RoundFinalized", "feed", u(feed), "round", u(id), "status", status, "tier", tier,
		"value", strconv.FormatInt(value, 10), "eligible", strconv.Itoa(popcount(eligibleMask)), "pool", strconv.FormatInt(pool, 10))
}

// RoundSetTier changes a finalised round's tier (provisional -> final).
func (r *StateRef) RoundSetTier(feed, id uint64, tier string) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.Tier = tier
}

// RoundSetDispute links a round to a dispute and marks an overturn.
func (r *StateRef) RoundSetDispute(feed, id uint64, disputeID uint64, overturned bool, value int64, status, tier string) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.DisputeID = disputeID
	rd.Overturned = overturned
	rd.Value = value
	rd.Status = status
	rd.Tier = tier
}

// RoundDelete removes a round record.
func (r *StateRef) RoundDelete(feed, id uint64) {
	r.check()
	if rd := GetRound(feed, id); rd != nil && rd.DisputeID != 0 {
		if d := GetDispute(rd.DisputeID); d != nil && d.Status != DisputeResolved {
			panic("core: the round is under a dispute that is not resolved")
		}
	}
	rounds.Remove(roundKey(feed, id))
}

// ---- credits and sponsors

// CreditDeposit records received credit.
func (r *StateRef) CreditDeposit(addr address, amount int64) {
	r.check()
	if amount <= 0 {
		panic("core: amount must be positive")
	}
	c := GetCredit(addr)
	if c == nil {
		c = &Credit{Addr: addr}
		credits.Set(string(addr), c)
	}
	c.Balance += amount
	r.inflow(amount)
	held.Credits += amount
	emit("CreditDeposited", "consumer", string(addr), "amount", strconv.FormatInt(amount, 10))
}

// CreditWithdraw pays credit back to its owner.
func (r *StateRef) CreditWithdraw(addr address, amount int64) {
	r.check()
	c := GetCredit(addr)
	if c == nil || amount <= 0 || c.Balance < amount {
		panic("core: insufficient credit")
	}
	c.Balance -= amount
	held.Credits -= amount
	r.send(addr, amount)
	emit("CreditWithdrawn", "consumer", string(addr), "amount", strconv.FormatInt(amount, 10))
}

// CreditSetFinalOnly toggles the consumer's read mode.
func (r *StateRef) CreditSetFinalOnly(addr address, on bool) {
	r.check()
	c := GetCredit(addr)
	if c == nil {
		c = &Credit{Addr: addr}
		credits.Set(string(addr), c)
	}
	c.FinalOnly = on
}

// CreditCharge debits a read fee and splits it: the provider share to the
// feed's accrued fees, the rest to the fee pool awaiting the DAO.
func (r *StateRef) CreditCharge(addr address, feed uint64, fee int64) {
	r.check()
	if fee <= 0 {
		panic("core: fee must be positive")
	}
	c := GetCredit(addr)
	if c == nil || c.Balance < fee {
		panic("core: insufficient credit; deposit with DepositFor")
	}
	c.Balance -= fee
	c.Spent += fee
	c.Reads++
	held.Credits -= fee
	r.splitFee(feed, fee)
}

// CreditCountRead records a free (sponsored) read.
func (r *StateRef) CreditCountRead(addr address) {
	r.check()
	c := GetCredit(addr)
	if c == nil {
		c = &Credit{Addr: addr}
		credits.Set(string(addr), c)
	}
	c.Reads++
}

// SponsorPay records a subscription payment and the consumers it covers.
func (r *StateRef) SponsorPay(feed uint64, sponsor address, amount int64, paidUntil int64, consumers []address) {
	r.check()
	if amount <= 0 {
		panic("core: amount must be positive")
	}
	if len(consumers) > 8 {
		panic("core: at most 8 consumers per sponsor")
	}
	r.inflow(amount)
	s := GetSponsor(feed, sponsor)
	if s == nil {
		s = &Sponsorship{Feed: feed, Addr: sponsor}
		sponsors.Set(providerKey(feed, sponsor), s)
	}
	// a consumer keeps whichever sponsorship covers it longest
	for _, old := range s.Consumers {
		if v := sponsored.Get(providerKey(feed, old)); v != nil && v.(*Sponsorship) == s {
			sponsored.Remove(providerKey(feed, old))
		}
	}
	s.PaidUntil = paidUntil
	s.Paid += amount
	s.Consumers = consumers
	for _, c := range consumers {
		if v := sponsored.Get(providerKey(feed, c)); v != nil {
			if other := v.(*Sponsorship); other != s && other.PaidUntil >= paidUntil {
				continue
			}
		}
		sponsored.Set(providerKey(feed, c), s)
	}
	// subscriptions fund the long-lived pool; metered read fees stay in the
	// per-round accrual
	r.splitSubscription(feed, amount)
	emit("Sponsored", "feed", u(feed), "sponsor", string(sponsor), "amount", strconv.FormatInt(amount, 10), "paidUntil", strconv.FormatInt(paidUntil, 10))
}

// splitFee routes a read fee: the provider share to the feed's accrued fees
// (paid with the next round), the staker and treasury shares to the pending
// fee pool.
func (r *StateRef) splitFee(feed uint64, amount int64) {
	f := mustFeed(feed)
	providerShare := amount * Param("feeSplitProvidersBps") / 10_000
	f.FeeAccrued += providerShare
	held.Pools += providerShare
	held.FeesPending += amount - providerShare
}

// splitSubscription routes a subscription or prepaid period: the provider
// share to the feed's long-lived pool, the rest to the pending fee pool.
func (r *StateRef) splitSubscription(feed uint64, amount int64) {
	f := mustFeed(feed)
	providerShare := amount * Param("feeSplitProvidersBps") / 10_000
	f.Pool += providerShare
	held.Pools += providerShare
	held.FeesPending += amount - providerShare
}

// ---- pools, rewards, tips

// BountyIn adds received coins to a feed's pool.
func (r *StateRef) BountyIn(feed uint64, amount int64) {
	r.check()
	if amount <= 0 {
		panic("core: amount must be positive")
	}
	r.inflow(amount)
	f := mustFeed(feed)
	f.Pool += amount
	held.Pools += amount
}

// DepositRefund returns a rejected request's deposit and escrowed
// prepayment to the proposer (as credit when the proposer is a realm).
func (r *StateRef) DepositRefund(feed uint64) {
	r.check()
	f := mustFeed(feed)
	amount := f.Deposit + f.Prepaid
	if amount == 0 {
		return
	}
	f.Deposit, f.Prepaid = 0, 0
	held.Deposits -= amount
	r.payProposer(f, amount)
	emit("DepositRefunded", "feed", u(feed), "amount", strconv.FormatInt(amount, 10))
}

// DepositToFees forfeits a feed's proposal deposit to the fee pool (spam);
// the escrowed prepayment still goes back to the proposer.
func (r *StateRef) DepositToFees(feed uint64) {
	r.check()
	f := mustFeed(feed)
	amount := f.Deposit
	f.Deposit = 0
	held.Deposits -= amount
	held.FeesPending += amount
	if pre := f.Prepaid; pre > 0 {
		f.Prepaid = 0
		held.Deposits -= pre
		r.payProposer(f, pre)
	}
}

// payProposer sends coins to the proposer, or credits a realm proposer.
func (r *StateRef) payProposer(f *Feed, amount int64) {
	if amount <= 0 {
		return
	}
	if f.FromRealm {
		// a realm cannot spend loose coins; give the money back as credit
		c := GetCredit(f.Proposer)
		if c == nil {
			c = &Credit{Addr: f.Proposer}
			credits.Set(string(f.Proposer), c)
		}
		c.Balance += amount
		held.Credits += amount
		return
	}
	r.send(f.Proposer, amount)
}

// FeedPoolRefund returns a one-off feed's undistributed bounty (pool and
// carry) to the proposer when the feed is retired; read fees stay for the
// fee pool.
func (r *StateRef) FeedPoolRefund(feed uint64) int64 {
	r.check()
	f := mustFeed(feed)
	amount := f.Pool + f.PenaltyCarry
	f.Pool, f.PenaltyCarry = 0, 0
	held.Pools -= amount
	r.payProposer(f, amount)
	if f.FeeAccrued > 0 {
		fees := f.FeeAccrued
		f.FeeAccrued = 0
		held.Pools -= fees
		held.FeesPending += fees
	}
	return amount
}

// CreditSpendOnFeed pays a feed proposal from a realm's credit: the deposit
// and the prepaid period or bounty are escrowed until activation.
func (r *StateRef) CreditSpendOnFeed(addr address, feed uint64, deposit, funding int64) {
	r.check()
	if deposit < 0 || funding < 0 {
		panic("core: amounts must not be negative")
	}
	c := GetCredit(addr)
	total := deposit + funding
	if c == nil || total <= 0 || c.Balance < total {
		panic("core: insufficient credit for the feed deposit and funding")
	}
	c.Balance -= total
	c.Spent += total
	held.Credits -= total
	f := mustFeed(feed)
	f.Deposit += deposit
	f.Prepaid += funding
	held.Deposits += total
}

// FeedPoolToFees moves a deprecated feed's remaining funds to the fee pool.
func (r *StateRef) FeedPoolToFees(feed uint64) int64 {
	r.check()
	f := mustFeed(feed)
	amount := f.Pool + f.FeeAccrued + f.PenaltyCarry
	f.Pool, f.FeeAccrued, f.PenaltyCarry = 0, 0, 0
	held.Pools -= amount
	held.FeesPending += amount
	return amount
}

// RoundPayout takes a round's pool from the feed's funds, credits each
// eligible provider an equal share, pays the cranker tip, and returns the
// pool actually distributed. Dust stays in the feed's carry.
func (r *StateRef) RoundPayout(feed uint64, eligible []address, cranker address) (pool, perProvider, tip int64) {
	r.check()
	f := mustFeed(feed)
	drip := f.Drip
	if f.Spec != nil && !f.Spec.IsRecurring() {
		drip = f.Pool
	}
	if drip > f.Pool {
		drip = f.Pool
	}
	pool = drip + f.FeeAccrued + f.PenaltyCarry
	f.Pool -= drip
	f.FeeAccrued = 0
	f.PenaltyCarry = 0
	if pool == 0 {
		return 0, 0, 0
	}
	tip = pool * Param("crankTipBps") / 10_000
	rest := pool - tip
	n := int64(len(eligible))
	if n == 0 {
		// nothing to pay: carry everything but the tip back to the feed
		f.PenaltyCarry += rest
		held.Pools -= tip
		if tip > 0 {
			r.send(cranker, tip)
		}
		return pool, 0, tip
	}
	perProvider = rest / n
	dust := rest - perProvider*n
	for _, addr := range eligible {
		p := mustProvider(feed, addr)
		p.Rewards += perProvider
		p.TotalEarned += perProvider
	}
	f.PenaltyCarry += dust
	f.TotalPaidOut += perProvider * n
	f.RoundsFinal++
	held.Pools -= perProvider*n + tip
	held.Rewards += perProvider * n
	if tip > 0 {
		r.send(cranker, tip)
	}
	return pool, perProvider, tip
}

// RewardPay pays a provider's accrued rewards.
func (r *StateRef) RewardPay(feed uint64, addr address) int64 {
	r.check()
	p := mustProvider(feed, addr)
	amount := p.Rewards
	if amount == 0 {
		return 0
	}
	p.Rewards = 0
	held.Rewards -= amount
	r.send(addr, amount)
	emit("RewardsClaimed", "feed", u(feed), "provider", string(addr), "amount", strconv.FormatInt(amount, 10))
	return amount
}

// MissSlash takes amount from a provider's stake for a missed round: the
// alerter share is paid to the alerter, the rest waits in the feed's carry.
func (r *StateRef) MissSlash(feed uint64, addr address, amount int64, alerter address) {
	r.check()
	if amount <= 0 {
		return
	}
	p := mustProvider(feed, addr)
	// unbonding stake stays slashable (plan §5.1)
	if amount > p.Stake+p.UnbondAmount {
		amount = p.Stake + p.UnbondAmount
	}
	if amount == 0 {
		return
	}
	fromStake := amount
	if fromStake > p.Stake {
		fromStake = p.Stake
	}
	p.Stake -= fromStake
	held.Stakes -= fromStake
	if rest := amount - fromStake; rest > 0 {
		p.UnbondAmount -= rest
		held.Unbonding -= rest
	}
	p.TotalSlashed += amount
	p.MissSlashedEpoch += amount
	alert := amount * Param("alerterShareBps") / 10_000
	carry := amount - alert
	f := mustFeed(feed)
	f.PenaltyCarry += carry
	held.Pools += carry
	if alert > 0 {
		r.send(alerter, alert)
	}
	emit("ProviderSlashed", "feed", u(feed), "provider", string(addr), "amount", strconv.FormatInt(amount, 10), "reason", "miss")
}

// ---- disputes

// NewDispute records a dispute with its bond already received.
func (r *StateRef) NewDispute(feed, round uint64, disputer address, bond, proposedValue int64, tier, evidence, evidenceHash string, priorValue int64, priorTier string) *DisputeRecord {
	r.check()
	if bond <= 0 {
		panic("core: bond must be positive")
	}
	id := uint64(disputeSeq.Next())
	d := &DisputeRecord{ID: id, Feed: feed, Round: round, Disputer: disputer, Bond: bond, ProposedValue: proposedValue,
		TierAsked: tier, Evidence: evidence, EvidenceHash: evidenceHash, OpenedAt: Now(), Status: DisputeOpen, BallotRound: 1,
		PriorValue: priorValue, PriorTier: priorTier}
	disputes.Set(u64key(id), d)
	r.inflow(bond)
	held.Bonds += bond
	emit("DisputeOpened", "dispute", u(id), "feed", u(feed), "round", u(round), "disputer", string(disputer),
		"bond", strconv.FormatInt(bond, 10), "proposedValue", strconv.FormatInt(proposedValue, 10), "tier", tier)
	return d
}

func mustDispute(id uint64) *DisputeRecord {
	d := GetDispute(id)
	if d == nil {
		panic("core: unknown dispute " + u(id))
	}
	return d
}

// DisputeSetDecided records a round-1 outcome and opens the appeal window.
func (r *StateRef) DisputeSetDecided(id uint64, outcome, tier string, coherent int64) {
	r.check()
	d := mustDispute(id)
	d.Status = DisputeDecided
	d.Outcome = outcome
	d.FirstOutcome = outcome
	d.TierDecided = tier
	d.CoherentW = coherent
	d.DecidedAt = Now()
	emit("DisputeDecided", "dispute", u(id), "round", "1", "outcome", outcome, "tier", tier)
}

// DisputeSetAppealed records an appeal bond and the second ballot round.
func (r *StateRef) DisputeSetAppealed(id uint64, appellant address, bond int64) {
	r.check()
	d := mustDispute(id)
	r.inflow(bond)
	d.Status = DisputeAppealed
	d.Appellant = appellant
	d.AppealBond = bond
	d.AppealAt = Now()
	d.BallotRound = 2
	held.Bonds += bond
	emit("AppealOpened", "dispute", u(id), "appellant", string(appellant), "bond", strconv.FormatInt(bond, 10))
}

// DisputeSetRolled records that the ballot rolled to a second round.
func (r *StateRef) DisputeSetRolled(id uint64) {
	r.check()
	d := mustDispute(id)
	d.Status = DisputeAppealed
	d.BallotRound = 2
	emit("DisputeRolled", "dispute", u(id))
}

// DisputeSetResolved records the applied outcome.
func (r *StateRef) DisputeSetResolved(id uint64, outcome, tier string, coherent, slashed int64) {
	r.check()
	d := mustDispute(id)
	d.Status = DisputeResolved
	d.Outcome = outcome
	d.TierDecided = tier
	d.CoherentW = coherent
	d.Slashed = slashed
	d.ResolvedAt = Now()
	emit("DisputeResolved", "dispute", u(id), "round", strconv.FormatInt(d.BallotRound, 10), "outcome", outcome, "tier", tier,
		"slashed", strconv.FormatInt(slashed, 10))
}

// BondRelease pays part of a held bond back to someone (the disputer, the
// appellant, or a provider) and reduces the Bonds category.
func (r *StateRef) BondRelease(id uint64, to address, amount int64) {
	r.check()
	if amount <= 0 {
		return
	}
	if amount > held.Bonds {
		panic("core: bond accounting short")
	}
	held.Bonds -= amount
	r.send(to, amount)
	emit("BondReleased", "dispute", u(id), "to", string(to), "amount", strconv.FormatInt(amount, 10))
}

// BondToPool credits part of a held bond to a feed's provider pool.
func (r *StateRef) BondToPool(id uint64, feed uint64, amount int64) {
	r.check()
	if amount <= 0 {
		return
	}
	if amount > held.Bonds {
		panic("core: bond accounting short")
	}
	held.Bonds -= amount
	mustFeed(feed).PenaltyCarry += amount
	held.Pools += amount
}

// BondToFees credits part of a held bond to the fee pool (treasury share).
func (r *StateRef) BondToFees(id uint64, amount int64) {
	r.check()
	if amount <= 0 {
		return
	}
	if amount > held.Bonds {
		panic("core: bond accounting short")
	}
	held.Bonds -= amount
	held.FeesPending += amount
}

// BondToVoters moves part of a held bond out of the Bonds category for
// FundVoters, which sends it to the DAO.
func (r *StateRef) BondToVoters(id uint64, amount int64) {
	r.check()
	if amount <= 0 {
		return
	}
	if amount > held.Bonds {
		panic("core: bond accounting short")
	}
	held.Bonds -= amount
	r.FundVoters(id, amount)
}

// SlashProvider takes bps of a provider's stake (or unbonding balance) after a
// lost dispute. At the major tier the provider is ejected: its slot is
// cleared and the rest of its stake starts unbonding. The slashed amount is
// moved to the Bonds category, from which the caller routes it. Returns the
// amount taken.
func (r *StateRef) SlashProvider(feed uint64, addr address, bps int64, tier string, fromRound uint64) int64 {
	r.check()
	p := GetProvider(feed, addr)
	if p == nil {
		return 0
	}
	amount := (p.Stake + p.UnbondAmount) * bps / 10_000
	if amount <= 0 {
		return 0
	}
	taken := int64(0)
	if p.Stake > 0 {
		x := amount
		if x > p.Stake {
			x = p.Stake
		}
		p.Stake -= x
		held.Stakes -= x
		taken += x
	}
	if rest := amount - taken; rest > 0 && p.UnbondAmount > 0 {
		if rest > p.UnbondAmount {
			rest = p.UnbondAmount
		}
		p.UnbondAmount -= rest
		held.Unbonding -= rest
		taken += rest
	}
	p.TotalSlashed += taken
	held.Bonds += taken
	if tier == "minor" {
		if Now()-p.EpochStart >= Param("providerEpoch") {
			p.MinorsEpoch, p.MissSlashedEpoch, p.EpochStart = 0, 0, Now()
		}
		p.MinorsEpoch++
	}
	emit("ProviderSlashed", "feed", u(feed), "provider", string(addr), "amount", strconv.FormatInt(taken, 10), "reason", "dispute-"+tier)
	if tier == "major" && (p.Status == ProviderActive || p.Status == ProviderJailed) {
		if p.Status == ProviderActive {
			f := mustFeed(feed)
			if p.Slot >= 0 && p.Slot < MaxSlots && f.SlotAt(int(p.Slot)) == addr {
				f.Slots = setCell(f.Slots, int(p.Slot), slotWidth, blankCell())
				f.ActiveCount--
				slotlog.Set(slotKey(feed, p.Slot, fromRound), address(""))
			}
		}
		if p.Stake > 0 {
			held.Stakes -= p.Stake
			held.Unbonding += p.Stake
			p.UnbondAmount += p.Stake
			p.Stake = 0
		}
		p.Status = ProviderUnbonding
		p.Slot = -1
		p.UnbondReadyAt = Now() + Param("unbondPeriod")
		emit("ProviderEjected", "feed", u(feed), "provider", string(addr))
	}
	return taken
}

// RoundOverturn replaces a round's value after a successful dispute and
// updates the served value when the round is the feed's latest.
func (r *StateRef) RoundOverturn(feed, id uint64, value int64) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.Value = value
	rd.Status = RoundAggregated
	rd.Tier = "final"
	rd.Overturned = true
	f := mustFeed(feed)
	if f.HaveFinal && f.FinalRound == id {
		f.FinalValue = value
	}
	if f.HaveValue && f.LastRound == id {
		f.LastValue = value
		f.LastTier = "final"
	}
}

// RoundVoid marks a round void after a dispute; a voided latest round leaves
// the feed without a served value.
func (r *StateRef) RoundVoid(feed, id uint64) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.Status = RoundVoid
	rd.Tier = "void"
	f := mustFeed(feed)
	if f.HaveValue && f.LastRound == id {
		f.LastTier = "void"
	}
}

// RoundRestartWindow returns an upheld round to its prior tier with a fresh
// dispute window.
func (r *StateRef) RoundRestartWindow(feed, id uint64, tier string) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.Status = RoundAggregated
	rd.Tier = tier
	rd.FinalisedAt = Now()
	f := mustFeed(feed)
	if f.HaveValue && f.LastRound == id {
		f.LastTier = tier
		f.LastFinalAt = Now()
	}
}

// RoundMarkDisputed links a round to its dispute while the ballot runs.
func (r *StateRef) RoundMarkDisputed(feed, id uint64, disputeID uint64) {
	r.check()
	rd := GetRound(feed, id)
	if rd == nil {
		panic("core: unknown round")
	}
	rd.DisputeID = disputeID
	rd.Tier = "disputed"
	f := mustFeed(feed)
	if f.HaveValue && f.LastRound == id {
		f.LastTier = "disputed"
	}
}

func blankCell() string {
	b := make([]byte, slotWidth)
	for i := range b {
		b[i] = ' '
	}
	return string(b)
}

// ---- trusted requesters

func setTrusted(pkgPath string, cap int64) {
	if cap < 0 {
		panic("core: negative cap")
	}
	if cap == 0 {
		trusted.Remove(pkgPath)
	} else {
		trusted.Set(pkgPath, cap)
	}
	emit("TrustedRequester", "path", pkgPath, "cap", strconv.FormatInt(cap, 10))
}

// ---- helpers

func u(v uint64) string { return strconv.FormatUint(v, 10) }

func popcount(m uint32) int {
	n := 0
	for m != 0 {
		m &= m - 1
		n++
	}
	return n
}

func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }
