# Gnoracle operations

The runbook for whoever holds the guardian key or runs the shared
infrastructure: deploying and upgrading the realms, running the bot, keeping
the chain-side invariants healthy, and what to do when something goes wrong.
Role guides for providers, consumers, sponsors, requesters and members live in
[docs/guides](guides/).

Everything here targets gno v1.2.0 (gnoland-1). Paths use the mainnet
namespace `gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/...`;
on gnodev the same realms live under `gno.land/r/clockwork/gnoracle/...`.

## 1. Components

| Component | Where | What it does |
|---|---|---|
| `core` (permanent realm) | chain | feeds, rounds, providers, credits, disputes; holds every GNOT balance; proxies to `core/impl/vN` |
| `dao` (permanent realm) | chain | PYTH staking, proposals, dispute ballots, treasury; proxies to `dao/impl/vN`; `dao/exec` is its self-upgrade trampoline |
| `token` | chain | PYTH (GRC20), minter is the DAO |
| `kourt` (permanent realm) | chain | mirrors resolved disputes to the DAO's court on Kourt; `kourt/impl/kourtv3` binds the deployed Kourt v3 realm (`gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3`), `kourt/impl/v1` binds the stand-in `kourtdev` on development chains |
| `gnoracle-agent` | provider hosts | fetches, checks and submits values; finalises; claims |
| `gnoracle-bot` | one shared host (anyone may run more) | announces events and deadlines, reminds members, cranks `CatchUp`, `ResolveDispute`, Kourt `Crank`, `SettleMember` |
| `gnoracle` CLI | operators' machines | reads the `:json` views, sends every transaction, keeps commit-reveal salts |

Nothing off-chain is trusted: the realms verify everything. The bot and the
agents only save people gas and attention. If both disappear, the protocol
keeps working; rounds and disputes wait for whoever cranks next.

## 2. Deploying

Prerequisites: `make toolchain` (builds gno v1.2.0 into `~/.cache/gno-toolchains/v1.2.0`),
`make deps` (mirrors the on-chain imports into `deps/`), a funded deployer key
in a gnokey keybase. The deployer address is the namespace, so the deployer
key is the one that owns `gno.land/r/<addr>/...`.

```sh
make test                                  # every Gno suite, pinned toolchain
make go-test go-build                      # the tools
make build NS=g1lnk...                     # rewrites clockwork -> NS into build/, strips tests
make deploy NS=g1lnk... REMOTE=https://rpc.gno.land:443 CHAINID=gnoland-1 KEY=deployer
```

`scripts/deploy.sh` rebuilds `build/`, checks that the keybase holds the
namespace address, publishes the packages in dependency order and skips
what is already live, so it is safe to re-run after a failure. Order: the
pure packages, `core`, `core/impl/v1`, `token`, `dao`, `dao/impl/v1`,
`dao/exec`, `kourt`, `kourt/impl/kourtv3`. The mirror release imports the
deployed Kourt v3 realm, so the script publishes it only when the target
chain has that realm (mainnet does) and says so otherwise. `WITH_KOURTDEV=1`
adds the stand-in `kourtdev` and its release `kourt/impl/v1` (development
and test chains only). `ONLY="r/clockwork/gnoracle/core/impl/v2"` publishes
just a new release.

Funding: the permanent `core` realm alone simulates at about 152M gas and
locks a refundable storage deposit of about 32 GNOT; the whole set needs
roughly 150 GNOT of deposits plus fees on the deployer key. The keybase:
`make` exports a repo-local `GNOHOME` for the gno download cache, so the
scripts look for keys in `${XDG_CONFIG_HOME:-$HOME/.config}/gno` unless
`GNOKEY_HOME` says otherwise; never create a real key under the repository.

Each implementation realm proposes itself to its permanent realm in `init`.
Activation is a separate, explicit step by the authority (the guardian key
until handover, then the DAO):

