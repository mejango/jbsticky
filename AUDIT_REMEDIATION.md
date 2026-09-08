# Sticky audit remediation — 2026-09-07

This release addresses the Sticky review of `efcdeb51f691be790f47c35e084593e8bbb3a5fb`. The contract changes, webclient changes, and deployment tools were reviewed together against the pinned V6 core and distributor commits recorded in CI. This is a bounded source and integration review, not a proof that every possible defect is absent.

## Findings and changes

| Original finding | Resolution | Regression coverage |
| --- | --- | --- |
| C-01: zero transfers fabricate streaks; dust makes exits unbounded | Zero/self movements leave position accounting unchanged. Indexed cumulative tranche balances support logarithmic partial exits and constant-work full exits. Bounded pagination is available and used by the client. | `JBStickyAccounting.t.sol`, `JBStickyHook_Unit.t.sol`, client action tests |
| C-02: voluntary burns leave phantom positions | The token reports every positive burn to the hook. Terminal callbacks cannot consume the same position twice. | `JBStickyBurn_Integration.t.sol`, accounting reference-model fuzz tests |
| C-03: fixed-price entrants capture donated backing | Exact backing-priced issuance uses the outstanding supply as numerator and an immutable project accounting feed as denominator. Backing left without shares is permanently excluded from later generations. | `JBStickyPricing_Regression.t.sol`, `JBStickyPriceFeed_Regression.t.sol` |
| C-04: rewards can compound for zero shares | Both adapter entrypoints use core previews, reject zero issuance before collection, recheck actual delivery, and enforce the quoted mint minimum. Positive zero-issuance payments also revert in the hook. | `JBStickyAutoStick_Unit.t.sol`, `JBStickyRewards_Regression.t.sol` |
| I-01: prior permissionless collection prevents keeper compounding | Documented as best effort. Prior collection delivers rewards to the holder; the adapter never substitutes unrelated wallet funds. The holder can stake the delivered tokens manually. | `test_priorPermissionlessCollectionKeepsRewardsWithHolder` |
| D-01: missing RPC mappings | All eight Sphinx network aliases have explicit environment-backed endpoints and configuration tests. | `test/deployment/config.test.cjs` |
| D-02: incompatible core artifact reader | The focused reader consumes flat per-network artifacts for the controller, directory and terminal, checking chain IDs, code and dependency bindings, including the price registry. | `test/deployment/JBStickyDeployment.t.sol` |
| D-03: deployment cannot safely resume | Canonical CREATE2 deployment reuses contracts only after compiled runtime and every immutable occurrence/binding match. Clean, partial, repeated and mismatched states are covered. Separate rehearsal and live-verification scripts produce clearly distinguished manifests. | Deployment tests and the commands in `DEPLOYMENT.md` |

The accounting redesign preserves exact LIFO timestamps. Under the test fixture, full and partial exits after 1,000 positive dust tranches use approximately 92,000 and 118,000 gas respectively for the measured exit operation; fixture construction is excluded. Full-array reads remain unbounded for compatibility, so clients must use pagination.

## Additional protections found during remediation

- Rounding an exchange rate into a fixed integer weight could let a one-atom initial supply and a donation disable every future stake. The final accounting feed instead gives core the exact denominator for `floor(amount * supply / backing)`. Tests cover one-token and twenty-token donations, including after voluntary burns reduce supply to one atom.
- Issuance has a conservative one-basis-point share-rounding guard, including bootstrap payments and 0–36 decimal assets. The guard does not bound redemption rounding or protocol fees.
- The hook authenticates pre-payment supply/backing metadata, checks the exact issued count, and rejects intervening aggregate changes. An incorrect default price feed therefore cannot silently dilute holders.
- Newly minted shares cannot be transferred or burned through an underlying-token callback before their tranche is recorded. Nested payments, donations and burns during the terminal's approval callback revert atomically.
- Both payable hook callbacks reject unexpected native value. Their production specifications forward no funds.
- Feed accounting precision is cached from the terminal, so later ERC-20 metadata changes cannot change the denominator. The factory rejects zero currency IDs and handles collision with its synthetic base currency.

## Validation and style

The complete Solidity suite passes **130 tests**, including five fuzz properties at **4,096 runs each**. It includes actual V6 core/distributor integrations, malicious-token callbacks, accounting reference-model checks, and deployment regressions. Client verification passes **275 Node tests and 23 Python tests**, with browser checks at mobile and desktop widths. Formatter and runtime/initcode size gates pass; the largest Sticky runtime is 18,375 bytes (`JBStickyDeployer`).

Read-only deployment-and-restart fork rehearsals pass on **Ethereum, Optimism, Base, Arbitrum and all four Sepolia networks**. The deployment-only Foundry profile disables transaction isolation to match Sphinx 0.33 and avoid a Foundry 1.8.1 Optimism-family simulation failure; the normal test profile is unchanged. Actual Sphinx configuration and state-diff compatibility checks pass without submitting a proposal.

