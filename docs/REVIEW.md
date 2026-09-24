# Code and documentation review, 2026-09-23

An eight-area review of the whole repository before the testnet milestone:
the permanent core realm, its implementation, the DAO and token, the pure
packages, the Kourt mirror and the upgrade proxy, the Go tools, the scripts
and CI, and documentation alignment. Each reviewer read its area end to end
and reproduced the serious findings with scratch tests; everything below was
then verified again and fixed or explicitly deferred. The fixes landed in
three commits ("Review fixes across the realms and pure packages", "Review
fixes for the Go tools, scripts and CI, with regression stories", and the
documentation pass); all Gno and Go suites, lint and the live soak pass on
the result.

Severity: **C** critical (funds or liveness at risk from an ordinary user),
**H** high, **M** medium, **L** low.

## Fixed

### Core realm (permanent) and its implementation

| sev | finding | fix |
|---|---|---|
| H | Inflow setters trusted the implementation's amounts: a buggy or malicious release could book coins that never arrived and drain the realm through later withdrawals. | Every setter that books incoming coins asserts the realm's balance covers everything it owes plus the new amount (`inflow`). |
| H | A round under a decided or appealed dispute could be pruned; the dispute became unresolvable and the feed's served tier stayed `disputed` forever. | `RoundDelete` and `PruneRounds` refuse while the dispute is not resolved, and never prune inside the dispute window. |
| H | A rejected feed request forfeited its prepaid period or bounty to the fee pool; the plan promised a refund. | The prepayment is escrowed with the deposit until activation and refunded on rejection; spam forfeits the deposit only. |
| C | One-off feeds: any slot change after round 0 opened rewrote the slot log at round 0, so a provider could submit a fabricated outcome, unbond, and dodge the slash; a newcomer could overwrite it. | `obligedFrom` returns a round that never exists once a one-off opened; registration is refused after the opening. |
| H | `PruneFeed` could never succeed (`minRoundsKept`) and deleted providers while iterating them. | A retired feed past its retention keeps no rounds; providers are collected first, rewards forfeit, ready unbonds are paid, stake left blocks the prune. |
| M | The disputed or voided value was served with a label instead of the last final value; the quarantine reference was the last aggregate, so a provisional jump became the reference. | The feed tracks its last final round (window passed, no dispute standing); `Read` serves it while the latest round is disputed or voided, `ReadFinal` always serves it, and it is the quarantine reference. |
| M | Deprecated feeds re-accumulated read fees and stayed unprunable; providers stayed seated on dead feeds. | Reads, finalisation and catch-up refuse retired feeds; deprecation starts unbonding for every seated provider, refunds a one-off bounty and sweeps a recurring pool; `PruneFeed` sweeps leftovers. |
| M | Extensions could decrement the ledger while paying from their own account. | Coin moves are refused from extensions (state-only), on all three realms. (Superseded: extensions were removed; releases add operations, data and parameters through `Invoke`, notes and `DefineParam`, see the deferred list.) |
| M | A typo in `TransferAuthorityToRealms` or a premature `Freeze` could lock a realm out of governance for good. | Realm-only authorities must include the DAO; freezing needs a realm authority; the authority check runs first. (Superseded: `TransferAuthorityToRealms` was replaced by the two-step, timelocked `ProposeAuthority` / `ExecuteAuthority` with an `authspec`; a realm authority must still include the DAO.) |
| M | The parameter rate limit could be chained inside one transaction and trapped small values above zero. | One change per parameter per block; the bounds themselves and one-unit steps are always allowed. |
| L | Unbonding stake dodged miss slashes; ejection cleared the slot retroactively; a sponsorship could evict a longer one; read fees were folded into the long-lived pool; empty one-off rounds stranded the bounty; sign guards were missing; outflows emitted no events; deleted feeds left index entries; minor-slash escalation counted across epochs; a one-off miss never jailed; a final-only reader paid for nothing (metered reads were removed later); a dispute on an old round marked the whole feed disputed; a resolved round could not be disputed again in its restarted window; the round view panicked on huge ids and attributed submissions to current holders. | All addressed (see the commit message for the list). |

### DAO and token

