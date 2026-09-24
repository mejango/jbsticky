# JBSticky

Sticky wraps an ERC-20 token in a permanently configured Juicebox V6 staking project. Deposits issue 18-decimal Sticky shares of the project's backing. Holders accumulate a streak while their share balance remains positive; each deposit also retains its own timestamp. Projects choose a permanent cash out tax and whether shares are soulbound or transferable.

Sticky shares are not a promise to redeem one underlying token each. Their issuance and redemption depend on share-owned backing, rounding, the configured cash out curve, and applicable Juicebox terminal fees. There is no time lock. A 100% cash out tax makes redemption return zero underlying tokens, including a full exit.

## Documentation

- [Production review](AUDIT_REPORT.md): findings, fixes, validation, and remaining release limits.

- [ARCHITECTURE.md](./ARCHITECTURE.md) — contracts, accounting flows, and trust boundaries.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — launch, stake, exit, rewards, and compounding.
- [INVARIANTS.md](./INVARIANTS.md) — guarantees to preserve across contract changes.
- [RISKS.md](./RISKS.md) — economic limits, dependencies, and operational failure modes.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — permanent settings, holder controls, and recovery limits.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — review scope, attack sequences, and verification commands.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — the shared V6 Solidity and documentation conventions.
- [DEPLOYMENT.md](./DEPLOYMENT.md) — Sphinx deployment and verification on testnets and mainnets.
- [webclient/README.md](./webclient/README.md) — site configuration and transaction checks.
- [AUDIT_REMEDIATION.md](./AUDIT_REMEDIATION.md) — historical review findings and validation at those revisions.

## Issuance and backing

For an existing supply, a deposit of `A` underlying atoms issues `floor(A × S / E)` Sticky share atoms, where `S` is the outstanding share supply and `E` is the backing belonging to those shares. `JBStickyHook` supplies the numerator and the project's immutable `JBStickyPriceFeed` supplies the exact backing denominator through the core price registry. The feed reads project accounting; it is not an external market oracle. Core performs a full-precision division without first rounding an exchange rate.

When no shares exist, issuance starts at one share per whole underlying token, normalized to 18 decimals. No virtual shares or virtual backing are created. The supported underlying accounting precision is 0–36 decimals. The terminal's accounting precision is fixed at launch and the feed caches it.

A bootstrap payment must issue at least `1e12` share atoms, one millionth of a Sticky share. At bootstrap this corresponds to one millionth of a whole underlying token; later backing changes the exchange rate. Burns and cash outs can leave any remaining supply, so another holder's dust cannot force someone to retain a position. If supply becomes tiny and backing per share atom becomes large, the issuance rounding guard can reject small deposits. A rejected payment reverts without donating the deposit; quote the intended amount before staking.

Share issuance rounds down. A deposit that would mint zero shares, or lose more than one basis point to share rounding, is rejected atomically. The rounding guard is conservative against the ceiling of the ideal issuance; it does not bound cash out rounding or fees. Use `JBMultiTerminal.previewPayFor(...)` with the actual payer and beneficiary, then protect `pay(...)` with a nonzero `minReturnedTokens`. A zero preview means the amount cannot currently be issued within that guard.

Donations and retained cash out tax increase existing holders' backing per share. New deposits buy shares at that updated price instead of immediately capturing earlier holders' surplus. Voluntarily burning shares also leaves backing to remaining holders.

Backing present when the share supply is zero has no owners. The next positive stake permanently excludes that balance as `orphanedBalanceOf(projectId)`; later shares cannot redeem it. This includes donations to an empty project and funds left after the last holder burns without redeeming. While supply is zero, all current backing is unowned, including amounts received since the stored orphaned balance was last updated. Sticky exposes no owner withdrawal or recovery path for these funds.

## Positions, transfers, and exits

Pay the project through `JBMultiTerminal.pay(...)` using its accepted underlying token. Self-stakes are allowed. Staking for someone else requires either a permanent launch-time granter or a sender trusted by that beneficiary through `setTrustedSenderFor(...)`. A beneficiary can change their personal trusted senders; they cannot revoke permanent granters.

The holder's streak starts at their first positive share balance and ends only when that balance reaches zero. Adding a deposit never backdates its tranche or restarts an existing holder streak. Newest tranches are consumed first; a partially consumed tranche keeps its timestamp.

