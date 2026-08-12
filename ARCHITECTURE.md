# Architecture

## Purpose

`nana-sticky-v6` exists to let holders of a token lock it into a Juicebox project in exchange for a soulbound 1:1 staked copy, while recording per-deposit amounts and durations that off-chain reward programs can trust.

The value the system protects is the staked backing: every staked token must remain reclaimable 1:1 at any time, by only its holder, with no party — including the project's owner — able to change that.

## System Overview

The package owns three contracts: a deployer that launches locked staking projects, a data hook that does position accounting, and a soulbound token. It composes `nana-core-v6` for everything economic: `JBMultiTerminal` custodies the staked tokens, `JBController`/`JBRulesets` enforce the eternal ruleset, and `JBTokens` mints and burns the soulbound token. It explicitly does not own reward logic — no points, multipliers, or payouts exist on-chain. The surrounding truth (what a stake is worth, when funds can move) is defined entirely by core's pay/cash-out flows under the ruleset this package configures.

## Core Invariants

- **1:1 backing, never under**: the staking project's funds can only leave through cash outs (payout limits and surplus allowances are zero, terminal migration disabled), so surplus ≥ soulbound supply's backing at all times. Donations via `addToBalanceOf` can push reclaims above 1:1, never below.
- **Fixed cash out tax forever**: the single ruleset's `cashOutTaxRate` is set once at launch — the project's "commitment reward", the share of every unwind left behind for remaining stakers. At 0 unwinds are proportional and protocol-fee-free; above 0 the Juicebox protocol's standard fee applies to what leavers reclaim. No second ruleset can ever be queued because the owner (the deployer contract) exposes no call to do so.
- **Tranche book equals staked balance**: `stakedBalanceOf` always equals the sum of a holder's tranche amounts; both are mutated only together in `afterPayRecordedWith` / `afterCashOutRecordedWith`. A holder burning their soulbound tokens directly via `JBController.burnTokensOf` can overstate their own tranche book relative to their token balance — self-inflicted only; the stranded backing accrues pro-rata to remaining stakers.
- **LIFO with timestamp preservation**: unstakes consume tranches newest-first; a split tranche keeps its original timestamp. Duration-weighted reward math can therefore never be reset by a partial exit nor backdated by a top-up.
- **Streak monotonicity**: `streakStartOf` is set only on a 0→non-zero balance transition and cleared only on a non-zero→0 transition. Staking more never moves it.
- **Streaks can't be laundered between wallets, in either transfer mode**: soulbound tokens revert transfers outright; transferable tokens route every transfer through `JBStickyHook.recordTransfer` (callable only by the project's registered token), which consumes the sender's newest tranches and restarts the clock on the moved amount as the receiver's fresh tranche. The tranche-book-equals-balance invariant holds in both modes.
- **Votes always equal locked balance**: every holder is self-delegated on first mint and `delegate`/`delegateBySig` revert, so `getPastVotes(holder) == balance(holder)` and the active-vote total equals total supply at every block. Distributor reward shares can therefore never be gamed by delegation churn, and no holder needs to register to be counted.
- **Hook callbacks are terminal-gated**: `afterPayRecordedWith` and `afterCashOutRecordedWith` revert unless `msg.sender` is a terminal of the context's project per `JBDirectory`.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBStickyDeployer` | Launches sticky projects with the locked eternal ruleset; deploys and attaches the soulbound token; permanent owner of every project it launches | Immutable; deploys `JBStickyHook` in its constructor; its only external transaction is `deployStickyFor` |
| `JBStickyHook` | `IJBRulesetDataHook` + `IJBPayHook` + `IJBCashOutHook` singleton keyed by project ID; tranche, balance, and streak accounting | Immutable; receives no funds (hook specifications carry `amount: 0`); no owner and no setters |
| `JBStickyToken` | Soulbound ERC-20 representing staked positions; checkpointed votes (self-delegated on mint, delegation locked) make it an `IJBActiveVotes` stake source for `JBTokenDistributor` rewards | One instance per sticky project, bound to its project ID via `canBeAddedTo`; mint/burn only by `JBTokens` |
| `JBStickyRewardPockets` / `JBStickyRewardPocket` | Cross-chain reward inbox: one deterministic, chain-identical pocket per sticky token; sucker-bridge arrivals are settled permissionlessly into the distributor | Ported from `JBXDistributor`'s bridge-settlement pattern, simplified: attribution is by pocket address instead of by leaf, so there is no settlement ledger, no double-settle surface, and pockets work counterfactually (tokens can land before the pocket is deployed) |

## Data Flow

**Stake**: holder (or granter) → `JBMultiTerminal.

**Unstake**: holder → `JBMultiTerminal.cashOutTokensOf` → data hook passes tax rate (0), count, supply, and surplus through untouched → terminal burns the tokens and returns the proportional reclaim → terminal calls `afterCashOutRecordedWith` (no funds forwarded) → hook consumes tranches newest-first, splitting the last one in place, and ends the streak if the balance reached zero.

Decimals: tranche amounts, staked balances, and cash out counts are all in the soulbound token's 18 decimals regardless of the staked token's decimals.

## Trust & Permissions

- No owner, no admin, no upgrade path.
- `allowSetCustomToken` is enabled in the ruleset, but `setTokenFor` is owner-gated in core and reverts once a token is set, so the launch-time attachment is one-shot.
- Any project can point its own ruleset's `dataHook` at `JBStickyHook`; the accounting is keyed by project ID, so a rogue project can only pollute its own book.


## Testing

- `test/JBStickyHook_Unit.t.
- `test/JBSticky_Integration.t.sol`: full stack against real core (`TestBaseWorkflow`) — 6-decimal staked token round trip, grants, donations above 1:1, soulbound transfer revert, minimum enforcement through `pay`.