| sev | finding | fix |
|---|---|---|
| H | Treasury payouts decremented the known balance twice, so the next sync handed phantom income to stakers. | `sendUgnot` alone keeps the known balance. |
| H | Proposal deposits were not booked in the known balance and were counted as fee income. | Booked on creation. |
| H | Any running ballot blocked staking, unstaking and withdrawal for every member. | Strict settlement blocks only on a resolved and funded ballot; withdrawal waits only for ballots the member holds weight in. |
| H | Ballots resolved at the decision but were funded when the core applied the outcome; a settlement in between forfeited the member's ugnot share (the bot did this daily). | Ballots carry a `final` flag set when the core applies the outcome (always called, amount possibly zero); settlement waits for it. |
| H | Reward payment panicked whenever the penalty pool was short and blocked the ugnot leg too. | The treasury covers the PYTH leg, a shortfall is reported, and the ugnot leg is independent. |
| M | Share changes ran before syncing fees; newcomers started at cursor zero; vesting had no way to be set; a second unstake restarted the cooldown; early execution aborted instead of recording the tally; the payload could escape its fence; thresholds carried at equality; rolled-round penalties were stranded; proposals could not reach the Kourt realm. | All addressed: fees sync first, cursor starts at the ballot count, vesting is set by a `vesting` proposal (no direct setter), second unstake waits, tally recorded without abort, backticks neutralised, strictly greater than the bar, rolled-round penalties go to the treasury, `kourt` is a proposal target and `kourt-abandon` exists. |

### Pure packages

| sev | finding | fix |
|---|---|---|
| H | Spec amounts had no upper bound; basis-point arithmetic wrapped into a credit mint. | Every amount is bounded by 1e15 ugnot; fees must be positive. |
| H | The fee accumulator could be wedged by one tiny share receiving a large bump. | The per-share value is capped, excess waits in carry, and a partial unstake must leave at least `minStake` staked. |
| M | A one-off window had no maximum (overflow in the schedule); the categorical tier applied the numeric move test; parameter bounds were unreachable; the registry emitted Go escapes; duplicated JSON keys parsed last-wins. | All addressed. |

### Kourt mirror and upgrade proxy

| sev | finding | fix |
|---|---|---|
| H | A third party answering the mirror's claim wedged the record and stranded its stake. | A foreign answer is recorded; dissent is derived from the verdict. |
| M | Records did not remember their Kourt binding; a rebinding release would crank another court's claims. | Records carry their binding; a release refuses foreign records; the authority may `Abandon` them. |
| M | No proposal kind reached the Kourt realm; no money primitive; attribution lived in the replaceable release. | Proposals target `kourt`; `SendToTreasury`; the header lives in the permanent `Render`; `WithdrawImpl` and `Forget` exist. |

### Go tools

| sev | finding | fix |
|---|---|---|
| H | The double-submission guard fell through to a blind submission when the round view errored. | Never submit without the mask. |
| H | Feed loops shared one key without serialisation; sequence races surfaced as signature failures and lost claims. | One transaction at a time per client; claims recorded only on success; the error is named. |
| M | Headroom carried no margin; the Telegram token reached the logs; same-type events in one transaction collapsed; the state file had no schedule or chain identity; the Kourt crank paid hourly for records that could not advance; `sanity_bps = 0` did not disable; numeric labels never aggregated. | All addressed. |
| L | State race, unvalidated durations, token with no chat, last-second submissions, re-commit refusal, crank race economics, API keys in the journal, stale obligation cache. | All addressed. |

### Scripts, build and CI

| sev | finding | fix |
|---|---|---|
| C | `deploy.sh` passed `-deposit`, a flag gnokey v1.2.0 does not have. | `-max-deposit`. |
| H | Gas and deposit defaults were below what the core realm needs; `kourt/impl/v1` imports the stand-in and would fail on mainnet; the keybase defaulted into the repository; realm-call gas was too low for chain-test; the toolchain cache could hide a missing GNOROOT. | Defaults sized from simulation; the stand-in release ships only with the stand-in; the keybase defaults to the user's config directory; 60M call gas; the toolchain fetches the gno sources. |
| M | Half-fetched mirror packages looked complete; the image's state directory was root-owned; operator configs were not ignored; CI published an image without the Gno suites; port defaults disagreed. | All addressed. |

### Documentation

