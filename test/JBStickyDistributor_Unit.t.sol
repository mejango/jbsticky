// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";

/// @notice An 18-decimal ERC-20 standing in for a token that gets staked or handed out as a reward.
contract MockErc20 is ERC20 {
    uint256 public feeBps; // taken out of every transfer when non-zero

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        if (fee != 0 && from != address(0) && to != address(0)) {
            super._update({from: from, to: address(0xdead), value: fee});
            value -= fee;
        }
        super._update({from: from, to: to, value: value});
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

    function _nativeTokens() internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);
    }

    /// @notice A payout-split context routing `amount` of `token` to the sticky token's stakers.
    function _splitContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory context) {
        context = JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: uint256(uint160(token)),
            split: JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(address(stickyToken)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(distributor))
            })
        });
    }

    /// @notice The reward round the distributor is currently funding into.
    function _currentRewardRoundOf(address token) internal view returns (uint208 amount, uint208 totalStake) {
        (amount,,,, totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 0, IERC20(token), distributor.currentRound());
    }

    function _fund(uint256 amount) internal {
        reward.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: amount});
        distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount});
        vm.stopPrank();
    }

    /// @notice Fund `amount` of the reward token into a specific criteria group's pot for the sticky token.
    function _fundGroup(uint256 amount, uint256 groupId) internal {
        reward.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: amount});
        distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount, groupId: groupId});
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
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_Unauthorized.selector, projectId, address(this)
            )
        );
        distributor.processSplitWith(_splitContext(address(reward), 1e18));
    }

    function test_splitFundingCreditsTheErc20BalanceDelta() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // A payout split hands the distributor 40 reward tokens on the terminal's behalf.
        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 40e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 40e18});
        uint256 balanceBefore = reward.balanceOf(address(distributor));
        distributor.processSplitWith(_splitContext(address(reward), 40e18));
        vm.stopPrank();

        // The pot is exactly what actually landed, and it is denominated against the staked supply.
        uint256 delta = reward.balanceOf(address(distributor)) - balanceBefore;
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward));
        assertEq(delta, 40e18);
        assertEq(amount, delta);
        assertEq(totalStake, 100e18);
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(address(reward))), 40e18);

        // The split-funded pot claims and collects like any other round.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 40e18);
    }

    function test_splitFundingCreditsOnlyWhatAFeeOnTransferTokenDelivers() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // The token skims 1% on the way in, so the nominal split amount overstates what arrives.
        reward.setFeeBps(100);
        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 40e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 40e18});
        uint256 balanceBefore = reward.balanceOf(address(distributor));
        distributor.processSplitWith(_splitContext(address(reward), 40e18));
        vm.stopPrank();

        // Only the delivered amount becomes claimable, so the pot can never over-promise.
        uint256 delta = reward.balanceOf(address(distributor)) - balanceBefore;
        (uint208 amount,) = _currentRewardRoundOf(address(reward));
        assertEq(delta, 39.6e18);
        assertEq(amount, delta);
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(address(reward))), delta);
    }

    function test_splitFundingRevertsWhenErc20CarriesNativeValue() public {
        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_TokenMismatch.selector,
                address(reward),
                JBConstants.NATIVE_TOKEN,
                uint256(1)
            )
        );
        vm.prank(terminal);
        distributor.processSplitWith{value: 1}(_splitContext(address(reward), 1e18));
    }

    function test_splitFundingRevertsWhenNativeValueMissesTheContextAmount() public {
        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_NativeAmountMismatch.selector, uint256(0.5e18), uint256(1e18)
            )
        );
        vm.prank(terminal);
        distributor.processSplitWith{value: 0.5e18}(_splitContext(JBConstants.NATIVE_TOKEN, 1e18));
    }

    function test_nativeSplitFundingCollectsThroughTheNativeTransferPath() public {
        _stake(alice, 75e18);
        _stake(bob, 25e18);
        vm.roll(vm.getBlockNumber() + 1);

        // A native payout split must deliver exactly the context amount.
        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 100e18);
        vm.prank(terminal);
        distributor.processSplitWith{value: 100e18}(_splitContext(JBConstants.NATIVE_TOKEN, 100e18));

        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(JBConstants.NATIVE_TOKEN);
        assertEq(amount, 100e18);
        assertEq(totalStake, 100e18);
        assertEq(address(distributor).balance, 100e18);

        // Claim, then collect through the native-transfer branch.
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        distributor.beginVesting({hook: address(stickyToken), tokenIds: _tokenIds(alice), tokens: _nativeTokens()});
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        uint256 aliceBalanceBefore = alice.balance;
        distributor.collectVestedRewards({
            hook: address(stickyToken), tokenIds: _tokenIds(alice), tokens: _nativeTokens(), beneficiary: alice
        });
        assertEq(alice.balance - aliceBalanceBefore, 75e18);

        // Bob's unclaimed share stays in the distributor's custody.
        assertEq(address(distributor).balance, 25e18);
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(JBConstants.NATIVE_TOKEN)), 25e18);
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
        _stake(bob, 900e18); // same round, after the pin
        _fundGroup(5e18, 1); // must not re-walk
        (uint208 amount,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 1, reward, distributor.currentRound());
        assertEq(amount, 15e18);
        assertEq(totalStake, 100e18);
    }
}
