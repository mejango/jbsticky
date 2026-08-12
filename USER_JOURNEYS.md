# User Journeys

## Repo Purpose

This repo owns staking-with-streaks for Juicebox project tokens: locked staking projects, soulbound staked copies, and per-deposit duration accounting. It does not own reward logic, token issuance economics (core does), or any UI. Start here if you're integrating staking into a client, designing a reward program on streak data, or launching a sticky project for a token.

## Primary Actors

- **Community operator** (e.g. Artizen): launches a sticky project for their token and designs off-chain reward programs on the resulting data.
- **Holder**: stakes to signal commitment, unstakes at will, tracks their streak.
- **Granter** (protocol or partner): stakes on holders' behalf as rewards, frictionlessly.
- **Indexer / reward engine**: consumes events and views to compute reward math off-chain.

## Key Surfaces

- `JBStickyDeployer.deployStickyFor`: launch a locked sticky project for a token.
- `JBMultiTerminal.pay` (core): stake.
- `JBMultiTerminal.cashOutTokensOf` (core): unstake.
- `JBStickyHook` views/events: all streak and tranche data.

## Journey 1: Launch a sticky project

**Actor:** community operator.

**Intent:** make their token stakeable with trustless 1:1 unwinding.

Call `deployStickyFor(stakedToken, name, symbol, projectUri, cashOutTaxRate)` with `msg.value` equal to `JBProjects.creationFee()`. Everything is permanent; verify parameters before sending. Failure modes: wrong `msg.value` reverts (`JBController_InvalidCreationFee`); a token without `decimals()` reverts. The returned `projectId` and the `DeploySticky` event carry the soulbound token address.

## Journey 2: Stake

**Actor:** holder.

**Intent:** lock tokens to start or grow a commitment streak.

Approve the terminal for the staked token, then `pay(projectId, stakedToken, amount, beneficiary: self, minReturnedTokens: 0, ...)`. Receives soulbound tokens 1:1 (18 decimals). First stake (or first after a full exit) starts the streak; later stakes add tranches with their own timestamps and never move the streak's start.

## Journey 3: Unstake

**Actor:** holder.

**Intent:** recover staked tokens, keeping as much duration credit as possible.

Call `cashOutTokensOf(holder: self, projectId, cashOutCount, tokenToReclaim: stakedToken, ...)` with `cashOutCount` in 18 decimals. Reclaim is 1:1 (more if donations raised the surplus), fee-free. Tranches are consumed newest-first — there is no position picker because protecting the oldest tranches is always optimal under duration-weighted rewards. A partial unstake never resets the streak or the remaining tranches' timestamps; unstaking everything ends the streak and records it into `longestStreakOf`.

## Journey 4: Grant staked tokens to a streaker

**Actor:** granter.

**Intent:** reward a holder with pre-staked tokens, no action required from them.

Pay the sticky project with `beneficiary` set to the holder. The payer must be one of the project's launch-time granters or a sender the holder has trusted via `setTrustedSenderFor` — otherwise the pay reverts (`JBStickyHook_SenderNotTrusted`). The grant lands as a new tranche with its own timestamp: the holder's streak is neither broken nor backdated, and amount-weighted math can't be laundered through an old streak.

## Journey 5: Reward streakers from another chain

**Actor:** funder on a chain where the sticky project doesn't exist.

**Intent:** reward a (possibly single-chain) project's streakers with a sucker-mapped project token.

Predict the pocket: `JBStickyRewardPockets.predictPocketOf(stickyToken)` — the factory is deployed at the same address on every chain, so the prediction is valid everywhere. Bridge the reward token through its own sucker with the pocket as the claim beneficiary. Once the claim lands on the sticky project's chain, anyone (funder, keeper, frontend) calls `settleFor(stickyToken, rewardToken)`; the arrival funds the current reward round. Constraints: the reward token must be sucker-mapped between the two chains (the sticky project needs no suckers), and the reward lands in whatever round is current at settlement.

## Journey 6: Claim a stick-time-gated reward

**Actor:** holder.

**Intent:** collect their pro-rata share of a `JBStickyDistributor` reward pot they qualify for.

Call `beginVesting(hook, groupId, tokenIds, tokens)` to materialize unclaimed past rounds into vesting entries, then `collectVestedRewards(hook, groupId, tokenIds, tokens, beneficiary)` to transfer out whatever has since unlocked — or skip straight to `collectVestedRewards`, which begins vesting on the caller's behalf first. `hook` is the sticky token address; `tokenIds` encode staker addresses; `groupId` selects the pot — `0` is the everyone-pool (votes-weighted, no criteria), `1`–`520` is "stuck ≥ `k` weeks" with `k = groupId`. Preview unlocked amounts first with `collectableFor(hook, groupId, tokenId, token)`.

**You must still be stuck to collect.** A criteria round's weight is computed from the holder's *live* tranches at claim time — the ones aged at least `k` weeks past the round's snapshot. LIFO unstaking consumes newest tranches first, so unstaking deep enough to consume an aged tranche after a round's snapshot forfeits that tranche's weight for that round, permanently — claims read live state, not a checkpoint. Claimed rewards vest linearly over `VESTING_ROUNDS` rounds (4 in production) and can be collected as they unlock. Unclaimed rounds expire after `CLAIM_DURATION` (28 days in production) and recycle into the same group's current round with a fresh denominator — a late unstaker only shares in the recycled amount if they still qualify at the new snapshot.

## Journey 7: Build a reward program on streak data

**Actor:** indexer / reward engine.

**Intent:** compute duration- and amount-weighted rewards off-chain.

Read `tranchesOf(projectId, holder)` (amount + timestamp per deposit, oldest first), `currentStreakOf`, and `longestStreakOf`; or index `Staked`, `Unstaked`, `StreakStarted`, and `StreakEnded` events. Trust boundary: a holder who burns soulbound tokens directly through `JBController.burnTokensOf` (bypassing cash out) leaves their tranche book overstated relative to `JBTokens.totalBalanceOf` — cross-check against token balances if exactness matters for large payouts. On-chain gating contracts (e.g. "365-day streakers only") can call the views directly.
