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
- Provider set per feed, bonded in GNOT, rewarded from subscriptions and
  bounties, penalised for missed rounds, slashed after a lost
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
 Consumer realm ──Read(feed), subscribed per period ──────────────────────────► value + tier
                                                                             │
 Disputer ──bond GNOT, propose corrected value + slash tier──► dispute ──commit/reveal──► DAO verdict (+ appeal)
                                                                             │
                              slash wrong providers, pay disputer and coherent voters
                                                                             │
                                          Kourt adapter files, stakes, answers, settles a claim
```

| Role | Capital | Earns | Risks |
|---|---|---|---|
| Requester | feed deposit (GNOT), first subscription period or bounty | a live feed | deposit and prepayment are escrowed until activation: the deposit is refunded on activation, the prepayment becomes the first period or the bounty; both are refunded on rejection (spam forfeits the deposit only) |
| Sponsor | monthly subscription per feed (shared) | a funded feed for everyone who depends on it | none beyond the fee |
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
                 gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/kourt/impl/kourtv3  # implementation bound to the deployed Kourt v3 realm
                 gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/kourt/impl/v1   # development release bound to the stand-in kourtdev
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
- **Proxy and authority.** `proxy = upgradeable.New(upgradeable.NewAddrAuthority(guardian))`
  at bootstrap on `core` and `kourt`; the DAO's own proxy starts as
  `AnyOf(guardian, exec)`. Authority moves in two steps seven days apart
  (`ProposeAuthority(spec)`, `ExecuteAuthority()`, cancellable in between;
  `AuthorityTimelock` is a constant so the holder cannot shorten it), and a
  spec naming realms must include the DAO (the exec trampoline on the DAO).
  There are no extension realms: the state gate admits the permanent realm's
  own frame only, and a release that needs more surface uses the hooks below.
- **Release hooks.** Three permanent entry points keep the permanent surface
  final: `Invoke(cur, method, args)` forwards operations a release defines
  beyond the interface (new user-facing operations ship as release code);
  `SetNote`/`Note` attach release-defined data to any object by kind and id
  (fields the permanent structs do not have); `DefineParam`/`DefineParamStr`
  add governed parameters with bounds; `FeesPay` pays bounded incentives
  from the fee pool (`maxIncentivePay`). After deployment only a new money
  category needs a permanent redeploy. Implementation realms are nested (`core/impl/v1`), so the
  default `New` (nested only) applies. An implementation registers itself in
  its `init`: `core.RegisterImpl(cross(cur), &implV1{})`, which calls
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
- `dao` imports `core`; `core` cannot import `dao` back, so the DAO registers
  a `BallotHouse` object with the core at init and the core calls it through
  that interface (open ballot, finish, appeal round, fund voters). The Kourt
  mirror never enters the core's paths: it reads the core's dispute records
  and is advanced by its own `Crank`, so a Kourt failure can never block a
  resolution.
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
  "subscriberPrice": 10000000,
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
- `subscriberPrice` at least `subscriberFloor` per period, or zero for a
  sponsored feed (one-off feeds have none: outcomes are open to every realm); `subscriptionPrice` at least `subscriptionFloor` (default
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
  (default 50,000 GNOT); the DAO can still `feed-deprecate` it and remove
  the requester from the list by a `trusted-requester` proposal with cap 0.
  This is the path gnomarket markets use (§6.3).
- Reject: a `feed-deprecate` proposal on the proposed feed refunds the
  deposit and the escrowed prepayment (as credit when the requester is a
  realm); with the reason `spam` the deposit goes to the fee pool and the
  prepayment still returns.
- Unfunded: when the subscription pool cannot cover the next period,
  providers keep submitting if they want (rounds still aggregate) but miss
  penalties stop, and the status reported to consumers carries `unfunded`.
  Any sponsor payment reactivates it.
- Deprecate: by proposal, or automatically when a recurring feed has had no
  eligible submissions for `deadFeedRounds` (default 168). Deprecation
  refunds a one-off's undistributed bounty to the requester, sweeps a
  recurring pool to the fee pool and starts unbonding for every seated
  provider. A one-off whose round produced nothing may be reopened by the
  requester (`ReopenOneOff`) instead.
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
| `credits` | account addr | Credit{balance, spent} (~32): a realm requester's prepaid balance |
| `subscriptions` | feedID (8) + realm path | Subscription{realm, since, paidUntil, paid, periods} (~90) |
| `disputes` | disputeID (8) | Dispute{feedID, roundID, disputer, bond, proposedValue, tier, round, state, daoBallotID, kourtRecordID, outcome} (~220) |
| `params` | name | typed value with bounds and last-change height |

Submitters and eligibility are bitmasks over the active set's slot index. A
slot is retired when its provider leaves and reused only after every round
referencing it is pruned (slot generation counter).

Per hourly feed, a round record measures about 1.8 to 1.9 kB on v1.2.0
(packed values and slots), so steady-state growth is about 44 kB per day
(4.6 GNOT of deposit across all submitters), refunded on prune. Retention:
`roundRetention` 30 d after finality, at least `minRoundsKept` (64) rounds,
never a round inside its dispute window or under an unresolved dispute; a
retired feed past `retentionAfterDeprecate` keeps nothing.

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
- `Submit(cur, feedID, roundID, value int64)`: Active provider holding a
  slot, round open and at or after the provider's `ObligedFrom` (the round in
  progress at registration is not the newcomer's to serve), one submission per
  provider per round (resubmission inside the window overwrites). Emits
  `Submitted`. A round is judged against its slot holders of record (the slot
  log, `SlotHolderAt`), so a provider that leaves after submitting is still
  counted and paid for that round and a newcomer is not counted before its
  first obliged round; without this rule an out-of-set submission made the
  eligible count exceed the active count and the round unfinalisable (found
  and fixed in the M5 soak).
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
| Eligible submission in a finalised round | equal share of the round pool | pool = subscription pool / rounds per period + miss slashes + one-off bounty share + bootstrap subsidy | provider reward balance (pull) |
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

Rewards accrue to the provider's record at finalisation and are paid by
`ClaimRewards(cur, feedID)`. Rewards still unclaimed when a retired feed is
pruned (after `retentionAfterDeprecate`) forfeit to the fee pool, which is
what lets pruning be permissionless.

### 5.3 Value at risk shown to consumers

`:json/feed/<id>` and the feed page report `securityBudget = Σ active stake
x majorSlashBps / 10000`, `corruptionThreshold = ceil(n/2)` providers, and
`maxValueAtRisk = 50% x securityBudget x corruptionThreshold / n` (the
research pass's rule of thumb from UMA's cost-of-corruption > profit-from-
corruption). Consumers are told to keep the value a single provisional read
controls below that figure, or to wait for `final`.

---

## 6. Consumers, sponsors and fees

### 6.1 Reading

Chain state is public. Every value a feed ever served can be read off the
free pages and `:json` views, by people and by `vm/qeval`, the moment it
exists. What the protocol can gate is on-chain use: whether another realm may
consume a value inside its own logic. That gate is a subscription per realm
and per period; nothing is metered per read, because a per-read charge would
only tax the honest.

Consumer realms import the permanent `core` realm and call:

```go
func Read(cur realm, feedID uint64) (value int64, decimals int64, roundID uint64, updatedAt int64, tier string)
func ReadFinal(cur realm, feedID uint64) (value int64, decimals int64, roundID uint64, finalisedAt int64, tier string)
func ReadRound(cur realm, feedID, roundID uint64) (value int64, tier string, finalisedAt int64)
Render(":json/feed/<id>") string           // machine view (Appendix D): everything, at once
```

`Read` is a crossing call so the caller is known; it changes no state and
costs nothing per call. It serves a realm when the feed is one-off (an
outcome is public once final), when the feed is `sponsored` (its requester
pays for everyone), when the caller is the feed's own realm requester, or
when the caller's package path holds a subscription that covers now
(`SubscribeRealm`). An account calling `Read` is sent to the pages. The
permanent realm's getters carry no values (`GetFeed` and `GetRound` expose
everything but the numbers; the implementation reads them through its gated
`StateRef`), so a realm cannot route around the gate through state access.

The returned `tier` is `consensus`, `provisional`, `final`, `disputed` (the
last final round is served instead of the disputed one, and a voided latest
round falls back the same way), `stale` (no aggregated round within two
intervals) or `none`, with `,unfunded` appended while the feed's pool is
empty. `ReadFinal` always serves the last final round. A value is served at
the moment a realm asks, inside that realm's own transaction, so a consumer
that reads when it needs the number is never stale; one that polls and
caches (the demo's reader realm) is as fresh as its last poll.

### 6.2 Paying

Two flows fund a feed. Both are priced per `subscriptionPeriod` (30 days),
both are prepaid 1 to 12 periods at a time, and both split the same way
(fixed at the time of each payment): 70% to the feed's pool, dripped to the
providers per round, 15% to the DAO staker accumulator, 15% to the treasury
(which funds voter gas rebates, watcher bounties and the bootstrap subsidy).

- `Sponsor(cur, feedID, periods)`: `-send` `subscriptionPrice x periods`
  (floor 100 GNOT per period, typically around 1,000 GNOT). The requester
  pays the first period with the proposal; sponsors pay further ones; each
  payment extends `paidUntil` and adds to the pool (the drip per round is
  fixed at activation from `subscriptionPrice`, so more money lasts longer
  rather than paying more per round). A feed whose pool is empty is
  `unfunded`; after enough empty rounds it is deprecated.
- `SubscribeRealm(cur, feedID, pkgPath, periods)`: `-send` `subscriberPrice
  x periods` (a spec field with the DAO floor `subscriberFloor`), payable by
  anyone for any realm; a realm caller pays from its prepaid balance. It
  extends that realm's `paidUntil` on that feed. Sponsored and one-off feeds
  take none: they are open to every realm.
- `DepositFor(cur, account)`: `-send` into a prepaid balance. A realm cannot
  attach coins to its own calls (the call-scoped `CallSend` RFC of
  2026-09-19 would change that and is tracked), so a realm that requests
  feeds, funds bounties or subscribes is funded this way by its operator;
  refunds owed to a realm land in the same balance and `WithdrawCredit`
  takes it out. Reads never touch it.
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
calls `Read` once the tier is `final` (a categorical value is the option index). The gnomarket dispute path is replaced by this DAO's; its
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
  commitment)` with `commitment = hex(sha256("gnoracle|dispute|" || disputeID
  || "|" || ballotRound || "|" || choice || "|" || salt || "|" || voter))`.
  Recommitting overwrites (the CLI keeps a fresh salt for a changed choice).