The plan's Appendices A (entry points), B (events) and C (parameters) are
now generated from the sources by `scripts/gen-appendices.py`, and CI fails
when they are stale. Sections 2, 3, 4, 5, 6, 7, 8, 9, 12 and 13 of the plan,
the runbook, the five guides, the README, the example configs and the
showcase were corrected where they disagreed with the code (token supply and
cap, commitment format, sponsor model, disputed reads, rejection refunds,
proposal kinds and bars, the guardian's powers, gnoweb paths, the storage
budget, Kourt cranking, the vote choice case, the approval step before
staking).

## Deferred, with reasons

- **`settleTipBps`** was recorded but never paid; the parameter was removed
  in the third review (2026-09-24). A tip or penalty share for third-party
  settlement waits for a design; a release can pay one from the fee pool
  with `FeesPay`, bounded by `maxIncentivePay`.
- **`guardianHandoverMembers`** was removed as a parameter in the third
  review; the handover at 25 members stays a published policy. Every
  authority transfer is a two-step, timelocked operation
  (`ProposeAuthority`, seven days, `ExecuteAuthority`) that anyone can see
  and the authority can cancel, which is the enforceable part; a
  member-count floor would trap the guardian if the community stalled.
- **Extensions were removed** rather than completed: the state gate admits
  the permanent realm alone, and releases add operations, data and
  parameters through `Invoke`, notes and `DefineParam` instead.
- **The inflow guard has no rogue-implementation test.** It is exercised by
  the money paths of every story, but a filetest that registers a malicious
  release and watches it fail belongs in the audit preparation (M7).
- **Kourt v3 binding.** Closed after the review: `kourt/impl/kourtv3` binds
  the deployed Kourt v3 realm and models its clocks (three epochs of stake
  history sealed by a top-up, the dynamic answer floor, the priority window,
  the 72 h settle, vote then escrow then `Finalize`, dead claims closed as
  abandoned with the stake taken back), tested against the realm's mirrored
  source including an overturn and an upheld vote. What remains is
  operational: the float has to be funded from an account (`Buy` is a
  direct user call on Kourt) and watched (`docs/OPERATIONS.md` §3).
- **Attribution.** The mirror shows the "built on Kourt" text link on every
  page; whether the licence's badge image is required on gnoweb is a question
  for the licence holder before M6.
- **Sponsor overpayment** above `periods x subscriptionPrice` joins the pool
  rather than being refunded; documented.
- **Metered reads removed (2026-09-24).** The permanent getters exposed
  fresh values to any realm and to `qeval`, so per-read charges and the
  page delay metered nothing. Reads are now free per call and side-effect
  free, served to realms with a per-period subscription (`SubscribeRealm`),
  to every realm on sponsored and one-off feeds, and to a feed's own realm
  requester; the getters carry no values and the implementation reads them
  through the `StateRef`; the pages show everything at once. Credits remain
  only as the prepaid balance a realm requester spends on proposals,
  bounties and subscriptions.
- **Development-chain floors.** Added for `make demo` (2026-09-24): on a
  chain whose id is `dev` the floors of `appealWindow`, the ballot phases,
  `upgradeTimelock` and `executionWindow` are lower, and the
  DAO exposes `DevSetParam`, which refuses on any other chain id. The
  defaults are untouched everywhere and the gate is one function per realm
  (`devFloor`); an auditor should confirm the gate reads the chain id and
  nothing else. The test harness runs realm calls under an empty chain id,
  so the suites exercise the production floors. Since the third review
  `epochBlocks` is fixed rather than floored: 720, or 10 on a `dev` chain
  from genesis, and no proposal or `DevSetParam` can change it (a change
  would move every sealed epoch).
- **Weights for penalties** use the smaller of the sealed and the live stake;
  unchanged and documented in the plan.

# Second review, 2026-09-24

A review of the whole repository after metered reads were replaced by
per-period realm subscriptions and the permanent APIs were finalised: the
core realm and its release, the DAO, the Kourt mirror and its v3 release,
the tools, scripts and documentation. Everything below was fixed in the
code and the suites, and the documentation was aligned with the result.

## Fixed

### Core realm and its implementation

