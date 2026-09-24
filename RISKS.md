# Risks

Sticky permanently binds projects to a specific core release and underlying token. A correct accounting implementation does not establish the safety of those dependencies, the suitability of a reward program, or a live deployment. Read this with [INVARIANTS.md](./INVARIANTS.md) and [ADMINISTRATION.md](./ADMINISTRATION.md).

## Priority risks

| Risk | Consequence | Integration requirement |
| --- | --- | --- |
| Maximum cash out tax | Every redemption returns zero, including a whole-supply exit | Show this permanent outcome before launch and before a holder stakes |
| Snapshot reward capture | Temporary ownership can retain group-0 rewards after exiting | Treat group-0 rewards as balance-at-a-block allocations; fund a tenure group when age should matter |
| Tenure claims need a live position | Exiting before claiming forfeits a tenure allocation to the pot | Claim tenure rewards before unstaking; tell holders the claim window |
| Unsupported underlying token | Transfer failures, backing mismatch, or unexpected value loss | Review transfer, rebase, freeze, mint, and upgrade behavior before accepting an asset |
| Incorrect core or deployment identity | Immutable bindings can point to unsuitable or privileged dependencies | Verify code, bindings, chain, and executed receipts for the reviewed release |
| Incorrect bridge destination | Rewards can become inaccessible or fund unintended holders | Predict the receiver on the destination chain and verify the reward-token route |

## Redemption and deposit availability

The cash out tax is a curve parameter, not a flat percentage deducted from every exit. Below the maximum, redeeming the whole supply returns all share-owned backing before terminal fees. At the maximum, gross reclaim is zero. A voluntary burn never returns backing. Another holder's dust does not prevent a full holder exit.

The terminal's `previewCashOutFrom` reports gross reclaim. A non-feeless beneficiary owes the terminal fee against all reclaim at positive tax, or against the reclaim covered by `feeFreeSurplusOf` at zero tax. A failed fee route credits the fee back to project backing; it does not refund the beneficiary. Client minimums must protect the net amount actually expected.

Share issuance rounds down and rejects excessive rounding loss. Initial issuance has a minimum, but later burns can leave very small supplies. Large backing per share atom, including after a donation, can make small deposits preview zero and revert. This preserves the payer's funds and exit independence; it does not guarantee that every desired deposit remains possible. The share-rounding guard does not bound underlying-token redemption rounding or protocol fees.

Donations to an empty project and backing left after the last voluntary burn are unowned. Subsequent shares cannot reclaim them. There is no rescue or administrator withdrawal path for orphaned backing.

Value added to a Sticky project's balance through `addToBalanceOf` or a `preferAddToBalance` payout split accrues immediately to current holders, so a holder who enters just before such an inflow and exits right after captures their share of it (`test_acceptedRisk_payoutSplitInflowCapturedByTransientHolder`); projects should not route payout splits into Sticky projects.

## Reward allocation and timing

Group 0 uses ownership snapshots without a minimum stake age. First positive funding or settlement pins the current round if needed. Anyone can call `poke()` to pin both the current and next round if unset, using the previous block. That timing is shared by every project on the distributor.

A holder can acquire shares, wait one block, pin snapshots, and exit while retaining the pinned group-0 allocations. A positive cash out tax raises stake/redeem cost but cannot prevent a profitable capture when rewards exceed that cost. Transferable shares can be temporarily acquired and returned without redeeming at all. Funders who want age to matter must fund a tenure group; group 0 remains age-blind by design.

Tenure groups weigh tranche age in whole weeks, measured from the week the round started in. A stake made earlier in that same week, or after the round started, is not eligible for that round regardless of the clock; the earliest it can qualify is a round starting `minWeeks` weeks later. A funder cannot shift a round's window by funding it later in the round. Rounds start on the distributor's own schedule, not on week boundaries, so a round can span two weeks; its window is still the one pinned by its start.

A tenure denominator is read from the hook's buckets at the round's first funding. A claim reads the holder's live tranches, so a holder must still hold the qualifying tranches when they claim: exiting or transferring first forfeits that allocation, which stays in the pot and recycles into the current round after the claim window. Partial exits consume the newest tranches first, so a tenure allocation survives a partial exit that leaves the aged tranches intact, while a recency window loses eligibility from its newest tranches first. Bounded windows pay deposits, not people: a continuous staker's cohort share is only the slice deposited in that window.

The denominator read relies on the hook's buckets summing to the token supply. During a payment the terminal mints before the hook records the tranche, so the buckets lag the supply until the after-pay callback runs. The registered token reports every mint to the hook, which flags the project's payment as in progress (`isPayingFor`) in transient storage until that callback records the tranche. A tenure funding or receiver settlement that reaches the distributor in that gap reverts with `JBStickyDistributor_PaymentInProgress` instead of recording a denominator, and a reverted payment leaves no flag behind. Group 0 weighs a past block and is unaffected. Reaching the gap requires an underlying token with transfer callbacks, which Sticky does not support.