Use `JBMultiTerminal.cashOutTokensOf(...)` to redeem. Zero cash out tax gives a proportional share of claimable backing before applicable terminal fees. Positive tax below the maximum uses the standard Juicebox cash out curve: its effect depends on the fraction of supply redeemed, rather than being a flat deduction in every case. The terminal's `previewCashOutFrom(...)` returns gross reclaim before its terminal fee; calculate the net amount for the actual beneficiary and set `minTokensReclaimed` accordingly. Unless the beneficiary is feeless, non-zero tax makes the whole reclaim subject to the protocol's 2.5% cash out fee, rounded down. With zero tax, only reclaim covered by the project's `feeFreeSurplusOf` is fee-eligible. If fee routing fails, the withheld fee returns to the project's backing, not to the exiting beneficiary, and becomes orphaned if no shares remain.

Every positive share burn updates the hook from the token's authoritative balance-change path, including voluntary controller burns. Cash outs do not consume the same tranches twice. A voluntary burn returns no underlying tokens. In transferable mode, a positive transfer consumes the sender's newest tranches and creates a fresh tranche for the recipient; their existing holder streak continues if they already had a balance. Zero transfers and self-transfers do not change Sticky accounting. Soulbound mode rejects transfers between nonzero addresses. Transfers are not gated by granters or trusted senders: in transferable mode anyone holding shares can give some to any address, which starts or extends that address's position with the giver's own value. Projects that want positions to be opt-in should deploy soulbound.

Stakes that join a position in the same week as its newest tranche merge into that tranche, which takes the latest timestamp; a stake in a later week starts a new tranche. Every active tranche therefore sits in a distinct week. Partial exits use indexed tranche balances and binary search, and every consumed tranche debits the epoch bucket it was credited to, so an exit's cost grows with the number of distinct weeks it consumes rather than with the number of deposits: incoming same-week dust cannot make an exit traverse every transfer, while a ten-year weekly position exits in about 3.3M gas. For reads, use `trancheCountOf(...)` and the bounded `tranchesOf(projectId, holder, start, count)` overload, capped at 256 entries. The original whole-array getter remains available but is unbounded. The webclient reads pages of 50 at a pinned block.

Balance and streak views include `stakedBalanceOf`, `streakStartOf`, `currentStreakOf`, and `longestStreakOf`. `Staked` and `Unstaked` describe share-accounting changes, including transfers and burns; an `Unstaked` event alone is not proof of an underlying-token payout.

## Rewards and auto-stick