| sev | finding | fix |
|---|---|---|
| H | `Render` bypassed the read gate: a realm could call the core's `Render` (or a `:json` view) and read every value without the subscription `Read` requires. | The permanent `Render` answers a realm caller with a short refusal; user calls, `vm/qrender` and `MsgRun` scripts are served. Realms read through `Read`, `ReadFinal` and `ReadRound`. |
| M | `SubscribeRealm` read the transaction's `-send` even when a realm was paying, so a realm paying from its prepaid balance failed when the transaction carried coins. | The sent amount is taken only on a user call; a realm always pays from its prepaid balance. |
| M | `FundVoters` sent bond coins to the DAO without taking them out of the held-bonds category. | `FundVoters` debits `Bonds` first and refuses when the category or the balance is short; a zero amount still marks the ballot final. |
| M | A spec could spell a known field with JSON escape sequences and slip past the duplicate-key check. | Escaped characters in field names are refused. |
| M | `MulBps` multiplied before dividing and could overflow on large amounts. | Computed without the full product; safe for any amount up to `MaxInt64` and any rate up to 10,000 bps. |
| M | Pruning a retired feed walked every index entry in one call, and the subscribers views listed every record. | `PruneFeed` removes at most 256 index entries per call (emitting `FeedPruning` until `FeedPruned`); the subscribers page and `json/feed/<id>/subscribers[/<offset>[/<count>]]` are paginated. |
| L | A subscription's `periods` did not count the periods paid. | Each payment adds the number of periods it buys. |
| L | `ForwardFees` could run before the DAO registered. | Nothing moves and it returns 0 until the DAO is registered. |
| L | Dead code: `FeeAccrued`, the `feeSplitStakersBps` parameter and unused setters. | Removed. |
| M | `ReopenOneOff` left departed or jailed providers obliged to the reopened round. | Active providers are obliged from round 0 again; others are not. |
| M | A subscribed realm path was stored and rendered as given. | `SubscribeRealm` accepts only `gno.land/r/` followed by `[a-z0-9_]` segments with single slashes, at most 128 bytes; pages escape what they print. |
| M | The categorical slash spared providers "within tolerance" of the established option index. | A categorical provider is spared only when its submission equals the established value exactly. |
| M | `UpdateFeed` accepted amounts and dispute windows `spec.Parse` would refuse for a new feed. | The same caps apply: amounts at most 1e15 ugnot, the dispute-window ceiling of a new feed, the price and stake floors. |
| M | `Read` could serve a voided round's replacement under a tier other than the one `ReadFinal` reports. | A voided round is replaced by the last final round, served as `final` (unless stale), consistent with `ReadFinal`. |
| M | Pruning could delete rounds past the final cursor, before they were examined for promotion. | Pruning stops at `FinalCursor`. |
| M | Auto-deprecation after `deadFeedRounds` empty rounds left providers seated. | Retirement unseats every active or jailed provider and starts their unbonding, as `DeprecateFeed` does. |
| L | An unfunded feed stayed unfunded after a subscription refilled its pool. | A subscription that brings the pool back to the drip reactivates the feed. |
| M | The rehearsal release `core/impl/v2` let anyone `define` a parameter or `tip` from the fee pool through `Invoke`. | `define` and `tip` require `IsAuthority`. |

### DAO

| sev | finding | fix |
|---|---|---|
| H | An appealed round-1 ballot never became final (the core applies only round 2), so it blocked every member's settlement for good. | An appeal supersedes round 1: it settles like a rolled round (absence and abstention penalties only, to the treasury) and is final at once. |
| M | Withdrawal ran while a ballot the member holds weight in was resolved but not yet applied by the core. | Withdrawal waits until every ballot the stake is obligated to is final. |
| M | A coherent voter's reward used its sealed weight even when it revealed less. | The reward weight is capped at the weight revealed. |
| M | The penalty cap window was keyed to settlement time, so settling late reset or stretched it. | The window is keyed to the ballot's resolution time. |
| M | `epochBlocks` was a governed parameter; changing it would move every sealed epoch. | Fixed: 720, or 10 on a `dev` chain from genesis. |
| M | The DAO had no way to redeem the Kourt float or change the mirror's attribution. | New proposal kinds `kourt-redeem <amount>` and `kourt-attribution <text>`. |
| L | `kourt-abandon` needed no reason. | `kourt-abandon <dispute> <reason>`; the reason is recorded. |
| M | A `param` proposal was checked only at execution, so members could vote on a change that could never apply. | Validated at propose time with `CheckParam` / `CheckParamStr` of the target realm. |
| L | A restake could leave a dust position. | Staking must bring the member's stake to at least `minStake`. |
| L | Cancelling a proposal refunded its deposit, so a slot could be held for free. | `Cancel` forfeits the deposit to the treasury. |
| M | An `authority-execute` proposal executed whatever transfer was pending when it passed. | The payload is `<core\|dao\|kourt> <spec>` and must equal the pending spec at proposal and at execution. |
| M | A proposal's effect ran before its status was recorded. | The status is recorded first; a failing effect reverts both. |
| L | Pages printed proposal payloads and other user text unescaped. | Escaped. |
| L | The health view did not show a treasury shortfall or the PYTH reserved for credited rewards. | `Health()` returns a JSON object, embedded raw in `json/health`, with `pendingMemberPyth`, `reservedPyth`, `treasuryPythFree` and status `SHORTFALL` when the reserve exceeds the treasury. |
| M | The ugnot ledger could drift silently. | Payouts assert the known balance covers them (`ugnot accounting short`). |
| M | Treasury PYTH proposals could spend PYTH already credited to members as rewards. | Credited rewards the penalty pool does not cover are reserved; proposals spend only `treasuryPythFree`. |

