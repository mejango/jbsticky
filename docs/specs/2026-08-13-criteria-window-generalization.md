# Criteria windows — generalizing stick-time gating to (min, max)

**Date:** 2026-08-13
**Status:** Approved design, pre-implementation
**Supersedes:** the "Criteria encoding" section of `2026-08-12-sticky-distributor-design.md`. Everything
else in that spec — epoch buckets, fund-time denominator, lazy one-phase claims, the downward-only
argument, group 0, the `lockedUntil` channel — stands unchanged.
**Lands on:** the open PR (`sticky-distributor`, mejango/jbsticky#1), before merge. Nothing is deployed,
so the one-parameter encoding is replaced outright rather than carried alongside.

## Why

`netStakedIn` is a cohort histogram: bucket `e` holds the still-held stake created in epoch `e`. The
shipped feature reads one predicate over it — `e ≤ snapshotEpoch − k`, a prefix. Two more predicates
are the same walk with different bounds:

| Intent | Parameters | Epoch window |
|---|---|---|
| Tenure — "4+ weeks" | min 4, max unbounded | `[firstStakeEpoch, snapshotEpoch − 4]` |
| Recency — "last 4 completed weeks" | min 1, max 4 | `[snapshotEpoch − 4, snapshotEpoch − 1]` |
| Cohort — "4 to 8 weeks" | min 4, max 8 | `[snapshotEpoch − 8, snapshotEpoch − 4]` |

One two-parameter form subsumes all three at the cost of the one already built.

## Safety: `min ≥ 1` is the whole rule

The shipped `k ≥ 1` constraint generalizes exactly. `min ≥ 1` means the window's top bound is
`snapshotEpoch − min ≤ snapshotEpoch − 1`, so **the current, still-incomplete epoch is never eligible**.
That is what preserves the downward-only invariant:

- New stake always lands in `epochOf(now) ≥ snapshotEpoch`, strictly above the window, so no bucket in
  the window can grow after the fund block. Buckets are append-frozen; the fund-time read IS the
  snapshot.
- Unstakes only decrement in-window buckets and only reduce the exiter's own numerator (LIFO).
- Therefore Σ numerators ≤ recorded denominator for every reachable sequence, as before.

`min = 0` would put the snapshot epoch inside the window: a stake made after the fund transaction but
in the same week would be absent from the denominator yet present in the live numerator —
overdistribution. `min = 0` is therefore rejected, which is also why recency is `(1, k)`, not `(0, k)`.

Eligibility is frozen at the snapshot: both sides compare against the round's stored `snapshotEpoch`,
so tokens do not age into or out of a pot between funding and claiming.

## Encoding

`groupId = minWeeks * CRITERIA_BASE + maxWeeks`, with `CRITERIA_BASE = 1000`.

- `minWeeks ∈ [1, MAX_CRITERIA_WEEKS]` (520). Required.
- `maxWeeks ∈ [0, MAX_CRITERIA_WEEKS]`. `0` means unbounded.
- If `maxWeeks != 0`, require `maxWeeks >= minWeeks`.
- `groupId == 0` remains the everyone-pool (ERC20Votes snapshot path), unchanged.

Examples: `4000` = 4+ weeks. `1004` = the last 4 completed weeks. `4008` = 4 to 8 weeks.
Largest valid criteria groupId is `520520`.

Decimal rather than bit-packing, for three reasons: it stays legible in a config field and a block
explorer; it fits `lockedUntil`'s `uint48` where a `curveId << 240` scheme could not; and `520520`
seconds is ~6 days past the Unix epoch, so the whole range remains permanently inert to core's split
lock (see the prior spec's `lockedUntil` section).

**The old encoding fails closed.** Every previously-valid criteria value (`1`–`520`) decodes to
`minWeeks == 0`, which is invalid. A stale config reverts on direct `fund` and falls through to group 0
on the split path. No old value is silently reinterpreted as a different window.

**Reserved for later:** the `curveId << 240` band stays reserved for weighted curves (√age). This
change is about which tranches are *in* the set, not how they are *weighted* within it.

## Contract changes

All in `src/JBStickyDistributor.sol` unless noted.

**New constant.** `uint256 public constant override CRITERIA_BASE = 1000;` — also declared on
`IJBStickyDistributor`. `MAX_CRITERIA_WEEKS` keeps its value and becomes the per-parameter cap.

**New shared decode** (internal view, replaces the duplicated guard logic the prior review flagged):

```
/// @return lo The first eligible epoch. Zero when the window is unbounded below.
/// @return hi The last eligible epoch.
/// @return isEmpty True when no epoch can qualify.
function _criteriaWindowFor(uint256 snapshotEpoch, uint256 groupId)
    internal pure returns (uint256 lo, uint256 hi, bool isEmpty)
```

- `minWeeks = groupId / CRITERIA_BASE`, `maxWeeks = groupId % CRITERIA_BASE`.
- `snapshotEpoch < minWeeks` → empty.
- `hi = snapshotEpoch - minWeeks`.
- `lo = maxWeeks == 0 ? 0 : (snapshotEpoch < maxWeeks ? 0 : snapshotEpoch - maxWeeks)`.
- `lo > hi` → empty (unreachable given the checks above, but returned defensively).

**Validation.** Split into a pure predicate and its reverting wrapper, because `processSplitWith` needs
the predicate without the revert:

```
function _isValidGroup(uint256 groupId) internal pure returns (bool)
function _requireValidGroup(uint256 groupId) internal pure   // reverts JBStickyDistributor_InvalidCriteria
```

`_isValidGroup` returns true for `0`; otherwise decodes and enforces the three parameter rules above.
`groupId` values above `520520` fail on `minWeeks > MAX_CRITERIA_WEEKS`, which also rejects the
reserved high-bit curve band until it is implemented.

**Denominator.** `_agedTotalStake` → `_windowTotalStake(address hook, uint256 snapshotEpoch, uint256
groupId)`. Resolves the window, clamps `lo` **up** to `firstStakeEpochPlusOneOf - 1` (mandatory — an
unclamped `lo = 0` would walk from 1970), returns 0 when the project never staked or the window is
empty, then sums `netStakedInEpochs(projectId, lo, hi)`.

**Numerator.** `_agedStakeOf` → `_windowStakeOf(JBStickyTranche[] memory tranches, uint256
snapshotEpoch, uint256 groupId)`. Resolves the window, then one forward pass over the oldest-first
array with three phases:

```
for i in 0..len:
    e = tranches[i].timestamp / EPOCH_DURATION
    if (e < lo) continue;   // older than the window; keep scanning
    if (e > hi) break;      // younger than the window, and so is everything after it
    amount += tranches[i].amount;
```

No clamp to `firstStakeEpoch` here — a comparison against `lo = 0` is already correct, and tranches
cannot predate the first stake.

**Call sites.** `_recordRewardRound`'s criteria branch passes `groupId` instead of `weeksRequired`;
`_claimRewardRoundFor` likewise. `processSplitWith` replaces its inline range test with
`groupId = _isValidGroup(lockedUntil) ? lockedUntil : 0` (still never reverts on an out-of-band value —
a split-hook revert soft-lands the funds, or burns them on the reserved-token path).

**Naming and placement.** Both renamed functions move to their alphabetical slots in "internal views"
(`_windowStakeOf` before `_windowTotalStake`); `_criteriaWindowFor` and `_isValidGroup` land in their
own alphabetical slots. Per STYLE_GUIDE section ordering.

## Semantics to document

**Bounded windows pay deposits, not persons.** A continuous staker who tops up monthly holds tranches
in many buckets; a `(4, 8)` pot pays only the slice deposited in that stretch. Tenure (`max` unbounded)
pays their whole aged position. Cohort pots are deposit-cohort instruments — document this prominently
in ADMINISTRATION and USER_JOURNEYS, since it is the most likely misread.

**LIFO erodes recency fastest.** Under tenure, a partial unstake consumes fresh tranches first, shielding
aged weight. Under recency the eligible tranches are the newest, so any partial unstake immediately cuts
eligibility. Cohort windows sit in between. Safety is unaffected (numerators only shrink); this is a UX
note.

**Recency is snipeable by construction.** Anyone can become recent; nobody can become old. `min ≥ 1`
closes only the post-fund-block hole. Staking during the window in anticipation of a drop is legitimate
participation that dilutes the intended cohort. Document that recency pots suit unannounced or
unpredictable funding, and that they are acquisition instruments rather than loyalty ones.

**Windows are relative, not absolute.** Funding `(4, 8)` monthly rewards a sliding set. A fixed
"everyone who staked in March, forever" cohort would need absolute epoch bounds — explicitly out of
scope.

## Testing

- **Validation:** accept `0`, `4000`, `1004`, `4008`, `520520`; reject `4`, `520` (old encoding, `min == 0`),
  `8004` (`max < min`), `4999` (`max > 520`), `521000` (`min > 520`), `1 << 240`.
- **Tenure equivalence:** port every existing criteria test from `k` to `min*1000`; assertions must be
  unchanged, proving the generalization is behavior-preserving for the shipped shape.
- **Cohort denominator:** stakes in epochs spanning below, inside, and above a `(4, 8)` window; only the
  middle buckets enter `totalStake`.
- **Cohort numerator / deposit-cohort:** a holder with tranches in three different buckets claims only
  the in-window slice.
- **Recency:** `(1, k)` pays the newest completed weeks and excludes older tenure.
- **The insolvency guard (most important test):** fund a recency pot, then stake again in the same epoch
  after the fund transaction; the late stake must contribute 0 to the claim numerator. Σ claims ≤ pot.
- **Split path:** `lockedUntil = 4008` selects the cohort group; `lockedUntil = 4` (stale encoding) and a
  real lock timestamp both fall to group 0 without reverting.
- **Invariants:** the handler's criteria set gains recency and cohort groups alongside tenure; pot
  solvency, bucket conservation, and per-hook custody isolation must all still hold.

## Out of scope

Weighted curves (√age) — still reserved in the high-bit band. Absolute-epoch cohorts. Per-address caps.
Webclient surfacing (follow-up: the AIRDROPS criteria selector becomes a min/max pair).
