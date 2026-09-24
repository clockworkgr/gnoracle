# Running a provider

A provider stakes GNOT on a feed, submits a value every round from the
sources the feed spec names, and is paid from the feed's round pool. Misses
and wrong values cost stake. This guide takes you from zero to a running
agent on one feed.

## What you need

- A gno.land account with the stake plus a gas budget. The stake floor is
  10,000 GNOT (`providerMinStakeFloor`); a feed may ask more (`providerMinStake`
  in its spec). Gas: about 0.023 GNOT per submission at the chain minimum
  price (about 0.04 GNOT for the submission that completes a round), so an
  hourly feed costs roughly 16 to 20 GNOT a month and a five-minute feed
  about 200 GNOT a month. Check the feed's subscription price and pool
  before registering; `gnoracle feed <id>` shows `pool` and `drip` (what a
  round pays, split among the providers that submitted).
- Reliable access to the sources in the spec (`gnoracle feed <id>` prints
  `spec.sources`). A price feed wants at least two independent sources.
- A machine that is up when rounds open. Submission windows are
  `spec.submitWindow` seconds after each round opens.

## 1. Install

```sh
git clone https://github.com/clockworkgr/gnoracle && cd gnoracle
make go-build                 # bin/gnoracle, bin/gnoracle-agent, bin/gnoracle-bot
export PATH=$PWD/bin:$PATH
export GNORACLE_REMOTE=https://rpc.gno.land:443 GNORACLE_CHAIN=gnoland-1
export GNORACLE_NS=g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm
gnoracle status               # chain time, live releases
```

## 2. A key for the agent

Use a dedicated key with only the stake and a gas float on it.

```sh
gnokey add provider                          # or gnokey add -recover provider
export GNORACLE_KEY_HOME=~/.config/gno GNORACLE_KEY=provider
export GNORACLE_KEY_PASSWORD='...'           # or -password-file
```

## 3. Pick a feed and register

```sh
gnoracle feeds                               # id, kind, status, providers
gnoracle feed 1                              # spec, schedule, slots, minimum stake
gnoracle register 1 10000gnot "acme ops, https://acme.example/oracle"
gnoracle provider 1 <your address>           # status active, slot, obligedFrom
```

Registration puts you in the active set at the next free slot. Your
obligations start at `obligedFrom`: the round after the current one, so you
are never penalised for a round that was already open. The realm also
rejects a submission to an earlier round (`obligations start at round N`);
the agent reads `obligedFrom` and waits for it.

## 4. Configure the agent

```sh
cp configs/agent.example.toml agent.toml
```

One `[[feeds]]` table per feed, with a `source`:

| adapter | use | key settings |
|---|---|---|
| `http` | JSON APIs; median across `urls` | `path` (e.g. `data.amount`), `min_sources`, `headers`, `scale` |
| `gnoswap` | a Gnoswap pool's tick TWAP through `OracleConsult` | `pool`, `seconds_ago`, `decimals0`, `decimals1`, `invert` |
| `qeval` | any realm view that returns an integer | `pkg_path`, `expr`, `result_decimals` |
| `exec` | your own script, stdout is the value | `command` |
| `file` | a one-off outcome you confirm by hand | `file`, `map` |

Safety settings per feed:

- `sanity_bps` (default 2000, `-1` disables): the agent refuses a value more
  than 20% away from its reference, the more recent of the feed's public
  value and its own last submission, and alerts you. Set `override = true`
  for one run when the move is real.
- `min` and `max`: absolute bounds in feed units.
- `jitter`: seconds after the round opens before fetching, to avoid every
  provider hitting a source at the same second.
- `skip_finalize`: by default the agent also finalises closed rounds and
  earns the 1% cranker tip.

Check and start:

```sh
gnoracle-agent -config agent.toml -check
gnoracle-agent -config agent.toml            # systemd, or docker with GNORACLE_MNEMONIC
```

The agent logs one line per submission with the transaction hash, gas and
fee, and appends every source response, value, refusal and transaction to
the journal (`journal.jsonl`). Keep the journal: it is your evidence if a
submission is disputed.

## 5. What happens each round

1. The round opens at `startAt + id x interval`; after `jitter` the agent
   fetches the sources and aggregates (lower median for numbers, plurality
   for options).
2. The value is checked against the bounds and the sanity band, scaled to
   the feed's decimals and submitted with `Submit(feed, round, value)`.
3. When every obliged provider has submitted, the round finalises at once;
   otherwise whoever calls `CatchUp` after the window closes finalises it.
   The feed's median becomes the round value; submissions within
   `toleranceBps` of it are eligible for an equal share of the round pool.
4. Rewards accrue to your provider record; the agent claims them weekly
   (`claim_every`) or you run `gnoracle claim <feed>`.

## 6. Penalties, in one table

| Event | Effect |
|---|---|
| Missed round on a funded feed | 0.5% of stake (capped at 5% per week); half to whoever recorded the miss, half to the next round pool |
| 3 consecutive misses | jailed: out of the set, no rewards; `gnoracle unjail <feed>` after 24 h; 3 jailings in 30 days force unbonding |
| Submission outside the tolerance band | no reward for that round and a strike; 5 strikes in 100 rounds jails |
| Lost dispute, minor | 5% of stake |
| Lost dispute, major | 100% of stake and ejection |

Disputes are decided by the DAO's commit-reveal ballot and mirrored to Kourt;
the disputer must post a bond and loses it if the round is upheld, so
frivolous disputes cost the disputer, not you.

## 7. Leaving

`gnoracle unbond <feed>` removes you from the active set from the next
round and starts the 14-day unbonding clock; `gnoracle withdraw <feed>` pays
out after it. Unbonding stake can still be slashed, for a missed round you
still owed and for a dispute on a round you submitted to, which is what
makes the dispute window meaningful. A one-off feed accepts no new
providers once its round has opened.

A retired feed unseats its providers: when the DAO deprecates a feed, or a
recurring feed goes 168 rounds (`deadFeedRounds`) without a value, every
active or jailed provider leaves the set and starts unbonding, and
`gnoracle withdraw <feed>` pays out after the same 14 days.

## 8. Checklist before going live

- [ ] two or more independent sources, or a source with a documented method
- [ ] `sanity_bps`, `min`, `max` set for the asset's real volatility
- [ ] the key holds stake plus a month of gas
- [ ] alerts wired (`[notify]` in agent.toml, or the journal shipped to your monitoring)
- [ ] `gnoracle-agent -check` passes and the first round shows in `gnoracle rounds <feed>`
