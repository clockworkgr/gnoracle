# Being a DAO member

DAO members stake PYTH. Staking earns 15% of every subscription and read fee
and a share of dispute rewards; it also obliges you to vote on every dispute.
Missing a ballot or voting against the outcome costs a small slice of stake
(UMA-style), so read this before staking.

## Stake

```sh
gnoracle status                                  # DAO totals, epoch
gnoracle stake 1000                              # 1,000 PYTH (6 decimals; "1000000000u" for base units)
gnoracle member <your address>                   # staked, power, feesOwed, cursor
```

Voting power is your stake checkpointed at the start of the next epoch (720
blocks), so stake before a dispute you want to vote on, not after.
`gnoracle unstake <pyth>` starts the 7-day cooldown; `gnoracle dao-withdraw`
pays out after it. Founder allocations carry a vesting floor.

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
gnoracle round <feed> <round>                    # what was submitted (once delayed), or read the page
gnoracle ballot 7                                # phase, deadlines, weights so far
gnoracle commit 7 UPHOLD                         # during the commit phase
gnoracle reveal 7                                # during the reveal phase
```

`commit` picks a random salt, computes the commitment, saves both under
`~/.gnoracle/votes/<chain>-<dispute>-<round>.json`, then sends
`CommitVote`. `reveal` reads that file and sends `RevealVote`. Keep the
file until the reveal is on chain; if you vote from several machines, copy
it. A commitment cannot be changed once sent.

Choices:

| choice | meaning |
|---|---|
| `UPHOLD` | the round's value stands; the disputer loses the bond |
| `OVERTURN` | the round is wrong; providers are slashed at the tier the disputer asked (major ejects) |
| `OVERTURN_MINOR` | wrong, but only the minor tier (5%) is warranted |
| `VOID` | the round cannot be judged (ambiguous spec, missing data); the round is voided, 5% of the bond consumed |
| `ABSTAIN` | counted for quorum, no position; 0.05% penalty instead of 0.5% |

The decision needs 33% of obligated weight revealed and 60% of the revealed
weight behind one choice; otherwise the ballot rolls to a 48 h + 24 h second
round with 25% and 55%. The heaviest voters are clipped at 20% of obligated
weight when deciding, so no single staker decides alone. A decided round
can be appealed within 24 h for twice the bond; the appeal round is final.

## Penalties

| event | penalty | cap |
|---|---|---|
| no commit or no reveal | 0.5% of stake | 5% per 30 days |
| revealed against the outcome | 0.5% | (same cap) |
| abstain | 0.05% | |

Penalties are applied lazily: `gnoracle settle` (or the bot, for opted-in
members) walks your resolved ballots and applies penalties and rewards.
Coherent voters share 30% of forfeited bonds and slashes plus the DAO's
voter fund. Once a member hits the 30-day cap, `PenaltyCapped` is emitted
and no more is taken that window.

## Proposals

```sh
gnoracle proposal 3
gnoracle vote 3 yes
gnoracle execute 3                               # after the timelock, anyone
gnoracle propose param "core.readPriceFloor=3000" "Raise the read floor" 20gnot
```

Kinds: `feed-accept`, `feed-update`, `feed-deprecate`, `provider-remove`,
`param`, `treasury`, `mint`, `upgrade-accept`, `upgrade-rollback`,
`upgrade-freeze`, `authority-transfer`, `trusted-requester`, `text`. Each
has its own quorum, threshold, voting period and timelock (plan §8.4). A
proposal needs 0.25% of staked power to open and a 20 GNOT deposit that is
refunded unless the proposal is marked as spam.

## Reminders and settlement by the bot

Send `/start` to the community bot and give the operator your Telegram user
id and address; you will get direct reminders and, if you opt in, the bot
settles your ballots for you (it pays the gas; settlement is permissionless
and changes nothing you could avoid).