- Reveal phase `revealPeriod` (default 24 h): `RevealVote(cur, disputeID,
  choice, salt)`. UMA's 24 h + 24 h reaches about 92% participation with
  slashing; Aragon uses 2 d + 2 d.
- Weight = `min(stakedAt(voter, sealedEpoch), stakedNow(voter))` (Kourt's
  rule). At tally time no single address counts for more than
  `maxVoterShareBps` (default 2000, 20%) of the *obligated* (sealed) weight;
  the cap is fixed and applied once to the heaviest reveals. (Capping against
  the revealed total has no fixed point when few members vote, which the
  first implementation showed; UMA's March 2025 vote had one holder at 25%.)
  Penalties and rewards use members' real weights; only the decision uses the
  clipped ones. The cap is gameable by splitting, which is why it is paired
  with the supermajority and the appeal.
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

- `UPHOLD`: bond forfeited: 50% to the feed's next round pool (the
  providers of the next finalised round), 30% to coherent voters, 20% to the
  treasury. The round returns to its prior tier and its dispute window
  restarts from resolution; a new dispute may be opened in that window.
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
is advanced by `Crank(cur, disputeID)` on the mirror realm, one step per
call; the bot and any cranker call it, `core` does not (the mirror imports
the core, not the other way round). Each record remembers the Kourt binding
it was filed under; a release bound to another Kourt refuses to touch it and
the authority can `Abandon` it.

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
  zero (`StartCourt` then accepts a realm caller), slug `gnoracle`. Kourt
  takes a non-zero burn only from a direct user call, so if the burn is set
  when the mirror goes live an account founds the court instead (any
  account: the mirror needs no right on it, and `EnsureCourt` says so).
- Which Kourt: decided and built. An import path is compile-time, so each
  mirror release binds one Kourt realm. `kourt/impl/kourtv3` binds the
  deployed Kourt v3 realm `gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3`
  (the two-way deployment with `Redeem`) and is the production release; its
  tests run against that realm's mirrored source, and gnodev serves the same
  source at the same path. `kourt/impl/v1` binds the local stand-in
  `gno.land/r/clockwork/gnoracle/kourtdev` for chains without Kourt. The v3
  release models Kourt's clocks rather than assuming them: an answer needs
  three epochs of stake history, which only advances when a stake is
  observed, so the mirror seals it with a one-unit top-up two epochs after
  staking; the answerability floor is 0.10% of the court's supply (min
  1 CC) and the mirror stakes twice what it sees, lifting the average if
  the court grew; the qualified answerers' 24 h priority window is waited
  out; an undisputed answer settles after 72 h; a disputed one goes through
  a one-week coin vote, an escrow of at least a week (reopenable) and
  `Finalize`; a claim unanswered for twelve weeks dies and the record closes
  as abandoned with the stake taken back. Every wait is read from Kourt's
  own `ClaimTimeline`, so a test clock armed on a development chain drives
  the mirror too. A release for another Kourt generation is a new directory
  under `kourt/impl/` named after it, accepted through the proxy.
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
- Decided: name `Pythia`, symbol `PYTH`, 6 decimals, 100,000,000 PYTH at
  genesis with a hard cap of 120,000,000 that only `mint` proposals may
  approach (at most `maxMintPerYearBps`, 2% a year), allocation as in §9.1.
  No automatic emission. Rewards to stakers are GNOT fees and forfeitures,
  not new tokens. `PYTH` is also the
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
  (or anyone; `settleTipBps` is reserved, no tip is paid in v1) calls
  `SettleMember` explicitly. A ballot that is still running or not yet funded
  by the core does not block stake changes; withdrawal waits for ballots the
  member holds weight in.
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
| `param` | name=value | 20% / >50% / 5 d + 2 d timelock; at most ±50% per change and once per block; hard floors (dispute window ≥ 2 h, per-voter cap ≤ 33%, stake floor ≥ 1,000 GNOT) | params.Set |
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
stakers' 15% of a subscription payment or forfeiture; each member has
`feeDebt`. `ClaimFees(cur)` pays `staked x accFeePerShare - feeDebt` in ugnot.
Unbonding stake does not earn. With `workGate` on, a member who revealed in
fewer than half of the disputes sealed during a 30-day window forfeits that
window's fee share to the treasury (§9.4).

