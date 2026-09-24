# Demo walkthrough: what you see on gnoweb

This guide follows one run of `make demo` and describes every page it leaves
behind on gnoweb, what each table means, and how the pages link to each
other. The numbers below come from a real run; yours will differ in the
details (addresses, timestamps, the exact prices) but not in shape.
[DEMO.md](DEMO.md) covers how to run the demo, the shortened clocks and
troubleshooting.

```sh
make toolchain deps go-build   # once
make demo                      # about seven minutes; everything stays up afterwards
make demo-stop                 # when you are done
```

gnoweb is at **http://127.0.0.1:38888**. Every link below is relative to it.

## The story in one paragraph

A price feed, `DEMO/USD`, is proposed and activated. Three provider agents
bond 1,000 GNOT each and submit a price every minute. The "market" price is
a small file that takes a random step every 15 seconds; two agents fetch it
over HTTP and the third reads it with its own small error. An example
consumer realm, **reader**, is subscribed to the feed and reads it every 20
seconds, keeping each value with the block height it read it at. A
challenger then disputes the round the reader last read, claiming it should
have been 5% higher. The DAO's three members vote in a commit-reveal ballot,
uphold the round, and the challenger loses the bond. The verdict is filed
as a claim in the DAO's court on Kourt v3, where it is staked, answered and
settled. Finally the fees are forwarded to the DAO and the members settle,
so their pages show what they earned.

While the demo runs, the terminal prints each page's link as the page comes
to life. Afterwards the agents, the bot and the reader keep running, so the
feed and reader pages keep growing while you browse.

## Where to start

| Page | Path |
|---|---|
| Oracle home (feeds) | `/r/clockwork/gnoracle/core` |
| The feed | `/r/clockwork/gnoracle/core:feed/1` |
| The consumer realm | `/r/clockwork/gnoracle/demo/reader` |
| The dispute | `/r/clockwork/gnoracle/core:dispute/1` |
| The DAO | `/r/clockwork/gnoracle/dao` |
| The Kourt mirror | `/r/clockwork/gnoracle/kourt` |
| The court on Kourt | `/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:gnoracle` |

Every realm page also has two gnoweb tabs at the top: **source**, which
shows the realm's code, and **actions** (`$help`), which lists its public
functions. Functions that only read, such as the reader's `Last()` or
`Count()`, run right in the browser. Functions that change state, such as
`Poll` or `Submit`, are transactions: the page shows the `gnokey` command
to run them from a terminal.

## 1. The oracle: `/r/clockwork/gnoracle/core`

The home page names the release serving the realm
(`core/impl/v1`) and lists the feeds:

| id | name | kind | status | providers | value |
|---|---|---|---|---|---|
| 1 | DEMO/USD | recurring | active | 3/3 | 1.003513 @ round 6 |

The links across the top lead to the disputes list, the health check, the
parameters and the releases page.

### The feed: `:feed/1`

The feed page is the heart of the demo. The top table is the feed's spec
and state:

- **interval** 60 s: a new round every minute, open for 60 s.
- **subscription** 100 GNOT per 30-day period: what funds the providers.
  The requester paid the first period when proposing the feed.
- **pool** and **drip**: the providers' share of the subscription (70%),
  paid out a little every round.
- **providers** 3 of 3, minimum 2, minimum stake 1,000 GNOT.
- **tolerance / quarantine** 1% / 10%: submissions within 1% of the median
  count toward consensus; a jump of more than 10% from the last final value
  would be marked provisional.
- **dispute window** 2 hours: how long anyone may challenge a round.
- **realm access** 10 GNOT per period per realm, with the number of
  subscribed realms and a link to the subscribers page. This is what a
  contract pays to use the feed on chain; reading costs nothing per call.
- **value at risk**: roughly what an attacker controlling a majority of the
  providers would lose to a major slash. Consumers should not let a single
  unconfirmed value move more than this.
- **last value** with its round and tier, for example
  `1.003513 @ round 6 (tier consensus)`.

Below it, the **Providers** table lists the three agents with their stake,
misses, strikes and unclaimed rewards. Each address links to that
provider's page.

### Rounds: `:feed/1/rounds`

Every round, newest first:

| round | status | tier | value | eligible | pool | finalised |
|---|---|---|---|---|---|---|
| 6 | aggregated | consensus | 1.003513 | 3/3 | 1250001620 | … |
| 5 | aggregated | consensus | 1.003686 | 3/3 | 1621 | … |
| 3 | aggregated | consensus | 1.000066 | 3/3 | 1620 | … |
| 2 | aggregated | consensus | 0.997461 | 3/3 | 1621 | … |