The round current at receiver settlement determines its recipients and, for tenure groups, its window. Anyone can settle immediately or across a round boundary. A funder cannot reserve an arrival for a chosen future round by leaving it in a receiver. Funding a round with zero eligible stake, including a tenure window nothing has aged into, leaves that round without a claimant until its unclaimed inventory becomes recyclable.

Splits carry the group in `split.projectId`. Tools that render a split destination without checking its hook first will show that number as a project. An invalid group or an unregistered beneficiary silently funds group 0; a funder who intends a tenure group must confirm the split's `projectId` decodes as one.

Every share holder is self-delegated, contracts included, so reward weight follows balances by design. An AMM pool that holds transferable shares receives an allocation that anyone can collect to the pool and then skim. Sticky tokens cannot be another Sticky project's staked token, so no terminal holds reward weight. A Sticky token funded as a reward leaves the distributor itself holding aged shares with weight in that token's rounds. The distributor cannot pay itself: collecting its allocation to the distributor, the only beneficiary a helper may use, recycles the unlocked amount into the current round of the same pot (`collectVestedRewards(..., beneficiary: distributor)`, or `releaseForfeitedRewards` for group 0), and a holder collecting their own rewards to the distributor is rejected. The distributor keeps its weight, so each recycled round hands it a share again; the remainder shrinks geometrically across rounds and anyone can keep recycling it.

Vesting starts through a transaction for eligible past allocations; elapsed time since funding alone does not mean all rewards are collectable. Auto-stick is permissionless to execute but requires someone to send transactions. Anyone can collect to the holder before a keeper, which preserves the reward in the wallet but prevents that later compound from using it. Auto-stick handles only the project's underlying reward token.

## Trust boundaries

- **Core authority.** `JBController.OMNICHAIN_RULESET_OPERATOR` can bypass owner authorization to queue rulesets. The canonical omnichain deployer checks owner/operator permissions before calling core. Verify its binding and code on each chain. Sticky's zero-duration ruleset has no approval hook to delay an incorrect privileged configuration.
- **Core forwarder and permissions.** Core transaction sender resolution and delegated authority remain part of the security model. The factory's lack of an owner-call surface is not a substitute for correct dependencies.
- **Protocol controls.** Core creation fees, feeless configuration, and default price feeds retain their respective authority models. Sticky's exact post-pay check prevents a mismatched fallback price from silently changing issued shares; a failed feed can still make payments revert.
- **Underlying custody.** The terminal's internal ledger is not a guarantee against token rebases, freezes, upgrades, or malicious callbacks. Fee-on-transfer and rebasing underlying tokens are unsupported; some paths may appear to work without making the whole integration safe.
- **Project identity.** Launching is permissionless. A familiar token name, symbol, or project URI does not authenticate its underlying asset or launcher. Use chain and contract addresses from a confirmed launch event.
- **Share transfers.** In transferable mode, an unsolicited transfer can start a position without the payment trust gate. Transferred tokens join the recipient's current-week tranche or start a new one, and preserve an existing recipient's holder streak. Granters are permanent and cannot be individually revoked by holders.
- **Reward receivers.** Cross-chain address parity depends on factory and distributor addresses, creation code, the destination Sticky-token address, and the group. These contracts do not validate bridge messages or recover mistaken native-token or ERC-20 transfers to unsupported destinations. A tenure-group receiver for a token the hook does not track cannot settle; its balance stays in the receiver.

## Operational limits

An exit debits one epoch bucket per distinct week it consumes. Same-week deposits merge, so dust cannot multiply that work, but a position built up weekly for ten years (520 tranches) costs about 3.3M gas to exit fully from cold storage, roughly 6,300 gas per week. Tenure denominators walk at most `MAX_CRITERIA_WEEKS` buckets plus the weeks elapsed since the round started.

Whole-array tranche reads are unbounded; use pagination at a pinned block. RPC failures and incomplete log ranges must be distinguished from a zero balance or absent reward. A submitted transaction is not a confirmed action: recover the canonical receipt before retrying a launch, approval, stake, or bridge operation.

Simulation manifests do not establish deployed code. Runtime changes alter CREATE2 predictions, and existing immutable projects retain their original contracts. Keep the site in its explicitly configured demo state until the reviewed release has executed, post-deployment verification has passed on its target chain, and the corresponding wallet flows have been exercised. See [DEPLOYMENT.md](./DEPLOYMENT.md).
