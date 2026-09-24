# Architecture

## Purpose

`@bananapus/sticky-v6` lets holders of an ERC-20 lock it into a permanently configured Juicebox V6 project in exchange for Sticky shares of that project's backing, while recording per-deposit amounts and timestamps and a per-holder streak that off-chain reward programs can trust.

The value the system protects is the backing allocated to outstanding shares. A holder or their authorized operator can redeem through the terminal under the launch-time cash out curve and applicable fees. Maximum tax returns zero even when redeeming the whole supply. These guarantees depend on the configured core contracts and a supported underlying token.

## System Overview

The package owns a deployer that launches locked projects, a singleton data hook that prices issuance and does position accounting, a per-project price feed that gives core the exact issuance denominator, and a per-project share token. It composes `nana-core-v6` for everything economic: `JBMultiTerminal` custodies the underlying tokens, `JBController`/`JBRulesets` enforce the eternal ruleset, `JBPrices` routes the feed, and `JBTokens` mints and burns the share token. Rewards go through `StickyDistributor`, a subclass of `JBDistributor` from `nana-distributor-v6` that keeps the token distributor's vote-checkpoint allocation as group 0 and adds funder-chosen tenure groups weighed by the hook's tranches, with two optional helpers: an opt-in compounding adapter and cross-chain reward receivers.

## Core Invariants

- **Backing-priced issuance, never dilutive**: a deposit of `A` underlying atoms issues `floor(A × S / E)` share atoms, where `S` is the outstanding supply and `E` is the backing owned by shares. `StickyHook.beforePayRecordedWith` returns `S` as the weight and `StickyPriceFeed` returns `E` as the price, so core computes the ratio without rounding an exchange rate first. The after-pay callback re-derives the expected count from the authenticated snapshot and rejects any mismatch, any intervening supply or backing change, and any positive payment that issues zero shares.
- **Orphaned backing is excluded forever**: backing present while supply is zero has no owner. The next positive stake stores it as `orphanedBalanceOf` and both the feed and the cash out hook subtract it. Nobody, including the deployer, can withdraw it.
- **No discretionary withdrawals**: payout limits and surplus allowances are zero, and terminal migration and terminal changes are disabled. Cash outs and core fee processing account for value leaving the project. Donations via `addToBalanceOf` and retained cash out tax raise backing per share.
- **Permanent project configuration**: the deployer owns the project NFT and exposes no call to queue another ruleset. Zero tax makes gross redemption proportional; tax below the maximum uses the Juicebox curve; maximum tax returns zero. Applicable terminal fees are separate. Core's privileged omnichain operator remains a dependency trust boundary.
- **Independent exits**: bootstrap issuance must reach `1e12` share atoms, but burns can leave any supply. Another holder's dust does not force a holder to retain shares. Very small remaining supplies can make issuance too coarse for a later deposit to pass the rounding guard.
- **Share book equals token balance**: at completed transaction boundaries, `stakedBalanceOf` equals the holder's ERC-20 balance. The token reports every positive burn and transfer to the hook from its `_update` path, and refuses to move tokens out of an address whose balance and book disagree, which closes the window between the terminal's mint and the after-pay callback.
- **LIFO with timestamp preservation**: exits consume tranches newest-first; a split tranche keeps its original timestamp. Cumulative tranche balances let a partial exit binary-search its retained tail. Each consumed tranche debits the epoch bucket it joined in, and same-week joins merge into the newest tranche, so an exit's work is bounded by the distinct weeks it consumes and incoming dust cannot make it unbounded.
- **Buckets sum to supply**: `netStakedIn[projectId][epoch]` is credited when tokens join a position and debited at the consumed tranche's original epoch, so the buckets always sum to the staked balances. Because tranches only ever join the current week, every bucket older than the current week is frozen except for exits, which is what lets a tenure round's denominator be read once at funding and its claims be read lazily from live tranches.
- **Streak monotonicity**: `streakStartOf` is set only on a 0→non-zero balance transition and cleared only on a non-zero→0 transition. Staking more never moves it.
- **Tranche age stays with the deposit**: soulbound tokens revert transfers outright; transferable tokens route every positive non-self transfer through `recordTransfer`, which consumes the sender's newest tranches and adds the moved tokens to the receiver's current-week tranche or a fresh one. An existing recipient's holder streak continues, so duration-weighted amounts must use tranche ages.
- **Votes follow ownership**: every holder is self-delegated on first receipt and `delegate`/`delegateBySig` revert. At a past block, votes equal that holder's balance at the same block, and past active votes equal past supply. Snapshot ownership is independent of tranche age and can include temporarily held shares; group 0 uses it, tenure groups do not.
- **State-changing callbacks are gated**: after-pay and after-cash-out callbacks accept only a terminal of the project per `JBDirectory` and reject forwarded native value; burn and transfer reports accept only the project's registered token; granters and token registration accept only the deployer. The before-recording data hooks are public views used by core and previews.

