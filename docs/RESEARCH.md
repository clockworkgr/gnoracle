# Gnoracle research notes

Research date: 2026-09-23. Everything below was verified against source or a live
query on that date, and each section says where. Where a fact could not be
verified it is marked as such in section 6.

Sources used:

- Local gno monorepo `/Volumes/Tendermint/gno` (allinbits fork, branch
  `feat/gnoweb-stateless-docs`, HEAD `3cee0b7a`, 2026-09-16) and its
  `origin/master` (`1fc4c140`, 2026-09-14). File references below are relative to
  that checkout.
- Kourt contract source `github.com/jaekwon/kourt` (HEAD `b91361e7`, 2026-09-18),
  cloned into the session scratchpad. File references are relative to that repo.
- gno.land mainnet `gnoland-1` via `https://rpc.gno.land:443` (`gnokey query`).
- The gnomarket research notes `/Volumes/Tendermint/gnomarket/docs/RESEARCH.md`
  (same date) for chain facts already verified there.
- Public documentation of Tellor, UMA, Pyth, Chainlink, API3, Kleros (section 4).

---

## 1. gno.land as of September 2026

### 1.1 Chain state

| Fact | Value | Verified how |
|---|---|---|
| Mainnet | `gnoland-1`, live since 2026-09-12, gno `v1.2.0` | gnomarket notes, RPC status |
| Storage price | 100 ugnot per byte of net realm growth, charged to the tx signer, refunded to whoever frees the bytes | `params/vm:p:storage_price` = `100ugnot`; `vm/keeper.go:2211-2403` |
| Default per-message deposit cap | 100 GNOT (`-max-deposit` raises it) | `params/vm:p:default_deposit` = `100000000ugnot` |
| GNOT transfer lock | `bank:p:restricted_denoms` returned `[]` on 2026-09-23, so ugnot moves freely now. The genesis proposal had locked it; treat this as "unlocked, re-check before launch" | `gnokey query params/bank:p:restricted_denoms` |
| Block gas limit / max tx gas | 3,000,000,000 (a tx may use the whole block) | `tm2/pkg/bft/types/params.go:51`, `auth/ante.go:68-78` |
| Gas price | starts at 1 ugnot per 1000 gas, adjusts toward 70% block fullness | `gnoland/genesis.go:22`, `auth/params.go:25` |
| Max tx bytes | 1 MB | `cmd/gnoland/start.go:429-432` |
| VM alloc per tx | 500 MB; queries get 1.5 GB and their own 3B gas meter | `vm/keeper.go:50-52` |
| Store costs | uncached object read about 59k gas + 17/byte; write about 130k gas + 14/byte; iterator step 1k | `tm2/pkg/store/types/gas.go:406-419`, `vm/params.go:62-71` |
| Block time resolution | `time.Now()` is block time with 1 s resolution (nanos always 0); blocks target about 5 s | `gnovm/stdlibs/time/time.go:10-17`, `vm/keeper.go:434` |
| Scheduling | none: no cron, timers, goroutines, or realm end-block hooks | `go-gno-compatibility.md:352-356`, `gnoland/app.go:1091-1180` |
| Namespaces | `gno.land/{p,r}/<g1addr>/*` always allowed for that address; `gno.land/{p,r}/<name>/*` needs the name in `r/sys/users`; mainnet names go through `r/sys/namereg` (`nym-<stem><3 digits>` unless GovDAO grants a vanity name) | `r/sys/names/verifier.gno`, gnomarket notes |
| Deploy gating | `addpkg` on mainnet needs the governance approvals oracle; the home-realm deploy script already handles the wait | gnomarket notes |
| Gnoswap on mainnet | live: `r/gnoswap/pool` (`CreatePool(cur, token0Path, token1Path string, fee uint32, sqrtPriceX96 string)`), `r/gnoswap/pool/v1`, `router/v1`, `position/v1`, `gns`; `GetPoolCreationFee()` = 100,000,000 (100 GNS) | `vm/qpaths`, `vm/qfuncs`, `vm/qeval` |
| GRC20 registry | `gno.land/r/nt/grc20reg/v0`; listed: wugnot, GNS, GNOMIC, several gnomi tokens | `vm/qrender` |
| Existing oracles on mainnet | none of substance (`r/moul/x/daily/rpsoracle/v0` is a toy); `p/demo/gnorkle` exists in examples and is used by `r/gnoland/ghverify` | `vm/qpaths`, examples tree |

Consequences that shape the design:

- Every deadline is evaluated lazily inside a transaction. Any state transition
  that "happens at time T" must be a public crank function anyone can call.
