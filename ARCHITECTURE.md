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

## Stick-time-gated rewards

`JBStickyDistributor` (`src/JBStickyDistributor.sol`) is a clean fork of `JBDistributor` + `JBTokenDistributor` that adds a second reward-pot class alongside the base's votes-weighted group 0: **criteria groups**, each gated on an epoch window `[lo, hi]` derived from a pair of parameters, `minWeeks` and `maxWeeks`. It reads a sticky project's stake directly from `JBStickyHook` via `STICKY_HOOK`; nothing about `JBStickyHook`'s own callback-gating or tranche-book invariants changes.

**Epoch buckets.** `JBStickyHook` anchors epochs globally, independent of any distributor's round schedule: `epochOf(t) = t / EPOCH_DURATION`, with `EPOCH_DURATION` fixed at 1 week. Two pieces of hook storage track stake by the epoch it entered: `netStakedIn[projectId][epoch]` (incremented on stake, decremented per consumed tranche — keyed by that tranche's own timestamp — on unstake or transfer-out) and `firstStakeEpochPlusOneOf[projectId]` (set once, bounds the walk). The batch view `netStakedInEpochs(projectId, fromEpoch, toEpoch)` lets a caller read a whole range in one external call.

**Criteria encoding.** A criteria `groupId` packs `minWeeks * CRITERIA_BASE + maxWeeks`, with `CRITERIA_BASE = 1000` (`maxWeeks` occupies the last three digits — ADMINISTRATION carries the operator-facing write/read procedure and the validity checklist) and both parameters capped at `MAX_CRITERIA_WEEKS = 520`. `_criteriaWindowFor(snapshotEpoch, groupId)` decodes a groupId into the epoch window `[lo, hi]` it selects: `hi = snapshotEpoch - minWeeks`; `lo = 0` when `maxWeeks == 0` (unbounded below — tenure), otherwise `lo = snapshotEpoch - maxWeeks` (clamped to 0). Three shapes fall out of the same window math:
- **Tenure** — `(minWeeks, 0)`, e.g. `4000` = "4+ weeks": `maxWeeks = 0` leaves the window unbounded below, so it pays a staker's whole aged position.
- **Recency** — `(1, maxWeeks)`, e.g. `1004` = "the last 4 completed weeks": the tightest legal `minWeeks`, paired with a `maxWeeks` cap, selects only the newest eligible tranches.
- **Cohort** — `(minWeeks, maxWeeks)`, e.g. `4008` = "4 to 8 weeks": both bounds active, paying only the deposit slice that fell in that stretch.

`_isValidGroup` accepts `0` (the everyone-pool) or any `groupId` whose decoded `minWeeks` is in `[1, 520]` and whose `maxWeeks` is either `0` or in `[minWeeks, 520]`; `_requireValidGroup` wraps it with `JBStickyDistributor_InvalidCriteria`. The largest valid criteria `groupId` is `520520`.

**Fund-time denominator.** The problem: pro-rata needs a denominator — "total stake whose window-eligible tranches sum to D at the snapshot" — but D is airdropper-chosen and tranches cross window boundaries silently, so no checkpointed quantity exists to look up lazily. The unlock: aging is deterministic. If stake is bucketed by the epoch it was staked in, then at any moment "total stake in epoch window `[lo, hi]`" is just the sum of buckets in that range, read at current values. Record that sum at fund time and it *is* the snapshot denominator — no history, no checkpoints, no pokes, no registration. Concretely, `_recordRewardRound` records `snapshotEpoch = block.timestamp / EPOCH_DURATION` and `totalStake = _windowTotalStake(hook, snapshotEpoch, groupId)` — which resolves the window via `_criteriaWindowFor`, clamps `lo` up to `firstStakeEpochPlusOneOf - 1`, and sums `netStakedIn[projectId][e]` over `[lo, hi]` — the first time a (group, token, round) is funded. Later fundings of the same round only add to the pot; the snapshot never re-walks.

**Downward-only claim rule.** A claimer's weight for a round is the sum of their **live** tranche amounts whose epoch falls in `[lo, hi]`, read from `STICKY_HOOK.tranchesOf` at claim time (`_windowStakeOf`). Why live tranches are safe:
- Tranches are append-only with now-timestamps, so nothing staked after the snapshot can land at or below `hi = snapshotEpoch − minWeeks` (epochs are monotonic in time and `minWeeks ≥ 1`, so `hi ≤ snapshotEpoch − 1`).
- LIFO unstaking consumes newest tranches first, so post-snapshot exits reduce only the exiting holder's own eligible weight, never anyone else's.
- Therefore Σ numerators ≤ recorded denominator, always. Shortfall stays in the pot and recycles through the existing expiry path, still criteria-gated.

Eligibility is frozen at the snapshot on both sides of the ledger: the denominator is fixed at fund time and the numerator is bounded by the same `[lo, hi]` window at claim time, so a tranche does not age into or out of a pot between funding and claiming — only unstaking it changes what it's worth.

