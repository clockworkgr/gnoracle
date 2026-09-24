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
| M | The disputed or voided value was served with a label instead of the last final value; the quarantine reference was the last aggregate, so a provisional jump became the reference. | The feed tracks its last final round (window passed, no dispute standing); `Read` serves it while the latest round is disputed or voided and to finalOnly readers; it is the quarantine reference. |
| M | Deprecated feeds re-accumulated read fees and stayed unprunable; providers stayed seated on dead feeds. | Reads, finalisation and catch-up refuse retired feeds; deprecation starts unbonding for every seated provider, refunds a one-off bounty and sweeps a recurring pool; `PruneFeed` sweeps leftovers. |
| M | Extensions could decrement the ledger while paying from their own account. | Coin moves are refused from extensions (state-only), on all three realms. |
| M | A typo in `TransferAuthorityToRealms` or a premature `Freeze` could lock a realm out of governance for good. | Realm-only authorities must include the DAO; freezing needs a realm authority; the authority check runs first. |
| M | The parameter rate limit could be chained inside one transaction and trapped small values above zero. | One change per parameter per block; the bounds themselves and one-unit steps are always allowed. |
| L | Unbonding stake dodged miss slashes; ejection cleared the slot retroactively; a sponsorship could evict a longer one; read fees were folded into the long-lived pool; empty one-off rounds stranded the bounty; sign guards were missing; outflows emitted no events; deleted feeds left index entries; minor-slash escalation counted across epochs; a one-off miss never jailed; a finalOnly reader paid for nothing; a dispute on an old round marked the whole feed disputed; a resolved round could not be disputed again in its restarted window; the round view panicked on huge ids and attributed submissions to current holders. | All addressed (see the commit message for the list). |

### DAO and token

| sev | finding | fix |
|---|---|---|
| H | Treasury payouts decremented the known balance twice, so the next sync handed phantom income to stakers. | `sendUgnot` alone keeps the known balance. |
| H | Proposal deposits were not booked in the known balance and were counted as fee income. | Booked on creation. |
| H | Any running ballot blocked staking, unstaking and withdrawal for every member. | Strict settlement blocks only on a resolved and funded ballot; withdrawal waits only for ballots the member holds weight in. |
| H | Ballots resolved at the decision but were funded when the core applied the outcome; a settlement in between forfeited the member's ugnot share (the bot did this daily). | Ballots carry a `final` flag set when the core applies the outcome (always called, amount possibly zero); settlement waits for it. |
| H | Reward payment panicked whenever the penalty pool was short and blocked the ugnot leg too. | The treasury covers the PYTH leg, a shortfall is reported, and the ugnot leg is independent. |
| M | Share changes ran before syncing fees; newcomers started at cursor zero; vesting had no setter; a second unstake restarted the cooldown; early execution aborted instead of recording the tally; the payload could escape its fence; thresholds carried at equality; rolled-round penalties were stranded; proposals could not reach the Kourt realm. | All addressed: fees sync first, cursor starts at the ballot count, `SetVesting` and a `vesting` kind, second unstake waits, tally recorded without abort, backticks neutralised, strictly greater than the bar, rolled-round penalties go to the treasury, `kourt` is a proposal target and `kourt-abandon` exists. |

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

- **`settleTipBps`** is recorded but no tip is paid in v1; a release can pay
  one from the treasury with the existing primitives.
- **`guardianHandoverMembers`** stays a published policy: every authority
  transfer is now a two-step, timelocked operation (`ProposeAuthority`,
  seven days, `ExecuteAuthority`) that anyone can see and the authority can
  cancel, which is the enforceable part; a member-count floor would trap
  the guardian if the community stalled.
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
- **Development-chain floors.** Added for `make demo` (2026-09-24): on a
  chain whose id is `dev` the floors of `appealWindow`, the ballot phases,
  `epochBlocks`, `upgradeTimelock` and `executionWindow` are lower, and the
  DAO exposes `DevSetParam`, which refuses on any other chain id. The
  defaults are untouched everywhere and the gate is one function per realm
  (`devFloor`); an auditor should confirm the gate reads the chain id and
  nothing else. The test harness runs realm calls under an empty chain id,
  so the suites exercise the production floors.
- **Weights for penalties** use the smaller of the sealed and the live stake;
  unchanged and documented in the plan.
