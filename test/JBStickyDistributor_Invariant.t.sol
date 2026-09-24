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
// forge-lint: disable-next-line(multi-contract-file)
contract InvariantErc20 is ERC20 {
    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param tokenName The token's name.
    /// @param tokenSymbol The token's symbol.
    constructor(string memory tokenName, string memory tokenSymbol) ERC20(tokenName, tokenSymbol) {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Mints tokens to an account.
    /// @param to The account receiving the tokens.
    /// @param amount The number of tokens to mint.
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
// forge-lint: disable-next-line(multi-contract-file)
contract JBStickyDistributorHandler is Test {
    //*********************************************************************//
    // ------------------------------ structs ---------------------------- //
    //*********************************************************************//

    /// @notice One (hook, groupId, round) triple whose tenure round has received funding.
    /// @custom:member hook The sticky token whose round was funded.
    /// @custom:member groupId The tenure group that was funded.
    /// @custom:member round The round that was funded.
    struct TouchedCriteriaRound {
        address hook;
        uint256 groupId;
        uint256 round;
    }

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The largest amount a single funding action draws.
    uint256 internal constant _MAX_FUND_AMOUNT = 1_000_000e18;

    /// @notice The largest amount a single stake action draws.
    uint256 internal constant _MAX_STAKE_AMOUNT = 1_000_000e18;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The distributor under test.
    JBStickyDistributor public immutable DISTRIBUTOR;

    /// @notice The hook's epoch length, in seconds.
    uint256 public immutable EPOCH_DURATION;

    /// @notice The hook accounting for both projects' tranches.
    IJBStickyHook public immutable HOOK;

    /// @notice The primary (transferable) project's ID.
    uint256 public immutable PROJECT_ID;

    /// @notice The second (soulbound) project's ID.
    uint256 public immutable PROJECT_ID_2;

    /// @notice The token both projects hand out as a reward.
    InvariantErc20 public immutable REWARD;

    /// @notice The token staked into both projects.
    InvariantErc20 public immutable STAKED;

    /// @notice The primary project's share token.
    IJBToken public immutable STICKY_TOKEN;

    /// @notice The second project's share token.
    IJBToken public immutable STICKY_TOKEN_2;

    /// @notice The terminal both projects are paid through.
    JBMultiTerminal public immutable TERMINAL;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The bounded actor set this handler drives.
    address[] public actors;

    /// @notice The reward token ever transferred out to a collecting actor for one hook.
    /// @custom:param hook The sticky token the rewards were collected from.
    mapping(address hook => uint256) public ghostCollectedOf;

    /// @notice The total reward token ever transferred out to a collecting actor, across both hooks.
    uint256 public ghostCollectedTotal;

    /// @notice True once any tenure claim materialized a different number of new vesting entries than predicted.
    bool public ghostEntitlementCountMismatch;

    /// @notice The reward token ever accepted into custody for one hook.
    /// @custom:param hook The sticky token the rewards were funded for.
    mapping(address hook => uint256) public ghostFundedOf;

    /// @notice The total reward token ever accepted into distributor custody, across both hooks.
    uint256 public ghostFundedTotal;

    /// @notice The most recent tenure group actually funded for one hook (0 if none yet), used to correlate
    /// materialize/collect draws against real inventory instead of drawing independently every time.
    /// @custom:param hook The sticky token the group was funded for.
    mapping(address hook => uint256) public ghostLastFundedCriteriaGroup;

    /// @notice The largest observed gap between a freshly pinned tenure denominator and a brute-force sum of every
    /// actor's live in-window tranches read in the same transaction (0 if they always agreed).
    uint256 public ghostWorstDenominatorMismatch;

    /// @notice The largest observed gap between a tenure claim's harness-derived expected entitlement and what the
    /// contract materialized into a vesting entry (0 if no mismatch has ever been observed).
    /// @dev Ghost-tracked rather than asserted inline: `fail_on_revert = false` treats a revert inside a handler action
    /// as a discarded call, so an inline `assertEq` would vanish instead of failing the campaign.
    uint256 public ghostWorstEntitlementMismatch;

    /// @notice The newest epoch a bucket-affecting action has touched.
    uint256 public maxTouchedEpoch;

    /// @notice The oldest epoch a bucket-affecting action has touched, or `type(uint256).max` if none yet.
    uint256 public minTouchedEpoch = type(uint256).max;

    /// @notice The touched reward round with the highest claimedAmount/amount ratio observed so far.
    JBRewardRoundData public worstRound;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Whether a (hook, groupId, round) triple has been recorded in `_touchedCriteriaRounds`.
    /// @custom:param key The hash of the (hook, groupId, round) triple.
    mapping(bytes32 key => bool) internal _isTouchedCriteriaRound;

    /// @notice Every (hook, groupId, round) tenure round funded so far, in first-funding order.
    TouchedCriteriaRound[] internal _touchedCriteriaRounds;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param stickyHook The hook accounting for both projects' tranches.
    /// @param rewardDistributor The distributor under test.
    /// @param paymentTerminal The terminal both projects are paid through.
    /// @param stakedToken The token staked into both projects.
    /// @param rewardToken The token both projects hand out as a reward.
    /// @param primaryStickyToken The primary project's share token.
    /// @param primaryProjectId The primary project's ID.
    /// @param secondStickyToken The second project's share token.
    /// @param secondProjectId The second project's ID.
    /// @param boundedActors The actor set to drive.
    constructor(
        IJBStickyHook stickyHook,
        JBStickyDistributor rewardDistributor,
        JBMultiTerminal paymentTerminal,
        InvariantErc20 stakedToken,
        InvariantErc20 rewardToken,
        IJBToken primaryStickyToken,
        uint256 primaryProjectId,
        IJBToken secondStickyToken,
        uint256 secondProjectId,
        address[] memory boundedActors
    ) {
        HOOK = stickyHook;
        DISTRIBUTOR = rewardDistributor;
        TERMINAL = paymentTerminal;
        STAKED = stakedToken;
        REWARD = rewardToken;
        STICKY_TOKEN = primaryStickyToken;
        PROJECT_ID = primaryProjectId;
        STICKY_TOKEN_2 = secondStickyToken;
        PROJECT_ID_2 = secondProjectId;
        actors = boundedActors;
        EPOCH_DURATION = stickyHook.EPOCH_DURATION();
    }

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    /// @notice Advances the block number by one before the action runs.
    modifier bumpBlock() {
        vm.roll(vm.getBlockNumber() + 1);
        _;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the primary project's bounded tenure group.
    /// @param actorSeed The seed selecting the actor.
    /// @param groupSeed The seed selecting the tenure group.
    function beginVestingCriteria(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(STICKY_TOKEN),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(STICKY_TOKEN), seed: groupSeed}),
            collect: false
        });
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the second project's bounded tenure group.
    /// @param actorSeed The seed selecting the actor.
    /// @param groupSeed The seed selecting the tenure group.
    function beginVestingCriteria2(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(STICKY_TOKEN_2),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(STICKY_TOKEN_2), seed: groupSeed}),
            collect: false
        });
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the primary project's default group.
    /// @param actorSeed The seed selecting the actor.
    function beginVestingDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(STICKY_TOKEN), actor: _actor(actorSeed), groupId: 0, collect: false});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the second project's default group.
    /// @param actorSeed The seed selecting the actor.
    function beginVestingDefault2(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(STICKY_TOKEN_2), actor: _actor(actorSeed), groupId: 0, collect: false});
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the primary project's bounded tenure
    /// group.
    /// @param actorSeed The seed selecting the actor.
    /// @param groupSeed The seed selecting the tenure group.
    function collectCriteria(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(STICKY_TOKEN),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(STICKY_TOKEN), seed: groupSeed}),
            collect: true
        });
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the second project's bounded tenure
    /// group.
    /// @param actorSeed The seed selecting the actor.
    /// @param groupSeed The seed selecting the tenure group.
    function collectCriteria2(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({
            hookAddr: address(STICKY_TOKEN_2),
            actor: _actor(actorSeed),
            groupId: _criteriaGroupForClaim({hookAddr: address(STICKY_TOKEN_2), seed: groupSeed}),
            collect: true
        });
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the primary project's default group.
    /// @param actorSeed The seed selecting the actor.
    function collectDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(STICKY_TOKEN), actor: _actor(actorSeed), groupId: 0, collect: true});
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the second project's default group.
    /// @param actorSeed The seed selecting the actor.
    function collectDefault2(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(STICKY_TOKEN_2), actor: _actor(actorSeed), groupId: 0, collect: true});
    }

    /// @notice Fund the primary project's bounded tenure group's current round with a bounded amount.
    /// @param groupSeed The seed selecting the tenure group.
    /// @param amountSeed The seed the funded amount is bounded from.
    function fundCriteriaGroup(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(STICKY_TOKEN), groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Fund the second project's bounded tenure group's current round with a bounded amount.
    /// @param groupSeed The seed selecting the tenure group.
    /// @param amountSeed The seed the funded amount is bounded from.
    function fundCriteriaGroup2(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(STICKY_TOKEN_2), groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Fund the primary project's default group's current round with a bounded amount.
    /// @param amountSeed The seed the funded amount is bounded from.
    function fundDefaultGroup(uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(STICKY_TOKEN), groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Fund the second project's default group's current round with a bounded amount.
    /// @param amountSeed The seed the funded amount is bounded from.
    function fundDefaultGroup2(uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(STICKY_TOKEN_2), groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Recycle a bounded expired round in the primary project's bounded tenure group into the current round.
    /// @param groupSeed The seed selecting the tenure group.
    /// @param roundSeed The seed selecting the round to recycle.
    function recycleCriteria(uint256 groupSeed, uint256 roundSeed) external bumpBlock {
        _recycle({groupId: _criteriaGroup(groupSeed), roundSeed: roundSeed});
    }

    /// @notice Recycle a bounded expired round in the primary project's default group into the current round.
    /// @param roundSeed The seed selecting the round to recycle.
    function recycleDefault(uint256 roundSeed) external bumpBlock {
        _recycle({groupId: 0, roundSeed: roundSeed});
    }

    /// @notice Stake a bounded amount of the underlying for a bounded actor in the primary (transferable) project.
    /// @param actorSeed The seed selecting the actor.
    /// @param amountSeed The seed the staked amount is bounded from.
    function stake(uint256 actorSeed, uint256 amountSeed) external bumpBlock {
        _stakeIn({
            targetProjectId: PROJECT_ID, actor: _actor(actorSeed), amount: bound(amountSeed, 1, _MAX_STAKE_AMOUNT)
        });
        _trackStakeEpoch();
    }

    /// @notice Stake a bounded amount for a bounded actor in the second (soulbound) project.
    /// @param actorSeed The seed selecting the actor.
    /// @param amountSeed The seed the staked amount is bounded from.
    function stake2(uint256 actorSeed, uint256 amountSeed) external bumpBlock {
        _stakeIn({
            targetProjectId: PROJECT_ID_2, actor: _actor(actorSeed), amount: bound(amountSeed, 1, _MAX_STAKE_AMOUNT)
        });
    }

    /// @notice Transfer a bounded amount of the transferable sticky token between two bounded actors.
    /// @param fromSeed The seed selecting the sender.
    /// @param toSeed The seed selecting the receiver.
    /// @param amountSeed The seed the transferred amount is bounded from.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external bumpBlock {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, STICKY_TOKEN.balanceOf(from));
        if (amount == 0) return;

        vm.prank(from);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(address(STICKY_TOKEN)).transfer({to: to, value: amount});

        // The receiver's moved tokens land in a tranche timestamped at the transfer.
        _trackStakeEpoch();
    }

    /// @notice Unstake a bounded amount (partial or full) for a bounded actor in the primary project.
    /// @param actorSeed The seed selecting the actor.
    /// @param countSeed The seed the unstaked count is bounded from.
    function unstake(uint256 actorSeed, uint256 countSeed) external bumpBlock {
        address actor = _actor(actorSeed);
        uint256 balance = HOOK.stakedBalanceOf({projectId: PROJECT_ID, holder: actor});
        uint256 count = bound(countSeed, 0, balance);
        if (count == 0) return;

        vm.prank(actor);
        // forge-lint: disable-next-item(unused-return)
        TERMINAL.cashOutTokensOf({
            holder: actor,
            projectId: PROJECT_ID,
            cashOutCount: count,
            tokenToReclaim: address(STAKED),
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: bytes("")
        });
    }

    /// @notice Warp forward by a bounded jump so rounds and epochs advance.
    /// @dev Bounded by the distributor's actual `ROUND_DURATION`, so a single jump can never exceed one round.
    /// @param jumpSeed The seed the jump is bounded from.
    function warp(uint256 jumpSeed) external bumpBlock {
        uint256 jump = bound(jumpSeed, 1, DISTRIBUTOR.ROUND_DURATION());
        vm.warp(vm.getBlockTimestamp() + jump);
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The number of bounded actors this suite drives.
    /// @return length The actor count.
    function actorsLength() external view returns (uint256 length) {
        return actors.length;
    }

    /// @notice The sum of every touched epoch's still-held bucket for the primary project.
    /// @return total The summed buckets.
    function sumBuckets() external view returns (uint256 total) {
        if (maxTouchedEpoch < minTouchedEpoch) return 0;
        for (uint256 epoch = minTouchedEpoch; epoch <= maxTouchedEpoch; epoch++) {
            // forge-lint: disable-next-line(calls-loop)
            total += HOOK.netStakedIn({projectId: PROJECT_ID, epoch: epoch});
        }
    }

    /// @notice The sum of every bounded actor's staked balance in the primary project.
    /// @return total The summed balances.
    function sumStakedBalances() external view returns (uint256 total) {
        uint256 length = actors.length;
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            total += HOOK.stakedBalanceOf({projectId: PROJECT_ID, holder: actors[i]});
        }
    }

    /// @notice One touched (hook, groupId, round) tenure round, by index.
    /// @param index The index into the touched rounds.
    /// @return hookAddr The sticky token whose round was funded.
    /// @return groupId The tenure group that was funded.
    /// @return round The round that was funded.
    function touchedCriteriaRoundAt(uint256 index)
        external
        view
        returns (address hookAddr, uint256 groupId, uint256 round)
    {
        TouchedCriteriaRound storage touched = _touchedCriteriaRounds[index];
        return (touched.hook, touched.groupId, touched.round);
    }

    /// @notice The number of distinct (hook, groupId, round) tenure rounds ever funded.
    /// @return length The touched round count.
    function touchedCriteriaRoundsLength() external view returns (uint256 length) {
        return _touchedCriteriaRounds.length;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Every bounded actor's live tranche weight inside `[lo, hi]` for one project, read straight from
    /// `HOOK.tranchesOf` rather than any distributor helper.
    /// @param targetProjectId The project whose tranches are summed.
    /// @param lo The first epoch counted.
    /// @param hi The last epoch counted.
    /// @return sum The summed tranche amounts.
    function liveWindowSum(uint256 targetProjectId, uint256 lo, uint256 hi) public view returns (uint256 sum) {
        uint256 actorsLength_ = actors.length;
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 a; a < actorsLength_; a++) {
            sum += _actorWindowWeight({targetProjectId: targetProjectId, actor: actors[a], lo: lo, hi: hi});
        }
    }

    /// @notice The epoch window a tenure group selects for a round, derived independently of the distributor.
    /// @param groupId The tenure group.
    /// @param round The round whose snapshot epoch anchors the window.
    /// @return lo The first eligible epoch, or 0 when unbounded below.
    /// @return hi The last eligible epoch.
    /// @return isEmpty Whether no epoch can qualify.
    function windowOf(uint256 groupId, uint256 round) public view returns (uint256 lo, uint256 hi, bool isEmpty) {
        uint256 snapshotEpoch = DISTRIBUTOR.snapshotEpochOf(round);
        uint256 base = DISTRIBUTOR.CRITERIA_BASE();
        uint256 minWeeks = groupId / base;
        uint256 maxWeeks = groupId % base;
        // forge-lint: disable-next-line(boolean-cst)
        if (snapshotEpoch < minWeeks) return (0, 0, true);
        hi = snapshotEpoch - minWeeks;
        lo = maxWeeks == 0 || snapshotEpoch < maxWeeks ? 0 : snapshotEpoch - maxWeeks;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Begins vesting (and optionally collects) `actor`'s unclaimed rounds for one hook, then sweeps exactly
    /// the round range the distributor just walked internally to refresh `worstRound`.
    /// @param hookAddr The sticky token whose rounds are claimed.
    /// @param actor The actor whose rounds are claimed.
    /// @param groupId The group claimed in.
    /// @param collect Whether to collect unlocked rewards instead of only beginning vesting.
    function _claimAndSweep(address hookAddr, address actor, uint256 groupId, bool collect) internal {
        uint256 tokenId = uint256(uint160(actor));
        IERC20 token = IERC20(address(REWARD));
        uint256 firstRound = DISTRIBUTOR.nextClaimRoundOf(hookAddr, groupId, tokenId, token);
        uint256 round = DISTRIBUTOR.currentRound();

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
            uint256 balanceBefore = REWARD.balanceOf(actor);
            if (groupId == 0) {
                DISTRIBUTOR.collectVestedRewards({
                    hook: hookAddr, tokenIds: _tokenIds(actor), tokens: _tokens(), beneficiary: actor
                });
            } else {
                DISTRIBUTOR.collectVestedRewards({
                    hook: hookAddr, groupId: groupId, tokenIds: _tokenIds(actor), tokens: _tokens(), beneficiary: actor
                });
            }
            uint256 delta = REWARD.balanceOf(actor) - balanceBefore;
            ghostCollectedOf[hookAddr] += delta;
            ghostCollectedTotal += delta;
        } else if (groupId == 0) {
            DISTRIBUTOR.beginVesting({hook: hookAddr, tokenIds: _tokenIds(actor), tokens: _tokens()});
        } else {
            DISTRIBUTOR.beginVesting({hook: hookAddr, groupId: groupId, tokenIds: _tokenIds(actor), tokens: _tokens()});
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

    /// @notice Funds one hook's group with a bounded amount of the reward token, recording the custody delta and,
    /// for a tenure group's first funding of a round, the pinned denominator check.
    /// @param hookAddr The sticky token whose group is funded.
    /// @param groupId The group funded.
    /// @param amountSeed The seed the funded amount is bounded from.
    function _fund(address hookAddr, uint256 groupId, uint256 amountSeed) internal {
        uint256 amount = bound(amountSeed, 0, _MAX_FUND_AMOUNT);
        if (amount == 0) return;

        uint256 round = DISTRIBUTOR.currentRound();
        // forge-lint: disable-next-line(unused-return)
        (uint208 amountBefore,,,,) = DISTRIBUTOR.rewardRoundOf(hookAddr, groupId, IERC20(address(REWARD)), round);

        REWARD.mint({to: address(this), amount: amount});
        // forge-lint: disable-next-line(unused-return)
        REWARD.approve({spender: address(DISTRIBUTOR), value: amount});
        uint256 balanceBefore = REWARD.balanceOf(address(DISTRIBUTOR));

        if (groupId == 0) {
            DISTRIBUTOR.fund({hook: hookAddr, token: IERC20(address(REWARD)), amount: amount});
        } else {
            DISTRIBUTOR.fund({hook: hookAddr, token: IERC20(address(REWARD)), amount: amount, groupId: groupId});
        }

        uint256 delta = REWARD.balanceOf(address(DISTRIBUTOR)) - balanceBefore;
        ghostFundedOf[hookAddr] += delta;
        ghostFundedTotal += delta;

        if (groupId != 0 && delta > 0) {
            ghostLastFundedCriteriaGroup[hookAddr] = groupId;
            _recordTouchedCriteriaRound({hookAddr: hookAddr, groupId: groupId, round: round});

            // The first funding of a round pins its denominator from the hook's buckets. Nothing else moved in this
            // transaction, so a brute-force sum of every actor's live in-window tranches must match it exactly.
            if (amountBefore == 0) _recordDenominatorCheck({hookAddr: hookAddr, groupId: groupId, round: round});
        }
    }

    /// @notice Records (without reverting) whether the contract materialized exactly the predicted vesting entry.
    /// @param hookAddr The sticky token whose vesting entries are read.
    /// @param groupId The group claimed in.
    /// @param tokenId The actor's token ID.
    /// @param token The reward token.
    /// @param vestingCountBefore The actor's vesting entry count before the claim.
    /// @param expectedShare The amount the claim is expected to materialize.
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
            if (vestingCountAfter != vestingCountBefore) ghostEntitlementCountMismatch = true;
            return;
        }

        if (vestingCountAfter != vestingCountBefore + 1) {
            ghostEntitlementCountMismatch = true;
            return;
        }

        // forge-lint: disable-next-line(unused-return)
        (, uint256 actualAmount,) = DISTRIBUTOR.vestingDataOf(hookAddr, groupId, tokenId, token, vestingCountBefore);
        uint256 diff = actualAmount > expectedShare ? actualAmount - expectedShare : expectedShare - actualAmount;
        if (diff > ghostWorstEntitlementMismatch) ghostWorstEntitlementMismatch = diff;
    }

    /// @notice Compares a freshly pinned denominator with an independent brute-force window sum.
    /// @param hookAddr The sticky token whose round was pinned.
    /// @param groupId The tenure group pinned.
    /// @param round The round pinned.
    function _recordDenominatorCheck(address hookAddr, uint256 groupId, uint256 round) internal {
        // forge-lint: disable-next-line(unused-return)
        (,,,, uint208 totalStake) = DISTRIBUTOR.rewardRoundOf(hookAddr, groupId, IERC20(address(REWARD)), round);
        (uint256 lo, uint256 hi, bool isEmpty) = windowOf({groupId: groupId, round: round});
        uint256 expected = isEmpty
            ? 0
            : liveWindowSum({
                targetProjectId: hookAddr == address(STICKY_TOKEN) ? PROJECT_ID : PROJECT_ID_2, lo: lo, hi: hi
            });
        uint256 diff = expected > totalStake ? expected - totalStake : totalStake - expected;
        if (diff > ghostWorstDenominatorMismatch) ghostWorstDenominatorMismatch = diff;
    }

    /// @notice Records a (hook, groupId, round) triple the first time it is funded.
    /// @param hookAddr The sticky token whose round was funded.
    /// @param groupId The tenure group funded.
    /// @param round The round funded.
    function _recordTouchedCriteriaRound(address hookAddr, uint256 groupId, uint256 round) internal {
        bytes32 key = keccak256(abi.encode(hookAddr, groupId, round));
        if (_isTouchedCriteriaRound[key]) return;
        _isTouchedCriteriaRound[key] = true;
        _touchedCriteriaRounds.push(TouchedCriteriaRound({hook: hookAddr, groupId: groupId, round: round}));
    }

    /// @notice Recycles one bounded round of the primary project's group into the current round, refreshing
    /// `worstRound` for both.
    /// @param groupId The group recycled.
    /// @param roundSeed The seed selecting the round to recycle.
    function _recycle(uint256 groupId, uint256 roundSeed) internal {
        uint256 currentR = DISTRIBUTOR.currentRound();
        uint256 round = bound(roundSeed, 0, currentR);
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = round;

        if (groupId == 0) {
            // forge-lint: disable-next-item(unused-return)
            DISTRIBUTOR.recycleExpiredRewards({
                hook: address(STICKY_TOKEN), token: IERC20(address(REWARD)), rounds: rounds
            });
        } else {
            (
                uint208 amountBefore,,,,
                // forge-lint: disable-next-line(unused-return)
            ) = DISTRIBUTOR.rewardRoundOf(address(STICKY_TOKEN), groupId, IERC20(address(REWARD)), currentR);
            uint256 recycled = DISTRIBUTOR.recycleExpiredRewards({
                hook: address(STICKY_TOKEN), groupId: groupId, token: IERC20(address(REWARD)), rounds: rounds
            });
            // A positive recycle funds the current round exactly like `_fund` does, pinning its denominator when it
            // is the round's first funding.
            if (recycled != 0) {
                _recordTouchedCriteriaRound({hookAddr: address(STICKY_TOKEN), groupId: groupId, round: currentR});
                if (amountBefore == 0) {
                    _recordDenominatorCheck({hookAddr: address(STICKY_TOKEN), groupId: groupId, round: currentR});
                }
            }
        }

        _updateWorstRound({hookAddr: address(STICKY_TOKEN), groupId: groupId, round: round});
        _updateWorstRound({hookAddr: address(STICKY_TOKEN), groupId: groupId, round: currentR});
    }

    /// @notice Stakes the underlying for an actor into a project through the terminal.
    /// @param targetProjectId The project staked into.
    /// @param actor The actor that stakes.
    /// @param amount The amount of the underlying staked.
    function _stakeIn(uint256 targetProjectId, address actor, uint256 amount) internal {
        STAKED.mint({to: actor, amount: amount});
        vm.startPrank(actor);
        // forge-lint: disable-next-line(unused-return)
        STAKED.approve({spender: address(TERMINAL), value: amount});
        // forge-lint: disable-next-item(unused-return)
        TERMINAL.pay({
            projectId: targetProjectId,
            token: address(STAKED),
            amount: amount,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
    }

    /// @notice Widens the touched epoch range to include the current epoch.
    function _trackStakeEpoch() internal {
        uint256 epoch = vm.getBlockTimestamp() / EPOCH_DURATION;
        if (epoch < minTouchedEpoch) minTouchedEpoch = epoch;
        if (epoch > maxTouchedEpoch) maxTouchedEpoch = epoch;
    }

    /// @notice Refreshes `worstRound` if the given round's claimedAmount/amount ratio is the highest observed so far.
    /// @param hookAddr The sticky token whose round is read.
    /// @param groupId The group read.
    /// @param round The round read.
    function _updateWorstRound(address hookAddr, uint256 groupId, uint256 round) internal {
        (
            uint208 amount,
            uint48 snapshotBlock,
            uint208 claimedAmount,
            uint48 claimDeadline,
            uint208 totalStake
            // forge-lint: disable-next-line(calls-loop)
        ) = DISTRIBUTOR.rewardRoundOf(hookAddr, groupId, IERC20(address(REWARD)), round);

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

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Picks one of the encoded `minWeeks * CRITERIA_BASE + maxWeeks` groups exercised by this suite: two
    /// tenure windows (bounded min, unbounded max), two recency windows (min = 1, bounded max), and two cohort windows.
    /// @param seed The seed selecting the group.
    /// @return groupId The selected group.
    function _criteriaGroup(uint256 seed) internal pure returns (uint256 groupId) {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[6] memory groups =
            [uint256(2000), uint256(4000), uint256(1002), uint256(1004), uint256(2004), uint256(4008)];
        // forge-lint: disable-next-line(literal-instead-of-constant)
        return groups[seed % 6];
    }

    /// @notice The token ID list holding only an actor's ID.
    /// @param actor The actor whose ID is listed.
    /// @return tokenIds A single-element list holding the actor's address as an ID.
    function _tokenIds(address actor) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(actor));
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The bounded actor a seed selects.
    /// @param seed The seed selecting the actor.
    /// @return actor The selected actor.
    function _actor(uint256 seed) internal view returns (address actor) {
        return actors[seed % actors.length];
    }

    /// @notice One actor's live tranche weight inside `[lo, hi]`, read straight from `HOOK.tranchesOf`.
    /// @param targetProjectId The project whose tranches are read.
    /// @param actor The actor whose tranches are read.
    /// @param lo The first epoch counted.
    /// @param hi The last epoch counted.
    /// @return weight The summed tranche amounts.
    function _actorWindowWeight(
        uint256 targetProjectId,
        address actor,
        uint256 lo,
        uint256 hi
    )
        internal
        view
        returns (uint256 weight)
    {
        // forge-lint: disable-next-line(calls-loop)
        JBStickyTranche[] memory tranches = HOOK.tranchesOf(targetProjectId, actor);
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 t; t < tranches.length; t++) {
            uint256 epoch = uint256(tranches[t].timestamp) / EPOCH_DURATION;
            if (epoch < lo || epoch > hi) continue;
            weight += tranches[t].amount;
        }
    }

    /// @notice Picks a group for a materialize/collect action, reusing the last funded group about half the time so
    /// claims land on real inventory, and drawing independently otherwise so unfunded groups stay safe no-ops.
    /// The reuse decision reads `seed / 6`, not `seed % 6`, so it is independent of the group drawn.
    /// @param hookAddr The sticky token whose last funded group may be reused.
    /// @param seed The seed selecting the group.
    /// @return groupId The selected group.
    function _criteriaGroupForClaim(address hookAddr, uint256 seed) internal view returns (uint256 groupId) {
        uint256 lastFunded = ghostLastFundedCriteriaGroup[hookAddr];
        // forge-lint: disable-next-line(literal-instead-of-constant)
        bool reuseLastFunded = (seed / 6) % 2 == 0;
        if (lastFunded != 0 && reuseLastFunded) return lastFunded;
        return _criteriaGroup(seed);
    }

    /// @notice Determines whether this claim is checkable for exact per-actor entitlement (exactly one pending,
    /// unexpired round), and if so precomputes the expected materialized amount and the pre-call vesting count.
    /// @dev A harness-computed zero weight still runs the check with `expectedShare == 0`, which the recorder turns
    /// into "no new vesting entry must appear": the case that catches a widened claim window.
    /// @param hookAddr The sticky token whose round is claimed.
    /// @param actor The actor claiming.
    /// @param groupId The group claimed in.
    /// @param tokenId The actor's token ID.
    /// @param token The reward token.
    /// @param firstRound The actor's next unclaimed round.
    /// @param round The current round.
    /// @return checkEntitlement Whether the claim is checkable.
    /// @return expectedShare The amount the claim is expected to materialize.
    /// @return vestingCountBefore The actor's vesting entry count before the claim.
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
        // forge-lint: disable-next-line(boolean-cst)
        if (groupId == 0 || round == 0 || round - firstRound != 1) return (false, 0, 0);

        (
            uint208 amount,,
            uint208 claimedAmount,,
            uint208 totalStake
            // forge-lint: disable-next-line(unused-return)
        ) = DISTRIBUTOR.rewardRoundOf(hookAddr, groupId, token, firstRound);
        // forge-lint: disable-next-line(boolean-cst)
        if (totalStake == 0) return (false, 0, 0);

        (uint256 lo, uint256 hi, bool isEmpty) = windowOf({groupId: groupId, round: firstRound});
        // forge-lint: disable-next-line(boolean-cst)
        if (isEmpty) return (false, 0, 0);

        uint256 targetProjectId = hookAddr == address(STICKY_TOKEN) ? PROJECT_ID : PROJECT_ID_2;
        uint256 weight = _actorWindowWeight({targetProjectId: targetProjectId, actor: actor, lo: lo, hi: hi});

        // Mirrors the contract's arithmetic, including its remaining-pot clamp, so an earlier claim or recycle that
        // already settled part of this round cannot produce a false positive.
        uint256 rawShare = mulDiv(uint256(amount), weight, uint256(totalStake));
        uint256 remainingPot = uint256(amount) - uint256(claimedAmount);
        expectedShare = rawShare > remainingPot ? remainingPot : rawShare;

        vestingCountBefore = _vestingEntryCount({hookAddr: hookAddr, groupId: groupId, tokenId: tokenId, token: token});
        checkEntitlement = true;
    }

    /// @notice The token list holding only the reward token.
    /// @return tokens A single-element list holding the reward token.
    function _tokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(REWARD));
    }

    /// @notice Probes `vestingDataOf`'s length by reading indices until the auto-generated getter reverts.
    /// @param hookAddr The sticky token whose vesting entries are read.
    /// @param groupId The group read.
    /// @param tokenId The actor's token ID.
    /// @param token The reward token.
    /// @return length The number of vesting entries.
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
            // forge-lint: disable-next-line(calls-loop)
            try DISTRIBUTOR.vestingDataOf(hookAddr, groupId, tokenId, token, length) returns (
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
}

/// @notice Invariant suite: the distributor can never over-promise its reward-token inventory, one hook's custody
/// can never leak into another's, the primary project's per-epoch buckets always sum to exactly what is staked, and
/// tenure denominators and entitlements always agree with independent brute-force recomputations.
// forge-lint: disable-next-line(multi-contract-file)
contract JBStickyDistributorInvariantTest is TestBaseWorkflow {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice How long a funded round stays claimable.
    uint48 constant _CLAIM_DURATION = 6 weeks;

    /// @notice How long each distributor round lasts.
    /// @dev Two-week rounds: the smoke test's four-week warp then starts a round exactly four epochs after the stake,
    /// which is the single offset that lands the stake inside a tenure(2+), a recency(1-4) and a cohort(4-8) window
    /// at once.
    uint256 constant _ROUND_DURATION = 2 weeks;

    /// @notice The number of rounds a claimed reward vests over.
    uint256 constant _VESTING_ROUNDS = 2;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The deployer that launches both Sticky projects.
    JBStickyDeployer _deployer;

    /// @notice The distributor under test.
    JBStickyDistributor _distributor;

    /// @notice The handler the fuzzer drives.
    JBStickyDistributorHandler _handler;

    /// @notice The hook accounting for both projects' tranches.
    IJBStickyHook _hook;

    /// @notice The primary (transferable) project's ID.
    uint256 _projectId;

    /// @notice The second (soulbound) project's ID.
    uint256 _projectId2;

    /// @notice The token both projects hand out as a reward.
    InvariantErc20 _reward;

    /// @notice The token staked into both projects.
    InvariantErc20 _staked;

    /// @notice The primary project's share token.
    IJBToken _stickyToken;

    /// @notice The second project's share token.
    IJBToken _stickyToken2;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();

        _staked = new InvariantErc20("Staked", "STK");
        _reward = new InvariantErc20("Reward", "RWD");

        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = _deployer.HOOK();

        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), 2 * fee);
        // forge-lint: disable-next-item(arbitrary-send-eth)
        _projectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_staked)),
            name: "Sticky",
            symbol: "STICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        _stickyToken = jbTokens().tokenOf(_projectId);

        // A second, soulbound sticky project sharing the same staked and reward tokens, so custody isolation between
        // hooks is actually exercised instead of assumed.
        // forge-lint: disable-next-item(arbitrary-send-eth)
        _projectId2 = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_staked)),
            name: "Sticky 2",
            symbol: "STICKY2",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        _stickyToken2 = jbTokens().tokenOf(_projectId2);

        _distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: _CLAIM_DURATION
        });

        // forge-lint: disable-next-line(literal-instead-of-constant)
        address[] memory actors = new address[](5);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        actors[3] = makeAddr("actor3");
        actors[4] = makeAddr("actor4");

        _handler = new JBStickyDistributorHandler({
            stickyHook: _hook,
            rewardDistributor: _distributor,
            paymentTerminal: jbMultiTerminal(),
            stakedToken: _staked,
            rewardToken: _reward,
            primaryStickyToken: _stickyToken,
            primaryProjectId: _projectId,
            secondStickyToken: _stickyToken2,
            secondProjectId: _projectId2,
            boundedActors: actors
        });

        targetContract(address(_handler));
    }

    /// @notice Non-vacuousness tripwire: deterministically drives the handler through fund, warp and collect for both
    /// hooks and every window shape, asserting the ghost totals actually moved.
    /// @dev A plain test rather than `afterInvariant()`, which runs once per independent fuzz run and can legitimately
    /// draw only zero-amount fund calls within one run's depth budget.
    function test_handlerReachesNonzeroFundingAndCollection() public {
        address actor = _handler.actors(0);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.stake({actorSeed: 0, amountSeed: 100e18});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.stake2({actorSeed: 0, amountSeed: 100e18});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.fundDefaultGroup({amountSeed: 100e18});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.fundDefaultGroup2({amountSeed: 100e18});

        // Age the stake four weeks before pinning any tenure round: two round-length jumps, since `warp` bounds a
        // single jump to `ROUND_DURATION`. The round starting now therefore snapshots four epochs after the stake.
        uint256 timestampBeforeAging = vm.getBlockTimestamp();
        _handler.warp({jumpSeed: _ROUND_DURATION});
        _handler.warp({jumpSeed: _ROUND_DURATION});
        assertEq(vm.getBlockTimestamp() - timestampBeforeAging, 4 weeks, "pre-fund aging warp must total 4 weeks");
        assertEq(
            _distributor.snapshotEpochOf(_distributor.currentRound()),
            timestampBeforeAging / 1 weeks + 4,
            "the current round must snapshot four epochs after the stake"
        );

        // `_criteriaGroup`'s array is `[2000, 4000, 1002, 1004, 2004, 4008]`; seeds 0, 3 and 5 select one shape each.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.fundCriteriaGroup({groupSeed: 0, amountSeed: 100e18}); // tenure: 2+ weeks
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.fundCriteriaGroup({groupSeed: 3, amountSeed: 100e18}); // recency: last 4 completed weeks
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _handler.fundCriteriaGroup({groupSeed: 5, amountSeed: 100e18}); // cohort: 4-8 weeks
        assertEq(_handler.ghostWorstDenominatorMismatch(), 0);

        // Seeds 6, 9 and 11 land on the same shapes while forcing `(seed / 6) % 2 == 1`, so each collect exercises the
        // shape it names rather than whatever was funded last.
        uint256 tenureSeed = 6;
        uint256 recencySeed = 9;
        uint256 cohortSeed = 11;

        // One round in: materialize each funded round into a vesting entry. Still fully locked, so nothing moves yet.
        _handler.warp({jumpSeed: _ROUND_DURATION});
        _handler.collectDefault({actorSeed: 0});
        _handler.collectDefault2({actorSeed: 0});
        _handler.collectCriteria({actorSeed: 0, groupSeed: tenureSeed});
        _handler.collectCriteria({actorSeed: 0, groupSeed: recencySeed});
        _handler.collectCriteria({actorSeed: 0, groupSeed: cohortSeed});
        assertEq(_handler.ghostWorstEntitlementMismatch(), 0);
        assertFalse(_handler.ghostEntitlementCountMismatch());

        // Halfway through the two-round vesting schedule: collect again to receive the unlocked half.
        _handler.warp({jumpSeed: _ROUND_DURATION});
        _handler.collectDefault({actorSeed: 0});
        _handler.collectDefault2({actorSeed: 0});

        uint256 balanceBeforeTenure = _reward.balanceOf(actor);
        _handler.collectCriteria({actorSeed: 0, groupSeed: tenureSeed});
        assertGt(_reward.balanceOf(actor) - balanceBeforeTenure, 0, "tenure window paid nothing");

        uint256 balanceBeforeRecency = _reward.balanceOf(actor);
        _handler.collectCriteria({actorSeed: 0, groupSeed: recencySeed});
        assertGt(_reward.balanceOf(actor) - balanceBeforeRecency, 0, "recency window paid nothing");

        uint256 balanceBeforeCohort = _reward.balanceOf(actor);
        _handler.collectCriteria({actorSeed: 0, groupSeed: cohortSeed});
        assertGt(_reward.balanceOf(actor) - balanceBeforeCohort, 0, "cohort window paid nothing");

        assertGt(_handler.ghostFundedTotal(), 0);
        assertGt(_handler.ghostCollectedTotal(), 0);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The primary project's hook buckets always sum to exactly the actor set's staked balances, and to the
    /// token supply.
    function invariant_bucketConservation() public view {
        assertEq(_handler.sumBuckets(), _handler.sumStakedBalances());
        assertEq(_handler.sumBuckets(), _stickyToken.totalSupply());
    }

    /// @notice Every checkable tenure claim materialized exactly the vesting entry an independent per-actor
    /// entitlement predicted, including that a zero-weight claim produced no entry at all. This is the check that
    /// conservation invariants cannot make: the pot-remainder clamp turns a too-wide window into misdistribution,
    /// not a solvency breach.
    function invariant_criteriaClaimEntitlement() public view {
        assertEq(_handler.ghostWorstEntitlementMismatch(), 0);
        assertFalse(_handler.ghostEntitlementCountMismatch());
    }

    /// @notice For every tenure round ever funded, independently recomputes the window-stake sum from live tranches
    /// and asserts it never exceeds the round's recorded `totalStake`.
    /// @dev `<=`, not `==`: live tranches can only have shrunk since the round's denominator was pinned. Exits reduce
    /// a holder's own tranches, and `minWeeks >= 1` keeps the round's own epoch out of every window so nothing staked
    /// later can land inside it. Exact agreement at pin time is checked by `invariant_denominatorMatchesBruteForce`.
    function invariant_criteriaWindowSolvency() public view {
        uint256 roundsLength = _handler.touchedCriteriaRoundsLength();
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < roundsLength; i++) {
            // forge-lint: disable-next-line(calls-loop)
            (address hookAddr, uint256 groupId, uint256 round) = _handler.touchedCriteriaRoundAt(i);
            _assertCriteriaRoundWindowSolvency({hookAddr: hookAddr, groupId: groupId, round: round});
        }
    }

    /// @notice Every freshly pinned tenure denominator equalled an independent brute-force sum of every actor's
    /// in-window tranches read in the same transaction.
    function invariant_denominatorMatchesBruteForce() public view {
        assertEq(_handler.ghostWorstDenominatorMismatch(), 0);
    }

    /// @notice One hook's reward-token custody can never leak into another's, even though both hooks' funds sit in
    /// the same ERC-20 balance. Every assertion is an equality: `_balanceOf` only ever moves by exact deltas.
    function invariant_hookCustodyIsolation() public view {
        uint256 hook1Balance = _distributor.balanceOf(address(_stickyToken), _reward);
        uint256 hook2Balance = _distributor.balanceOf(address(_stickyToken2), _reward);

        assertEq(hook1Balance + hook2Balance, _handler.ghostFundedTotal() - _handler.ghostCollectedTotal());
        assertEq(
            hook1Balance,
            _handler.ghostFundedOf(address(_stickyToken)) - _handler.ghostCollectedOf(address(_stickyToken))
        );
        assertEq(
            hook2Balance,
            _handler.ghostFundedOf(address(_stickyToken2)) - _handler.ghostCollectedOf(address(_stickyToken2))
        );
    }

    /// @notice The reward token can never be over-promised: the distributor's balance always covers every unit funded
    /// but not yet collected, and no touched round's claimed amount ever exceeds its funded amount.
    function invariant_potSolvency() public view {
        assertGe(_reward.balanceOf(address(_distributor)), _handler.ghostFundedTotal() - _handler.ghostCollectedTotal());

        // forge-lint: disable-next-line(unused-return)
        (uint208 amount,, uint208 claimedAmount,,) = _handler.worstRound();
        assertGe(amount, claimedAmount);
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Independently recomputes one touched tenure round's live window-stake sum and asserts it against the
    /// round's recorded denominator. Split out of `invariant_criteriaWindowSolvency`'s loop to stay within the Yul
    /// stack under `via_ir`.
    /// @param hookAddr The sticky token whose round is checked.
    /// @param groupId The tenure group checked.
    /// @param round The round checked.
    function _assertCriteriaRoundWindowSolvency(address hookAddr, uint256 groupId, uint256 round) internal view {
        // forge-lint: disable-next-line(calls-loop,unused-return)
        (uint208 amount,,,, uint208 totalStake) = _distributor.rewardRoundOf(hookAddr, groupId, _reward, round);

        // Only a funded round has a pinned denominator to compare against.
        if (amount == 0) return;

        // forge-lint: disable-next-line(calls-loop)
        (uint256 lo, uint256 hi, bool isEmpty) = _handler.windowOf({groupId: groupId, round: round});
        if (isEmpty) return;

        uint256 targetProjectId = hookAddr == address(_stickyToken) ? _projectId : _projectId2;
        // forge-lint: disable-next-line(calls-loop)
        assertLe(_handler.liveWindowSum({targetProjectId: targetProjectId, lo: lo, hi: hi}), uint256(totalStake));
    }
}