```sh
export NS=g1lnk...
export GNORACLE_REMOTE=https://rpc.gno.land:443 GNORACLE_CHAIN=gnoland-1 GNORACLE_NS=$NS
export GNORACLE_KEY_HOME=~/.config/gno GNORACLE_KEY=deployer
gnoracle call gno.land/r/$NS/gnoracle/core Accept gno.land/r/$NS/gnoracle/core/impl/v1
gnoracle call gno.land/r/$NS/gnoracle/dao Accept gno.land/r/$NS/gnoracle/dao/impl/v1
gnoracle status                            # prints the DAO's address, live paths, counts, chain time
gnoracle call gno.land/r/$NS/gnoracle/token TransferMinter <dao address>
gnoracle call gno.land/r/$NS/gnoracle/core SetParamStr kourtRealm gno.land/r/$NS/gnoracle/kourt
gnoracle call gno.land/r/$NS/gnoracle/kourt Accept gno.land/r/$NS/gnoracle/kourt/impl/kourtv3
gnoracle call gno.land/r/$NS/gnoracle/kourt EnsureCourt        # founds court "gnoracle" on Kourt while creation is free
KV3=gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3
gnoracle -send 20000000ugnot call $KV3 Buy gnoracle 0            # 20 GNOT of court coin to the deployer (a direct user call)
gnoracle call $KV3 TransferCC gnoracle <mirror address> 40000000 # 40 CC into the float (the mirror address is `address` on the kourt line of `gnoracle status`)
```

`EnsureCourt` refuses, with instructions, while Kourt charges a
court-creation burn: then found the court from an account with `StartCourt
gnoracle "Gnoracle disputes"` on the Kourt realm, sending the burn, and run
`EnsureCourt` again. Then the genesis distribution (plan §9.1: 40% treasury, 25%
incentives, 20% liquidity, 15% founders) with `token Transfer`, the founders'
vesting with `dao SetVesting <member> <until> <floor>` (authority) or a
`vesting` proposal later, and the first parameter tuning by `SetParam` while
the guardian still holds authority (one change per parameter per block, at
most ±50% each).
`scripts/chain-test.sh` drives a whole lifecycle against gnodev and doubles
as the deployment rehearsal checklist; `make agent-soak` then runs several
agents and the bot against it and asserts the rounds, rewards and
conservation checks (the CI workflow in `.github/workflows/ci.yml` runs the
suites and publishes the image; the soak needs a chain and stays manual).

### Authority handover

The guardian is a single key until enough members have staked (the plan's
threshold is `guardianHandoverMembers`, 25; the step itself is a policy the
guardian follows, verifiable on chain). Every authority transfer is two
steps seven days apart: `ProposeAuthority <spec>` records and announces the
new authority, `ExecuteAuthority` applies it once `AuthorityTimelock` has
passed, `CancelAuthority` drops it before that. The spec is one line:
`addr:<address>`, `realms:<path>[,<path>]` or `anyof:<address>|<paths>`; a
spec that names realms must include the DAO (on the DAO itself, the exec
trampoline), so a typo cannot leave a realm ungoverned.

Handover, in order, each step proposed then executed after the delay:

1. `core ProposeAuthority anyof:<guardian>|<dao path>`, then `ExecuteAuthority`
   (both may act for the overlap); the same on `kourt`.
2. `core ProposeAuthority realms:<dao path>` and the same on `kourt` (DAO
   only). After the guardian is dropped, the DAO executes these through
   `authority-transfer` and `authority-execute` proposals.
3. On the DAO, an `authority-transfer dao realms:<exec path>` proposal, then
   after the delay an `authority-execute dao` proposal, so only the DAO's own
   votes govern its releases from then on.

Each step emits `AuthorityProposed`, `AuthorityTransferred` or
`AuthorityCancelled`; the bot posts them. Freezing a realm is refused while
a key still holds its authority. An `authority-execute` proposal opens once
the seven-day delay has passed, since its own execution window is limited.

## 3. Upgrading a realm

1. Deploy the new implementation (`core/impl/v2`, `dao/impl/v2`, a new `kourt/impl/<binding>`)
   with `ONLY="r/clockwork/gnoracle/core/impl/v2" make deploy ...`; its `init`
   proposes it. The `:releases` page (or `vm/qeval '<permanent>.PendingPaths()'`)
   shows it as pending.
2. Rehearse on gnodev first: `make dev`, deploy, `Accept`, run `make chain-test`
   and an agent against it, then `Rollback` and check the state is intact
   (the permanent realm holds all state; an implementation holds none).
3. Activate: before handover `gnoracle call <permanent> Accept <path>`; after
   handover a DAO proposal of kind `upgrade-accept` with payload `core <path>`,
   `dao <path>` or `kourt <path>` (7-day timelock, `upgradeTimelock`), executed
   with `gnoracle execute <id>`. `ReleaseAccepted` is emitted and posted.
   A release may add operations (`Invoke <method> <args>` on the permanent
   realm), attach data to objects (notes) and define governed parameters
   without any permanent change; new money categories are the one thing
   that still needs a permanent redeploy.