- **value** follows the random walk of the market price.
- **eligible 3/3** means all three submissions agreed within tolerance.
- **pool** is what that round paid out. Most rounds pay only the small drip
  of about 1,600 ugnot. One round after the dispute pays about 1,250 GNOT:
  half of the losing challenger's bond went to the feed's penalty carry,
  and the next finalised round paid it to the providers.
- The disputed round (3 in this run) shows a later **finalised** time,
  because resolving the dispute re-finalised it.

Values show the moment they exist. Chain state is public, so the pages hide
nothing; what a subscription buys is the right to use a value inside a
realm's logic.

### A provider: `:provider/1/<address>`

One provider's record: status, stake, unbonding amount, unclaimed rewards,
total earned and slashed, consecutive misses, strikes, jailings and the
memo it registered with (`demo agent demo1`). In the demo every provider
shows 0 misses and 0 strikes and roughly 412 GNOT earned: its equal share of
the round pools, including the forfeited bond.

### Subscribers: `:feed/1/subscribers`

The realms allowed to `Read` this feed:

| realm | since | paid until | paid | periods | active |
|---|---|---|---|---|---|
| `gno.land/r/clockwork/gnoracle/demo/reader` | … | … | 10000000 | 1 | true |

The demo paid one 30-day period (10 GNOT) for the reader realm. Anyone may
pay for any realm with `SubscribeRealm`; paying again extends the same row.

### The dispute: `:dispute/1`

| | |
|---|---|
| round | 3 |
| status | resolved |
| disputer | the challenger's address |
| bond | 2500000000 ugnot |
| asks for | minor |
| proposed value | 1.050069 |
| outcome | UPHOLD |
| slashed | 0 ugnot |

The page ends with the challenger's evidence text and two links: the
**DAO ballot** (its machine view, with the commit and reveal tallies) and
the **Kourt mirror** record of the same dispute. UPHOLD means the round
stood: nobody was slashed, and the challenger's 2,500 GNOT bond was split
between the providers (via the penalty carry), the coherent voters and the
fee pool.

`:disputes` lists every dispute with its feed, round, status and outcome.

### Health: `:health`

The conservation check of the permanent realm:

```
{"status":"ok","balance":4314499888,"held":4314499888,"stakes":3000000000,
 "pools":76988662,"rewards":1237511226,"feesPending":0, ...}
```

`status` is `ok` when every category the core owes (stakes, pools,
rewards, bonds, pending fees, deposits) is covered by its actual balance.
Here `balance` equals `held` exactly: three 1,000 GNOT stakes, the feed
pool and the providers' unclaimed rewards. `feesPending` is 0 because the
demo forwarded the fee pool to the DAO at the end.

### Releases and parameters: `:releases`, `:params`

`:releases` shows which implementation serves the realm, who holds the
upgrade authority (the public dev key `test1` on this chain), the rehearsal
release `core/impl/v2` waiting for acceptance, and every parameter with its
bounds and the most it may change per step. On this development chain the
demo lowered a few clocks; the table shows the values actually in force.

## 2. The consumer realm: `/r/clockwork/gnoracle/demo/reader`

An example of a contract that uses the oracle. Its page shows:

| | |
|---|---|
| realm | `gno.land/r/clockwork/gnoracle/demo/reader` and its address |
| subscription | `feed 1: active until … UTC, 10.000000 GNOT paid over 1 period(s)` |
| readings kept | 21 |
| last reading | **1.003513** (consensus) for round 6 of feed 1 DEMO/USD, read at height 434, … UTC |

Then a table of the newest 50 readings: sequence number, block height,
chain time, feed, round, value and tier. The demo's poller calls
`Poll(1)` every 20 seconds, so you see several readings per round, and the
value changes when a new round lands.

Each `Poll` is a transaction in which the reader realm calls the core's
`Read` and stores what it got. The core serves it because the reader is
subscribed; any other realm calling `Read` on this feed would be refused.
A read costs nothing per call and changes nothing on the core.

On the **actions** tab, `Last()` and `Count()` run in the browser.

## 3. The DAO: `/r/clockwork/gnoracle/dao`

The home page shows the staked PYTH (300,000 across 3 members), the release
serving it, and the governance proposals. The demo opens no proposals, so
the table is empty; disputes use ballots, not proposals.

