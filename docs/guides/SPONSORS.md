# Sponsoring a feed

A sponsor pays a feed's subscription so it stays funded, and names the
consumer realms whose reads are free. Subscriptions are the protocol's main
revenue: 70% goes to the feed's round pools (the providers), 15% to DAO
stakers, 15% to the treasury.

## Why sponsor

- Your consumer realms read without per-read charges.
- The feed keeps providers: a feed whose pool is empty is `unfunded`,
  providers are not paid, and after enough empty rounds it is deprecated.
- Several sponsors can share a feed; each period's cost is split among that
  period's sponsors and any surplus rolls forward.

## How

```sh
gnoracle feed 1                          # spec.subscriptionPrice per 30-day period, paidUntil, pool
gnoracle sponsor 1 3 g1consumerA...,g1consumerB... 3000gnot
#                 ^feed ^periods ^up to 8 consumer addresses  ^periods x subscriptionPrice
```

`paidUntil` moves forward by the periods bought; the drip per round is
recomputed from the pool. Renew before `paidUntil`; the bot posts
`FeedUnfunded` when a pool runs dry.

To fund a one-off outcome instead of a recurring feed, top up its bounty:
`gnoracle call <core> FundBounty <feed>` with `-send`.

## Proposing a feed that does not exist yet

See [REQUESTERS.md](REQUESTERS.md): anyone may propose a spec with a 5 GNOT
deposit; the DAO accepts it by vote; the deposit is refunded on activation.
Sponsoring your own request is the normal path for a business that needs a
feed.
