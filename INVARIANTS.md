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
4. Tranches are consumed newest-first. A partially consumed tranche retains its timestamp. Partial exits find the retained tail by binary search; every fully consumed tranche debits its original epoch bucket, so an exit loops once per distinct week it consumes, never once per deposit.
5. Positive minting and incoming transfers join the holder's newest tranche when it was created in the current week, moving its timestamp to the transaction timestamp, and otherwise create a new tranche. Every active tranche is in a distinct week. Transferred shares do not inherit the sender's age. Existing recipient streaks continue.
6. A holder's streak starts when their recorded balance becomes positive and ends when it reaches zero. Adding shares cannot backdate a tranche or restart an active streak. The longest completed streak never decreases.
7. Zero movements and self-transfers do not change Sticky position accounting. Soulbound tokens reject transfers between nonzero addresses, including zero and self-transfers.
8. The bounded tranche getter returns at most 256 active entries. Logically discarded storage is never exposed as an active tranche.
9. For every project, the sum of `netStakedIn` over all epochs equals the sum of holders' staked balances and the token supply at completed transaction boundaries. `stakedBalanceThroughEpochOf(projectId, holder, epoch)` equals the sum of the holder's active tranches created through that epoch.

## Authorization and permanent settings

1. Only the deployer registers project tokens and granters. Its public launch path registers each once and exposes no later project mutation operation.
2. A third-party payment requires the beneficiary's personal trust or permanent granter status. Self-stakes are permitted. Transferable share transfers do not use this payment gate.
3. Only a project's terminal may call the state-changing after-pay or after-cash-out hooks. Both reject forwarded native value. Public before-recording views do not change state.
4. Only core `JBTokens` may mint or burn the share token. Its project binding, metadata, transfer mode, and self-delegation are immutable.
5. The factory grants no owner permissions and exposes no path to withdraw, reconfigure, or transfer a launched project. This guarantee does not override core's omnichain operator or trusted-forwarder assumptions.

## Rewards and compounding

1. At any queryable past block, holder votes equal their share balance at that block, and active votes equal total supply. No delegation change can move reward weight independently of ownership.
2. Group-0 allocations use the pinned historical balance, not tranche age, holder streak, current balance, or continued ownership throughout vesting.
3. A tenure group's window for a round is fixed by the round's start week and the group's `minWeeks`/`maxWeeks`. Its denominator equals the sum of the project's live in-window stake when the round is first funded, is never read while a payment's minted shares still lack a tranche, and no stake added afterwards can enter that window. A holder's allocation equals the pot times their live in-window stake at claim time over that denominator, capped by what the pot still holds, so the sum of claims never exceeds the pot.
4. A receiver is bound to one Sticky token, one reward group, and one distributor. Positive settlement funds the current distributor round of that group with the receiver's reward balance; a zero balance is a no-op. The returned gross amount is not proof of net distributor credit for a transfer-tax token.
5. Keeper compounding requires the selected holder's enabled configuration, cooldown, positive minimum, allowance, hook permission, and at least one reward group. The minimum applies to the combined collectable amount across the requested groups. Only that holder can change the configuration.
6. Both compounding entrypoints collect every requested group to the holder, pull only the total balance increase delivered by those collections, and stake into the same holder's project. Existing unrelated wallet funds cannot substitute for rewards collected before the call.
7. A holder-to-adapter transfer delta mismatch or a payment below the adapter's execution-time share quote reverts the complete collection and stake. The adapter clears its terminal allowance after success.
8. Failure cannot leave a partially completed auto-stick transaction. Permissionless prior collection can leave rewards safely in the holder's wallet and make a later compound ineligible.
9. Rewards allocated to the distributor's own address are never transferred out or erased. Collecting them to the distributor recycles the unlocked amount into the current round of the same hook, group and token; any other token ID collected to the distributor reverts. Custody and the accounted balance are unchanged by a recycle.

## Verification map

| Surface | Tests |
| --- | --- |
| Tranche accounting, exits, epoch buckets, and streaks | `test/JBStickyAccounting.t.sol`, `test/JBStickyHook_Unit.t.sol`, `test/JBStickyBurn_Integration.t.sol` |
| Reward groups, windows, splits, and pot solvency | `test/JBStickyDistributor_Unit.t.sol`, `test/JBStickyDistributor_Invariant.t.sol` |
| Issuance, rounding, and orphaned backing | `test/JBStickyPricing_Regression.t.sol`, `test/JBStickyPriceFeed_Regression.t.sol` |
| Callback ordering | `test/JBStickyPricingCallbacks.t.sol` |
| Core and reward integration | `test/JBSticky_Integration.t.sol`, `test/JBStickyRewards_Regression.t.sol`, `test/JBStickyAutoStick_Unit.t.sol` |
| Deployment identity and restart | `test/deployment/` |
| Quotes, configuration, and transaction recovery | `webclient/test/` |
