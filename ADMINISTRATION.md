# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Sticky contracts, their reward distributor, and every project launched by `JBStickyDeployer` |
| Control posture | Permissionless deployment; immutable after construction; sticky projects are deployer-owned with no mutable surface |
| Highest-risk actions | `deployStickyFor` (irreversible per-project parameters: underlying token, cash out tax, transfer mode, granters) |
| Recovery posture | Replacement deployment for incorrect permanent settings. Redemption remains subject to tax, fees, and token behavior; maximum tax returns zero |

## Purpose

Sticky exposes no project administration after launch. The deployer owns every project it launches and its only external transaction is `deployStickyFor`. It cannot queue rulesets, send payouts, set metadata, replace a token or price feed, delegate permissions, or transfer the project NFT. This limits the factory's owner powers; it does not remove core's protocol controls or the underlying token's administration.

## Control model

- Permissionless: anyone can launch with an ERC-20 that exposes supported accounting precision (0–36 decimals) and a nonzero currency ID derived from its address, by paying the `JBProjects` creation fee. This validates configuration, not the safety of the underlying token.
- Immutable project settings: Sticky contracts have no administrator or upgrade path. Holders can update their trusted senders on the hook and their auto-stick configuration on the adapter; ERC-20 allowances remain separate wallet controls.
- Deployer-controlled in name only: the deployer holds each project NFT forever; `JBPermissions` delegation never comes into play because the owner account is a contract with no permission-granting surface.
- Core dependency: `JBController.OMNICHAIN_RULESET_OPERATOR` can queue rulesets without the factory's permission. The canonical omnichain deployer checks the project owner's permissions itself. Verify its implementation and the controller binding on each network; Sticky's zero-duration ruleset and absent approval hook do not provide a second guard against an incorrect operator.
- Protocol controls: the core project creation fee, feeless-address configuration, and default price-feed routing retain their core authority model. The underlying ERC-20 may separately have minting, freezing, or upgrade powers. See [RISKS.md](./RISKS.md).

## One-way decisions

- **Launching a sticky project.** The underlying token and its accounting context, the eternal ruleset (backing-priced issuance through the hook and feed, launch-time cash out tax, no payouts, no migration), the share token's name, symbol and transfer mode, and the granter list are permanent. There is no fix for a wrong parameter besides deploying a fresh project.
- **Attaching the share token and feed.** `setTokenFor` and `addPriceFeedFor` are called once at launch; the ruleset flags that permit them stay on, but only the owner can call them and the owner exposes no such call.
- **Choosing granters.** The launch-time granter list is permanent; a forgotten grant program address can still reach holders who individually trust it, but cannot airdrop to everyone. Unauthorized third-party stakes revert.
- **Orphaned backing.** Backing present while the share supply is zero, including donations to an empty project and anything left after the last holder burns without redeeming, is excluded from every later share and cannot be recovered by anyone.

## Operational notes

- The project creation fee (`JBProjects.creationFee()`) must be sent exactly as `msg.value` to `deployStickyFor`.
- Fee-on-transfer or rebasing tokens must not be used as underlying tokens: pricing assumes the terminal's recorded balance equals what was paid, and the adapter reverts on any transfer delta mismatch.
- A cash out tax at the maximum makes every redemption, including a full exit, return zero underlying tokens. Non-zero tax subjects the whole reclaim to the terminal fee unless its beneficiary is feeless. Zero-tax cash outs can still owe a fee against the project's fee-free surplus balance; use the net amount in transaction minimums.
- Bootstrap payments must issue at least `1e12` share atoms. Burns and cash outs impose no minimum remaining supply. Very small supplies and donated backing can make later small deposits unissuable within the rounding guard.
- The production reward path is one shared `JBTokenDistributor` per chain, configured in `script/helpers/JBStickyDeployment.sol`: 7-day rounds, 4 vesting rounds, a 3-year claim window, loans disabled. These are constructor arguments and cannot be changed without deploying a new distributor and adapter. Its round snapshots are shared by every sticky token on the chain and are age-blind; see the README's rewards section before promising tenure-based rewards through it.
- Reward programs read `tranchesOf` (paginated), `stakedBalanceOf`, `currentStreakOf`, `longestStreakOf`, and the `Staked`, `Unstaked`, `StreakStarted`, `StreakEnded` events; nothing on-chain needs administering to change reward rules.
- Disabling auto-stick requires a valid nonzero minimum and a cooldown between one and thirty days. It preserves the last-compounded timestamp. Revoke the adapter's ERC-20 allowance separately if it is no longer wanted; revoking personal trust cannot override a permanent project granter.
- There is no Sticky pause, asset rescue, forced migration, or orphaned-fund recovery operation. Follow [DEPLOYMENT.md](./DEPLOYMENT.md) for new releases and [USER_JOURNEYS.md](./USER_JOURNEYS.md) for holder actions.
