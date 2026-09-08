# User Journeys

## Repo Purpose

This repo owns staking-with-streaks for Juicebox project tokens: locked staking projects, soulbound or transferable staked copies, per-deposit duration accounting, and the Sticky webclient. Juicebox core handles token issuance and cash-out economics; the distributor integration handles rewards. Start here if you're integrating staking into a client, designing a reward program on streak data, or launching a sticky project for a token. See [the webclient guide](webclient/README.md) for site configuration and production checks.

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

**Intent:** make their token stakeable under permanent, reviewed withdrawal and transfer rules.

Call `deployStickyFor(stakedToken, name, symbol, projectUri, cashOutTaxRate, granters, soulbound)` with `msg.value` equal to `JBProjects.creationFee()`. The tax rate, launch-time granters, and transfer mode are permanent; verify them before sending. A maximum tax rate means cash outs return no underlying tokens. Failure modes include an incorrect creation fee, an out-of-range tax rate, and a token without `decimals()`. The call returns `projectId`; the `DeploySticky` event identifies the deployed sticky token.

## Journey 2: Stake

**Actor:** holder.

**Intent:** lock tokens to start or grow a commitment streak.

Approve the terminal for the exact staked-token amount, then `pay(projectId, stakedToken, amount, beneficiary: self, minReturnedTokens: expectedMint, ...)`. The immutable issuance rules mint sticky tokens 1:1, normalized to 18 decimals, even if donations changed the pool's backing. Use that expected amount as the minimum return. First stake (or first after a full exit) starts the streak; later stakes add tranches with their own timestamps and never move the streak's start. Transfer behavior follows the project's launch-time `soulbound` choice.

## Journey 3: Unstake

**Actor:** holder.

**Intent:** recover staked tokens, keeping as much duration credit as possible.

Call `cashOutTokensOf(holder: self, projectId, cashOutCount, tokenToReclaim: stakedToken, ...)` with `cashOutCount` in 18 decimals. Reclaim depends on the current backing, supply, configured cash-out tax, and terminal fee accounting. A zero-tax pool with unchanged backing normally unwinds 1:1; donations can increase backing, and a maximum tax rate returns zero even for a full exit. Review the terminal's current reclaim quote and set a minimum output before sending. Tranches are consumed newest-first. A partial unstake never resets the streak or the remaining tranches' timestamps; unstaking everything ends the streak and records it into `longestStreakOf`.

## Journey 4: Grant staked tokens to a streaker

**Actor:** granter.

**Intent:** reward a holder with pre-staked tokens, no action required from them.

Pay the sticky project with `beneficiary` set to the holder. The payer must be one of the project's launch-time granters or a sender the holder has trusted via `setTrustedSenderFor` — otherwise the pay reverts (`JBStickyHook_SenderNotTrusted`). The grant lands as a new tranche with its own timestamp: the holder's streak is neither broken nor backdated, and amount-weighted math can't be laundered through an old streak.

## Journey 5: Reward streakers from another chain

**Actor:** funder on a chain where the sticky project doesn't exist.

**Intent:** reward a (possibly single-chain) project's streakers with a sucker-mapped project token.

Predict the pocket: `JBStickyRewardPockets.predictPocketOf(stickyToken)` — the factory is deployed at the same address on every chain, so the prediction is valid everywhere. Bridge the reward token through its own sucker with the pocket as the claim beneficiary. Once the claim lands on the sticky project's chain, anyone (funder, keeper, frontend) calls `settleFor(stickyToken, rewardToken)`; the arrival funds the current reward round. Constraints: the reward token must be sucker-mapped between the two chains (the sticky project needs no suckers), and the reward lands in whatever round is current at settlement.

## Journey 6: Build a reward program on streak data

**Actor:** indexer / reward engine.

**Intent:** compute duration- and amount-weighted rewards off-chain.

Read `tranchesOf(projectId, holder)` (amount + timestamp per deposit, oldest first), `currentStreakOf`, and `longestStreakOf`; or index `Staked`, `Unstaked`, `StreakStarted`, and `StreakEnded` events. Trust boundary: a holder who burns soulbound tokens directly through `JBController.burnTokensOf` (bypassing cash out) leaves their tranche book overstated relative to `JBTokens.totalBalanceOf` — cross-check against token balances if exactness matters for large payouts. On-chain gating contracts (e.g. "365-day streakers only") can call the views directly.
