# Sponsoring a feed

A sponsor pays a feed's subscription so it stays funded. Subscriptions are
the protocol's revenue: 70% goes to the feed's round pools (the providers),
15% to DAO stakers, 15% to the treasury.

## Why sponsor

- The feed keeps providers: a feed whose pool is empty is `unfunded`,
  providers are not paid, and after enough empty rounds it is deprecated.
- Several sponsors can pay for the same feed; each payment extends the
  feed's coverage and adds to its pool.
- The realms that depend on the feed keep their source. A sponsor who also
  runs a consumer realm subscribes it separately ([CONSUMERS.md](CONSUMERS.md)),
  or asks the requester to mark the feed `sponsored`, which makes it free
  for every realm.

## How

```sh
gnoracle feed 1                          # spec.subscriptionPrice per 30-day period, paidUntil, pool
gnoracle sponsor 1 3 3000gnot
#                 ^feed ^periods        ^periods x subscriptionPrice
```

`paidUntil` moves forward by the periods bought (1 to 12 at a time) and 70%
of the payment joins the pool. The drip per round is fixed from the spec's
`subscriptionPrice` (recomputed only when a `feed-update` changes it), so a
bigger pool lasts longer rather than paying more per round. Renew before
`paidUntil`; the bot posts `FeedUnfunded` when a pool runs dry.

To fund a one-off outcome instead of a recurring feed, top up its bounty:
`gnoracle call <core> FundBounty <feed>` with `-send`.

## Proposing a feed that does not exist yet

See [REQUESTERS.md](REQUESTERS.md): anyone may propose a spec with a 5 GNOT
deposit; the DAO accepts it by vote; the deposit is refunded on activation.
Sponsoring your own request is the normal path for a business that needs a
feed.
