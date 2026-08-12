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

`JBStickyDistributor` is permissionless to fund — anyone can seed a reward pot for any sticky token, either directly or through a project's payout/reserved-token splits. Two funding paths:

- **Direct funding:** call `fund(hook, token, amount, groupId)`, where `hook` is the sticky token address and `groupId` is the criteria — `0` for the votes-weighted everyone-pool (identical mechanics to the deployed `JBTokenDistributor`), or `1`–`520` for "stuck at least `k` weeks", with `k = groupId`. The 3-arg `fund(hook, token, amount)` overload always targets group 0. For native ETH, send `msg.value` and pass `JBConstants.NATIVE_TOKEN` as `token`.
- **Split-funded (recipe):** configure a payout or reserved-token split with `hook` (the split's `hook` field) set to the `JBStickyDistributor` address, `beneficiary` set to the sticky token address, and `lockedUntil` set to the desired `k` in `[1, 520]`. Project distribution calls (`sendPayoutsOf` / `sendReservedTokensToSplitsOf`) route the split through `processSplitWith`, which reads `lockedUntil` as the criteria: `1`–`520` maps to threshold group `k = lockedUntil`; `0` or any other value (a genuine lock timestamp) falls through to group 0 rather than reverting. A split cannot be both genuinely time-locked and criteria-carrying — pick one when configuring it.

## Stick-Time Reward Notes

- `groupId` above `520` reverts (`JBStickyDistributor_InvalidCriteria`) — pots can't be created for criteria no claim path understands yet. A split's out-of-range `lockedUntil` does not revert: `processSplitWith` routes it to group 0 instead, per the split-funded recipe above.
- The first funder of a (group, token, round) fixes that round's eligibility snapshot (the block for group 0, the stick-age epoch for criteria groups) — fund early in your intended round if snapshot timing matters to you.
- The first funding of a (group, token, round) triggers an on-chain epoch walk back to the sticky project's first stake (~2.1k gas per epoch, ~1.1M gas worst case for a 10-year-old project); the cost lands on the funder for direct `fund` calls, or on the caller of the distribution function for split-funded pots. Subsequent fundings of the same round are cheap.
- Group-0 (everyone) rewards behave byte-for-byte like the deployed `JBTokenDistributor` — same votes-snapshot mechanics, same claim/vesting model.
- Production deployments use 7-day rounds, alongside the 4 vesting rounds and 28-day claim window already noted in the README.