- Whoever grows realm state pays 100 ugnot per byte. A 200-byte submission
  costs the provider 0.02 GNOT in deposit on top of gas. Pruning refunds the
  pruner, so pruning of settled rounds must be a public, incentive-compatible
  call.
- Iterating a large avl or bptree in one transaction is not viable (about 59k
  gas per cold node). Payouts must be pull-based and per-member accounting must
  use cursors and accumulators.

### 1.2 Language and runtime (gno 0.9, current master)

- The `std` package is gone. Replacements: `chain` (`Coins`, `Emit`,
  `PackageAddress`, `DerivePkgSubAddr`), `chain/banker`, `chain/runtime`
  (`ChainHeight`, `ChainID`, `AssertOriginCall`, `GetSessionInfo`),
  `chain/runtime/unsafe` (`OriginCaller`, `OriginSend`, `PreviousRealm`,
  `CurrentRealm`), `chain/params`. Several docs pages still show the old names
  (`docs/resources/gno-stdlibs.md:622-708`, `effective-gno.md:489-530`).
- `address` and `realm` are builtin types. A crossing function is
  `func F(cur realm, ...)`; only `/r/` packages may declare one; only crossing
  functions are callable by `MsgCall`. Cross-realm calls are written
  `other.F(cross(cur), ...)`. Library code that acts for a realm takes
  `(_ int, rlm realm, ...)` and is called as `F(0, cur, ...)`.
- Caller identity: check `cur.IsCurrent()` then read `cur.Previous().Address()`,
  `.PkgPath()`, `.IsUserCall()`. `realm` values cannot be persisted; store the
  address. `unsafe.OriginCaller()` is tx.origin and must not be used for
  authorization (gnorkle does, which is one reason not to reuse it).
- `MsgCall` arguments are primitives only (plus `[]byte` as base64). Anything
  taking a struct, slice of structs, or func needs `MsgRun`. Public entry points
  must therefore take strings and integers; feed specs arrive as a JSON string
  parsed on-chain.
- Receiving ugnot: `unsafe.OriginSend()` guarded by `cur.Previous().IsUserCall()`
  (or `runtime.AssertOriginCall()`); coins sent with a MsgCall must be read or
  the message fails. Sending ugnot: `banker.NewBanker(banker.BankerTypeRealmSend,
  cur).SendCoins(cur.Address(), to, coins)`. A RealmSend banker is an
  irrevocable, persistable spending grant: never hand `cur` or a banker to
  foreign code.
- Cross-realm panics abort the whole transaction and cannot be recovered
  (`revive` is test-only). A callee that panics can grief a caller; keep the
  set of realms called from a consumer read path minimal.
- Interfaces and closures can be stored across realms, but calling them runs
  foreign code inside your transaction. Gate interface parameters by concrete
  type (`grc20.IsCanonicalTeller`, `banker.IsCanonical`).
- No floats for money, no `math/big`, no generics. `int64` everywhere with
  `math/overflow` and `math/bits.Mul64/Div64` for 128-bit intermediates.
  `p/onbloc/uint256/v0` exists if wider math is needed. There is no decimal
  package; use scaled integers.
- Hashing available in realms: `crypto/sha256`, `crypto/keccak256`,
  `crypto/ed25519.Verify`, `crypto/merkle`, `encoding/hex`. No secp256k1.
  Commit-reveal voting is feasible. There is no VRF and `math/rand` is
  deterministic, so no on-chain random juror selection.
- Events: `chain.Emit(type, k1, v1, ...)`, at most 64 pairs, each string at
  most 4096 bytes. Convention: PascalCase type, lowercase keys, string values.
  tx-indexer (`https://indexer.gno.land/graphql/query`) exposes them.
- Render: `func Render(path string) string`, Gno-flavoured markdown, forms via
  `p/jeronimoalbi/mdform/v0`, tx links via `p/moul/txlink/v0`, routing via
  `p/nt/mux/v0`, paging via `p/nt/bptree/pager/v0` or `p/nt/avl/pager/v0`.
- Package paths were versioned on master (commit `09a7530a6`): `p/nt/grc20/v0`,
  `r/nt/grc20reg/v0`, `p/nt/commondao/v0`, `p/moul/authz/v0`, `p/nt/avl/v0`,
  `p/nt/bptree/v0`, `p/nt/seqid/v0`, `p/nt/treasury/v0`, `p/nt/ownable/v0`,
  `p/nt/uassert/v0`, `p/nt/ufmt/v0`, `p/moul/txlink/v0`, `p/nt/mux/v0`,
  `p/onbloc/uint256/v0`, `p/nt/addrset/v0`. All confirmed present on
  `origin/master`. The local allinbits branch still has the old paths; pin the
  toolchain to `gnolang/gno v1.2.0` as Kourt does (`make toolchain`).
