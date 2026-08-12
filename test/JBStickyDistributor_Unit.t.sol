// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";

/// @notice An 18-decimal ERC-20 standing in for a token that gets staked or handed out as a reward.
contract MockErc20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

contract JBStickyDistributorUnitTest is TestBaseWorkflow {
    uint256 constant ROUND_DURATION = 1 days;
    uint256 constant VESTING_ROUNDS = 2;
    uint48 constant CLAIM_DURATION = 30 days;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address funder = makeAddr("funder");

    MockErc20 staked;
    MockErc20 reward;
    JBStickyDeployer deployer;
    IJBStickyHook hook;
    JBStickyDistributor distributor;
    uint256 projectId;
    IJBToken stickyToken;

    function setUp() public override {
        super.setUp();

        staked = new MockErc20("Staked", "STK");
        reward = new MockErc20("Reward", "RWD");

        deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        hook = deployer.HOOK();

        // Deploy a sticky project for the staked token, forwarding the project creation fee.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Sticky",
            symbol: "STICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        stickyToken = jbTokens().tokenOf(projectId);

        distributor = new JBStickyDistributor({
            directory: jbDirectory(),
            stickyHook: hook,
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: CLAIM_DURATION
        });
    }

    //*********************************************************************//
    // ------------------------------ helpers ---------------------------- //
    //*********************************************************************//

    /// @notice Stake `amount` of the underlying for `holder`, minting them an equal count of sticky tokens.
    function _stake(address holder, uint256 amount) internal {
        staked.mint({to: holder, amount: amount});
        vm.startPrank(holder);
        staked.approve({spender: address(jbMultiTerminal()), value: amount});
        jbMultiTerminal()
            .pay({
            projectId: projectId,
            token: address(staked),
            amount: amount,
            beneficiary: holder,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
    }

    /// @notice Unstake `count` sticky tokens for `holder`.
    function _unstake(address holder, uint256 count) internal {
        vm.prank(holder);
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: address(staked),
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: bytes("")
        });
    }

    function _tokenIds(address holder) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
    }

    function _rewardTokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));
    }

    function _fund(uint256 amount) internal {
        reward.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: amount});
        distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount});
        vm.stopPrank();
    }

    function _beginVestingFor(address holder) internal {
        distributor.beginVesting({hook: address(stickyToken), tokenIds: _tokenIds(holder), tokens: _rewardTokens()});
    }

    /// @notice Collect everything unlocked for `holder`, returning the amount that landed in their wallet.
    function _collectFor(address holder) internal returns (uint256 collected) {
        uint256 balanceBefore = reward.balanceOf(holder);
        distributor.collectVestedRewards({
            hook: address(stickyToken), tokenIds: _tokenIds(holder), tokens: _rewardTokens(), beneficiary: holder
        });
        collected = reward.balanceOf(holder) - balanceBefore;
    }

    //*********************************************************************//
    // ------------------------------- tests ----------------------------- //
    //*********************************************************************//

    function test_group0FundClaimCollect_parity() public {
        // Two holders stake 75/25 before funding.
        _stake(alice, 75e18);
        _stake(bob, 25e18);
        vm.roll(vm.getBlockNumber() + 1); // votes checkpoints need a past block

        _fund(100e18);

        // Next round: claims materialize 75/25.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        _beginVestingFor(bob);

        // Full vesting: collect everything.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 75e18);
        assertEq(_collectFor(bob), 25e18);
    }

    function test_vestingUnlocksLinearlyAcrossRounds() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);

        // Claim in the next round: the whole pot starts vesting, nothing is unlocked yet.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        assertEq(distributor.claimedFor(address(stickyToken), uint256(uint160(alice)), IERC20(address(reward))), 100e18);
        assertEq(_collectFor(alice), 0);

        // Halfway through the vesting period, half unlocks.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        assertEq(
            distributor.collectableFor(address(stickyToken), uint256(uint160(alice)), IERC20(address(reward))), 50e18
        );
        assertEq(_collectFor(alice), 50e18);

        // The rest unlocks at the release round.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        assertEq(_collectFor(alice), 50e18);
        assertEq(distributor.totalVestingAmountOf(address(stickyToken), IERC20(address(reward))), 0);
    }

    function test_expiredRoundsRecycleUnclaimedRewards() public {
        _stake(alice, 50e18);
        _stake(bob, 50e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);
        uint256 fundedRound = distributor.currentRound();

        // Only alice claims before the round's window closes.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        vm.warp(vm.getBlockTimestamp() + CLAIM_DURATION);

        // Bob's unclaimed half recycles into the current round.
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = fundedRound;
        uint256 recycled = distributor.recycleExpiredRewards({
            hook: address(stickyToken), token: IERC20(address(reward)), rounds: rounds
        });
        assertEq(recycled, 50e18);

        // Nothing left to recycle from the expired round, and the inventory never left the distributor.
        assertEq(
            distributor.recycleExpiredRewards({
                hook: address(stickyToken), token: IERC20(address(reward)), rounds: rounds
            }),
            0
        );
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(address(reward))), 100e18);

        // Alice still collects the 50 she claimed before expiry.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 50e18);
    }

    function test_pokeLocksTheCurrentAndNextRoundSnapshots() public {
        uint256 round = distributor.currentRound();
        vm.roll(vm.getBlockNumber() + 1);

        distributor.poke();

        assertEq(distributor.roundSnapshotBlock(round), vm.getBlockNumber() - 1);
        assertEq(distributor.roundSnapshotBlock(round + 1), vm.getBlockNumber() - 1);
    }

    function test_splitFundingRejectsUnauthorizedCallers() public {
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(reward),
            amount: 1e18,
            decimals: 18,
            projectId: projectId,
            groupId: 1,
            split: JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(address(stickyToken)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(distributor))
            })
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_Unauthorized.selector, projectId, address(this)
            )
        );
        distributor.processSplitWith(context);
    }

    function test_unstakedHolderKeepsAlreadyClaimedRewards() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);

        // Leaving the position does not claw back rewards that already started vesting.
        _unstake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 100e18);
    }
}
