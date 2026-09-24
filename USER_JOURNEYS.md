# User Journeys

## Repo Purpose

This repo owns staking-with-streaks for ERC-20 tokens on Juicebox V6: permanently configured staking projects, backing-priced Sticky shares that are soulbound or transferable, per-deposit tranche accounting, holder streaks, opt-in reward compounding, cross-chain reward receivers, and the Sticky webclient. Juicebox core handles custody, issuance math, and cash out economics; `JBStickyDistributor` handles rewards, by vote snapshot or by tenure. Start here if you're integrating staking into a client, designing a reward program on streak data, or launching a sticky project for a token. See [the webclient guide](webclient/README.md) for site configuration and production checks.

## Primary Actors

- **Community operator** (e.g. Artizen): launches a sticky project for their token and designs reward programs on the resulting data.
- **Holder**: stakes to signal commitment, redeems under the project's fixed cash out curve, tracks their streak, and optionally compounds rewards.
- **Granter** (protocol or partner): stakes on holders' behalf as rewards, frictionlessly.
- **Funder**: sends reward tokens to a sticky token's holders, on the same chain or from another chain.
- **Indexer / reward engine**: consumes events and views to compute reward math off-chain.

## Key Surfaces

- `JBStickyDeployer.deployStickyFor`: launch a locked sticky project for a token.
- `JBMultiTerminal.pay` and `previewPayFor` (core): stake and quote.
- `JBMultiTerminal.cashOutTokensOf` (core): unstake.
- `JBStickyHook` views/events: all balance, streak, tranche, and trust data.
- `JBStickyDistributor.fund` / `collectVestedRewards` (with an optional `groupId`), `JBStickyAutoStick`, `JBStickyRewardReceiverFactory`: rewards.

## Journey 1: Launch a sticky project

**Actor:** community operator.

**Intent:** make their token stakeable under permanent, reviewed withdrawal and transfer rules.

Call `deployStickyFor(stakedToken, name, symbol, projectUri, cashOutTaxRate, granters, soulbound)` with `msg.value` equal to `JBProjects.creationFee()`. The token, tax rate, launch-time granters, and transfer mode are permanent; review them before sending. A maximum tax rate means cash outs return no underlying tokens. Other redemptions depend on the curve and applicable terminal fees. Failure modes include an incorrect creation fee, an out-of-range tax rate, unsupported token decimals, and a zero currency ID derived from the token address. The call returns `projectId`; the confirmed `DeploySticky` event identifies the share token. Names and symbols are permissionless, so identify a project by its chain, deployer, underlying token, and emitted addresses.

## Journey 2: Stake

**Actor:** holder.

**Intent:** lock tokens to start or grow a commitment streak.

Quote first: call `previewPayFor` with the actual payer, amount, and beneficiary. Its beneficiary token count uses `floor(amount × supply / share-owned backing)` for an existing supply. The first deposit into an empty project starts at one share per whole token, normalized to 18 decimals, and must issue at least `1e12` share atoms. A zero preview means the amount cannot be issued within the pricing guard; a larger amount may work, but deposit availability is not guaranteed when backing per share atom is very large. Approve the terminal for the intended amount, then call `pay` with the previewed share count as `minReturnedTokens`. A state change that reduces issuance below that minimum reverts the payment. The first positive balance starts the holder's streak; later stakes add tranches with their own timestamps and never move an existing streak's start.

## Journey 3: Unstake

**Actor:** holder.

**Intent:** recover staked tokens, keeping as much duration credit as possible.

Call `cashOutTokensOf(holder: self, projectId, cashOutCount, tokenToReclaim: stakedToken, minTokensReclaimed, beneficiary, metadata)` with `cashOutCount` in 18 decimals. Use `previewCashOutFrom` for the gross reclaim, then account for the actual beneficiary's terminal fee treatment to derive the net quote. A feeless beneficiary is exempt; otherwise non-zero tax makes the whole reclaim fee-eligible, while zero tax only charges against the project's fee-free surplus balance. Set `minTokensReclaimed` from the net quote. A failed fee route restores the withheld fee to project backing; it does not increase the holder's payout.

Zero tax gives a proportional gross reclaim. Positive tax below the maximum reduces partial exits according to the Juicebox curve; redeeming the whole supply recovers all share-owned backing before fees. Maximum tax returns zero for every exit. Shares held by someone else do not impose a minimum position the holder must retain. Tranches are consumed newest-first. A partial unstake preserves the holder's streak and the remaining tranches' timestamps; a full holder exit ends the streak and updates `longestStreakOf`.

## Journey 4: Grant staked tokens to a streaker

**Actor:** granter.

**Intent:** reward a holder with pre-staked tokens, no action required from them.

Pay the sticky project with `beneficiary` set to the holder. The payer must be one of the project's launch-time granters or a sender the holder has trusted via `setTrustedSenderFor`; otherwise the pay reverts with `JBStickyHook_SenderNotTrusted`. The grant is priced like any deposit and lands as a new tranche with its own timestamp: the holder's streak is neither broken nor backdated, and amount-weighted math can't be laundered through an old streak.

## Journey 5: Reward holders

**Actor:** funder.

**Intent:** distribute a reward token pro rata to a sticky token's holders, by ownership or by tenure.