The configured reward path is `JBStickyDistributor`, a subclass of [`JBDistributor`](https://github.com/Bananapus/nana-distributor-v6) bound to the Sticky hook. Anyone can fund rewards for a Sticky token and chooses, per funding, who the pot rewards:

- **Group 0** allocates by holders' share-vote checkpoints at the round's snapshot block, exactly like `JBTokenDistributor`. Sticky tokens automatically self-delegate and prohibit delegation changes, keeping reward voting units with the holder.
- **Tenure groups**, encoded as `groupId = minWeeks * 1000 + maxWeeks` (both at most 520, `minWeeks` at least 1, `maxWeeks` 0 for no upper bound), allocate by the stake each holder still holds in tranches created between `maxWeeks` and `minWeeks` weeks before the round started. `4000` rewards stake at least four weeks old; `1004` rewards the last four completed weeks; `4008` rewards stake between four and eight weeks old. `isValidGroupId(groupId)` reports whether an encoding is accepted.

A tenure round's window is measured from `snapshotEpochOf(round)`, the week the round started in, so every funding of a round weighs the same tranches whenever it lands. The denominator is read from the hook's per-week net stake buckets when the round is first funded; because tranches only ever join the current week and `minWeeks` is at least one, nothing staked after that read can enter the window, and holders who exit only shrink their own claim. A holder's claim reads their live tranches through `stakedBalanceThroughEpochOf`, so tenure rewards must be claimed while the tranches are still held; shares forfeited by exiting stay in the pot and recycle after the claim window, which the distributor requires to be non-zero so a forfeited pot always recycles. Tenure is whole-week granular: a stake made earlier in the same week as a round start is not yet one week old for that round.

Group 0 shares `roundSnapshotBlock(round)` across every Sticky token the distributor serves. The first positive funding or receiver settlement records the current round's snapshot at `block.number - 1` if it is unset. Permissionless `poke()` also records the following round if unset. Buying after a pinned block earns no group-0 allocation for that round; exiting after it does not remove the allocation. A holder can stake for one block, call `poke()` in the next block, exit, and retain a share of group-0 rewards funded into both pinned rounds. Zero tax can make that stake/redeem round trip fee-free; non-zero tax raises its cost but does not prevent capture. Transferable shares can also be temporarily acquired and returned without redeeming or paying a cash out tax. Funders who want tenure-based allocation should fund a tenure group instead, which a one-block position cannot enter.

Payout and reserved-token splits fund the distributor with `hook = distributor`, `beneficiary = stickyToken`, and the group encoded in `split.projectId`, which core never reads while the split's hook is set; a split can be locked and group-carrying at once. A `projectId` that is not a valid group, or a beneficiary the hook does not track, funds group 0 rather than reverting. Direct `fund(hook, token, amount, groupId)` reverts on an invalid group or, for tenure groups, an unregistered token. Point a reserved-token split at the distributor only after the source project has deployed its ERC-20: the controller moves credits to the hook before calling it, and credits that reach the distributor are stranded.

Rewards vest over rounds. `collectVestedRewards(...)` collects unlocked rewards and starts vesting eligible earlier allocations; `beginVesting(...)` is available when only starting the schedule is needed; both take an optional `groupId`. A Sticky token funded as a reward gives the distributor itself weight in that token's rounds; collecting that allocation to the distributor recycles it into the current round of the same pot instead of transferring, and holders cannot collect their own rewards to the distributor. The production deployment script configures weekly rounds, four vesting rounds, a two-year claim window, and no distributor loan integration. The design record is [`docs/specs/2026-09-24-tenure-rewards.md`](docs/specs/2026-09-24-tenure-rewards.md).

`JBStickyAutoStick` can collect a holder's unlocked underlying-token rewards from the reward groups the caller names, listed once each in ascending order, pull only the newly delivered amount, and stake them back for that holder. `statusOf` rejects a group the distributor cannot serve instead of reporting it ready. The holder's minimum applies to the combined amount across those groups. Automatic execution requires the holder's enabled configuration, cooldown, minimum reward threshold, allowance, and hook permission. A holder can also call `stickRewardsFor(...)` without enabling automatic execution. Both paths quote the terminal during execution, reject zero issuance, require the exact quoted token minimum, and reject unexpected underlying transfer deltas. They cannot redirect rewards to a keeper or arbitrary beneficiary.

Auto-stick is best effort. The distributor permits anyone to collect to the holder's canonical beneficiary first. Those tokens arrive safely in the holder's wallet, but a later keeper may find nothing to compound. The holder can stake those funds manually. UI estimates can change before execution; the adapter's quote is taken during the actual transaction.

For cross-chain rewards, `JBStickyRewardReceiverFactory` predicts and deploys a `JBStickyRewardReceiver` for each destination Sticky token and reward group. Separate receiving addresses keep arrivals attributed to the intended reward pool and weighting. Rewards may arrive before that receiver is deployed; anyone can call `settleFor(...)` to fund the distributor with its ERC-20 balance. Transport requires a supported bridge route for the reward token, independently of the Sticky project. Identical receiver addresses across chains require identical factory/distributor addresses, creation code, the same destination Sticky-token address, and the same group; using common salts alone does not establish parity. Share tokens are deployed with CREATE2 under a salt bound to the launcher and the launch arguments, and `predictStickyTokenOf(launcher, projectId, ...)` returns the address a launch produces; the project ID is part of the token's creation code, so predict against the ID the launch will receive, or route rewards after the launch confirms. See [the architecture rationale](ARCHITECTURE.md#why-a-receiver-and-a-factory) for the receiver/factory split and the per-project price feed.

## Contracts

| Contract | Role |
| --- | --- |
| `JBStickyDeployer` | Launches projects and their share tokens/price feeds; holds each project NFT without exposing project mutation or withdrawal operations. |
| `JBStickyHook` | Prices issuance, excludes orphaned backing, and tracks exact balances, LIFO tranches, and streaks. |
| `JBStickyPriceFeed` | Immutable per-project accounting denominator for exact backing-priced issuance. |
| `JBStickyToken` | Configurably soulbound ERC-20 shares with locked self-delegation and authoritative burn/transfer reporting. |
| `JBStickyDistributor` | Round-based reward distributor: vote-checkpoint allocation for group 0 and tenure-window allocation for funder-chosen groups. |
| `JBStickyAutoStick` | Opt-in reward collection and compounding for the same holder and project across chosen reward groups. |
| `JBStickyRewardReceiverFactory` | Predicts/deploys reward receivers per Sticky token and group and settles their balances into the distributor. |
| `JBStickyRewardReceiver` | Holds arriving reward tokens for one destination Sticky token and group and its bound distributor. |

Project rules do not expire. Reserved issuance and fund access limits are zero. The factory retains no callable path to change project rules, metadata, token, controller, terminals, price feed, or ownership after launch. Core flags needed to attach the custom token and feed are enabled during construction; immutability follows from the factory's exposed operations, not a claim that every metadata flag is disabled. These contracts still depend on the configured core release and the underlying token's behavior.

## Develop and check

Use Node 22.23.1, Foundry v1.8.1, and the committed npm lockfile. Contract development uses the V6 workspace layout: this repository at `extensions/JBSticky`, with `nana-core-v6` and `nana-distributor-v6` at the workspace root. Their `file:` dependencies are intentional. [Contract CI](.github/workflows/test.yml) records the tested dependency commits and reconstructs that layout.

```sh
npm ci
forge fmt --check
forge test
npm run test:deployment
forge build --sizes --skip '*/test/**' --skip '*/script/**' --skip SphinxUtils
forge build --skip '*/test/**'
```

The tests cover accounting invariants and adversarial dust, direct burns, share pricing and orphaned backing, rounding/decimal boundaries, reward compounding, and deployment restart/verification behavior. The repository also runs Slither and webclient checks in CI. Passing local checks is not evidence that contracts have been deployed or that a particular target chain's dependencies have been verified.

Run `STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork` for the
[real-project fork suites](test/fork/README.md): Base `6` (Artizen), Ethereum `3`
(Revnet Network), and Ethereum `3` rewards through its deployed Base sucker route.
They require archive RPC access and exercise real project tokens and payment
contracts. The cross-chain suite models portal delivery at the live messenger
boundary; its precise scope and pinned blocks are documented with the tests.

See [the webclient guide](webclient/README.md) for local demo setup, configuration, and browser/server checks.

## Deploy

Follow [DEPLOYMENT.md](DEPLOYMENT.md) for the complete Sphinx workflow, eight RPC aliases, trusted core artifacts, credentials, and post-execution verification. Production scripts use the canonical CREATE2 factory and reuse existing deployments only after checking runtime code and immutable bindings. They fail on unexpected code or configuration.

```sh
# Load the intended RPC configuration and rehearse without broadcasting:
npm run deploy:rehearse -- --rpc-url ethereum_sepolia -vv

# Create a Sphinx proposal for review and execution through the existing process:
npm run deploy:propose:testnets
# npm run deploy:propose:mainnets

# After execution, verify the reviewed suite against the live chain:
npm run deploy:verify -- --rpc-url ethereum_sepolia -vv
```

Use `deploy:rehearse:testnets` / `deploy:rehearse:mainnets` to rehearse whole groups,
and `deploy:post:testnets` / `deploy:post:mainnets` to verify them after Sphinx execution and write the
explorer-verified per-contract artifacts.
Grouped proposal commands rehearse every destination before collecting a proposal.
Set `STICKY_ENV_FILE=../../deploy-all-v6/.env` to reuse the workspace credentials.
Repeat rehearsals and verification for every intended network. `simulation.json` describes simulated state; only post-execution verification produces `verified.json`. Retain executed Sphinx receipts and publish the verified release artifacts before configuring a live client. The site should remain in demo mode until its addresses and target-chain transaction flows have been checked. Source changes produce new deployment predictions and do not upgrade existing immutable Sticky projects.
