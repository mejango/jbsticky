# JBSticky

Sticky wraps an ERC-20 token in a permanently configured Juicebox V6 staking project. Deposits issue 18-decimal Sticky shares of the project's backing. Holders accumulate a streak while their share balance remains positive; each deposit also retains its own timestamp. Projects choose a permanent cash out tax and whether shares are soulbound or transferable.

Sticky shares are not a promise to redeem one underlying token each. Their issuance and redemption depend on share-owned backing, rounding, the configured cash out curve, and applicable Juicebox terminal fees. There is no time lock. A 100% cash out tax makes redemption return zero underlying tokens, including a full exit.

## Issuance and backing

For an existing supply, a deposit of `A` underlying atoms issues `floor(A × S / E)` Sticky share atoms, where `S` is the outstanding share supply and `E` is the backing belonging to those shares. `JBStickyHook` supplies the numerator and the project's immutable `JBStickyPriceFeed` supplies the exact backing denominator through the core price registry. The feed reads project accounting; it is not an external market oracle. Core performs a full-precision division without first rounding an exchange rate.

When no shares exist, issuance starts at one share per whole underlying token, normalized to 18 decimals. No virtual shares or virtual backing are created. The supported underlying accounting precision is 0–36 decimals. The terminal's accounting precision is fixed at launch and the feed caches it.

The share supply is either zero or at least `1e12` atoms, one millionth of a whole underlying token. A bootstrap deposit below that previews zero and reverts, and a burn or cash out that would leave a positive supply below it reverts; emptying the supply is always allowed. Without the floor a sole holder could burn down to one share atom, donate backing, and make every later deposit revert unless it was an exact multiple of the inflated atom price.

Share issuance rounds down. A deposit that would mint zero shares, or lose more than one basis point to share rounding, is rejected atomically. The rounding guard is conservative against the ceiling of the ideal issuance; it does not bound cash out rounding or fees. Use `JBMultiTerminal.previewPayFor(...)` with the actual payer and beneficiary, then protect `pay(...)` with a nonzero `minReturnedTokens`. A zero preview means the amount cannot currently be issued within that guard.

Donations and retained cash out tax increase existing holders' backing per share. New deposits buy shares at that updated price instead of immediately capturing earlier holders' surplus. Voluntarily burning shares also leaves backing to remaining holders.

Backing present when the share supply is zero has no owners. The next positive stake permanently excludes that balance as `orphanedBalanceOf(projectId)`; later shares cannot redeem it. This includes donations to an empty project and funds left after the last holder burns without redeeming. While supply is zero, all current backing is unowned, including amounts received since the stored orphaned balance was last updated. Sticky exposes no owner withdrawal or recovery path for these funds.

## Positions, transfers, and exits

Pay the project through `JBMultiTerminal.pay(...)` using its accepted underlying token. Self-stakes are allowed. Staking for someone else requires either a permanent launch-time granter or a sender trusted by that beneficiary through `setTrustedSenderFor(...)`. A beneficiary can change their personal trusted senders; they cannot revoke permanent granters.

The holder's streak starts at their first positive share balance and ends only when that balance reaches zero. Adding a deposit never backdates its tranche or restarts an existing holder streak. Newest tranches are consumed first; a partially consumed tranche keeps its timestamp.

Use `JBMultiTerminal.cashOutTokensOf(...)` to redeem. Zero cash out tax gives a proportional share of claimable backing before applicable terminal fees. Positive tax uses the standard Juicebox cash out curve: its effect depends on the fraction of supply redeemed, rather than being a flat deduction in every case. Use the terminal's live quote and a reviewed minimum reclaim. Any non-zero tax costs the exiting holder the protocol's 2.5% cash out fee on every reclaim, even when the fee project cannot receive the underlying token; in that case the fee is returned to the project's balance for remaining holders, and becomes orphaned if the last holder leaves. Zero tax takes no fee unless the project received fee-free funds through the terminal's project-to-project routes.

Every positive share burn updates the hook from the token's authoritative balance-change path, including voluntary controller burns. Cash outs do not consume the same tranches twice. A voluntary burn returns no underlying tokens. In transferable mode, a positive transfer consumes the sender's newest tranches and creates a fresh tranche for the recipient; their existing holder streak continues if they already had a balance. Zero transfers and self-transfers do not change Sticky accounting. Soulbound mode rejects transfers between nonzero addresses. Transfers are not gated by granters or trusted senders: in transferable mode anyone holding shares can give some to any address, which starts or extends that address's position with the giver's own value. Projects that want positions to be opt-in should deploy soulbound.

Partial exits use indexed tranche balances and binary search; full exits clear the active position without iterating over old tranches. Incoming dust therefore cannot force an exit to traverse every deposit. For reads, use `trancheCountOf(...)` and the bounded `tranchesOf(projectId, holder, start, count)` overload, capped at 256 entries. The original whole-array getter remains available but is unbounded. The webclient reads pages of 50 at a pinned block.

