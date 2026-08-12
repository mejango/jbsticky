# JBStickyDistributor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A stick-time-gated reward distributor: airdroppers fund pots that split pro-rata only across tokens stuck ≥ k weeks, with lazy one-phase claims.

**Architecture:** `JBStickyHook` gains weekly `netStakedIn` epoch buckets maintained on every tranche add/consume. `JBStickyDistributor` (a clean single-contract fork of `JBDistributor` + `JBTokenDistributor`, loans dropped) records a criteria pot's denominator at fund time by summing buckets older than k weeks at current values; claims weight each holder by their live tranches older than k weeks. Group 0 keeps the exact ERC20Votes snapshot path; splits carry criteria via small `lockedUntil` values.

**Tech Stack:** Solidity 0.8.28, Foundry (via_ir — use `vm.getBlockTimestamp()` not `block.timestamp` in tests per the warp-rematerialization gotcha), existing `@bananapus/*` pins.

**Spec:** `docs/specs/2026-08-12-sticky-distributor-design.md` — read it first; its invariants section governs.

## Global Constraints

- Repo: `extensions/JBSticky` (its own git repo, push direct to `mejango/jbsticky`).
- Epochs: fixed `1 weeks`, global unix anchor: `epoch = timestamp / 1 weeks`.
- Criteria: threshold only, `k` in whole weeks, `1 ≤ k ≤ 520`; `groupId = k`; groupIds with bits above 240 reserved for future curves — revert at fund time.
- Group 0 = everyone-pool, votes-snapshot mechanics, byte-for-byte base behavior.
- Distributor storage keyed by `hook` = sticky token address; `projectId` derived via `IJBStickyToken(hook).PROJECT_ID()`.
- No changes to `node_modules/@bananapus/distributor-v6` (reference source only).
- Solvency invariant: Σ claimed ≤ funded per (hook, group, token, round). Bucket invariant: Σ netStakedIn == Σ stakedBalanceOf per project.
- Comments follow repo natspec style; no retrospective comments.
- Commit after each task; `forge build && forge test` green before every commit.

---

### Task 1: Hook epoch buckets

**Files:**
- Modify: `src/JBStickyHook.sol` (`_addTo` ~:377, `_consumeFrom` ~:401, storage section ~:100)
- Modify: `src/interfaces/IJBStickyHook.sol`
- Test: `test/JBStickyHook_Unit.t.sol` (append)

