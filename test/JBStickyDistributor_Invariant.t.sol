// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyRewardRoundData} from "../src/structs/JBStickyRewardRoundData.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice An 18-decimal ERC-20 standing in for the staked and reward tokens driven by the invariant handler.
contract InvariantErc20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice Drives a bounded actor set through every distributor and hook entrypoint against two sticky projects —
/// one transferable, one soulbound — that share the same reward token, tracking the ghost accounting
/// `JBStickyDistributorInvariantTest` checks its invariants against.
/// @dev Every action bumps the block number first, so group-0 votes snapshots (which require a strictly past block)
/// never revert regardless of call order. The second project keeps a lean action set (stake, fund, claim only — no
/// transfer, unstake, or recycle) since it exists solely to exercise per-hook custody isolation, not bucket
/// conservation.
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

    /// @notice The total amount of the reward token ever actually accepted into distributor custody, across both
    /// hooks.
    uint256 public ghost_fundedTotal;

    /// @notice The total amount of the reward token ever actually transferred out to a collecting actor, across
    /// both hooks.
    uint256 public ghost_collectedTotal;

    /// @notice The amount of the reward token ever actually accepted into custody for one hook.
    /// @custom:param hook The sticky token the funding was credited to.
    mapping(address hook => uint256) public ghost_fundedOf;

    /// @notice The amount of the reward token ever actually transferred out to a collecting actor for one hook.
    /// @custom:param hook The sticky token the collection was debited from.
    mapping(address hook => uint256) public ghost_collectedOf;

    /// @notice The most recent criteria groupId actually funded for one hook (0 if none yet), used to correlate
    /// materialize/collect draws against real inventory instead of drawing independently every time.
    /// @custom:param hook The sticky token the funding was credited to.
    mapping(address hook => uint256) public ghost_lastFundedCriteriaGroup;

    /// @notice One (hook, groupId, round) triple whose criteria round has received at least one dollar of funding,
    /// tracked so `invariant_criteriaWindowSolvency` can recompute the window independently against live tranches.
    struct TouchedCriteriaRound {
        address hook;
        uint256 groupId;
        uint256 round;
    }

    TouchedCriteriaRound[] internal _touchedCriteriaRounds;
    mapping(bytes32 key => bool) internal _isTouchedCriteriaRound;

    /// @notice The touched reward round with the highest claimedAmount/amount ratio observed so far.
    JBStickyRewardRoundData public worstRound;

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
    // ------------------------------ actions ------------------------------ //
    //*********************************************************************//

    modifier bumpBlock() {
        vm.roll(vm.getBlockNumber() + 1);
        _;
    }

    /// @notice Stake a bounded amount of the underlying for a bounded actor in the primary (transferable) project.
    function stake(uint256 actorSeed, uint256 amountSeed) external bumpBlock {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, MAX_STAKE_AMOUNT);

        staked.mint({to: actor, amount: amount});
        vm.startPrank(actor);
        staked.approve({spender: address(terminal), value: amount});
        terminal.pay({
            projectId: projectId,
            token: address(staked),
            amount: amount,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();

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
        uint256 balance = stickyToken.balanceOf(from);
        uint256 amount = bound(amountSeed, 0, balance);
        if (amount == 0) return;

        vm.prank(from);
        IERC20(address(stickyToken)).transfer({to: to, value: amount});

        // The receiver's moved tokens land in a fresh tranche timestamped now.
        _trackStakeEpoch();
    }

    /// @notice Stake a bounded amount of the underlying for a bounded actor in the second (soulbound) project — the
    /// only entrypoint that ever touches `projectId2`, so this project exists purely to give the distributor a
    /// second hook whose custody must never leak into the first.
    function stake2(uint256 actorSeed, uint256 amountSeed) external bumpBlock {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, MAX_STAKE_AMOUNT);

        staked.mint({to: actor, amount: amount});
        vm.startPrank(actor);
        staked.approve({spender: address(terminal), value: amount});
        terminal.pay({
            projectId: projectId2,
            token: address(staked),
            amount: amount,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
    }

    /// @notice Fund the primary project's default (votes-weighted) group's current round with a bounded amount.
    function fundDefaultGroup(uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken), groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Fund the primary project's bounded stick-time criteria group's current round with a bounded amount.
    function fundCriteriaGroup(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken), groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Fund the second project's default group's current round with a bounded amount, from the same reward
    /// token as the primary project.
    function fundDefaultGroup2(uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken2), groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Fund the second project's bounded stick-time criteria group's current round with a bounded amount.
    function fundCriteriaGroup2(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({hookAddr: address(stickyToken2), groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the primary project's default group.
    function beginVestingDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({hookAddr: address(stickyToken), actor: _actor(actorSeed), groupId: 0, collect: false});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the primary project's bounded criteria group.
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

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the primary project's bounded
    /// criteria group.
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

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the second project's bounded criteria group.
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

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the second project's bounded criteria
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

    /// @notice Recycle a bounded expired round in the primary project's bounded criteria group into the current
    /// round.
    function recycleCriteria(uint256 groupSeed, uint256 roundSeed) external bumpBlock {
        _recycle({groupId: _criteriaGroup(groupSeed), roundSeed: roundSeed});
    }

    /// @notice Warp forward by a bounded jump so rounds and epochs advance.
    /// @dev Bounded by the distributor's actual `ROUND_DURATION` rather than a literal, so a single jump can never
    /// exceed one round regardless of how the suite is configured.
    function warp(uint256 jumpSeed) external bumpBlock {
        uint256 jump = bound(jumpSeed, 1, distributor.ROUND_DURATION());
        vm.warp(vm.getBlockTimestamp() + jump);
    }

    //*********************************************************************//
    // ------------------------------- views -------------------------------- //
    //*********************************************************************//

    /// @notice The sum of every touched epoch's still-held bucket for the primary project — every bucket that could
    /// ever be non-zero was created by a stake or transfer-receive within `[minTouchedEpoch, maxTouchedEpoch]`.
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

    /// @notice The number of distinct (hook, groupId, round) criteria rounds ever funded.
    function touchedCriteriaRoundsLength() external view returns (uint256) {
        return _touchedCriteriaRounds.length;
    }

    /// @notice One touched (hook, groupId, round) criteria round, by index.
    function touchedCriteriaRoundAt(uint256 index)
        external
        view
        returns (address hookAddr, uint256 groupId, uint256 round)
    {
        TouchedCriteriaRound storage touched = _touchedCriteriaRounds[index];
        return (touched.hook, touched.groupId, touched.round);
    }

    //*********************************************************************//
    // ----------------------------- internal -------------------------------- //
    //*********************************************************************//

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Picks one of the encoded `minWeeks * CRITERIA_BASE + maxWeeks` criteria-window groups exercised by
    /// this suite: two tenure windows (bounded min, unbounded max), two recency windows (min = 1, bounded max), and
    /// two cohort windows (min > 1, bounded max) — covering every window shape the generalized encoding defines.
    function _criteriaGroup(uint256 seed) internal pure returns (uint256) {
        uint256[6] memory groups =
            [uint256(2000), uint256(4000), uint256(1002), uint256(1004), uint256(2004), uint256(4008)];
        return groups[seed % 6];
    }

    /// @notice Picks a criteria group for a materialize/collect action. On roughly half of calls, reuses whatever
    /// group was last actually funded for this hook (if any), so materialize/release calls have a realistic chance
    /// of landing on a round with real inventory instead of drawing an unrelated group every time; on the other
    /// half, draws independently across the full shape mix via `_criteriaGroup` so unfunded groups are still
    /// exercised (must be a safe no-op). The reuse decision reads `seed / 6`, not `seed % 6` — the array has an
    /// even length, so `seed % 2` would be fully determined by `seed % 6` and always pick the same three groups for
    /// reuse and the other three for independent draws instead of splitting each group's own calls between them.
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

    function _fund(address hookAddr, uint256 groupId, uint256 amountSeed) internal {
        uint256 amount = bound(amountSeed, 0, MAX_FUND_AMOUNT);
        if (amount == 0) return;

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
            _recordTouchedCriteriaRound({hookAddr: hookAddr, groupId: groupId, round: distributor.currentRound()});
        }
    }

    /// @notice Records a (hook, groupId, round) triple the first time it's ever funded, so
    /// `invariant_criteriaWindowSolvency` knows which recorded rounds to independently re-check.
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
        uint256 firstRound = distributor.nextClaimRoundOf(hookAddr, groupId, tokenId, IERC20(address(reward)));

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

        uint256 round = distributor.currentRound();
        if (round == 0 || firstRound >= round) return;
        for (uint256 r = firstRound; r < round; r++) {
            _updateWorstRound({hookAddr: hookAddr, groupId: groupId, round: r});
        }
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
            distributor.recycleExpiredRewards({
                hook: address(stickyToken), groupId: groupId, token: IERC20(address(reward)), rounds: rounds
            });
            // Recycling can freeze a fresh snapshot for the destination round exactly like `_fund` does, so it must
            // also be tracked for the independent window-solvency recomputation.
            _recordTouchedCriteriaRound({
                hookAddr: address(stickyToken), groupId: groupId, round: distributor.currentRound()
            });
        }

        _updateWorstRound({hookAddr: address(stickyToken), groupId: groupId, round: round});
        _updateWorstRound({hookAddr: address(stickyToken), groupId: groupId, round: distributor.currentRound()});
    }

    /// @notice Refreshes `worstRound` if the given (hook, group, round) triple's claimedAmount/amount ratio is the
    /// highest observed so far. This suite bounds every stake and fund amount well under `type(uint208).max`, so the
    /// cross-multiplied comparison never overflows.
    function _updateWorstRound(address hookAddr, uint256 groupId, uint256 round) internal {
        (
            uint208 amount,
            uint48 snapshotBlock,
            uint208 claimedAmount,
            uint48 claimDeadline,
            uint208 totalStake,
            uint48 snapshotEpoch
        ) = distributor.rewardRoundOf(hookAddr, groupId, IERC20(address(reward)), round);

        // Rounds that never received funding have no ratio to compare.
        if (amount == 0) return;

        bool isWorse = worstRound.amount == 0
            || uint256(claimedAmount) * uint256(worstRound.amount) > uint256(worstRound.claimedAmount) * uint256(amount);
        if (!isWorse) return;

        worstRound = JBStickyRewardRoundData({
            amount: amount,
            snapshotBlock: snapshotBlock,
            claimedAmount: claimedAmount,
            claimDeadline: claimDeadline,
            totalStake: totalStake,
            snapshotEpoch: snapshotEpoch
        });
    }
}

/// @notice Invariant suite: the distributor can never over-promise its reward-token inventory, one hook's custody
/// can never leak into another's, and the primary project's per-epoch buckets always sum to exactly what's staked.
/// @dev Drives two sticky projects sharing one reward token through a bounded actor set: a transferable primary
/// project (stake, unstake, transfer, fund, claim, recycle) and a soulbound second project (stake, fund, claim
/// only) that exists solely to make cross-hook custody isolation falsifiable — the distributor pools every hook's
/// reward-token balance in one real ERC-20 account (`_accountedBalanceOf`) but must keep each hook's share
/// separately in `_balanceOf`, and that separation is exactly what `invariant_hookCustodyIsolation` checks.
contract JBStickyDistributorInvariantTest is TestBaseWorkflow {
    uint256 constant ROUND_DURATION = 3 weeks;
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

        // A second, soulbound sticky project sharing the same staked and reward tokens — the distributor's second
        // hook, so custody isolation between hooks is actually exercised instead of assumed.
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

    /// @notice The reward token can never be over-promised: the distributor's actual balance always covers every
    /// dollar that was funded but not yet collected, and no touched round's claimed amount ever exceeds its funded
    /// amount.
    function invariant_potSolvency() public view {
        assertGe(reward.balanceOf(address(distributor)), handler.ghost_fundedTotal() - handler.ghost_collectedTotal());

        (uint208 amount,, uint208 claimedAmount,,,) = handler.worstRound();
        assertGe(amount, claimedAmount);
    }

    /// @notice One hook's reward-token custody can never leak into another's, even though both hooks' funds sit in
    /// the same real ERC-20 balance. Every assertion here is an equality, not a bound: `_balanceOf` only ever moves
    /// by exact funded/collected deltas (see `_recordRewardFunding` and `_unlockRewards`), so nothing should ever
    /// make it drift from the ghost accounting.
    function invariant_hookCustodyIsolation() public view {
        uint256 hook1Balance = distributor.balanceOf(address(stickyToken), reward);
        uint256 hook2Balance = distributor.balanceOf(address(stickyToken2), reward);

        // (i) The internal per-hook ledger sums to exactly the aggregate ghost accounting.
        assertEq(hook1Balance + hook2Balance, handler.ghost_fundedTotal() - handler.ghost_collectedTotal());

        // (ii) Each hook's own custody matches only its own ghost accounting — a cross-hook drain (or an unchecked
        // underflow silently wrapping one hook's balance) would break this without necessarily breaking (i).
        assertEq(
            hook1Balance, handler.ghost_fundedOf(address(stickyToken)) - handler.ghost_collectedOf(address(stickyToken))
        );
        assertEq(
            hook2Balance,
            handler.ghost_fundedOf(address(stickyToken2)) - handler.ghost_collectedOf(address(stickyToken2))
        );
    }

    /// @notice The primary project's hook buckets always sum to exactly the actor set's staked balances.
    function invariant_bucketConservation() public view {
        assertEq(handler.sumBuckets(), handler.sumStakedBalances());
    }

    /// @notice For every criteria round ever funded, independently recomputes the window-stake denominator from
    /// live tranches and asserts it never exceeds the round's recorded `totalStake`. `potSolvency`'s
    /// `assertGe(amount, claimedAmount)` is tautological — `_claimRewardRoundFor` already clamps every claim to
    /// `amount - claimedAmount`, so that assertion can only fail if the clamp itself is deleted. It cannot detect
    /// the actual risk of this generalization: a claim-time window that diverges from the fund-time window (e.g. a
    /// wider filter reading past the frozen `[lo, hi]`) would still conserve custody and still respect the clamp —
    /// it would only ever surface as late claimers silently receiving nothing, or worse, receiving more than the
    /// round can pay. This invariant recomputes the bounds independently in the harness — deriving `lo`/`hi` from
    /// the round's stored `snapshotEpoch` and `groupId` exactly as `_criteriaWindowFor` specifies, rather than
    /// calling into the distributor's internal helper — and sums every bounded actor's live `HOOK.tranchesOf`
    /// weight against those bounds, so a real divergence between the two window computations would show up here as
    /// a live-recomputed sum exceeding the denominator the contract actually recorded.
    /// @dev `<=`, not `==`: live tranches can only have shrunk since the round's snapshot (partial or full
    /// unstakes reduce a holder's own tranches), never grown into an already-frozen window — `minWeeks >= 1` keeps
    /// the current, still-open epoch out of every valid window, so nothing staked after the snapshot can land
    /// inside it. A live recomputation is therefore a lower bound on what was true at snapshot time, not an exact
    /// match.
    function invariant_criteriaWindowSolvency() public view {
        uint256 roundsLength = handler.touchedCriteriaRoundsLength();
        for (uint256 i; i < roundsLength; i++) {
            (address hookAddr, uint256 groupId, uint256 round) = handler.touchedCriteriaRoundAt(i);
            _assertCriteriaRoundWindowSolvency({hookAddr: hookAddr, groupId: groupId, round: round});
        }
    }

    /// @notice Independently recomputes one touched criteria round's live window-stake sum and asserts it against
    /// the round's recorded denominator. Split out of `invariant_criteriaWindowSolvency` — inlining this body into
    /// the loop above overflows the Yul stack under `via_ir`.
    function _assertCriteriaRoundWindowSolvency(address hookAddr, uint256 groupId, uint256 round) internal view {
        (,,,, uint208 totalStake, uint48 snapshotEpoch) = distributor.rewardRoundOf(hookAddr, groupId, reward, round);

        uint256 base = distributor.CRITERIA_BASE();
        uint256 minWeeks = groupId / base;
        uint256 maxWeeks = groupId % base;

        // Mirrors `_criteriaWindowFor`: the window's top bound would sit at or above the snapshot epoch itself, so
        // no epoch can qualify.
        if (uint256(snapshotEpoch) < minWeeks) return;

        uint256 hi = uint256(snapshotEpoch) - minWeeks;
        uint256 lo = maxWeeks == 0 ? 0 : (uint256(snapshotEpoch) < maxWeeks ? 0 : uint256(snapshotEpoch) - maxWeeks);
        if (lo > hi) return;

        uint256 targetProjectId = hookAddr == address(stickyToken) ? projectId : projectId2;
        uint256 liveWindowSum = _liveWindowSum({projectId_: targetProjectId, lo: lo, hi: hi});

        assertLe(liveWindowSum, uint256(totalStake));
    }

    /// @notice Every bounded actor's live tranche weight inside `[lo, hi]` for one project, read straight from
    /// `HOOK.tranchesOf` rather than any distributor helper.
    function _liveWindowSum(uint256 projectId_, uint256 lo, uint256 hi) internal view returns (uint256 sum) {
        uint256 epochDuration = handler.EPOCH_DURATION();
        uint256 actorsLength = handler.actorsLength();

        for (uint256 a; a < actorsLength; a++) {
            JBStickyTranche[] memory tranches = hook.tranchesOf(projectId_, handler.actors(a));
            for (uint256 t; t < tranches.length; t++) {
                uint256 epoch = uint256(tranches[t].timestamp) / epochDuration;
                if (epoch < lo || epoch > hi) continue;
                sum += tranches[t].amount;
            }
        }
    }

    /// @notice Non-vacuousness tripwire: deterministically drives the handler through fund → warp → collect for
    /// both hooks and asserts the ghost totals actually moved, so a future bound or gating regression that makes
    /// those actions permanently no-ops can't let the invariants above pass vacuously. Also proves each of the
    /// three criteria-window shapes — tenure, recency, and cohort — individually funds and pays out, not just the
    /// default group: a single actor's stake sits in one epoch, and a 4-week pre-fund warp is the unique offset
    /// that lands that epoch inside a tenure(2+), a recency(1-4), and a cohort(4-8) window simultaneously (tenure's
    /// floor is unbounded, recency's ceiling is the stake epoch + 4, and cohort's floor is the stake epoch + 4).
    /// @dev Deliberately not `afterInvariant()`: that hook runs once per *independent* fuzz run (not once for the
    /// whole campaign — Foundry calls `setUp()` before every run), and Foundry's fuzzer deliberately biases toward
    /// boundary values like `0`. A single unlucky run out of 1024 can legitimately draw only zero-amount fund calls
    /// within its own depth budget, which made an `afterInvariant`-based version of this check fail on ~1 in 1024
    /// runs even though every invariant it guards was passing — confirmed by removing it and re-running clean.
    /// A plain deterministic test exercises the same code paths without that per-run randomness.
    function test_handlerReachesNonzeroFundingAndCollection() public {
        address actor = handler.actors(0);

        handler.stake({actorSeed: 0, amountSeed: 100e18});
        handler.stake2({actorSeed: 0, amountSeed: 100e18});
        handler.fundDefaultGroup({amountSeed: 100e18});
        handler.fundDefaultGroup2({amountSeed: 100e18});

        // Age the stake's epoch 4 weeks before pinning any criteria round's snapshot — see the shape-overlap note
        // above. Two 2-week jumps rather than one 4-week jump because `warp` bounds a single jump to
        // `distributor.ROUND_DURATION()` (3 weeks here); asserted below rather than assumed, so a future
        // `ROUND_DURATION` change under 2 weeks fails loudly here instead of silently breaking the window overlap
        // this test's fund/collect sequence below depends on.
        uint256 timestampBeforeAging = vm.getBlockTimestamp();
        handler.warp({jumpSeed: 2 weeks});
        handler.warp({jumpSeed: 2 weeks});
        assertEq(vm.getBlockTimestamp() - timestampBeforeAging, 4 weeks, "pre-fund aging warp must total 4 weeks");

        // `_criteriaGroup`'s array is `[2000, 4000, 1002, 1004, 2004, 4008]`; these seeds select one representative
        // of each shape (indices 0, 3, 5) so each is individually proven below. Funding always draws independently
        // (`fundCriteriaGroup` never routes through `_criteriaGroupForClaim`), so these three seeds are unambiguous.
        handler.fundCriteriaGroup({groupSeed: 0, amountSeed: 100e18}); // tenure: 2+ weeks
        handler.fundCriteriaGroup({groupSeed: 3, amountSeed: 100e18}); // recency: last 4 completed weeks
        handler.fundCriteriaGroup({groupSeed: 5, amountSeed: 100e18}); // cohort: 4-8 weeks

        // Collecting routes through `_criteriaGroupForClaim`, which reuses `ghost_lastFundedCriteriaGroup` (the
        // most recently funded group — cohort, by the time any of these run) whenever `(seed / 6) % 2 == 0`. Seeds
        // 6, 9, and 11 land on the same three array indices (0, 3, 5) as above while forcing `(seed / 6) % 2 == 1`,
        // so each collect call independently exercises the specific shape it claims to, not whatever was funded
        // last.
        uint256 tenureSeed = 6;
        uint256 recencySeed = 9;
        uint256 cohortSeed = 11;

        // One round in (well inside the 6-week claim deadline): materialize each hook's funded round into a
        // vesting entry. Still fully locked, so this transfers nothing yet.
        handler.warp({jumpSeed: ROUND_DURATION});
        handler.collectDefault({actorSeed: 0});
        handler.collectDefault2({actorSeed: 0});
        handler.collectCriteria({actorSeed: 0, groupSeed: tenureSeed});
        handler.collectCriteria({actorSeed: 0, groupSeed: recencySeed});
        handler.collectCriteria({actorSeed: 0, groupSeed: cohortSeed});

        // Halfway through the 2-round vesting schedule: collect again to actually receive the unlocked half.
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