- Package name must equal the last path element or the element before a `vN`
  suffix. Realms are immutable once deployed.
- Checked against the `v1.2.0` release tag (commit `98e816d7`) on GitHub:
  `p/nt/grc20/v0` exists with `NewToken(name, symbol string, decimals int, id
  seqid.ID, rlm realm) (*Token, *PrivateLedger)`, and `r/nt/grc20reg/v0`,
  `p/nt/commondao/v0`, `p/moul/authz/v0`, `p/nt/treasury/v0`, `p/nt/bptree/v0`,
  `p/nt/seqid/v0`, `p/nt/mux/v0`, `p/moul/txlink/v0`, `p/nt/ownable/v0` and
  `p/nt/markdown/sanitize/v0` are all present at those paths. So the mainnet
  release already uses the versioned layout.

### 1.3 Testing

- `_test.gno` with `func TestX(cur realm, t *testing.T)`; switch caller with
  `testing.SetRealm(testing.NewUserRealm(addr))` or
  `testing.NewCodeRealm(pkgPath)`; fund with `testing.IssueCoins`; attach coins
  with `testing.SetOriginSend`; advance time with `testing.SkipHeights(n)`
  (adds 5 s per height); assert cross-realm panics with
  `uassert.AbortsWithMessage(t, cur, msg, func(){ F(cross(cur), ...) })`.
- Filetests (`*_filetest.gno`, `func main(cur realm)`) assert `// Output:`,
  `// Events:`, `// Realm:`, `// Storage:` and `// Gas:` blocks, which is how to
  pin gas and storage budgets per operation.
- `gnowork.toml` at the workspace root lets `gno test ./...` resolve sibling
  packages; gnodev takes several roots.

### 1.4 Reusable packages and their fit

| Need | Package | Fit |
|---|---|---|
| Governance token | `p/nt/grc20/v0` + `r/nt/grc20reg/v0` | Use as is. `NewToken(name, symbol, decimals, id seqid.ID, rlm) (*Token, *PrivateLedger)`; pull user tokens with `tok.RealmTeller(0,cur).TransferFrom(0,cur,user,cur.Address(),amt)` after the user approves. Amounts are int64. No checkpoints, so vote snapshots must be built on top. Registry membership is exactly what Gnoswap's `CreatePool` gates on. |
| Treasury | `p/nt/treasury/v0` | Use for the DAO fee treasury (coins banker + GRC20 banker, history, Render). Keep staking escrow separate. |
| Governance engine | `p/nt/commondao/v0` | One address one vote, YES/NO/ABSTAIN, hard-wired tally, early close. Good for its proposal lifecycle and electorate snapshot ideas, not usable for stake-weighted mandatory dispute votes. |
| Governance engine | `p/kourt/governor/v0` + `p/kourt/grc20votes/v0` + `p/kourt/checkpoint/v0` (on mainnet under `gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/...`) | Stake-weighted, epoch-checkpointed, absolute quorum floors, sealed 7-day tallies. Licensed GNO NGPL v6 with strong attribution terms (section 2.6). Reusable in principle, but its ledger is the voting token itself; our members stake a separate GRC20, so we would checkpoint the staked balance, not the token. |
| Chain governance | `r/gov/dao` (proxy + v3 impl) | Not a library. Copy the proxy-with-allowlist upgrade pattern. |
| Admin authority | `p/moul/authz/v0`, `p/nt/ownable/v0` | Use authz with a `ContractAuthority` so admin actions route through DAO proposals. No pausable package survives; a `paused bool` is trivial. |
| Sets and IDs | `p/nt/bptree/v0` (2.2x cheaper storage than avl), `p/nt/avl/v0`, `p/nt/addrset/v0`, `p/nt/seqid/v0` | Use bptree for large tables, avl where ordered range scans by prefix are needed. |
| Oracle framework | `p/demo/gnorkle` | Single trusted whitelisted reporter, `OriginCaller` auth, no aggregation, no bonds, string values only, O(n) task listing. Borrow the `request`/`ingest`/`commit` message idea for the agent protocol; do not depend on it. |
| Quarantined | `p/samcrew/daokit`, `basedao`, `daocond`, `p/nt/pausable`, `p/thox/timelock`, `p/moul/collection`, `p/moul/xmath` | Not shipped to mainnet, not modernized. Do not import. |
| Staking, slashing, escrow, vesting | none in examples | Build. |

---

## 2. Kourt (Jae Kwon)

