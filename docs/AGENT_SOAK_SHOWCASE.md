# Agent soak showcase: three providers, the bot and one feed on gnodev

> **Historical capture.** This run predates the removal of metered reads
> (2026-09-24) and is kept as it was recorded. Since then the spec field
> `readPrice`, the `renderDelay` that made the views show `delayed`, and
> the chain-test step "deposit consumer credit and read" no longer exist:
> realms read free per call under a per-period subscription, and
> `make chain-test` now subscribes the example reader realm
> (`demo/reader`) instead. The soak's bot now signs with a key of its own,
> `soakbot`, rather than the `test1` it shared with an agent in this run.
> The round pools, credits and health figures below reflect the old read
> fee.
A complete, unedited run of `make agent-soak` on 2026-09-23 (UTC 14:02:09 to 14:07:18), from repository commit `ff248d4`, against a local gno v1.2.0 chain. Every command, log line and chain state below was captured from that run; nothing is illustrative. It shows the whole loop the protocol relies on: providers register with stake, their agents fetch a value each round, submit it, the round finalises (early, when everyone obliged has submitted), rewards accrue, and the bot announces every step while cranking what nobody else did.
Chain time in the tables below is UTC; the tool logs are in the host's local time (UTC+3).

## 1. Environment

| | |
|---|---|
| chain | gnodev (`chain dev height 144 time 2026-09-23T14:02:09Z`), RPC `http://127.0.0.1:36657`, gnoweb `http://127.0.0.1:38888` |
| toolchain | gno v1.2.0 built from the tag (`make toolchain`); tools built with `CGO_ENABLED=0 go build` from `gnolang/gno v1.2.0` |
| core realm | `gno.land/r/clockwork/gnoracle/core` serving `gno.land/r/clockwork/gnoracle/core/impl/v1` |
| dao realm | `gno.land/r/clockwork/gnoracle/dao` serving `gno.land/r/clockwork/gnoracle/dao/impl/v1` |
| keys | throwaway keybase `.dev-keys/` (test1 is gnodev's funded genesis key; the soak creates the others) |
| price source | a local `python3 -m http.server` serving `price.json` on port 38999 for the `http` adapter; the `exec` adapter prints a value from a shell one-liner |

### The feed
`gnoracle feed 1` before the run (the spec is what the DAO accepted when `make chain-test` created the feed):

| field | value |
|---|---|
| `name` | DEMO/USD |
| `kind` | recurring |
| `valueType` | numeric |
| `decimals` | 6 |
| `interval` | 60 |
| `submitWindow` | 60 |
| `sources` | Any number; this is a demo. |
| `minProviders` | 2 |
| `maxProviders` | 3 |
| `providerMinStake` | 1000000000 ugnot (1,000 GNOT) |
| `toleranceBps` | 100 |
| `quarantineBps` | 1000 |
| `disputeWindow` | 7200 |
| `readPrice` | 20000 ugnot (0.02 GNOT) |
| `subscriptionPrice` | 100000000 ugnot (100 GNOT) |
| status / pool / drip per round | active / 69996760 ugnot / 1620 ugnot |
| last finalised round / current round | 1 / 1 |

Providers before the run (`gnoracle providers 1`): the two providers `make chain-test` registered when it created the feed.

| provider | status | slot | stake (ugnot) | consecutive misses | earned so far (ugnot) |
|---|---|---|---|---|---|
| `g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5` | active | 0 | 1000000000 | 0 | 1604 |
| `g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434` | active | 1 | 1000000000 | 0 | 1604 |

## 1a. The chain was new
gnodev was started from scratch shortly before 14:00:40 UTC (`make dev RPC=36657 WEB=38888`) and `make chain-test` then drove the whole lifecycle once: accept the implementations, create and activate feed 1, register two providers, submit two rounds, deposit consumer credit and read, stake in the DAO, forward fees, found the Kourt court and fund its float. Its step headings, unedited:

```
state before
accept the implementation (registered by its own init at deploy)
fund prov2 with 3000 GNOT
lower the stake floor for the demo (rate limit: several steps)
propose a one-minute price feed (deposit 5 + first period 100 GNOT)
activate
register two providers (1000 GNOT each)
wait for round 0 to open
submit round 0 from both providers (second submission finalises early)
round 1: measure the marginal storage of one more round
deposit credit and read
DAO: accept its implementation, stake PYTH, sync fees, open and vote a proposal
forward the core's pending fees to the DAO and sync them
a text proposal and a vote (voting weight activates next epoch, so this may need ~1h of chain time)
Kourt mirror: accept its implementation, found the court, fund the float
health and page
```

## 2. Pre-flight
`gnoracle status` reads the three realms' `:json/now` views and the node's `/status`:

```
chain dev height 144 time 2026-09-23T14:02:09Z
core  gno.land/r/clockwork/gnoracle/core now 1790172129 live gno.land/r/clockwork/gnoracle/core/impl/v1
dao   gno.land/r/clockwork/gnoracle/dao epoch 1 staked 1000000000000 members 1 proposals 1 ballots 0 live gno.land/r/clockwork/gnoracle/dao/impl/v1
kourt gno.land/r/clockwork/gnoracle/kourt {"now":1790172129,"live":"gno.land/r/clockwork/gnoracle/kourt/impl/v1","court":"gnoracle","kourt":"gno.land/r/clockwork/gnoracle/kourtdev","count":0,"disputes":0}
```

## 3. Keys, funding and registration
The soak script (`scripts/agent-soak.sh`) uses `test1` and creates `soak1`, `soak2`, … in the dev keybase, funds each from `test1` with the feed's minimum stake plus a gas float, and registers it through the CLI (`gnoracle register <feed> <stake> <memo>`, which sends the stake with the `Register` call). A key that is already an active provider is reused; a full provider set is reported and skipped.

```
prov2 (g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434): existing key, runs as an agent
soak1 (g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr): registered
agents: test1 prov2 soak1
```

Registration assigns the next free slot; obligations start at the round after the current one (`obligedFrom`), so a newcomer is never penalised for a round that was already open.

## 4. Generated configuration
One `agent.toml` per key. Odd-numbered agents use the `http` adapter against the local price server, even-numbered ones the `exec` adapter, so the run exercises both paths and the values differ slightly (the feed's tolerance is 1%, so all stay eligible). `dev_tick` is a gnodev-only setting that nudges the lazy chain clock with a one-ugnot self-send.
`test1.toml`:

```toml
remote = "http://127.0.0.1:36657"
chain_id = "dev"
core = "gno.land/r/clockwork/gnoracle/core"
key_home = "/Volumes/Tendermint/gnoracle/.dev-keys"
key = "test1"
state = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/test1-state.json"
journal = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/test1-journal.jsonl"
poll = "2s"
dev_tick = true
[[feeds]]
id = 1
jitter = "1s"
finalize_delay = "3s"
[feeds.source]
adapter = "http"
urls = ["http://127.0.0.1:38999/price.json"]
path = "data.amount"
```

`prov2.toml`:

```toml
remote = "http://127.0.0.1:36657"
chain_id = "dev"
core = "gno.land/r/clockwork/gnoracle/core"
key_home = "/Volumes/Tendermint/gnoracle/.dev-keys"
key = "prov2"
state = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/prov2-state.json"
journal = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/prov2-journal.jsonl"
poll = "2s"
dev_tick = true
[[feeds]]
id = 1
jitter = "2s"
finalize_delay = "6s"
[feeds.source]
adapter = "exec"
command = ["sh", "-c", "printf '1.00%02d\n' $((RANDOM % 40))"]
```

`soak1.toml`:

```toml
remote = "http://127.0.0.1:36657"
chain_id = "dev"
core = "gno.land/r/clockwork/gnoracle/core"
key_home = "/Volumes/Tendermint/gnoracle/.dev-keys"
key = "soak1"
state = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/soak1-state.json"
journal = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/soak1-journal.jsonl"
poll = "2s"
dev_tick = true
[[feeds]]
id = 1
jitter = "3s"
finalize_delay = "9s"
[feeds.source]
adapter = "http"
urls = ["http://127.0.0.1:38999/price.json"]
path = "data.amount"
```

The bot's configuration (`bot.toml`) posts to the log (no Telegram token) and has every crank enabled:

```toml
# Notifier and cranker against the local gnodev, posting to the log.
remote = "http://127.0.0.1:36657"
chain_id = "dev"
core     = "gno.land/r/clockwork/gnoracle/core"
dao      = "gno.land/r/clockwork/gnoracle/dao"
kourt    = "gno.land/r/clockwork/gnoracle/kourt"
gnoweb   = "http://127.0.0.1:38888"
key_home = "/Volumes/Tendermint/gnoracle/.dev-keys"
key      = "test1"
state = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/bot-state.json"
poll     = "5s"
max_blocks = 500
events = ["RoundFinalized", "Submitted", "DisputeOpened", "DisputeBallotOpened", "DisputeRolled", "AppealOpened", "DisputeDecided", "DisputeResolved", "ProposalCreated", "ProposalStatus", "ProviderJailed", "ProviderSlashed", "KourtDissent", "FeedActivated", "ReleaseAccepted", "ReleaseRolledBack"]

[telegram]
token = ""    # empty: messages go to the log
chat = 0

[[members]]
addr = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
name = "test1"
settle = true

[remind]
hours = [24, 2]
every = "1m"

[crank]
finalize = true
resolve = true
kourt = true
settle = true
every = "30s"
kourt_every = "2m"
settle_every = "2m"
finalize_grace = "20s"
```

## 5. The run, as one timeline
The agents and the bot ran for 300 seconds. Below are their log lines merged and sorted by time. Agents are `test1`, `prov2`, `soak1`; `bot` lines are the messages the bot would have posted to Telegram (`RoundFinalized` and `Submitted` are announced here because the dev config lists them; the default list covers disputes, proposals, providers, feed lifecycle, releases, authority and parameter changes).

```text
17:02:17  prov2  agent: gno.land/r/clockwork/gnoracle/core on http://127.0.0.1:36657 as g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434, 1 feed(s), poll 2s
17:02:17  bot    bot: watching gno.land/r/clockwork/gnoracle/core, gno.land/r/clockwork/gnoracle/dao on http://127.0.0.1:36657; cranks finalize=true resolve=true kourt=true settle=true
17:02:18  test1  agent: gno.land/r/clockwork/gnoracle/core on http://127.0.0.1:36657 as g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5, 1 feed(s), poll 2s
17:02:18  soak1  agent: gno.land/r/clockwork/gnoracle/core on http://127.0.0.1:36657 as g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr, 1 feed(s), poll 2s
17:02:18  soak1  obligations start at round 2 (current 1); waiting
17:03:06  test1  round 2: submitted 1.001200 (tx 8EB0829FDD82B3561178F2DABA33CEFBA33128C3DBEA553B99A085A039C62F19, gas 17952070, fee 38449ugnot)
17:03:06  soak1  round 2: submitted 1.001200 (tx 82D8B7174EE448ED8A9C16B1696AFABBE54F95711EA01C0A4892D14CCB2FCEC8, gas 18566740, fee 38208ugnot)
17:03:07  prov2  round 2: submitted 1.001500 (tx 143243A8C293D324883E6E23E7B8DDBB6E19403DE4B884A54D7B78DB593E9197, gas 31770846, fee 54713ugnot)
17:03:07  bot    [core] Submitted feed=1 round=2 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1001200
17:03:07  bot    [core] Submitted feed=1 round=2 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
17:03:07  bot    [core] Submitted feed=1 round=2 provider=g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434 value=1001500
17:03:07  bot    [core] RoundFinalized feed=1 round=2 status=aggregated tier=consensus value=1001200 eligible=3 pool=15620
17:04:03  prov2  round 3: submitted 1.000800 (tx 3EE88BCA9675EF905DCC3B4B2E7F6617657B053A8213D5CBB7FD232EF9126638, gas 18583528, fee 38229ugnot)
17:04:04  test1  round 3: submitted 1.001200 (tx 4BA1553ADC11B8152AB4DFF675168758BB93EB7BD6B09E15BF338C845F32B769, gas 31771194, fee 54714ugnot)
17:04:04  soak1  round 3: submitted 1.001200 (tx 1269DD4E1E2F2161A9CBD81CB44C1F10E318399A3DAFE0BCD9FB96E5AF94C8F8, gas 17765755, fee 37207ugnot)
17:04:07  bot    [core] Submitted feed=1 round=3 provider=g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434 value=1000800
17:04:07  bot    [core] Submitted feed=1 round=3 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1001200
17:04:07  bot    [core] Submitted feed=1 round=3 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
17:04:07  bot    [core] RoundFinalized feed=1 round=3 status=aggregated tier=consensus value=1001200 eligible=3 pool=1622
17:05:05  prov2  round 4: submitted 1.002900 (tx A3675C80754C91BF673508910DC29AA34CB64286C4491AC332CC5ED687AEA435, gas 18593526, fee 38242ugnot)
17:05:06  test1  round 4: submitted 1.001200 (tx 5889685886D033A3F59634A03E6264DD3F243865C158F120DA2572701D8BCC4A, gas 31791815, fee 37974ugnot)
17:05:06  soak1  round 4: submitted 1.001200 (tx 383F7A96F0877C39CEA68236512AA4B9112799BC6FD6CB62C671823D3169E541, gas 17777915, fee 37222ugnot)
17:05:07  bot    [core] Submitted feed=1 round=4 provider=g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434 value=1002900
17:05:07  bot    [core] Submitted feed=1 round=4 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1001200
17:05:07  bot    [core] Submitted feed=1 round=4 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
17:05:07  bot    [core] RoundFinalized feed=1 round=4 status=aggregated tier=consensus value=1001200 eligible=3 pool=1621
17:06:02  test1  round 5: submitted 1.001200 (tx 972E37E2C37FEC11AFAF176F5CE5B034AEDCFC2FDF40BE85DC57A1BBCD456DDA, gas 18792331, fee 38490ugnot)
17:06:02  bot    [core] Submitted feed=1 round=5 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
17:06:03  prov2  round 5: submitted 1.003600 (tx 3CC147FD8592E64B8D02F8A4BD6DCD14EF28791B360EDF5BE896B15075C9AF91, gas 18385830, fee 37982ugnot)
17:06:04  soak1  round 5: submitted 1.001200 (tx 9B7CC3C93E26B38C2730979AFCEB3FEFF1362013384A7412C2BB3EC2CE8A98D7, gas 31798335, fee 54748ugnot)
17:06:07  bot    [core] Submitted feed=1 round=5 provider=g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434 value=1003600
17:06:07  bot    [core] Submitted feed=1 round=5 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1001200
17:06:07  bot    [core] RoundFinalized feed=1 round=5 status=aggregated tier=consensus value=1001200 eligible=3 pool=1620
17:07:05  prov2  round 6: submitted 1.003200 (tx 7C0B110D28D9CC01F78F7FC596860A6BDF8F4BF14FF4C8C7C8B5626C72970B7F, gas 18607046, fee 38258ugnot)
17:07:06  test1  round 6: submitted 1.001200 (tx 2B0A6BE971E0340C57FCF713B1F555FBBDA95601AB0179A08C732D6C387B9A05, gas 31803975, fee 54755ugnot)
17:07:06  soak1  round 6: submitted 1.001200 (tx C8E77CEC2253188C5A160B74F2686D9837EA0F0C9DF5E956D3115963075ECBB8, gas 17789283, fee 37236ugnot)
17:07:07  bot    [core] Submitted feed=1 round=6 provider=g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434 value=1003200
17:07:07  bot    [core] Submitted feed=1 round=6 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1001200
17:07:07  bot    [core] Submitted feed=1 round=6 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
17:07:07  bot    [core] RoundFinalized feed=1 round=6 status=aggregated tier=consensus value=1001200 eligible=3 pool=1622
```

Things to notice:

- **The newcomer waits.** `soak1` registered during round 1, so its obligations start at round 2; its agent says so and waits, and the realm would reject an earlier submission. Round 1 was served by the two existing providers alone.
- **The last submitter finalises.** A `Submit` that completes the round aggregates, pays and records it in the same call: 18.5M gas for a plain submission against 31.8M for the finalising one, and the bot announces `RoundFinalized` in the same second as the third `Submitted`. Which agent is last varies with their jitter (1, 2 and 3 seconds).
- No `CatchUp` was needed: every round was completed by all three providers inside the window, so the cranks in the agents and the bot had nothing to do.
- Each agent's value comes from its own source: the two `http` agents read the same local `price.json` (1.0012), the `exec` agent prints a random value between 1.0000 and 1.0039; the round's value is the lower median, and every submission within the 1% tolerance is eligible and paid.

## 6. What the journal recorded
Every agent appends one JSON line per fetch, refusal, submission, finalisation, claim and error to its journal. This is the operator's evidence in a dispute: the raw source answers, the aggregated value, and the transaction that carried it. Entries from this run:
**A fetch (raw source response, aggregated value)** (`test1-journal.jsonl`):

```json
{
  "at": "2026-09-23T14:03:06Z",
  "feed": 1,
  "round": 2,
  "kind": "fetch",
  "value": 1001200,
  "samples": [
    {
      "source": "http://127.0.0.1:38999/price.json",
      "raw": "{\"data\":{\"base\":\"GNOT\",\"currency\":\"USD\",\"amount\":\"1.0012\"}}\n",
      "value": "1.001200000000"
    }
  ]
}
```

**The submission that followed** (`test1-journal.jsonl`):

```json
{
  "at": "2026-09-23T14:03:06Z",
  "feed": 1,
  "round": 2,
  "kind": "submit",
  "value": 1001200,
  "tx": "8EB0829FDD82B3561178F2DABA33CEFBA33128C3DBEA553B99A085A039C62F19",
  "gasUsed": 17952070,
  "fee": "38449ugnot"
}
```

## 7. Chain state after the run
`gnoracle rounds 1 10` (newest first) shows the rounds the run produced. `opened → finalised` is the chain-time distance from the round's scheduled opening to its finalisation; with a 60-second window, single-digit seconds mean every obliged provider submitted and the last one finalised the round early.

| round | status | tier | submitters (slots) | value | pool (ugnot) | opened → finalised |
|---|---|---|---|---|---|---|
| 6 | aggregated | consensus | 0, 1, 2 | delayed | 1622 | 6s |
| 5 | aggregated | consensus | 0, 1, 2 | delayed | 1620 | 3s |
| 4 | aggregated | consensus | 0, 1, 2 | delayed | 1621 | 6s |
| 3 | aggregated | consensus | 0, 1, 2 | delayed | 1622 | 4s |
| 2 | aggregated | consensus | 0, 1, 2 | delayed | 15620 | 6s |
| 1 | aggregated | consensus | 0, 1 | delayed | 1620 | 4s |
| 0 | aggregated | consensus | 0, 1 | delayed | 1620 | 5s |

Values read `delayed` because the free views only show a round's numbers once its dispute window and `renderDelay` have passed (plan §6.1); a paying realm gets them immediately through `Read`. The bot's `RoundFinalized` lines above carry the aggregate as emitted, which is the same rule applied to events: the value is public in the event log, and the fresh *view* is what consumers pay for.

### Providers

| provider | key | status | slot | rewards before | rewards after | earned this run | consecutive misses |
|---|---|---|---|---|---|---|---|
| `g1jg8mtutu9khhfw…` | test1 | active | 0 | 1604 | 8897 | 7293 | 0 |
| `g1y0rdyznt4hprxq…` | prov2 | active | 1 | 1604 | 8897 | 7293 | 0 |
| `g1y84vg6pkw0jtav…` | soak1 | active | 2 | 0 | 7293 | 7293 | 0 |

Feed pool: 69996760 → 69988660 ugnot (drip 1620 ugnot per round, from the subscription bought by `make chain-test`); rounds finalised: 2 → 7.
Each finalised round's pool is split equally among the eligible submitters after the 1% cranker tip. The pool is the drip plus the provider share of read fees metered since the last finalisation plus any penalty carry: round 2 above carries the 14,000 ugnot provider share (70%) of the 20,000 ugnot `Read` that `make chain-test` paid, which is why it pays far more than the drip.

### Conservation checks
`gnoracle health` renders both permanent realms' `Health()`: every ugnot the core holds must equal the sum of what it owes (stakes, unbonding, credits, pools, rewards, bonds, pending fees, deposits); the DAO checks its PYTH and ugnot the same way. Both read `ok` after the run:

```json
{
  "status": "ok",
  "balance": 3070993748,
  "held": 3070993748,
  "stakes": 3000000000,
  "unbonding": 0,
  "credits": 980000,
  "pools": 69988661,
  "rewards": 25087,
  "bonds": 0,
  "feesPending": 0,
  "deposits": 0
}
```

```json
{
  "status": "ok",
  "pyth": 1000000000000,
  "owedPyth": 1000000000000,
  "treasuryPyth": 0,
  "ugnot": 30006000,
  "owedUgnot": 15003000,
  "treasuryUgnot": 15003000,
  "staked": 1000000000000
}
```

## 8. Assertions
The script ends with the checks that make it a test rather than a demo:

```
- three consecutive aggregated rounds with two or more submitters
- consensus reached
- test1 earned rewards
- prov2 earned rewards
- soak1 earned rewards
- core health ok
- dao health ok
- bot announced finalisations
soak: PASS (logs in /Volumes/Tendermint/gnoracle/.dev-agent/soak)
exit 0
```

## 9. Numbers from this run

| transaction | count | gas used (min / median / max) | fee paid at 0.001 ugnot per gas |
|---|---|---|---|
| submit | 15 | 17,765,755 / 18,593,526 / 31,803,975 | 37,207 to 54,755 ugnot |

- Round finalised after it opened: 3 to 6 s against a 60 s window (agents poll every 2 s and wait a 1 to 3 s jitter).
- The fee is the gas asked for, not the gas used. In this run the tools simulated each call and asked for (measured gas + 12M finalisation headroom) x 1.25 for every `Submit`; the sizing has since been changed so the headroom is only added when exactly one other provider is still to submit, and the fee is the larger of measured x 1.25 and measured + headroom, which would have made most of these fees about 23,000 ugnot and the finalising ones about 40,000. A submission that also finalises costs about 13M gas more than a plain one, and which agent pays it depends on who submits last.
- On gnoland-1 the same transactions cost the same gas; only the gas price (0.001 ugnot per gas minimum) and the block time differ. `docs/SIMULATION.md` turns these numbers into monthly costs per feed cadence.

## 10. Reproduce it

```sh
make toolchain deps                       # once: pinned gno v1.2.0 and the on-chain dependency mirror
make dev RPC=36657 WEB=38888              # a local chain with the realms, in another shell
make dev-keys                             # .dev-keys/ with gnodev's test1 key
REMOTE=http://127.0.0.1:36657 CALL_GAS_WANTED=60000000 CALL_GAS_FEE=120000ugnot make chain-test   # feed 1, providers, DAO, Kourt
REMOTE=http://127.0.0.1:36657 AGENTS=3 DURATION=300 make agent-soak
ls .dev-agent/soak/                       # configs, logs, journals, state files of the run
```

The same agents run unchanged against pearl-1 or gnoland-1 with `remote`, `chain_id`, `core` and a real key in `agent.toml` (`configs/agent.example.toml`); `docs/guides/PROVIDERS.md` is the operator's path.
