# Consuming a feed from a realm

A realm reads a feed with one crossing call. The call changes nothing and
costs nothing per read; what the core checks is that the calling realm is
allowed to use the feed on chain: it holds a subscription that covers now,
or the feed is sponsored, or it is a one-off outcome (public once final), or
the realm is the feed's own requester. Off-chain readers use the public
pages and JSON views, which show every value the moment it exists.

## From a realm

```go
import oracle "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/gnoracle/core"

func Settle(cur realm) {
	value, decimals, round, updatedAt, tier := oracle.Read(cross(cur), feedID)
	// value is an integer scaled by decimals: 1234567 with 6 decimals is 1.234567
	// tier: consensus | provisional | final | disputed | stale | none, with ",unfunded" appended when the feed's pool is empty
	if tier != "final" && tier != "consensus" {
		panic("no usable value")
	}
	...
}
```

- `Read(cur, feedID)` returns the latest round's value and tier.
- `ReadFinal(cur, feedID)` returns the last final round, whatever later
  rounds are doing (the conservative choice for anything that moves money).
- `ReadRound(cur, feedID, roundID)` returns a specific round.
- For option feeds (`valueType = "categorical"`) the value is the option
  index; the labels are in the spec.

Read at the moment you need the number, inside the transaction that uses
it: that value is never stale. A realm that polls on a schedule and caches
is as fresh as its last poll (the demo's reader realm does that to show a
history).

What the tiers mean (plan §4.3): `consensus` is a round where at least
`minProviders` agreed within tolerance and the value stayed within the
quarantine band of the last final value; `provisional` had fewer or moved
more; `final` is either once the dispute window passed; `disputed` means the
latest round is under dispute, and the value returned with it is the last
final round's, not the disputed one (zero and round 0 when no final round
exists yet); a voided latest round also falls back to the last final one;
`stale` means no round finalised within two intervals.

Keep the value a single `provisional` read controls below the feed's value
at risk (half the active stake times the major-slash share, divided per
provider). For anything larger use `ReadFinal`.

## Subscribing

A subscription names the reading realm by its package path and is paid per
30-day period, 1 to 12 at a time, by anyone:

```sh
gnoracle feed 1                                      # spec.subscriberPrice per period, subscribers
gnoracle subscribe 1 gno.land/r/you/app 3 30gnot     # SubscribeRealm: 3 periods x subscriberPrice
gnoracle subscription 1 gno.land/r/you/app           # paidUntil, active
gnoracle subscribers 1
```

Paying again extends the same subscription from its current end. The price
is per feed (`spec.subscriberPrice`, above the DAO's `subscriberFloor`);
70% of it joins the feed's pool for the providers, 15% goes to DAO stakers
and 15% to the treasury. Sponsored feeds (`spec.sponsored`) and one-off
outcomes take no subscription: every realm may read them.

A realm can also pay for itself from a prepaid balance its operator funds
with `gnoracle deposit <amount> <realm address>`; the same balance pays a
realm's feed requests and bounties, and receives its refunds. Reads never
touch it.

## Off chain

```sh
gnoracle feed 1          # spec, status, schedule, the latest value
gnoracle round 1 current
gnoracle rounds 1 20
```

or `vm/qrender` on `<core>:json/feed/1`. Everything the chain holds is
public and shows at once; a subscription buys a realm the right to use a
value in its own logic, not secrecy.

## Trusting a feed

Before wiring a feed into something that moves money, read its spec
(`sources`, `tolerance`, `minProviders`), its provider set (`gnoracle
providers <id>`: stake, misses, strikes) and its dispute history (`gnoracle
disputes`). Anyone with a bond can dispute a round within the feed's dispute
window; the DAO votes; verdicts are mirrored to Kourt.