### 2.1 What it is

Kourt (kourt.xyz) is a network of on-chain prediction-market courts on gno.land.
Each court has its own coin (`KOURT:<SLUG>`) minted on a linear bonding curve
paid in GNOT. Anyone files a claim (one sentence, at most 200 characters, fixed
forever); coin holders stake on TRUE or FALSE; an answerer bonds a verdict; anyone
can dispute it by posting a bond, which triggers a coin-weighted vote whose
weights were sealed at an hourly epoch before the vote opened. The verdict, the
stakes, the bonds and the dissents are recorded permanently. "This record is the
purpose of the system." (WHITEPAPER.md abstract.)

### 2.2 Deployment status (verified on mainnet 2026-09-23)

| Generation | Path | Notes |
|---|---|---|
| V2 code, the one kourt.xyz points at | `gno.land/r/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/kourt` | Deployed at height 9676 by the author's address. Error strings are prefixed `kourtv2:`. 3 one-way courts (`covid` 43 claims, `meta`, `atomone`), `BurnedGNOT()` = 581.13 GNOT, `CourtCreationBurn()` = 0. Same claim, stake, answer, dispute and vote API as v3 minus `Redeem`, `StartOneWayCourt`, `HandOver`. |
| V3 code (two-way coin) | `gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3` | Found by `vm/qpaths` on 2026-09-23 under a second address, with 2 courts (`covid` 43 claims, `meta` 0) and the full v3 API (`StartCourt`, `StartOneWayCourt`, `Buy`, `OpenClaim`, `OpenClaimP`, `Stake`, `PostAnswer`, `OpenDispute`, `VoteDispute`, `ResolveDispute`, `Finalize`, `SettleUndisputed`, `TransferCC`, `Redeem`, `HandOver`, `Settled`, `Verdict`, `VerdictRoute`). The whitepaper calls v3 "a fresh realm"; whether this deployment is the production one or a rehearsal is not stated anywhere. |
| libraries | `gno.land/p/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/{checkpoint,curve,governor,grc20votes}/v0` and `gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/{checkpoint,curve,governor,grc20votes,twap}/v0` | Same code as the repo's `p/kourt/*`. |
| testnet `pearl-1` | `gno.land/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt` and `.../kourt2` | Found by `vm/qpaths` on 2026-09-23; generation not checked. Enough for an end-to-end testnet rehearsal of the mirror. `restricted_denoms` is also empty on pearl-1. |

The repo's `gnomod.toml` files say `gno.land/r/kourt/kourtv3`; that namespace is
not registered on mainnet, so the address-namespaced paths above are the live
ones. Any integration must take the Kourt realm path and court slug as DAO
parameters, not constants, and the adapter must target the API subset common to
v2 and v3. (Superseded by the plan, §7.4: a Gno import is compile-time, so each
mirror release binds one Kourt realm and court; `kourt/impl/kourtv3` binds the
v3 realm above and a release for another generation is a new directory.)

### 2.3 Mechanics that matter for us (kourtv3 source)

| Mechanism | Value | Source |
|---|---|---|
| Epoch (vote snapshot granularity) | 720 blocks (about 1 h) | `court.gno:42` |
| Voting weight | `min(PastVotes at the sealed epoch, live balance)`; the vote then locks that weight until the round resolves | `dispute.gno` `VoteDispute`, `votelock.gno` |
| Participants may not vote | stakers, author and answerer of the claim are refused | `dispute.gno` `isParticipant` |
| Dispute vote | 7 days (`votingBlocks` 120,960), strict majority of yes+no (`disputeThresholdBps` 5001), third option "spam" counts toward quorum only | `court.gno` `defaultParams`, `dispute.gno` |
| Quorum | absolute floor = `min(X̄frozen, votable/3)` where votable excludes the court escrow (the older 5%-of-supply arm was removed; the constant is still declared); failed quorum burns half the disputer's bond and returns half; three failed rounds close the claim with everyone made whole | `dispute.gno:784`, `ResolveDispute` |
| Undisputed settle | 72 h after the answer (`SettleUndisputed`, permissionless) | `session.gno`, `clock.gno:45` |
| Answer bond | `max(6% of X̄frozen, 1.6 x the larger side's frozen conviction)`, min 1 CC | `answer.gno` header |
| Dispute bond | `min(20% of X̄frozen, 40% of the answer bond)`, doubling per failed round, claim-scoped | `dispute.gno` header, `court.gno:167` |
| Escrow window after a decided round | 1 to 3 weeks (`escrowMinBlocks` 120,960 to `escrowMaxBlocks` 362,880), then `Finalize` (participant-only for the first week) | `court.gno` `defaultParams`, `dispute.gno` `Finalize` |
| Dead claim | unanswered 12 weeks: closes, stakes return, no prize | `clock.gno:46` |
| Bond doctrine | "FORFEITURES BURN; COMPENSATION MINTS. No value ever moves between adversaries." Comp = `min(2 x own bond, 80% of the loser's burned bond)`, minted from emission | `dispute.gno` header |
| Staker principal | always returns 1x, both sides, unpausable (`WithdrawStake`) | `session.gno` |
| Rewards | minted from a bounded emission (0.38% of live supply per week at genesis, stepping down, half-life 2 years, lifetime under 80% of curve-minted supply); split 80% winning stakers, 8% author, 7% deciding-round voters who matched the verdict, 5% answerer | `court.gno:56-66,150`, ECONOMICS.md |
| Coin | two-way curve: 10% of each payment burned (`BurnBps`, admin-set within 5% to 50%), the rest held per court; `Redeem` pays `floor(reserve x amount / supply)` | `redeem.gno`, TWOWAY.md |
| Claim cost | opener escrows a CC deposit (floor 0.01% of supply, min 1 CC) plus a 10% fee, refunded unless the claim dies or is judged low quality | `claim.gno` `openClaim`, `court.gno:231,299` |
| Answerability | trailing 3 h average total stake must be at least `max(0.10% of supply, 1 CC)` | `answer.gno:53`, `court.gno:298,541` |