### 8.6 Treasury and guardian

- The treasury is the DAO realm's own balance beyond what it owes (stakes,
  unbonding, rewards, fee shares, deposits): `TreasuryUgnot()` and
  `TreasuryPyth()` are derived, not separate accounts. Spends only by proposal. Standing
  programmes by proposal: voter gas rebates (UMA's Risk Labs pays about
  $45k/month of these), watcher bounties, bootstrap subsidies.
- Guardian: decided as a single key (the deployer's) until handover. Its
  powers are those of the proxy authority: activate, update and deprecate
  feeds, set parameters (at most ±50% per change and once per block), eject
  providers, accept or roll back releases, and hand the authority over.
  There is no pause: a mistaken release is rolled back, not paused. Every
  authority transfer is proposed, announced and executed seven days later;
  the realms refuse a realm-only authority that leaves the DAO out, and
  refuse to freeze while a key still holds the authority. The trust statement in
  the docs says so plainly: until handover one key governs the realms. The
  DAO executes `authority-transfer` to `NewRealmAuthority(daoPath)` on all
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

### 12.1 Provider agent (`agent/`, Go) — built

`gnoracle-agent` (`cmd/gnoracle-agent`, package `agent`) runs one loop per
configured feed against the pinned `gnoclient` (gno v1.2.0):

- Config `agent.toml` (`configs/agent.example.toml`): chain, key (a gnokey
  keybase copied into memory at start, or `GNORACLE_MNEMONIC`), gas policy,
  alert channel, one `[[feeds]]` table per feed with a source adapter and
  safety bounds.
- Each tick (default 5 s) reads `:json/feed/<id>` (one query carries block
  time, schedule, slots and the delayed aggregate), computes the round from
  chain time, and: cranks `CatchUp` for closed rounds after
  `finalize_delay` (adaptive batch, halved on out-of-gas); fetches, checks
  and submits when the round is open and our slot has not submitted (it
  reads `:json/feed/<id>/round/<r>`'s submitted mask first, so a restart never
  double-submits); claims rewards on `claim_every`.
- Adapters: `http` (median across URLs with a JSON path, headers, scale,
  `min_sources`), `gnoswap` (`OracleConsult` tick TWAP on
  `gno.land/r/gnoswap/pool`, converted with the tokens' decimals), `qeval`
  (any integer view), `exec` (a script), `file` (a human-written answer for
  one-off outcomes; the agent waits until the file exists).
- Safety: absolute `min`/`max`, `sanity_bps` against the agent's last
  submission or the public delayed aggregate (refusal is journaled and
  alerted; `override` forces), lower-median aggregation and a plurality rule
  for options, gas simulated before every send.
- Evidence: `journal.jsonl` records every source response (clipped), the
  aggregated value, refusals and every transaction with hash, gas and fee.
- Measured on gnodev (v1.2.0): `Submit` 17.7M to 18.6M gas, `Submit` that
  also finalises 28M to 32M (three providers), `CatchUp` of one round 27.1M;
  at the 0.001 ugnot/gas minimum with the 25% estimate margin a submission
  costs about 0.023 GNOT and the finalising one about 0.04 GNOT. When exactly
  one other provider is still to submit, the agent adds 14M headroom to its
  estimate: the simulation can run before that submission lands and the
  included call then finalises the round (observed on gnodev as one
  out-of-gas failure per round before the fix). The client asks for the
  larger of estimate plus margin and estimate plus headroom.
- `configs/agent.dev.toml` and `agent.dev2.toml` run two providers against
  gnodev (`make agent-dev`); rounds reach consensus and finalise early when
  both submit. `make agent-soak` (`scripts/agent-soak.sh`) is the plan's
  integration scenario: it creates and funds provider keys, registers them
  through the CLI, runs the agents and the bot for a few minutes and asserts
  aggregated rounds with two or more submitters, consensus, rewards for
  every agent, both conservation checks and the bot's announcements.
- Shipping: one container image with the three tools (`Dockerfile`, built
  from `golang:1.25` onto distroless, `CGO_ENABLED=0`); `.github/workflows/ci.yml`
  runs the Go and Gno suites, checks the simulation report is current, and
  publishes `ghcr.io/clockworkgr/gnoracle` on pushes to `main` and on `v*`
  tags.

### 12.2 Notifier and cranker bot (`bot/`) — built

`gnoracle-bot` (`cmd/gnoracle-bot`, package `bot`) needs no indexer: it
reads `block_results` from the node's JSON-RPC and decodes the `/tm.Event`
entries of successful transactions, filtered to the three realms.

- Announces (Telegram Bot API over HTTPS, or the log when no token is set)
  the event types in `events` (default: dispute lifecycle, proposals,
  provider jail/slash/eject, feed lifecycle, releases, authority, params,
  Kourt dissent) with the deadlines fetched from the `:json` views and a
  gnoweb link.
- Reminders: every 10 minutes it derives each running ballot's phase from
  block time and posts 24 h and 2 h before the commit and reveal deadlines,
  naming the opted-in members who have not acted, and messages them
  directly; the reveal opening is announced once.
- Cranks (with a key): `CatchUp` for feeds whose next round closed more than
  `finalize_grace` (120 s) ago, so live agents keep the tip; `ResolveDispute`
  once a ballot's reveal ended or a decided round's appeal window passed;
  Kourt `Crank` hourly for resolved disputes whose mirror is not terminal
  (a `dissent` result is posted); `SettleMember` daily for opted-in members
  with unprocessed resolved ballots. Each attempt is rate-limited in the
  state file; a lost race with another cranker costs one small fee.
- State: `bot-state.json` (scan cursor, announcements sent, attempts).

### 12.2a Operator CLI (`cmd/gnoracle`)

`gnoracle` reads every `:json` view (`status`, `feed`, `round`, `providers`,
`dispute`, `ballot`, `member`, `params`, `health`, `kourt`) and sends every
transaction with unit-aware amounts (`10000gnot`), feed-unit values
(`submit 1 current 1.2345`), and `commit`/`reveal` that generate the salt,
compute the commitment (`tally.Commitment`, cross-checked by test vectors)
and keep the salt file under `~/.gnoracle/votes` until the reveal is on
chain.

### 12.3 gnoweb pages (`Render`)

`core`: `:feeds`, `:feed/<id>` (spec, providers, `maxValueAtRisk`, delayed
values), `:feed/<id>/rounds`, `:disputes`,
`:dispute/<id>` (tallies once resolved, evidence hash, Kourt link with the
attribution badge), `:provider/<feed>/<addr>`, `:consumer/<addr>`, `:releases`
(live, pending, history). `dao`: `:members`, `:member/<addr>` (stake, pending
obligations, penalties in window), `:proposals`, `:proposal/<id>`, `:params`,
`:treasury`, `:releases`. Lists paged with `p/nt/bptree/pager/v0`; all user
text through `sanitize.InlineText`.

---

## 13. Testing strategy

| Layer | What | Tooling |
|---|---|---|
| Pure packages | median and majority edge cases, tier assignment at the boundaries, round arithmetic across long gaps, accumulator rounding (dust never leaks to users), checkpoints across epochs, commit hash round-trips, tally with clipping and both decision thresholds, penalty caps | `gno test`, table tests, seeded property loops |
| Realm flows | one narrative test per story: feed proposed to final; provider misses to jail to unjail; dispute upheld; overturn at minor tier; overturn downgraded from major to minor; void; failed quorum rolls to round 2; appeal reverses round 1; member absent then settled; unstake blocked by pending obligations; sponsor lapses to unfunded; Kourt crank through every state against a fake Kourt realm | `_test.gno` with `testing.SetRealm`, `SkipHeights`, `IssueCoins`, `SetOriginSend`; `r/clockwork/gnoracle/kourtdev` (the stand-in Kourt) |
| Upgrade | register `impl/v2`, accept through a DAO proposal, verify state untouched and `Health()` unchanged, roll back, verify the old release's `StateRef` is dead (`IsCurrent()` fails), freeze and verify `Accept` refuses | realm tests plus a filetest per proxy |
| Filetests | events for every entry point; `// Storage:` and `// Gas:` pins for §11 | `*_filetest.gno`, golden files updated only with a reviewed diff |
| Adversarial | stale `cur`, `maketx run` payments refused, non-canonical teller refused, reentrant proposal execution refused, a panicking Kourt callee does not block resolution, oversized spec and evidence refused, overflow attempts, an implementation trying to keep a `StateRef` across calls, an implementation calling a mutator that would break conservation | `adversarial_test.gno` per realm |
| Economic simulation | `docs/SIMULATION.md` (`go run ./sim`): deterministic break-even tables for provider gas by cadence, subscription prices, fee routing, miss penalties, voter exposure and dispute bonds; the stochastic run with honest, flaky, colluding and copycat providers and lazy, coherent, abstaining and bribed voters moves to the pearl-1 soak; sweeps the parameter table | `sim/` in Go, results in `docs/SIMULATION.md` |
| Integration | gnodev with three agents, one consumer realm, the bot in dry-run; a dispute end to end with the Kourt mirror against a local copy of `r/kourtv3` | `make chain-test` (feed lifecycle), `make agent-soak` (agents and bot with assertions), `make demo` (the whole story including the reader realm `demo/reader`, a resolved dispute and a settled Kourt claim, in about seven minutes; `docs/DEMO.md`) |
| Testnet soak | 4 weeks on `pearl-1` with at least 5 external providers, 2 feeds, at least 3 real disputes including one appeal, one live upgrade and one rollback | `docs/OPERATIONS.md` runbook |
| Review | external audit of the permanent realms, `impl/v1` and `p/ledger`; a mutation run like Kourt's on the money paths | before mainnet |

---

## 14. Milestones

One experienced Gno developer full time, with the agent and bot written in
parallel by a second person from M3.

| # | Milestone | Content | Exit criteria | Estimate |
|---|---|---|---|---|
| M0 | Spec | this document reviewed; decisions in §16 answered; toolchain pinned; repo scaffolded from `clockwork-gno-home`; `upgradeable/v0` mirrored into `deps/` | `make test` runs on v1.2.0 | **done 2026-09-23** |
| M1 | Pure packages | `spec`, `agg`, `rounds`, `ledger`, `checkpoint`, `tally`, `params` with unit tests and gas pins | every invariant in §10.2 has a test; simulation skeleton | **done 2026-09-23** (the `// Gas:` filetest pins move to M6; the economics tables are `docs/SIMULATION.md`) |
| M2 | Core without disputes | permanent `core` (interface, state, gated store, proxy, entry points), `core/impl/v1` feeds, providers, rounds, credits, sponsors, `Read`, prune; Render | three fake agents keep an hourly feed live for 48 h on gnodev; a consumer realm reads and is billed; an `impl/v2` is accepted and rolled back by the guardian | **done 2026-09-23**: realms and realm tests, `make chain-test` lifecycle on gnodev, the `impl/v2` accept-and-rollback rehearsal in `upgrade_test.gno`, and the multi-agent soak (`make agent-soak`, five-minute runs; the 48 h soak is part of the M6 testnet criteria) |
| M3 | Token and DAO | `token`, permanent `dao` plus `dao/impl/v1` staking, checkpoints, proposals, `feed-accept`, `upgrade-*` kinds, treasury, guardian | feeds accepted by vote; stake and unstake with cooldown; fee accumulator pays; an upgrade of `core` executed through a proposal with timelock | **done 2026-09-23** (realm tests: staking and weight, fee sync, feed-accept and param proposals on the core with timelock, treasury and rate-limited mint, DAO self-upgrade and rollback through the `dao/exec` trampoline; the founder vesting fields exist but no genesis vesting is applied yet) |
| M4 | Disputes and Kourt | dispute open, commit-reveal, clipping, supermajority, roll, appeal, penalties with lazy settle, forfeiture routing, `kourt` permanent realm plus `impl/v1` against a local stand-in Kourt realm, bot cranks | all dispute stories pass; a resolved dispute appears as a settled Kourt claim on the local chain; attribution shown | **done 2026-09-23** against the stand-in `kourtdev` realm (file, stake, answer, settle; contested claim recorded as dissent; "built on Kourt" on the mirror pages); the bot's cranking landed in M5 and the production release `kourt/impl/kourtv3`, bound to the deployed Kourt v3 realm and tested against its source (undisputed settle, overturn recorded as dissent, upheld vote as confirmed, redeem to the treasury), on 2026-09-23 |
| M5 | Agents and operations | provider agent with three adapters, bot with reminders, docs for consumers, providers, sponsors and members, `OPERATIONS.md`, simulation report | two outside testers run agents from the docs alone | **built 2026-09-23**: `gnoracle-agent` (five adapters: http, gnoswap, qeval, exec, file; sanity bounds; journal), `gnoracle-bot` (RPC event scanner, Telegram reminders, four cranks), `gnoracle` CLI (views, every transaction, commit-reveal salts), `:json` machine views on the three realms, `scripts/deploy.sh`, Dockerfile, `docs/OPERATIONS.md` and five role guides; soaked on gnodev with two agents and the bot; `docs/SIMULATION.md` (break-even tables from `go run ./sim`); `make agent-soak` integration scenario; container image and CI publishing to ghcr.io. Open: the acceptance run by two outside testers from the docs alone; **reviewed 2026-09-23**: eight-area code and documentation review, findings and fixes in `docs/REVIEW.md` |
| M6 | Testnet | deploy to `pearl-1`, soak 4 weeks, parameter tuning by DAO vote, one live upgrade and one rollback; the Kourt mirror is rehearsed on gnodev against the mirrored Kourt v3 source (pearl-1 has no Kourt v3 realm; its `kourt`/`kourt2` realms are another generation), or against a copy of the v3 source deployed under our namespace with a release bound to it | soak criteria in §13 met | 5 wk |
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
| Kourt target | the v3 realm `gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3`, bound by the release `kourt/impl/kourtv3`; another generation would be a new release directory accepted through the proxy | §7.4 |
| gnomarket requests | allowlisted trusted requesters activate one-off feeds without a vote under `trustedOneOffCap` | §4.2, §6.3, §8.3 |
| Guardian | single key (the deployer's) until handover at 25 staked members | §8.6 |
| Token | `Pythia` / `PYTH`, 6 decimals, 100,000,000 at genesis, 120,000,000 hard cap (mint by vote, 2%/yr), 40% treasury / 25% incentives / 20% liquidity / 15% founders (12 m cliff, 36 m vest via `SetVesting` or a `vesting` proposal) | §8.1, §9.1 |

Still open (needed before M3):

1. Who operates the first three provider agents and the notifier bot on
   pearl-1 (M5/M6).

---

## Appendix A. Public API (generated from the sources)

Generated by `scripts/gen-appendices.py`; edit the realms, not this section. Crossing functions take `cur realm` and are called with `cross(cur)`; the others are free views (`vm/qeval`). The behaviour behind each entry point lives in the live implementation realm.

### `gno.land/r/clockwork/gnoracle/core`

```go
func ProposeFeed(cur realm, specJSON string) uint64
func ActivateFeed(cur realm, feedID uint64)
func DeprecateFeed(cur realm, feedID uint64, reason string)
func UpdateFeed(cur realm, feedID uint64, changesJSON string)
func Sponsor(cur realm, feedID uint64, periods int64)
func FundBounty(cur realm, feedID uint64)
func Finalize(cur realm, feedID, roundID uint64)
func CatchUp(cur realm, feedID uint64, maxRounds int64) int64
func PruneRounds(cur realm, feedID uint64, maxRounds int64) int64
func PruneFeed(cur realm, feedID uint64)
func ReopenOneOff(cur realm, feedID uint64, resolveAt int64)
func Register(cur realm, feedID uint64, memo string)
func TopUp(cur realm, feedID uint64)
func Submit(cur realm, feedID, roundID uint64, value int64)
func RequestUnbond(cur realm, feedID uint64)
func Withdraw(cur realm, feedID uint64) int64
func Unjail(cur realm, feedID uint64)
func ClaimRewards(cur realm, feedID uint64) int64
func ForceUnbond(cur realm, feedID uint64, provider address)
func DepositFor(cur realm, account address)
func WithdrawCredit(cur realm, amount int64)
func SubscribeRealm(cur realm, feedID uint64, pkgPath string, periods int64)
func Read(cur realm, feedID uint64) (value int64, decimals int64, roundID uint64, updatedAt int64, tier string)
func ReadFinal(cur realm, feedID uint64) (value int64, decimals int64, roundID uint64, finalisedAt int64, tier string)
func ReadRound(cur realm, feedID, roundID uint64) (value int64, tier string, finalisedAt int64)
func Dispute(cur realm, feedID, roundID uint64, proposedValue int64, tier, evidence string) uint64
func Appeal(cur realm, disputeID uint64)
func ResolveDispute(cur realm, disputeID uint64)
func SetParam(cur realm, name string, value int64)
func SetTrustedRequester(cur realm, pkgPath string, cap int64)
func RegisterImpl(cur realm, impl Core)
func Accept(cur realm, pkgPath string)
func WithdrawImpl(cur realm, pkgPath string)
func Rollback(cur realm)
func Forget(cur realm)
func Freeze(cur realm)
func ProposeAuthority(cur realm, spec string) int64
func ExecuteAuthority(cur realm)
func CancelAuthority(cur realm)
func Invoke(cur realm, method, args string) string
func Render(cur realm, path string) string
func RegisterDAO(cur realm, h BallotHouse)
func ForwardFees(cur realm) int64
func SetParamStr(cur realm, name, value string)
```

Views:

```go
func PendingAuthority() (spec string, readyAt int64)
func LiveImpl() any
func LivePath() string
func PendingPaths() []string
func HistoryPaths() []string
func Frozen() bool
func Authority() string
func SelfPath() string
func HasDAO() bool
func Held() (stakes, unbonding, credits, pools, rewards, bonds, feesPending, deposits int64)
func HeldTotal() int64
func Balance() int64
func Health() string
func Param(name string) int64
func ParamStr(name string) string
func ParamsJSON() string
func Now() int64
func GetFeed(id uint64) *Feed
func GetProvider(feed uint64, addr address) *Provider
func GetRound(feed, round uint64) *Round
func GetCredit(addr address) *Credit
func GetSponsor(feed uint64, addr address) *Sponsorship
func GetSubscription(feed uint64, pkgPath string) *Subscription
func IsSubscribed(feed uint64, pkgPath string, t int64) bool
func IterateSubscriptions(feed uint64, fn func(*Subscription) bool)
func GetDispute(id uint64) *DisputeRecord
func TrustedCap(pkgPath string) int64
func SlotHolderAt(feed uint64, slot int64, r uint64) address
func Note(kind, id, key string) string
func FeedCount() uint64
func DisputeCount() uint64
func IterateFeeds(offset, count int, fn func(*Feed) bool)
func IterateProviders(feed uint64, fn func(*Provider) bool)
func IterateRounds(feed, start uint64, count int, fn func(*Round) bool)
func ReverseIterateRounds(feed uint64, count int, fn func(*Round) bool)
func Store(_ int, rlm realm) *StateRef
```

### `gno.land/r/clockwork/gnoracle/dao`

```go
func Stake(cur realm, amount int64)
func RequestUnstake(cur realm, amount int64)
func Withdraw(cur realm) int64
func SettleMember(cur realm, member address, maxN int64) int64
func ClaimFees(cur realm) int64
func ClaimRewards(cur realm) (int64, int64)
func SyncFees(cur realm) int64
func Propose(cur realm, kind, payload, title string) uint64
func Vote(cur realm, proposalID uint64, choice string)
func Execute(cur realm, proposalID uint64)
func Cancel(cur realm, proposalID uint64)
func OpenDisputeVote(cur realm, disputeID uint64, majorRequested bool, summary string) uint64
func CommitVote(cur realm, disputeID uint64, commitment string)
func RevealVote(cur realm, disputeID uint64, choice, salt string)
func FinishDisputeVote(cur realm, disputeID uint64) (string, string, int64)
func OpenAppealRound(cur realm, disputeID uint64) uint64
func FundVoters(cur realm, disputeID uint64, amount int64)
func RegisterImpl(cur realm, impl DAO)
func Accept(cur realm, pkgPath string)
func Rollback(cur realm)
func WithdrawImpl(cur realm, pkgPath string)
func Forget(cur realm)
func Freeze(cur realm)
func DevSetParam(cur realm, name string, value int64)
func ProposeAuthority(cur realm, spec string) int64
func ExecuteAuthority(cur realm)
func CancelAuthority(cur realm)
func Invoke(cur realm, method, args string) string
func Render(cur realm, path string) string
func RegisterTrampoline(cur realm, t Trampoline)
```

Views:

```go
func Hooks() core.BallotHouse
func PendingAuthority() (spec string, readyAt int64)
func LiveImpl() any
func LivePath() string
func PendingPaths() []string
func HistoryPaths() []string
func Frozen() bool
func Authority() string
func SelfPath() string
func Address() address
func Health() string
func Param(name string) int64
func ParamStr(name string) string
func ParamsJSON() string
func Now() int64
func Epoch() uint32
func GetMember(addr address) *Member
func GetProposal(id uint64) *Proposal
func VoteOf(id uint64, addr address) string
func GetBallot(seq uint64) *Ballot
func BallotOf(disputeID uint64) uint64
func CommitOf(seq uint64, addr address) string
func RevealOf(seq uint64, addr address) string
func PowerAt(addr address, epoch uint32) int64
func TotalPowerAt(epoch uint32) int64
func TotalStaked() int64
func MemberCount() int
func ProposalCount() uint64
func BallotCount() uint64
func MintedInYear(year int64) int64
func FeesOwed(addr address) int64
func Held() (stakedPyth, unbondingPyth, rewardPyth, feeUgnot, rewardUgnot, depositUgnot, knownUgnot int64)
func IterateProposals(offset, count int, fn func(*Proposal) bool)
func IterateMembers(offset, count int, fn func(*Member) bool)
func Store(_ int, rlm realm) *StateRef
func TreasuryUgnot() int64
func TreasuryPyth() int64
func Note(kind, id, key string) string
```

### `gno.land/r/clockwork/gnoracle/kourt`

```go
func Crank(cur realm, disputeID uint64) string
func EnsureCourt(cur realm) string
func RedeemFloat(cur realm, amount int64) int64
func Float(cur realm) int64
func Abandon(cur realm, disputeID uint64, reason string)
func RegisterImpl(cur realm, impl Mirror)
func Accept(cur realm, pkgPath string)
func Rollback(cur realm)
func WithdrawImpl(cur realm, pkgPath string)
func Forget(cur realm)
func Freeze(cur realm)
func ProposeAuthority(cur realm, spec string) int64
func ExecuteAuthority(cur realm)
func CancelAuthority(cur realm)
func SetAttribution(cur realm, text string)
func Invoke(cur realm, method, args string) string
func Render(cur realm, path string) string
```

Views:

```go
func GetRecord(disputeID uint64) *Record
func Count() uint64
func Address() address
func SelfPath() string
func Store(_ int, rlm realm) *StateRef
func PendingAuthority() (spec string, readyAt int64)
func Note(kind, id, key string) string
func LivePath() string
func PendingPaths() []string
func Authority() string
```

### `gno.land/r/clockwork/gnoracle/token`

```go
func Transfer(cur realm, to address, amount int64)
func Approve(cur realm, spender address, amount int64)
func TransferFrom(cur realm, from, to address, amount int64)
func Mint(cur realm, to address, amount int64)
func Burn(cur realm, amount int64)
func TransferMinter(cur realm, newMinter address)
```

Views:

```go
func TotalSupply() int64
func BalanceOf(owner address) int64
func Allowance(owner, spender address) int64
func Minter() address
func Render(path string) string
```

## Appendix B. Events (generated from the sources)

Every `chain.Emit` in the permanent realms and their implementations, with attribute keys in emission order (`<expr>` marks a computed key). The bot announces a configurable subset (`bot.DefaultEvents`).

### `gno.land/r/clockwork/gnoracle/core`

| event | attributes |
|---|---|
| `AppealOpened` | `dispute`, `appellant`, `bond` |
| `AuthorityCancelled` | `spec` |
| `AuthorityProposed` | `spec`, `readyAt` |
| `AuthorityTransferred` | `authority` |
| `BondReleased` | `dispute`, `to`, `amount` |
| `CreditDeposited` | `consumer`, `amount` |
| `CreditWithdrawn` | `consumer`, `amount` |
| `DAORegistered` | `path` |
| `DepositRefunded` | `feed`, `amount` |
| `DisputeDecided` | `dispute`, `round`, `outcome`, `tier` |
| `DisputeOpened` | `dispute`, `feed`, `round`, `disputer`, `bond`, `proposedValue`, `tier` |
| `DisputeResolved` | `dispute`, `round`, `outcome`, `tier`, `slashed` |
| `DisputeRolled` | `dispute` |
| `FeedActivated` | `feed`, `startAt` |
| `FeedDeprecated` | `feed`, `reason` |
| `FeedProposed` | `feed`, `proposer`, `specHash` |
| `FeedPruned` | `feed` |
| `FeedReopened` | `feed`, `resolveAt` |
| `FeedUnfunded` | `feed` |
| `FeedUpdated` | `feed` |
| `FeesForwarded` | `to`, `amount` |
| `Frozen` | (none) |
| `IncentivePaid` | `to`, `amount` |
| `ParamChanged` | `name`, `old`, `new` |
| `ParamDefined` | `name`, `default` |
| `ProviderEjected` | `feed`, `provider` |
| `ProviderJailed` | `feed`, `provider`, `jailings` |
| `ProviderRegistered` | `feed`, `provider`, `stake` |
| `ProviderSlashed` | `feed`, `provider`, `amount`, `reason` |
| `ProviderUnbonding` | `feed`, `provider`, `readyAt` |
| `ProviderWithdrawn` | `feed`, `provider`, `amount` |
| `RealmSubscribed` | `feed`, `realm`, `amount`, `paidUntil` |
| `ReleaseAccepted` | `path` |
| `ReleaseRolledBack` | `path` |
| `RewardsClaimed` | `feed`, `provider`, `amount` |
| `RewardsForfeited` | `feed`, `provider`, `amount` |
| `RoundFinalized` | `feed`, `round`, `status`, `tier`, `value`, `eligible`, `pool` |
| `Sponsored` | `feed`, `sponsor`, `amount`, `paidUntil` |
| `Submitted` | `feed`, `round`, `provider`, `value` |
| `TrustedRequester` | `path`, `cap` |
| `VotersFunded` | `dispute`, `amount` |

### `gno.land/r/clockwork/gnoracle/dao`

| event | attributes |
|---|---|
| `AuthorityCancelled` | `realm`, `spec` |
| `AuthorityProposed` | `realm`, `spec`, `readyAt` |
| `AuthorityTransferred` | `realm`, `authority` |
| `DisputeBallotOpened` | `dispute`, `ballot`, `round` |
| `DisputeBallotResolved` | `ballot`, `dispute`, `outcome`, `tier` |
| `FeesSynced` | `amount`, `stakers` |
| `Frozen` | `realm` |
| `MemberStaked` | `member`, `amount`, `staked` |
| `MemberUnstakeRequested` | `member`, `amount`, `readyAt` |
| `MemberVesting` | `member`, `until`, `floor` |
| `ParamChanged` | `name`, `old`, `new` |
| `ParamDefined` | `name`, `default` |
| `PenaltyCapped` | `member`, `forgiven` |
| `ProposalCreated` | `id`, `kind`, `proposer` |
| `ProposalStatus` | `id`, `status` |
| `ProposalVoted` | `id`, `voter`, `choice`, `weight` |
| `ReleaseAccepted` | `realm`, `path` |
| `ReleaseRolledBack` | `realm`, `path` |
| `RewardShortfall` | `member`, `pending`, `available` |

### `gno.land/r/clockwork/gnoracle/kourt`

| event | attributes |
|---|---|
| `AuthorityCancelled` | `realm`, `spec` |
| `AuthorityProposed` | `realm`, `spec`, `readyAt` |
| `AuthorityTransferred` | `realm`, `authority` |
| `FloatRedeemed` | `amount` |
| `KourtDissent` | `dispute`, `claim` |
| `KourtRecord` | `dispute`, `state` / `dispute`, `state`, `claim` |

## Appendix C. Parameter registry (generated from the sources)

Defaults, bounds and the per-call change limit (`MaxChangeBps`, 5000 = at most 50% per change; the bounds themselves and one-unit steps are always allowed). A parameter changes at most once per block height. Amounts are ugnot (PYTH base units on the DAO), times are seconds.

### `gno.land/r/clockwork/gnoracle/core`

| name | default | min | max | change | what |
|---|---|---|---|---|---|
| `feedDeposit` | 5,000,000 | 1,000,000 | 1,000 GNOT/PYTH (1000000000) | 5000 | deposit attached to a feed proposal, refunded unless spam |
| `providerMinStakeFloor` | 10,000 GNOT/PYTH (10000000000) | 1,000 GNOT/PYTH (1000000000) | 1,000,000 GNOT/PYTH (1000000000000) | 5000 | smallest providerMinStake a spec may set |
| `subscriptionFloor` | 100 GNOT/PYTH (100000000) | 10,000,000 | 100,000 GNOT/PYTH (100000000000) | 5000 | smallest subscriptionPrice per period |
| `subscriberFloor` | 2,000 | 0 | 100,000 GNOT/PYTH (100000000000) | 5000 | smallest subscriberPrice per period a non-sponsored recurring spec may set |
| `bountyFloor` | 50,000,000 | 1,000,000 | 100,000 GNOT/PYTH (100000000000) | 5000 | smallest one-off bounty |
| `subscriptionPeriod` | 30 d (2592000 s) | 7 d (604800 s) | 90 d (7776000 s) | 5000 | length of one subscription period |
| `maxCatchUpRounds` | 48 | 1 | 500 | 5000 | stale rounds written off per CatchUp call |
| `roundRetention` | 30 d (2592000 s) | 7 d (604800 s) | 365 d (31536000 s) | 5000 | seconds after finality before a round may be pruned |
| `minRoundsKept` | 64 | 8 | 10,000 | 5000 | rounds always kept per feed regardless of age |
| `retentionAfterDeprecate` | 90 d (7776000 s) | 30 d (2592000 s) | 730 d (63072000 s) | 5000 | seconds after deprecation before a feed may be pruned |
| `deadFeedRounds` | 168 | 24 | 10,000 | 5000 | consecutive empty rounds after which a feed is deprecated on prune |
| `maxIncentivePay` | 10,000,000 | 0 | 1,000 GNOT/PYTH (1000000000) | 5000 | largest fee-pool payment a release may make per call (tips, bounties) |
| `trustedOneOffCap` | 50,000 GNOT/PYTH (50000000000) | 0 | 10,000,000 GNOT/PYTH (10000000000000) | 5000 | largest declared value at stake a trusted requester may self-activate |
| `missSlashBps` | 50 | 0 | 500 | 5000 | slash per missed round on a funded feed |
| `missSlashCapPerEpochBps` | 500 | 0 | 10,000 | 5000 | largest total miss slash per provider per providerEpoch |
| `providerEpoch` | 7 d (604800 s) | 1 d (86400 s) | 90 d (7776000 s) | 5000 | window of the miss slash cap and the minor-slash escalation |
| `alerterShareBps` | 5,000 | 0 | 10,000 | 5000 | share of a miss slash paid to whoever recorded it |
| `jailAfterMisses` | 3 | 1 | 20 | 5000 | consecutive misses that jail a provider |
| `jailCooldown` | 1 d (86400 s) | 1 h (3600 s) | 30 d (2592000 s) | 5000 | seconds before a jailed provider may unjail |
| `maxJailings` | 3 | 1 | 20 | 5000 | jailings within 30 days that force unbonding |
| `strikesToJail` | 5 | 1 | 100 | 5000 | out-of-tolerance submissions within strikeWindowRounds that jail |
| `strikeWindowRounds` | 100 | 10 | 10,000 | 5000 | rounds over which strikes are counted |
| `minorSlashBps` | 500 | 100 | 2,000 | 5000 | slash at the minor tier after a lost dispute |
| `majorSlashBps` | 10,000 | 5,000 | 10,000 | 5000 | slash at the major tier after a lost dispute (ejects) |
| `minorsToMajor` | 3 | 2 | 10 | 5000 | minor slashes within a providerEpoch that escalate to major |
| `unbondPeriod` | 14 d (1209600 s) | 7 d (604800 s) | 60 d (5184000 s) | 5000 | seconds between RequestUnbond and Withdraw |
| `crankTipBps` | 100 | 0 | 1,000 | 5000 | share of a round pool paid to whoever finalises it |
| `feeSplitProvidersBps` | 7,000 | 0 | 10,000 | 5000 | share of subscription payments (feed funding and realm subscriptions) to the feed pool |
| `feeSplitStakersBps` | 1,500 | 0 | 5,000 | 5000 | share of subscription payments to DAO stakers |
| `minDisputeBond` | 2,500 GNOT/PYTH (2500000000) | 100 GNOT/PYTH (100000000) | 100,000 GNOT/PYTH (100000000000) | 5000 | smallest dispute bond |
| `disputeBondBps` | 1,000 | 100 | 10,000 | 5000 | dispute bond as a share of the feed's active stake |
| `disputeEscalationWindow` | 7 d (604800 s) | 1 d (86400 s) | 90 d (7776000 s) | 5000 | seconds within which repeat disputes on a feed double the bond |
| `appealWindow` | 1 d (86400 s) | 1 h (3600 s) | 7 d (604800 s) | 5000 | seconds after a decided round in which an appeal may be posted |
| `appealBondMultiple` | 2 | 1 | 10 | 5000 | appeal bond as a multiple of the dispute bond |
| `appealConsumeBps` | 2,500 | 0 | 10,000 | 5000 | share of a losing appeal bond consumed |
| `voidConsumeBps` | 500 | 0 | 2,000 | 5000 | share of the bond consumed on a void outcome |
| `forfeitSplitWinnerBps` | 5,000 | 0 | 10,000 | 5000 | share of forfeitures to the prevailing party |
| `forfeitSplitVotersBps` | 3,000 | 0 | 10,000 | 5000 | share of forfeitures to coherent voters |
| `kourtRealm` | "" |  |  | text | package path of the Kourt adapter realm |

On a development chain (chain id `dev`: gnodev) these bounds are relaxed so `make demo` can run in minutes (`docs/DEMO.md`): `appealWindow` min 10. The defaults are the same everywhere; on the DAO the relaxed values are set with `DevSetParam`, which refuses on any other chain.

### `gno.land/r/clockwork/gnoracle/dao`

| name | default | min | max | change | what |
|---|---|---|---|---|---|
| `epochBlocks` | 720 | 720 | 720 | 0 | blocks per voting-weight epoch |
| `unstakeCooldown` | 7 d (604800 s) | 3 d (259200 s) | 60 d (5184000 s) | 5000 | seconds between RequestUnstake and Withdraw |
| `settleMaxN` | 20 | 1 | 200 | 5000 | resolved disputes processed per member per settle |
| `settleTipBps` | 50 | 0 | 1,000 | 5000 | share of settled penalties paid to whoever runs SettleMember |
| `stakerFeeShareBps` | 5,000 | 0 | 10,000 | 5000 | share of forwarded fees credited to stakers (rest to the treasury) |
| `absenceSlashBps` | 50 | 0 | 1,000 | 5000 | penalty per dispute a member did not reveal in |
| `incoherenceSlashBps` | 50 | 0 | 2,000 | 5000 | penalty per dispute a member voted against the outcome |
| `abstainSlashBps` | 5 | 0 | 500 | 5000 | penalty per dispute a member abstained in |
| `maxPenaltyPerWindowBps` | 500 | 0 | 10,000 | 5000 | largest total penalty per member per penaltyWindow |
| `penaltyWindow` | 30 d (2592000 s) | 7 d (604800 s) | 365 d (31536000 s) | 5000 | window of the penalty cap |
| `maxVoterShareBps` | 2,000 | 1,250 | 3,300 | 5000 | largest share of revealed weight one address may hold |
| `disputeQuorumBps` | 3,300 | 500 | 10,000 | 5000 | round-1 quorum of obligated weight |
| `decisionBps` | 6,000 | 5,001 | 10,000 | 5000 | round-1 share of the two sides a side needs |
| `disputeQuorumBps2` | 2,500 | 500 | 10,000 | 5000 | round-2 quorum |
| `decisionBps2` | 5,500 | 5,001 | 10,000 | 5000 | round-2 decision bar |
| `commitPeriod` | 1 d (86400 s) | 6 h (21600 s) | 14 d (1209600 s) | 5000 | round-1 commit phase |
| `revealPeriod` | 1 d (86400 s) | 6 h (21600 s) | 14 d (1209600 s) | 5000 | round-1 reveal phase |
| `commitPeriod2` | 2 d (172800 s) | 6 h (21600 s) | 14 d (1209600 s) | 5000 | round-2 commit phase |
| `revealPeriod2` | 1 d (86400 s) | 6 h (21600 s) | 14 d (1209600 s) | 5000 | round-2 reveal phase |
| `proposeBps` | 25 | 0 | 1,000 | 5000 | share of staked supply a proposer must hold to skip the deposit |
| `proposalDeposit` | 20,000,000 | 0 | 1,000 GNOT/PYTH (1000000000) | 5000 | deposit for a proposer below proposeBps, refunded on quorum |
| `maxActiveProposals` | 32 | 8 | 128 | 5000 | live proposals at once |
| `executionWindow` | 7 d (604800 s) | 1 d (86400 s) | 90 d (7776000 s) | 5000 | seconds after the timelock in which a passed proposal may execute |
| `minStake` | 1,000,000 | 1 | 1,000,000 GNOT/PYTH (1000000000000) | 5000 | smallest stake that makes a member |
| `maxMintPerYearBps` | 200 | 0 | 1,000 | 5000 | largest mint per 365 days as a share of supply |
| `upgradeTimelock` | 7 d (604800 s) | 1 d (86400 s) | 30 d (2592000 s) | 5000 | timelock of upgrade-accept proposals |
| `guardianHandoverMembers` | 25 | 1 | 1,000 | 5000 | staked members at which the guardian hands authority over |
| `kourtRealm` | "" |  |  | text | package path of the Kourt adapter realm |

On a development chain (chain id `dev`: gnodev) these bounds are relaxed so `make demo` can run in minutes (`docs/DEMO.md`): `epochBlocks` min 10, change 5,000; `commitPeriod` min 30; `revealPeriod` min 30; `commitPeriod2` min 30; `revealPeriod2` min 30; `executionWindow` min 60; `upgradeTimelock` min 30. The defaults are the same everywhere; on the DAO the relaxed values are set with `DevSetParam`, which refuses on any other chain.

## Appendix D: machine views

Every realm serves JSON under `Render(":json/...")` (read with `vm/qrender`,
`gnoracle`, or any HTTP client through gnoweb). Objects carry `now` (block
time) so readers compute rounds without a second query; values obey the
render delay of §6.1 (`"delayed": true` until final and `renderDelay` old).
Unknown members must be ignored by readers; releases may add fields.

`core`:

| path | content |
|---|---|
| `json/now` | `now`, `height`, `live` |
| `json/feeds[/<offset>[/<count>]]` | `total`, `feeds[]` summaries (id, name, kind, valueType, status, startAt, interval, submitWindow, decimals, activeCount, maxProviders, haveLast, lastFinalized, openDisputes) |
| `json/feed/<id>` | the feed record, `slots[15]`, `currentRound` with `currentOpenAt`/`currentCloseAt`, `value` once delayed, `spec{...}` |
| `json/feed/<id>/round/<r or current>` | `exists`, `status`, `opensAt`, `closesAt`, `open`, `closed`, `submittedMask`, `submitted[]{slot,addr}`, and once delayed `value` and `values[]{slot,addr,value,eligible}` |
| `json/feed/<id>/rounds[/<n>]` | the last `n` round records |
| `json/feed/<id>/provider/<addr>` | the provider record (stake, status, slot, obligedFrom, misses, strikes, jailings, rewards) |
| `json/feed/<id>/providers` | all providers of the feed |
| `json/dispute/<id>` | the dispute record with `appealWindowEnds` while decided |
| `json/disputes[/<from>[/<count>]]` | `total`, `disputes[]` |
| `json/credit/<addr>` | a consumer's credit |
| `json/params`, `json/health` | the registry and the conservation check |

`dao`: `json/now` (epoch, totals), `json/member/<addr>` (power, cursor,
pending rewards, `feesOwed`), `json/members`, `json/ballot/<seq>`,
`json/ballot/dispute/<id>`, `json/ballots[/<from>[/<count>]]` (the most
recent page by default), `json/commit/<seq>/<addr>`,
`json/reveal/<seq>/<addr>`, `json/proposal/<id>`, `json/proposals`,
`json/params`, `json/health`. A ballot's `phase` is the last phase written
on chain; readers derive the live phase from `commitEnds`/`revealEnds`.

`kourt`: `json/now` (court, bound Kourt path, counts), `json/record/<dispute>`,
`json/records[/<from>[/<count>]]`.

The Go structs in `internal/gnochain/views.go` mirror these objects.
