# JBStickyDistributor — stick-time-gated reward distribution

**Date:** 2026-08-12
**Status:** Approved design, pre-implementation
**Decisions by:** jango (weighting, age basis, cadence, claim model, epoch size)

## Goal

Let an airdropper fund a reward pot that distributes only to holders whose tokens
have been stuck at least some duration D, pro-rata by the amount that meets the
criteria. Threshold criteria ships first; the weight function is an internal
override point so a curve (e.g. √age capped at U, from the Stickiness Ratchet
design's quadratic-distribution option) can be added later without touching the
accounting.

## Decisions (locked)

| Axis | Decision |
|---|---|
| Weighting | Hard threshold now; weight function structured for curves later |
| Criteria source | Airdropper picks criteria per funding (not fixed per project) |
| Age basis | **Tranche age** — only tokens themselves stuck ≥ D count. Each tranche carries its own clock (`JBStickyTranche.timestamp`, preserved across partial LIFO consumes). Fresh capital cannot ride an old holder streak. `streakStartOf` is not used for weighting. |
| Cadence | Full JBDistributor cadence: rounds, linear vesting over `VESTING_ROUNDS`, claim windows, expiry-recycle |
| Code shape | **Clean fork** of `JBDistributor` + `JBTokenDistributor` into `extensions/JBSticky/src/JBStickyDistributor.sol` (REVLoans wiring dropped) |
| Claim model | **Lazy one-phase claims are non-negotiable.** No registration window. The time base is restricted instead. |
| Time base | Criteria quantized to **fixed 1-week epochs**, minimum 1 epoch (`k ≥ 1`) |

## Core mechanism: epoch buckets + fund-time denominator

The problem: pro-rata needs a denominator — "total stake stuck ≥ D at the
snapshot" — but D is airdropper-chosen and tranches cross age thresholds
silently, so no checkpointed quantity exists to look up lazily.

The unlock: **aging is deterministic.** If stake is bucketed by the epoch it was
staked in, then at any moment "total stake aged ≥ k epochs" is just the sum of
buckets at least k epochs old, read at **current** values. Record that sum at
fund time and it *is* the snapshot denominator — no history, no checkpoints, no
pokes, no registration.

### Hook bookkeeping (JBStickyHook)

- `epochOf(t) = t / 1 weeks` (global anchor, unix time; no coupling to any
  distributor's round schedule).
- New storage: `netStakedIn[projectId][epoch]` (plain uint mapping, no
  checkpoint history).
  - `_addTo` (pay, transfer-receive): `netStakedIn[projectId][epochOf(now)] += amount`.
  - `_consumeFrom` (cashout, transfer-send): for each consumed tranche,
    `netStakedIn[projectId][epochOf(tranche.timestamp)] -= consumedAmount`.
    LIFO consumption already walks tranches with their timestamps in hand.
- New storage: `firstStakeEpochOf[projectId]` (set once) to bound walks.
- New batch view: `netStakedInEpochs(projectId, fromEpoch, toEpoch) → uint256[]`
  so the distributor reads the range in one external call.

Hook is not deployed to production; this is a pre-deploy change, not a migration.

### Denominator (fund time)

All storage stays keyed by `hook` = the sticky token address, exactly like the
base (the splits path already names the sticky token as beneficiary). The
distributor derives `projectId = IJBStickyToken(hook).PROJECT_ID()` wherever it
reads the tranche book or buckets from `STICKY_HOOK`.

`JBStickyDistributor.fund(stickyToken, token, amount, criteria)`:

1. Resolve the pot's group from `criteria` (encoding below); the pot is keyed
   (stickyToken, group, token, round).
2. If this is the first funding of (group, token, round): record
   `snapshotEpoch = epochOf(block.timestamp)` in the round data and record
   `totalStake = Σ netStakedIn[projectId][e]` for
   `e ∈ [firstStakeEpochOf, snapshotEpoch − k]`, read at current values via the
   batch view. (Mirrors the base's first-funding-pins-the-snapshot semantics.)
3. Later fundings of the same (group, token, round) only add to the pot amount,
   exactly like the base.

Cost lands on the funder, once per (group, token, round): ~2.1k gas per epoch
walked cold. A 10-year-old project walks ~520 slots ≈ 1.1M gas worst case;
trivially cheap before that. No pagination needed at weekly granularity.

For a future curve, the same walk computes `Σ netStakedIn[e] · w(snapshotEpoch − e)`
— arbitrary age curves cost the same fund-time walk. This is why the walk, not
the criteria, is the primitive.

### Numerator (claim time — lazy, one-phase)

A claimer's weight for a round = the sum of their **live** tranche amounts where
`epochOf(tranche.timestamp) ≤ snapshotEpoch − k`, read from
`STICKY_HOOK.tranchesOf(projectId, holder)` at claim time. Per-holder tranche
counts are small; multi-round lazy claims iterate rounds exactly like the base's
`_claimRewardsFor`.

**Why live tranches are safe (downward-only invariant):**
- Tranches are append-only with now-timestamps, so nothing staked after the
  snapshot can land in an epoch ≤ `snapshotEpoch − k` (epochs are monotonic in
  time and k ≥ 1).
- LIFO unstaking consumes newest tranches first, so post-snapshot exits reduce
  only the exiting holder's own eligible weight, never anyone else's.
- Therefore Σ numerators ≤ recorded denominator, always. Shortfall stays in the
  pot and recycles through the existing expiry path, still criteria-gated.

**Documented rule:** you must still be stuck to collect. Unsticking deep enough
to consume aged tranches after the snapshot forfeits that weight. On-theme.

### Why k ≥ 1 is load-bearing

With k = 0, a tranche staked after the fund block but in the same epoch would
pass the age test while the denominator missed it → Σ numerators could exceed
the denominator → overdistribution / insolvency of the pot. Criteria groups
therefore enforce `k ≥ 1` (revert otherwise).

### Group 0: the everyone-pool

Group 0 (no criteria) keeps the base's exact ERC20Votes snapshot mechanics —
`getPastVotes` numerator, `getPastTotalActiveVotes` denominator at
`roundSnapshotBlock` — which `JBStickyToken` already supports (`IJBActiveVotes`,
auto-self-delegated, delegation locked). `processSplitWith` (payout and
reserved-token splits, beneficiary = sticky token) books to group 0 unchanged,
so recurring split-funded rewards behave byte-for-byte like the deployed
`JBTokenDistributor`.

## Criteria encoding

`groupId` identifies the pot and encodes the criteria:

- `groupId = 0`: everyone (votes-snapshot path).
- `groupId = (curveId << 240) | param`:
  - `curveId 0`, `param = k` (weeks, ≥ 1): hard threshold. So `groupId = 4`
    reads as "stuck ≥ 4 weeks".
  - Future `curveId 1`, `param = U`: √(min(age, U)/U) weighting — new weight
    function + same walk; no storage changes.
- Claims pass the same groupId; the weight function dispatches on curveId.
  Unknown curveIds revert at fund time so pots can't be created that no claim
  path understands.

## Contract inventory

| File | Change |
|---|---|
| `src/JBStickyDistributor.sol` | New. Fork of `JBDistributor` + `JBTokenDistributor` collapsed into one contract: rounds/vesting/claim-window/expiry-recycle/split-hook intake kept; REVLoans + REVOwner wiring dropped; adds `STICKY_HOOK` immutable, criteria-aware `fund`, snapshotEpoch in round data, bucket-walk denominator, tranche-book numerator, curveId dispatch. |
| `src/JBStickyHook.sol` | `netStakedIn` bucket updates in `_addTo`/`_consumeFrom`, `firstStakeEpochOf`, `netStakedInEpochs` view. |
| `src/interfaces/IJBStickyDistributor.sol` | New. |
| `src/interfaces/IJBStickyHook.sol` | Add the new view/storage getters. |
| `script/Deploy*.s.sol` | Deploy `JBStickyDistributor` (7d rounds, 4 vesting rounds, 28d claim duration, matching the current sticky-tuned distributor params; 600s rounds in DeployLocal — note: bucket epochs stay 1 week even on local fork; local demos use warp). |

Distributor package (`@bananapus/distributor-v6`) is untouched. The deployed
`JBTokenDistributor` keeps working for anything already wired to it.

## Edge cases & invariants

- **Pot solvency:** Σ claimed ≤ funded per (group, token, round). Guaranteed by
  the downward-only invariant + k ≥ 1. This is the invariant to fuzz hardest.
- **Bucket conservation:** Σ_epochs netStakedIn[projectId][e] ==
  token totalSupply staked (== Σ stakedBalanceOf). Holds across pay, cashout,
  transfer (transferable mode: sender decrements old buckets, receiver adds to
  current epoch — matching the moved-tokens-restart-their-clock rule
  automatically). Fuzz across all three flows.
- **Same-round double fund:** second funding must not re-walk or move
  snapshotEpoch (denominator pinned at first funding).
- **Claim after further staking:** late tranches can never satisfy
  `epoch ≤ snapshotEpoch − k`; late claims of old rounds stay correct.
- **Burn via `burnTokensOf`:** already an accepted edge in ARCHITECTURE (tranche
  book overstates); buckets inherit the same overstatement, which is
  denominator-inflating (under-distribution, recycles) — safe direction, but
  document it.
- **Zero-eligible round:** totalStake == 0 → base already treats the pot as
  unclaimable and the expiry path recycles it forward.
- **Expiry-recycle of a criteria pot:** recycled amount books into the current
  round of the *same group*, which re-walks a fresh denominator at its own
  snapshotEpoch — stays criteria-gated, fresh eligibility. (Recycle triggers a
  walk; the walker pays. Acceptable: recycle is already lazy-triggered by
  claimers.)
- **Griefing check:** funding 1 wei of dust to a (group, token) creates a pot and
  pins the round's denominator walk cost onto... the funder themself. No
  third-party grief surface identified; claims skip zero-amount rounds like the
  base.

## Testing

- Foundry unit + fuzz in `extensions/JBSticky/test`, following the repo's
  existing patterns (via_ir + `vm.getBlockTimestamp()` per the
  warp-rematerialization gotcha).
- Invariant suite: pot solvency and bucket conservation under a handler doing
  random pay/cashout/transfer/fund/claim/warp sequences.
- Integration: fork test mirroring the existing distributor demo — deploy, two
  holders stake in different weeks, warp, fund with k=2, verify only the aged
  tranche weight claims; verify group-0 splits path unchanged; verify the
  still-stuck-to-collect forfeit; verify k=0 fund reverts; verify recycle of an
  expired criteria pot.

## Webclient (follow-up, not in contract scope)

The AIRDROPS tab's fund card gains a stick-time criteria selector (weeks,
default "everyone" = group 0); rewards tables read pots per groupId; claim
plans unchanged (still preflighted beginVesting + collect). Copy: "only tokens
stuck ≥ N weeks share this drop."

## Out of scope

- √age / curve weighting (structure reserved: curveId dispatch + fund-walk
  weight function; no storage changes needed when it comes).
- Holder-streak basis (rejected: fresh capital riding old streaks).
- Registration-window claims (rejected: breaks lazy one-phase claims).
- REVLoans borrowing against vesting sticky rewards.
- Changes to `@bananapus/distributor-v6`.