Balance and streak views include `stakedBalanceOf`, `streakStartOf`, `currentStreakOf`, and `longestStreakOf`. `Staked` and `Unstaked` describe share-accounting changes, including transfers and burns; an `Unstaked` event alone is not proof of an underlying-token payout.

## Rewards and auto-stick

The configured reward path uses [`JBTokenDistributor`](https://github.com/Bananapus/nana-distributor-v6). Anyone can fund rewards for a Sticky token. Allocations use holders' share-vote checkpoints at a round's snapshot, not tranche age or the holder's streak length. Sticky tokens automatically self-delegate and prohibit delegation changes, keeping reward voting units with the holder.

The snapshot timing is a property of the distributor, not of Sticky. A round's snapshot block is `block.number - 1` at the first interaction with that round on the whole distributor, and that interaction also pins the following round. Any funding of any sticky token, any settle, and the permissionless `poke()` count as interactions. So a holder's share of a round is their balance at one past block that anyone could have pinned; shares bought after that block earn nothing for the round and, at the maximum, the one after it; shares sold after that block still earn both. On a zero-tax project the round trip is fee-free, so a one-block stake before the pin captures a proportional share of everything funded into those two rounds. Funders can read `roundSnapshotBlock(round)` before funding. Projects that expect meaningful reward rounds should set a non-zero cash out tax, or use an age-gated distributor.

Rewards vest over rounds. `collectVestedRewards(...)` collects unlocked rewards and starts vesting eligible earlier allocations; `beginVesting(...)` is available when only starting the schedule is needed. The production deployment script configures weekly rounds, four vesting rounds, a three-year claim window, and no distributor loan integration. Historical age-gated distributor plans under `docs/` are separate proposals, not this configured reward path.

`JBStickyAutoStick` can collect a holder's unlocked underlying-token rewards, pull only the newly delivered amount, and stake them back for that holder. Automatic execution requires the holder's enabled configuration, cooldown, minimum reward threshold, allowance, and hook permission. A holder can also call `stickRewardsFor(...)` without enabling automatic execution. Both paths quote the terminal during execution, reject zero issuance, require the exact quoted token minimum, and reject unexpected underlying transfer deltas. They cannot redirect rewards to a keeper or arbitrary beneficiary.

Auto-stick is best effort. The distributor permits anyone to collect to the holder's canonical beneficiary first. Those tokens arrive safely in the holder's wallet, but a later keeper may find nothing to compound. The holder can stake those funds manually. UI estimates can change before execution; the adapter's quote is taken during the actual transaction.

For cross-chain rewards, `JBStickyRewardPockets` predicts a pocket for a destination Sticky token. Rewards may arrive before that pocket is deployed; anyone can call `settleFor(...)` to fund the distributor with its ERC-20 balance. Transport requires a supported bridge route for the reward token, independently of the Sticky project. Identical pocket addresses across chains require identical factory/distributor addresses, creation code, and the same destination Sticky-token address; using common salts alone does not establish parity.

## Contracts

| Contract | Role |
| --- | --- |
| `JBStickyDeployer` | Launches projects and their share tokens/price feeds; holds each project NFT without exposing project mutation or withdrawal operations. |
| `JBStickyHook` | Prices issuance, excludes orphaned backing, and tracks exact balances, LIFO tranches, and streaks. |
| `JBStickyPriceFeed` | Immutable per-project accounting denominator for exact backing-priced issuance. |
| `JBStickyToken` | Configurably soulbound ERC-20 shares with locked self-delegation and authoritative burn/transfer reporting. |
| `JBStickyAutoStick` | Opt-in reward collection and compounding for the same holder and project. |
| `JBStickyRewardPockets` | Predicts/deploys reward pockets and settles their balances into the distributor. |
| `JBStickyRewardPocket` | Holds arriving reward tokens for one destination Sticky token and its bound distributor. |

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

See [the webclient guide](webclient/README.md) for local demo setup, configuration, and browser/server checks.

## Deploy

Follow [DEPLOYMENT.md](DEPLOYMENT.md) for the complete Sphinx workflow, eight RPC aliases, trusted core artifacts, credentials, and post-execution verification. Production scripts use the canonical CREATE2 factory and reuse existing deployments only after checking runtime code and immutable bindings. They fail on unexpected code or configuration.

```sh
# Load the intended RPC configuration and rehearse without broadcasting:
npm run deploy:rehearse -- --rpc-url ethereum_sepolia -vv

# Create a Sphinx proposal for review and execution through the existing process:
npm run deploy:testnets
# npm run deploy:mainnets

# After execution, verify the reviewed suite against the live chain:
npm run deploy:verify -- --rpc-url ethereum_sepolia -vv
```

Repeat rehearsals and verification for every intended network. `simulation.json` describes simulated state; only post-execution verification produces `verified.json`. Retain executed Sphinx receipts and publish the verified release artifacts before configuring a live client. The site should remain in demo mode until its addresses and target-chain transaction flows have been checked. Source changes produce new deployment predictions and do not upgrade existing immutable Sticky projects.
