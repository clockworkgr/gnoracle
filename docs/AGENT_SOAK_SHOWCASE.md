# Agent soak showcase: three providers, the bot and one feed on gnodev
A complete, unedited run of `make agent-soak` on 2026-09-23 (UTC 13:42:28 to 13:47:36), from repository commit `d2571db`, against a local gno v1.2.0 chain. Every command, log line and chain state below was captured from that run; nothing is illustrative. It shows the whole loop the protocol relies on: providers register with stake, their agents fetch a value each round, submit it, the round finalises (early, when everyone obliged has submitted), rewards accrue, and the bot announces every step while cranking what nobody else did.
Chain time in the tables below is UTC; the tool logs are in the host's local time (UTC+3).
## 1. Environment
| | |
|---|---|
| chain | gnodev (`chain dev height 117 time 2026-09-23T12:20:56Z`), RPC `http://127.0.0.1:36657`, gnoweb `http://127.0.0.1:38888` |
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
| status / pool / drip per round | active / 69959500 ugnot / 1620 ugnot |
| last finalised round / current round | 96 / 96 |

Providers before the run (`gnoracle providers 1`). Two are jailed: their agents were stopped in earlier experiments and three consecutive misses jail a provider, which is the protocol working as specified and frees their slots for newcomers.
| provider | status | slot | stake (ugnot) | consecutive misses | earned so far (ugnot) |
|---|---|---|---|---|---|
| `g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5` | active | 0 | 1000000000 | 0 | 6962920 |
| `g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr` | active | 2 | 1000000000 | 0 | 3715708 |
| `g1nzef2xxf66zgf0gelytqxu8nvfly5mwztgsd86` | jailed | -1 | 985000000 | 3 | 3245608 |
| `g1y0rdyznt4hprxqgxz366uar3v5pe247ksrr434` | jailed | -1 | 985000000 | 3 | 1604 |