### 2.4 What Kourt does NOT do (this corrects the brief)

The brief assumed "voting against the majority is slashed (see Kourt
tokenomics)". Kourt does not slash voters or stakers at all:

- A minority voter loses nothing. They simply do not receive the 7% voter
  "carrot" for that round (`openrewards.gno` `PullCarrot` pays only voters whose
  recorded choice matches the verdict).
- A non-voter loses nothing except eligibility for that carrot.
- Only bonded parties (answerer, disputer) can lose money, and their forfeited
  bonds are burned, not redistributed.
- `LOSERLOCK.md` §5 lists "Slashing the loser" as already rejected because it
  "destroys the regulatory position outright", and `VOTELOCK.md` documents that a
  live-weight vote-lock variant was built, reviewed and reverted because it
  broke the governor's frozen-denominator invariants. The current mitigation is
  `min(snapshot, live)` weight plus a lock of the tallied weight until the round
  resolves.
- What keeps Kourt voters honest is exclusion of conflicted parties, sealed
  snapshots, carrot-only rewards, permanent public dissent, and the option to
  found a rival court.

The systems that do slash incoherent or absent voters are Kleros (incoherent
jurors lose their locked stake to coherent ones) and UMA's DVM 2.0 (both wrong
and missing votes are slashed at a small per-vote rate and redistributed to
correct voters). Section 4 has their numbers. The plan therefore treats
"slash non-voters and minority voters" as a UMA-style mechanism with Kourt's
snapshot and lock discipline, and makes the slash rates DAO parameters that can
be set to zero to adopt Kourt's posture.

### 2.5 Calling Kourt from a realm

- Every entry point checks `cur.IsCurrent()` and uses `cur.Previous().Address()`
  as the actor, so another realm can call `OpenClaim`, `Stake`, `PostAnswer`,
  `SettleUndisputed`, `TransferCC` and the rest with `cross(cur)`.
- `Buy` reads `unsafe.OriginSend()` under `IsUserCall`, so a realm cannot mint
  court coin itself. A user buys CC and `TransferCC`s it to the realm address
  (transfers to any address except the court escrow are allowed). `Redeem` is
  realm-callable, so excess CC can be returned to GNOT by the realm.
- `StartCourt` takes the court-creation burn from `OriginSend` only when the
  burn parameter is non-zero (`courtburn.gno:118-143`, initial value 0). While it
  is zero a realm can found a court and becomes its admin; otherwise a user
  founds it and appoints the realm address as a moderator.
- Recording one outcome as a settled Kourt claim takes: `OpenClaimP` (CC deposit
  + fee), `Stake` on the verdict side so the 3 h trailing average clears the
  answerability floor, `PostAnswer` (bond), then at least 72 h, then
  `SettleUndisputed`, then `WithdrawStake`. Minimum wall time about 75 h. Kourt
  coin holders may dispute the answer during those 72 h, which sends it to a
  Kourt vote; the Kourt record then reflects Kourt's verdict, not ours.
- `p/governor` `Kind` payloads and `MsgCall` args are strings; the claim title is
  at most 200 characters and the body at most 2000 (`claim.gno:29`).