### Members: `:members` and `:member/<address>`

`:members` lists the three members (the dev key `test1`, `voter1`,
`voter2`) with their stake. A member page shows what that member is owed
after the demo's settlement step:

| | |
|---|---|
| staked | 100000000000 |
| voting weight now | 100000000000 |
| fees claimable | 88833333 ugnot |
| dispute rewards | 0 PYTH, 250000000 ugnot |
| ballots settled | 1 of 1 |

- **fees claimable** is the member's share of the staker half of the fee
  pool: the subscription fees and the forfeited bond's fee share,
  forwarded from the core and split by stake.
- **dispute rewards** is the member's share of the coherent voters' 30% of
  the forfeited bond. All three voted UPHOLD, the winning side, so each got
  a third of 750 GNOT. Nobody was absent or voted against, so no PYTH moved.
- **ballots settled 1 of 1** means the member's penalties and rewards for
  the one ballot have been applied.

### Health: `:health`

The DAO's conservation check. After the demo it reads `status` ok. The
ugnot it holds (1,283 GNOT) splits into what it owes members (1,016.5 GNOT
of fees and rewards) and the treasury (266.5 GNOT: the treasury half of the
fee pool). The PYTH it holds is exactly the members' stake.

## 4. The Kourt mirror: `/r/clockwork/gnoracle/kourt`

Every page starts with the "built on Kourt" notice. The index shows the
DAO's court (linked), the Kourt v3 realm it lives in, the mirror's
court-coin float (20 CC, all free after settlement) and whether the court's
coin is two-way. Below is one row per mirrored dispute: its state, its
claim on Kourt (linked) and the claim's title.

`:dispute/1` is the mirror's record of dispute 1:

| | |
|---|---|
| dispute | 1 (links back to the core's dispute page) |
| state | settled |
| claim | 1 (links to the claim on Kourt) |
| title | Gnoracle #1: feed 1 round 3 resolved UPHOLD; value 1000066; … |
| verdict | YES (undisputed) |
| stake | 2.000001 CC |
| Kourt says | settled YES — every stake withdraws 1× |

The mirror's states run pending, filed, staked, answered, then settled
(Kourt agreed without a vote), confirmed (Kourt's vote agreed) or dissent
(Kourt's vote disagreed with the DAO).

## 5. The court on Kourt: `/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:gnoracle`

This is Kourt's own page for the DAO's court, "Gnoracle disputes". It
lists the claims with their status, then the court's coin: its price on the
bonding curve, the GNOT held behind it, what one coin redeems for, and the
coin in circulation. The demo bought about 141 CC for 10 GNOT, which shows
here.

### The claim: `:gnoracle/1`

Kourt's page for the claim the mirror filed:

- **Title**: the verdict as one sentence, for example
  `Gnoracle #1: feed 1 round 3 resolved UPHOLD; value 1000066; …`.
- **Body**: the dispute record as JSON: feed and name, round, outcome,
  prior and proposed values, disputer, bond, slashed amount, coherent
  weight, evidence hash, resolution time and the core page it came from.
- **Signal**: 2 CC staked on YES by the mirror, 100% YES.
- **Status**: `settled YES — every stake withdraws 1×`.
- **Resolution**: the mirror answered YES with a bond, nobody disputed it
  within Kourt's 72-hour window, and the verdict is YES, undisputed.

Kourt's clocks normally take hours to days (three epochs of stake history
before an answer, 72 hours before an undisputed settlement). The demo
skips them with Kourt's own test clock, which only works on a fresh
development chain.

## 6. What keeps running

After the demo prints its final list of links:

- The three agents keep submitting every minute, so the rounds page and
  the feed's last value keep moving.
- The reader keeps polling every 20 seconds, so its table grows.
- The bot keeps finalising rounds, resolving disputes and cranking the
  Kourt mirror, and logs its announcements to `.dev-agent/demo/bot.log`.

To try things yourself, use the CLI with the dev keybase (password
`devpassword`), for example:

```sh
bin/gnoracle -remote http://127.0.0.1:36657 -chain dev -ns clockwork -key-home .dev-keys -key test1 feed 1
bin/gnoracle -remote http://127.0.0.1:36657 -chain dev -ns clockwork -key-home .dev-keys -key test1 \
  call gno.land/r/clockwork/gnoracle/demo/reader Poll 1
```

`make demo-stop` ends the agents, the bot, the reader's poller, the price
source and the chain the demo started.
