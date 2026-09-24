# Being a DAO member

DAO members stake PYTH. Staking earns 15% of every subscription payment
and a share of dispute rewards; it also obliges you to vote on every dispute.
Missing a ballot or voting against the outcome costs a small slice of stake
(UMA-style), so read this before staking.

## Stake

```sh
gnoracle status                                  # DAO totals, epoch
gnoracle stake 1000                              # approves the DAO on the token, then stakes 1,000 PYTH ("1000000000u" for base units)
gnoracle member <your address>                   # staked, power, feesOwed, cursor
```

Voting power is your stake checkpointed at the start of the next epoch (720
blocks, fixed), so stake before a dispute you want to vote on, not after.
`gnoracle unstake <pyth>` starts the 7-day cooldown; `gnoracle dao-withdraw`
pays out after it. A partial unstake must leave at least 1 PYTH
(`minStake`) staked, and a second unstake waits until the first is
withdrawn. Staking again after penalties or a full unstake must bring the
stake to at least `minStake`.
Founder allocations carry a vesting floor set only by a `vesting`
proposal; the floor cannot be unstaked before its date.

## Fees and rewards

`gnoracle dao-claim` pays your fee share (ugnot) and any dispute rewards
(ugnot and PYTH). The accumulator credits fees continuously; nothing is
lost by claiming rarely.

## Disputes: commit, then reveal

Every dispute opens a ballot for all stakers: 24 h commit, 24 h reveal.
The bot announces each one with its deadlines and reminds opted-in members
24 h and 2 h before each phase closes.

```sh
gnoracle dispute 7                               # the round, the disputer's claim, the evidence hash
gnoracle round <feed> <round>                    # what was submitted, or read the page
gnoracle ballot 7                                # phase, deadlines, weights so far
gnoracle commit 7 UPHOLD                         # during the commit phase
gnoracle reveal 7                                # during the reveal phase
```

`commit` picks a random salt, computes the commitment, saves both under
`~/.gnoracle/votes/<chain>-<dispute>-<round>.json`, then sends
`CommitVote`. `reveal` reads that file and sends `RevealVote`. Keep the
file until the reveal is on chain; if you vote from several machines, copy
it. Running `commit` again with another choice during the commit phase
replaces the commitment on chain and the saved salt (only once the
transaction committed).

Choices:

| choice | meaning |
|---|---|
| `UPHOLD` | the round's value stands; the disputer loses the bond |
| `OVERTURN` | the round is wrong; providers are slashed at the tier the disputer asked (major ejects) |
| `OVERTURN_MINOR` | wrong, but only the minor tier (5%) is warranted |
| `VOID` | the round cannot be judged (ambiguous spec, missing data); the round is voided, 5% of the bond consumed |
| `ABSTAIN` | counted for quorum, no position; 0.05% penalty instead of 0.5% |

The decision needs 33% of obligated weight revealed and 60% of the weight
on the two sides (UPHOLD against OVERTURN and OVERTURN_MINOR together; VOID
and ABSTAIN count for quorum, not for this bar) behind one side; VOID wins
instead when it holds a strict majority of the revealed weight other than
ABSTAIN. Otherwise the ballot rolls to a 48 h + 24 h second round with 25%
and 55%; a second round that decides nothing voids the dispute. The
heaviest voters are clipped at 20% of obligated weight when deciding, so no
single staker decides alone. A decided round can be appealed within 24 h
for twice the bond; the appeal round is final. An appealed first round
settles like a rolled one: no rewards and no incoherence penalty, only the
absence and abstention penalties, which go to the treasury.

## Penalties

| event | penalty | cap |
|---|---|---|
| no commit or no reveal | 0.5% of stake | 5% per 30 days |
| revealed against the outcome | 0.5% | (same cap) |
| abstain | 0.05% | |

Penalties are applied lazily: `gnoracle settle` (or the bot, for opted-in
members) walks your resolved ballots once the core has applied each
outcome and applies penalties and rewards. Staking and unstaking are not
blocked by a running ballot; withdrawing unbonded stake waits until every
ballot you hold weight in is final, which includes a ballot that has
resolved but whose outcome the core has not applied yet.
Coherent voters share, by revealed weight, the voters' 30% of forfeited
bonds and slashes (ugnot) and the PYTH penalties of the members who were
absent or voted against the outcome. The 30-day cap window is keyed to
when each ballot resolved, not to when you settle; once a member hits the
cap, `PenaltyCapped` is emitted and no more is taken that window.

## Proposals

```sh
gnoracle proposal 3
gnoracle vote 3 yes
gnoracle execute 3                               # after the timelock, anyone
gnoracle propose param "core.subscriberFloor=3000" "Raise the subscriber floor" 20gnot
```

A parameter moves at most 50% per change (`subscriberFloor`, 2000 ugnot by
default, can go to 3000 at most in one proposal); the payload is checked
against the bounds when the proposal is made.

Kinds: `feed-accept`, `feed-update`, `feed-deprecate`, `provider-remove`,
`param`, `treasury`, `mint`, `upgrade-accept`, `upgrade-rollback`, `freeze`,
`authority-transfer`, `authority-execute`, `authority-cancel` (each of the
last six names `core`, `dao` or `kourt`), `trusted-requester`, `vesting`
(`<member> <until> <floor>`), `kourt-abandon` (`<dispute> <reason>`, the
reason is required), `kourt-redeem` (`<amount>` of the mirror's court coin
back to GNOT for the treasury), `kourt-attribution` (`<text>`, the Kourt
attribution notice), `text`. An authority transfer executes in a second
proposal after the realm's seven-day delay: `authority-execute <core|dao|kourt>
<spec>`, where the spec must equal the transfer pending on that realm when
the proposal is made and when it executes. Each kind has its own quorum,
threshold, voting period and timelock (plan §8.3); a proposal carries when
strictly more than the bar votes yes. To open one you hold 0.25% of the
staked supply or attach a 20 GNOT deposit, refunded when the vote reaches
quorum and forfeited to the treasury when it does not. A proposer who
cancels a proposal (`Cancel`, before voting ends) forfeits the deposit to
the treasury as well.

## Reminders and settlement by the bot

Send `/start` to the community bot and give the operator your Telegram user
id and address; you will get direct reminders and, if you opt in, the bot
settles your ballots for you (it pays the gas; settlement is permissionless
and changes nothing you could avoid).