**Documented rule:** you must still be stuck to collect. Unsticking deep enough to consume an in-window tranche after the snapshot forfeits that weight, permanently — claims read live tranche state, not a checkpoint. On-theme.

**Why `minWeeks ≥ 1` is load-bearing.** With `minWeeks = 0`, the window's top bound `hi` would sit at the snapshot epoch itself: a tranche staked after the fund block but in the same epoch would pass the window test while the denominator missed it → Σ numerators could exceed the denominator → overdistribution / insolvency of the pot. Criteria groups therefore enforce `minWeeks ≥ 1` — the current, still-incomplete epoch is never eligible, which is what keeps in-window buckets append-frozen at fund time. `MAX_CRITERIA_WEEKS = 520` bounds both parameters, and `_requireValidGroup` reverts with `JBStickyDistributor_InvalidCriteria` for any `groupId` whose decode fails those checks — 0 stays reserved for the votes-weighted everyone-pool, so every criteria group has `minWeeks ∈ [1, 520]` by construction. This is also why recency is `(1, maxWeeks)`, not `(0, maxWeeks)`: `minWeeks = 0` is rejected outright, closing the only path to overdistribution the encoding has to guard against.

Two further semantics worth documenting, independent of safety:
- **Bounded windows pay deposits, not persons.** A continuous staker who tops up every month holds tranches spread across many buckets; a `(4, 8)` cohort pot pays only the slice deposited in that stretch, while a tenure pot (`maxWeeks = 0`) pays their whole aged position. See ADMINISTRATION for the operator-facing version of this.
- **LIFO erodes recency fastest.** Under tenure, a partial unstake consumes fresh tranches first, shielding aged weight. Under recency the eligible tranches are the newest ones, so any partial unstake immediately cuts eligibility. Safety is unaffected either way — numerators only shrink — but it's a real UX asymmetry between the two shapes.

**`projectId` overload.** `processSplitWith` (payout and reserved-token splits, `beneficiary` = the sticky token) reads criteria from the split's `projectId` field: any value that decodes as a valid criteria `groupId` via `_isValidGroup` selects that window; `0` or any other value falls through to group 0.

This overload rests on hook priority, not on any numeric coincidence. Core's split-distribution logic pays `hook` > `projectId` > `beneficiary`; `projectId` is read only in the `else` branch that runs after the hook check (`JBMultiTerminal.sol:389`, `JBController.sol:1184`), so with this split's `hook` set to this distributor, core's own pay-a-project branch never runs and the field is free to carry other meaning. `JBSplits._setSplitsOf` validates only percent rules and locked-split preservation, with no existence check on `projectId`, so any `uint64` value stores intact — comfortably above the `520520` ceiling this encoding needs. Because the guarantee is structural rather than a numeric range, a split can be genuinely locked (`lockedUntil` in the future) *and* criteria-carrying at the same time: `_isLockedSplitIncluded` already requires a replacement split to preserve `projectId` alongside `percent`, `hook`, `beneficiary`, and `preferAddToBalance` while locked, so a locked criteria split freezes both its share and its window as one immutable promise. A `projectId` value below `CRITERIA_BASE` (e.g. `4`) decodes to `minWeeks == 0`, which `_isValidGroup` rejects, so it falls through to group 0 exactly like any other out-of-range value rather than reverting.

**Display caveat.** A tool that renders a split's destination without checking `hook` first will show "pays project 4008" — plausible-looking wrong information. Such tools are already wrong today, since `hook` takes priority regardless of what gets rendered. `revnet.money`'s `splitRouting` resolves `hook` first and is correct; `juicebox.money`'s splits editor already treats `projectId` as an optional rider on hook splits. Sweeping juicescan and juicy.vision is a follow-up in those repos, not this one.

**Why not `context.groupId`.** The split hook context carries its own `groupId`, but it is JB's split-group lookup key, not a per-split payload: payout distributions query `splitsOf(projectId, rulesetId, uint256(uint160(token)))` and reserved-token distributions query `JBSplitGroupIds.RESERVED_TOKENS`, so the value is fixed by the distribution path and echoed back. A split group whose ID were set to a criteria value would never be looked up at all — the split would silently never distribute. `JBSplitGroupIds.RESERVED_TOKENS == 1` happens to fall inside the criteria band numerically, but it decodes to `minWeeks == 0`, which `_isValidGroup` rejects — so it isn't even a candidate collision under this encoding. The disqualifying problem is structural, not a numeric near-miss: a group ID is shared by every split in the group, which would rule out running (say) a 4-to-8-week cohort pot and an everyone-pool off the same payout token, since both splits would be forced to read the same `groupId`. `projectId` is per-split and free whenever this split's `hook` is set, so it is the field with room for this.

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