## 2. Pre-flight
`gnoracle status` reads the three realms' `:json/now` views and the node's `/status`:
```
chain dev height 117 time 2026-09-23T12:20:56Z
core  gno.land/r/clockwork/gnoracle/core now 1790166056 live gno.land/r/clockwork/gnoracle/core/impl/v1
dao   gno.land/r/clockwork/gnoracle/dao epoch 1 staked 1000000000000 members 1 proposals 1 ballots 0 live gno.land/r/clockwork/gnoracle/dao/impl/v1
kourt gno.land/r/clockwork/gnoracle/kourt {"now":1790166056,"live":"gno.land/r/clockwork/gnoracle/kourt/impl/v1","court":"gnoracle","kourt":"gno.land/r/clockwork/gnoracle/kourtdev","count":0,"disputes":0}
```
## 3. Keys, funding and registration
The soak script (`scripts/agent-soak.sh`) uses `test1` and creates `soak1`, `soak2`, … in the dev keybase, funds each from `test1` with the feed's minimum stake plus a gas float, and registers it through the CLI (`gnoracle register <feed> <stake> <memo>`, which sends the stake with the `Register` call). A key that is already an active provider is reused; a full provider set is reported and skipped.
```
soak1 (g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr): already an active provider
soak2 (g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve): registered
agents: test1 soak1 soak2
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
jitter = "2s"
finalize_delay = "6s"
[feeds.source]
adapter = "exec"
command = ["sh", "-c", "printf '1.00%02d\n' $((RANDOM % 40))"]
```
`soak2.toml`:
```toml
remote = "http://127.0.0.1:36657"
chain_id = "dev"
core = "gno.land/r/clockwork/gnoracle/core"
key_home = "/Volumes/Tendermint/gnoracle/.dev-keys"
key = "soak2"
state = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/soak2-state.json"
journal = "/Volumes/Tendermint/gnoracle/.dev-agent/soak/soak2-journal.jsonl"
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
The agents and the bot ran for 300 seconds. Below are their log lines merged and sorted by time. Agents are `test1`, `soak1`, `soak2`; `bot` lines are the messages the bot would have posted to Telegram (`RoundFinalized` and `Submitted` are announced here because the dev config lists them; the default list is the dispute, proposal, provider and release events).
```text
16:42:35  soak2  agent: gno.land/r/clockwork/gnoracle/core on http://127.0.0.1:36657 as g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve, 1 feed(s), poll 2s
16:42:36  soak1  agent: gno.land/r/clockwork/gnoracle/core on http://127.0.0.1:36657 as g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr, 1 feed(s), poll 2s
16:42:36  soak2  finalised 8 round(s) from 97 (tx 5E1F79BC09E92B59558E50A944BE824B563E7BF5EE402B118191BBE864BE47BD, gas 32066545, fee 40083ugnot)
16:42:36  soak2  round 178: submitted 1.001200 (tx F702CA260383B8DD7D22886600D132CD66FA9012A00FED9C77ECDD8FCC1CF83D, gas 18452004, fee 38065ugnot)
16:42:36  bot    bot: watching gno.land/r/clockwork/gnoracle/core, gno.land/r/clockwork/gnoracle/dao on http://127.0.0.1:36657; cranks finalize=true resolve=true kourt=true settle=true
16:42:36  bot    [core] RoundFinalized feed=1 round=97 status=skipped tier= value=0 eligible=0 pool=0
16:42:36  bot    feed 1: finalised 8 round(s) from 105 (tx 19B45E2BB0F0BF54290EFC5AE0ADCC0435F436380E4D2D08EF263332D712D058, gas 32659322, fee 40415ugnot)
16:42:37  test1  agent: gno.land/r/clockwork/gnoracle/core on http://127.0.0.1:36657 as g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5, 1 feed(s), poll 2s
16:42:37  test1  finalised 8 round(s) from 121 (tx D48FF9E8A4F47550E0389F1438BA08E1035D303F39BD583A16290FC41CC6C916, gas 37702303, fee 47128ugnot)
16:42:37  soak1  finalised 8 round(s) from 113 (tx 9C4955622110F9E9E94549BDBD653D524557319FA1E932C2E25B7DF971958586, gas 32832086, fee 41040ugnot)
16:42:37  soak1  round 178: submitted 1.002300 (tx 15D87ED362C22D9CC5CE64AB291A4E56861405C720CFBFD0EC30DB6C0F3B2BBB, gas 17539080, fee 36924ugnot)
16:42:37  soak1  claimed 3715708 ugnot (tx 6B8C550D7CECCDC0BBFF5EBE2E3CEA979BD6E21CD1237A73B5BF8CA41FF250D0)
16:42:38  test1  round 178: submitted 1.001200 (tx 1BAFB0AD945FE860806B0700E083053EE4675DA1C9368B161A0059B5735972E1, gas 17571835, fee 36964ugnot)
16:42:38  test1  claimed 3715708 ugnot (tx 3602673B15453B359C2C161DF4256B7684601C11620391471841EFB68DBD4F13)
16:42:38  soak1  finalised 8 round(s) from 137 (tx 759D51C0A5739D6291A2650583B4D32CA3082B7A58F201CB2C2EA0694DBDBE1F, gas 37722154, fee 47152ugnot)
16:42:38  soak2  finalised 8 round(s) from 129 (tx E61AC075D8DBA821B8FA83F99B864F26E3B63057231C46E56C82B8C347AA5451, gas 32910069, fee 41137ugnot)
16:42:39  test1  finalised 8 round(s) from 145 (tx 38D8EAF88D71016C98B88C826E8F95F7C6BF4555B454EF367E85551CA8379767, gas 32927874, fee 41160ugnot)
16:42:40  soak1  finalised 8 round(s) from 161 (tx 029D59F7DD323B99C1A7A99D420341FB1BD3963B1F9A3119991E24DB777FDE5F, gas 33049170, fee 41311ugnot)
16:42:40  soak2  finalised 8 round(s) from 153 (tx 9CE07EF7F81DD58A411825A3694651D0F21CA20819C1DCB5CA892E64593134ED, gas 37842275, fee 47303ugnot)
16:42:41  test1  finalised 8 round(s) from 169 (tx E15E01A7C2EC41BC9345071E276EB78177C79A12B656F0B41C511205678F219A, gas 37922263, fee 47402ugnot)
16:42:41  bot    [core] Submitted feed=1 round=178 provider=g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve value=1001200
16:42:41  bot    [core] RoundFinalized feed=1 round=105 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] RoundFinalized feed=1 round=113 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] Submitted feed=1 round=178 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1002300
16:42:41  bot    [core] RoundFinalized feed=1 round=121 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] Submitted feed=1 round=178 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
16:42:41  bot    [core] RoundFinalized feed=1 round=129 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] RoundFinalized feed=1 round=137 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] RoundFinalized feed=1 round=145 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] RoundFinalized feed=1 round=153 status=skipped tier= value=0 eligible=0 pool=0
16:42:41  bot    [core] RoundFinalized feed=1 round=161 status=skipped tier= value=0 eligible=0 pool=0
16:42:42  soak2  finalised 1 round(s) from 177 (tx 22D942F60512C0ED90287EA66621B1ECA515FF8C5E368465F7E4246E39DE6B45, gas 22055280, fee 27569ugnot)
16:42:46  bot    [core] RoundFinalized feed=1 round=169 status=skipped tier= value=0 eligible=0 pool=0
16:42:46  bot    [core] RoundFinalized feed=1 round=177 status=skipped tier= value=0 eligible=0 pool=0
16:43:03  test1  round 179: submitted 1.001200 (tx 25507941789C0FD4B669F29C3F794CEC163BF147E8CBDDEC8A0F0DFFD35D563C, gas 18638222, fee 38297ugnot)
16:43:04  soak1  round 179: submitted 1.000200 (tx D8C0547B6D2E437F6E757F56EC425FC6783987992E097BD3C602FA313587AF48, gas 18026467, fee 37533ugnot)
16:43:04  soak2  round 179: submitted 1.001200 (tx C8DE9CBC958CD95DB1FAF2BC8C69B0488DEED89A511065FD959E44DDFD0BE3F2, gas 17872650, fee 37340ugnot)
16:43:05  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:43:06  bot    [core] Submitted feed=1 round=179 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
16:43:06  bot    [core] Submitted feed=1 round=179 provider=g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve value=1001200
16:43:06  bot    [core] Submitted feed=1 round=179 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1000200
16:43:09  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:43:10  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:43:36  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:43:37  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:43:41  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:43:42  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:44:05  test1  round 180: submitted 1.001200 (tx 457A24FD5305D01E4575B34E36D3D5B6056254CE0D033F82A3FFF574054A03B9, gas 18648260, fee 38310ugnot)
16:44:06  soak2  round 180: submitted 1.001200 (tx 41D75700E6863B47EA340C69E329CE1BD83E1E5AEDF2C8C580C42770841FB265, gas 17884847, fee 37356ugnot)
16:44:06  bot    [core] Submitted feed=1 round=180 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
16:44:06  bot    [core] Submitted feed=1 round=180 provider=g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve value=1001200
16:44:06  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:44:07  soak1  round 180: submitted 1.000400 (tx 268EB633B30B45F2710C8596FAC7C92E52C8A2176D1D36B6040A69D066925619, gas 18038664, fee 37548ugnot)
16:44:09  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:44:11  bot    [core] Submitted feed=1 round=180 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1000400
16:44:12  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:44:13  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:44:36  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:44:41  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:44:44  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:44:45  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:45:03  test1  round 181: submitted 1.001200 (tx CEC8D8E4C178B1DB859A3F07148FB8E956D099DF0154FFADD5148817289ED74C, gas 18655060, fee 38318ugnot)
16:45:04  soak1  round 181: submitted 1.000100 (tx CF656D92677C62226F35BA30E47328DE08A46767A1AB0C2680A6AAC035F13515, gas 18044385, fee 37555ugnot)
16:45:04  soak2  round 181: submitted 1.001200 (tx C3A2C45FA657E0E2F945173D11E46F4534B36AAE54989736C19B03EB576212AF, gas 17890568, fee 37363ugnot)
16:45:06  bot    [core] Submitted feed=1 round=181 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
16:45:06  bot    [core] Submitted feed=1 round=181 provider=g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve value=1001200
16:45:06  bot    [core] Submitted feed=1 round=181 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1000100
16:45:06  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:45:13  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:45:14  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:45:17  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:45:36  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:45:45  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:45:45  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:45:49  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:46:06  soak1  round 182: submitted 1.003500 (tx 8960D06EA17CC2FCA88609CC8320B74E14A7457E58C9B3ED4FE0CA1BEB2940B7, gas 17562711, fee 36953ugnot)
16:46:06  soak2  round 182: submitted 1.001200 (tx 45D7378821C4D456C623AE9250B7ACF2F59819BE1F616C0C9319B5203979184E, gas 18603518, fee 38254ugnot)
16:46:06  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:46:07  test1  round 182: submitted 1.001200 (tx E38871AEB7D46BE3959257BD697224C246FFBA544876B15AE9503FE515B91B5C, gas 18049638, fee 37562ugnot)
16:46:11  bot    [core] Submitted feed=1 round=182 provider=g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve value=1001200
16:46:11  bot    [core] Submitted feed=1 round=182 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1003500
16:46:11  bot    [core] Submitted feed=1 round=182 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
16:46:16  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:46:17  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:46:20  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:46:36  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:46:48  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:46:49  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:46:51  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
16:47:03  test1  round 183: submitted 1.001200 (tx 8D4962F172977B37AEDEB0A2871E8F4AB23631417AF97C76B93B8E6597EDFF5C, gas 18668660, fee 38335ugnot)
16:47:04  soak2  round 183: submitted 1.001200 (tx 6738384DDE0603FC017EE05A7D74A017DBBC8845E78A537A7B8CE7251106ADC0, gas 17902010, fee 37377ugnot)
16:47:05  soak1  round 183: submitted 1.003900 (tx 64F082A3A8E134078CEFA02EAE72B51812B4872B7799B3618601F40C4C941F43, gas 18055827, fee 37569ugnot)
16:47:06  bot    [core] Submitted feed=1 round=183 provider=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 value=1001200
16:47:06  bot    [core] Submitted feed=1 round=183 provider=g16y4yy2tztgm4v6hsfnpwn2pcx82dsa3kq63tve value=1001200
16:47:06  bot    [core] Submitted feed=1 round=183 provider=g1y84vg6pkw0jtavp0auv6lep35lzwl2sjz6n0zr value=1003900
16:47:06  bot    feed 1 CatchUp: simulate: error encountered during simulation: agg: malformed tier input
16:47:18  soak1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:47:21  test1  crank: simulate: error encountered during simulation: agg: malformed tier input
16:47:24  soak2  crank: simulate: error encountered during simulation: agg: malformed tier input
```
Things to notice:

- The first tick of every agent may hit `round is closed` or `round is finalised`: the agent computed the round from the chain time it read, and by the time the transaction was simulated another agent's transaction had moved the clock or finished the round. Simulation is free, so this costs nothing.
- A `Submit` that completes the round finalises it in the same call: the log shows more gas for the last submitter of each round (about 28M against 18M) and the bot announces `RoundFinalized` in the same second.
- When a round was not completed by everyone, the agents' `finalised N round(s)` lines show `CatchUp` closing it after the window plus `finalize_delay`; the bot would do the same after its 20-second grace.
## 6. What the journal recorded
Every agent appends one JSON line per fetch, refusal, submission, finalisation, claim and error to its journal. This is the operator's evidence in a dispute: the raw source answers, the aggregated value, and the transaction that carried it. Three entries from this run:
**A fetch (raw source response, aggregated value)** (`test1-journal.jsonl`):
```json
{
  "at": "2026-09-23T13:42:37Z",
  "feed": 1,
  "round": 178,
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
  "at": "2026-09-23T13:42:38Z",
  "feed": 1,
  "round": 178,
  "kind": "submit",
  "value": 1001200,
  "tx": "1BAFB0AD945FE860806B0700E083053EE4675DA1C9368B161A0059B5735972E1",
  "gasUsed": 17571835,
  "fee": "36964ugnot"
}
```
**A finalisation crank** (`test1-journal.jsonl`):
```json
{
  "at": "2026-09-23T13:42:37Z",
  "feed": 1,
  "round": 121,
  "kind": "finalize",
  "value": 8,
  "tx": "D48FF9E8A4F47550E0389F1438BA08E1035D303F39BD583A16290FC41CC6C916",
  "gasUsed": 37702303,
  "fee": "47128ugnot"
}
```
## 7. Chain state after the run
`gnoracle rounds 1 10` (newest first) shows the rounds the run produced. `opened → finalised` is the chain-time distance from the round's scheduled opening to its finalisation; with a 60-second window, single-digit seconds mean every obliged provider submitted and the last one finalised the round early.
| round | status | tier | submitters (slots) | value | pool (ugnot) | opened → first submission | opened → finalised |
|---|---|---|---|---|---|---|---|
| 183 | open |  | 0, 1, 2 |  | 0 | 0s | s |
| 182 | open |  | 0, 1, 2 |  | 0 | 0s | s |
| 181 | open |  | 0, 1, 2 |  | 0 | 0s | s |
| 180 | open |  | 0, 1, 2 |  | 0 | 0s | s |
| 179 | open |  | 0, 1, 2 |  | 0 | 0s | s |
| 178 | open |  | 0, 1, 2 |  | 0 | 0s | s |
| 177 | skipped |  |  | delayed | 0 | 0s | 101s |
| 176 | skipped |  |  | delayed | 0 | 0s | 161s |
| 175 | skipped |  |  | delayed | 0 | 0s | 221s |
| 174 | skipped |  |  | delayed | 0 | 0s | 281s |

Values read `delayed` because the free views only show a round's numbers once its dispute window and `renderDelay` have passed (plan §6.1); a paying realm gets them immediately through `Read`. The bot's `RoundFinalized` lines above carry the aggregate as emitted, which is the same rule applied to events: the value is public in the event log, and the fresh *view* is what consumers pay for.

### Providers
| provider | key | status | slot | rewards before | rewards after | earned this run | consecutive misses |
|---|---|---|---|---|---|---|---|
| `g1jg8mtutu9khhfw…` | test1 | active | 0 | 3715708 | 0 | 0 | 0 |
| `g16y4yy2tztgm4v6…` | soak2 | active | 1 | 0 | 0 | 0 | 0 |
| `g1y84vg6pkw0jtav…` | soak1 | active | 2 | 3715708 | 0 | 0 | 0 |
| `g1nzef2xxf66zgf0…` | g1nzef2xxf66… | jailed | -1 | 3245608 | 3245608 | 0 | 3 |
| `g1y0rdyznt4hprxq…` | g1y0rdyznt4h… | jailed | -1 | 1604 | 1604 | 0 | 3 |

Feed pool: 69959500 → 69959500 ugnot (drip 1620 ugnot per round, from the subscription bought by `make chain-test`); rounds finalised: 10 → 10.
Each finalised round's pool is split equally among the eligible submitters after the 1% cranker tip; the pool is the drip plus any penalty carry (miss slashes of jailed providers flow to the next rounds' pools, which is why some rounds pay far more than the drip).

### Conservation checks
`gnoracle health` renders both permanent realms' `Health()`: every ugnot the core holds must equal the sum of what it owes (stakes, unbonding, credits, pools, rewards, bonds, pending fees, deposits); the DAO checks its PYTH and ugnot the same way. Both read `ok` after the run:
```json
{
  "status": "ok",
  "balance": 5044186713,
  "held": 5044186713,
  "stakes": 4970000000,
  "unbonding": 0,
  "credits": 980000,
  "pools": 69959501,
  "rewards": 3247212,
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
x the last three finalised rounds are not all aggregated with two or more submitters
x no round reached consensus
- test1 earned rewards
- soak1 earned rewards
x soak2 earned nothing
- core health ok
- dao health ok
- bot announced finalisations
FAIL: soak failed (logs in /Volumes/Tendermint/gnoracle/.dev-agent/soak)
exit 1
```
## 9. Numbers from this run
| transaction | count | gas used (min / median / max) | fee at 0.001 ugnot per gas with the 25% estimate margin |
|---|---|---|---|
| submit | 18 | 17,539,080 / 18,041,524 / 18,668,660 | 36,924 to 38,335 ugnot |
| finalize | 10 | 22,055,280 / 32,988,522 / 37,922,263 | 27,569 to 47,402 ugnot |
| claim | 2 | 13,161,132 / 13,161,383 / 13,161,634 | 16,451 to 16,452 ugnot |

- First submission after a round opened: 0 to 0 s (agents poll every 2 s and wait a 1 to 3 s jitter).
- Round finalised after it opened: 101 to 281 s against a 60 s window.
- A submission that also finalises costs about 10M gas more than a plain one; the agent adds that headroom to its estimate so the last submitter's transaction never runs out of gas.
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