### 2.6 Licence

GNO Network General Public License v6 with "Additional Terms (Strong
Attribution)": any work that "derives functionality from it or otherwise uses
it" must display the "built on Kourt" badge (`brand/built-on-kourt.svg`), linked
to `https://kourt.xyz`, at least 20 px tall, on every screen that displays a
claim, a court or a stake, in persistent chrome. Copying `p/kourt/*` code into
this project makes the whole project a Covered Work. Calling the deployed realm
still makes our UI an "Applicable Work" for the screens that show Kourt records.
Counsel should confirm the reading; the plan budgets the badge on every page that
renders a Kourt claim and avoids copying Kourt code.

---

## 3. Adjudication and oracle designs compared

### 3.1 Coherence-based voting schemes (who loses what)

| Scheme | Electorate and weight | Voter capital at risk | Minority voter | Non-voter | Appeal | Timing |
|---|---|---|---|---|---|---|
| Kourt (2026) | all coin holders except claim participants; `min(sealed-epoch snapshot, live balance)` | none, coin locked until resolution | loses nothing, forgoes the 7% carrot | loses nothing, forgoes the carrot | reopen rounds inside a 1 to 3 week escrow with doubling bonds; 3 failed rounds close without decision | hourly epochs, 72 h settle, 7 day vote |
| Kleros (KlerosLiquid) | jurors drawn in proportion to PNK staked in a subcourt | `minStake x alpha / 10^4` locked per vote | loses the locked stake; penalties of the round pooled and split equally among coherent jurors, plus the ETH fees | treated as incoherent | appeal cost `feeForJuror x (2n + 1)`, jurors more than double per round, court jump at a threshold | per court: evidence, commit, vote, appeal periods (example 1d15h / 3d9h / 2d6h) |
| Aragon Court v1 (mainnet config) | guardians drafted in proportion to activated ANJ, min 10,000 ANJ, first round 3 jurors | 30% of the min active balance locked per drafted juror (`penaltyPct` 3000) | locked tokens slashed to coherent jurors, who also get dispute fees | penalised like incoherent (commit and reveal both required) | appeal factor 3 (3, 9, 27, 81), max 4 rounds, then all active jurors at 50% weight; appeal collateral 3x juror fees | 8 h terms: evidence 7 d, commit 2 d, reveal 2 d, appeal 2 d |
| UMA DVM 2.0 | all UMA stakers, commit and reveal, delegation allowed | whole stake exposed to the slash rate | about 0.1% of stake per wrong vote, redistributed pro rata to correct voters | same about 0.1% per missed vote (a permanently absent staker's emissions and slashes roughly cancel) | none at the DVM; the Optimistic Oracle escalates to it | 48 h commit and reveal rounds, 7 day unstake cooldown |
| Truthcoin / Hivemind | VoteCoin holders per branch | reputation redistributed each period | SVD-based coherence score, most deviant voter gets zero for the round, smoothed with alpha 0.1 to 0.2 | imputed as majority, then penalised in proportion to non-participation | none per period | per voting period |

Sources: `KlerosLiquid.sol` lines 53, 150, 571-660, 797-806; docs.kleros.io
"how it works" and FAQ; aragon-network-deploy `court.mainnet.js` (2020-09-01);
aragon-court docs 1-mechanism and 3-cryptoeconomic-considerations; docs.uma.xyz
DVM 2.0 walkthrough and FAQ; Truthcoin whitepaper v1.2 and reference
`consensus.py`; Kourt sources as in section 2.

Takeaway: Kleros, Aragon and UMA all redistribute the incoherent or absent
voter's loss to coherent voters, at rates from about 0.1% of stake per vote
(UMA) to 30% of a minimum balance per draft (Aragon). All three hide votes
until a reveal phase. Kourt is the outlier that penalises nobody but the
bonded litigants. The plan adopts UMA's shape (small per-dispute rates on the
whole staked balance, redistributed, commit-reveal) with Kourt's sealed
snapshot and vote lock, and exposes the rates as parameters.

### 3.2 Oracle networks (providers, bonds, disputes, fees)

Full pass with about 190 cited URLs in `docs/ORACLE_NETWORKS_RESEARCH.md`
(sections per system, attack literature, fee models, a recommended parameter
set and an UNVERIFIED list). The numbers below are the ones the plan borrows.