See [INVARIANTS.md](./INVARIANTS.md) for the complete verification checklist and [RISKS.md](./RISKS.md) for its limits.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `StickyDeployer` | Launches sticky projects with the locked eternal ruleset; deploys the share token with CREATE2 under a launcher- and configuration-bound salt, attaches it and the price feed; permanent owner of every project it launches | Immutable; creates `StickyHook` in its constructor; its only external transaction is `deployStickyFor`; `predictStickyTokenOf` reproduces a launch's token address |
| `StickyHook` | `IJBRulesetDataHook` + `IJBPayHook` + `IJBCashOutHook` singleton keyed by project ID; issuance pricing, orphaned-backing exclusion, exact balances, LIFO tranches, streaks, granter and trusted-sender gates | Immutable; receives no funds (hook specifications carry `amount: 0`); no owner |
| `StickyPriceFeed` | One per project; returns share-owned backing in the terminal's cached accounting precision as the issuance denominator, or one unit while supply is zero | Registered under a distinct synthetic base currency; the after-pay check rejects issuance mismatches, including an incorrect fallback price |
| `StickyToken` | ERC-20 shares, soulbound or transferable, with checkpointed locked self-delegation; reports burns and transfers to the hook | One per project, bound via `canBeAddedTo`; mint/burn only by `JBTokens` |
| `StickyDistributor` | Round-based reward distribution with linear vesting; group 0 weighs vote checkpoints at the round's snapshot block, tenure groups weigh the stake held in tranches created within a week window before the round started | Subclass of `JBDistributor` bound to the hook; loans disabled; splits carry the group in `split.projectId`; 20,515-byte runtime |
| `StickyAutoStick` | Opt-in, keeper-executable compounding of a holder's vested underlying-token rewards from the caller's chosen reward groups back into the same position | Immutable; nothing caller-provided beyond project, holder, and groups; quotes the terminal and enforces the quoted minimum |
| `StickyRewardReceiverFactory` | Predicts and deploys one deterministic reward receiver per Sticky token and reward group; `settleFor` deploys it if needed and settles its balance | A shared deployment entrypoint bound to one distributor; rejects groups the distributor rejects |
| `StickyRewardReceiver` | Holds arriving reward tokens for one Sticky token and group and settles them permissionlessly into its bound distributor | Attribution by receiver address; no deposit ledger or ordered queue; can receive tokens before deployment |

### Why a receiver and a factory?

A bridged ERC-20 transfer delivers a token balance to an address without telling Sticky which reward pool should receive it or how it should be weighed. Each receiver's address identifies one Sticky token and one reward group, so arrivals for different pools and weightings remain separate even when they use the same reward asset. Its immutable bindings determine which distributor pool settlement funds. The factory predicts these receiving addresses, deploys the receivers when needed, and provides the shared `settleFor` entrypoint. That deployment role could be folded into another contract, but receiving addresses still need separate pool attribution; sending every arrival to one shared balance would lose it. Settlement forwards the receiver's whole balance of the chosen reward asset, so there is no ordered queue of deposits.

### Why a per-project price feed?

Core calculates share issuance as `floor(amount × weight / price)`, in the terminal's accounting precision. Sticky supplies outstanding share supply as `weight` through the hook and exact share-owned backing as `price` through `StickyPriceFeed`. Keeping that numerator and denominator separate avoids first rounding an exchange rate and then multiplying a deposit by the rounded result. The feed reads terminal accounting and subtracts orphaned backing; it does not obtain an external market price.

`IJBPriceFeed.currentUnitPrice(decimals)` has no project ID argument, so the singleton hook cannot directly return a different project's backing for each call. Each feed binds the required project and accounting context. The per-project share token could implement this interface instead and save a standalone deployment, but that would add terminal, backing, and pricing responsibilities to the token. The separate feed keeps those responsibilities in a small accounting adapter.

## Data Flow

**Stake**: holder (or granter / trusted sender) → `JBMultiTerminal.pay` → store calls `beforePayRecordedWith` (trust gate, snapshot of supply/backing/orphaned, weight = supply) and `JBPrices` → feed (backing − orphaned) → store records payment and calculates `floor(A × S / E)` → controller and `JBTokens` mint shares → terminal calls `afterPayRecordedWith` with the snapshot as metadata → hook checks the issued count and post-state, stores the orphaned baseline if it changed, appends a tranche, starts the streak if the balance was zero.

