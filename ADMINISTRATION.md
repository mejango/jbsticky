# Administration

## At A Glance

| Item | What To State |
| --- | --- |
| Scope | `JBStickyDeployer`, `JBStickyHook`, `JBStickyPriceFeed`, `JBStickyToken`, `JBStickyAutoStick`, `JBStickyRewardPockets`, and every sticky project launched through them |
| Control posture | Permissionless deployment; immutable after construction; sticky projects are deployer-owned with no mutable surface |
| Highest-risk actions | `deployStickyFor` (irreversible per-project parameters: underlying token, cash out tax, transfer mode, granters) |
| Recovery posture | No in-place correction. A misconfigured sticky project is abandoned and a new one deployed; holders can always cash out their share of the backing under the launch-time curve |

## Purpose

Nobody can change behavior after deployment. The deployer contract owns every sticky project it launches and exposes exactly one external transaction, `deployStickyFor`, so the owner powers that Juicebox grants a project owner (queue rulesets, send payouts, set metadata, set a token or price feed, transfer the project NFT) are permanently unexercisable. The admin surface is deployment-time only: everything a sticky project will ever do is fixed by the arguments to its launch call.

## Control Model

- Permissionless: anyone can deploy a sticky project for any ERC-20 with `decimals()` by paying the `JBProjects` creation fee.
- Immutable after construction: no Sticky contract has an owner, an upgrade path, or a parameter setter reachable after a project's launch transaction completes. Holders own two per-position settings: their trusted senders on the hook and their auto-stick configuration on the adapter.
- Deployer-controlled in name only: the deployer holds each project NFT forever; `JBPermissions` delegation never comes into play because the owner account is a contract with no permission-granting surface.

## One-Way Doors

- **Launching a sticky project.** The underlying token and its accounting context, the eternal ruleset (backing-priced issuance through the hook and feed, launch-time cash out tax, no payouts, no migration), the share token's name, symbol and transfer mode, and the granter list are permanent. There is no fix for a wrong parameter besides deploying a fresh project.
- **Attaching the share token and feed.** `setTokenFor` and `addPriceFeedFor` are called once at launch; the ruleset flags that permit them stay on, but only the owner can call them and the owner exposes no such call.
- **Choosing granters.** The launch-time granter list is permanent; a forgotten grant program address can still reach holders who individually trust it, but cannot airdrop to everyone. Unauthorized third-party stakes revert.
- **Orphaned backing.** Backing present while the share supply is zero, including donations to an empty project and anything left after the last holder burns without redeeming, is excluded from every later share and cannot be recovered by anyone.

## Operational Notes

- The project creation fee (`JBProjects.creationFee()`) must be sent exactly as `msg.value` to `deployStickyFor`.
- Fee-on-transfer or rebasing tokens must not be used as underlying tokens: pricing assumes the terminal's recorded balance equals what was paid, and the adapter reverts on any transfer delta mismatch.
- A cash out tax at the maximum makes every redemption, including a full exit, return zero underlying tokens. Any non-zero tax subjects reclaims to the protocol's cash out fee.
- The production reward path is one shared `JBTokenDistributor` per chain, configured in `script/helpers/JBStickyDeployment.sol`: 7-day rounds, 4 vesting rounds, a 3-year claim window, loans disabled. These are constructor arguments and cannot be changed without deploying a new distributor and adapter. Its round snapshots are shared by every sticky token on the chain and are age-blind; see the README's rewards section before promising tenure-based rewards through it.
- Reward programs read `tranchesOf` (paginated), `stakedBalanceOf`, `currentStreakOf`, `longestStreakOf`, and the `Staked`, `Unstaked`, `StreakStarted`, `StreakEnded` events; nothing on-chain needs administering to change reward rules.