| Dimension | Tellor 360 / Layer | UMA OO + DVM 2.0 | Pyth OIS | Chainlink v0.2 + OCR | API3 | Kleros / Reality.eth |
|---|---|---|---|---|---|---|
| Data model | push; single-reporter values (360) or stake-weighted median per window (Layer) | pull per assertion; DVM only on dispute | push to Pythnet, pull to chains; median of publishers | push on deviation or heartbeat; OCR median, n = 3f+1 | push on deviation or 24 h heartbeat; median of first-party beacons | bond-escalation answers; jury on arbitration |
| Provider stake | `max(100 TRB, $1,500)` (360); at least 1 TRB (Layer) | proposer bond = final fee (250 USDC; Polymarket $750) | delegated pools with a soft cap per publisher | operators 1,000 to 75,000 LINK; community 1 to 15,000 | none (pool is governance and insurance) | answer bonds at least 2x the previous; jurors stake PNK |
| Unbonding | 7 d (360), 21 d (Layer) | 7 d | 1 epoch (7 d) | 28 d + 7 d claim | 7 d | locked while drawn |
| Correctness | optimistic 12 h (360); 2/3-power consensus tier plus optimistic tier (Layer) | optimistic liveness 2 h, then stakers vote | Council ex-post test | BFT median, f < n/3 | median plus curation | escalation, then 3, 7, 15, 31 jurors |
| Dispute bond | 10% of stake, doubling (360); equals the slash tier (Layer) | equals the proposer bond | none (Council) | none | Kleros fee (designed, never live) | arbitration fee per juror |
| Voting | 4 groups x 25%, 24 h rounds up to 6 d (360); 48 h commit + 24 h reveal, up to 5 rounds (Layer) | 24 h commit + 24 h reveal; GAT 5M UMA; SPAT 65% | 7-of-9 council | none | none | commit 6.75 d, vote 6.75 d, appeal 4.5 d |
| Provider slash | whole stake (360); 1%, 5%, 100% tiers (Layer) | 100% of bond, half to winner, half to the Store | at most 5% of a pool (never used) | 700 LINK per operator after 3 h downtime (never used) | none (0 claims) | loses bond |
| Voter slash | none | 0.1% absent, 0.1% wrong, 0% wrong on governance votes | n/a | n/a | n/a | alpha x minStake per incoherent vote |
| Reward source | 146.94 TRB/day mint plus tips | 0.130 UMA/s emissions plus slash redistribution | finite 100M PYTH pool, at 0 since April 2026 | treasury emissions 4.32% to 4.5%; feeds sponsor-funded | inflation plus OEV | asker bounty; juror fees |
| Consumer pays | tips; free reads | requester reward plus bonds | update fee (now 0); Pyth Pro $500 to $2,500+/month | sponsors; free reads; Data Streams subscriptions | 3-month plans at cost | bounty plus arbitration fee |
| Live scale (2026-09) | Layer 58,120 TRB bonded, 18 reporters | 19.45M UMA staked; Polymarket volume secured | about 1.0B PYTH in about 120 pools | 42.5M LINK staked; 31 nodes on ETH/USD | 67.6M API3 staked | v2 beta on Arbitrum |

Findings that changed the plan's defaults:

- **Slashing almost never fires.** Pyth OIS: zero slashing proposals in two
  years. Chainlink v0.2: no alert or slash has ever executed. API3 coverage:
  designed, audited, never switched on. Tellor Layer: 13 disputes, all in the
  1% "warning" tier, 11 without quorum. UMA is the only network where the
  slash fires routinely (0.1% per missed or wrong vote, every 48 h round). So
  the small slash tier is the one that gets exercised and the large tier is the
  deterrent; the plan now has both.
- **Stake below about $1,500 per provider has been exploited.** BonqDAO lost
  about $120M nominal to an attacker who bought a 10 TRB (about $150) Tellor
  Layer stake. Tellor 360 requires `max(100 TRB, $1,500)`. The plan raises the
  provider minimum accordingly and publishes a per-feed value-at-risk figure.
- **Whale capture of dispute votes is recent and real.** In UMA's March and
  July 2025 Polymarket episodes one holder cast about 25% of votes and the top
  ten about 30%; UMA raised its supermajority (SPAT) from 50% to 65%. The plan
  adopts a supermajority with a void fallback, an appeal round, and a
  per-address cap on revealed weight.
- **Emissions are being cut everywhere and per-read fees have not replaced
  them.** Pyth's on-chain update fees earned about $115K in H1 2026 across 70+
  chains and were then zeroed; Tellor tips total 44 TRB lifetime; UMA cut
  emissions from 0.18 to 0.130 UMA/s. What pays is subscriptions (Pyth Pro
  about $676K gross in August 2026; Chainlink Data Streams) and sponsor-funded
  feeds. The plan makes a monthly feed subscription the primary revenue and
  keeps metered reads as secondary.
