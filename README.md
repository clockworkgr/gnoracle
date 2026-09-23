# Gnoracle

An Oracle DAO for gno.land: feeds requested by anyone, accepted by PYTH (Pythia) stakers,
served by GNOT-bonded providers, disputed under commit-reveal with penalties for
absent or incoherent voters, mirrored as claims in a Kourt court of record, and
upgradeable behind permanent realms with `gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0`.

Status (2026-09-23): plan v0.4; M0 to M4 done (pure packages, core, token
and DAO, disputes and the Kourt mirror against a local stand-in); M5 built
(provider agent, notifier and cranker bot, operator CLI, runbook and role
guides), soaked on gnodev. Run `make toolchain && make test && make go-test`.

Layout: pure packages under `gno.land/p/clockwork/gnoracle/*/v0`; permanent
realms `gno.land/r/clockwork/gnoracle/{core,dao,token}` with implementations at
`core/impl/v1`, `dao/impl/v1` and `kourt/impl/v1` (`impl/v2` are upgrade
rehearsals), the `dao/exec` self-upgrade trampoline and the `kourtdev`
stand-in for Kourt; `make build` rewrites the `clockwork`
namespace to the deployer address.

- `docs/IMPLEMENTATION_PLAN.md`: design, tokenomics, security analysis,
  milestones, API sketch, parameter registry, machine views.
- `docs/OPERATIONS.md`: deploying, upgrading, running the bot, monitoring,
  incidents. `docs/guides/`: providers, consumers, sponsors, requesters,
  members. `docs/SIMULATION.md`: break-even tables (`make sim`).
- `docs/RESEARCH.md`: verified facts about gno.land (September 2026), Kourt,
  and comparable court and oracle designs, with sources.
- `docs/ORACLE_NETWORKS_RESEARCH.md`: raw research pass on Tellor, UMA, Pyth,
  Chainlink, API3, Band, Switchboard and Kleros with about 190 citations.

Toolchain target: `gnolang/gno v1.2.0` (the `gnoland-1` mainnet release), gno
0.9, package paths as on `master` (`gno.land/p/nt/grc20/v0` and so on).

## Off-chain tools (Go)

`make go-build` puts three binaries in `bin/` (module
`github.com/clockworkgr/gnoracle`, pinned to `gnolang/gno v1.2.0`):

- `gnoracle-agent`: the provider daemon. One `[[feeds]]` table per feed with
  a source adapter (`http` median across URLs, `gnoswap` pool TWAP, `qeval`,
  `exec`, `file`), sanity bounds, an evidence journal; it submits, finalises
  closed rounds for the tip and claims rewards. `configs/agent.example.toml`.
- `gnoracle-bot`: follows the chain's events straight from the RPC, posts
  deadlines to Telegram, reminds members 24 h and 2 h before commit and
  reveal phases close, and cranks `CatchUp`, `ResolveDispute`, the Kourt
  mirror and `SettleMember`. `configs/bot.example.toml`.
- `gnoracle`: the operator CLI. Reads the realms' `:json` views, sends every
  transaction with unit-aware amounts, and runs `commit`/`reveal` with the
  salt kept for you.

Against the local chain: `make dev RPC=36657 WEB=38888`, `make chain-test`,
then `make agent-dev` and `make bot-dev` (configs in `configs/*.dev.toml`).
`make docker` builds one image with the three tools.