Choose the group first. Group 0 rewards ownership at the round's snapshot block. A tenure group `minWeeks * 1000 + maxWeeks` rewards stake held in tranches created between `maxWeeks` and `minWeeks` weeks before the round started: `4000` for four-plus weeks, `1004` for the last four completed weeks, `4008` for four to eight weeks. `isValidGroupId` accepts `minWeeks` in 1–520 and `maxWeeks` 0 or in `minWeeks`–520. Bounded windows pay deposits, not people; recency windows are open to anyone who stakes before the round starts.

Same chain: approve the distributor and call `fund(hook: stickyToken, token: rewardToken, amount, groupId)`. For group 0, inspect `roundSnapshotBlock(round)` first; positive funding and settlement pin the current round if unset, `poke()` can also pin the next round, snapshots are shared across projects, and a one-block position followed by `poke()` can capture both rounds. For a tenure group, inspect `snapshotEpochOf(currentRound())` and `STICKY_HOOK.netStakedWithin(projectId, from, to)` over the window to see the denominator the first funding will record; nothing staked after the round started can enter it, and funding later in the round does not move it. A tenure funding for a token the hook does not track reverts.

Through a split: set `hook = distributor`, `beneficiary = stickyToken`, and `projectId = groupId` on the payout or reserved-token split. Core never reads `projectId` while the hook is set, so the split can also be locked. An invalid group or untracked beneficiary funds group 0 instead of reverting.

Rewards vest over four weekly rounds and have a two-year claim window before unclaimed inventory can be recycled. Vesting needs a transaction: call `beginVesting(hook, groupId, tokenIds, tokens)`, or use `collectVestedRewards(hook, groupId, ...)` to collect vested rewards and begin eligible allocations. Tenure claims read the holder's live tranches, so they must be claimed while those tranches are still held; an exit first forfeits them to the pot. Anyone may collect on a holder's behalf to that holder's address. A holder calling directly may choose their own beneficiary. Auto-stick always collects to the holder.

Other chain: call `JBStickyRewardReceiverFactory.predictReceiverOf(destinationStickyToken, groupId)` on the destination chain. Address parity across chains requires matching factory and distributor addresses, creation code, destination Sticky-token address, and group; common salts alone are insufficient. Verify the destination reward token and its supported bridge route, then bridge with that receiver as beneficiary. Once the ERC-20 arrival is claimable on the destination, complete the bridge claim and call `settleFor(destinationStickyToken, groupId, destinationRewardToken)`. The receiver can receive tokens before deployment. Anyone may settle, so funding belongs to the round current when settlement executes. The Sticky project needs no sucker deployment of its own; the reward token needs the route. Receivers provide no recovery path for an incorrect destination or unsupported asset.

## Journey 6: Compound rewards

**Actor:** holder.

**Intent:** turn vested underlying-token rewards back into the position without extra steps.

One-time compound: trust the adapter through `setTrustedSenderFor` unless the project listed it as a granter at launch, approve it for the collectable underlying amount, and call `JBStickyAutoStick.stickRewardsFor(projectId, groupIds)` with the reward groups to collect from (`[0]` for ownership rewards, more for tenure pots). These may require separate wallet transactions. The adapter collects each group's vested rewards to the holder, pulls exactly the total delivered amount, quotes the terminal, and pays the project with the holder as beneficiary and the quoted share minimum.

Keeper mode: `setConfigFor(projectId, enabled: true, minimumAmount, cooldown)` with a positive minimum and a cooldown between one and thirty days. Anyone can call `beginVestingFor(projectId, holder, groupIds)` for an enabled holder, and `compoundFor(projectId, holder, groupIds)` once the combined reward across those groups, cooldown, allowance, and trust conditions pass; `statusOf(projectId, holder, groupIds)` previews the same ladder. An empty group list reverts. A keeper chooses which enabled position and groups to process; it cannot redirect that position's token, beneficiary, or destination. Keeper availability is separate from permissionless execution. Compounding is best effort: if someone collected to the holder first, the tokens stay in the holder's wallet and can be staked manually. Disabling the configuration stops keeper compounding; allowance revocation is a separate wallet action.

## Journey 7: Build a reward program on streak data

**Actor:** indexer / reward engine.

**Intent:** compute duration- and amount-weighted rewards off-chain.

Read `trancheCountOf` and page through `tranchesOf(projectId, holder, start, count)` (amount + timestamp per tranche, oldest first, one tranche per week the holder added to their position, at most 256 per call), `stakedBalanceThroughEpochOf(projectId, holder, epoch)` for a holder's stake aged through a week, `netStakedIn(projectId, epoch)` and `netStakedWithin(projectId, from, to)` for project-wide stake by joining week, plus `currentStreakOf` and `longestStreakOf`; or index `Staked`, `Unstaked`, `StreakStarted`, and `StreakEnded`. A `Staked` event in the same week as the holder's newest tranche extends that tranche and moves its timestamp forward rather than adding one. At completed transaction boundaries, `stakedBalanceOf` equals the token balance and the active tranche sum, including after voluntary controller burns. In transferable mode, a positive non-self transfer emits `Unstaked` for the sender and `Staked` for the receiver; an `Unstaked` event alone is not proof of an underlying-token payout. On-chain holder-streak gates can call the views directly. Amount-weighted duration rewards must use each tranche's age, because a long-running holder streak can include recent deposits and incoming transfers.
