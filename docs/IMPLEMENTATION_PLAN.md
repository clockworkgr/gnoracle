# Gnoracle: an Oracle DAO on gno.land. Implementation plan

Status: v0.4, 2026-09-23 (all owner decisions applied except operators). Companion documents: `docs/RESEARCH.md` (verified facts
and sources) and `docs/ORACLE_NETWORKS_RESEARCH.md` (raw pass on incumbent
oracles with about 190 citations). Where this plan states a number, the
rationale is next to it, and the number is a DAO parameter unless marked
"fixed".

Changes from v0.1: upgradeability now uses `gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0` (your package, already deployed on gnoland-1 together with `app/v0`)
(permanent realms, nested implementation realms, gated state); the front realm
and the migration machinery are gone. Parameters were re-derived from the
oracle-networks research: higher provider stake minima with a published USD
target, two slash tiers, a 60% supermajority with a void fallback and one
appeal round, a per-address vote cap, subscriptions as the primary revenue,
and a capped bootstrap subsidy.

---

## 0. What changed from the brief, and why

The brief is sound. Five points needed adjusting after checking gno.land,
Kourt and the incumbent oracle networks as they exist today.

1. **Kourt does not slash minority voters.** It withholds a small minted reward
   from them, burns the bonds of losing litigants, and its own design record
   rejects loser slashing (RESEARCH §2.4). The systems that do slash absent or
   incoherent voters are UMA (0.1% of stake per vote, redistributed to correct
   voters), Kleros and Aragon Court. This plan implements the brief's
   penalties with UMA's shape and Kourt's snapshot and lock discipline, and
   makes both rates DAO parameters that can be set to zero if the DAO later
   prefers Kourt's no-slash posture.
2. **Members are token stakers, not token holders.** A tradeable GRC20 will sit
   in Gnoswap pools, custodial wallets and idle accounts that cannot vote, and
   slashing raw balances would break every pool the token is in. Anyone may
   hold PYTH; only PYTH staked into the DAO carries fee share, voting power and
   the duty to vote. UMA 2.0 and Kourt key obligations to committed coin the
   same way.
3. **Nothing runs on a timer on gno.land.** Every deadline is evaluated lazily
   inside transactions, so every transition is a public crank with a tip, and
   every per-member computation is bounded and cursor-based.
4. **Kourt is a court of record, not a database.** "Persisting a dispute
   outcome in Kourt" means filing a claim in a Kourt court the DAO controls,
   staking on it, posting the bonded answer and letting it settle after 72 h.
   Kourt holders may contest it, which the plan treats as a public second
   opinion and a v2 appeal trigger.
5. **Slashing is a deterrent that almost never fires, and small stakes get
   exploited.** Across Pyth Network, Chainlink, API3 and Tellor Layer no provider
   slash has executed in years; UMA's 0.1% voter slash is the only one that
   fires routinely. Meanwhile a $150 Tellor Layer stake was enough to attack
   BonqDAO for about $120M nominal, and UMA raised its supermajority to 65%
   after single holders cast about 25% of dispute votes (RESEARCH §3.2). The
   plan therefore has a small slash tier that will actually be used and a
   100% tier as the deterrent, a provider stake floor with a USD target, a
   supermajority that makes an attacker win rather than deadlock, and a
   per-address vote cap.

Everything else in the brief maps directly: feed requests with a config, DAO
acceptance, feed IDs any realm can read, providers staking GNOT, slashing for
missed or wrong updates, fee rewards to providers and to DAO stakers, disputes
settled by DAO members, and a tradeable DAO token.

---

## 1. Goals and non-goals

Goals

- A permissionless request path: any account or realm proposes a feed by
  submitting a JSON spec and a deposit; DAO stakers vote to accept.
- Feeds usable by any realm through one permanent import path, with a status
  field that tells the consumer whether a value is consensus, provisional or
  final.
- Provider set per feed, bonded in GNOT, rewarded from subscriptions, metered
  reads and bounties, penalised for missed rounds, slashed after a lost
  dispute.
- Disputes bonded in GNOT, decided by PYTH stakers under commit-reveal with
  sealed voting weights, a supermajority, one appeal round, and penalties for
  absence and incoherence.
- Every dispute outcome mirrored as a settled claim in a Kourt court.
- PYTH: a standard GRC20, registered, listable on Gnoswap on day one.
- Logic upgradeable behind permanent realms under DAO control, with rollback
  and freeze; state and money primitives never move.
- All economics in `int64` with overflow checks; all loops bounded; all
  payouts pull-based; all settled state prunable with the deposit refund going
  to the pruner.

Non-goals for v1

- Off-chain aggregation networks (OCR-style signed reports). Providers submit
  individually; the realm aggregates.
- Random juror sampling. No VRF on gno.land; all obligated members vote.
- Cross-chain data or IBC delivery. Consumers are gno.land realms.
- A web frontend beyond gnoweb `Render` pages. The gnomarket web stack can host
  one later.
- Deviation-triggered updates. v1 rounds are time-based; v1.1 adds
  provider-initiated extra rounds on deviation.

---

## 2. Actors and the shape of the system

```
 Requester ──proposes feed spec + deposit──► DAO (PYTH stakers) ──accept──► Feed #id
                                                                             │
 Sponsors ──monthly subscription──────────────────────────────────────────► feed pool
 Providers ──stake GNOT, submit values each round──────────────────────────► rounds
                                                                             │ aggregate (median / majority), status tier
 Consumer realm ──Read(feed), pays metered credit──────────────────────────► value + status
                                                                             │
 Disputer ──bond GNOT, propose corrected value + slash tier──► dispute ──commit/reveal──► DAO verdict (+ appeal)
                                                                             │
                              slash wrong providers, pay disputer and coherent voters
                                                                             │
                                          Kourt adapter files, stakes, answers, settles a claim
```

| Role | Capital | Earns | Risks |
|---|---|---|---|
| Requester | feed deposit (GNOT), first subscription period | a live feed | deposit becomes the first subscription on acceptance; refunded on rejection |
| Sponsor | monthly subscription per feed (shared) | fresh-tier access for named consumer realms | none beyond the fee |
| Provider | GNOT stake per feed | share of the feed's round pool, alerter and cranker tips | miss penalties, jail, minor (5%) or major (100%) slash after a lost dispute |
| Consumer realm | prepaid GNOT credits | data | none beyond fees |
| Disputer | GNOT bond | bond back plus 50% of what the losing providers forfeit | bond if the DAO upholds the value |
| DAO member (PYTH staker) | staked PYTH | 15% of protocol fees, 30% of forfeitures on disputes they voted coherently on | absence and incoherence penalties, unstake cooldown |
| PYTH holder (not staked) | PYTH | price exposure only | none |
| DAO treasury | GNOT and PYTH | 20% of forfeitures, 15% of fees, spam deposits | spends only by proposal (voter gas rebates, watcher bounties, bootstrap subsidy) |

---

## 3. Architecture

### 3.1 Repository layout

Matches `gno-contracts` and `clockwork-gno-home` conventions (RESEARCH §5).

```
gnoracle/
  gnowork.toml
  Makefile                                   # toolchain (pinned v1.2.0), test, lint, fmt, dev, deploy, accept, render
  scripts/                                   # env.sh, deploy.sh, deps.sh, dev-keys.sh from clockwork-gno-home
  p/spec/        gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/spec/v0         # feed spec JSON parse and validation, canonical text
  p/agg/         gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/agg/v0          # median, majority, tolerance, status tier, 128-bit mulDiv
  p/rounds/      gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/rounds/v0       # round arithmetic from block time, window checks
  p/ledger/      gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/ledger/v0       # balances, reward-per-share accumulators, unbonding queue
  p/checkpoint/  gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/checkpoint/v0   # epoch checkpoints of a per-address int64
  p/tally/       gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/tally/v0        # commit hashes, weighted tally with caps, penalty math
  p/params/      gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/params/v0       # typed parameter registry with bounds and rate limits
  r/token/       gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/token           # PYTH GRC20 (permanent, not upgradeable)
  r/core/        gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/core            # PERMANENT: interface, state, gated store, proxy, typed entry points
                 gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/core/impl/v1    # implementation: feeds, providers, rounds, credits, disputes
  r/dao/         gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/dao             # PERMANENT: interface, state, gated store, proxy, entry points
                 gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/dao/impl/v1     # implementation: staking, proposals, ballots, penalties, treasury
  r/kourt/       gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/kourt           # PERMANENT: record state, court-coin float, proxy
                 gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/kourt/impl/v1   # implementation bound to one Kourt realm path
  agent/                                      # Go: provider daemon (gnoclient), source adapters
  bot/                                        # Go: dispute and deadline notifier, cranker (Telegram; reuses telegram-bots)
  sim/                                        # Go: economic simulation over the parameter table
  docs/
```

Pure packages hold the logic that does not touch realm state and almost all
the unit tests. Permanent realms own state, money primitives, authentication
and events. Implementation realms hold the decision logic and are the unit of
upgrade.

### 3.2 Upgradeability with `gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0`

The three stateful realms (`core`, `dao`, `kourt`) follow the typed-proxy
pattern from `gno-contracts/docs/proxy.md`, importing the package at its
mainnet path `gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0` (verified deployed on 2026-09-23; pearl-1 needs a
deploy of the same source under the same address).

- **Interface in the permanent realm.** `core` declares `type Core interface {
  Submit(_ int, rlm realm, feedID, roundID uint64, value int64) ... }` and so
  on for every entry point, in non-crossing `(_ int, rlm realm, ...)` form. The
  permanent realm threads its own `cur` into the live implementation as data,
  so the implementation runs with the permanent realm's identity and every
  version sees one type identity.
- **State in the permanent realm.** Every table in §4.4 is a package variable
  of the permanent realm. Implementations never hold state; an upgrade
  changes behaviour, never storage. Schema growth is by adding new tables or
  optional fields in the permanent realm's own extension realms (below), never
  by rewriting existing objects.
- **Gated store.** `Store(_ int, rlm realm) *StateRef` returns an accessor
  that re-checks `rlm.IsCurrent()` and that `rlm.PkgPath()` is the permanent
  realm or a registered extension on every operation. Because it holds a
  realm value it cannot be persisted, so a rolled-back or frozen
  implementation loses access at the end of its own call. Every mutator on
  `StateRef` is typed and enforces conservation: `MoveStakeToPool`,
  `SlashProvider(feedID, addr, bps, reason)`, `DebitCredit`, `PayOut(to,
  amount)`, `LockBond`, `ReleaseBond`. Amounts are checked against the
  invariants in §10.2 inside the permanent realm, so a buggy or malicious
  implementation can misjudge a dispute but cannot mint, overdraw or drain.
