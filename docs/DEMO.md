# The local demo

`make demo` tells the whole Gnoracle story on a chain on your machine in
about seven minutes, and leaves everything running so you can look at each
page on gnoweb afterwards: a price feed served by three provider agents, a
consumer realm that reads it, a dispute, the DAO's commit-reveal ballot, and
the verdict filed as a claim in the DAO's court on Kourt v3.

```sh
make toolchain deps go-build   # once: the pinned gno tools, the on-chain dependency mirror, the Go binaries
make demo                      # starts a local chain (gnodev with gnoweb) if none listens on 36657, else uses it
RESET=1 make demo              # same, but reset a running dev chain first
make demo-stop                 # stop the agents, bot, poller and a chain the demo started (KEEP_CHAIN=1 keeps it)
```

The script prints a link to each page as it comes to life; gnoweb is at
`http://127.0.0.1:38888` (`WEB=` to change it; `RPC=` for the node, default
36657). Logs land in `.dev-agent/demo/`.

## What happens, in order

| Step | What you see | Where to look |
|---|---|---|
| Chain | gnodev starts with the realms, the Kourt v3 realm's mirrored source at its mainnet path and the example reader realm; gnoweb comes up | the five realm links printed first |
| Releases | the guardian key (`test1`) accepts `core/impl/v1`, `dao/impl/v1` and `kourt/impl/kourtv3` | `core:releases`, `dao:releases`, `kourt` |
| Clocks | Kourt's test clock is armed; the ballot, appeal and epoch clocks are shortened (table below) | the `:params` pages |
| Keys | three provider keys, two member keys, a challenger, a bot key and a poller key are created in `.dev-keys/` and funded | |
| Members | `test1`, `voter1` and `voter2` each stake 100,000 PYTH; their weight counts from the next epoch (ten blocks here) | `dao:members` |
| Feed | `DEMO/USD` (one-minute rounds) is proposed and activated; the three providers register 1,000 GNOT each; 10 GNOT of read credit is deposited for the reader realm | `core:feed/1`, `core:consumer/<reader address>` |
| Live phase | three agents (http and exec adapters) submit every round, the bot announces finalisations, and the reader realm polls the feed every 20 s, keeping each value with its block height | `core:feed/1/rounds`, `demo/reader`, `.dev-agent/demo/bot.log` |
| Dispute | the challenger contests the round the reader last read, proposing a value 5% higher (minor tier, 2,500 GNOT bond); the ballot opens | `core:dispute/1` |
| Ballot | the three members commit `UPHOLD`, reveal when the phase turns, the ballot is counted, the appeal window passes, the dispute resolves: the challenger forfeits the bond | `core:dispute/1`, `dao:member/<address>` |
| Kourt | the mirror founds court `gnoracle` on the Kourt v3 realm, `test1` buys court coin and moves 20 CC into the mirror's float, the verdict is filed as claim 1, staked, answered and settled | `kourtv3:gnoracle`, `kourtv3:gnoracle/1`, `kourt:dispute/1` |

Afterwards the agents keep producing rounds and the reader keeps reading, so
the feed and reader pages grow while you browse. The bot posts to its log
(no Telegram token in the dev config).

## The clocks

A development chain cannot skip time, so the demo shortens what would
otherwise take days. Production values stay what the plan says; the shorter
values are only *allowed* on a chain whose id is `dev` (gnodev, and nothing
else), through floors that exist only there and the DAO's `DevSetParam`
entry point, which refuses on any other chain.

| Clock | Production default | Demo value | How |
|---|---|---|---|
| `dao.commitPeriod` | 24 h | 60 s | `DevSetParam` (dev floor 30 s; 6 h elsewhere) |
| `dao.revealPeriod` | 24 h | 60 s | same |
| `core.appealWindow` | 24 h | 30 s | guardian `SetParam` (dev floor 10 s; 1 h elsewhere) |
| `dao.epochBlocks` | 720 blocks, fixed | 10 blocks | `DevSetParam` (dev floor 10; fixed elsewhere) |
| `core.providerMinStakeFloor` | 10,000 GNOT | 1,000 GNOT | guardian `SetParam` (within the ordinary bounds) |
| `core.renderDelay` | 600 s | 0 | guardian `SetParam` (within the ordinary bounds), so pages show values at once |
| Kourt v3: three epochs of stake history before an answer, 72 h before an undisputed settlement | | skipped | Kourt's own test clock (`EnableTestClock`, `AdvanceTestHeight`, `AdvanceTestClock`), which only the realm's deployer may arm, only before the court exists |

Each change obeys the parameters' 50%-per-block rate limit, so the script
halves its way down and prints the result beside the value it started from.

The Kourt clock is armed only on a chain that has no court besides Kourt's
own `meta` yet. On a chain where a court already exists (a chain-test ran
before, say) the demo says so and the claim runs on Kourt's real clock: the
bot cranks the mirror hourly, the answer follows about three hours of blocks
and the settlement 72 hours later. `RESET=1` gives a clean chain.

## Reading the pages

- **`core:feed/1`** shows the feed, its providers and the latest value;
  `core:feed/1/rounds` every round with who submitted what.
- **`demo/reader`** is the example consumer realm: its address, the read
  credit left, and every reading with the block height and chain time it was
  taken at. Its source is `gno.land/r/clockwork/gnoracle/demo/reader`; any
  realm reads the same way (`core.Read` through a crossing call, paid from
  credit deposited for its address).
- **`core:dispute/1`** shows the challenge, the ballot's tally once counted,
  the outcome, the bond's fate and the Kourt link.
- **`kourtv3:gnoracle`** is the DAO's court on Kourt; **`kourtv3:gnoracle/1`**
  the claim: the verdict sentence as its title, the JSON record as its body,
  the mirror realm as author, staker and answerer, `settled YES` once done.
  **`kourt:dispute/1`** is the mirror's own record of the same steps.
- **`core:health`** and **`dao:health`** are the conservation checks; both
  read `ok` throughout.
- **Calling from the pages.** Each realm page lists its functions. Views
  without a `cur realm` parameter (`Last()`, `Count()`) run in the browser
  against the node; anything that changes state (`Poll`, `Submit`, a
  dispute) is a transaction, so the page shows the `gnokey` command to run
  from a terminal with the dev keybase, and the `gnoracle` CLI does the
  same: `bin/gnoracle -remote http://127.0.0.1:36657 -chain dev -ns clockwork
  -key-home .dev-keys -key test1 call gno.land/r/clockwork/gnoracle/demo/reader Poll 1`
  (password `devpassword`).

## If something is off

- *Another chain answers on 26657.* The demo uses 36657/38888 by default so
  it never touches it; pass `RPC=`/`WEB=` to use other ports.
- *"the chain ... does not serve ... restart make dev"*: a gnodev started
  before this repo added the reader realm or the Kourt v3 release is still
  running; stop it and let the demo start its own (or `make dev` again).
- *A port is in use* (38998 for the demo's price server): set `PRICE_PORT`.
- *The demo stopped mid-way*: `make demo-stop`, then `RESET=1 make demo`.
  The chain state is a throwaway; the keys in `.dev-keys/` are the public
  gnodev ones and never worth anything.
