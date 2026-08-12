# JBSticky

Staking with streaks for Juicebox project tokens. Holders stake a token (e.g. ART) into a locked Juicebox project and receive a staked copy (e.g. STREAKART) 1:1 — soulbound by default, or transferable with transfers restarting the streak clock on the moved tokens. Staked tokens are out of circulation — they can't be sold, transferred, or collateralized — and can be unwound back 1:1 at any time, with no minimum lock and no fee.

The contracts are silent on rewards. They expose the data that reward programs need — per-deposit tranches with their own timestamps, LIFO unstaking that never resets the remainder's clock, and a person-level streak that only resets when the staked balance returns to zero — and emit clean events so reward math can iterate off-chain without touching the contracts.

## How it works

- `JBStickyDeployer. The deployer owns the project forever and exposes no way to change its rules: a single eternal ruleset with 1:1 issuance, a fixed cash out tax (the project's "commitment reward"), zero reserved percent, no fund access limits, and every mutation flag disabled.
- **Stake** by paying the project through `JBMultiTerminal.pay(...)` with the staked token. The payment mints the soulbound token 1:1 (normalized to 18 decimals) and `JBStickyHook` records a tranche with its own timestamp.
- **Unstake** through `JBMultiTerminal.cashOutTokensOf(...)`. With a zero commitment reward the reclaim is proportional and fee-free — 1:1 against the staked backing. With a non-zero commitment reward, leavers forfeit a share of their reclaim to remaining stakers (and the Juicebox protocol takes its standard fee on taxed cash outs). The hook consumes tranches newest-first (LIFO); a partially consumed tranche keeps its original timestamp, so unstaking 2 out of a 5-token tranche doesn't reset the clock on the 3 that stay.
- **Streak clock**: starts when a holder's staked balance becomes non-zero, never moves when more is staked, and resets only when the balance returns to zero. Grants staked on a holder's behalf (any payer, `beneficiary = holder`) auto-add as their own tranche without touching the streak — a long streak can't be used to backdate fresh capital.
- **Queryable**: `tranchesOf`, `stakedBalanceOf`, `streakStartOf`, `currentStreakOf`, `longestStreakOf`. Events: `Staked`, `Unstaked`, `StreakStarted`, `StreakEnded`.

## Rewards

Sticky tokens plug straight into [`JBTokenDistributor`](https://github.com/Bananapus/nana-distributor-v6): anyone can `fund(stickyToken, rewardToken, amount)` to reward that project's streakers pro-rata to their locked balance at the round's snapshot — snapshot gamers who lock right after a funding get nothing until the next round. The soulbound token self-delegates every holder on first mint and locks delegation, so voting power always equals locked balance and no holder ever needs to register. Rewards vest over rounds and are collected with `beginVesting` + `collectVestedRewards`. The deploy script ships a sticky-tuned distributor (weekly rounds, 4 vesting rounds, 28-day claims) to every supported chain.

**Rewards from other chains**: every sticky token has a deterministic, chain-identical reward pocket (`JBStickyRewardPockets.predictPocketOf`). A funder on any chain bridges any sucker-mapped project token with the pocket as the sucker-claim beneficiary; when the claim lands, anyone calls `settleFor` and the arrival funds a reward round for the sticky token's holders. The sticky project itself needs no suckers — a Base-only project like ART can receive rewards originated on any chain, as long as the *reward* token bridges. Pockets work counterfactually: tokens can arrive before the pocket contract exists.

## Contracts

| Contract | Role |
| --- | --- |
| `JBStickyDeployer` | Launches sticky projects, owns them forever, deploys and attaches the soulbound token. |
| `JBStickyHook` | Ruleset data hook + pay hook + cash out hook. Tracks tranches, balances, and streaks per project per holder. |
| `JBStickyToken` | Soulbound ERC-20 with locked self-delegated votes (`transfer` and `delegate` revert; mint/burn only through `JBTokens`) — a valid `IJBActiveVotes` stake source for `JBTokenDistributor`. |

## Develop

```bash
npm install
forge test
```

## Deploy

Deployments run through [Sphinx](https://sphinx.dev):

```bash
npm run deploy:testnets
npm run deploy:mainnets
```