4. Watch `gnoracle health` (both realms' conservation checks must read `ok`)
   and the agents' logs for one full round cycle.
5. Roll back with `Rollback` (or an `upgrade-rollback` proposal) if anything
   is off; the previous release is kept and the state is untouched.
6. `Freeze` ends upgradeability for good. Do not call it before the audit
   closes.

`kourt/impl/kourtv3` is the production mirror release, bound to the deployed
Kourt v3 realm; `kourt/impl/v1` binds the stand-in for development chains,
and a release for another Kourt generation is a new directory under
`kourt/impl/` named after it. Each record remembers the binding it was filed
under; a release bound elsewhere refuses to advance it, and the authority
closes such records with `Abandon` (or a `kourt-abandon` proposal). Claims
that die unanswered on the bound court are closed by the release itself.

**The Kourt float.** `kourt:json/now` reports the mirror's court coin as
`float` (held) and `spendable` (not staked). A claim in flight needs about
4 CC (a 1 CC deposit plus a 10% fee, a stake of twice the answerability
floor, currently 2 CC, and the answer bond of about 6% of the stake); the
deposit, fee and stake return when the claim settles, the bond too unless
Kourt's vote overturns the answer. Top up by buying coin on the Kourt realm
from any account (`Buy gnoracle 0` with GNOT sent) and moving it with
`TransferCC gnoracle <mirror address> <amount>`. `Invoke reclaim <dispute>`
pulls the emission Kourt grants a settled claim's author, answerer and
winning stake into the float (anyone may run it). `RedeemFloat <amount>`
(authority) converts excess coin back to GNOT and sends it to the treasury;
the bot posts every `FloatRedeemed`.

## 4. Running the bot

One instance is enough for the network; several are harmless (the second
cranker's transaction fails cheaply when the first got there). The bot's key
pays gas for the cranks and earns the finaliser tip on `CatchUp`.

```sh
cp configs/bot.example.toml bot.toml      # edit paths, key, Telegram token and chat
export GNORACLE_KEY_PASSWORD=...          # or password_file in bot.toml
gnoracle-bot -config bot.toml
```

- **Telegram**: create the bot with BotFather, add it to the channel as a
  poster, put the channel id in `telegram.chat`. Members who want direct
  reminders send `/start` to the bot and give you their user id for a
  `[[members]]` entry. Without a token every message goes to the log.
- **State**: `bot-state.json` holds the scan cursor and what was already
  announced or attempted. Delete it to rescan from `start_height`.
- **Cranks**: `finalize` (after `finalize_grace`, so the feed's own agents
  keep the tip when they are alive), `resolve` (after reveal ends, and after
  an appeal window), `kourt` (hourly), `settle` (daily, opted-in members).
  Each is idempotent on chain; a lost race costs one small fee.
- **Docker**: `make docker` locally, or pull `ghcr.io/clockworkgr/gnoracle`
  (published by CI on every push to `main` and every `v*` tag). The image
  runs as uid 65532 and owns `/var/lib/gnoracle`; a bind mount must be
  writable by that user. The entrypoint is `gnoracle-agent`, so the bot is
  `docker run --rm -v $PWD/bot.toml:/etc/gnoracle/bot.toml -v gnoracle-state:/var/lib/gnoracle
  -e GNORACLE_MNEMONIC=... --entrypoint gnoracle-bot ghcr.io/clockworkgr/gnoracle -config /etc/gnoracle/bot.toml`
  (a dedicated low-balance key).

## 5. Running an agent

See [guides/PROVIDERS.md](guides/PROVIDERS.md). The short version:

```sh
gnoracle register 1 10000gnot "acme oracle ops"   # once per feed
cp configs/agent.example.toml agent.toml           # sources per feed
gnoracle-agent -config agent.toml -check           # key, balance, config
gnoracle-agent -config agent.toml
```

The two dev configs (`configs/agent.dev.toml`, `agent.dev2.toml`) run two
providers against gnodev; `make agent-dev` starts one.

## 6. Monitoring

- `gnoracle health`: both realms' conservation checks. Anything other than
  `ok` is an incident (§8).
- `gnoracle feed <id>`: `status`, `activeCount`, `lastFinalized` against
  `currentRound`, `openDisputes`, `pool`. A feed whose `lastFinalized` lags
  `currentRound` by more than two rounds has no live cranker.
- `gnoracle providers <id>`: `consecutiveMisses`, `strikes`, `status`.
- `gnoracle disputes` and `gnoracle ballot <id>`: phases and deadlines.
- gnoweb pages: `core:feeds`, `core:disputes`, `core:health`, `dao:members`,
  `dao:proposals`, `kourt`.
- The bot's channel is the human-readable event log; `bot-state.json`'s
  `height` should track the chain head.

Realm events worth alerting on outside the bot: `ProviderJailed`,
`FeedUnfunded`, `KourtDissent`, `PenaltyCapped`, `Frozen`,
`AuthorityTransferred`.

## 7. Keys and gas

- Every tool reads the password from `GNORACLE_KEY_PASSWORD` or a
  `password_file`, and a mnemonic from `GNORACLE_MNEMONIC` for containers.
  Keybase directories are copied into memory at start and released, so the
  agent, the bot and `gnokey` can share one.
- Gas is priced at `0.001ugnot` per gas and the whole fee is charged, so the
  tools simulate first (`gas.mode = "estimate"`) and ask for the measured
  gas plus 25%. Measured on v1.2.0: `Submit` about 18M gas (0.023 GNOT at
  the minimum price), `Submit` that also finalises about 32M, `CatchUp` of
  one round about 27M and more per extra round (the tools halve the batch
  on out-of-gas). When exactly one other provider is still to submit, the
  agent asks for 14M of headroom on top of its `Submit` estimate, because
  that provider's submission may land between the simulation and inclusion
  and turn the call into the finalising one.
- Storage deposits: the first submission of a round locks about 0.18 GNOT
  (1.8 kB at 100 ugnot per byte) from the submitter's account; the chain
  refunds it to whoever later frees the storage (`PruneRounds`), so pruning
  pays for itself. `gas.max_deposit` (5 GNOT) caps what one call may lock.

## 8. Incidents

**`health` is not `ok`.** The realm's held balances disagree with its
account. Stop accepting new releases, capture `gnoracle health` output and
the last blocks' events, and compare against the money primitives in
`core/money.gno` and `dao/money.gno`. Every transfer goes through them; a
mismatch means a release wrote outside them. Roll back the release if it is
new.

**A feed is stale.** Nobody finalised: run `gnoracle finalize <id>` (the
bot's `finalize` crank does this). Nobody submitted: check the providers'
agents; misses are slashed automatically at the next finalisation and the
alerter half goes to whoever finalises. Unfunded (`FeedUnfunded`): the
subscription ran out; a sponsor renews or the DAO deprecates.

**A provider is jailed.** They fix the source, wait `jailCooldown` (24 h),
top up to the feed's minimum if slashed below it, and `gnoracle unjail <id>`.
Three jailings in 30 days force unbonding.

**A dispute is open.** The bot posts the deadlines. Members commit with
`gnoracle commit <dispute> <choice>` and reveal with `gnoracle reveal
<dispute>`; the CLI keeps the salt under `~/.gnoracle/votes`. After the
reveal phase anyone runs `gnoracle resolve <dispute>` (the bot does). A
`ROLL` opens round two automatically; a decided round waits `appealWindow`
(24 h) for `gnoracle appeal <dispute> <2x bond>` before it applies.

**Kourt dissent.** The court's vote disagreed with the DAO. Nothing changes
on chain automatically; the record is public. The DAO discusses whether a
parameter or an incentive needs a change, and may reopen through a new
dispute on a later round.

**A release misbehaves.** `Rollback` (guardian) or an `upgrade-rollback`
proposal. State is in the permanent realms, so a rollback loses nothing.

**Lost guardian key before handover.** Authority is bound to the key; there
is no recovery. Keep the guardian key on a hardware device and schedule the
handover early (§2).

## 9. Parameters

`gnoracle params` and `gnoracle params dao` print every parameter with its
bounds; each change is limited to ±50% per call (`MaxChangeBps`; the bounds
themselves and one-unit steps are always allowed) and to one change per
parameter per block, and after handover goes through a `param` proposal
(`core.<name>=<value>` or `dao.<name>=<value>`; strings as
`core.<name>=str:<text>`). Appendix C of the plan is generated from the
registries (`scripts/gen-appendices.py`).

## 10. Backups and records

The chain is the record. Keep off chain: the agents' journals (evidence in
a dispute), the bot's state file (only to avoid re-announcements), and the
CLI's `~/.gnoracle/votes` salt files until the reveal is on chain. Nothing
else needs backing up.
