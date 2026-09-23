# Gnoracle

Gnoracle is an oracle for [gno.land](https://gno.land): a service that puts
real-world facts on the chain so that smart contracts can use them. A price
every hour, the result of a match, the outcome of an election: anyone can ask
for such a value, a community of staked providers delivers it round after
round, contracts read it for a fee, and every disagreement is settled by a
vote whose verdict is recorded in a court of record. It runs as a DAO, owned
by the holders of its token, Pythia (PYTH).

This page describes what the project does and how the pieces fit. The
guides in `docs/guides/` say what to do as a provider, consumer, sponsor,
requester or DAO member; `docs/OPERATIONS.md` is the runbook for whoever
operates it; `docs/IMPLEMENTATION_PLAN.md` holds the full design and the
reasons behind every number.

## What it does, in one pass

1. **Someone requests a feed.** They write a short specification: what the
   value is, how often it is needed (or the one moment it resolves), where
   providers must get it from, how many providers it needs, what a read
   costs. They post a small deposit.
2. **The DAO accepts it.** Token holders vote. Allow-listed applications (the
   first is gnomarket, a prediction market) can activate small one-off
   requests themselves, up to a cap.
3. **Providers stake and serve.** Anyone can become a provider of a feed by
   locking at least 10,000 GNOT on it. Each round, their agent fetches the
   value from the named sources and submits it. The round's value is the
   median of the submissions; everyone whose submission was close enough to
   it is paid from the feed's pool.
4. **Contracts read it.** A realm calls `Read` and gets the latest value, its
   round and a quality tier. Reads cost a small fee per call, or nothing when
   a sponsor pays the feed's monthly subscription and names the consumer.
   Anyone can look at older values for free on the feed's web page.
5. **Anyone can dispute a round.** Post a bond, say what the value should
   have been and why. Every token holder who staked must then vote in a
   sealed two-phase ballot (commit, then reveal). If the round was wrong the
   providers at fault lose part or all of their stake and the disputer is
   paid; if it was right the disputer loses the bond. A losing side can appeal
   once.
6. **The verdict is filed in Kourt.** Each resolved dispute is mirrored as a
   claim in a court on [Kourt](https://kourt.xyz), gno.land's court of record,
   so the oracle's judgements live somewhere the oracle does not control.

## The people involved

| Who | What they do | What they pay | What they earn | What they risk |
|---|---|---|---|---|
| **Requester** | writes a feed specification and posts it | a 5 GNOT deposit, refunded when the feed is accepted | the feed they need | the deposit, if the request is spam |
| **Provider** | runs an agent that submits a value every round | stake of at least 10,000 GNOT per feed, plus gas of roughly 0.02 GNOT per submission | an equal share of every round's pool they took part in, plus a 1% tip for whoever finalises a round | 0.5% of stake per missed round, jail after three misses, 5% of stake for a wrong value, all of it for a fabricated one |
| **Consumer** | a contract that reads values | a per-read fee set by the feed (from 0.002 GNOT), half price for final values only, free when sponsored | the value, with a quality tier | nothing beyond the fee |
| **Sponsor** | keeps a feed funded | the feed's monthly subscription (typically around 1,000 GNOT) | free reads for up to eight named consumers | nothing |
| **Disputer** | challenges a round | a bond of at least 2,500 GNOT (10% of the feed's stake if larger, doubling for repeat disputes) | the bond back plus half of the slash when right | the bond when wrong |
| **DAO member** | stakes PYTH, votes on requests and parameters, must vote on every dispute | nothing to join beyond the tokens | 15% of all subscriptions and read fees, plus a share of forfeited bonds and slashes | 0.5% of stake per ballot missed or voted against the outcome, capped at 5% a month |

Of every subscription or read fee, 70% goes to the providers of that feed,
15% to the DAO's stakers and 15% to the DAO treasury.

## How a feed lives

A recurring feed has a fixed interval (one minute to thirty days) and a
submission window after each round opens. Providers submit inside the
window; the round settles as soon as every obliged provider has submitted,
or when anyone closes it after the window. Each round's value carries a
tier:

- **consensus**: at least the required number of providers agreed and the
  value did not jump past the feed's quarantine band;
- **provisional**: fewer providers, or a large jump; use with care;
- **final**: either of the above once the dispute window has passed;
- **disputed**: a dispute is open on it; wait or use the previous round;
- **stale**: no round has settled for two intervals.

A one-off feed has a single round at its resolve time. Options ("Home",
"Draw", "Away") are supported as well as numbers, and the same rules apply.

Feeds that run out of subscription money stop paying providers and, after
enough empty rounds, are retired. The DAO can also update a feed's prices,
minimum stake, tolerance and dispute window, retire it, or remove a provider
by vote.

## How it stays honest

- **Stakes and slashes.** Providers, disputers and voters all have money at
  stake, sized so that lying costs more than it can gain: a wrong value costs
  a provider 5% of its stake, a fabricated one all of it plus ejection; a
  frivolous dispute costs the bond; a voter who skips ballots or votes
  against the outcome loses a little stake each time.
- **Sealed voting.** Dispute ballots are commit-reveal: votes are hidden
  until everyone has committed, so nobody can follow the crowd. The heaviest
  voters are capped at 20% of the vote when deciding, so no single holder
  decides alone. A ballot without enough participation rolls to a second
  round; a decided round can be appealed once for twice the bond.
- **Nothing is trusted off chain.** The provider agents, the notifier bot
  and the command-line tool only save people gas and attention; the realms
  verify everything and keep working, more slowly, if every tool disappears.
- **Money is accounted for.** Both realms publish a conservation check:
  every coin they hold must equal the sum of what they owe (stakes,
  credits, pools, rewards, bonds). The check is `ok` after every test and
  every run.
- **Upgradeable, but not silently.** State and funds live in permanent
  realms; the logic runs behind a proxy that a guardian key, and later the
  DAO by vote with a seven-day delay, can replace or roll back. Handing the
  keys over is itself a two-step move with a seven-day delay that anyone
  can see. Every change of release or authority is a public event.
- **A court of record.** Verdicts are mirrored into Kourt, where the
  community there can contest them; a disagreement is recorded as dissent
  for everyone to see.

## The token

Pythia (PYTH) has a fixed supply of 100 million, with a hard cap of 120
million that only the DAO can approach, by vote, at most 2% a year. At
launch 40% goes to the DAO treasury, 25% to provider and user incentives,
20% to market liquidity and 15% to the founders with vesting. Holding PYTH
does nothing by itself; staking it in the DAO earns the stakers' share of
fees and the right and duty to vote.

## The software

On the chain (gno.land realms):

- **core**: feeds, rounds, providers, consumer credits, disputes, and all
  the GNOT they involve.
- **dao**: PYTH staking, proposals, dispute ballots, the treasury.
- **token**: PYTH itself.
- **kourt**: the mirror that files verdicts in the DAO's court on Kourt
  (the deployed Kourt v3 realm).

Each realm has web pages (feeds, rounds, disputes, members, proposals,
health) and machine-readable views the tools use.

Off the chain (one small program each, also shipped as one container
image):

- **gnoracle-agent**: what a provider runs. It watches its feeds, fetches
  values from web APIs, a Gnoswap pool, another realm, a script or a file a
  human writes, checks them against sanity bounds, submits, finalises rounds
  and claims rewards, and keeps a journal that serves as evidence in a
  dispute.
- **gnoracle-bot**: announces disputes, proposals, jailings and releases
  with their deadlines on Telegram, reminds members before a voting phase
  closes, and performs the routine chores anyone may do: closing rounds,
  resolving finished ballots, filing verdicts in Kourt, settling members'
  penalties and rewards.
- **gnoracle**: the command-line tool for everything else, from registering
  as a provider to casting a sealed vote (it keeps the secret needed to
  reveal it).

## Status

The realms and the tools are complete and tested against a local chain,
including a captured end-to-end run with three providers and the bot
(`docs/AGENT_SOAK_SHOWCASE.md`). The next steps are a public testnet
deployment with a live Kourt court, a four-week soak with real providers,
an external audit, and then mainnet under the namespace
`gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/`. Nothing
here has been audited yet; do not put real money behind it before that.

## Where to read more

- `docs/guides/PROVIDERS.md`, `CONSUMERS.md`, `SPONSORS.md`,
  `REQUESTERS.md`, `MEMBERS.md`: what to do, step by step, in each role.
- `docs/OPERATIONS.md`: deploying, upgrading, running the bot, monitoring,
  what to do when something breaks.
- `docs/IMPLEMENTATION_PLAN.md`: the design, the tokenomics, the security
  analysis, every parameter and why it has its value.
- `docs/SIMULATION.md`: what feeds cost and earn at different cadences.
- `docs/RESEARCH.md` and `docs/ORACLE_NETWORKS_RESEARCH.md`: the facts about
  gno.land, Kourt and other oracle networks the design rests on.

## For developers

Gno realms under `gno.land/r/clockwork/gnoracle/` and pure packages under
`gno.land/p/clockwork/gnoracle/`, pinned to gno v1.2.0 (the mainnet
release); Go tools under `cmd/`, `agent/`, `bot/` and `internal/`.

```sh
make toolchain deps        # the pinned gno toolchain and the on-chain dependency mirror
make test go-test          # every Gno suite, then the Go tests
make dev RPC=36657 WEB=38888   # a local chain with the realms and gnoweb
make chain-test            # drive a whole lifecycle on it
make agent-soak            # several agents and the bot against it, with assertions
make go-build              # bin/gnoracle, bin/gnoracle-agent, bin/gnoracle-bot
make build deploy NS=<address>   # publish the realms under your namespace
```

CI runs the suites and publishes the container image
`ghcr.io/clockworkgr/gnoracle`. The Kourt mirror pages carry the "built on
Kourt" notice that Kourt's licence asks for.