**Interfaces:**
- Consumes: existing `_addTo`/`_consumeFrom` tranche flow.
- Produces (used by Tasks 2, 5, 6):
  - `uint256 public constant EPOCH_DURATION = 1 weeks;`
  - `mapping(uint256 projectId => mapping(uint256 epoch => uint256)) public netStakedIn;`
  - `mapping(uint256 projectId => uint256) public firstStakeEpochPlusOneOf;` (0 = never staked; stores epoch+1 so unix-epoch-0 test timestamps can't alias the sentinel)

- [ ] **Step 1: Write failing tests** (append to `test/JBStickyHook_Unit.t.sol`, following the file's existing setup pattern)

```solidity
function test_bucketsTrackStakeByEpoch() public {
    vm.warp(10 weeks + 1);
    _stake(holder, 100e18); // use the file's existing stake helper
    assertEq(hook.netStakedIn(PROJECT_ID, 10), 100e18);
    assertEq(hook.firstStakeEpochPlusOneOf(PROJECT_ID), 11);

    vm.warp(12 weeks + 1);
    _stake(holder, 50e18);
    assertEq(hook.netStakedIn(PROJECT_ID, 12), 50e18);
    // First-stake marker doesn't move.
    assertEq(hook.firstStakeEpochPlusOneOf(PROJECT_ID), 11);
}

function test_bucketsDecrementByConsumedTrancheEpoch() public {
    vm.warp(10 weeks + 1);
    _stake(holder, 100e18);
    vm.warp(12 weeks + 1);
    _stake(holder, 50e18);

    // Unstake 120: LIFO consumes the epoch-12 tranche fully (50) and 70 of the epoch-10 tranche.
    _unstake(holder, 120e18);
    assertEq(hook.netStakedIn(PROJECT_ID, 12), 0);
    assertEq(hook.netStakedIn(PROJECT_ID, 10), 30e18);
}

function test_bucketConservation() public {
    vm.warp(10 weeks + 1);
    _stake(holder, 100e18);
    vm.warp(11 weeks + 1);
    _stake(holder2, 40e18);
    _unstake(holder, 25e18);
    assertEq(
        hook.netStakedIn(PROJECT_ID, 10) + hook.netStakedIn(PROJECT_ID, 11),
        hook.stakedBalanceOf(PROJECT_ID, holder) + hook.stakedBalanceOf(PROJECT_ID, holder2)
    );
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-test test_buckets -vv`
Expected: FAIL — `netStakedIn` not defined.

- [ ] **Step 3: Implement**

Storage (public stored properties section):

```solidity
/// @notice The duration of one stick-age epoch. Stick-time criteria are quantized to these epochs.
uint256 public constant EPOCH_DURATION = 1 weeks;

/// @notice The net amount staked during each epoch that is still held, per project.
/// @dev Increases when a tranche is created in an epoch; decreases when that tranche is later consumed.
/// @custom:param projectId The ID of the sticky project.
/// @custom:param epoch The epoch, measured as `timestamp / EPOCH_DURATION`.
mapping(uint256 projectId => mapping(uint256 epoch => uint256)) public override netStakedIn;

/// @notice One more than the first epoch in which a project's token was staked, or 0 if never staked.
/// @dev Stored plus-one so an unset entry can't alias epoch 0.
/// @custom:param projectId The ID of the sticky project.
mapping(uint256 projectId => uint256) public override firstStakeEpochPlusOneOf;
```

In `_addTo`, after the tranche push:

```solidity
// Track the stake in its epoch bucket so distributors can total aged stake without checkpoints.
uint256 epoch = block.timestamp / EPOCH_DURATION;
netStakedIn[projectId][epoch] += count;
if (firstStakeEpochPlusOneOf[projectId] == 0) firstStakeEpochPlusOneOf[projectId] = epoch + 1;
```

In `_consumeFrom`, inside the while-loop's two branches (the consumed amount is `remaining` pre-zeroing in the split branch, `tranche.amount` in the pop branch):

```solidity
// Split branch, before `remaining = 0;`:
netStakedIn[projectId][uint256(tranche.timestamp) / EPOCH_DURATION] -= remaining;
// Pop branch, before `remaining -= tranche.amount;`:
netStakedIn[projectId][uint256(tranche.timestamp) / EPOCH_DURATION] -= tranche.amount;
```

Add both getters to `IJBStickyHook` and `override` specifiers.

- [ ] **Step 4: Run full suite**

Run: `forge test`
Expected: all PASS (transfer-path coverage comes free: `recordTransfer` calls `_consumeFrom` + `_addTo`).

- [ ] **Step 5: Commit** — `feat: track net stake per weekly epoch in the hook`

---

### Task 2: Hook batch view

**Files:**
- Modify: `src/JBStickyHook.sol` (public views section), `src/interfaces/IJBStickyHook.sol`
- Test: `test/JBStickyHook_Unit.t.sol` (append)

**Interfaces:**
- Produces (used by Task 5): `function netStakedInEpochs(uint256 projectId, uint256 fromEpoch, uint256 toEpoch) external view returns (uint256[] memory amounts);` — inclusive bounds, reverts if `fromEpoch > toEpoch`.

- [ ] **Step 1: Failing test**

```solidity
function test_netStakedInEpochsRange() public {
    vm.warp(10 weeks + 1);
    _stake(holder, 100e18);
    vm.warp(12 weeks + 1);
    _stake(holder, 50e18);

    uint256[] memory amounts = hook.netStakedInEpochs(PROJECT_ID, 10, 12);
    assertEq(amounts.length, 3);
    assertEq(amounts[0], 100e18);
    assertEq(amounts[1], 0);
    assertEq(amounts[2], 50e18);

    vm.expectRevert(
        abi.encodeWithSelector(JBStickyHook.JBStickyHook_InvalidEpochRange.selector, 12, 10)
    );
    hook.netStakedInEpochs(PROJECT_ID, 12, 10);
}
```

- [ ] **Step 2: Verify failure** — `forge test --match-test test_netStakedInEpochsRange -vv`

- [ ] **Step 3: Implement**

```solidity
/// @notice Thrown when an epoch range's bounds are inverted.
error JBStickyHook_InvalidEpochRange(uint256 fromEpoch, uint256 toEpoch);

/// @notice The net still-held stake for each epoch in an inclusive range.
/// @param projectId The ID of the sticky project.
/// @param fromEpoch The first epoch to read.
/// @param toEpoch The last epoch to read.
/// @return amounts The net staked amount for each epoch, in order.
function netStakedInEpochs(
    uint256 projectId,
    uint256 fromEpoch,
    uint256 toEpoch
)
    external
    view
    override
    returns (uint256[] memory amounts)
{
    if (fromEpoch > toEpoch) revert JBStickyHook_InvalidEpochRange({fromEpoch: fromEpoch, toEpoch: toEpoch});
    amounts = new uint256[](toEpoch - fromEpoch + 1);
    for (uint256 i; i < amounts.length; i++) {
        amounts[i] = netStakedIn[projectId][fromEpoch + i];
    }
}
```

- [ ] **Step 4: Run** — `forge test`, all PASS.
- [ ] **Step 5: Commit** — `feat: batch epoch-bucket view on the hook`

---

### Task 3: Fork scaffold — JBStickyDistributor compiles with group-0 semantics

**Files:**
- Create: `src/JBStickyDistributor.sol`
- Create: `src/interfaces/IJBStickyDistributor.sol`
- Create: `src/structs/JBStickyRewardRoundData.sol`
- Test: `test/JBStickyDistributor_Unit.t.sol` (new)

**Interfaces:**
- Consumes: `node_modules/@bananapus/distributor-v6/src/{JBDistributor,JBTokenDistributor}.sol` as copy source; `IJBStickyHook` from Task 1-2; `IJBStickyToken.PROJECT_ID()`.
- Produces (used by Tasks 4-7): one contract `JBStickyDistributor` with constructor
  `(IJBDirectory directory, IJBStickyHook stickyHook, uint256 initialRoundDuration, uint256 initialVestingRounds, uint48 initialClaimDuration)`,
  public `STICKY_HOOK`, and these externals (group-0 behavior identical to the base):
  `fund(address hook, IERC20 token, uint256 amount)`,
  `beginVesting(address hook, uint256[] tokenIds, IERC20[] tokens)`,
  `collectVestedRewards(address hook, uint256[] tokenIds, IERC20[] tokens, address beneficiary)`,
  `recycleExpiredRewards(address hook, IERC20 token, uint256[] rounds)`,
  `processSplitWith(JBSplitHookContext calldata context)`, `poke()`,
  plus the base's public views/state (`currentRound`, `roundStartTimestamp`, `rewardRoundOf`, `vestingDataOf`, `collectableFor`, `totalVestingAmountOf`, `nextClaimRoundOf`, `roundSnapshotBlock`, `balanceOf`).

- [ ] **Step 1: Copy and collapse.** Concatenate `JBDistributor.sol` and `JBTokenDistributor.sol` from `node_modules/@bananapus/distributor-v6/src/` into one `JBStickyDistributor is IJBStickyDistributor` contract (internal virtual-hook indirection flattened: `_claimPastRewards`, `_tokenStake*`, `_totalStake`, `_canClaim`, `_claimBeneficiaryOf`, `_requireCanClaimTokenIds`, `_validateTokenIds` become plain internal functions with the token-distributor bodies). Delete wholesale:
  - REVLoans/REVOwner: `REV_LOANS`, `REV_OWNER`, `CONTROLLER` (only used for loans/revnet lookups — token registry not needed since `hook` IS the sticky token), constructor permission-grant block, `_PENDING_VESTING_LOAN_ID`, `activeVestingLoanIdOf`, `totalLoanedVestingAmountOf`, `_vestingLoanOf`, `borrowAgainstVesting`, `repayVestingLoan`, `writeOffLiquidatedVestingLoan`, `_revnetIdOf`, `_requireNoActiveVestingLoan`, `JBVestingLoan` imports, `JBDistributor_VestingLoansDisabled` paths.
  - 721-isms: `releaseForfeitedRewards`, `_tokenBurned`, `_unlockRewards`'s `ownerClaim=false` branch (keep the owner-claim path only).
  - Rename errors/events `JBDistributor_*`/`JBTokenDistributor_*` → `JBStickyDistributor_*`.
- Replace `JBRewardRoundData` with the new struct (one added field):

```solidity
/// @notice A reward amount assigned to a specific distributor round.
/// @custom:member amount The reward amount assigned to the round.
/// @custom:member snapshotBlock The block used for group-0 historical stake lookups.
/// @custom:member claimedAmount The reward amount already materialized into vesting.
/// @custom:member claimDeadline The timestamp used by expiration logic. Zero means no expiration.
/// @custom:member totalStake The aggregate stake denominator used to split the round.
/// @custom:member snapshotEpoch The stick-age epoch at the first funding, used by criteria groups (0 for group 0).
struct JBStickyRewardRoundData {
    uint208 amount;
    uint48 snapshotBlock;
    uint208 claimedAmount;
    uint48 claimDeadline;
    uint208 totalStake;
    uint48 snapshotEpoch;
}
```

- Constructor stores `DIRECTORY`, `STICKY_HOOK`, round/vesting/claim params; keep the base's zero-round-duration revert.
- [ ] **Step 2: Write the group-0 parity test** (new file, model setup on `test/JBSticky_Integration.t.sol`'s deploy helpers: deploy hook + deployer + a sticky project + the new distributor):

```solidity
function test_group0FundClaimCollect_parity() public {
    // Two holders stake 75/25 before funding.
    _stake(alice, 75e18);
    _stake(bob, 25e18);
    vm.roll(block.number + 1); // votes checkpoints need a past block

    reward.mint(funder, 100e18);
    vm.startPrank(funder);
    reward.approve(address(distributor), 100e18);
    distributor.fund(address(stickyToken), reward, 100e18);
    vm.stopPrank();

    // Next round: claims materialize 75/25.
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
    _beginVestingFor(alice);
    _beginVestingFor(bob);

    // Full vesting: collect everything.
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
    assertEq(_collectFor(alice), 75e18);
    assertEq(_collectFor(bob), 25e18);
}
```

- [ ] **Step 3: Iterate until green** — `forge build && forge test --match-contract JBStickyDistributor -vv`. The scaffold is done when this parity test passes with the votes path.
- [ ] **Step 4: Full suite green; commit** — `feat: fork JBStickyDistributor scaffold (group-0 votes parity, loans dropped)`

---

### Task 4: Criteria groupId validation + criteria-aware fund

**Files:**
- Modify: `src/JBStickyDistributor.sol`, `src/interfaces/IJBStickyDistributor.sol`
- Test: `test/JBStickyDistributor_Unit.t.sol` (append)

**Interfaces:**
- Produces (used by Tasks 5-7):
  - `uint256 public constant MAX_CRITERIA_WEEKS = 520;`
  - `function fund(address hook, IERC20 token, uint256 amount, uint256 groupId) external payable;`
  - `function beginVesting(address hook, uint256 groupId, uint256[] tokenIds, IERC20[] tokens) external;`
  - `function collectVestedRewards(address hook, uint256 groupId, uint256[] tokenIds, IERC20[] tokens, address beneficiary) external;`
  - `function recycleExpiredRewards(address hook, uint256 groupId, IERC20 token, uint256[] rounds) external returns (uint256);`
  - `error JBStickyDistributor_InvalidCriteria(uint256 groupId);`
  - internal `_requireValidGroup(uint256 groupId)`: allows 0 and `[1, MAX_CRITERIA_WEEKS]`, reverts otherwise (future curveIds land above bit 240 and are rejected here until implemented).

- [ ] **Step 1: Failing tests**

```solidity
function test_fundRejectsInvalidCriteria() public {
    reward.mint(funder, 10e18);
    vm.startPrank(funder);
    reward.approve(address(distributor), 10e18);

    vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidCriteria.selector, 521));
    distributor.fund(address(stickyToken), reward, 10e18, 521);

    vm.expectRevert(
        abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidCriteria.selector, uint256(1) << 240)
    );
    distributor.fund(address(stickyToken), reward, 10e18, uint256(1) << 240);
    vm.stopPrank();
}

function test_fundWithCriteriaCreatesGroupPot() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    vm.warp(14 weeks + 1); // alice's tranche is 4 epochs old

    reward.mint(funder, 10e18);
    vm.startPrank(funder);
    reward.approve(address(distributor), 10e18);
    distributor.fund(address(stickyToken), reward, 10e18, 2); // stuck >= 2 weeks
    vm.stopPrank();

    (uint208 amount,,,, uint208 totalStake, uint48 snapshotEpoch) =
        distributor.rewardRoundOf(address(stickyToken), 2, reward, distributor.currentRound());
    assertEq(amount, 10e18);
    assertEq(totalStake, 100e18);
    assertEq(snapshotEpoch, 14);
}
```

- [ ] **Step 2: Verify failure** — `forge test --match-test test_fundRejects -vv`
- [ ] **Step 3: Implement.** The 4-arg `fund` mirrors `_fund` with `_requireValidGroup(groupId)` first; the group-aware `beginVesting`/`collect`/`recycle` overloads call the existing internal group-parameterized paths (the base internals already thread `groupId`). Denominator recording comes in Task 5 — for this task, make the criteria branch of `_recordRewardRound` record `snapshotEpoch = _toUint48(block.timestamp / STICKY_HOOK.EPOCH_DURATION())` and the walk-based `totalStake` per Task 5's code (implement both tasks' `_recordRewardRound` change here if simpler, keeping Task 5 for the claim side; adjust its steps accordingly).
- [ ] **Step 4: Run; full suite green.**
- [ ] **Step 5: Commit** — `feat: criteria groups — validation, fund/claim/recycle overloads`

---

### Task 5: Fund-time bucket-walk denominator

**Files:**
- Modify: `src/JBStickyDistributor.sol` (`_recordRewardRound`)
- Test: `test/JBStickyDistributor_Unit.t.sol` (append)

**Interfaces:**
- Consumes: `STICKY_HOOK.netStakedInEpochs`, `firstStakeEpochPlusOneOf` (Tasks 1-2); `IJBStickyToken(hook).PROJECT_ID()`.
- Produces: criteria rounds record `totalStake = Σ netStakedIn[e]` for `e ∈ [firstStakeEpoch, snapshotEpoch − k]`, pinned at first funding of (hook, group, token, round).

- [ ] **Step 1: Failing tests**

```solidity
function test_denominatorSumsOnlyAgedBuckets() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    vm.warp(13 weeks + 1);
    _stake(bob, 300e18); // too fresh for k=2 at epoch 14
    vm.warp(14 weeks + 1);

    _fundGroup(10e18, 2);
    (,,,, uint208 totalStake,) =
        distributor.rewardRoundOf(address(stickyToken), 2, reward, distributor.currentRound());
    assertEq(totalStake, 100e18); // only alice's epoch-10 bucket is <= 14 - 2
}

function test_denominatorZeroWhenNothingAged() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    _fundGroup(10e18, 52); // nothing is a year old
    (,,,, uint208 totalStake,) =
        distributor.rewardRoundOf(address(stickyToken), 52, reward, distributor.currentRound());
    assertEq(totalStake, 0);
}

function test_secondFundingSameRoundKeepsPinnedDenominator() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    vm.warp(12 weeks + 1);
    _fundGroup(10e18, 1);
    _stake(bob, 900e18);   // same round, after the pin
    _fundGroup(5e18, 1);   // must not re-walk
    (uint208 amount,,,, uint208 totalStake,) =
        distributor.rewardRoundOf(address(stickyToken), 1, reward, distributor.currentRound());
    assertEq(amount, 15e18);
    assertEq(totalStake, 100e18);
}
```

- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement** inside `_recordRewardRound`'s first-funding branch (`rewardRound.amount == 0`), replacing the votes-denominator line for `groupId != 0`:

```solidity
if (groupId == 0) {
    uint256 snapshotBlock = _ensureSnapshotBlockFor(round);
    rewardRound.snapshotBlock = _toUint48(snapshotBlock);
    rewardRound.totalStake = _toUint208(_totalStake({hook: hook, blockNumber: snapshotBlock}));
} else {
    // Criteria pots snapshot at the funding block: current bucket values ARE the snapshot,
    // because tranches are append-only with now-timestamps and k >= 1.
    uint256 snapshotEpoch = block.timestamp / STICKY_HOOK.EPOCH_DURATION();
    rewardRound.snapshotEpoch = _toUint48(snapshotEpoch);
    rewardRound.totalStake = _toUint208(
        _agedTotalStake({hook: hook, snapshotEpoch: snapshotEpoch, weeksRequired: groupId})
    );
}
rewardRound.claimDeadline = claimDeadline;
```

```solidity
/// @notice The total still-held stake at least `weeksRequired` epochs old, read at current bucket values.
/// @param hook The sticky token whose project's buckets are read.
/// @param snapshotEpoch The epoch being snapshotted.
/// @param weeksRequired The criteria threshold in epochs.
/// @return total The aged-stake denominator.
function _agedTotalStake(
    address hook,
    uint256 snapshotEpoch,
    uint256 weeksRequired
)
    internal
    view
    returns (uint256 total)
{
    uint256 projectId = IJBStickyToken(hook).PROJECT_ID();
    uint256 firstPlusOne = STICKY_HOOK.firstStakeEpochPlusOneOf(projectId);

    // No stake ever, or the threshold reaches past the first stake: nothing qualifies.
    if (firstPlusOne == 0 || snapshotEpoch < weeksRequired || firstPlusOne - 1 > snapshotEpoch - weeksRequired) {
        return 0;
    }

    uint256[] memory amounts =
        STICKY_HOOK.netStakedInEpochs({projectId: projectId, fromEpoch: firstPlusOne - 1, toEpoch: snapshotEpoch - weeksRequired});
    for (uint256 i; i < amounts.length; i++) {
        total += amounts[i];
    }
}
```

- [ ] **Step 4: Run; full suite green.**
- [ ] **Step 5: Commit** — `feat: fund-time epoch-walk denominator for criteria pots`

---

### Task 6: Criteria claim path — live-tranche numerator

**Files:**
- Modify: `src/JBStickyDistributor.sol` (`_claimRewardRoundFor` dispatch + new `_agedStakeOf`)
- Test: `test/JBStickyDistributor_Unit.t.sol` (append)

**Interfaces:**
- Consumes: `STICKY_HOOK.tranchesOf(projectId, holder)` (oldest-first, nondecreasing timestamps), `rewardRound.snapshotEpoch` (Task 5), `ctx.groupId` already threaded through `JBClaimContext`.
- Produces: criteria claims weight = Σ live tranche amounts with `timestamp / EPOCH_DURATION ≤ snapshotEpoch − k`.

- [ ] **Step 1: Failing tests**

```solidity
function test_claimSplitsProRataAcrossAgedTranches() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    _stake(bob, 300e18);
    vm.warp(13 weeks + 1);
    _stake(bob, 600e18); // fresh bob tranche won't count for k=2 at epoch 14
    vm.warp(14 weeks + 1);
    _fundGroup(100e18, 2); // denominator = 400e18

    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
    _beginVestingGroupFor(alice, 2);
    _beginVestingGroupFor(bob, 2);
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
    assertEq(_collectGroupFor(alice, 2), 25e18);
    assertEq(_collectGroupFor(bob, 2), 75e18);
}

function test_postSnapshotDeepExitForfeitsAgedWeight() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    _stake(bob, 100e18);
    vm.warp(12 weeks + 1);
    _fundGroup(100e18, 1); // denominator 200e18

    // Bob unsticks 80 after the snapshot: LIFO eats into his only (aged) tranche.
    _unstake(bob, 80e18);
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
    _beginVestingGroupFor(alice, 1);
    _beginVestingGroupFor(bob, 1);
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
    assertEq(_collectGroupFor(alice, 1), 50e18); // alice's share unaffected
    assertEq(_collectGroupFor(bob, 1), 10e18);   // 20/200 of the pot; 40e18 stays for recycle
}

function test_lateStakeCannotClaimOldRound() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    vm.warp(12 weeks + 1);
    _fundGroup(100e18, 1);
    _stake(carol, 500e18); // staked after snapshot

    vm.warp(vm.getBlockTimestamp() + 30 weeks); // carol's tranche is now ancient in wall-time
    _beginVestingGroupFor(carol, 1);
    assertEq(_collectableGroupFor(carol, 1), 0); // epoch 12 > snapshotEpoch(12) - 1
}
```

- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement.** In `_claimRewardRoundFor` (which receives the storage `rewardRound`), thread `groupId` from the caller and dispatch:

```solidity
uint256 tokenStakeAmount = groupId == 0
    ? _tokenStakeAt({hook: hook, tokenId: tokenId, blockNumber: rewardRound.snapshotBlock})
    : _agedStakeOf({
        hook: hook,
        account: _claimBeneficiaryOf({hook: hook, tokenId: tokenId}),
        snapshotEpoch: rewardRound.snapshotEpoch,
        weeksRequired: groupId
    });
```

```solidity
/// @notice A holder's live tranche amount old enough for a round's criteria.
/// @dev Live tranches are safe: they're append-only with now-timestamps (nothing staked after the
/// snapshot can reach an epoch <= snapshotEpoch - k with k >= 1), and LIFO unstaking means post-snapshot
/// exits only reduce the exiting holder's own weight. You must still be stuck to collect.
/// @param hook The sticky token whose project's tranches are read.
/// @param account The holder claiming.
/// @param snapshotEpoch The round's pinned epoch.
/// @param weeksRequired The criteria threshold in epochs.
/// @return amount The holder's aged stake.
function _agedStakeOf(
    address hook,
    address account,
    uint256 snapshotEpoch,
    uint256 weeksRequired
)
    internal
    view
    returns (uint256 amount)
{
    if (snapshotEpoch < weeksRequired) return 0;
    uint256 cutoff = snapshotEpoch - weeksRequired;
    JBStickyTranche[] memory tranches =
        STICKY_HOOK.tranchesOf({projectId: IJBStickyToken(hook).PROJECT_ID(), holder: account});
    for (uint256 i; i < tranches.length; i++) {
        // Tranches are oldest-first with nondecreasing timestamps; stop at the first too-young one.
        if (uint256(tranches[i].timestamp) / STICKY_HOOK.EPOCH_DURATION() > cutoff) break;
        amount += tranches[i].amount;
    }
}
```

- [ ] **Step 4: Run; full suite green.**
- [ ] **Step 5: Commit** — `feat: criteria claims weigh live aged tranches`

---

### Task 7: Splits carry criteria via lockedUntil

**Files:**
- Modify: `src/JBStickyDistributor.sol` (`processSplitWith`)
- Test: `test/JBStickyDistributor_Unit.t.sol` (append)

**Interfaces:**
- Consumes: `context.split.lockedUntil` (uint48, delivered on both terminal and controller paths); `MAX_CRITERIA_WEEKS` (Task 4).
- Produces: `lockedUntil ∈ [1, 520]` → `groupId = lockedUntil`; anything else → group 0. Never reverts on out-of-band values (a split-hook revert soft-lands funds back into the project silently).

- [ ] **Step 1: Failing tests** (reuse the file's mock-terminal split-context helper from the group-0 tests; if none exists yet, build the `JBSplitHookContext` by hand and prank the terminal address registered in the mock directory):

```solidity
function test_splitLockedUntilSelectsCriteriaGroup() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    vm.warp(14 weeks + 1);

    _processSplitWithLockedUntil(10e18, 3); // lockedUntil = 3 => k = 3 weeks
    (uint208 amount,,,, uint208 totalStake,) =
        distributor.rewardRoundOf(address(stickyToken), 3, reward, distributor.currentRound());
    assertEq(amount, 10e18);
    assertEq(totalStake, 100e18);
}

function test_splitRealLockTimestampFallsToGroupZero() public {
    _stake(alice, 100e18);
    vm.roll(block.number + 1);
    _processSplitWithLockedUntil(10e18, uint48(vm.getBlockTimestamp() + 365 days));
    (uint208 amount,,,,,) =
        distributor.rewardRoundOf(address(stickyToken), 0, reward, distributor.currentRound());
    assertEq(amount, 10e18);
}
```

- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement** in `processSplitWith`, replacing the hard-coded `groupId: 0` at both `_recordRewardFunding` call sites:

```solidity
// Small lockedUntil values are 1970-era timestamps that can never lock a split, so the field
// doubles as the split's stick-time criteria. Real lock timestamps route to the everyone-pool;
// out-of-band values also fall to group 0 rather than reverting, because a split-hook revert
// soft-lands the funds back into the project silently.
uint256 lockedUntil = context.split.lockedUntil;
uint256 groupId = (lockedUntil >= 1 && lockedUntil <= MAX_CRITERIA_WEEKS) ? lockedUntil : 0;
```

- [ ] **Step 4: Run; full suite green.**
- [ ] **Step 5: Commit** — `feat: splits select stick-time criteria via inert lockedUntil values`

---

### Task 8: Invariant suite — solvency and bucket conservation

**Files:**
- Create: `test/JBStickyDistributor_Invariant.t.sol`

**Interfaces:**
- Consumes: everything above. Handler drives: stake, unstake, transfer (transferable-mode project), fund (random group ∈ {0,1,2,4}), beginVesting, collect, recycle, warp (bounded jumps up to 3 weeks).

- [ ] **Step 1: Write the handler + two invariants** (follow `test/JBStickyHook_Unit.t.sol` setup style; bound all fuzz inputs; handler tracks ghost totals):

```solidity
function invariant_potSolvency() public view {
    // Reward token can never be over-promised: distributor balance covers all unvested + uncollected inventory.
    assertGe(reward.balanceOf(address(distributor)), handler.ghost_fundedTotal() - handler.ghost_collectedTotal());
    // Per-round: claimed never exceeds funded.
    (uint208 amount,, uint208 claimedAmount,,,) = handler.worstRound();
    assertGe(amount, claimedAmount);
}

function invariant_bucketConservation() public view {
    // Sum of buckets equals sum of staked balances for every touched project.
    assertEq(handler.sumBuckets(), handler.sumStakedBalances());
}
```

The handler exposes `worstRound()` (tracks the (group, round) with the highest claimed/amount ratio as it drives claims), `sumBuckets()` (iterates epochs touched — record min/max epoch on each stake), and `sumStakedBalances()` (iterates its actor set).

- [ ] **Step 2: Run** — `forge test --match-contract Invariant -vv` (use the repo's existing invariant runs/depth config in `foundry.toml`; add `[invariant]` runs=64 depth=64 if absent).
- [ ] **Step 3: Fix anything it finds; suite green.**
- [ ] **Step 4: Commit** — `test: invariant suite for pot solvency and bucket conservation`

---

### Task 9: Deploy scripts + integration test

**Files:**
- Modify: `script/Deploy.s.sol`, `script/DeployLocal.s.sol` (replace the `JBTokenDistributor` deployment with `JBStickyDistributor`)
- Test: `test/JBSticky_Integration.t.sol` (append)

**Interfaces:**
- Consumes: constructor `(directory, stickyHook, roundDuration, vestingRounds, claimDuration)`.
- Produces: prod params `7 days / 4 / 28 days`; local params `600 / 4 / 2400` (bucket epochs stay `1 weeks` regardless — local demos warp).

- [ ] **Step 1: Swap the deployment** in both scripts (constructor args only — drop controller/revLoans/revOwner args, add the hook address the script already has in scope; keep deployments inside `startBroadcast`/`stopBroadcast`).
- [ ] **Step 2: Append an end-to-end integration test** mirroring the existing distributor demo: deploy via the script path, two holders stake in different weeks, warp, fund `k=2` via direct `fund` AND via a payout split with `lockedUntil = 2`, verify only aged weight claims in both pots, verify a `k=0` direct fund reverts, verify an expired criteria pot recycles into the same group with a fresh denominator.

```solidity
function test_integration_criteriaPotEndToEnd() public {
    vm.warp(10 weeks + 1);
    _stake(alice, 100e18);
    vm.warp(11 weeks + 1);
    _stake(bob, 100e18);
    vm.warp(13 weeks + 1);

    _fundGroup(90e18, 2); // only alice's tranche (epoch 10 <= 11) qualifies
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
    _beginVestingGroupFor(alice, 2);
    _beginVestingGroupFor(bob, 2);
    vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
    assertEq(_collectGroupFor(alice, 2), 90e18);
    assertEq(_collectGroupFor(bob, 2), 0);
}
```

- [ ] **Step 3: Run everything** — `forge build && forge test`. All green.
- [ ] **Step 4: Commit** — `feat: deploy JBStickyDistributor; end-to-end criteria integration test`

---

### Task 10: Docs

**Files:**
- Modify: `ARCHITECTURE.md` (new "Stick-time-gated rewards" section: epoch buckets, fund-time denominator, downward-only claim rule, k ≥ 1 rationale, lockedUntil overload), `ADMINISTRATION.md` (airdropper how-to: direct fund with groupId = weeks; split recipe hook = distributor / beneficiary = sticky token / lockedUntil = weeks), `USER_JOURNEYS.md` (holder claim journey: "you must still be stuck to collect").

- [ ] **Step 1: Write the three sections**, copying the invariant language from the spec verbatim where it applies (don't re-derive).
- [ ] **Step 2: Commit** — `docs: stick-time-gated distributor`

---

## Self-Review Notes

- Spec coverage: hook buckets (T1-2), fork + group 0 parity (T3), criteria encoding + validation (T4), fund-time denominator (T5), lazy claim numerator + forfeit rule (T6), lockedUntil splits (T7), invariants from the spec's edge-case list (T8), deploy + E2E incl. recycle-stays-gated (T9), docs (T10). Webclient work is explicitly out of contract scope per the spec.
- Type consistency: `groupId = k` (plain uint, 1..520) everywhere; `snapshotEpoch` uint48 in `JBStickyRewardRoundData`; `netStakedIn`/`firstStakeEpochPlusOneOf`/`netStakedInEpochs` names match across T1/T2/T5; `_agedTotalStake`/`_agedStakeOf` defined where used.
- Known judgment calls left to the implementer: exact placement of flattened internals in the fork (T3 step 1 lists what to delete, not line numbers — the copy source is pinned in node_modules and stable), and whether T4/T5's `_recordRewardRound` change lands in one commit (allowed, noted in T4 step 3).
