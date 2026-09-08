# Architecture

## Purpose

`@bananapus/sticky-v6` lets holders of an ERC-20 lock it into a permanently configured Juicebox V6 project in exchange for Sticky shares of that project's backing, while recording per-deposit amounts and timestamps and a per-holder streak that off-chain reward programs can trust.

The value the system protects is the share-owned backing: every share is redeemable for its proportion of the backing that belongs to shares, by only its holder, at any time, under a cash out curve fixed at launch, with no party able to change that.

## System Overview

The package owns a deployer that launches locked projects, a singleton data hook that prices issuance and does position accounting, a per-project price feed that gives core the exact issuance denominator, and a per-project share token. It composes `nana-core-v6` for everything economic: `JBMultiTerminal` custodies the underlying tokens, `JBController`/`JBRulesets` enforce the eternal ruleset, `JBPrices` routes the feed, and `JBTokens` mints and burns the share token. Rewards are delegated to `JBTokenDistributor` from `nana-distributor-v6`, with two optional helpers: an opt-in compounding adapter and cross-chain reward pockets.

## Core Invariants

- **Backing-priced issuance, never dilutive**: a deposit of `A` underlying atoms issues `floor(A × S / E)` share atoms, where `S` is the outstanding supply and `E` is the backing owned by shares. `JBStickyHook.beforePayRecordedWith` returns `S` as the weight and `JBStickyPriceFeed` returns `E` as the price, so core computes the ratio without rounding an exchange rate first. The after-pay callback re-derives the expected count from the authenticated snapshot and rejects any mismatch, any intervening supply or backing change, and any positive payment that issues zero shares.
- **Orphaned backing is excluded forever**: backing present while supply is zero has no owner. The next positive stake stores it as `orphanedBalanceOf` and both the feed and the cash out hook subtract it. Nobody, including the deployer, can withdraw it.
- **Funds only leave through cash outs**: payout limits and surplus allowances are zero, terminal migration and terminal changes are disabled, so surplus never drops below the orphaned balance plus what shares own. Donations via `addToBalanceOf` and retained cash out tax raise backing per share.
- **Fixed cash out tax forever**: the single ruleset's `cashOutTaxRate` is the project's commitment reward. At 0 unwinds are proportional; above 0 the standard Juicebox curve and its protocol fee apply. No second ruleset can ever be queued because the owner is a contract with no call to do so.
- **Share book equals token balance**: `stakedBalanceOf` always equals the holder's ERC-20 balance. The token reports every positive burn and transfer to the hook from its `_update` path, and refuses to move tokens out of an address whose balance and book disagree, which closes the window between the terminal's mint and the after-pay callback.
- **LIFO with timestamp preservation**: exits consume tranches newest-first; a split tranche keeps its original timestamp. Cumulative tranche balances let a partial exit binary-search its retained tail and a full exit truncate in constant work, so incoming dust cannot make an exit unbounded.
- **Streak monotonicity**: `streakStartOf` is set only on a 0→non-zero balance transition and cleared only on a non-zero→0 transition. Staking more never moves it.
- **Streaks can't be laundered between wallets**: soulbound tokens revert transfers outright; transferable tokens route every transfer through `recordTransfer`, which consumes the sender's newest tranches and gives the receiver a fresh tranche.
- **Votes always equal balance**: every holder is self-delegated on first receipt and `delegate`/`delegateBySig` revert, so `getPastVotes(holder) == balance(holder)` and `getPastTotalActiveVotes == getPastTotalSupply` at every block. Distributor shares cannot be gamed by delegation churn.
- **Callbacks are gated**: pay and cash out callbacks accept only a terminal of the project per `JBDirectory` and reject forwarded native value; burn and transfer reports accept only the project's registered token; granters and the token registration accept only the deployer.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBStickyDeployer` | Launches sticky projects with the locked eternal ruleset; deploys and attaches the share token and price feed; permanent owner of every project it launches | Immutable; creates `JBStickyHook` in its constructor; its only external transaction is `deployStickyFor` |
| `JBStickyHook` | `IJBRulesetDataHook` + `IJBPayHook` + `IJBCashOutHook` singleton keyed by project ID; issuance pricing, orphaned-backing exclusion, exact balances, LIFO tranches, streaks, granter and trusted-sender gates | Immutable; receives no funds (hook specifications carry `amount: 0`); no owner |
| `JBStickyPriceFeed` | One per project; returns share-owned backing in the terminal's cached accounting precision as the issuance denominator, or one unit while supply is zero | Registered under a synthetic base currency so no default feed can match the pair |
| `JBStickyToken` | ERC-20 shares, soulbound or transferable, with checkpointed locked self-delegation; reports burns and transfers to the hook | One per project, bound via `canBeAddedTo`; mint/burn only by `JBTokens` |
| `JBStickyAutoStick` | Opt-in, keeper-executable compounding of a holder's vested underlying-token rewards back into the same position | Immutable; nothing caller-provided beyond project and holder; quotes the terminal and enforces the quoted minimum |
| `JBStickyRewardPockets` / `JBStickyRewardPocket` | Deterministic per-sticky-token inbox for cross-chain reward arrivals, settled permissionlessly into the distributor | Attribution by pocket address instead of by bridge leaf: no ledger, balance-based settle, works before the pocket is deployed |

