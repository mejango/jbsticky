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

/// @notice An 18-decimal ERC-20 standing in for the staked and reward tokens driven by the invariant handler.
contract InvariantErc20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice Drives a bounded actor set through every distributor and hook entrypoint against one transferable sticky
/// project, tracking the ghost accounting `JBStickyDistributorInvariantTest` checks its invariants against.
/// @dev Every action bumps the block number first, so group-0 votes snapshots (which require a strictly past block)
/// never revert regardless of call order.
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
    uint256 public immutable EPOCH_DURATION;

    address[] public actors;

    /// @notice The total amount of the reward token ever actually accepted into distributor custody.
    uint256 public ghost_fundedTotal;

    /// @notice The total amount of the reward token ever actually transferred out to a collecting actor.
    uint256 public ghost_collectedTotal;

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
        address[] memory actors_
    ) {
        HOOK = hook_;
        distributor = distributor_;
        terminal = terminal_;
        staked = staked_;
        reward = reward_;
        stickyToken = stickyToken_;
        projectId = projectId_;
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

    /// @notice Stake a bounded amount of the underlying for a bounded actor.
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

    /// @notice Unstake a bounded amount (partial or full) for a bounded actor.
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

    /// @notice Fund the default (votes-weighted) group's current round with a bounded amount.
    function fundDefaultGroup(uint256 amountSeed) external bumpBlock {
        _fund({groupId: 0, amountSeed: amountSeed});
    }

    /// @notice Fund a bounded stick-time criteria group's current round with a bounded amount.
    function fundCriteriaGroup(uint256 groupSeed, uint256 amountSeed) external bumpBlock {
        _fund({groupId: _criteriaGroup(groupSeed), amountSeed: amountSeed});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in the default group.
    function beginVestingDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({actor: _actor(actorSeed), groupId: 0, collect: false});
    }

    /// @notice Begin vesting a bounded actor's unclaimed rounds in a bounded criteria group.
    function beginVestingCriteria(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({actor: _actor(actorSeed), groupId: _criteriaGroup(groupSeed), collect: false});
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in the default group.
    function collectDefault(uint256 actorSeed) external bumpBlock {
        _claimAndSweep({actor: _actor(actorSeed), groupId: 0, collect: true});
    }

    /// @notice Begin vesting and collect a bounded actor's unlocked rewards in a bounded criteria group.
    function collectCriteria(uint256 actorSeed, uint256 groupSeed) external bumpBlock {
        _claimAndSweep({actor: _actor(actorSeed), groupId: _criteriaGroup(groupSeed), collect: true});
    }

    /// @notice Recycle a bounded expired round in the default group into the current round.
    function recycleDefault(uint256 roundSeed) external bumpBlock {
        _recycle({groupId: 0, roundSeed: roundSeed});
    }

    /// @notice Recycle a bounded expired round in a bounded criteria group into the current round.
    function recycleCriteria(uint256 groupSeed, uint256 roundSeed) external bumpBlock {
        _recycle({groupId: _criteriaGroup(groupSeed), roundSeed: roundSeed});
    }

    /// @notice Warp forward by a bounded jump so rounds and epochs advance.
    function warp(uint256 jumpSeed) external bumpBlock {
        uint256 jump = bound(jumpSeed, 1, 3 weeks);
        vm.warp(vm.getBlockTimestamp() + jump);
    }

    //*********************************************************************//
    // ------------------------------- views -------------------------------- //
    //*********************************************************************//

    /// @notice The sum of every touched epoch's still-held bucket for the project — every bucket that could ever be
    /// non-zero was created by a stake or transfer-receive within `[minTouchedEpoch, maxTouchedEpoch]`.
    function sumBuckets() external view returns (uint256 total) {
        if (maxTouchedEpoch < minTouchedEpoch) return 0;
        for (uint256 epoch = minTouchedEpoch; epoch <= maxTouchedEpoch; epoch++) {
            total += HOOK.netStakedIn({projectId: projectId, epoch: epoch});
        }
    }

    /// @notice The sum of every bounded actor's staked balance.
    function sumStakedBalances() external view returns (uint256 total) {
        uint256 length = actors.length;
        for (uint256 i; i < length; i++) {
            total += HOOK.stakedBalanceOf({projectId: projectId, holder: actors[i]});
        }
    }

    //*********************************************************************//
    // ----------------------------- internal -------------------------------- //
    //*********************************************************************//

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Picks one of the bounded stick-time criteria groups exercised by this suite.
    function _criteriaGroup(uint256 seed) internal pure returns (uint256) {
        uint256[3] memory groups = [uint256(1), uint256(2), uint256(4)];
        return groups[seed % 3];
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

    function _fund(uint256 groupId, uint256 amountSeed) internal {
        uint256 amount = bound(amountSeed, 0, MAX_FUND_AMOUNT);
        if (amount == 0) return;

        reward.mint({to: address(this), amount: amount});
        reward.approve({spender: address(distributor), value: amount});
        uint256 balanceBefore = reward.balanceOf(address(distributor));

        if (groupId == 0) {
            distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount});
        } else {
            distributor.fund({
                hook: address(stickyToken), token: IERC20(address(reward)), amount: amount, groupId: groupId
            });
        }

        ghost_fundedTotal += reward.balanceOf(address(distributor)) - balanceBefore;
    }

    /// @notice Begins vesting (and optionally collects) `actor`'s unclaimed rounds, then sweeps exactly the round
    /// range the distributor just walked internally to refresh `worstRound`.
    function _claimAndSweep(address actor, uint256 groupId, bool collect) internal {
        uint256 tokenId = uint256(uint160(actor));
        uint256 firstRound = groupId == 0
            ? distributor.nextClaimRoundOf(address(stickyToken), 0, tokenId, IERC20(address(reward)))
            : distributor.nextClaimRoundOf(address(stickyToken), groupId, tokenId, IERC20(address(reward)));

        if (collect) {
            uint256 balanceBefore = reward.balanceOf(actor);
            if (groupId == 0) {
                distributor.collectVestedRewards({
                    hook: address(stickyToken), tokenIds: _tokenIds(actor), tokens: _tokens(), beneficiary: actor
                });
            } else {
                distributor.collectVestedRewards({
                    hook: address(stickyToken),
                    groupId: groupId,
                    tokenIds: _tokenIds(actor),
                    tokens: _tokens(),
                    beneficiary: actor
                });
            }
            ghost_collectedTotal += reward.balanceOf(actor) - balanceBefore;
        } else if (groupId == 0) {
            distributor.beginVesting({hook: address(stickyToken), tokenIds: _tokenIds(actor), tokens: _tokens()});
        } else {
            distributor.beginVesting({
                hook: address(stickyToken), groupId: groupId, tokenIds: _tokenIds(actor), tokens: _tokens()
            });
        }

        uint256 round = distributor.currentRound();
        if (round == 0 || firstRound >= round) return;
        for (uint256 r = firstRound; r < round; r++) {
            _updateWorstRound({groupId: groupId, round: r});
        }
    }

    function _recycle(uint256 groupId, uint256 roundSeed) internal {
        uint256 currentR = distributor.currentRound();
        uint256 round = bound(roundSeed, 0, currentR);
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = round;

        if (groupId == 0) {
            distributor.recycleExpiredRewards({hook: address(stickyToken), token: IERC20(address(reward)), rounds: rounds});
        } else {
            distributor.recycleExpiredRewards({
                hook: address(stickyToken), groupId: groupId, token: IERC20(address(reward)), rounds: rounds
            });
        }

        _updateWorstRound({groupId: groupId, round: round});
        _updateWorstRound({groupId: groupId, round: distributor.currentRound()});
    }

    /// @notice Refreshes `worstRound` if the given (group, round) pair's claimedAmount/amount ratio is the highest
    /// observed so far. This suite bounds every stake and fund amount well under `type(uint208).max`, so the
    /// cross-multiplied comparison never overflows.
    function _updateWorstRound(uint256 groupId, uint256 round) internal {
        (
            uint208 amount,
            uint48 snapshotBlock,
            uint208 claimedAmount,
            uint48 claimDeadline,
            uint208 totalStake,
            uint48 snapshotEpoch
        ) = distributor.rewardRoundOf(address(stickyToken), groupId, IERC20(address(reward)), round);

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

/// @notice Invariant suite: the distributor can never over-promise its reward-token inventory, and the hook's
/// per-epoch buckets always sum to exactly what's staked.
/// @dev Drives one transferable sticky project through a bounded actor set. A fourth invariant — the distributor's
/// per-hook `balanceOf` bounding per-hook unvested inventory — is redundant with `invariant_potSolvency` here,
/// because this suite drives a single sticky project: the per-hook balance and the token's total distributor
/// balance are the same number. It's skipped rather than asserted twice.
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

    JBStickyDistributorHandler handler;

    function setUp() public override {
        super.setUp();

        staked = new InvariantErc20("Staked", "STK");
        reward = new InvariantErc20("Reward", "RWD");

        deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        hook = deployer.HOOK();

        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
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

    /// @notice The hook's per-epoch buckets always sum to exactly the actor set's staked balances.
    function invariant_bucketConservation() public view {
        assertEq(handler.sumBuckets(), handler.sumStakedBalances());
    }
}
