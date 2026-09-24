// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBRewardRoundData} from "@bananapus/distributor-v6/src/structs/JBRewardRoundData.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {Test} from "forge-std/Test.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice An 18-decimal ERC-20 standing in for the staked and reward tokens driven by the invariant handler.
contract InvariantErc20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice Drives a bounded actor set through every distributor and hook entrypoint against two sticky projects,
/// one transferable and one soulbound, that share the same reward token, tracking the ghost accounting
/// `JBStickyDistributorInvariantTest` checks its invariants against.
/// @dev Every action bumps the block number first, so default-group votes snapshots (which require a strictly past
/// block) never revert regardless of call order. The second project keeps a lean action set (stake, fund, claim only)
/// since it exists solely to exercise per-hook custody isolation, not bucket conservation.
contract JBStickyDistributorHandler is Test {
    uint256 internal constant MAX_STAKE_AMOUNT = 1_000_000e18;
    uint256 internal constant MAX_FUND_AMOUNT = 1_000_000e18;

    IJBStickyHook public immutable HOOK;
    JBStickyDistributor public immutable distributor;
    JBMultiTerminal public immutable terminal;
    InvariantErc20 public immutable staked;
    InvariantErc20 public immutable reward;
    IJBToken public immutable stickyToken;
    uint256 public immutable projectId;
    IJBToken public immutable stickyToken2;
    uint256 public immutable projectId2;
    uint256 public immutable EPOCH_DURATION;

    address[] public actors;

    /// @notice The total reward token ever accepted into distributor custody, across both hooks.
    uint256 public ghost_fundedTotal;

    /// @notice The total reward token ever transferred out to a collecting actor, across both hooks.
    uint256 public ghost_collectedTotal;

    /// @notice The reward token ever accepted into custody for one hook.
    mapping(address hook => uint256) public ghost_fundedOf;

    /// @notice The reward token ever transferred out to a collecting actor for one hook.
    mapping(address hook => uint256) public ghost_collectedOf;

    /// @notice The most recent tenure group actually funded for one hook (0 if none yet), used to correlate
    /// materialize/collect draws against real inventory instead of drawing independently every time.
    mapping(address hook => uint256) public ghost_lastFundedCriteriaGroup;

    /// @notice One (hook, groupId, round) triple whose tenure round has received funding.
    struct TouchedCriteriaRound {
        address hook;
        uint256 groupId;
        uint256 round;
    }

    TouchedCriteriaRound[] internal _touchedCriteriaRounds;
    mapping(bytes32 key => bool) internal _isTouchedCriteriaRound;

    /// @notice The touched reward round with the highest claimedAmount/amount ratio observed so far.
    JBRewardRoundData public worstRound;

    /// @notice The largest observed gap between a tenure claim's harness-derived expected entitlement and what the
    /// contract materialized into a vesting entry (0 if no mismatch has ever been observed).
    /// @dev Ghost-tracked rather than asserted inline: `fail_on_revert = false` treats a revert inside a handler action
    /// as a discarded call, so an inline `assertEq` would vanish instead of failing the campaign.
    uint256 public ghost_worstEntitlementMismatch;

    /// @notice True once any tenure claim materialized a different number of new vesting entries than predicted.
    bool public ghost_entitlementCountMismatch;

    /// @notice The largest observed gap between a freshly pinned tenure denominator and a brute-force sum of every
    /// actor's live in-window tranches read in the same transaction (0 if they always agreed).
    uint256 public ghost_worstDenominatorMismatch;

    /// @notice The oldest epoch a bucket-affecting action has touched, or `type(uint256).max` if none yet.
    uint256 public minTouchedEpoch = type(uint256).max;

    /// @notice The newest epoch a bucket-affecting action has touched.
    uint256 public maxTouchedEpoch;

    constructor(
        IJBStickyHook hook_,
        JBStickyDistributor distributor_,
        JBMultiTerminal terminal_,
        InvariantErc20 staked_,
        InvariantErc20 reward_,
        IJBToken stickyToken_,
        uint256 projectId_,
        IJBToken stickyToken2_,
        uint256 projectId2_,
        address[] memory actors_
    ) {
        HOOK = hook_;
        distributor = distributor_;
        terminal = terminal_;
        staked = staked_;
        reward = reward_;
        stickyToken = stickyToken_;
        projectId = projectId_;
        stickyToken2 = stickyToken2_;
        projectId2 = projectId2_;
        actors = actors_;
        EPOCH_DURATION = hook_.EPOCH_DURATION();
    }

    //*********************************************************************//
    // ------------------------------ actions ---------------------------- //
    //*********************************************************************//

    modifier bumpBlock() {
        vm.roll(vm.getBlockNumber() + 1);
        _;
    }

    /// @notice Stake a bounded amount of the underlying for a bounded actor in the primary (transferable) project.
    function stake(uint256 actorSeed, uint256 amountSeed) external bumpBlock {
        _stakeIn({targetProjectId: projectId, actor: _actor(actorSeed), amount: bound(amountSeed, 1, MAX_STAKE_AMOUNT)});
        _trackStakeEpoch();
    }

    /// @notice Unstake a bounded amount (partial or full) for a bounded actor in the primary project.
    function unstake(uint256 actorSeed, uint256 countSeed) external bumpBlock {
        address actor = _actor(actorSeed);
        uint256 balance = HOOK.stakedBalanceOf({projectId: projectId, holder: actor});
        uint256 count = bound(countSeed, 0, balance);
        if (count == 0) return;

        vm.prank(actor);
        terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: address(staked),
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: bytes("")
        });
    }

    /// @notice Transfer a bounded amount of the transferable sticky token between two bounded actors.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external bumpBlock {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, stickyToken.balanceOf(from));
        if (amount == 0) return;

        vm.prank(from);
        IERC20(address(stickyToken)).transfer({to: to, value: amount});

        // The receiver's moved tokens land in a tranche timestamped now.
        _trackStakeEpoch();
    }

    /// @notice Stake a bounded amount for a bounded actor in the second (soulbound) project.
    function stake2(uint256 actorSeed, uint256 amountSeed) external bumpBlock {
        _stakeIn({
            targetProjectId: projectId2, actor: _actor(actorSeed), amount: bound(amountSeed, 1, MAX_STAKE_AMOUNT)
        });
    }

    /// @notice Fund the primary project's default group's current round with a bounded amount.
    function fundDefaultGroup(uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken), groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Fund the primary project's bounded tenure group's current round with a bounded amount.
    function fundCriteriaGroup(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken), groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Fund the second project's default group's current round with a bounded amount.
    function fundDefaultGroup2(uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken2), groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Fund the second project's bounded tenure group's current round with a bounded amount.
    function fundCriteriaGroup2(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken2), groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the primary project's default group.
    function beginVestingDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(stickyToken), actor: _actor(actorSeed), groupId: 0, collect: false});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the primary project's bounded tenure group.
    function beginVestingCriteria(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(stickyToken),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(stickyToken), seed: groupSeed}),
            collect: false
        });
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the primary project's default group.
    function collectDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(stickyToken), actor: _actor(actorSeed), groupId: 0, collect: true});
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the primary project's bounded tenure
    /// group.
    function collectCriteria(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(stickyToken),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(stickyToken), seed: groupSeed}),
            collect: true
        });
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the second project's default group.
    function beginVestingDefault2(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(stickyToken2), actor: _actor(actorSeed), groupId: 0, collect: false});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the second project's bounded tenure group.
    function beginVestingCriteria2(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(stickyToken2),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(stickyToken2), seed: groupSeed}),
            collect: false
        });
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the second project's default group.
    function collectDefault2(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(stickyToken2), actor: _actor(actorSeed), groupId: 0, collect: true});
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the second project's bounded tenure
    /// group.
    function collectCriteria2(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(stickyToken2),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(stickyToken2), seed: groupSeed}),
            collect: true
        });
    }

    /// @notice Recycle a bounded expired round in the primary project's default group into the current round.
    function recycleDefault(uint256 roundSeed) external bumpBlock {
        _recycle({groupId: 0, roundSeed: roundSeed});
    }

    /// @notice Recycle a bounded expired round in the primary project's bounded tenure group into the current round.
    function recycleCriteria(uint256 groupSeed, uint256 roundSeed) external bumpBlock {
        _recycle({groupId: _criteriaGroup(groupSeed), roundSeed: roundSeed});
    }

    /// @notice Warp forward by a bounded jump so rounds and epochs advance.
    /// @dev Bounded by the distributor's actual `ROUND_DURATION`, so a single jump can never exceed one round.
    function warp(uint256 jumpSeed) external bumpBlock {
        uint256 jump = bound(jumpSeed, 1, distributor.ROUND_DURATION());
        vm.warp(vm.getBlockTimestamp() + jump);
    }

    //*********************************************************************//
    // ------------------------------- views ----------------------------- //
    //*********************************************************************//

    /// @notice The sum of every touched epoch's still-held bucket for the primary project.
    function sumBuckets() external view returns (uint256 total) {
        if (maxTouchedEpoch < minTouchedEpoch) return 0;
        for (uint256 epoch = minTouchedEpoch; epoch <= maxTouchedEpoch; epoch++) {
            total += HOOK.netStakedIn({projectId: projectId, epoch: epoch});
        }
    }

    /// @notice The sum of every bounded actor's staked balance in the primary project.
    function sumStakedBalances() external view returns (uint256 total) {
        uint256 length = actors.length;
        for (uint256 i; i < length; i++) {
            total += HOOK.stakedBalanceOf({projectId: projectId, holder: actors[i]});
        }
    }

    /// @notice The number of bounded actors this suite drives.
    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    /// @notice The number of distinct (hook, groupId, round) tenure rounds ever funded.
    function touchedCriteriaRoundsLength() external view returns (uint256) {
        return _touchedCriteriaRounds.length;
    }

    /// @notice One touched (hook, groupId, round) tenure round, by index.
    function touchedCriteriaRoundAt(uint256 index)
        external
        view
        returns (address hookAddr, uint256 groupId, uint256 round)
    {
        TouchedCriteriaRound storage touched = _touchedCriteriaRounds[index];
        return (touched.hook, touched.groupId, touched.round);
    }

    /// @notice Every bounded actor's live tranche weight inside `[lo, hi]` for one project, read straight from
    /// `HOOK.tranchesOf` rather than any distributor helper.
    function liveWindowSum(uint256 projectId_, uint256 lo, uint256 hi) public view returns (uint256 sum) {
        uint256 actorsLength_ = actors.length;
        for (uint256 a; a < actorsLength_; a++) {
            sum += _actorWindowWeight({projectId_: projectId_, actor: actors[a], lo: lo, hi: hi});
        }
    }

    /// @notice The epoch window a tenure group selects for a round, derived independently of the distributor.
    /// @return lo The first eligible epoch, or 0 when unbounded below.
    /// @return hi The last eligible epoch.
    /// @return isEmpty Whether no epoch can qualify.
    function windowOf(uint256 groupId, uint256 round) public view returns (uint256 lo, uint256 hi, bool isEmpty) {
        uint256 snapshotEpoch = distributor.snapshotEpochOf(round);
        uint256 base = distributor.CRITERIA_BASE();
        uint256 minWeeks = groupId / base;
        uint256 maxWeeks = groupId % base;
        if (snapshotEpoch < minWeeks) return (0, 0, true);
        hi = snapshotEpoch - minWeeks;
        lo = maxWeeks == 0 || snapshotEpoch < maxWeeks ? 0 : snapshotEpoch - maxWeeks;
    }

    //*********************************************************************//
    // ------------------------------ internal --------------------------- //
    //*********************************************************************//

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Picks one of the encoded `minWeeks * CRITERIA_BASE + maxWeeks` groups exercised by this suite: two
    /// tenure windows (bounded min, unbounded max), two recency windows (min = 1, bounded max), and two cohort windows.
    function _criteriaGroup(uint256 seed) internal pure returns (uint256) {
        uint256[6] memory groups =
            [uint256(2000), uint256(4000), uint256(1002), uint256(1004), uint256(2004), uint256(4008)];
        return groups[seed % 6];
    }

    /// @notice Picks a group for a materialize/collect action, reusing the last funded group about half the time so
    /// claims land on real inventory, and drawing independently otherwise so unfunded groups stay safe no-ops.
    /// The reuse decision reads `seed / 6`, not `seed % 6`, so it is independent of the group drawn.
    function _criteriaGroupForClaim(address hookAddr, uint256 seed) internal view returns (uint256) {
        uint256 lastFunded = ghost_lastFundedCriteriaGroup[hookAddr];
        bool reuseLastFunded = (seed / 6) % 2 == 0;
        if (lastFunded != 0 && reuseLastFunded) return lastFunded;
        return _criteriaGroup(seed);
    }

    function _tokenIds(address actor) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(actor));
    }

    function _tokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));
    }

    function _trackStakeEpoch() internal {
        uint256 epoch = vm.getBlockTimestamp() / EPOCH_DURATION;
        if (epoch < minTouchedEpoch) minTouchedEpoch = epoch;
        if (epoch > maxTouchedEpoch) maxTouchedEpoch = epoch;
    }

    function _stakeIn(uint256 targetProjectId, address actor, uint256 amount) internal {
        staked.mint({to: actor, amount: amount});
        vm.startPrank(actor);
        staked.approve({spender: address(terminal), value: amount});
        terminal.pay({
            projectId: targetProjectId,
            token: address(staked),
            amount: amount,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
    }

    function _fund(address hookAddr, uint256 groupId, uint256 amountSeed) internal {
        uint256 amount = bound(amountSeed, 0, MAX_FUND_AMOUNT);
        if (amount == 0) return;

        uint256 round = distributor.currentRound();
        (uint208 amountBefore,,,,) = distributor.rewardRoundOf(hookAddr, groupId, IERC20(address(reward)), round);

        reward.mint({to: address(this), amount: amount});
        reward.approve({spender: address(distributor), value: amount});
        uint256 balanceBefore = reward.balanceOf(address(distributor));

        if (groupId == 0) {
            distributor.fund({hook: hookAddr, token: IERC20(address(reward)), amount: amount});
        } else {
            distributor.fund({hook: hookAddr, token: IERC20(address(reward)), amount: amount, groupId: groupId});
        }

        uint256 delta = reward.balanceOf(address(distributor)) - balanceBefore;
        ghost_fundedOf[hookAddr] += delta;
        ghost_fundedTotal += delta;

        if (groupId != 0 && delta > 0) {
            ghost_lastFundedCriteriaGroup[hookAddr] = groupId;
            _recordTouchedCriteriaRound({hookAddr: hookAddr, groupId: groupId, round: round});

            // The first funding of a round pins its denominator from the hook's buckets. Nothing else moved in this
            // transaction, so a brute-force sum of every actor's live in-window tranches must match it exactly.
            if (amountBefore == 0) _recordDenominatorCheck({hookAddr: hookAddr, groupId: groupId, round: round});
        }
    }

    /// @notice Compares a freshly pinned denominator with an independent brute-force window sum.
    function _recordDenominatorCheck(address hookAddr, uint256 groupId, uint256 round) internal {
        (,,,, uint208 totalStake) = distributor.rewardRoundOf(hookAddr, groupId, IERC20(address(reward)), round);
        (uint256 lo, uint256 hi, bool isEmpty) = windowOf({groupId: groupId, round: round});
        uint256 expected = isEmpty
            ? 0
            : liveWindowSum({projectId_: hookAddr == address(stickyToken) ? projectId : projectId2, lo: lo, hi: hi});
        uint256 diff = expected > totalStake ? expected - totalStake : totalStake - expected;
        if (diff > ghost_worstDenominatorMismatch) ghost_worstDenominatorMismatch = diff;
    }

    /// @notice Records a (hook, groupId, round) triple the first time it is funded.
    function _recordTouchedCriteriaRound(address hookAddr, uint256 groupId, uint256 round) internal {
        bytes32 key = keccak256(abi.encode(hookAddr, groupId, round));
        if (_isTouchedCriteriaRound[key]) return;
        _isTouchedCriteriaRound[key] = true;
        _touchedCriteriaRounds.push(TouchedCriteriaRound({hook: hookAddr, groupId: groupId, round: round}));
    }

    /// @notice Begins vesting (and optionally collects) `actor`'s unclaimed rounds for one hook, then sweeps exactly
    /// the round range the distributor just walked internally to refresh `worstRound`.
    function _claimAndSweep(address hookAddr, address actor, uint256 groupId, bool collect) internal {
        uint256 tokenId = uint256(uint160(actor));
        IERC20 token = IERC20(address(reward));
        uint256 firstRound = distributor.nextClaimRoundOf(hookAddr, groupId, tokenId, token);
        uint256 round = distributor.currentRound();

        (bool checkEntitlement, uint256 expectedShare, uint256 vestingCountBefore) = _prepareCriteriaEntitlementCheck({
            hookAddr: hookAddr,
            actor: actor,
            groupId: groupId,
            tokenId: tokenId,
            token: token,
            firstRound: firstRound,
            round: round
        });

        if (collect) {
            uint256 balanceBefore = reward.balanceOf(actor);
            if (groupId == 0) {
                distributor.collectVestedRewards({
                    hook: hookAddr, tokenIds: _tokenIds(actor), tokens: _tokens(), beneficiary: actor
                });
            } else {
                distributor.collectVestedRewards({
                    hook: hookAddr, groupId: groupId, tokenIds: _tokenIds(actor), tokens: _tokens(), beneficiary: actor
                });
            }
            uint256 delta = reward.balanceOf(actor) - balanceBefore;
            ghost_collectedOf[hookAddr] += delta;
            ghost_collectedTotal += delta;
        } else if (groupId == 0) {
            distributor.beginVesting({hook: hookAddr, tokenIds: _tokenIds(actor), tokens: _tokens()});
        } else {
            distributor.beginVesting({hook: hookAddr, groupId: groupId, tokenIds: _tokenIds(actor), tokens: _tokens()});
        }

        if (checkEntitlement) {
            _recordCriteriaEntitlement({
                hookAddr: hookAddr,
                groupId: groupId,
                tokenId: tokenId,
                token: token,
                vestingCountBefore: vestingCountBefore,
                expectedShare: expectedShare
            });
        }

        if (round == 0 || firstRound >= round) return;
        for (uint256 r = firstRound; r < round; r++) {
            _updateWorstRound({hookAddr: hookAddr, groupId: groupId, round: r});
        }
    }

    /// @notice Determines whether this claim is checkable for exact per-actor entitlement (exactly one pending,
    /// unexpired round), and if so precomputes the expected materialized amount and the pre-call vesting count.
    /// @dev A harness-computed zero weight still runs the check with `expectedShare == 0`, which the recorder turns
    /// into "no new vesting entry must appear": the case that catches a widened claim window.
    function _prepareCriteriaEntitlementCheck(
        address hookAddr,
        address actor,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token,
        uint256 firstRound,
        uint256 round
    )
        internal
        view
        returns (bool checkEntitlement, uint256 expectedShare, uint256 vestingCountBefore)
    {
        // Only a single unclaimed round is attributable to one vesting entry. `CLAIM_DURATION` exceeds
        // `ROUND_DURATION` in this fixture, so the round just completed cannot have expired.
        if (groupId == 0 || round == 0 || round - firstRound != 1) return (false, 0, 0);

        (uint208 amount,, uint208 claimedAmount,, uint208 totalStake) =
            distributor.rewardRoundOf(hookAddr, groupId, token, firstRound);
        if (totalStake == 0) return (false, 0, 0);

        (uint256 lo, uint256 hi, bool isEmpty) = windowOf({groupId: groupId, round: firstRound});
        if (isEmpty) return (false, 0, 0);

        uint256 targetProjectId = hookAddr == address(stickyToken) ? projectId : projectId2;
        uint256 weight = _actorWindowWeight({projectId_: targetProjectId, actor: actor, lo: lo, hi: hi});

        // Mirrors the contract's arithmetic, including its remaining-pot clamp, so an earlier claim or recycle that
        // already settled part of this round cannot produce a false positive.
        uint256 rawShare = mulDiv(uint256(amount), weight, uint256(totalStake));
        uint256 remainingPot = uint256(amount) - uint256(claimedAmount);
        expectedShare = rawShare > remainingPot ? remainingPot : rawShare;

        vestingCountBefore = _vestingEntryCount({hookAddr: hookAddr, groupId: groupId, tokenId: tokenId, token: token});
        checkEntitlement = true;
    }

    /// @notice One actor's live tranche weight inside `[lo, hi]`, read straight from `HOOK.tranchesOf`.
    function _actorWindowWeight(
        uint256 projectId_,
        address actor,
        uint256 lo,
        uint256 hi
    )
        internal
        view
        returns (uint256 weight)
    {
        JBStickyTranche[] memory tranches = HOOK.tranchesOf(projectId_, actor);
        for (uint256 t; t < tranches.length; t++) {
            uint256 epoch = uint256(tranches[t].timestamp) / EPOCH_DURATION;
            if (epoch < lo || epoch > hi) continue;
            weight += tranches[t].amount;
        }
    }

    /// @notice Probes `vestingDataOf`'s length by reading indices until the auto-generated getter reverts.
    function _vestingEntryCount(
        address hookAddr,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        internal
        view
        returns (uint256 length)
    {
        while (true) {
            try distributor.vestingDataOf(hookAddr, groupId, tokenId, token, length) returns (
                uint256, uint256, uint256
            ) {
                unchecked {
                    length++;
                }
            } catch {
                break;
            }
        }
    }

    /// @notice Records (without reverting) whether the contract materialized exactly the predicted vesting entry.
    function _recordCriteriaEntitlement(
        address hookAddr,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token,
        uint256 vestingCountBefore,
        uint256 expectedShare
    )
        internal
    {
        uint256 vestingCountAfter =
            _vestingEntryCount({hookAddr: hookAddr, groupId: groupId, tokenId: tokenId, token: token});

        if (expectedShare == 0) {
            if (vestingCountAfter != vestingCountBefore) ghost_entitlementCountMismatch = true;
            return;
        }

        if (vestingCountAfter != vestingCountBefore + 1) {
            ghost_entitlementCountMismatch = true;
            return;
        }

        (, uint256 actualAmount,) = distributor.vestingDataOf(hookAddr, groupId, tokenId, token, vestingCountBefore);
        uint256 diff = actualAmount > expectedShare ? actualAmount - expectedShare : expectedShare - actualAmount;
        if (diff > ghost_worstEntitlementMismatch) ghost_worstEntitlementMismatch = diff;
    }

    function _recycle(uint256 groupId, uint256 roundSeed) internal {
        uint256 currentR = distributor.currentRound();
        uint256 round = bound(roundSeed, 0, currentR);
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = round;

        if (groupId == 0) {
            distributor.recycleExpiredRewards({
                hook: address(stickyToken), token: IERC20(address(reward)), rounds: rounds
            });
        } else {
            (uint208 amountBefore,,,,) =
                distributor.rewardRoundOf(address(stickyToken), groupId, IERC20(address(reward)), currentR);
            uint256 recycled = distributor.recycleExpiredRewards({
                hook: address(stickyToken), groupId: groupId, token: IERC20(address(reward)), rounds: rounds
            });
            // A positive recycle funds the current round exactly like `_fund` does, pinning its denominator when it
            // is the round's first funding.
            if (recycled != 0) {
                _recordTouchedCriteriaRound({hookAddr: address(stickyToken), groupId: groupId, round: currentR});
                if (amountBefore == 0) {
                    _recordDenominatorCheck({hookAddr: address(stickyToken), groupId: groupId, round: currentR});
                }
            }
        }

        _updateWorstRound({hookAddr: address(stickyToken), groupId: groupId, round: round});
        _updateWorstRound({hookAddr: address(stickyToken), groupId: groupId, round: currentR});
    }

    /// @notice Refreshes `worstRound` if the given round's claimedAmount/amount ratio is the highest observed so far.
    function _updateWorstRound(address hookAddr, uint256 groupId, uint256 round) internal {
        (uint208 amount, uint48 snapshotBlock, uint208 claimedAmount, uint48 claimDeadline, uint208 totalStake) =
            distributor.rewardRoundOf(hookAddr, groupId, IERC20(address(reward)), round);

        if (amount == 0) return;

        bool isWorse = worstRound.amount == 0
            || uint256(claimedAmount) * uint256(worstRound.amount) > uint256(worstRound.claimedAmount) * uint256(amount);
        if (!isWorse) return;

        worstRound = JBRewardRoundData({
            amount: amount,
            snapshotBlock: snapshotBlock,
            claimedAmount: claimedAmount,
            claimDeadline: claimDeadline,
            totalStake: totalStake
        });
    }
}

/// @notice Invariant suite: the distributor can never over-promise its reward-token inventory, one hook's custody
/// can never leak into another's, the primary project's per-epoch buckets always sum to exactly what is staked, and
/// tenure denominators and entitlements always agree with independent brute-force recomputations.
contract JBStickyDistributorInvariantTest is TestBaseWorkflow {
    // Two-week rounds: the smoke test's four-week warp then starts a round exactly four epochs after the stake, which
    // is the single offset that lands the stake inside a tenure(2+), a recency(1-4) and a cohort(4-8) window at once.
    uint256 constant ROUND_DURATION = 2 weeks;
    uint256 constant VESTING_ROUNDS = 2;
    uint48 constant CLAIM_DURATION = 6 weeks;

    InvariantErc20 staked;
    InvariantErc20 reward;
    JBStickyDeployer deployer;
    IJBStickyHook hook;
    JBStickyDistributor distributor;
    IJBToken stickyToken;
    uint256 projectId;
    IJBToken stickyToken2;
    uint256 projectId2;

    JBStickyDistributorHandler handler;

    function setUp() public override {
        super.setUp();

        staked = new InvariantErc20("Staked", "STK");
        reward = new InvariantErc20("Reward", "RWD");

        deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        hook = deployer.HOOK();

        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), 2 * fee);
        projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Sticky",
            symbol: "STICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        stickyToken = jbTokens().tokenOf(projectId);

        // A second, soulbound sticky project sharing the same staked and reward tokens, so custody isolation between
        // hooks is actually exercised instead of assumed.
        projectId2 = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Sticky 2",
            symbol: "STICKY2",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        stickyToken2 = jbTokens().tokenOf(projectId2);

        distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: hook,
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: CLAIM_DURATION
        });

        address[] memory actors = new address[](5);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        actors[3] = makeAddr("actor3");
        actors[4] = makeAddr("actor4");

        handler = new JBStickyDistributorHandler({
            hook_: hook,
            distributor_: distributor,
            terminal_: jbMultiTerminal(),
            staked_: staked,
            reward_: reward,
            stickyToken_: stickyToken,
            projectId_: projectId,
            stickyToken2_: stickyToken2,
            projectId2_: projectId2,
            actors_: actors
        });

        targetContract(address(handler));
    }

    /// @notice The reward token can never be over-promised: the distributor's balance always covers every unit funded
    /// but not yet collected, and no touched round's claimed amount ever exceeds its funded amount.
    function invariant_potSolvency() public view {
        assertGe(reward.balanceOf(address(distributor)), handler.ghost_fundedTotal() - handler.ghost_collectedTotal());

        (uint208 amount,, uint208 claimedAmount,,) = handler.worstRound();
        assertGe(amount, claimedAmount);
    }

    /// @notice One hook's reward-token custody can never leak into another's, even though both hooks' funds sit in
    /// the same ERC-20 balance. Every assertion is an equality: `_balanceOf` only ever moves by exact deltas.
    function invariant_hookCustodyIsolation() public view {
        uint256 hook1Balance = distributor.balanceOf(address(stickyToken), reward);
        uint256 hook2Balance = distributor.balanceOf(address(stickyToken2), reward);

        assertEq(hook1Balance + hook2Balance, handler.ghost_fundedTotal() - handler.ghost_collectedTotal());
        assertEq(
            hook1Balance, handler.ghost_fundedOf(address(stickyToken)) - handler.ghost_collectedOf(address(stickyToken))
        );
        assertEq(
            hook2Balance,
            handler.ghost_fundedOf(address(stickyToken2)) - handler.ghost_collectedOf(address(stickyToken2))
        );
    }

    /// @notice The primary project's hook buckets always sum to exactly the actor set's staked balances, and to the
    /// token supply.
    function invariant_bucketConservation() public view {
        assertEq(handler.sumBuckets(), handler.sumStakedBalances());
        assertEq(handler.sumBuckets(), stickyToken.totalSupply());
    }

    /// @notice For every tenure round ever funded, independently recomputes the window-stake sum from live tranches
    /// and asserts it never exceeds the round's recorded `totalStake`.
    /// @dev `<=`, not `==`: live tranches can only have shrunk since the round's denominator was pinned. Exits reduce
    /// a holder's own tranches, and `minWeeks >= 1` keeps the round's own epoch out of every window so nothing staked
    /// later can land inside it. Exact agreement at pin time is checked by `invariant_denominatorMatchesBruteForce`.
    function invariant_criteriaWindowSolvency() public view {
        uint256 roundsLength = handler.touchedCriteriaRoundsLength();
        for (uint256 i; i < roundsLength; i++) {
            (address hookAddr, uint256 groupId, uint256 round) = handler.touchedCriteriaRoundAt(i);
            _assertCriteriaRoundWindowSolvency({hookAddr: hookAddr, groupId: groupId, round: round});
        }
    }

    /// @notice Every freshly pinned tenure denominator equalled an independent brute-force sum of every actor's
    /// in-window tranches read in the same transaction.
    function invariant_denominatorMatchesBruteForce() public view {
        assertEq(handler.ghost_worstDenominatorMismatch(), 0);
    }

    /// @notice Every checkable tenure claim materialized exactly the vesting entry an independent per-actor
    /// entitlement predicted, including that a zero-weight claim produced no entry at all. This is the check that
    /// conservation invariants cannot make: the pot-remainder clamp turns a too-wide window into misdistribution,
    /// not a solvency breach.
    function invariant_criteriaClaimEntitlement() public view {
        assertEq(handler.ghost_worstEntitlementMismatch(), 0);
        assertFalse(handler.ghost_entitlementCountMismatch());
    }

    /// @notice Independently recomputes one touched tenure round's live window-stake sum and asserts it against the
    /// round's recorded denominator. Split out of the loop above to stay within the Yul stack under `via_ir`.
    function _assertCriteriaRoundWindowSolvency(address hookAddr, uint256 groupId, uint256 round) internal view {
        (uint208 amount,,,, uint208 totalStake) = distributor.rewardRoundOf(hookAddr, groupId, reward, round);

        // Only a funded round has a pinned denominator to compare against.
        if (amount == 0) return;

        (uint256 lo, uint256 hi, bool isEmpty) = handler.windowOf({groupId: groupId, round: round});
        if (isEmpty) return;

        uint256 targetProjectId = hookAddr == address(stickyToken) ? projectId : projectId2;
        assertLe(handler.liveWindowSum({projectId_: targetProjectId, lo: lo, hi: hi}), uint256(totalStake));
    }

    /// @notice Non-vacuousness tripwire: deterministically drives the handler through fund, warp and collect for both
    /// hooks and every window shape, asserting the ghost totals actually moved.
    /// @dev A plain test rather than `afterInvariant()`, which runs once per independent fuzz run and can legitimately
    /// draw only zero-amount fund calls within one run's depth budget.
    function test_handlerReachesNonzeroFundingAndCollection() public {
        address actor = handler.actors(0);

        handler.stake({actorSeed: 0, amountSeed: 100e18});
        handler.stake2({actorSeed: 0, amountSeed: 100e18});
        handler.fundDefaultGroup({amountSeed: 100e18});
        handler.fundDefaultGroup2({amountSeed: 100e18});

        // Age the stake four weeks before pinning any tenure round: two round-length jumps, since `warp` bounds a
        // single jump to `ROUND_DURATION`. The round starting now therefore snapshots four epochs after the stake.
        uint256 timestampBeforeAging = vm.getBlockTimestamp();
        handler.warp({jumpSeed: ROUND_DURATION});
        handler.warp({jumpSeed: ROUND_DURATION});
        assertEq(vm.getBlockTimestamp() - timestampBeforeAging, 4 weeks, "pre-fund aging warp must total 4 weeks");
        assertEq(
            distributor.snapshotEpochOf(distributor.currentRound()),
            timestampBeforeAging / 1 weeks + 4,
            "the current round must snapshot four epochs after the stake"
        );

        // `_criteriaGroup`'s array is `[2000, 4000, 1002, 1004, 2004, 4008]`; seeds 0, 3 and 5 select one shape each.
        handler.fundCriteriaGroup({groupSeed: 0, amountSeed: 100e18}); // tenure: 2+ weeks
        handler.fundCriteriaGroup({groupSeed: 3, amountSeed: 100e18}); // recency: last 4 completed weeks
        handler.fundCriteriaGroup({groupSeed: 5, amountSeed: 100e18}); // cohort: 4-8 weeks
        assertEq(handler.ghost_worstDenominatorMismatch(), 0);

        // Seeds 6, 9 and 11 land on the same shapes while forcing `(seed / 6) % 2 == 1`, so each collect exercises the
        // shape it names rather than whatever was funded last.
        uint256 tenureSeed = 6;
        uint256 recencySeed = 9;
        uint256 cohortSeed = 11;

        // One round in: materialize each funded round into a vesting entry. Still fully locked, so nothing moves yet.
        handler.warp({jumpSeed: ROUND_DURATION});
        handler.collectDefault({actorSeed: 0});
        handler.collectDefault2({actorSeed: 0});
        handler.collectCriteria({actorSeed: 0, groupSeed: tenureSeed});
        handler.collectCriteria({actorSeed: 0, groupSeed: recencySeed});
        handler.collectCriteria({actorSeed: 0, groupSeed: cohortSeed});
        assertEq(handler.ghost_worstEntitlementMismatch(), 0);
        assertFalse(handler.ghost_entitlementCountMismatch());

        // Halfway through the two-round vesting schedule: collect again to receive the unlocked half.
        handler.warp({jumpSeed: ROUND_DURATION});
        handler.collectDefault({actorSeed: 0});
        handler.collectDefault2({actorSeed: 0});

        uint256 balanceBeforeTenure = reward.balanceOf(actor);
        handler.collectCriteria({actorSeed: 0, groupSeed: tenureSeed});
        assertGt(reward.balanceOf(actor) - balanceBeforeTenure, 0, "tenure window paid nothing");

        uint256 balanceBeforeRecency = reward.balanceOf(actor);
        handler.collectCriteria({actorSeed: 0, groupSeed: recencySeed});
        assertGt(reward.balanceOf(actor) - balanceBeforeRecency, 0, "recency window paid nothing");

        uint256 balanceBeforeCohort = reward.balanceOf(actor);
        handler.collectCriteria({actorSeed: 0, groupSeed: cohortSeed});
        assertGt(reward.balanceOf(actor) - balanceBeforeCohort, 0, "cohort window paid nothing");

        assertGt(handler.ghost_fundedTotal(), 0);
        assertGt(handler.ghost_collectedTotal(), 0);
    }
}
