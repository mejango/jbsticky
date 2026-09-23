# Invariants

These guarantees apply to projects launched by `JBStickyDeployer`, using the configured V6 core and supported underlying tokens. [RISKS.md](./RISKS.md) describes assumptions and behaviors they do not guarantee.

## Issuance and backing

1. A successful payment into an existing supply issues `floor(amount × supply / backing)` share atoms, using pre-payment supply and backing after excluding orphaned funds. No intermediate exchange-rate rounding changes this ratio.
2. Empty-supply issuance starts at one Sticky share per whole underlying token, normalized to 18 decimals. A bootstrap must issue at least `1e12` share atoms. The minimum is an initial issuance requirement, not a minimum remaining supply after a burn.
3. Positive payments cannot issue zero shares or exceed the conservative one-basis-point share-rounding bound. Rejection reverts the complete payment.
4. The after-pay callback checks the expected issuance and aggregate supply/backing against the terminal's pre-payment snapshot. Unexpected intervening mint, burn, payment, or donation cannot silently change the accepted price.
5. Backing that exists without shares is excluded from subsequent generations. The next positive payment records that baseline in `orphanedBalanceOf`; while supply is zero, all backing is unowned even if the stored baseline has not caught up.
6. Cash out pricing excludes orphaned backing. Sticky exposes no operation that withdraws it or allocates it to later holders.
7. The immutable project feed uses the terminal's cached accounting precision. Later ERC-20 metadata changes cannot change that precision. An incorrect fallback price cannot pass the after-pay check if it changes issuance.

## Positions and exits

1. At completed transaction boundaries, a holder's `stakedBalanceOf` equals their share-token balance and the sum of active tranche amounts. Between core minting and after-pay recording, outgoing positive share movements from an unreconciled holder revert.
2. Only the registered share token reports burns or transfers. Every positive burn, including a voluntary controller burn, consumes accounting exactly once.
3. A burn can leave any remaining supply. Another holder's dust does not create a minimum balance the exiter must keep.
4. Tranches are consumed newest-first. A partially consumed tranche retains its timestamp. Full exits discard the logical tranche list without a loop; partial exits use binary search.
5. Positive minting and incoming transfers create a new tranche at the transaction timestamp. Transferred shares do not inherit the sender's age. Existing recipient streaks continue.
6. A holder's streak starts when their recorded balance becomes positive and ends when it reaches zero. Adding shares cannot backdate a tranche or restart an active streak. The longest completed streak never decreases.
7. Zero movements and self-transfers do not change Sticky position accounting. Soulbound tokens reject transfers between nonzero addresses, including zero and self-transfers.
8. The bounded tranche getter returns at most 256 active entries. Logically discarded storage is never exposed as an active tranche.

## Authorization and permanent settings

1. Only the deployer registers project tokens and granters. Its public launch path registers each once and exposes no later project mutation operation.
2. A third-party payment requires the beneficiary's personal trust or permanent granter status. Self-stakes are permitted. Transferable share transfers do not use this payment gate.
3. Only a project's terminal may call the state-changing after-pay or after-cash-out hooks. Both reject forwarded native value. Public before-recording views do not change state.
4. Only core `JBTokens` may mint or burn the share token. Its project binding, metadata, transfer mode, and self-delegation are immutable.
5. The factory grants no owner permissions and exposes no path to withdraw, reconfigure, or transfer a launched project. This guarantee does not override core's omnichain operator or trusted-forwarder assumptions.

## Rewards and compounding

1. At any queryable past block, holder votes equal their share balance at that block, and active votes equal total supply. No delegation change can move reward weight independently of ownership.
2. Distributor allocations use the pinned historical balance, not tranche age, holder streak, current balance, or continued ownership throughout vesting.
3. A receiver is bound to one Sticky token and one distributor. Positive settlement funds the current distributor round with that receiver's reward balance; a zero balance is a no-op. The returned gross amount is not proof of net distributor credit for a transfer-tax token.
4. Keeper compounding requires the selected holder's enabled configuration, cooldown, positive minimum, allowance, and hook permission. Only that holder can change the configuration.
5. Both compounding entrypoints collect to the holder, pull only the balance increase delivered by that collection, and stake into the same holder's project. Existing unrelated wallet funds cannot substitute for rewards collected before the call.
6. A holder-to-adapter transfer delta mismatch or a payment below the adapter's execution-time share quote reverts the complete collection and stake. The adapter clears its terminal allowance after success.
7. Failure cannot leave a partially completed auto-stick transaction. Permissionless prior collection can leave rewards safely in the holder's wallet and make a later compound ineligible.

## Verification map

| Surface | Tests |
| --- | --- |
| Tranche accounting, exits, and streaks | `test/JBStickyAccounting.t.sol`, `test/JBStickyHook_Unit.t.sol`, `test/JBStickyBurn_Integration.t.sol` |
| Issuance, rounding, and orphaned backing | `test/JBStickyPricing_Regression.t.sol`, `test/JBStickyPriceFeed_Regression.t.sol` |
| Callback ordering | `test/JBStickyPricingCallbacks.t.sol` |
| Core and reward integration | `test/JBSticky_Integration.t.sol`, `test/JBStickyRewards_Regression.t.sol`, `test/JBStickyAutoStick_Unit.t.sol` |
| Deployment identity and restart | `test/deployment/` |
| Quotes, configuration, and transaction recovery | `webclient/test/` |