**Unstake**: holder → `JBMultiTerminal.cashOutTokensOf` → `beforeCashOutRecordedWith` passes the tax rate, count, and supply through and subtracts the orphaned balance from surplus → terminal burns through the controller and `JBTokens` → the token's `_update` calls `recordBurn` → hook consumes tranches newest-first and ends the streak if the balance reached zero → terminal pays the reclaim after applicable fees.

**Voluntary burn**: `JBController.burnTokensOf` follows the same token path, so the book stays exact; the burned shares' backing stays with remaining holders.

**Reward**: funder → distributor `fund` (optionally with a group), a payout or reserved-token split with the group in `split.projectId`, or destination reward receiver → `settle` → distributor `fund` → the current round's pot for that group. For group 0, the first positive funding pins the current round's snapshot block if needed and records the active vote total as the denominator; `poke()` can pin the current and following round. For a tenure group, the first funding of a round records the denominator from the hook's buckets over the window measured back from `snapshotEpochOf(round)`, the week the round started in. Claims read vote checkpoints (group 0) or `stakedBalanceThroughEpochOf` on the holder's live tranches (tenure) and vest over four weekly rounds. Anyone can choose when to settle a receiver, which can change the reward round and its recipients.

**Compound**: enabled holder configuration → keeper `compoundFor`, or holder `stickRewardsFor`, naming the reward groups → collect each group's vested underlying rewards to the holder → pull only the total delivered amount → terminal preview → pay for the same holder. Trust and allowance are separate requirements. The final payment enforces its freshly quoted minimum.

Decimals: tranche amounts, staked balances, and cash out counts are all in the share token's 18 decimals; issuance and backing use the underlying token's accounting decimals, 0 to 36.

## Trust & Permissions

- No Sticky implementation has an upgrade path or an administrator who can change its immutable bindings. Holders can change their personal trust and auto-stick settings.
- Core still has protocol controls. In particular, `JBController.OMNICHAIN_RULESET_OPERATOR` bypasses owner authorization for queueing rulesets. The canonical omnichain deployer enforces owner/operator permissions before calling core; verify that binding and implementation on each chain. The trusted forwarder and core permission model are part of this assumption.
- `allowSetCustomToken` and `allowAddPriceFeed` stay enabled in the eternal ruleset because the launch transaction needs them; both core calls are owner-gated and the owner is the deployer, which exposes no later call to either.
- Any project can point its own ruleset's `dataHook` at `StickyHook`; the accounting is keyed by project ID and requires a registered token, so a rogue project can only revert its own pays.
- The underlying token is trusted for standard ERC-20 behavior. Fee-on-transfer and rebasing tokens are unsupported; the adapter rejects an unexpected holder-to-adapter transfer delta. A successful factory launch does not certify a token's transfer behavior.
- Reward receiver address parity across chains requires matching factory and distributor addresses, creation code, destination Sticky-token address, and group. Read the destination factory's prediction before bridging; no source-chain deployment is required to receive at that destination address.
- Tenure groups trust the hook's tranche and bucket accounting, which only the registered token and the project's terminals can move. A split beneficiary the hook does not track falls back to group 0, and a direct tenure funding for such a token reverts.

## Testing

- `test/StickyHook_Unit.t.sol`, `test/StickyAccounting.t.sol`: unit and reference-model fuzz coverage of tranches, same-week merging, epoch buckets, LIFO, streaks, pagination, dust-bounded exits, and the weekly exit gas bound.
- `test/StickyDistributor_Unit.t.sol`, `test/StickyDistributor_Invariant.t.sol`: group-0 parity with the stock token distributor, tenure windows pinned at round start, split routing, validation, and an invariant campaign over pot solvency, custody isolation, bucket conservation, denominators and entitlements against brute force.
- `test/StickyPricing_Regression.t.sol`, `test/StickyPriceFeed_Regression.t.sol`, `test/StickyPricingCallbacks.t.sol`: issuance pricing, orphaned backing across lifecycles, decimal boundaries, rounding guard, feed fallback, malicious-token callbacks.
- `test/Sticky_Integration.t.sol`, `test/StickyBurn_Integration.t.sol`, `test/StickyRewards_Regression.t.sol`, `test/StickyAutoStick_Unit.t.sol`: full stack against real core and distributor, including grants, donations, tax, transferable mode, burns, rewards, receivers, and compounding.
- `test/deployment/`: restartable CREATE2 deployment, runtime and immutable verification, artifact loading.
