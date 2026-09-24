// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBDistributor} from "@bananapus/distributor-v6/src/JBDistributor.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {IJBTokenDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBTokenDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {JBStickyToken} from "../src/JBStickyToken.sol";
import {IJBStickyDistributor} from "../src/interfaces/IJBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice An 18-decimal ERC-20 standing in for a token that gets staked or handed out as a reward.
// forge-lint: disable-next-line(multi-contract-file)
contract MockErc20 is ERC20 {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The fee, in basis points, taken out of every transfer when non-zero.
    uint256 public feeBps;

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

    /// @notice Sets the fee taken out of every transfer.
    /// @param bps The fee in basis points.
    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Moves tokens, burning the configured fee out of every transfer between two accounts.
    /// @param from The account the tokens move from.
    /// @param to The account the tokens move to.
    /// @param value The number of tokens moved before the fee.
    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        if (fee != 0 && from != address(0) && to != address(0)) {
            super._update({from: from, to: address(0xdead), value: fee});
            value -= fee;
        }
        super._update({from: from, to: to, value: value});
    }
}

/// @notice Unit coverage for the Sticky distributor: default-group parity with the stock token distributor, tenure
/// windows pinned at round start, split routing, and funding validation.
/// @dev Rounds last one day and the distributor starts on a week boundary, so a round that starts `n` weeks after
/// `_start` has snapshot epoch `_startEpoch + n`.
// forge-lint: disable-next-line(multi-contract-file)
contract JBStickyDistributorUnitTest is TestBaseWorkflow {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice How long a funded round stays claimable.
    uint48 constant _CLAIM_DURATION = 30 days;

    /// @notice How long each distributor round lasts.
    uint256 constant _ROUND_DURATION = 1 days;

    /// @notice The number of rounds a claimed reward vests over.
    uint256 constant _VESTING_ROUNDS = 2;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice A staking account.
    // forge-lint: disable-next-line(function-init-state)
    address _alice = makeAddr("alice");

    /// @notice A staking account.
    // forge-lint: disable-next-line(function-init-state)
    address _bob = makeAddr("bob");

    /// @notice A staking account.
    // forge-lint: disable-next-line(function-init-state)
    address _carol = makeAddr("carol");

    /// @notice The deployer that launches the Sticky projects.
    JBStickyDeployer _deployer;

    /// @notice The distributor under test.
    JBStickyDistributor _distributor;

    /// @notice The account that funds rewards.
    // forge-lint: disable-next-line(function-init-state)
    address _funder = makeAddr("funder");

    /// @notice The hook accounting for every Sticky project's tranches.
    IJBStickyHook _hook;

    /// @notice The soulbound Sticky project's ID.
    uint256 _projectId;

    /// @notice The token handed out as a reward.
    MockErc20 _reward;

    /// @notice The token staked into the Sticky projects.
    MockErc20 _staked;

    /// @notice The timestamp the distributor starts at, on a week boundary.
    uint256 _start;

    /// @notice The epoch containing `_start`.
    uint256 _startEpoch;

    /// @notice The soulbound Sticky project's share token.
    IJBToken _stickyToken;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();

        _staked = new MockErc20("Staked", "STK");
        _reward = new MockErc20("Reward", "RWD");

        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = _deployer.HOOK();

        // Deploy a sticky project for the staked token, forwarding the project creation fee.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        // forge-lint: disable-next-item(arbitrary-send-eth)
        _projectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_staked)),
            name: "Sticky",
            symbol: "STICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        _stickyToken = jbTokens().tokenOf(_projectId);

        // Start the distributor on a week boundary so day-long rounds line up with epochs.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _start = (vm.getBlockTimestamp() / 1 weeks + 1) * 1 weeks;
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _startEpoch = _start / 1 weeks;
        vm.warp(_start);
        vm.roll(vm.getBlockNumber() + 1);

        _distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: _CLAIM_DURATION
        });
    }

    function test_claimSplitsProRataAcrossAgedTranches() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 300e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(13);
        _stake(_bob, 600e18); // fresh bob tranche won't count for min = 2 at epoch +14
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 2000); // denominator = 400e18

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 2000);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 2000), 25e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_bob, 2000), 75e18);
    }

    function test_cohortDenominatorOnlyMiddleBucketsCount() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18); // epoch +10, below the (4, 8) window at snapshot +20
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 200e18); // epoch +14, inside [+12, +16]
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_carol, 300e18); // epoch +18, above the window
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(20);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(10e18, 4008);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 4008);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 200e18);
    }

    function test_cohortNumeratorClaimsOnlyDepositCohortSlice() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(20);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 4008); // denominator = alice's epoch +14 100e18 + bob's epoch +14 100e18

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 4008);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 4008);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 4008), 50e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_bob, 4008), 50e18);
    }

    function test_constructorRejectsMismatchedEpochDuration() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(address(_hook), abi.encodeCall(IJBStickyHook.EPOCH_DURATION, ()), abi.encode(uint256(1 days)));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_EpochDurationMismatch.selector,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256(1 weeks),
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256(1 days)
            )
        );
        new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: _CLAIM_DURATION
        });
    }

    /// @notice A zero claim duration never expires, so a tenure pot forfeited by exits could never recycle.
    function test_constructorRejectsZeroClaimDuration() public {
        vm.expectRevert(JBStickyDistributor.JBStickyDistributor_ZeroClaimDuration.selector);
        new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: 0
        });
    }

    function test_denominatorSumsOnlyAgedStake() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(13);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 300e18); // too fresh for min = 2 at epoch +14
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(10e18, 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
    }

    function test_denominatorZeroWhenNothingAged() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(10e18, 52_000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 52_000);
        assertEq(totalStake, 0);
    }

    /// @notice A Sticky token funded as a reward leaves the distributor holding aged shares. Collecting its own
    /// allocation, which a helper can only send to the distributor, recycles it into the current round instead of
    /// erasing it from the ledger, and other holders' claims are untouched.
    function test_distributorHeldSharesRecycleInsteadOfSelfCollecting() public {
        (uint256 openProjectId, IJBToken openToken) = _launchOpenProject();
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stakeIn({holder: _alice, amount: 100e18, targetProjectId: openProjectId});

        // Alice hands 40% of the open project's shares to the first project's holders as a reward. That funding
        // pins this round's shared snapshot, so the open project's own round is funded in the next one.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundShares({openToken: openToken, amount: 40e18});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_hook.stakedBalanceOf(openProjectId, address(_distributor)), 40e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        vm.roll(vm.getBlockNumber() + 1);

        // The open project's holders are rewarded: alice weighs 60% and the distributor 40%.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundHook({rewardedHook: address(openToken), amount: 100e18, groupId: 0});
        uint256 distributorId = uint256(uint160(address(_distributor)));

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _distributor.beginVesting({
            hook: address(openToken), tokenIds: _tokenIds(address(_distributor)), tokens: _rewardTokens()
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.claimedFor(address(openToken), 0, distributorId, _reward), 40e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);

        _distributor.collectVestedRewards({
            hook: address(openToken),
            tokenIds: _tokenIds(address(_distributor)),
            tokens: _rewardTokens(),
            beneficiary: address(_distributor)
        });

        // The allocation is the current round's pot; custody and the accounted balance are unchanged.
        (
            uint208 recycledPot,,,,
            // forge-lint: disable-next-line(unused-return)
        ) = _distributor.rewardRoundOf(address(openToken), 0, IERC20(address(_reward)), _distributor.currentRound());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(recycledPot, 40e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.balanceOf(address(openToken), IERC20(address(_reward))), 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_reward.balanceOf(address(_distributor)), 100e18);
        assertEq(_distributor.claimedFor(address(openToken), 0, distributorId, _reward), 0);
        assertEq(_distributor.totalVestingAmountOf(address(openToken), IERC20(address(_reward))), 0);

        // Alice's share of the funded round is intact, and she shares the recycled round once it completes.
        _distributor.beginVesting({hook: address(openToken), tokenIds: _tokenIds(_alice), tokens: _rewardTokens()});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.claimedFor(address(openToken), 0, uint256(uint160(_alice)), _reward), 60e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        _distributor.collectVestedRewards({
            hook: address(openToken), tokenIds: _tokenIds(_alice), tokens: _rewardTokens(), beneficiary: _alice
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_reward.balanceOf(_alice), 60e18);
        _distributor.beginVesting({hook: address(openToken), tokenIds: _tokenIds(_alice), tokens: _rewardTokens()});
        assertEq(_distributor.claimedFor(address(openToken), 0, uint256(uint160(_alice)), _reward), 24e18);
    }

    /// @notice The same recycling applies to a tenure group's pot, through the group-carrying collection.
    function test_distributorHeldSharesRecycleInTenureGroups() public {
        (uint256 openProjectId, IJBToken openToken) = _launchOpenProject();
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stakeIn({holder: _alice, amount: 100e18, targetProjectId: openProjectId});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundShares({openToken: openToken, amount: 40e18});

        // Both tranches are two weeks old when the round is funded, so the denominator counts them both.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundHook({rewardedHook: address(openToken), amount: 100e18, groupId: 1000});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 pot, uint208 totalStake) = _currentRewardRoundOfHook({rewardedHook: address(openToken), groupId: 1000});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(pot, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _distributor.beginVesting({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            hook: address(openToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 1000,
            tokenIds: _tokenIds(address(_distributor)),
            tokens: _rewardTokens()
        });
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        _distributor.collectVestedRewards({
            hook: address(openToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 1000,
            tokenIds: _tokenIds(address(_distributor)),
            tokens: _rewardTokens(),
            beneficiary: address(_distributor)
        });

        // forge-lint: disable-next-line(literal-instead-of-constant)
        (pot,) = _currentRewardRoundOfHook({rewardedHook: address(openToken), groupId: 1000});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(pot, 40e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.balanceOf(address(openToken), IERC20(address(_reward))), 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_reward.balanceOf(address(_distributor)), 100e18);
    }

    function test_expiredRoundsRecycleUnclaimedRewards() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 50e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 50e18);
        vm.roll(vm.getBlockNumber() + 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fund(100e18);
        uint256 fundedRound = _distributor.currentRound();

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _beginVestingFor(_alice);
        vm.warp(vm.getBlockTimestamp() + _CLAIM_DURATION);

        uint256[] memory rounds = new uint256[](1);
        rounds[0] = fundedRound;
        uint256 recycled = _distributor.recycleExpiredRewards({
            hook: address(_stickyToken), token: IERC20(address(_reward)), rounds: rounds
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(recycled, 50e18);

        assertEq(
            _distributor.recycleExpiredRewards({
                hook: address(_stickyToken), token: IERC20(address(_reward)), rounds: rounds
            }),
            0
        );
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(address(_reward))), 100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_alice), 50e18);
    }

    function test_fullExitBeforeClaimForfeitsTheRoundToRecycling() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 1000);
        uint256 fundedRound = _distributor.currentRound();

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _unstake(_bob, 100e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.claimedFor(address(_stickyToken), 1000, uint256(uint160(_bob)), _reward), 0);

        vm.warp(vm.getBlockTimestamp() + _CLAIM_DURATION);
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = fundedRound;
        assertEq(
            _distributor.recycleExpiredRewards({
                // forge-lint: disable-next-line(literal-instead-of-constant)
                hook: address(_stickyToken),
                // forge-lint: disable-next-line(literal-instead-of-constant)
                groupId: 1000,
                token: _reward,
                rounds: rounds
            }),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            100e18
        );
    }

    function test_fundAcceptsValidGroups() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[4] memory validGroups = [uint256(0), 4000, 1004, 4008];
        vm.roll(vm.getBlockNumber() + 1);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint(_funder, 4e18);
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve(address(_distributor), 4e18);
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < validGroups.length; i++) {
            // forge-lint: disable-next-line(calls-loop,literal-instead-of-constant)
            _distributor.fund(address(_stickyToken), _reward, 1e18, validGroups[i]);
        }
        vm.stopPrank();

        // The widest window is accepted; its bottom simply clamps at epoch 0 and nothing is that old yet.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(1e18, 520_520);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 520_520);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 1e18);
        assertEq(totalStake, 0);
    }

    function test_fundRejectsInvalidGroups() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[6] memory invalidGroups = [uint256(4), 520, 8004, 4999, 521_000, uint256(1) << 240];

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint(_funder, 10e18);
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve(address(_distributor), 10e18);
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < invalidGroups.length; i++) {
            // forge-lint: disable-next-item(calls-loop)
            vm.expectRevert(
                abi.encodeWithSelector(
                    JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, invalidGroups[i]
                )
            );
            // forge-lint: disable-next-line(calls-loop,literal-instead-of-constant)
            _distributor.fund(address(_stickyToken), _reward, 1e18, invalidGroups[i]);
        }
        vm.stopPrank();

        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, 4));
        _distributor.beginVesting({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            hook: address(_stickyToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 4,
            tokenIds: _tokenIds(_alice),
            tokens: _rewardTokens()
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, 4));
        _distributor.collectVestedRewards({
            hook: address(_stickyToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 4,
            tokenIds: _tokenIds(_alice),
            tokens: _rewardTokens(),
            beneficiary: _alice
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, 4));
        // forge-lint: disable-next-item(unused-return)
        _distributor.recycleExpiredRewards({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            hook: address(_stickyToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 4,
            token: _reward,
            rounds: new uint256[](0)
        });
    }

    function test_fundTenureGroupRejectsUnregisteredToken() public {
        JBStickyToken impostor = new JBStickyToken({
            name: "Impostor",
            symbol: "IMP",
            tokens: IJBTokens(address(this)),
            projectId: _projectId,
            hook: _hook,
            soulbound: true
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint(_funder, 1e18);
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve(address(_distributor), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_UnregisteredStickyToken.selector, address(impostor)
            )
        );
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.fund(address(impostor), _reward, 1e18, 2000);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_UnregisteredStickyToken.selector, _alice)
        );
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.fund(_alice, _reward, 1e18, 2000);
        vm.stopPrank();
    }

    function test_fundWithTenureGroupAcceptsNativeToken() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.deal(_funder, 10e18);
        vm.prank(_funder);
        // forge-lint: disable-next-line(arbitrary-send-eth,literal-instead-of-constant)
        _distributor.fund{value: 10e18}(address(_stickyToken), IERC20(JBConstants.NATIVE_TOKEN), 0, 2000);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(JBConstants.NATIVE_TOKEN, 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
    }

    function test_fundWithTenureGroupCreatesPot() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: _funder, amount: 10e18});
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 10e18});
        vm.expectEmit(address(_distributor));
        // forge-lint: disable-next-item(reentrancy-events)
        emit IJBStickyDistributor.Fund({
            hook: address(_stickyToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 2000,
            token: IERC20(address(_reward)),
            round: _distributor.currentRound(),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 10e18,
            caller: _funder
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.fund({hook: address(_stickyToken), token: IERC20(address(_reward)), amount: 10e18, groupId: 2000});
        vm.stopPrank();

        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.snapshotEpochOf(_distributor.currentRound()), _startEpoch + 14);
    }

    function test_group0FundClaimCollect_parity() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 75e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 25e18);
        vm.roll(vm.getBlockNumber() + 1);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _beginVestingFor(_alice);
        _beginVestingFor(_bob);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_alice), 75e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_bob), 25e18);
    }

    function test_group0MatchesStockTokenDistributorStepForStep() public {
        JBTokenDistributor stock = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: _CLAIM_DURATION
        });
        assertEq(stock.STARTING_TIMESTAMP(), _distributor.STARTING_TIMESTAMP());

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 60e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 40e18);
        vm.roll(vm.getBlockNumber() + 1);

        // Fund both identically across several rounds, with a stake change in between.
        // forge-lint: disable-next-line(literal-instead-of-constant,uninitialized-local)
        for (uint256 round; round < 3; round++) {
            // forge-lint: disable-next-line(literal-instead-of-constant)
            uint256 amount = (round + 1) * 10e18 + 7;
            // forge-lint: disable-next-line(calls-loop)
            _reward.mint({to: _funder, amount: 2 * amount});
            // forge-lint: disable-next-line(calls-loop)
            vm.startPrank(_funder);
            // forge-lint: disable-next-line(calls-loop,unused-return)
            _reward.approve({spender: address(_distributor), value: amount});
            // forge-lint: disable-next-line(calls-loop)
            _distributor.fund({hook: address(_stickyToken), token: IERC20(address(_reward)), amount: amount});
            // forge-lint: disable-next-line(calls-loop,unused-return)
            _reward.approve({spender: address(stock), value: amount});
            // forge-lint: disable-next-line(calls-loop)
            stock.fund({hook: address(_stickyToken), token: IERC20(address(_reward)), amount: amount});
            // forge-lint: disable-next-line(calls-loop)
            vm.stopPrank();
            if (round == 1) _stake(_carol, 33e18);
            // forge-lint: disable-next-line(calls-loop)
            vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
            // forge-lint: disable-next-line(calls-loop)
            vm.roll(vm.getBlockNumber() + 1);
        }

        // forge-lint: disable-next-line(literal-instead-of-constant)
        address[3] memory holders = [_alice, _bob, _carol];
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 h; h < holders.length; h++) {
            uint256 tokenId = uint256(uint160(holders[h]));
            // forge-lint: disable-next-item(calls-loop)
            _distributor.beginVesting({
                hook: address(_stickyToken), tokenIds: _tokenIds(holders[h]), tokens: _rewardTokens()
            });
            // forge-lint: disable-next-line(calls-loop)
            stock.beginVesting({hook: address(_stickyToken), tokenIds: _tokenIds(holders[h]), tokens: _rewardTokens()});
            assertEq(
                // forge-lint: disable-next-line(calls-loop)
                _distributor.claimedFor(address(_stickyToken), tokenId, _reward),
                // forge-lint: disable-next-line(calls-loop)
                stock.claimedFor(address(_stickyToken), tokenId, _reward)
            );
        }

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 h; h < holders.length; h++) {
            uint256 tokenId = uint256(uint160(holders[h]));
            assertEq(
                // forge-lint: disable-next-line(calls-loop)
                _distributor.collectableFor(address(_stickyToken), tokenId, _reward),
                // forge-lint: disable-next-line(calls-loop)
                stock.collectableFor(address(_stickyToken), tokenId, _reward)
            );
            // forge-lint: disable-next-line(calls-loop)
            uint256 before = _reward.balanceOf(holders[h]);
            // forge-lint: disable-next-item(calls-loop)
            _distributor.collectVestedRewards({
                hook: address(_stickyToken),
                tokenIds: _tokenIds(holders[h]),
                tokens: _rewardTokens(),
                beneficiary: holders[h]
            });
            // forge-lint: disable-next-line(calls-loop)
            uint256 fromSticky = _reward.balanceOf(holders[h]) - before;
            // forge-lint: disable-next-item(calls-loop)
            stock.collectVestedRewards({
                hook: address(_stickyToken),
                tokenIds: _tokenIds(holders[h]),
                tokens: _rewardTokens(),
                beneficiary: holders[h]
            });
            // forge-lint: disable-next-line(calls-loop)
            assertEq(_reward.balanceOf(holders[h]) - before - fromSticky, fromSticky);
        }

        // forge-lint: disable-next-line(literal-instead-of-constant,uninitialized-local)
        for (uint256 round; round < 3; round++) {
            (
                uint208 amount,
                uint48 snapshotBlock,
                uint208 claimed,
                uint48 deadline,
                uint208 totalStake
                // forge-lint: disable-next-line(calls-loop)
            ) = _distributor.rewardRoundOf(address(_stickyToken), 0, _reward, round);
            (
                uint208 sAmount,
                uint48 sSnapshotBlock,
                uint208 sClaimed,
                uint48 sDeadline,
                uint208 sTotalStake
                // forge-lint: disable-next-line(calls-loop)
            ) = stock.rewardRoundOf(address(_stickyToken), 0, _reward, round);
            assertEq(amount, sAmount);
            assertEq(snapshotBlock, sSnapshotBlock);
            assertEq(claimed, sClaimed);
            assertEq(deadline, sDeadline);
            assertEq(totalStake, sTotalStake);
        }
        assertEq(
            _distributor.balanceOf(address(_stickyToken), _reward), stock.balanceOf(address(_stickyToken), _reward)
        );
        assertEq(
            _distributor.totalVestingAmountOf(address(_stickyToken), _reward),
            stock.totalVestingAmountOf(address(_stickyToken), _reward)
        );
    }

    /// @notice Holders cannot route their own rewards to the distributor, which would leave them in custody with no
    /// ledger entry.
    function test_holderCannotCollectToTheDistributor() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fund(100e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _beginVestingFor(_alice);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_NoAccess.selector, address(_stickyToken), uint256(uint160(_alice)), _alice
            )
        );
        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stickyToken),
            tokenIds: _tokenIds(_alice),
            tokens: _rewardTokens(),
            beneficiary: address(_distributor)
        });
    }

    function test_nativeSplitFundingCollectsThroughTheNativeTransferPath() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 75e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 25e18);
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.deal(terminal, 100e18);
        vm.prank(terminal);
        // forge-lint: disable-next-line(arbitrary-send-eth,literal-instead-of-constant)
        _distributor.processSplitWith{value: 100e18}(_splitContext(JBConstants.NATIVE_TOKEN, 100e18));

        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(JBConstants.NATIVE_TOKEN, 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(address(_distributor).balance, 100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _distributor.beginVesting({hook: address(_stickyToken), tokenIds: _tokenIds(_alice), tokens: _nativeTokens()});
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);

        uint256 aliceBalanceBefore = _alice.balance;
        _distributor.collectVestedRewards({
            hook: address(_stickyToken), tokenIds: _tokenIds(_alice), tokens: _nativeTokens(), beneficiary: _alice
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_alice.balance - aliceBalanceBefore, 75e18);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(address(_distributor).balance, 25e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(JBConstants.NATIVE_TOKEN)), 25e18);
    }

    function test_pokeLocksTheCurrentAndNextRoundSnapshots() public {
        uint256 round = _distributor.currentRound();
        vm.roll(vm.getBlockNumber() + 1);

        _distributor.poke();

        assertEq(_distributor.roundSnapshotBlock(round), vm.getBlockNumber() - 1);
        assertEq(_distributor.roundSnapshotBlock(round + 1), vm.getBlockNumber() - 1);
    }

    function test_postSnapshotDeepExitForfeitsAgedWeight() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 1000); // denominator 200e18

        _unstake(_bob, 80e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 1000);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 1000), 50e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_bob, 1000), 10e18); // 20/200 of the pot; 40e18 stays for recycle
    }

    function test_recencyPaysNewestWeeksExcludesOldTenure() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(20);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 1004);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 1004), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_bob, 1004), 100e18);
    }

    function test_recencyPotInsolvencyGuardAgainstSameEpochLateStake() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(20);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 500e18); // same epoch as the round start, right after the funding

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 1004);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectableGroupFor(_bob, 1004), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 aliceClaim = _collectGroupFor(_alice, 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 bobClaim = _collectGroupFor(_bob, 1004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(aliceClaim, 100e18);
        assertEq(bobClaim, 0);
    }

    function test_sameWeekTopUpsMergeAndAgeAsOne() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 40e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(vm.getBlockTimestamp() + 3 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 60e18); // merges into the epoch +10 tranche
        assertEq(_hook.trancheCountOf(_projectId, _alice), 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 2000); // window top is epoch +10: the whole merged tranche qualifies
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 2000);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 2000), 100e18);
    }

    function test_secondFundingSameRoundKeepsPinnedDenominator() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(10e18, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 900e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(5e18, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 1000);
        assertEq(amount, 15e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
    }

    function test_singleBucketWindowMatchesExactlyOneEpoch() public {
        _warpWeeks(15);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        _warpWeeks(16);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 100e18);
        _warpWeeks(17);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_carol, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(20);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(30e18, 4004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 4004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 4004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_bob, 4004);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_carol, 4004);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 4004), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_bob, 4004), 30e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_carol, 4004), 0);
    }

    function test_snapshotEpochIsPinnedAtRoundStart() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);

        // The round starting at +12 weeks runs one day. Funding early or late in it reads the same window.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        uint256 round = _distributor.currentRound();
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.snapshotEpochOf(round), _startEpoch + 12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.roundStartTimestamp(round), _start + 12 weeks);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(_start + 12 weeks + 20 hours);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_bob, 900e18); // same round, same epoch: never enters this round's window
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(10e18, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);

        // A round that starts mid-week still pins to that week's epoch, so earlier same-week stakes are excluded.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(_start + 13 weeks + 3 days + 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_carol, 50e18); // epoch +13, before the next round starts
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(_start + 13 weeks + 4 days + 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.snapshotEpochOf(_distributor.currentRound()), _startEpoch + 13);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(10e18, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (, totalStake) = _currentRewardRoundOf(address(_reward), 1000);
        assertEq(totalStake, 1000e18); // alice + bob, staked in epochs +10 and +12; carol's epoch +13 is excluded
    }

    function test_splitFundingCreditsOnlyWhatAFeeOnTransferTokenDelivers() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        _reward.setFeeBps(100);
        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: terminal, amount: 40e18});
        vm.startPrank(terminal);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 40e18});
        uint256 balanceBefore = _reward.balanceOf(address(_distributor));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.processSplitWith(_splitContext(address(_reward), 40e18));
        vm.stopPrank();

        uint256 delta = _reward.balanceOf(address(_distributor)) - balanceBefore;
        (uint208 amount,) = _currentRewardRoundOf(address(_reward), 0);
        assertEq(delta, 39.6e18);
        assertEq(amount, delta);
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(address(_reward))), delta);
    }

    function test_splitFundingCreditsTheErc20BalanceDelta() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: terminal, amount: 40e18});
        vm.startPrank(terminal);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 40e18});
        uint256 balanceBefore = _reward.balanceOf(address(_distributor));
        vm.expectEmit(address(_distributor));
        // forge-lint: disable-next-item(reentrancy-events)
        emit IJBStickyDistributor.Fund({
            hook: address(_stickyToken),
            groupId: 0,
            token: IERC20(address(_reward)),
            round: _distributor.currentRound(),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 40e18,
            caller: terminal
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.processSplitWith(_splitContext(address(_reward), 40e18));
        vm.stopPrank();

        uint256 delta = _reward.balanceOf(address(_distributor)) - balanceBefore;
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(delta, 40e18);
        assertEq(amount, delta);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(address(_reward))), 40e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _beginVestingFor(_alice);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_alice), 40e18);
    }

    function test_splitFundingRejectsUnauthorizedCallers() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_Unauthorized.selector, _projectId, address(this)
            )
        );
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.processSplitWith(_splitContext(address(_reward), 1e18));
    }

    function test_splitFundingRevertsWhenErc20CarriesNativeValue() public {
        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_TokenMismatch.selector,
                address(_reward),
                JBConstants.NATIVE_TOKEN,
                uint256(1)
            )
        );
        vm.prank(terminal);
        // forge-lint: disable-next-line(arbitrary-send-eth,literal-instead-of-constant)
        _distributor.processSplitWith{value: 1}(_splitContext(address(_reward), 1e18));
    }

    function test_splitFundingRevertsWhenNativeValueMissesTheContextAmount() public {
        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.deal(terminal, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                JBStickyDistributor.JBStickyDistributor_NativeAmountMismatch.selector,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256(0.5e18),
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256(1e18)
            )
        );
        vm.prank(terminal);
        // forge-lint: disable-next-line(arbitrary-send-eth,literal-instead-of-constant)
        _distributor.processSplitWith{value: 0.5e18}(_splitContext(JBConstants.NATIVE_TOKEN, 1e18));
    }

    function test_splitGroupValueInLockedUntilIsIgnored() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: terminal, amount: 10e18});
        vm.startPrank(terminal);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 10e18});
        _distributor.processSplitWith(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _splitContext({token: address(_reward), amount: 10e18, groupId: 0, lockedUntil: 4008})
        );
        vm.stopPrank();

        (uint208 amount,) = _currentRewardRoundOf(address(_reward), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
    }

    function test_splitInvalidGroupFallsToGroupZero() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // 4 decodes to minWeeks == 0, which is invalid, so it funds the default group instead of reverting.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _processSplitWithGroup({amount: 10e18, groupId: 4});
        (uint208 amount,) = _currentRewardRoundOf(address(_reward), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
    }

    function test_splitLockedGroupFundsTenurePot() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);

        // forge-lint: disable-next-line(literal-instead-of-constant,unsafe-typecast)
        uint48 futureLock = uint48(vm.getBlockTimestamp() + 365 days);
        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: terminal, amount: 10e18});
        vm.startPrank(terminal);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 10e18});
        _distributor.processSplitWith(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _splitContext({token: address(_reward), amount: 10e18, groupId: 3000, lockedUntil: futureLock})
        );
        vm.stopPrank();

        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 3000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
    }

    function test_splitOutOfRangeGroupFallsToGroupZero() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // forge-lint: disable-next-line(literal-instead-of-constant,unsafe-typecast)
        _processSplitWithGroup({amount: 10e18, groupId: uint64(vm.getBlockTimestamp() + 365 days)});
        (uint208 amount,) = _currentRewardRoundOf(address(_reward), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
    }

    function test_splitProjectIdSelectsCohortGroup() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(20);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _processSplitWithGroup({amount: 10e18, groupId: 4008});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 4008);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
    }

    function test_splitProjectIdSelectsTenureGroup() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(14);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _processSplitWithGroup({amount: 10e18, groupId: 3000});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(_reward), 3000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(totalStake, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.snapshotEpochOf(_distributor.currentRound()), _startEpoch + 14);
    }

    function test_splitTenureGroupForUnregisteredBeneficiaryFallsToGroupZero() public {
        // A Sticky token the hook never registered: it reports the project, but is not its movement reporter.
        JBStickyToken impostor = new JBStickyToken({
            name: "Impostor",
            symbol: "IMP",
            tokens: IJBTokens(address(this)),
            projectId: _projectId,
            hook: _hook,
            soulbound: true
        });
        assertTrue(_hook.tokenOf(_projectId) != address(impostor));
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: terminal, amount: 10e18});
        vm.startPrank(terminal);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 10e18});
        JBSplitHookContext memory context =
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _splitContext({token: address(_reward), amount: 10e18, groupId: 3000, lockedUntil: 0});
        context.split.beneficiary = payable(address(impostor));
        _distributor.processSplitWith(context);
        vm.stopPrank();

        // forge-lint: disable-next-line(unused-return)
        (uint208 amount,,,,) = _distributor.rewardRoundOf(address(impostor), 0, _reward, _distributor.currentRound());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e18);
        (
            uint208 tenureAmount,,,,
            // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        ) = _distributor.rewardRoundOf(address(impostor), 3000, _reward, _distributor.currentRound());
        assertEq(tenureAmount, 0);
    }

    function test_stakeAfterRoundStartCannotClaimThatRound() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fundGroup(100e18, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_carol, 500e18); // staked after the round started

        vm.warp(vm.getBlockTimestamp() + 3 weeks); // carol's tranche is well past minWeeks in wall-time
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_carol, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectableGroupFor(_carol, 1000), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _beginVestingGroupFor(_alice, 1000);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectGroupFor(_alice, 1000), 100e18);
    }

    function test_tenureDenominatorMatchesBruteForce() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        address[] memory holders = new address[](3);
        holders[0] = _alice;
        holders[1] = _bob;
        holders[2] = _carol;

        // Stakes and exits scattered across 20 weeks, several per week.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 seed = 7;
        // forge-lint: disable-next-line(literal-instead-of-constant,uninitialized-local)
        for (uint256 week; week < 20; week++) {
            // forge-lint: disable-next-line(literal-instead-of-constant,uninitialized-local)
            for (uint256 k; k < 3; k++) {
                seed = uint256(keccak256(abi.encode(seed, week, k)));
                // forge-lint: disable-next-line(calls-loop,literal-instead-of-constant)
                vm.warp(_start + week * 1 weeks + (seed % 6 days) + 1);
                // forge-lint: disable-next-line(literal-instead-of-constant)
                address holder = holders[seed % 3];
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256 amount = (seed >> 8) % 50e18 + 1;
                // forge-lint: disable-next-line(calls-loop,literal-instead-of-constant)
                if ((seed >> 4) % 4 == 0 && _hook.stakedBalanceOf(_projectId, holder) != 0) {
                    // forge-lint: disable-next-line(calls-loop)
                    _unstake(holder, amount % _hook.stakedBalanceOf(_projectId, holder) + 1);
                } else {
                    _stake(holder, amount);
                }
            }
        }

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(21);
        uint256 snapshotEpoch = _distributor.snapshotEpochOf(_distributor.currentRound());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(snapshotEpoch, _startEpoch + 21);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[4] memory groups = [uint256(1000), 4000, 3009, 1004];
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 g; g < groups.length; g++) {
            // forge-lint: disable-next-line(literal-instead-of-constant)
            uint256 minWeeks = groups[g] / 1000;
            // forge-lint: disable-next-line(literal-instead-of-constant)
            uint256 maxWeeks = groups[g] % 1000;
            uint256 hi = snapshotEpoch - minWeeks;
            uint256 lo = maxWeeks == 0 ? 0 : snapshotEpoch - maxWeeks;
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _fundGroup(1e18, groups[g]);
            (, uint208 totalStake) = _currentRewardRoundOf(address(_reward), groups[g]);
            assertEq(totalStake, _bruteForceWindow(holders, lo, hi), "denominator");

            // Every holder's numerator matches the same brute force over their own tranches.
            // forge-lint: disable-next-line(uninitialized-local)
            for (uint256 h; h < holders.length; h++) {
                // forge-lint: disable-next-line(calls-loop)
                address[] memory one = new address[](1);
                one[0] = holders[h];
                // forge-lint: disable-next-line(calls-loop)
                uint256 expected = _hook.stakedBalanceThroughEpochOf(_projectId, holders[h], hi)
                    // forge-lint: disable-next-line(calls-loop)
                    - (lo == 0 ? 0 : _hook.stakedBalanceThroughEpochOf(_projectId, holders[h], lo - 1));
                assertEq(expected, _bruteForceWindow(one, lo, hi), "numerator");
            }
        }
        assertEq(_hook.netStakedWithin(_projectId, _startEpoch, snapshotEpoch), IJBToken(_stickyToken).totalSupply());
    }

    function test_transferDoesNotInheritAgeForTenureClaims() public {
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        // forge-lint: disable-next-item(arbitrary-send-eth)
        uint256 openProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_staked)),
            name: "Open Sticky",
            symbol: "OSTICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        IJBToken openToken = jbTokens().tokenOf(openProjectId);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(10);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stakeIn({holder: _alice, amount: 100e18, targetProjectId: openProjectId});

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _warpWeeks(12);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({to: _funder, amount: 100e18});
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _reward.approve({spender: address(_distributor), value: 100e18});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.fund({hook: address(openToken), token: IERC20(address(_reward)), amount: 100e18, groupId: 1000});
        vm.stopPrank();

        // Alice moves half to carol after the snapshot: LIFO splits her only aged tranche, and carol's new tranche
        // is timestamped at the transfer, above the window.
        vm.prank(_alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer,literal-instead-of-constant)
        IERC20(address(openToken)).transfer({to: _carol, value: 50e18});

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _distributor.beginVesting({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            hook: address(openToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 1000,
            tokenIds: _tokenIds(_alice),
            tokens: _rewardTokens()
        });
        _distributor.beginVesting({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            hook: address(openToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 1000,
            tokenIds: _tokenIds(_carol),
            tokens: _rewardTokens()
        });
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);

        uint256 aliceBalanceBefore = _reward.balanceOf(_alice);
        _distributor.collectVestedRewards({
            hook: address(openToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 1000,
            tokenIds: _tokenIds(_alice),
            tokens: _rewardTokens(),
            beneficiary: _alice
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_reward.balanceOf(_alice) - aliceBalanceBefore, 50e18);

        uint256 carolBalanceBefore = _reward.balanceOf(_carol);
        _distributor.collectVestedRewards({
            hook: address(openToken),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            groupId: 1000,
            tokenIds: _tokenIds(_carol),
            tokens: _rewardTokens(),
            beneficiary: _carol
        });
        assertEq(_reward.balanceOf(_carol) - carolBalanceBefore, 0);
    }

    function test_unstakedHolderKeepsAlreadyClaimedRewards() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _beginVestingFor(_alice);

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _unstake(_alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION * _VESTING_ROUNDS);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_alice), 100e18);
    }

    function test_vestingUnlocksLinearlyAcrossRounds() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _stake(_alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        _beginVestingFor(_alice);
        assertEq(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _distributor.claimedFor(address(_stickyToken), uint256(uint160(_alice)), IERC20(address(_reward))),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            100e18
        );
        assertEq(_collectFor(_alice), 0);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        assertEq(
            _distributor.collectableFor(address(_stickyToken), uint256(uint160(_alice)), IERC20(address(_reward))),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            50e18
        );
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_alice), 50e18);

        vm.warp(vm.getBlockTimestamp() + _ROUND_DURATION);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_collectFor(_alice), 50e18);
        assertEq(_distributor.totalVestingAmountOf(address(_stickyToken), IERC20(address(_reward))), 0);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function test_bindingsAndInterfaces() public view {
        assertEq(address(_distributor.STICKY_HOOK()), address(_hook));
        assertEq(address(_distributor.DIRECTORY()), address(jbDirectory()));
        assertEq(address(_distributor.CONTROLLER()), address(jbController()));
        assertEq(address(_distributor.REV_LOANS()), address(0));
        assertEq(address(_distributor.REV_OWNER()), address(0));
        assertEq(_distributor.EPOCH_DURATION(), _hook.EPOCH_DURATION());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.CRITERIA_BASE(), 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.MAX_CRITERIA_WEEKS(), 520);
        assertTrue(_distributor.supportsInterface(type(IJBStickyDistributor).interfaceId));
        assertTrue(_distributor.supportsInterface(type(IJBTokenDistributor).interfaceId));
        assertTrue(_distributor.supportsInterface(type(IJBSplitHook).interfaceId));
        assertTrue(_distributor.supportsInterface(type(IERC165).interfaceId));
        assertFalse(_distributor.supportsInterface(0xffffffff));
    }

    function test_distributorFitsEip170() public view {
        assertLe(address(_distributor).code.length, 24_576);
    }

    function test_isValidGroupIdTable() public view {
        assertTrue(_distributor.isValidGroupId(0));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertTrue(_distributor.isValidGroupId(1000));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertTrue(_distributor.isValidGroupId(4000));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertTrue(_distributor.isValidGroupId(1004));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertTrue(_distributor.isValidGroupId(4008));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertTrue(_distributor.isValidGroupId(4004));
        assertTrue(_distributor.isValidGroupId(520_000));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertTrue(_distributor.isValidGroupId(520_520));
        assertFalse(_distributor.isValidGroupId(1)); // minWeeks == 0
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertFalse(_distributor.isValidGroupId(520)); // minWeeks == 0
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertFalse(_distributor.isValidGroupId(8004)); // maxWeeks < minWeeks
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertFalse(_distributor.isValidGroupId(4999)); // maxWeeks > 520
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertFalse(_distributor.isValidGroupId(521_000)); // minWeeks > 520
        assertFalse(_distributor.isValidGroupId(uint256(1) << 240));
        assertFalse(_distributor.isValidGroupId(type(uint256).max));
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Begins vesting a holder's unclaimed default-group rounds of the reward token.
    /// @param holder The holder whose rounds are claimed.
    function _beginVestingFor(address holder) internal {
        _distributor.beginVesting({hook: address(_stickyToken), tokenIds: _tokenIds(holder), tokens: _rewardTokens()});
    }

    /// @notice Begins vesting a holder's unclaimed rounds of the reward token in a tenure group.
    /// @param holder The holder whose rounds are claimed.
    /// @param groupId The tenure group to claim in.
    function _beginVestingGroupFor(address holder, uint256 groupId) internal {
        _distributor.beginVesting({
            hook: address(_stickyToken), groupId: groupId, tokenIds: _tokenIds(holder), tokens: _rewardTokens()
        });
    }

    /// @notice Collects everything unlocked for a holder in the default group.
    /// @param holder The holder whose rewards are collected.
    /// @return collected The amount of the reward token that landed in the holder's wallet.
    function _collectFor(address holder) internal returns (uint256 collected) {
        uint256 balanceBefore = _reward.balanceOf(holder);
        _distributor.collectVestedRewards({
            hook: address(_stickyToken), tokenIds: _tokenIds(holder), tokens: _rewardTokens(), beneficiary: holder
        });
        collected = _reward.balanceOf(holder) - balanceBefore;
    }

    /// @notice Collects everything unlocked for a holder in a tenure group.
    /// @param holder The holder whose rewards are collected.
    /// @param groupId The tenure group to collect from.
    /// @return collected The amount of the reward token that landed in the holder's wallet.
    function _collectGroupFor(address holder, uint256 groupId) internal returns (uint256 collected) {
        uint256 balanceBefore = _reward.balanceOf(holder);
        _distributor.collectVestedRewards({
            hook: address(_stickyToken),
            groupId: groupId,
            tokenIds: _tokenIds(holder),
            tokens: _rewardTokens(),
            beneficiary: holder
        });
        collected = _reward.balanceOf(holder) - balanceBefore;
    }

    /// @notice Funds the reward token into the sticky token's default-group pot, as the funder.
    /// @param amount The amount of the reward token to fund.
    function _fund(uint256 amount) internal {
        _reward.mint({to: _funder, amount: amount});
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(unused-return)
        _reward.approve({spender: address(_distributor), value: amount});
        _distributor.fund({hook: address(_stickyToken), token: IERC20(address(_reward)), amount: amount});
        vm.stopPrank();
    }

    /// @notice Funds the reward token into a group's pot for the sticky token, as the funder.
    /// @param amount The amount of the reward token to fund.
    /// @param groupId The tenure group to fund.
    function _fundGroup(uint256 amount, uint256 groupId) internal {
        // forge-lint: disable-next-line(calls-loop)
        _reward.mint({to: _funder, amount: amount});
        // forge-lint: disable-next-line(calls-loop)
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(calls-loop,unused-return)
        _reward.approve({spender: address(_distributor), value: amount});
        // forge-lint: disable-next-item(calls-loop)
        _distributor.fund({
            hook: address(_stickyToken), token: IERC20(address(_reward)), amount: amount, groupId: groupId
        });
        // forge-lint: disable-next-line(calls-loop)
        vm.stopPrank();
    }

    /// @notice Funds the reward token into a group's pot for another sticky token's holders, as the funder.
    /// @param rewardedHook The sticky token whose holders are rewarded.
    /// @param amount The amount of the reward token to fund.
    /// @param groupId The tenure group to fund.
    function _fundHook(address rewardedHook, uint256 amount, uint256 groupId) internal {
        _reward.mint({to: _funder, amount: amount});
        vm.startPrank(_funder);
        // forge-lint: disable-next-line(unused-return)
        _reward.approve({spender: address(_distributor), value: amount});
        _distributor.fund({hook: rewardedHook, token: IERC20(address(_reward)), amount: amount, groupId: groupId});
        vm.stopPrank();
    }

    /// @notice Funds the open project's shares from alice as a default-group reward for the first project.
    /// @param openToken The open project's share token.
    /// @param amount The number of shares to fund.
    function _fundShares(IJBToken openToken, uint256 amount) internal {
        vm.startPrank(_alice);
        // forge-lint: disable-next-line(unused-return)
        IERC20(address(openToken)).approve({spender: address(_distributor), value: amount});
        _distributor.fund({hook: address(_stickyToken), token: IERC20(address(openToken)), amount: amount});
        vm.stopPrank();
        assertEq(openToken.balanceOf(address(_distributor)), amount);
    }

    /// @notice Launches a transferable Sticky project for the staked token, so its shares can be handed out as
    /// rewards.
    /// @return openProjectId The launched project's ID.
    /// @return openToken The launched project's share token.
    function _launchOpenProject() internal returns (uint256 openProjectId, IJBToken openToken) {
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        // forge-lint: disable-next-item(arbitrary-send-eth)
        openProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_staked)),
            name: "Open Sticky",
            symbol: "OSTICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        openToken = jbTokens().tokenOf(openProjectId);
    }

    /// @notice Routes the reward token through a payout split carrying a group, as the terminal.
    /// @param amount The amount of the reward token to route.
    /// @param groupId The group carried on the split's `projectId`.
    function _processSplitWithGroup(uint256 amount, uint64 groupId) internal {
        address terminal = address(jbMultiTerminal());
        _reward.mint({to: terminal, amount: amount});
        vm.startPrank(terminal);
        // forge-lint: disable-next-line(unused-return)
        _reward.approve({spender: address(_distributor), value: amount});
        _distributor.processSplitWith(
            _splitContext({token: address(_reward), amount: amount, groupId: groupId, lockedUntil: 0})
        );
        vm.stopPrank();
    }

    /// @notice Stakes the underlying for a holder into the soulbound project, minting them an equal count of sticky
    /// tokens.
    /// @param holder The account that stakes.
    /// @param amount The amount of the underlying to stake.
    function _stake(address holder, uint256 amount) internal {
        _stakeIn({holder: holder, amount: amount, targetProjectId: _projectId});
    }

    /// @notice Stakes the underlying for a holder into a Sticky project.
    /// @param holder The account that stakes.
    /// @param amount The amount of the underlying to stake.
    /// @param targetProjectId The project to stake into.
    function _stakeIn(address holder, uint256 amount, uint256 targetProjectId) internal {
        // forge-lint: disable-next-line(calls-loop)
        _staked.mint({to: holder, amount: amount});
        // forge-lint: disable-next-line(calls-loop)
        vm.startPrank(holder);
        // forge-lint: disable-next-line(calls-loop,unused-return)
        _staked.approve({spender: address(jbMultiTerminal()), value: amount});
        // forge-lint: disable-next-item(calls-loop)
        jbMultiTerminal().pay({
            projectId: targetProjectId,
            token: address(_staked),
            amount: amount,
            beneficiary: holder,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        // forge-lint: disable-next-line(calls-loop)
        vm.stopPrank();
    }

    /// @notice Unstakes sticky tokens for a holder from the soulbound project.
    /// @param holder The account that unstakes.
    /// @param count The number of sticky tokens to cash out.
    function _unstake(address holder, uint256 count) internal {
        // forge-lint: disable-next-line(calls-loop)
        vm.prank(holder);
        // forge-lint: disable-next-item(calls-loop)
        jbMultiTerminal().cashOutTokensOf({
            holder: holder,
            projectId: _projectId,
            cashOutCount: count,
            tokenToReclaim: address(_staked),
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: bytes("")
        });
    }

    /// @notice Warps to one second into the round that starts a number of weeks after the distributor started.
    /// @param weekCount The number of weeks after the distributor's start.
    function _warpWeeks(uint256 weekCount) internal {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(_start + weekCount * 1 weeks + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice The token list holding only the native token.
    /// @return tokens A single-element list holding the native token.
    function _nativeTokens() internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);
    }

    /// @notice The token ID list holding only a holder's ID.
    /// @param holder The holder whose ID is listed.
    /// @return tokenIds A single-element list holding the holder's address as an ID.
    function _tokenIds(address holder) internal pure returns (uint256[] memory tokenIds) {
        // forge-lint: disable-next-line(calls-loop)
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Brute-force sum of every holder's live tranches created in `[lo, hi]`.
    /// @param holders The holders whose tranches are summed.
    /// @param lo The first epoch counted.
    /// @param hi The last epoch counted.
    /// @return sum The summed tranche amounts.
    function _bruteForceWindow(address[] memory holders, uint256 lo, uint256 hi) internal view returns (uint256 sum) {
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 h; h < holders.length; h++) {
            // forge-lint: disable-next-line(calls-loop)
            JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, holders[h]);
            // forge-lint: disable-next-line(uninitialized-local)
            for (uint256 t; t < tranches.length; t++) {
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256 epoch = uint256(tranches[t].timestamp) / 1 weeks;
                if (epoch >= lo && epoch <= hi) sum += tranches[t].amount;
            }
        }
    }

    /// @notice The amount of the reward token a holder can collect from a tenure group.
    /// @param holder The holder whose collectable amount is read.
    /// @param groupId The tenure group read.
    /// @return collectable The collectable amount.
    function _collectableGroupFor(address holder, uint256 groupId) internal view returns (uint256 collectable) {
        return _distributor.collectableFor(address(_stickyToken), groupId, uint256(uint160(holder)), _reward);
    }

    /// @notice The current round's pot and denominator for a group and reward token.
    /// @param token The reward token read.
    /// @param groupId The group read.
    /// @return amount The round's funded amount.
    /// @return totalStake The round's pinned denominator.
    function _currentRewardRoundOf(
        address token,
        uint256 groupId
    )
        internal
        view
        returns (uint208 amount, uint208 totalStake)
    {
        // forge-lint: disable-next-item(unused-return)
        (amount,,,, totalStake) =
        // forge-lint: disable-next-line(calls-loop)
        _distributor.rewardRoundOf(address(_stickyToken), groupId, IERC20(token), _distributor.currentRound());
    }

    /// @notice The current round's pot and denominator for another sticky token's group.
    /// @param rewardedHook The sticky token whose round is read.
    /// @param groupId The group read.
    /// @return amount The round's funded amount.
    /// @return totalStake The round's pinned denominator.
    function _currentRewardRoundOfHook(
        address rewardedHook,
        uint256 groupId
    )
        internal
        view
        returns (uint208 amount, uint208 totalStake)
    {
        // forge-lint: disable-next-item(unused-return)
        (amount,,,, totalStake) =
            _distributor.rewardRoundOf(rewardedHook, groupId, IERC20(address(_reward)), _distributor.currentRound());
    }

    /// @notice The token list holding only the reward token.
    /// @return tokens A single-element list holding the reward token.
    function _rewardTokens() internal view returns (IERC20[] memory tokens) {
        // forge-lint: disable-next-line(calls-loop)
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_reward));
    }

    /// @notice A payout-split context routing a token amount to the sticky token's holders.
    /// @param token The token being routed.
    /// @param amount The amount being routed.
    /// @return context The split hook context.
    function _splitContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory context) {
        context = _splitContext({token: token, amount: amount, groupId: 0, lockedUntil: 0});
    }

    /// @notice A payout-split context carrying a group on the split's `projectId`, optionally locked.
    /// @param token The token being routed.
    /// @param amount The amount being routed.
    /// @param groupId The group carried on the split's `projectId`.
    /// @param lockedUntil The split's lock timestamp.
    /// @return context The split hook context.
    function _splitContext(
        address token,
        uint256 amount,
        uint64 groupId,
        uint48 lockedUntil
    )
        internal
        view
        returns (JBSplitHookContext memory context)
    {
        context = JBSplitHookContext({
            token: token,
            amount: amount,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            decimals: 18,
            projectId: _projectId,
            groupId: uint256(uint160(token)),
            split: JBSplit({
                percent: 0,
                projectId: groupId,
                beneficiary: payable(address(_stickyToken)),
                preferAddToBalance: false,
                lockedUntil: lockedUntil,
                hook: IJBSplitHook(address(_distributor))
            })
        });
    }
}