## Data Flow

**Stake**: holder (or granter / trusted sender) → `JBMultiTerminal.pay` → store calls `beforePayRecordedWith` (trust gate, snapshot of supply/backing/orphaned, weight = supply) and `JBPrices` → feed (backing − orphaned) → store mints `floor(A × S / E)` → terminal calls `afterPayRecordedWith` with the snapshot as metadata → hook checks the issued count and post-state, stores the orphaned baseline if it changed, appends a tranche, starts the streak if the balance was zero.

**Unstake**: holder → `JBMultiTerminal.cashOutTokensOf` → `beforeCashOutRecordedWith` passes the tax rate, count, and supply through and subtracts the orphaned balance from surplus → terminal burns via `JBTokens` → the token's `_update` calls `recordBurn` → hook consumes tranches newest-first and ends the streak if the balance reached zero → terminal pays the reclaim, less the protocol fee when the tax is non-zero.

**Voluntary burn**: `JBController.burnTokensOf` follows the same token path, so the book stays exact; the burned shares' backing stays with remaining holders.

Decimals: tranche amounts, staked balances, and cash out counts are all in the share token's 18 decimals; issuance and backing use the underlying token's accounting decimals, 0 to 36.

## Trust & Permissions

- No owner, no admin, no upgrade path in any contract.
- `allowSetCustomToken` and `allowAddPriceFeed` stay enabled in the eternal ruleset because the launch transaction needs them; both core calls are owner-gated and the owner is the deployer, which exposes no later call to either.
- Any project can point its own ruleset's `dataHook` at `JBStickyHook`; the accounting is keyed by project ID and requires a registered token, so a rogue project can only revert its own pays.
- The underlying token is trusted for standard ERC-20 behavior. Fee-on-transfer and rebasing tokens are out of scope; the adapter rejects unexpected transfer deltas outright.

## Testing

- `test/JBStickyHook_Unit.t.sol`, `test/JBStickyAccounting.t.sol`: unit and reference-model fuzz coverage of tranches, LIFO, streaks, pagination, dust-bounded exits.
- `test/JBStickyPricing_Regression.t.sol`, `test/JBStickyPriceFeed_Regression.t.sol`, `test/JBStickyPricingCallbacks.t.sol`: issuance pricing, orphaned backing across lifecycles, decimal boundaries, rounding guard, feed fallback, malicious-token callbacks.
- `test/JBSticky_Integration.t.sol`, `test/JBStickyBurn_Integration.t.sol`, `test/JBStickyRewards_Regression.t.sol`, `test/JBStickyAutoStick_Unit.t.sol`: full stack against real core and distributor, including grants, donations, tax, transferable mode, burns, rewards, pockets, and compounding.
- `test/deployment/`: restartable CREATE2 deployment, runtime and immutable verification, artifact loading.