### Kourt mirror (`kourt/impl/kourtv3`)

| sev | finding | fix |
|---|---|---|
| H | A holder answering the claim before the mirror staked froze staking and wedged the record. | The mirror follows such a claim to its verdict without a position. |
| H | A claim nobody answered stayed filed forever. | After twelve weeks the mirror closes the dead claim on Kourt (fee burned, deposit and stake back) and records it as abandoned. |
| M | The coin vote was judged closed by height only. | Closed on Kourt's clock: wall time when the vote carries a closing instant, height otherwise. |
| M | A one-way court and the claim's polish window were not modelled. | `Redeem` refuses a one-way court (shown as `oneWay` on the page and in the JSON head); the mirror waits out the stake-open delay. |
| M | The stake could fall below the answerability floor if the court grew after staking. | The mirror tops the stake up to lift the average. |
| M | An abandoned record kept its verdict field ambiguous and its coins on Kourt. | `Abandon` records verdict -1; `Invoke withdraw <dispute>` recovers what an abandoned record left on Kourt. |
| L | A verdict closed without a decision looked like agreement. | `KourtNoVerdict` is emitted. |
| L | The claim body was assembled by hand. | Built with `jsonw`. |
| L | The mirror's index was not paged and its pages echoed the requested path. | 50 records per page (`:page/<n>`); unknown paths are not echoed. |
| L | The example reader realm's storage and page were not bounded. | Readings live in an avl tree; the page and JSON show the newest 50. |

### Tools, scripts and build

| sev | finding | fix |
|---|---|---|
| H | `make deploy` shipped the public test1 key as the bootstrap authority of core, dao, kourt and the token. | `make build/deploy ADMIN=g1...` rewrites it (default: NS when NS is an address); deploy refuses a build that still names test1 on any chain id other than `dev`. |
| H | The deploy order put `dao` before `kourt`, which it imports. | `kourt` deploys before `dao`. |
| H | `p/.../authspec/v0` was missing from the deploy list. | Added. |
| M | `make toolchain` did not build gnodev, so `make dev` failed late. | `make toolchain` builds it (`gnodev-build`); `make dev` fails early without it. |
| M | The agent's sanity check used the public value even when its own last submission was newer. | The reference is the more recent of the feed's public value and the agent's own last submission. |
| L | The demo and soak scripts had stale steps after the read model changed. | Fixed. |

## Still open

- **The v2 `note` method is open to anyone.** `core/impl/v2`'s `Invoke note`
  writes release data for any caller. v2 is a rehearsal release for the
  upgrade path and must never be accepted on a live chain.
- **The subscription gate covers on-chain composability only.** Values are
  public on the pages and the `:json` views; an operator can always read
  them off chain and push them into a realm. What a subscription buys is
  the right to call `Read` from a realm's own logic.
- **`DisputeRecord.PriorValue` and `ProposedValue` are public** by design:
  the dispute pages and voters need them.
- **Third-party settlement has no incentive.** The tip (`settleTipBps`) and
  any penalty share for whoever settles members were removed pending a
  design; the bot settles for now.