- **Optimistic windows are short when bots watch and long when humans do.**
  UMA/Polymarket 2 h with whitelisted proposer bots; Tellor 12 h; Chainlink's
  only slashable condition is 3 h of downtime. The plan starts at 12 h for
  recurring feeds and 72 h for one-off outcomes, to be lowered once
  independent watcher bots exist.
- **gno.land specifics from that pass:** GNOT traded at about $0.062 on
  2026-09-23; a call-scoped `CallSend()` for realm-to-realm payments is only a
  draft RFC (2026-09-19), so consumer realms still cannot pay per call from
  their own balance.

---

## 4. Attack literature and standard mitigations

- Schelling-point oracles (Buterin, "SchellingCoin", 2014): honest reporting is
  a focal equilibrium only while voters expect others to be honest; visible
  early votes create herding, hence commit-reveal.
- p + epsilon attack (Buterin, 2015): an attacker who credibly promises to pay
  slightly more than the honest payoff to anyone who votes wrong, only in the
  world where the attack fails, can flip a Schelling game for free. Mitigations:
  large slashable stake relative to what is at risk, appeal rounds that enlarge
  the electorate, counter-coordination, and making the payoff for correct votes
  depend on the outcome of an appeal.
- Bribery and collusion among providers: median aggregation protects until more
  than half of the weight colludes; disputes with bonded challengers and a
  separate voter set add a second line; consumer-visible security budgets let
  integrators size their exposure.
- Lazy voting and freeloading: voters copy the visible majority. Commit-reveal
  hides votes; penalties for absence force participation; rewards for coherence
  are small enough not to become the primary income (Kourt keeps the voter slice
  at 7% for this reason).
- Whale capture: stake caps per member, quorum floors, and a public record of
  dissent. Kourt's `min(snapshot, live)` weight and vote locks stop "rent weight,
  vote, return it" (`VOTEFLOOR.md`).
- Liveness attacks: heartbeat deadlines with per-miss penalties, jailing after
  consecutive misses, consumer-visible staleness.
- Data-source manipulation (thin markets, flash moves): multi-source
  medianization off-chain, TWAP or time-averaged values on-chain where the
  consumer can tolerate lag, deviation-bounded updates.
- Griefing via panics: a consumer read path must not call untrusted realms; a
  provider submission path must not iterate unbounded sets.
- Storage-deposit griefing: any state a stranger can create must be bounded or
  paid for by that stranger; Kourt charges a claim deposit and fee for this.

---

## 5. Your own conventions to match

From `/Volumes/Tendermint/gno-contracts`, `/Volumes/Tendermint/clockwork-gno-home`
and `/Volumes/Tendermint/gnomarket/docs/RESEARCH.md`:

- Workspace root with `gnowork.toml`, `Makefile` (`test`, `lint`, `fmt`, `dev`,
  `deploy`, `accept`, `render`), `scripts/env.sh` (gas defaults: call 10M gas,
  addpkg 120M gas, deposit 20 GNOT), `scripts/deploy.sh` (rewrites `/r/clockwork/`
  to `/r/$NS/`, `nym-clockwork001` fallback, mainnet approver wait),
  `scripts/deps.sh` (fetch deps from mainnet with `vm/qfile`).
- Pure logic in `gno.land/p/clockwork/<project>/<pkg>/v0`, thin versioned realms
  in `gno.land/r/clockwork/<project>/<realm>/v1`.
- Two-line `gnomod.toml` (`module`, `gno = "0.9"`), external `_test` packages,
  `uassert`, `testutils.TestAddress`, narrative tests per story, `gas_test.gno`
  and `adversarial_test.gno` files, `export_test.gno` hooks.
- The gnomarket plan already sketches an optimistic resolver (`r/clockwork/
  gnomarket/oracle/v1`) with bonds, a liveness window and a council vote. This
  project should become that resolver's backend: gnomarket markets can request a
  one-off outcome feed from the Oracle DAO instead of running their own council.

---

## 6. Unverified or open

- Whether ugnot will stay unrestricted on `gnoland-1`; the empty
  `restricted_denoms` list was observed once. Provider staking in native GNOT
  depends on it; the plan keeps a wugnot (GRC20) path as fallback.
- Kourt's court-creation burn on mainnet (`SetCourtCreationBurn` is admin-set;
  initial value 0). If non-zero, a user must found the DAO's court.
- Gnoswap `CreatePool` fee denomination (GNS decimals) and whether `sqrtPriceX96`
  must be supplied by an off-chain tool. Listing is an ops step, not a contract
  dependency.
- Kourt licence applicability to a UI that only links to Kourt records.