Slither 0.11.3 with the committed configuration reports **no High or Medium findings**. Nine Low reports were independently triaged: three constructor-input checks whose canonical factory paths already bind valid values, a dependency permission loop outside Sticky's deployed flow, and five benign/event-order reentrancy reports. Factory writes concern fresh project IDs; reward settlement credits actual received balances, and asset-moving auto-stick operations retain reentrancy protection. `Settle.amount` is the gross pocket amount sent, not an authoritative net credit for fee-on-transfer tokens.

Source and scripts now follow the V6 section order, function ordering, named-call conventions, parameter names, PascalCase enum values, and NatSpec requirements. Solidity base-constructor initializers retain positional arguments because named initializer syntax is invalid. Global package remappings remain necessary to unify nested dependency interface types; the original audit's suggestion that these mappings were redundant was disproved by compilation and is withdrawn. Slither CI and deployment compilation/configuration checks are included.

## Release boundaries

The intended economic policy is backing-priced shares with permanently excluded orphan funds. These are immutable project rules, not upgradeable settings. Source changes create new deployment predictions and do not alter earlier deployed projects. Underlying token controls and unusual token behavior remain relevant; the adapter fails on unsupported transfer deltas.

No live contract deployment, Sphinx execution, or production activation is established by passing tests or producing a simulation manifest. Follow `DEPLOYMENT.md`, retain execution receipts, and run `Verify` against the reviewed compilation before publishing addresses. The website remains an explicit read-only demo until verified contracts and target-chain transaction checks are available.

## Addendum — 2026-09-08 production review

A second bounded review of `f6f120f` re-read every contract, script, and document against the pinned core and distributor commits, re-ran the CI gates, and added three independent adversarial passes (issuance and cash-out pricing, rewards and auto-stick, webclient transaction paths).

| Finding | Resolution | Regression coverage |
| --- | --- | --- |
| P-01 (High): a sole holder could bootstrap one share atom, or burn or cash out down to one, donate through `addToBalanceOf`, and the one-basis-point rounding guard then rejected every deposit below ten thousand atoms unless it was an exact multiple of the inflated atom price. A one-wei donation front-run broke exactness. The attacker's funds were fully recoverable on zero-tax projects. Earlier donation tests only exercised exact multiples. | `JBStickyPricing.MIN_SUPPLY` (`1e12` atoms, one millionth of a whole underlying token) is the smallest positive supply. A bootstrap below it previews zero and reverts; a burn or cash out leaving a positive supply below it reverts with `JBStickyHook_SupplyBelowMinimum`; emptying the supply stays allowed. Coarsening the atom price to block deposits of size `X` now needs roughly `X × 1e8` of locked donation. Known edge: when others hold sub-floor dust after extreme donations, the last exiter must leave the floor behind until they exit. | `test_bootstrapBelowSupplyFloorPreviewsZeroAndRevertsAtomically`, `test_soleHolderDonationCannotForceExactMultipleDeposits`, `test_voluntaryBurnCannotLeaveSupplyBelowFloor`, updated first-mint boundary, tiny-supply donation, and newcomer fuzz tests |
| P-02 (Medium, accepted): the shared `JBTokenDistributor` snapshot is keyed by round only, pinned at `block.number - 1` on the first interaction of any hook or `poke()`, which also pins the next round. On zero-tax projects a one-block stake before the pin and a fee-free exit capture two weekly rounds. | Not a Sticky contract change. Documented in `README.md`, `USER_JOURNEYS.md`, and `ADMINISTRATION.md` with the mitigations: non-zero cash out tax for reward-receiving projects, funders reading `roundSnapshotBlock` first, or an age-gated distributor. Accepted as the configured reward path's known timing model. | None (distributor behavior) |
| P-03 (Low): transferable mode moves accounting without the granter or trusted-sender gate. | Documented; soulbound mode is the opt-in choice. | Existing transferable-mode tests |
| P-04 (Info): older design notes cited a 28-day `CLAIM_DURATION`. | The deployed value is 3 years, which needs no keeper; the notes now say so. | Deployment tests |
| W-01 (Medium): reward-token discovery used an unchunked, address-less `eth_getLogs` and swallowed failures, hiding funded rewards on hosted RPCs. | Routed through the chunked log reader with the failure logged. | Client tests |
| W-02, W-03 (Low): a middot separator and a "1:1 backing" phrase in client copy. | Reworded. | Client tests |
| D-04: `ARCHITECTURE.md`, `ADMINISTRATION.md`, and `USER_JOURNEYS.md` still described the pre-redesign one-to-one, soulbound-only, cash-out-hook accounting. | Rewritten to the shipped semantics. | n/a |

The Solidity suite passes **133 tests** with the CI command, the runtime and initcode size gates pass (`JBStickyHook` is 8,660 bytes), deployment entrypoints compile, Slither reports no High or Medium findings, and the client checks pass (275 Node tests, 23 Python tests). The hook's runtime changed, so every CREATE2 prediction from `f6f120f` is superseded; rerun rehearsals before proposing.
