# User Journeys

## Repo Purpose

This repo owns staking-with-streaks for ERC-20 tokens on Juicebox V6: permanently configured staking projects, backing-priced Sticky shares that are soulbound or transferable, per-deposit tranche accounting, holder streaks, opt-in reward compounding, cross-chain reward pockets, and the Sticky webclient. Juicebox core handles custody, issuance math, and cash out economics; `JBTokenDistributor` handles rewards. Start here if you're integrating staking into a client, designing a reward program on streak data, or launching a sticky project for a token. See [the webclient guide](webclient/README.md) for site configuration and production checks.

## Primary Actors

- **Community operator** (e.g. Artizen): launches a sticky project for their token and designs reward programs on the resulting data.
- **Holder**: stakes to signal commitment, unstakes at will, tracks their streak, optionally compounds rewards.
- **Granter** (protocol or partner): stakes on holders' behalf as rewards, frictionlessly.
- **Funder**: sends reward tokens to a sticky token's holders, on the same chain or from another chain.
- **Indexer / reward engine**: consumes events and views to compute reward math off-chain.

## Key Surfaces

- `JBStickyDeployer.deployStickyFor`: launch a locked sticky project for a token.
- `JBMultiTerminal.pay` and `previewPayFor` (core): stake and quote.
- `JBMultiTerminal.cashOutTokensOf` (core): unstake.
- `JBStickyHook` views/events: all balance, streak, tranche, and trust data.
- `JBTokenDistributor.fund` / `collectVestedRewards`, `JBStickyAutoStick`, `JBStickyRewardPockets`: rewards.

## Journey 1: Launch a sticky project

**Actor:** community operator.

**Intent:** make their token stakeable under permanent, reviewed withdrawal and transfer rules.

Call `deployStickyFor(stakedToken, name, symbol, projectUri, cashOutTaxRate, granters, soulbound)` with `msg.value` equal to `JBProjects.creationFee()`. The token, tax rate, launch-time granters, and transfer mode are permanent; verify them before sending. A maximum tax rate means cash outs return no underlying tokens; any non-zero tax subjects reclaims to the protocol's cash out fee. Failure modes include an incorrect creation fee, an out-of-range tax rate, and a token without `decimals()`. The call returns `projectId`; the `DeploySticky` event identifies the deployed share token.

## Journey 2: Stake

**Actor:** holder.

**Intent:** lock tokens to start or grow a commitment streak.

Quote first: `previewPayFor(projectId, stakedToken, amount, beneficiary: self, metadata)` returns the exact share count the deposit will issue, `floor(amount × supply / backing)`. The first deposit into an empty project issues one share per whole token, normalized to 18 decimals. A zero preview means the amount cannot be issued within the rounding guard; increase it. Then approve the terminal for the exact amount and `pay(projectId, stakedToken, amount, beneficiary: self, minReturnedTokens: preview, ...)`. A deposit that would issue fewer shares than quoted, including because a donation or another stake landed first, reverts against the minimum. The first stake (or the first after a full exit) starts the streak; later stakes add tranches with their own timestamps and never move the streak's start.

## Journey 3: Unstake

**Actor:** holder.

**Intent:** recover staked tokens, keeping as much duration credit as possible.

Call `cashOutTokensOf(holder: self, projectId, cashOutCount, tokenToReclaim: stakedToken, minTokensReclaimed, beneficiary, metadata)` with `cashOutCount` in 18 decimals. The reclaim is the holder's proportion of share-owned backing (surplus minus the orphaned balance) under the launch-time cash out curve, less the protocol fee when the tax is non-zero. Zero tax gives a proportional share; positive tax gives less per share for partial exits, and a full exit of the whole supply reclaims everything shares own. Read the current backing from `currentSurplusOf` and `orphanedBalanceOf`, compute the quote, and set a minimum before sending. Tranches are consumed newest-first. A partial unstake never resets the streak or the remaining tranches' timestamps; unstaking everything ends the streak and records it into `longestStreakOf`.

## Journey 4: Grant staked tokens to a streaker

**Actor:** granter.

**Intent:** reward a holder with pre-staked tokens, no action required from them.

Pay the sticky project with `beneficiary` set to the holder. The payer must be one of the project's launch-time granters or a sender the holder has trusted via `setTrustedSenderFor`; otherwise the pay reverts with `JBStickyHook_SenderNotTrusted`. The grant is priced like any deposit and lands as a new tranche with its own timestamp: the holder's streak is neither broken nor backdated, and amount-weighted math can't be laundered through an old streak.

## Journey 5: Reward holders

**Actor:** funder.

**Intent:** distribute a reward token pro rata to a sticky token's holders.

Same chain: approve the distributor and call `fund(hook: stickyToken, token: rewardToken, amount)`. The first interaction with a round anywhere on the distributor (any funding, settle, or `poke()`) pins its snapshot block and the next round's; holders' shares at that block set their allocation, so stakes after the snapshot earn nothing for that round while exits after it still earn. Check `roundSnapshotBlock(round)` before funding, and prefer projects with a non-zero cash out tax, since a zero-tax project lets a one-block stake ahead of the pin capture a share of the round for free. Rewards vest over four weekly rounds and stay claimable for three years before they can be recycled. Holders call `collectVestedRewards(hook: stickyToken, tokenIds: [uint160(self)], tokens, beneficiary)`; anyone may collect on a holder's behalf, but only to the holder's own address.

Other chain: predict the pocket with `JBStickyRewardPockets.predictPocketOf(stickyToken)`. The factory is deployed at the same address on every chain, so the prediction is valid everywhere. Bridge a sucker-mapped reward token with the pocket as the claim beneficiary. Once the claim lands on the sticky project's chain, anyone calls `settleFor(stickyToken, rewardToken)`; the arrival funds the round current at settlement. The reward token must be sucker-mapped between the two chains; the sticky project itself needs no suckers.

## Journey 6: Compound rewards

**Actor:** holder.

**Intent:** turn vested underlying-token rewards back into the position without extra steps.

One click: approve the adapter for the collectable amount and call `JBStickyAutoStick.stickRewardsFor(projectId)`. The adapter collects the holder's vested rewards to the holder, pulls exactly the delivered amount, quotes the terminal, and pays the project with the holder as beneficiary and the quote as the minimum. It needs the hook to accept it as a payer: the holder trusts it via `setTrustedSenderFor`, or the project listed it as a granter at launch.

Keeper mode: `setConfigFor(projectId, enabled: true, minimumAmount, cooldown)` with a cooldown between one and thirty days; anyone can then call `compoundFor(projectId, holder)` once the collectable reward clears the minimum. Keepers cannot choose the token, amount, beneficiary, or destination. Compounding is best effort: if someone collected to the holder first, the tokens sit in the holder's wallet and can be staked manually.

## Journey 7: Build a reward program on streak data

**Actor:** indexer / reward engine.

**Intent:** compute duration- and amount-weighted rewards off-chain.

Read `trancheCountOf` and page through `tranchesOf(projectId, holder, start, count)` (amount + timestamp per deposit, oldest first, at most 256 per call), plus `currentStreakOf` and `longestStreakOf`; or index `Staked`, `Unstaked`, `StreakStarted`, and `StreakEnded`. The tranche book is exact: every burn and transfer, including voluntary controller burns, updates it, and `stakedBalanceOf` always equals the token balance. In transferable mode, a transfer emits `Unstaked` for the sender and `Staked` for the receiver; an `Unstaked` event alone is not proof of an underlying-token payout. On-chain gating contracts (e.g. "365-day streakers only") can call the views directly.
