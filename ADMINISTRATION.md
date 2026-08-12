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
