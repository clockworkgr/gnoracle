# Gnoracle

An Oracle DAO for gno.land: feeds requested by anyone, accepted by PYTH (Pythia) stakers,
served by GNOT-bonded providers, disputed under commit-reveal with penalties for
absent or incoherent voters, mirrored as claims in a Kourt court of record, and
upgradeable behind permanent realms with `gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0`.

Status (2026-09-23): plan v0.4; M0 scaffold and M1 pure packages done; M2
core realm and `impl/v1` implemented with realm tests passing; gnodev smoke
test in progress. Run `make toolchain && make test`.

Layout: pure packages under `gno.land/p/clockwork/gnoracle/*/v0`; permanent
realms `gno.land/r/clockwork/gnoracle/{core,dao,token}` with implementations at
`core/impl/v1`, `dao/impl/v1` and `kourt/impl/v1` (`impl/v2` are upgrade
rehearsals), the `dao/exec` self-upgrade trampoline and the `kourtdev`
stand-in for Kourt; `make build` rewrites the `clockwork`
namespace to the deployer address.

- `docs/IMPLEMENTATION_PLAN.md`: design, tokenomics, security analysis,
  milestones, API sketch, parameter registry.
- `docs/RESEARCH.md`: verified facts about gno.land (September 2026), Kourt,
  and comparable court and oracle designs, with sources.
- `docs/ORACLE_NETWORKS_RESEARCH.md`: raw research pass on Tellor, UMA, Pyth,
  Chainlink, API3, Band, Switchboard and Kleros with about 190 citations.

Toolchain target: `gnolang/gno v1.2.0` (the `gnoland-1` mainnet release), gno
0.9, package paths as on `master` (`gno.land/p/nt/grc20/v0` and so on).
