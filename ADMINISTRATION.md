# Administration

## At A Glance

| Item | What To State |
| --- | --- |
| Scope | `JBStickyDeployer`, `JBStickyHook`, `JBStickyToken`, and every sticky project launched through them |
| Control posture | Permissionless deployment; immutable after construction; sticky projects are deployer-owned with no mutable surface |
| Highest-risk actions | `deployStickyFor` (irreversible per-project parameters, including the commitment reward) |
| Recovery posture | No in-place correction. A misconfigured sticky project is abandoned and a new one deployed; stakers can always unwind 1:1 |

## Purpose

Nobody can change behavior after deployment. The deployer contract owns every sticky project it launches and exposes exactly one external transaction — `deployStickyFor` — so the owner powers that Juicebox grants a project owner (queue rulesets, distribute payouts, set metadata, transfer the project NFT) are permanently unexercisable. The admin surface is deployment-time only: everything a sticky project will ever do is fixed by the arguments to its launch call.

## Control Model

- Permissionless: anyone can deploy a sticky project for any token by paying the `JBProjects` creation fee.
- Immutable after construction: `JBStickyDeployer` and `JBStickyHook` have no owner, no upgrade path, and no parameter setters reachable after a project's launch transaction completes.
- Deployer-controlled in name only: the deployer holds each project NFT forever; `JBPermissions` delegation never comes into play because the owner account is a contract with no permission-granting surface.


## One-Way Doors

- **Launching a sticky project.** The staked token, accounting context, ruleset (1:1 weight, launch-time commitment reward as the cash out tax, all mutation flags off), and token metadata are permanent. There is no fix for a wrong parameter besides deploying a fresh project.
- **Attaching the soulbound token.** `setTokenFor` is one-shot in core; the token is bound to its project ID via `canBeAddedTo`.
- **Choosing granters.** The launch-time granter list is permanent; a forgotten grant program address can still reach holders who individually trust it, but cannot airdrop to everyone. Unauthorized third-party stakes revert.

## Operational Notes

- The project creation fee (`JBProjects.creationFee()`) must be sent exactly as `msg.value` to `deployStickyFor`.
- Fee-on-transfer or rebasing-down tokens must not be used as staked tokens: the 1:1 backing invariant assumes the terminal receives what was paid.
- Reward programs read `tranchesOf` / `currentStreakOf` / `longestStreakOf` and the `Staked` / `Unstaked` / `StreakStarted` / `StreakEnded` events; nothing on-chain needs administering to change reward rules.

## Funding Stick-Time-Gated Rewards (Airdropper How-To)

`JBStickyDistributor` is permissionless to fund — anyone can seed a reward pot for any sticky token, either directly or through a project's payout/reserved-token splits. A criteria pot is keyed by `groupId = minWeeks * CRITERIA_BASE + maxWeeks`, `CRITERIA_BASE = 1000`. Three shapes cover the useful windows:

| Shape | Params | Example | Meaning |
| --- | --- | --- | --- |
| Tenure | `(minWeeks, 0)` | `4000` | stake aged 4+ weeks — `maxWeeks = 0` means unbounded |
| Recency | `(1, maxWeeks)` | `1004` | the last 4 completed weeks — the newest tranches only |
| Cohort | `(minWeeks, maxWeeks)` | `4008` | tranches deposited 4 to 8 weeks ago, no older and no younger |

`minWeeks` and `maxWeeks` each range over `[0, MAX_CRITERIA_WEEKS]` (520). `minWeeks >= 1` is required for every criteria pot — this is the single safety rule the encoding enforces: it keeps the current, still-incomplete epoch out of every window, so a criteria pot's stake buckets can never grow after the funding transaction (see ARCHITECTURE for why that matters). When `maxWeeks != 0` it must be `>= minWeeks`. The largest valid criteria `groupId` is `520520`. `groupId == 0` stays the everyone-pool, votes-weighted, unrelated to any window.

Two funding paths:

- **Direct funding:** call `fund(hook, token, amount, groupId)`, where `hook` is the sticky token address and `groupId` is the encoded window (or `0` for the everyone-pool, identical mechanics to the deployed `JBTokenDistributor`). An invalid `groupId` reverts (`JBStickyDistributor_InvalidCriteria`). The 3-arg `fund(hook, token, amount)` overload always targets group 0. For native ETH, send `msg.value` and pass `JBConstants.NATIVE_TOKEN` as `token`.
- **Split-funded (recipe):** configure a payout or reserved-token split with `hook` (the split's `hook` field) set to the `JBStickyDistributor` address, `beneficiary` set to the sticky token address, and `lockedUntil` set to the encoded `groupId` for your window (e.g. `4008` for a 4-to-8-week cohort). Project distribution calls (`sendPayoutsOf` / `sendReservedTokensToSplitsOf`) route the split through `processSplitWith`, which reads `lockedUntil` as the criteria: any value that decodes to a valid window funds that pot; `0` or a genuine lock timestamp falls through to the everyone-pool. A split cannot be both genuinely time-locked and criteria-carrying — pick one when configuring it.

**Bounded windows pay deposits, not persons.** A cohort or recency pot pays whatever tranches fall inside its window at fund time — not "whoever has been staking since week 4." A continuous staker who tops up every month holds tranches spread across many buckets; a `(4, 8)` pot pays only the slice they deposited in that stretch, and the rest of their position is invisible to it. Only a tenure pot (`maxWeeks = 0`) pays a staker's whole aged position. Configuring a `(4, 8)` pot to reward "loyal 4-to-8-week holders" instead rewards a deposit cohort that happens to have been made 4 to 8 weeks before this specific funding — fund it again next month and it rewards a different, newer cohort.

**Recency pots are acquisition instruments, not loyalty ones.** A recency window like `(1, 4)` is snipeable by construction: anyone can stake today and become "recent," but nobody can become "old" faster than time allows. `minWeeks >= 1` closes only the one hole that would break solvency (staking after the fund transaction in the same epoch); it does not and cannot stop someone from staking during the window in anticipation of an announced drop. That's legitimate participation, not an exploit, but it dilutes an intended "reward loyal recent stakers" cohort with newcomers. Recency pots suit unannounced or unpredictable funding, or campaigns that are explicitly trying to attract new stakers rather than reward existing ones.

**LIFO erodes recency fastest.** Every unstake consumes a holder's newest tranches first (see ARCHITECTURE). Under a tenure pot this shields the holder's aged weight — a partial unstake burns through fresh stake before it ever touches the tranches a tenure pot cares about. Under a recency pot the opposite holds: the eligible tranches are exactly the newest ones, so any partial unstake immediately cuts into what a recency claim would have paid. Cohort pots sit in between, depending on where the cohort's tranches fall relative to a holder's other stake. This doesn't affect solvency — claims can only shrink — but it's worth flagging to holders funding or claiming from recency pots.

**Windows are relative to each funding, not to a calendar.** Funding a `(4, 8)` pot every month rewards a sliding set of deposit cohorts, not a fixed one. There is no way to configure "everyone who staked in March, forever" — that would need absolute epoch bounds, which this encoding doesn't support.

## Stick-Time Reward Notes

- A `groupId` that isn't `0` and doesn't decode to a valid `(minWeeks, maxWeeks)` window reverts on direct `fund` (`JBStickyDistributor_InvalidCriteria`) — pots can't be created for criteria no claim path understands. **The split path does not revert on the same bad value — it silently funds the everyone-pool instead.** Any `lockedUntil` below `CRITERIA_BASE` (1000) decodes to `minWeeks == 0`, which is invalid; `processSplitWith` treats it exactly like an out-of-range value or a genuine lock timestamp and routes the funds to group 0. There is no error and no event distinguishing this from an intentional everyone-pool split. Double-check the encoded value before configuring a split — `k * 1000` for a bare week count `k` (e.g. `4000` for "4+ weeks"), never `k` alone — and confirm the resulting pot actually receives funds rather than assuming it did.
- The first funder of a (group, token, round) fixes that round's eligibility snapshot (the block for group 0, the stick-age epoch for criteria groups) — fund early in your intended round if snapshot timing matters to you.
- The first funding of a (group, token, round) triggers an on-chain epoch walk back to the sticky project's first stake (~2.1k gas per epoch, ~1.1M gas worst case for a 10-year-old project); the cost lands on the funder for direct `fund` calls, or on the caller of the distribution function for split-funded pots. Subsequent fundings of the same round are cheap.
- Group-0 (everyone) rewards behave byte-for-byte like the deployed `JBTokenDistributor` — same votes-snapshot mechanics, same claim/vesting model.
- Production deployments use 7-day rounds, alongside the 4 vesting rounds and 28-day claim window already noted in the README.
