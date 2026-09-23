# Consuming a feed from a realm

A realm reads a feed with one crossing call and pays per read from a credit
balance, or reads free when a sponsor covers it. Off-chain readers use the
public JSON views, which show values once they are final and ten minutes old.

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

- `Read(cur, feedID)` returns the latest round's value and tier and debits
  the calling realm's credit by the feed's `readPrice` (half price with
  `finalOnly`, free when sponsored).
- `ReadRound(cur, feedID, roundID)` returns a specific round.
- For option feeds (`valueType = "categorical"`) the value is the option
  index; the labels are in the spec.

What the tiers mean (plan §4.3): `consensus` is a round where at least
`minProviders` agreed within tolerance; `provisional` had fewer; `final` is
either once the dispute window passed; `disputed` has an open dispute (use
the previous round or wait); `stale` means no round finalised within two
intervals.

Keep the value a single `provisional` read controls below the feed's value
at risk (half the active stake times the major-slash share, divided per
provider). For anything larger wait for `final`.

## Paying

Reads are charged to the **calling realm's address**. A realm cannot attach
coins to its own calls, so anyone funds it from an account:

```sh
gnoracle deposit 100gnot <realm address>          # DepositFor: credits the realm
gnoracle -raw call <core> WithdrawCredit 50000000 # returns unused credit to the caller's own account
```

`SetFinalOnly(true)` halves the price and serves the latest final round; the
consumer sets it on its own credit record, so a realm consumer exposes a
small owner-only function that calls `core.SetFinalOnly(cross(cur), true)`.

Metered prices are per feed (`spec.readPrice`, floor 0.002 GNOT). A realm
that reads often is cheaper on a subscription: see
[SPONSORS.md](SPONSORS.md). A sponsor names up to eight consumer addresses
whose reads on that feed are free for the sponsored period.

## Off chain

```sh
gnoracle feed 1          # spec, status, schedule; value once delayed
gnoracle round 1 current
gnoracle rounds 1 20
```

or `vm/qrender` on `<core>:json/feed/1`. Values appear once the round is
final and `renderDelay` (10 minutes) old; before that the object says
`"delayed": true`. Fresh values are for paying realms.

## Trusting a feed

Before wiring a feed into something that moves money, read its spec
(`sources`, `tolerance`, `minProviders`), its provider set (`gnoracle
providers <id>`: stake, misses, strikes) and its dispute history (`gnoracle
disputes`). Anyone with a bond can dispute a round within the feed's dispute
window; the DAO votes; verdicts are mirrored to Kourt.