- **Money primitives in permanent code.** Receiving ugnot (`OriginSend` under
  `IsUserCall`), sending ugnot (the realm's `RealmSend` banker), pulling and
  paying PYTH through `token`'s tellers, and the balance tables live in the
  permanent realm and are not upgradeable. Implementations request movements
  through `StateRef`; they never see a banker or a `cur`.
- **Proxy and authority.** `proxy = upgradeable.New(upgradeable.NewAnyOf(
  upgradeable.NewAddrAuthority(guardian), upgradeable.NewRealmAuthority(daoPath)))`
  at bootstrap. Implementation realms are nested (`core/impl/v1`), so the
  default `New` (nested only) applies. An implementation registers itself in
  its `init`: `core.Register(cross(cur), &implV1{})`, which calls
  `proxy.Propose`. Acceptance is `core.Accept(cross(cur), path)` executed by a
  DAO proposal (`upgrade-accept`, 66%, 7-day timelock) or, during bootstrap,
  by the guardian. `Rollback` reverts to the previous release (`upgrade-
  rollback`, 50%, 24 h, and guardian during bootstrap). `Freeze` is
  irreversible (`freeze`, 75%). At guardian handover the DAO executes
  `TransferAuthority(NewRealmAuthority(daoPath))`, after which only proposals
  can change the live release.
- **Typed entry points, frozen.** The permanent realm's exported crossing
  functions are the consumer and provider API forever. The API grows through
  extension realms (`proxy.AddExtension`, e.g. `core/ext/v1` for
  deviation-triggered rounds), which reach state through the same gate.
  Anything that might change is a string payload (feed spec JSON, proposal
  payloads, dispute evidence), which is also what `MsgCall` needs.
- **Self-upgrade goes through `dao/exec`.** The proxy authorizes by the realm
  that crossed in and a realm cannot cross into itself, so a passed proposal
  that changes the DAO's own release calls the tiny `dao/exec` trampoline,
  which calls straight back into the DAO's proxy entry points; the trampoline
  acts only when the DAO realm is its caller, and the DAO's authority is
  `AnyOf(guardian, exec)` until handover leaves `exec` alone.
- **`token` is not upgradeable.** A GRC20 ledger's value is its permanence;
  mint and burn authority is `ownable`, transferred to the `dao` permanent
  realm at bootstrap.

Why this and not a pull-based migration: state never moves, consumers import
one path forever, provider stakes and credits are untouched by upgrades, and
the DAO can roll back a bad release in one transaction. The cost is that
entry-point signatures and the storage layout are permanent, which the design
accepts by keeping both small and by pushing variability into JSON payloads
and extension realms.

Trust statement for the docs: an upgradeable implementation sits in front of
escrowed funds. What bounds it is (a) the gated store with conservation checks
in permanent code, (b) DAO-only acceptance with a 7-day timelock and a public
`Pending()` list, (c) one-transaction rollback, (d) freeze, and (e) the
invariants in §10.2 asserted by a permanent `Health()` view that anyone can
query before and after an upgrade.

### 3.3 Realm responsibilities and trust boundaries

| Permanent realm | Holds | Trusts | Called by |
|---|---|---|---|
| `token` | PYTH ledger | nobody; standard GRC20 | anyone |
| `dao` | staked PYTH (its own address), PYTH treasury, GNOT treasury sub-account, ballots, proposals, member records | `core` for dispute open and resolve callbacks (by pkgpath), `token` tellers | members, core |
| `core` | provider stakes, consumer credits, subscription pools, dispute bonds, round pools (GNOT at its address), feeds, rounds, submissions, disputes | `dao` for verdicts and parameter reads | providers, consumers, sponsors, disputers, crankers |
| `kourt` | court-coin float, mirror records | `core` (callbacks), the DAO authority | core, crankers |

Design rules

- No realm ever passes its `cur` or a banker to another realm. All value
  movement is explicit: ugnot via a `RealmSend` banker at the sender, PYTH via
  `RealmTeller.TransferFrom` after an allowance.
- A consumer read path touches `core` only and never calls back into the
  consumer. A provider submission path touches `core` only.
- `dao` and `core` reference each other by package path constants and by
  address. The only cross-realm interface value stored is `core`'s active
  Kourt adapter, and the Kourt realm is called only from the adapter's crank,
  never inside `core`'s hot paths; a panic there marks the mirror record
  `Failed` and never aborts a resolution.
- Every public state transition is callable by anyone once its preconditions
  hold (crank functions), and pays the cranker a tip from the pool it settles.

---

## 4. Feeds

### 4.1 Feed spec

Submitted as one JSON string (MsgCall arguments are primitives only). Parsed
and validated on-chain by `p/spec`, then stored as typed fields; the original
text is kept as `specText` and hashed (`sha256`) into `specHash`, which every
submission, dispute and Kourt claim references. Editing a spec is a new feed;
economic fields can be changed by `feed-update` proposals.

```json
{
  "name": "GNOT/USD",
  "description": "Spot price of GNOT in USD.",
  "kind": "recurring",
  "valueType": "numeric",
  "decimals": 6,
  "interval": 3600,
  "submitWindow": 600,
  "sources": "Median of Gnoswap GNOT/wugnot-USDC TWAP (30 min) and any two of Coinbase, Kraken, Binance spot at round start. Round start is the Unix time floor to the hour.",
  "minProviders": 3,
  "maxProviders": 9,
  "providerMinStake": 25000000000,
  "toleranceBps": 100,
  "quarantineBps": 1000,
  "disputeWindow": 43200,
  "readPrice": 20000,
  "subscriptionPrice": 1000000000,
  "tags": ["price", "gnot"]
}
```

One-off variant: `"kind": "oneoff"`, `"resolveAt": <unix>`, `"submitWindow":
86400`, `"valueType": "categorical"`, `"options": ["Yes", "No", "Invalid"]`,
`"disputeWindow": 259200`, `"bounty": <ugnot>` instead of a subscription.

Validation (fixed rules)

- `valueType` in {numeric, categorical}; numeric needs `decimals` 0..18;
  categorical needs 2..16 options, each at most 64 bytes.
- `interval` in [60 s, 30 d]; `submitWindow` in [60 s, interval];
  `disputeWindow` in [2 h, 14 d]; one-off `resolveAt` at least 1 h ahead and
  at most 2 years.
- `minProviders` in [1, maxProviders]; `maxProviders` at most 15 (fixed; this
  bounds every per-round loop).
- `providerMinStake` at least the DAO-wide floor (`providerMinStakeFloor`).
  Decision: launch at 10,000 GNOT (about $620) and rise on a published
  schedule (`stakeFloorSchedule`: 15,000 GNOT after 90 days, 25,000 GNOT after
  180 days, each step a `param` proposal the DAO can delay but that the
  checklist assumes). The DAO publishes a USD target per feed class ($1,500 for
  price feeds, Tellor's figure) that the acceptance checklist compares against
  and that `maxValueAtRisk` reflects.
- `toleranceBps` in [1, 5000]; `quarantineBps` in [toleranceBps, 10000].
- `readPrice` at least `readPriceFloor` (default 0.002 GNOT) or zero for a
  sponsored feed; `subscriptionPrice` at least `subscriptionFloor` (default
  100 GNOT per 30 d).
- `sources` at most 2000 bytes; `name` at most 64; `description` at most 512.
  A spec is 1 to 3 kB, so 0.1 to 0.3 GNOT of storage deposit paid by the
  requester and refunded if the feed is ever pruned.

### 4.2 Lifecycle

```
Proposed ──DAO accept──► Active ──pool empty for a period──► Unfunded ──sponsor pays──► Active
    │                       │
    └──reject / expiry      └──DAO deprecate, or one-off finalised──► Deprecated ──prune after retention──► (deleted)
```

- `ProposeFeed(cur, specJSON string) (feedID)`: requires the feed deposit
  (`feedDeposit`, default 5 GNOT) plus the first subscription period (or the
  one-off bounty) as `-send`. Creates a governance proposal of kind
  `feed-accept`. Emits `FeedProposed`.
- Accept: the prepaid subscription funds the feed's pool; the feed becomes
  `Active` with `startAt` = execution time rounded up to the next interval;
  the deposit is refunded.
- Trusted requesters (decided): a one-off feed proposed by a realm on the
  `trustedRequesters` list (set by `trusted-requester` proposals) activates
  immediately without a vote when its bounty is at least `oneOffBountyFloor`
  and the requester's declared value at stake is under `trustedOneOffCap`
  (default 50,000 GNOT); the DAO can still `feed-deprecate` it, and a
  requester whose feeds are deprecated twice is removed from the list. This
  is the path gnomarket markets use (§6.3).
- Reject or no quorum after the voting period: deposit and prepayment
  refunded minus the proposal's storage cost. The DAO may instead mark a
  proposal spam, in which case the deposit goes to the treasury.
- Unfunded: when the subscription pool cannot cover the next period,
  providers keep submitting if they want (rounds still aggregate) but miss
  penalties stop, and the status reported to consumers carries `unfunded`.
  Any sponsor payment reactivates it.
- Deprecate: by proposal, or automatically when a one-off feed's round is
  final, or when a recurring feed has had no eligible submissions for
  `deadFeedRounds` (default 168) and anyone calls `PruneFeed`.
- Prune: after `retentionAfterDeprecate` (default 90 d) anyone may delete
  rounds and then the feed; the storage refund goes to the caller.

### 4.3 Rounds, aggregation and status tiers

`p/rounds` derives everything from the spec and block time; nothing is
scheduled.

- Recurring: `roundID = (now - startAt) / interval`, round `r` opens at
  `startAt + r*interval`, submissions accepted until `open + submitWindow`.
- One-off: a single round `0`, opens at `resolveAt`, closes at `resolveAt +
  submitWindow`.
- `Finalize(cur, feedID, roundID)`: callable by anyone after the window
  closes, or by the last expected provider before it. Iterates the active
  provider set (at most 15): records misses, computes the aggregate, marks
  eligibility, assigns the status tier, credits the round pool, pays the
  cranker and alerter tips. One round per call; `CatchUp(feedID, n)` writes
  off up to `maxCatchUpRounds` (48) stale rounds as `Skipped`.
- Aggregation (`p/agg`):
  - numeric: median of submitted values (even count: lower median, so the
    result is always a submitted value); eligibility: within `toleranceBps`
    of the median.
  - categorical: option with the most submissions; ties: `Empty` (no value);
    eligibility: equal to the winning option.
- Status tiers (Tellor Layer's two-tier rule adapted to equal-weight
  providers):
  - `consensus`: at least `minProviders` eligible, at least two thirds of the
    active set eligible, and the median moved at most `quarantineBps` from
    the last final value. Usable immediately.
  - `provisional`: aggregated but thin, divergent, or a large move. Usable at
    the consumer's own risk until the dispute window passes.
  - `final`: dispute window passed with no dispute, or a dispute resolved to
    uphold or overturn.
  - `disputed`, `overturned`, `void`, `empty`, `skipped` as named.
- Equal-weight median is deliberate: each provider slot costs the same stake,
  so weight buys nothing but exposure. Stake-weighted median with a 30% cap
  (Tellor Layer) is a v2 option once stake sizes diverge.

### 4.4 Storage model (permanent `core` realm)

bptree keys are fixed-width big-endian so ranges scan in order.

| Table | Key | Value (approx bytes) |
|---|---|---|
| `feeds` | feedID (8) | Feed{spec fields, status, startAt, counters, subscription pool, sponsors count} (~600 + spec text) |
| `sponsors` | feedID (8) + addr | Sponsor{paidUntil, consumers allowlist hash} (~60) |
| `providers` | feedID (8) + addr | Provider{stake, slot, status, consecutiveMisses, strikes, minorsInEpoch, lastRound, unbondAt, rewardCursor} (~140) |
| `activeSet` | feedID (8) + slot (1) | addr (at most 15) |
| `rounds` | feedID (8) + roundID (8) | Round{status, tier, value, submittedMask, eligibleMask, pool, finalisedAt, disputeID} (~110) |
| `submissions` | feedID + roundID + slot (1) | value int64 + submittedAt (~24) |
| `credits` | consumer addr | Credit{balance, spentTotal, lastRead, finalOnly} (~48) |
| `disputes` | disputeID (8) | Dispute{feedID, roundID, disputer, bond, proposedValue, tier, round, state, daoBallotID, kourtRecordID, outcome} (~220) |
| `params` | name | typed value with bounds and last-change height |

Submitters and eligibility are bitmasks over the active set's slot index. A
slot is retired when its provider leaves and reused only after every round
referencing it is pruned (slot generation counter).

Per hourly feed with 9 providers, steady-state growth is about 7.6 kB per day
(0.76 GNOT of deposit across all submitters), refunded on prune. Retention:
`roundRetention` 30 d after finality and at least 64 rounds.

---

## 5. Providers

### 5.1 Lifecycle

```
(none) ──Register + stake──► Active ──miss x jailAfterMisses──► Jailed ──Unjail after cooldown──► Active
            │                    │
            │                    └──RequestUnbond──► Unbonding ──after unbondPeriod──► Withdrawn
            └── major slash or DAO removal ─────────────────────► Unbonding (forced, ejected)
```

- `Register(cur, feedID)`: `-send` at least `providerMinStake` in ugnot under
  `cur.Previous().IsUserCall()`; the feed must be Active or Unfunded with
  fewer than `maxProviders` active providers. Emits `ProviderRegistered`.
- `TopUp(cur, feedID)` adds stake. `RequestUnbond(cur, feedID)` leaves the
  active set immediately and starts the clock. `Withdraw(cur, feedID)` pays
  out after `unbondPeriod` (default 14 d, Tellor Layer and Chainlink are 21
  and 28; it must exceed a dispute window plus two voting rounds plus the
  appeal gap) minus any slash applied meanwhile. Unbonding stake stays
  slashable, which is what makes the dispute window meaningful.
- `Submit(cur, feedID, roundID, value int64)`: Active provider, round open,
  one submission per provider per round (resubmission inside the window
  overwrites). Emits `Submitted`.
- Jail: `consecutiveMisses >= jailAfterMisses` (default 3; one-off feeds jail
  on the single miss). Jailed providers are out of the active set, earn
  nothing, keep their stake, and may `Unjail` after `jailCooldown` (24 h).
  Three jailings in 30 days force unbonding.

### 5.2 Penalties and rewards

| Event | Effect | Default | Where the money goes |
|---|---|---|---|
| Missed round (funded feed) | slash `missSlashBps` of stake | 50 bps (0.5%), capped at 5% per provider per 7-day epoch | 50% to the alerter (whoever ran `Finalize` and recorded the miss), 50% to the feed's next round pool |
| Outside tolerance, no dispute | no reward, one strike; `strikesToJail` strikes in `strikeWindowRounds` jails | 5 in 100 rounds | nothing moves |
| Lost dispute, minor tier | slash `minorSlashBps` of stake | 500 bps (5%) | 50% disputer, 30% coherent voters, 20% treasury |
| Lost dispute, major tier | slash `majorSlashBps` and forced unbond (ejection) | 10000 bps (100%) | same split |
| Three minor slashes within an epoch | escalates to major | fixed | same split |
| Eligible submission in a finalised round | equal share of the round pool | pool = subscription pool / rounds per period + 70% of metered read fees since the last finalisation + miss slashes + one-off bounty share + bootstrap subsidy | provider reward balance (pull) |
| Finalising a round | tip | `crankTipBps` 100 (1%) of the round pool | cranker |

Why two tiers: Tellor Layer's 1/5/100% tiers are the only provider-slash
schedule with a record, and all 13 of its disputes landed in the small tier;
Pyth Network's 5% cap and Chainlink's 700 LINK have never fired. The 5% tier is what
gets used for stale, sloppy or marginally wrong values; the 100% tier plus
ejection is the deterrent for fabricated values. The disputer names the tier
when opening; voters can downgrade a major to a minor (§7.2) but not upgrade,
so the bond risked always matches the harm alleged.

Why 0.5% per miss with an alerter share: Chainlink pays the alerter about a
third of the slash and only after 3 h of downtime; on a chain with no cron
the alerter is the liveness mechanism, so the share is half and the trigger
is one missed round. The 5% per epoch cap keeps a provider whose upstream
died over a weekend from losing more than an honest error should cost.

Rewards are claimed with `ClaimRewards(cur, feedID, maxRounds)`, which walks
the provider's rounds from `rewardCursor` (bounded by `maxRounds`, default
50). Rounds older than `roundRetention` whose rewards were never claimed
forfeit them to the treasury on prune, which is what lets pruning be
permissionless.

### 5.3 Value at risk shown to consumers

`FeedInfo(feedID)` and the feed page report `securityBudget = Σ active stake
x majorSlashBps / 10000`, `corruptionThreshold = ceil(n/2)` providers, and
`maxValueAtRisk = 50% x securityBudget x corruptionThreshold / n` (the
research pass's rule of thumb from UMA's cost-of-corruption > profit-from-
corruption). Consumers are told to keep the value a single provisional read
controls below that figure, or to wait for `final`.

---

## 6. Consumers, sponsors and fees

### 6.1 Reading

Consumer realms import the permanent `core` realm and call:

```go
func Read(cur realm, feedID uint64) (value int64, decimals int, roundID uint64, updatedAt int64, tier string)
func ReadOption(cur realm, feedID uint64) (option int, label string, roundID uint64, updatedAt int64, tier string)
func ReadRound(cur realm, feedID, roundID uint64) (value int64, tier string, finalisedAt int64)
func FeedInfo(feedID uint64) string        // JSON view, no fresh values
```

`Read` is a crossing call because it debits the caller's credit and writes.
The returned `tier` is `consensus`, `provisional`, `final`, `disputed`,
`stale` (no aggregated round within two intervals), `unfunded` (appended,
e.g. `final,unfunded`) or `none`. A consumer that sets `finalOnly` on its
credit record receives the latest `final` round instead and pays half price.

Free access exists and is bounded on purpose: `Render` and `FeedInfo` are
non-crossing and any realm or `vm/qeval` can call them, so they show values
only once `final` and at least `renderDelay` (default 10 minutes, Pyth Network Pro's
delayed-tier convention) old. Fresh data costs a credit; delayed data is a
public good. One-off outcomes become public once final, which a court of
record implies anyway; requesters pay for those through the bounty.

### 6.2 Paying

Subscriptions are the primary revenue because they are the only model that
has demonstrably reached sustainability (Chainlink feeds on BNB and Polygon,
Pyth Network Pro; RESEARCH §3.2). Metered reads are secondary.

- `Sponsor(cur, feedID, periods)`: `-send` `subscriptionPrice x periods`
  (default 1,000 GNOT per 30 d per feed, about $62). Several sponsors may
  pay for the same feed; each period's cost is split evenly among that
  period's sponsors and the surplus rolls forward. A sponsor names up to 8
  consumer realm addresses whose metered reads on that feed are free.
- `DepositFor(cur, consumer address)`: `-send` ugnot credits a consumer realm
  for metered reads (a realm cannot attach `-send` to its own calls; the
  call-scoped `CallSend` RFC of 2026-09-19 would change that and is tracked).
  Each `Read` by a non-sponsored consumer debits `readPrice` (default 0.02
  GNOT).
- Fee split (fixed at the time of each payment): 70% to the feed's round
  pool, 15% to the DAO staker accumulator, 15% to the treasury (which funds
  voter gas rebates, watcher bounties and the bootstrap subsidy).
- Bootstrap subsidy: the treasury may fund a provider subsidy per feed, only
  for feeds with at least one paying sponsor, capped at a fixed budget for 12
  months and decaying 10% per month (Pyth Network's finite pool ran out in 19 months
  with no fee replacement; this one is tied to real demand from day one).

### 6.3 gnomarket as the first consumer

The gnomarket plan's resolver becomes a client of this DAO: a market question
is a one-off categorical feed (`options` = the market outcomes plus
`Invalid`), `resolveAfter` becomes `resolveAt`, the market creator pays the
bounty, the market realm is on the `trustedRequesters` list so the feed
activates without a vote while under `trustedOneOffCap`, and the market realm
calls `ReadOption` once the tier is `final`. The gnomarket dispute path is replaced by this DAO's; its
"TOO_EARLY" case becomes a `VOID` outcome followed by `ReopenOneOff`.

---

## 7. Disputes

### 7.1 Opening

`Dispute(cur, feedID, roundID, proposedValue int64, tier string, evidence
string)` with `-send` of the bond in ugnot.

- Allowed while the round is `consensus` or `provisional` inside
  `disputeWindow` (default 12 h for recurring feeds: between UMA/Polymarket's
  2 h with bots and Tellor's 12 h with humans, to be lowered once at least
  three independent watcher bots exist; 72 h for one-off outcomes, Kourt's
  settle delay). One open dispute per round.
- `proposedValue` is what the disputer says the round should have been (the
  option index for categorical feeds); `tier` is `minor` or `major` (§5.2).
- `evidence` at most 1024 bytes; its `sha256` goes into the record and the
  Kourt claim body.
- Bond: `max(minDisputeBond, disputeBondBps x Σ active provider stake)`,
  defaults 2,500 GNOT (about $150, Tellor 360's `stakeAmount/10`) and 1000
  bps. Repeat disputes on the same feed within `disputeEscalationWindow`
  (7 d) double the bond (Tellor and Kourt doubling). v1.1 adds crowdfunding
  of a bond within 24 h (Tellor Layer).
- Opening calls `dao.OpenDisputeVote(cross(cur), disputeID, summary)`, which
  seals the electorate at the previous epoch. The round becomes `disputed`
  and its value is quarantined: `Read` returns the last `final` round with
  tier `disputed` until resolution. Emits `DisputeOpened`.

### 7.2 Ballot

Choices, fixed: `UPHOLD`, `OVERTURN`, `OVERTURN_MINOR` (only when the
disputer asked for `major`), `VOID` (the round cannot be resolved as
specified: ambiguous spec, source unavailable, too early), `ABSTAIN`.

- Commit phase `commitPeriod` (default 24 h): `CommitVote(cur, disputeID,
  commitment)` with `commitment = hex(sha256(disputeID || choice || salt ||
  voter))`. Recommitting overwrites.
- Reveal phase `revealPeriod` (default 24 h): `RevealVote(cur, disputeID,
  choice, salt)`. UMA's 24 h + 24 h reaches about 92% participation with
  slashing; Aragon uses 2 d + 2 d.
- Weight = `min(stakedAt(voter, sealedEpoch), stakedNow(voter))` (Kourt's
  rule), then capped so that no single address counts for more than
  `maxVoterShareBps` (default 2000, 20%) of the revealed weight (the cap is
  applied at tally time by clipping the largest reveals; UMA's March 2025
  vote had one holder at 25%). The cap is gameable by splitting, which is why
  it is paired with the supermajority and the appeal.
- Obligated set = members with positive weight at the sealed epoch. There is
  no exclusion of interested parties as in Kourt: a member who is also a
  provider or the disputer has information; their conflict is public and
  their vote slashable like any other.

### 7.3 Tally, appeal and outcome

`ResolveDispute(cur, disputeID)`: anyone, after the reveal phase.

Round 1

- Quorum: revealed weight (including `ABSTAIN`) at least `disputeQuorumBps`
  (3300) of the obligated weight.
- If `VOID` holds a strict majority of the non-abstain weight, outcome `VOID`.
- Otherwise let `O = OVERTURN + OVERTURN_MINOR`, `U = UPHOLD`. A side wins
  with at least `decisionBps` (6000) of `O + U` (UMA raised its SPAT to 65%
  after the whale episodes; 60% is the plan's start because every member is
  obligated). If `O` wins, the tier is `major` if `OVERTURN > OVERTURN_MINOR`
  else `minor`.
- No quorum or no side at 60%: the dispute rolls to round 2 automatically.

Appeal and round 2

- Within `appealWindow` (24 h) after a decided round 1, anyone may `Appeal`
  by posting 2x the round-1 bond; if the appeal loses, 25% of the appeal bond
  is consumed (half to the round-2 coherent voters, half to the treasury) and
  the rest returned.
- Round 2: commit 48 h, reveal 24 h, quorum 2500 bps, decision 5500 bps. Its
  outcome is final. No decision in round 2 means `VOID`. Two rounds are
  enough when the same electorate votes again under a higher bar; more rounds
  only add delay (Tellor allows up to five, UMA deletes after four rolls).

Effects

- `UPHOLD`: bond forfeited: 50% to the round's eligible providers (equal
  shares), 30% to coherent voters, 20% to the treasury. The round returns to
  its prior tier and its dispute window restarts from resolution.
- `OVERTURN`: the round value becomes `proposedValue`, tier `final`
  (`overturned` in the round record). Providers whose submission lies outside
  `toleranceBps` of the new value are slashed at the decided tier; a major
  slash ejects them. Total slashed splits 50% disputer, 30% coherent voters,
  20% treasury. The disputer's bond returns.
- `VOID`: the round has no value (`void`); the last final round remains the
  served value. Bond and stakes untouched except a 5% consumption of the bond
  (2.5% to voters who revealed, 2.5% to the treasury) so nuisance disputes
  are never free (Tellor Layer's rule). One-off requesters may
  `ReopenOneOff` with a new `resolveAt` once.
- Coherent voters are those whose revealed choice matched the winning side
  (`OVERTURN_MINOR` counts as coherent when `O` wins at either tier). On
  `VOID` there is no incoherence.
- Emits `DisputeResolved{disputeID, round, outcome, tier, upholdW, overturnW,
  minorW, voidW, abstainW}`.

### 7.4 Kourt persistence

Every resolved dispute (including `VOID`) is mirrored as a claim in the DAO's
own Kourt court through the `kourt` permanent realm and its live
implementation, which is compiled against one Kourt realm path. The record
is advanced by `KourtCrank(cur, disputeID)`; `core` calls it once on
resolution, crankers and the notifier bot call it later.

```
Pending ──OpenClaimP (CC deposit + fee)──► Filed ──Stake(verdict side)──► Staked
   ──after the 3 h trailing window──► PostAnswer(verdict) ──► Answered
   ──after 72 h, no Kourt dispute──► SettleUndisputed + WithdrawStake ──► Settled
   ──Kourt dispute opened by anyone──► Contested ──Kourt Finalize──► SettledByKourt(verdict)
```

- Claim title (at most 200 chars, fixed format): `Gnoracle #<disputeID>:
  feed <feedID> round <roundID> resolved <OUTCOME>[/<tier>]; value
  <canonical>; <ISO time>`. Body (at most 2000 chars): JSON with tallies,
  provider addresses and submissions, evidence hash, spec hash and a gnoweb
  link.
- Verdict posted: `TRUE` = "this record is accurate". A Kourt overturn sets
  `kourtContested` on the dispute record and emits `KourtDissent`; v2 may
  open an automatic appeal on it.
- Costs come from the realm's court-coin float: claim deposit (0.01% of the
  court's supply, min 1 CC) plus a 10% fee, a stake clearing the
  answerability floor (0.10% of supply, min 1 CC), and the answer bond
  (max(6% of trailing stake, 1.6x the larger side's conviction), min 1 CC),
  all returned on an undisputed settle. Users `Buy` CC and `TransferCC` it to
  the realm address by DAO proposal; `Redeem` unwinds excess on a two-way
  court.
- The court: founded by the realm itself while Kourt's court-creation burn is
  zero (`StartCourt` then accepts a realm caller), slug `gnoracle`. If the
  burn is non-zero at deploy time an operator founds it and appoints the
  realm address as moderator.
- Which Kourt: decided. An import path is compile-time, so `kourt/impl/v1`
  targets the v3 realm at
  `gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3` (the
  deployment with `Redeem`). If kourt.xyz keeps pointing at the v2 realm at
  `gno.land/r/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/kourt`, a
  `kourt/impl/v2` against it is a one-file change accepted through the proxy.
  Confirm with Jae Kwon before M4 which one he considers production. pearl-1
  has Kourt realms for the testnet rehearsal.
- Licence: pages that show a Kourt claim or court carry the "built on Kourt"
  attribution linked to kourt.xyz (RESEARCH §2.6). No Kourt code is copied.

---

## 8. The DAO

### 8.1 Token (Pythia, PYTH)

- `token`: `grc20.NewToken("Pythia", "PYTH", 6, id, cur)`, registered in
  `r/nt/grc20reg/v0` at init, canonical `Transfer`, `Approve`,
  `TransferFrom`, `Render`. Mint and burn are `ownable` by the `dao`
  permanent realm; `dao` mints only by executed proposal, capped by
  `maxSupply` and `maxMintPerYearBps`.
- Decided: name `Pythia`, symbol `PYTH`, 6 decimals, fixed max supply
  100,000,000 PYTH, allocation as in §9.1. No automatic emission. Rewards to
  stakers are GNOT fees and forfeitures, not new tokens. `PYTH` is also the
  ticker of Pyth Network's token on Solana; gno.land keys tokens by realm path
  plus symbol (`.../gnoracle/token.PYTH`), so there is no on-chain collision,
  and these documents say "Pyth Network" whenever they mean that project.
- Listing on Gnoswap is an ops step: `r/gnoswap/pool.CreatePool(cur,
  "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/token.PYTH", "gno.land/r/gnoland/wugnot.wugnot", fee,
  sqrtPriceX96)` after approving the 100 GNS creation fee, then a
  `position/v1` mint for liquidity. Nothing in the realms depends on it.

### 8.2 Membership by staking

- `Stake(cur, amount)`: pulls PYTH via allowance, credits `staked[member]`,
  checkpoints at the next epoch (720 blocks, about 1 h) so new stake never
  counts for a dispute already open.
- `RequestUnstake(cur, amount)`: moves the amount to `unbonding[member]` with
  `readyAt = now + unstakeCooldown` (7 d, UMA). Unbonding stake still counts
  for obligations sealed before the request and is still slashable; voting
  weight for new disputes drops immediately.
- `Withdraw(cur)`: pays unbonding stake whose `readyAt` passed and whose
  obligations are all processed (cursor at head); otherwise it tells the
  member to `SettleMember` first.
- Before any stake change or vote, `settleMember(addr, maxN)` runs (§8.4);
  beyond `settleMaxN` (20) pending disputes the call refuses and the member
  (or anyone, for a `settleTipBps` 50 tip) calls `SettleMember` explicitly.
- Founding allocations carry `vestedUntil`; unstaking below the vested floor
  is refused (there is no vesting package on gno.land).

### 8.3 Governance proposals (optional votes)

Kinds, each a string payload parsed by the kind, so any wallet can propose:

| Kind | Payload | Quorum / decision / period | Executes |
|---|---|---|---|
| `feed-accept` | feedID | 15% / >50% / 3 d | core.ActivateFeed |
| `feed-update` | feedID + JSON of economic fields | 15% / >50% / 3 d | core.UpdateFeed |
| `feed-deprecate` | feedID + reason | 15% / >50% / 3 d | core.DeprecateFeed |
| `provider-remove` | feedID + addr + reason | 20% / >50% / 3 d | core.ForceUnbond |
| `trusted-requester` | add or remove realm path, cap | 20% / >50% / 5 d | core.SetTrustedRequester |
| `param` | name=value | 20% / >50% / 5 d + 7 d timelock for economic params (stake floors, slash rates, windows, splits), 2 d for operational ones; at most ±50% per change; hard floors (dispute window ≥ 2 h, per-voter cap ≤ 33%, stake floor ≥ 1,000 GNOT) | params.Set |
| `treasury` | denom, amount, to, memo | 20% / >66% / 5 d + 2 d timelock | treasury.Send |
| `subsidy` | feedID, budget, months | 20% / >50% / 5 d | core.SetSubsidy |
| `mint` | amount, to | 25% / >66% / 7 d + 7 d timelock | token mint (capped) |
| `upgrade-accept` | realm (core, dao, kourt) + impl path | 25% / >66% / 7 d + 7 d timelock | `<realm>.Accept(cross(cur), path)` |
| `upgrade-rollback` | realm | 15% / >50% / 24 h, no timelock | `<realm>.Rollback(cross(cur))` |
| `freeze` | realm | 30% / >75% / 14 d + 7 d timelock | `<realm>.Freeze(cross(cur))` (irreversible) |
| `authority-transfer` | realm + authority spec | 30% / >75% / 14 d + 7 d timelock | `<realm>.TransferAuthority` |
| `text` | markdown | 10% / >50% / 5 d | nothing |

- Weight = staked PYTH at the proposal's sealed epoch, `min` with live stake;
  choices YES / NO / ABSTAIN (abstain counts to quorum only); no early close.
  Governance voting is optional and never penalised (UMA also exempts
  governance votes from slashing).
- Proposer must hold at least `proposeBps` (25 bps) of staked supply or pay a
  20 GNOT deposit refunded on quorum. `feed-accept` proposals are created by
  `core` on `ProposeFeed` and skip this check.
- At most `maxActiveProposals` (32) live at once.
- Guardian bootstrap: until handover (§8.6) the guardian may also call
  `Accept` and `Rollback` directly through the proxy's `AnyOf` authority, so
  early releases and hotfixes do not wait 7 days; every such action emits an
  event and shows on the realm's `Pending()`/`History()` pages.

### 8.4 Mandatory dispute voting and penalties

Per resolved dispute round the DAO stores `DisputeRecord{sealedEpoch,
obligatedWeight, revealedWeight, outcome, coherentWeight,
expectedPenaltyPool, bondShareGNOT}` and a ballot tree
`reveals[disputeID][member] = {choice, weight}`.

`settleMember(addr, maxN)` walks records from the member's cursor:

1. `w = min(stakedAt(addr, sealedEpoch), stakedNow(addr) + unbonding(addr))`;
   if `w == 0` skip.
2. Look up the member's reveal:
   - none: `penalty = w x absenceSlashBps / 10000`;
   - `ABSTAIN`: `penalty = w x abstainSlashBps / 10000`;
   - a side that lost, or `VOID` when a side won: `penalty = w x
     incoherenceSlashBps / 10000`;
   - coherent: `reward = expectedPenaltyPool x w / coherentWeight` in PYTH plus
     `bondShareGNOT x w / coherentWeight` in ugnot.
   - Outcome `VOID`: no incoherence penalties, only absence.
3. Penalties come from staked balance first, then unbonding balance, capped
   at `maxPenaltyPerWindowBps` (500, 5%) per member per `penaltyWindow`
   (30 d); the excess is forgiven and emitted as `PenaltyCapped`.
4. `expectedPenaltyPool` is computed at resolution from the ballot (obligated
   minus revealed for absence, abstain weight, incoherent weight) so a
   coherent member's reward is one read; penalties collected later refill the
   DAO's PYTH balance, and any shortfall from the cap is covered by the
   treasury's PYTH and emitted.

Defaults and rationale

| Parameter | Default | Rationale |
|---|---|---|
| `absenceSlashBps` | 50 (0.5% per dispute) | UMA is 0.1% per vote with about six votes per 48 h round; a young DAO will see far fewer disputes, so a higher per-dispute rate is needed to bite. Ten misses cost about 5%, the per-window cap. |
| `incoherenceSlashBps` | 50 | Equal to absence, as in UMA. With commit-reveal there is no visible majority to herd toward, so a higher rate would only punish honest minorities. |
| `abstainSlashBps` | 5 | Kleros's "refuse to arbitrate" made cheap: an uninformed member should abstain rather than guess (expected cost of a coin flip is 25 bps) or stay away (50 bps). Abstain counts toward quorum, not toward a side. |
| `maxPenaltyPerWindowBps` | 500 per 30 d | Bounds the worst case; Pyth Network caps a slashing event at 5%. |
| `maxVoterShareBps` | 2000 | UMA's 25%-from-one-holder episode; Chainlink and Kleros v2 cap per-address stake. |
| `disputeQuorumBps` / `decisionBps` | 3300 / 6000 (round 2: 2500 / 5500) | Kourt's one-third floor; UMA's SPAT went 50% to 65% after capture; a supermajority with a void fallback means a captured vote can freeze but not inject. |
| `commitPeriod` / `revealPeriod` | 24 h / 24 h (round 2: 48 h / 24 h) | UMA's proven schedule; the notifier bot is part of the protocol. |
| `voterShareOfForfeits` | 30% | Below the disputer's 50% so that manufacturing disputes to farm voter rewards is dominated by disputing honestly; well above Kourt's 7% because voting is a duty here. |
| `unstakeCooldown` | 7 d | UMA; exceeds commit + reveal + appeal + round 2 slack. |

Setting the three slash rates to 0 turns the scheme into Kourt's: coherent
voters earn, nobody loses stake. The plan launches on testnet with the
defaults above and lets the DAO set mainnet values with counsel's input.

### 8.5 Fee share for stakers

`accFeePerShare` (scaled 1e12) is bumped whenever `core` forwards the
stakers' 15% of a subscription, read fee or forfeiture; each member has
`feeDebt`. `ClaimFees(cur)` pays `staked x accFeePerShare - feeDebt` in ugnot.
Unbonding stake does not earn. With `workGate` on, a member who revealed in
fewer than half of the disputes sealed during a 30-day window forfeits that
window's fee share to the treasury (§9.4).

### 8.6 Treasury and guardian

- `p/nt/treasury/v0` with a coins banker on the DAO's `cur.Sub("treasury")`
  sub-account and a GRC20 banker for PYTH. Spends only by proposal. Standing
  programmes by proposal: voter gas rebates (UMA's Risk Labs pays about
  $45k/month of these), watcher bounties, bootstrap subsidies.
- Guardian: decided as a single key (the deployer's) until handover, with
  three powers: `Pause` (stops new stakes, registrations, submissions,
  sponsorships and metered reads; never withdrawals, unbonding, claims or
  dispute resolution), `Accept`/`Rollback` on the three proxies during
  bootstrap, and nothing else. The trust statement in the docs says so
  plainly: until handover one key can pause inflows and switch releases. The
  DAO executes `authority-transfer` to `NewRealmAuthority(daoPath)` on all
  three realms once at least `guardianHandoverMembers` (25) members are
  staked; after that the guardian keeps only `Pause`, and a later proposal can
  drop that too. The `authz` member authority makes widening to 2-of-3 later
  a one-line change if collaborators join.

---

## 9. Tokenomics

### 9.1 Supply and distribution (decided)

| Bucket | Share | Release |
|---|---|---|
| DAO treasury reserve | 40% | held; spent by proposal |
| Provider and member incentives | 25% | released by `subsidy` and `treasury` proposals against published programmes, tied to feeds with paying sponsors |
| Gnoswap liquidity and LP incentives | 20% | paired with GNOT by proposal |
| Founding contributors | 15% | staked at genesis, 12-month cliff then linear over 36 months via `vestedUntil` |

Fixed supply, no automatic inflation. `mint` proposals are capped at
`maxMintPerYearBps` (200, 2%) of supply for a future bounded emission if the
DAO ever wants one.

### 9.2 Value flows

```
subscription (per feed, per 30 d) ─┬─ 70% ─► feed round pools over the period ─► eligible providers, 1% cranker
                                   ├─ 15% ─► DAO staker accumulator (ugnot)
                                   └─ 15% ─► treasury
metered read fee ────────────────── same 70 / 15 / 15
one-off bounty ────────────────── 100% ─► that feed's round pool
provider miss slash ──────────────┬─ 50% ─► alerter
                                  └─ 50% ─► feed's next round pool
lost-dispute slash (5% or 100%) ─┬─ 50% ─► disputer
                                  ├─ 30% ─► coherent voters (ugnot, pro rata)
                                  └─ 20% ─► treasury
failed dispute bond ─────────────┬─ 50% ─► eligible providers of the round
                                  ├─ 30% ─► coherent voters
                                  └─ 20% ─► treasury
void dispute ─────────────────── 5% of bond: 2.5% voters who revealed, 2.5% treasury; 95% returned
lost appeal ──────────────────── 25% of appeal bond: half round-2 coherent voters, half treasury
voter absence / abstain / incoherence ─ 100% ─► coherent voters of that dispute (PYTH)
spam feed deposit ─────────────── 100% ─► treasury
bootstrap subsidy ─────────────── treasury ─► round pools of sponsored feeds, decaying 10%/month, 12 months
```

Voting penalties are zero-sum among members; the treasury takes none of
them, so nobody inside the DAO profits from manufacturing disputes except
through the 20% treasury share of forfeitures, which needs a real loser.

### 9.3 Sanity checks (GNOT at $0.062)

Provider economics on an hourly price feed with 5 providers at 25,000 GNOT
each ($1,550), one sponsor at 1,000 GNOT per 30 d, and 10 metered reads per
hour at 0.02 GNOT:

| Item | Per day | Per provider per day |
|---|---|---|
| subscription to pool (70% of 33.3 GNOT) | 23.3 GNOT | 4.67 GNOT |
| metered reads to pool (70% of 4.8 GNOT) | 3.36 GNOT | 0.67 GNOT |
| gas for 24 submissions and a share of finalisations (measured about 17M gas each at 1 ugnot per 1000 gas) | | about 0.5 GNOT |
| storage deposit locked, refundable on prune | | about 0.6 GNOT rolling |
| net | | about 4.8 GNOT/day, about 7% annualised on 25,000 GNOT |

That yield is thin, which is the honest state of oracle economics in 2026:
Pyth Network's on-chain fees earned about $115K in a half-year across 70 chains. Two
sponsors or a subsidy double it; the acceptance checklist requires
`(subscription pool per period x 70% / rounds per period) >= 3 x minProviders
x 0.5 GNOT / rounds per day` or an approved subsidy, and the feed page shows realised provider
APR so the market can price stake.

Attack cost on that feed: corrupting the equal-weight median needs 3 of 5
providers, so 75,000 GNOT ($4,650) at risk of a major slash against a 12,500
GNOT bond (10% of 125,000) that any watcher can post and that returns 37,500
GNOT if the dispute succeeds. `maxValueAtRisk` published for the feed is
about 37,500 GNOT ($2,300): consumers moving more than that on a single
provisional read are told to wait for `final` or ask for a higher-stake feed.
The absolute numbers are small because GNOT is; the USD targets in the
parameter table rise with the DAO's own GNOT/USD feed (v1.1, 24 h lagged,
bounded ±25% per epoch, Tellor's rule).

Voter economics: a member with 1% of staked PYTH, 4 disputes a month, coherent
every time, earns 1% of the month's voter share of forfeitures plus 1% of 15%
of all fees. Absent every time, they lose 2% of stake a month, capped at 5%;
abstaining every time costs 0.2%. A member who never shows up is out in about
three years, slower than UMA (where absence and emissions roughly cancel) and
faster than Kourt (where absence costs nothing).

### 9.4 Regulatory note (not legal advice)

Kourt's authors chose "principal always returns, nothing is risked upon the
outcome, rewards are minted for work" to keep the coin a participation
instrument. PYTH as planned differs on two points: stakers receive a share of
protocol fees, and stakers can lose stake for not working. The second
strengthens the "paid for work" framing; the first is the one to discuss
with counsel before mainnet. Two levers are already parameters:
`stakerFeeShareBps` can be 0 (fees go to providers and the treasury only),
and `workGate` conditions the fee share on having voted in the period.

---

## 10. Security analysis

### 10.1 Threat table

| Threat | Mitigation |
|---|---|
| Provider collusion above the median threshold | bonded disputes decided by a separate voter set; published `maxValueAtRisk`; `provider-remove`; feed specs may require 5+ providers and higher stake; require providers to declare at least three distinct upstream sources in their registration memo (API3 and Chainlink's layered aggregation are the references) |
| Copycat providers | equal split gives no gain from copying; the copied value is as slashable as the original; v1.1 optional per-feed commit-reveal submissions |
| Sybil providers filling `maxProviders` | `providerMinStake` x 15 slots is the price (375,000 GNOT at the recommended price-feed stake); DAO removal by proposal |
| Stake too small for the value secured (BonqDAO) | USD-targeted floors with a GNOT minimum; per-feed `maxValueAtRisk`; 100% tier plus ejection; quarantine band so one round cannot print an absurd value into the consensus tier; parameter timelock so floors cannot be quietly lowered |
| Lazy voters copying visible votes | commit-reveal; cheap explicit abstain |
| Vote buying after a dispute is visible | weight sealed at the previous epoch; `min(snapshot, live)`; new stake activates next epoch; unstake cooldown longer than a dispute |
| Whale capture of a dispute vote (UMA 2025) | 20% per-address cap; 60% / 55% supermajorities with void fallback; appeal round; quarantined value so a captured vote can freeze but not inject |
| p + epsilon bribery of voters | slashable stake far above voter rewards; permanent public dissent in the Kourt mirror; appeal; the DAO can raise `incoherenceSlashBps` temporarily |
| Dispute spam to grief providers or force votes | bond of 10% of feed stake, min 2,500 GNOT, doubling within 7 d; failed disputes pay providers and voters; void consumes 5% |
| Censorship by dispute (Liquity/Tellor 2022) | disputed values are quarantined, not deleted; the last final value keeps serving; bond doubling per open dispute |
| Manufactured disputes to farm voter rewards | penalties are zero-sum among members; forfeitures need a real loser; disputer share dominates voter share |
| Storage-deposit griefing | every writable path costs the writer a deposit or a bond; strangers cannot create per-member state |
| Unbounded loops | active set at most 15; one round per `Finalize`; catch-up capped; member settle capped; pagers in Render; filetest `// Gas:` pins |
| Cross-realm panic griefing | consumer read path calls only `core`; Kourt calls only from the adapter crank, failures recorded not propagated; token calls only to `token` and `wugnot` |
| Reentrancy through token callbacks | GRC20 has no hooks; checks-effects-interactions everywhere; `executing` guard on the DAO as in Kourt's governor |
| Spoofed realm values | `cur.IsCurrent()` before `cur.Previous()`; payments only under `IsUserCall()`; `grc20.IsCanonicalTeller` on any teller received; the upgradeable store re-checks `IsCurrent()` on every access |
| Malicious or buggy implementation release | gated store with conservation checks in permanent code; DAO-only `Accept` with 7-day timelock and a public pending list; one-transaction `Rollback`; `Freeze`; `Health()` before and after |
| Guardian abuse | guardian can pause inflows and accept or roll back releases only until handover; withdrawals and settlements are unpausable; every action emits an event |
| Integer overflow | `math/overflow` everywhere; 128-bit products via `bits.Mul64`/`Div64`; feed values validated against `decimals`; accumulators scaled 1e12 with headroom tests |
| Front-running submissions inside a block | validators order transactions; values are public anyway; equal split; tolerance band |

### 10.2 Invariants (asserted in tests and by the permanent `Health()` view)

- `core` ugnot balance ≥ Σ provider stakes (active + unbonding) + Σ credits +
  Σ subscription pools + Σ open dispute and appeal bonds + Σ unclaimed round
  pools + Σ unclaimed provider rewards + fees not yet forwarded.
- `dao` PYTH balance (token ledger) == Σ staked + Σ unbonding + unclaimed voter
  rewards + treasury PYTH.
- Every `StateRef` mutator preserves the two equalities above or panics.
- For every round: `eligibleMask ⊆ submittedMask`; `Aggregated` iff
  `popcount(eligibleMask) >= minProviders`; `consensus` implies
  `3 x popcount(eligibleMask) >= 2 x |activeSet|`.
- For every dispute record: `coherentWeight + incoherentWeight + abstainWeight
  <= revealedWeight <= obligatedWeight`; no single reveal above
  `maxVoterShareBps` of revealed weight after clipping.
- A member's cursor never exceeds the record count; penalties per window never
  exceed the cap; unbonding never pays before `readyAt` and never before the
  cursor is at head.
- The live implementation path of each proxy is in its `History()`; the
  `Pending()` list is public.

---

## 11. Gas and storage budget

Measured on gnodev built from the v1.2.0 tag (2026-09-23, `make chain-test`),
one-minute feed, two providers. Gas at the launch price of 1 ugnot per 1000
gas; storage deposit at 100 ugnot per byte, refundable on delete.

| Operation | Gas used | Cost at launch price | Storage delta |
|---|---|---|---|
| `SetParam` | 10 to 14.5M | 0.010 to 0.015 GNOT | +36 B |
| `Accept` (release) | about 12M | 0.012 GNOT | +144 B |
| `ProposeFeed` (400 B spec) | 37.6M | 0.038 GNOT | +5,570 B (feed record, spec, credit record) |
| `ActivateFeed` | 18.9M | 0.019 GNOT | 0 |
| `Register` | 16.5M | 0.017 GNOT | +2,703 B (provider record, slot log) |
| `Submit` (first of a round) | 17.0M | 0.017 GNOT | +1,840 B (the round record) |
| `Submit` (last, with early finalisation) | 27.5M | 0.028 GNOT | +90 B |
| `DepositFor` | 12.0M | 0.012 GNOT | +~60 B |
| `Read` | 17.8M | 0.018 GNOT | 0 |

These are 5 to 10x the v0.1 estimates: the fixed cost of entering the realm
and loading its package objects dominates every call. Two consequences:

- Provider gas on an hourly feed is about 24 x 0.017 + a share of
  finalisations, roughly 0.5 GNOT per day rather than the 0.06 assumed in
  §9.3; still small against the subscription drip, but the acceptance
  checklist now uses 0.5 GNOT per provider per day.
- Storage, not gas, is the larger rolling cost: a round is 1.9 kB (0.19 GNOT
  of refundable deposit), so an hourly feed locks about 4.6 GNOT per day and
  about 140 GNOT over a 30-day retention, returned to whoever prunes. The
  slot addresses and per-round values are packed into fixed-width strings for
  this reason (arrays cost about 150 bytes per element on chain); the
  remaining size is per-field object overhead.

The `// Gas:` filetest pins for these operations are still to be written
(open from M1). All figures are far below the 3B block limit; the point of
the table is fee estimation for agents and a regression guard.

## 12. Off-chain components

### 12.1 Provider agent (`agent/`, Go)

- Config: key, RPC, feed IDs, per-feed source adapter and parameters, gas and
  deposit ceilings, at least three declared upstream sources per price feed.
- Loop per feed: cache the spec from `FeedInfo`; compute the current round
  from chain time; at `open + jitter` run the adapter, validate the value
  (type, range, `sanityBps` against the previous aggregate), broadcast
  `Submit`; after the window broadcast `Finalize` if needed (the tip and the
  alerter share pay for it); claim rewards weekly; alert on jail.
- Adapters in v1: HTTP JSON with a JSONPath and a median across N URLs,
  Gnoswap pool TWAP via qeval, and an `exec` adapter for one-off outcomes a
  human confirms.
- Safety: refuse to submit a value that deviates more than `sanityBps` from
  the last aggregate without an operator override; log every submission with
  raw source responses (the operator's evidence in a dispute).
- Ships as one binary and a Docker image; a `gnodev` scenario runs three
  agents against a local chain for the integration tests.

### 12.2 Notifier and cranker bot (`bot/`)

Penalties make notification part of the protocol. A Telegram (later Discord)
bot watches tx-indexer events `DisputeOpened`, `DisputeRolled`, `AppealOpened`,
`ProposalCreated`, `ProviderJailed`, `KourtDissent`, `ReleaseProposed`,
`ReleaseAccepted`, posts deadlines with countdowns, and sends direct reminders
24 h and 2 h before a reveal closes to registered members. It also cranks:
`Finalize` on stale rounds, `ResolveDispute` after reveal, `KourtCrank`
daily, and `SettleMember` for opted-in addresses.

### 12.3 gnoweb pages (`Render`)

`core`: `:feeds`, `:feed/<id>` (spec, providers, `maxValueAtRisk`, delayed
values, sponsor and register forms), `:feed/<id>/rounds`, `:disputes`,
`:dispute/<id>` (tallies once resolved, evidence hash, Kourt link with the
attribution badge), `:providers/<addr>`, `:consumers/<addr>`, `:releases`
(live, pending, history). `dao`: `:members`, `:member/<addr>` (stake, pending
obligations, penalties in window), `:proposals`, `:proposal/<id>`, `:params`,
`:treasury`, `:releases`. Lists paged with `p/nt/bptree/pager/v0`; all user
text through `sanitize.InlineText`.

---

## 13. Testing strategy

| Layer | What | Tooling |
|---|---|---|
| Pure packages | median and majority edge cases, tier assignment at the boundaries, round arithmetic across long gaps, accumulator rounding (dust never leaks to users), checkpoints across epochs, commit hash round-trips, tally with clipping and both decision thresholds, penalty caps | `gno test`, table tests, seeded property loops |
| Realm flows | one narrative test per story: feed proposed to final; provider misses to jail to unjail; dispute upheld; overturn at minor tier; overturn downgraded from major to minor; void; failed quorum rolls to round 2; appeal reverses round 1; member absent then settled; unstake blocked by pending obligations; sponsor lapses to unfunded; Kourt crank through every state against a fake Kourt realm | `_test.gno` with `testing.SetRealm`, `SkipHeights`, `IssueCoins`, `SetOriginSend`; `r/tests/fakekourt` |
| Upgrade | register `impl/v2`, accept through a DAO proposal, verify state untouched and `Health()` unchanged, roll back, verify the old release's `StateRef` is dead (`IsCurrent()` fails), freeze and verify `Accept` refuses | realm tests plus a filetest per proxy |
| Filetests | events for every entry point; `// Storage:` and `// Gas:` pins for §11 | `*_filetest.gno`, golden files updated only with a reviewed diff |
| Adversarial | stale `cur`, `maketx run` payments refused, non-canonical teller refused, reentrant proposal execution refused, a panicking Kourt callee does not block resolution, oversized spec and evidence refused, overflow attempts, an implementation trying to keep a `StateRef` across calls, an implementation calling a mutator that would break conservation | `adversarial_test.gno` per realm |
| Economic simulation | 1000 rounds with honest, flaky, colluding and copycat providers and lazy, coherent, abstaining and bribed voters; asserts honest providers profit, colluders lose, the penalty cap binds; sweeps the parameter table | `sim/` in Go, results in `docs/SIMULATION.md` |
| Integration | gnodev with three agents, one consumer realm, the bot in dry-run; a dispute end to end with the Kourt mirror against a local copy of `r/kourtv3` | `make chain-test` |
| Testnet soak | 4 weeks on `pearl-1` with at least 5 external providers, 2 feeds, at least 3 real disputes including one appeal, one live upgrade and one rollback | `docs/OPERATIONS.md` runbook |
| Review | external audit of the permanent realms, `impl/v1` and `p/ledger`; a mutation run like Kourt's on the money paths | before mainnet |

---

## 14. Milestones

One experienced Gno developer full time, with the agent and bot written in
parallel by a second person from M3.

| # | Milestone | Content | Exit criteria | Estimate |
|---|---|---|---|---|
| M0 | Spec | this document reviewed; decisions in §16 answered; toolchain pinned; repo scaffolded from `clockwork-gno-home`; `upgradeable/v0` mirrored into `deps/` | `make test` runs on v1.2.0 | **done 2026-09-23** |
| M1 | Pure packages | `spec`, `agg`, `rounds`, `ledger`, `checkpoint`, `tally`, `params` with unit tests and gas pins | every invariant in §10.2 has a test; simulation skeleton | **done 2026-09-23** (gas pins and simulation skeleton still open) |
| M2 | Core without disputes | permanent `core` (interface, state, gated store, proxy, entry points), `core/impl/v1` feeds, providers, rounds, credits, sponsors, `Read`, prune; Render | three fake agents keep an hourly feed live for 48 h on gnodev; a consumer realm reads and is billed; an `impl/v2` is accepted and rolled back by the guardian | **in progress**: realms and realm tests done 2026-09-23; gnodev smoke (`make chain-test`), the 48 h agent soak and the v1b rollback rehearsal remain |
| M3 | Token and DAO | `token`, permanent `dao` plus `dao/impl/v1` staking, checkpoints, proposals, `feed-accept`, `upgrade-*` kinds, treasury, guardian | feeds accepted by vote; stake and unstake with cooldown; fee accumulator pays; an upgrade of `core` executed through a proposal with timelock | **done 2026-09-23** (realm tests: staking and weight, fee sync, feed-accept and param proposals on the core with timelock, treasury and rate-limited mint, DAO self-upgrade and rollback through the `dao/exec` trampoline; the founder vesting fields exist but no genesis vesting is applied yet) |
| M4 | Disputes and Kourt | dispute open, commit-reveal, clipping, supermajority, roll, appeal, penalties with lazy settle, forfeiture routing, `kourt` permanent realm plus `impl/v1` against a local `r/kourtv3`, bot cranks | all dispute stories pass; a resolved dispute appears as a settled Kourt claim on the local chain; attribution shown | 4 wk |
| M5 | Agents and operations | provider agent with three adapters, bot with reminders, docs for consumers, providers, sponsors and members, `OPERATIONS.md`, simulation report | two outside testers run agents from the docs alone | 3 wk |
| M6 | Testnet | deploy to `pearl-1`, found the court on the pearl-1 Kourt realm (`gno.land/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt2`, generation to confirm), soak 4 weeks, parameter tuning by DAO vote, one live upgrade and one rollback | soak criteria in §13 met | 5 wk |
| M7 | Audit and mainnet | external audit, fixes, mutation run, mainnet `addpkg` approvals, PYTH genesis distribution, Gnoswap pool, first feeds (gnomarket outcomes, GNOT/USD), guardian handover scheduled | audit findings closed; at least 25 stakers | 6 wk + audit lead time |

About 5.5 months to mainnet, of which the last two are testnet and audit. M2
alone is a usable admin-curated oracle for gnomarket on testnet.

---

## 15. Risks to the plan itself

- **GNOT transfer lock returns.** Observed unlocked on 2026-09-23 on both
  mainnet and pearl-1. `stakeDenom` exists from day one so stakes and bonds
  can move to wugnot (GRC20) with one code path change in permanent money
  primitives, which is the one place an upgrade cannot reach; if the lock
  returns before mainnet, deploy with wugnot.
- **Kourt path or API changes.** Kourt is pre-audit and address-namespaced on
  mainnet. The `kourt` realm's implementation is the isolation; the DAO
  accepts a new one through the proxy.
- **Low DAO turnout.** Mandatory voting is only humane with good notifications
  and few disputes; the bond schedule and roll rule keep counts low. If
  turnout still fails, the DAO lowers `disputeQuorumBps` or moves to the Kourt
  posture.
- **Thin provider market and thin yield.** 7.7% on a single-sponsor feed is
  not enough to attract professional operators; the subsidy bucket and the
  per-feed APR display make the shortfall visible, and the acceptance
  checklist refuses feeds nobody funds.
- **Permanent API and storage layout.** The upgradeable pattern freezes both.
  Mitigated by keeping entry points few and string-payload based, by
  extension realms, and by an explicit API review before M2 ships.
- **Securities exposure of PYTH.** §9.4; get an opinion before the token is
  transferable on mainnet; `stakerFeeShareBps` and `workGate` are the levers.

---

## 16. Decisions

Resolved with the owner on 2026-09-23:

| Decision | Choice | Where applied |
|---|---|---|
| Voter penalty posture at launch | UMA-style: 0.5% absence, 0.5% incoherence, 0.05% abstain, 5% cap per 30 d, redistributed to coherent voters | §8.4 |
| Provider stake floor | 10,000 GNOT at launch, rising by schedule to 15,000 (90 d) and 25,000 (180 d); USD target $1,500 published | §4.1, Appendix C |
| Stake denomination | native ugnot for stakes, bonds and credits; `stakeDenom` kept for a fresh deploy if the transfer lock returns | §3.2, §15 |
| Namespace | address namespace `gno.land/{p,r}/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/...`, as Kourt did; no name registration needed | §3.1 |
| Upgrade mechanism | `gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0`, permanent realms with nested `impl/vN` | §3.2 |
| Kourt target | v3 realm `gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3` first; v2 adapter if kourt.xyz stays on v2; confirm with Jae Kwon before M4 | §7.4 |
| gnomarket requests | allowlisted trusted requesters activate one-off feeds without a vote under `trustedOneOffCap` | §4.2, §6.3, §8.3 |
| Guardian | single key (the deployer's) until handover at 25 staked members | §8.6 |
| Token | `Pythia` / `PYTH`, 6 decimals, 100,000,000 fixed, 40% treasury / 25% incentives / 20% liquidity / 15% founders (12 m cliff, 36 m vest) | §8.1, §9.1 |

Still open (needed before M3):

1. Who operates the first three provider agents and the notifier bot on
   pearl-1 (M5/M6).

---

## Appendix A. Public API sketch

Crossing functions are `func F(cur realm, ...)` on the permanent realm and
forward to the live implementation's `(_ int, rlm realm, ...)` method; view
functions are plain.

```go
// gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/core (permanent)
// consumers and sponsors
func Read(cur realm, feedID uint64) (value int64, decimals int, roundID uint64, updatedAt int64, tier string)
func ReadOption(cur realm, feedID uint64) (option int, label string, roundID uint64, updatedAt int64, tier string)
func ReadRound(cur realm, feedID, roundID uint64) (value int64, tier string, finalisedAt int64)
func DepositFor(cur realm, consumer address)                         // -send
func WithdrawCredit(cur realm, amount int64)
func SetFinalOnly(cur realm, on bool)
func Sponsor(cur realm, feedID uint64, periods int, consumers string) // -send; consumers: comma-separated addresses
// feeds
func ProposeFeed(cur realm, specJSON string) uint64                  // -send: feedDeposit + first period or bounty
func FundBounty(cur realm, feedID uint64)                             // -send (one-off)
func Finalize(cur realm, feedID, roundID uint64)
func CatchUp(cur realm, feedID uint64, maxRounds int) int
func PruneRounds(cur realm, feedID uint64, maxRounds int) int
func PruneFeed(cur realm, feedID uint64)
func ReopenOneOff(cur realm, feedID uint64, resolveAt int64)
// providers
func Register(cur realm, feedID uint64, sourcesMemo string)          // -send: >= providerMinStake
func TopUp(cur realm, feedID uint64)                                  // -send
func Submit(cur realm, feedID, roundID uint64, value int64)
func RequestUnbond(cur realm, feedID uint64)
func Withdraw(cur realm, feedID uint64) int64
func Unjail(cur realm, feedID uint64)
func ClaimRewards(cur realm, feedID uint64, maxRounds int) int64
// disputes
func Dispute(cur realm, feedID, roundID uint64, proposedValue int64, tier, evidence string) uint64 // -send: bond
func Appeal(cur realm, disputeID uint64)                              // -send: 2x bond
func ResolveDispute(cur realm, disputeID uint64)
// governance hooks (dao only)
func ActivateFeed(cur realm, feedID uint64)
func UpdateFeed(cur realm, feedID uint64, changesJSON string)
func DeprecateFeed(cur realm, feedID uint64, reason string)
func ForceUnbond(cur realm, feedID uint64, provider address)
func SetSubsidy(cur realm, feedID uint64, budget int64, months int)
func SetTrustedRequester(cur realm, path string, allowed bool, cap int64)
func SetKourtAdapter(cur realm, path string)
// upgradeable proxy
func Register(cur realm, impl Core)      // called by an implementation realm's init
func Accept(cur realm, pkgPath string)   // dao (proposal) or guardian during bootstrap
func Rollback(cur realm)
func Freeze(cur realm)
func TransferAuthority(cur realm, spec string)
func Store(_ int, rlm realm) *StateRef   // gated; implementations and extensions only
func LiveImpl() any
// views
func FeedInfo(feedID uint64) string
func RoundInfo(feedID, roundID uint64) string
func ProviderInfo(feedID uint64, addr address) string
func DisputeInfo(disputeID uint64) string
func Releases() string
func Health() string
func Render(path string) string

// gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/dao (permanent)
func Stake(cur realm, amount int64)
func RequestUnstake(cur realm, amount int64)
func Withdraw(cur realm) int64
func SettleMember(cur realm, member address, maxN int) int
func ClaimFees(cur realm) int64
func ClaimVoterRewards(cur realm) (orc int64, ugnot int64)
func Propose(cur realm, kind, payload, title string) uint64          // -send optional deposit
func Vote(cur realm, proposalID uint64, choice string)
func Execute(cur realm, proposalID uint64)
func CommitVote(cur realm, disputeID uint64, commitment string)
func RevealVote(cur realm, disputeID uint64, choice, salt string)
func OpenDisputeVote(cur realm, disputeID uint64, summary string)    // core only
func RollDisputeVote(cur realm, disputeID uint64)                     // core only
func FinishDisputeVote(cur realm, disputeID uint64) (outcome, tier string, weights string) // core only
func Pause(cur realm) / Unpause(cur realm)                           // guardian, then DAO
func Register / Accept / Rollback / Freeze / TransferAuthority        // proxy, as above
func MemberInfo(addr address) string
func ProposalInfo(id uint64) string
func Params() string
func Releases() string
func Render(path string) string

// gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/kourt (permanent)
func KourtCrank(cur realm, disputeID uint64) string                  // returns the new state
func RedeemFloat(cur realm, amount int64)                            // dao only
func Register / Accept / Rollback / Freeze / TransferAuthority        // proxy
func RecordInfo(disputeID uint64) string
func FloatBalance() int64
func Render(path string) string
```

## Appendix B. Events

`FeedProposed{feedID, proposer, specHash}`, `FeedActivated{feedID, startAt}`,
`FeedUpdated{feedID, field, value}`, `FeedUnfunded{feedID}`,
`FeedDeprecated{feedID, reason}`, `Sponsored{feedID, sponsor, periods}`,
`ProviderRegistered{feedID, provider, stake}`, `ProviderUnbonding{feedID,
provider, readyAt}`, `ProviderJailed{feedID, provider, misses}`,
`ProviderSlashed{feedID, provider, amount, tier, reason}`,
`ProviderEjected{feedID, provider}`, `Submitted{feedID, roundID, provider,
value}`, `RoundFinalized{feedID, roundID, status, tier, value, eligible,
pool}`, `CreditDeposited{consumer, amount}`, `Read{consumer, feedID, roundID,
fee}` (only when `emitReads` is on), `DisputeOpened{disputeID, feedID,
roundID, disputer, bond, proposedValue, tier}`, `DisputeRolled{disputeID}`,
`AppealOpened{disputeID, appellant, bond}`, `DisputeResolved{disputeID, round,
outcome, tier, upholdW, overturnW, minorW, voidW, abstainW}`,
`MemberStaked{member, amount, epoch}`, `MemberUnstakeRequested{member, amount,
readyAt}`, `MemberSettled{member, disputes, penaltyPYTH, rewardPYTH,
rewardUgnot}`, `PenaltyCapped{member, forgiven}`, `ProposalCreated{id, kind}`,
`ProposalVoted{id, voter, choice, weight}`, `ProposalExecuted{id, ok}`,
`ParamChanged{name, old, new}`, `ReleaseProposed{realm, path}`,
`ReleaseAccepted{realm, path, by}`, `ReleaseRolledBack{realm, path, by}`,
`Frozen{realm}`, `AuthorityTransferred{realm, authority}`,
`KourtRecord{disputeID, state, claimID}`, `KourtDissent{disputeID, claimID}`,
`Paused{by}`, `Unpaused{by}`.

## Appendix C. Parameter registry (defaults)

| Name | Default | Bounds | Section |
|---|---|---|---|
| `feedDeposit` | 5 GNOT | 1 to 1000 GNOT | 4.2 |
| `providerMinStakeFloor` | 10,000 GNOT | 1,000 to 1,000,000 GNOT | 4.1 |
| `providerStakeTargetUSD` (per feed class, published) | price feeds $1,500; one-off outcomes $600 | | 4.1 |
| `stakeFloorSchedule` | 10,000 GNOT at launch, 15,000 after 90 d, 25,000 after 180 d | each step a `param` proposal | 4.1 |
| `trustedOneOffCap` | 50,000 GNOT declared value at stake | 0 to 10,000,000 GNOT | 4.2 |
| `oneOffBountyFloor` | 50 GNOT | 1 to 100,000 GNOT | 4.2 |
| `readPriceFloor` | 0.002 GNOT | 0 to 1 GNOT | 4.1 |
| `subscriptionFloor` | 100 GNOT / 30 d | 10 to 100,000 GNOT | 4.1 |
| `maxProviders` | 15 | fixed | 4.1 |
| `maxCatchUpRounds` | 48 | 1 to 500 | 4.3 |
| `roundRetention` | 30 d and at least 64 rounds | 7 to 365 d | 4.4 |
| `retentionAfterDeprecate` | 90 d | 30 to 730 d | 4.2 |
| `deadFeedRounds` | 168 | 24 to 10000 | 4.2 |
| `renderDelay` | 10 min | 0 to 24 h | 6.1 |
| `missSlashBps` | 50 | 0 to 500 | 5.2 |
| `missSlashCapPerEpochBps` / `providerEpoch` | 500 / 7 d | | 5.2 |
| `alerterShareBps` | 5000 | 0 to 10000 | 5.2 |
| `jailAfterMisses` | 3 | 1 to 20 | 5.1 |
| `jailCooldown` | 24 h | 1 h to 30 d | 5.1 |
| `strikesToJail` / `strikeWindowRounds` | 5 / 100 | | 5.2 |
| `minorSlashBps` | 500 | 100 to 2000 | 5.2 |
| `majorSlashBps` | 10000 | 5000 to 10000 | 5.2 |
| `minorsToMajor` | 3 per epoch | 2 to 10 | 5.2 |
| `unbondPeriod` | 14 d | 7 to 60 d | 5.1 |
| `crankTipBps` | 100 | 0 to 1000 | 5.2 |
| `feeSplitProviders/Stakers/Treasury` | 7000 / 1500 / 1500 | sum 10000 | 6.2 |
| `readPriceFinalBps` | 5000 | 0 to 10000 | 6.1 |
| `subsidyMaxMonths` / `subsidyDecayBps` | 12 / 1000 per month | | 6.2 |
| `minDisputeBond` | 2,500 GNOT | 100 to 100,000 GNOT | 7.1 |
| `disputeBondBps` | 1000 | 100 to 10000 | 7.1 |
| `disputeEscalationWindow` | 7 d | 1 to 90 d | 7.1 |
| `disputeWindowRecurring` (spec default) | 12 h | 2 h to 14 d | 7.1 |
| `disputeWindowOneOff` (spec default) | 72 h | 2 h to 14 d | 7.1 |
| `commitPeriod` / `revealPeriod` | 24 h / 24 h | 6 h to 14 d each | 7.2 |
| `commitPeriod2` / `revealPeriod2` | 48 h / 24 h | | 7.3 |
| `disputeQuorumBps` / `decisionBps` | 3300 / 6000 | 500 to 10000, 5001 to 10000 | 7.3 |
| `disputeQuorumBps2` / `decisionBps2` | 2500 / 5500 | | 7.3 |
| `appealWindow` | 24 h | 1 h to 7 d | 7.3 |
| `appealBondMultiple` / `appealConsumeBps` | 2x / 2500 | | 7.3 |
| `voidConsumeBps` | 500 | 0 to 2000 | 7.3 |
| `forfeitSplitWinner/Voters/Treasury` | 5000 / 3000 / 2000 | sum 10000 | 7.3 |
| `maxVoterShareBps` | 2000 | 500 to 3300 | 7.2 |
| `absenceSlashBps` | 50 | 0 to 1000 | 8.4 |
| `incoherenceSlashBps` | 50 | 0 to 2000 | 8.4 |
| `abstainSlashBps` | 5 | 0 to 500 | 8.4 |
| `maxPenaltyPerWindowBps` / `penaltyWindow` | 500 / 30 d | | 8.4 |
| `unstakeCooldown` | 7 d | 3 to 60 d | 8.2 |
| `epochBlocks` | 720 | fixed | 8.2 |
| `settleMaxN` / `settleTipBps` | 20 / 50 | | 8.2 |
| `proposeBps` / `proposalDeposit` | 25 / 20 GNOT | | 8.3 |
| `maxActiveProposals` | 32 | 8 to 128 | 8.3 |
| `paramChangeMaxBps` | 5000 per change | fixed | 8.3 |
| `upgradeTimelock` | 7 d | 1 to 30 d | 8.3 |
| `stakerFeeShareBps` (alias of the fee split) | 1500 | 0 to 5000 | 9.4 |
| `workGate` | off | on/off | 8.5 |
| `maxMintPerYearBps` | 200 | 0 to 1000 | 9.1 |
| `guardianHandoverMembers` | 25 | | 8.6 |
| `stakeDenom` | `ugnot` | `ugnot` or a grc20reg key | 15 |
