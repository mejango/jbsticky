# Tenure rewards — funder-chosen reward groups on the Sticky distributor

**Date:** 2026-09-24
**Status:** Implemented on `fix/audit-hardening-and-review-docs` (mejango/sticky#2)
**Supersedes:** `2026-08-12-sticky-distributor-design.md`, `2026-08-13-criteria-window-generalization.md`, and
`2026-08-14-criteria-carrier-projectid.md` (the PR #1 design). The encoding and the split carrier survive; the
contract shape, the snapshot epoch, the denominator, tranche merging, and the receiver and adapter surfaces are
decided here.

## Decisions

| Axis | Decision |
| --- | --- |
| Contract shape | `StickyDistributor` subclasses the stock `JBDistributor` and replaces `JBTokenDistributor` in the deployment. Group 0 is byte-for-byte the token distributor's behaviour (`getPastVotes` / `getPastTotalActiveVotes`). Loans are disabled (`REV_LOANS`, `REV_OWNER` = 0). Runtime is 20,515 bytes, 4,061 under EIP-170, so no loan-free fork was needed. |
| Group encoding | `groupId = minWeeks * 1000 + maxWeeks`; `maxWeeks == 0` means no upper bound; both at most 520; `minWeeks` at least 1 for non-zero groups. `isValidGroupId` is a public pure view. Same encoding as PR #1's final head. |
| Snapshot epoch | Pinned at **round start**: `snapshotEpochOf(round) = roundStartTimestamp(round) / 1 weeks`. Window top `hi = E − minWeeks`, bottom `lo = E − maxWeeks` (bounded windows only). No new round-struct fields; the stock `JBRewardRoundData` is reused. |
| Same-week merge | `_addTo` extends the newest active tranche when it was created in the current week and moves its timestamp to `block.timestamp`; otherwise it appends. Applies to pays, incoming transfers, and granter stakes. A merged tranche never overstates the age of its newest tokens. |
| Split fallback | An invalid `split.projectId`, or a beneficiary the hook does not track, funds group 0 without reverting. Direct `fund(hook, token, amount, groupId)` reverts on an invalid group (`StickyDistributor_InvalidGroupId`) or, for tenure groups, an unregistered token (`StickyDistributor_UnregisteredStickyToken`, checked as `STICKY_HOOK.tokenOf(IStickyToken(hook).PROJECT_ID()) == hook` through a low-level staticcall so a non-Sticky beneficiary cannot revert a split). |
| Claim window | `CLAIM_DURATION` is two years (was three) in the production deployment. |
| Denominator | No `totalStakedOf` storage. Tenure (`maxWeeks == 0`): the registered token's `totalSupply()` minus `netStakedWithin(p, hi + 1, currentEpoch)`. Bounded window: `netStakedWithin(p, lo, hi)`. Both walks are capped by `MAX_CRITERIA_WEEKS` plus the weeks elapsed since the round started. |
| AutoStick | `beginVestingFor`, `compoundFor`, `stickRewardsFor`, and `statusOf` take `uint256[] calldata groupIds`; the holder's minimum applies to the combined total; one balance delta is measured around the whole collect loop; an empty list reverts `StickyAutoStick_EmptyGroupIds(count)`. `AutoStuck` and `BeganAutoStickVesting` carry `groupIds`. |
| Receivers | One receiver per `(stickyToken, groupId)` with immutables `DISTRIBUTOR`, `GROUP_ID`, `STICKY_TOKEN`. Factory salt `keccak256(abi.encode(stickyToken, groupId))`; `deployReceiverFor`, `predictReceiverOf`, `receiverOf`, and `settleFor` take `groupId`; invalid groups revert `StickyRewardReceiverFactory_InvalidGroupId(groupId)` via `DISTRIBUTOR.isValidGroupId`; events carry `groupId`. |
| Deployment | `StickyDistributor(controller, directory, hook, 7 days, 4, uint48(2 * 365 days))`; nine compiler immutables; `_verifyDistributor` checks `STICKY_HOOK == hook` and `EPOCH_DURATION == hook.EPOCH_DURATION()`. |

## Hook mechanism

`StickyHook.EPOCH_DURATION = 1 weeks`. `netStakedIn[projectId][epoch]` is credited in `_addTo` and debited in
`_consumeFrom` at each removed tranche's original epoch: a partial exit subtracts the trimmed part from the retained
tranche's epoch and the full amount of every newer tranche from its own epoch; a full exit loops over every active
tranche. Because active tranches sit in distinct weeks, the loop runs once per week the exit consumes. Measured
cold: about 98,000 gas for a full exit after 1,000 same-week dust transfers (one merged tranche), and about 3.3M gas
for a full exit across 520 weekly tranches, roughly 6,300 gas per distinct week. This keeps audit fix C-01
(unbounded dust exits) in a weaker form: dust cannot multiply the work, but distinct weeks do.

Views: `netStakedWithin(projectId, fromEpoch, toEpoch)` sums a bucket range and reverts
`StickyHook_InvalidEpochRange(fromEpoch, toEpoch)` when inverted; `stakedBalanceThroughEpochOf(projectId, holder,
epoch)` binary-searches the holder's active tranches (timestamps never decrease with index) and returns the
cumulative endpoint of the newest tranche created through that epoch. Pricing, orphaned-backing, and streak logic
are untouched.

## Solvency argument

Tranches only ever join the current week (`_addTo` uses `block.timestamp`), and `minWeeks >= 1` keeps a round's
own start week out of its window, so every bucket a window reads is frozen against additions from the moment the
round starts. The denominator recorded at first funding is therefore an upper bound on any later live reading.
Exits consume newest tranches first and debit only the exiting holder's own tranches, so a holder's live in-window
stake at claim time is at most what the denominator counted for them. Each claim is additionally capped at the pot's
remaining balance. The invariant campaign checks the pinned denominator against a brute-force sum of every actor's
in-window tranches in the same transaction, live window sums against the recorded denominator afterwards, per-actor
entitlements against an independent computation, bucket conservation against staked balances and supply, and pot
solvency and custody isolation across two hooks.

The only path to a denominator that overstates supply is a read between the terminal's mint and the hook's
after-pay callback, which needs an underlying token with transfer callbacks; Sticky does not support such tokens.
Its effect would be a lower per-holder payout with the remainder recycling after the claim window, never an
overpayment.

## Semantics worth stating

- Tenure is whole-week granular and measured from the round's start week, not from funding time. A round that
  starts mid-week still pins to that week.
- Holders must still hold the qualifying tranches when they claim. Exiting first forfeits the allocation to the
  pot, which recycles after `CLAIM_DURATION`.
- Bounded windows pay deposits, not people. LIFO erodes recency eligibility first and tenure eligibility last.
- A same-week top-up merges into the newest tranche and takes the latest timestamp, so it can only delay that
  tranche's eligibility within the week, never advance it.

## Deviations from the brief

- `IStickyDistributor` extends `IJBTokenDistributor` rather than redeclaring `DIRECTORY` and `IJBSplitHook`; the
  contract also reports the token-distributor interface ID because group 0 is that distributor.
- `IStickyToken` declares `HOOK`, `PROJECT_ID`, `SOULBOUND`, and `TOKENS` so the price feed, which also exposes
  `PROJECT_ID`, does not accidentally match it.
- The registration check on direct funding applies to tenure groups only; `fund(hook, token, amount, 0)` behaves
  exactly like the three-argument overload so group 0 stays the stock path.
- The receiver factory validates the group in `predictReceiverOf` as well as `deployReceiverFor`, so no address is
  ever predicted for a group that could not settle.
