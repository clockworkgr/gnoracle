# Requesting a feed

Anyone can ask the oracle for a value: a recurring price, a one-off outcome,
a categorical result. You write a spec, post a deposit, and the DAO accepts
or rejects it. Allowlisted realms (gnomarket) activate small one-off
requests themselves.

## The spec

```json
{
  "name": "GNOT/USD",
  "description": "Spot price of GNOT in USD.",
  "kind": "recurring",
  "valueType": "numeric",
  "decimals": 6,
  "interval": 3600,
  "submitWindow": 600,
  "sources": "Median of Gnoswap GNOT/USDC TWAP (30 min) and any two of Coinbase, Kraken, Binance spot at round start. Round start is the Unix time floor to the hour.",
  "minProviders": 3,
  "maxProviders": 7,
  "providerMinStake": 10000000000,
  "toleranceBps": 100,
  "quarantineBps": 1000,
  "disputeWindow": 43200,
  "readPrice": 20000,
  "subscriptionPrice": 1000000000,
  "tags": ["price", "gnot"]
}
```

One-off:

```json
{
  "name": "Match 2026-10-04 Home vs Away",
  "kind": "one-off",
  "valueType": "categorical",
  "options": ["Home", "Draw", "Away", "Abandoned"],
  "resolveAt": 1791158400,
  "submitWindow": 7200,
  "bounty": 50000000,
  "sources": "Official result on the league's site; Abandoned if not played within 48h.",
  "minProviders": 2,
  "maxProviders": 5,
  "providerMinStake": 10000000000,
  "disputeWindow": 86400,
  "valueAtStake": 20000000
}
```

Fields and bounds are validated on chain by `p/.../gnoracle/spec` (interval
60 s to 30 d, window 60 s to the interval, at most 16 options, sources up
to 2,000 bytes, floors for stake, prices and bounties from the core
parameters). `sources` is the contract with providers: say exactly where
the value comes from and how ties, outages and edge cases resolve. Vague
sources produce disputes.

## Proposing

```sh
gnoracle propose-feed spec.json 5gnot            # ProposeFeed with the deposit
gnoracle feed <id>                               # status proposed
```

A DAO member then opens a `feed-accept` proposal (`gnoracle propose
feed-accept <id> "Accept GNOT/USD" 20gnot`); members vote; on execution the
feed activates at the next interval boundary and the deposit is refunded.
Rejections refund too unless the proposal marks the spec as spam. A realm
that proposes gets its refund as read credit, since realms cannot receive
coins from calls.

Trusted requesters (allowlisted realm paths with a cap set by the DAO,
`trusted-requester` proposal kind) activate one-off feeds themselves when the
declared `valueAtStake` is under the cap; gnomarket's outcome requests use
this path.

## After activation

Providers register when the economics make sense: `subscriptionPrice` (or
the one-off `bounty`) has to cover their gas and stake risk. Sponsor the
feed ([SPONSORS.md](SPONSORS.md)) or fund the bounty, and tell the provider
community. `gnoracle feed <id>` shows `activeCount` against `maxProviders`;
`gnoracle rounds <id>` shows values arriving.

Changing a live spec (`feed-update` proposal) is limited to the fields that
do not change the meaning of past rounds: prices, provider counts, tolerance,
window, description, tags.
