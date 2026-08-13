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
    address carol = makeAddr("carol");
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
        context = _splitContext({token: token, amount: amount, lockedUntil: 0});
    }

    /// @notice A payout-split context routing `amount` of `token` to the sticky token's stakers, carrying
    /// `lockedUntil` on the split (the criteria-selection field under test).
    function _splitContext(
        address token,
        uint256 amount,
        uint48 lockedUntil
    )
        internal
        view
        returns (JBSplitHookContext memory context)
    {
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
                lockedUntil: lockedUntil,
                hook: IJBSplitHook(address(distributor))
            })
        });
    }

    /// @notice Route `amount` of the reward token through a payout split carrying `lockedUntil`, pranking the
    /// registered terminal as the caller.
    function _processSplitWithLockedUntil(uint256 amount, uint48 lockedUntil) internal {
        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: amount});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: amount});
        distributor.processSplitWith(_splitContext({token: address(reward), amount: amount, lockedUntil: lockedUntil}));
        vm.stopPrank();
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

    /// @notice Begin vesting `holder`'s unclaimed rewards in a specific criteria group.
    function _beginVestingGroupFor(address holder, uint256 groupId) internal {
        distributor.beginVesting({
            hook: address(stickyToken), groupId: groupId, tokenIds: _tokenIds(holder), tokens: _rewardTokens()
        });
    }

    /// @notice Collect everything unlocked for `holder` in a specific criteria group, returning the amount that
    /// landed in their wallet.
    function _collectGroupFor(address holder, uint256 groupId) internal returns (uint256 collected) {
        uint256 balanceBefore = reward.balanceOf(holder);
        distributor.collectVestedRewards({
            hook: address(stickyToken),
            groupId: groupId,
            tokenIds: _tokenIds(holder),
            tokens: _rewardTokens(),
            beneficiary: holder
        });
        collected = reward.balanceOf(holder) - balanceBefore;
    }

    /// @notice The collectable (unlocked, uncollected) amount for `holder` in a specific criteria group.
    function _collectableGroupFor(address holder, uint256 groupId) internal view returns (uint256) {
        return distributor.collectableFor(address(stickyToken), groupId, uint256(uint160(holder)), reward);
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

    function test_splitLockedUntilSelectsCriteriaGroup() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        vm.warp(14 weeks + 1); // alice's tranche is 4 epochs old

        _processSplitWithLockedUntil({amount: 10e18, lockedUntil: 3000}); // lockedUntil = 3000 => min = 3 weeks
        (uint208 amount,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 3000, reward, distributor.currentRound());
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
    }

    function test_splitRealLockTimestampFallsToGroupZero() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // A genuine future lock timestamp is far outside the valid criteria-window range and must not be mistaken
        // for a criteria window.
        _processSplitWithLockedUntil({amount: 10e18, lockedUntil: uint48(vm.getBlockTimestamp() + 365 days)});
        (uint208 amount,,,,,) = distributor.rewardRoundOf(address(stickyToken), 0, reward, distributor.currentRound());
        assertEq(amount, 10e18);
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

    function test_fundAcceptsValidCriteriaGroups() public {
        uint256[5] memory validGroups = [uint256(0), 4000, 1004, 4008, 520_520];

        vm.roll(vm.getBlockNumber() + 1); // group 0 needs a past block for its votes snapshot

        reward.mint(funder, 5e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 5e18);
        for (uint256 i; i < validGroups.length; i++) {
            distributor.fund(address(stickyToken), reward, 1e18, validGroups[i]);
        }
        vm.stopPrank();
    }

    function test_fundRejectsInvalidCriteriaGroups() public {
        // 8004 = max(4) < min(8); 4999 = max(999) > MAX_CRITERIA_WEEKS; 521000 = min(521) > MAX_CRITERIA_WEEKS;
        // 1 << 240 lands in the reserved curve band and also fails min > MAX_CRITERIA_WEEKS.
        uint256[4] memory invalidGroups = [uint256(8004), 4999, 521_000, uint256(1) << 240];

        reward.mint(funder, 10e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 10e18);
        for (uint256 i; i < invalidGroups.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    JBStickyDistributor.JBStickyDistributor_InvalidCriteria.selector, invalidGroups[i]
                )
            );
            distributor.fund(address(stickyToken), reward, 1e18, invalidGroups[i]);
        }
        vm.stopPrank();
    }

    function test_oldEncodingGroupIdsFailClosed() public {
        // Every previously-valid bare-k criteria value (1-520) decodes to minWeeks == 0 under the new encoding,
        // which is invalid — a stale config reverts rather than being silently reinterpreted as a different window.
        reward.mint(funder, 10e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 10e18);

        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidCriteria.selector, 4));
        distributor.fund(address(stickyToken), reward, 1e18, 4);

        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidCriteria.selector, 520));
        distributor.fund(address(stickyToken), reward, 1e18, 520);
        vm.stopPrank();
    }

    function test_fundWithCriteriaCreatesGroupPot() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        vm.warp(14 weeks + 1); // alice's tranche is 4 epochs old

        reward.mint(funder, 10e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 10e18);
        distributor.fund(address(stickyToken), reward, 10e18, 2000); // stuck >= 2 weeks
        vm.stopPrank();

        (uint208 amount,,,, uint208 totalStake, uint48 snapshotEpoch) =
            distributor.rewardRoundOf(address(stickyToken), 2000, reward, distributor.currentRound());
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
        assertEq(snapshotEpoch, 14);
    }

    function test_fundWithCriteriaAcceptsNativeToken() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        vm.warp(14 weeks + 1); // alice's tranche is 4 epochs old

        vm.deal(funder, 10e18);
        vm.prank(funder);
        // stuck >= 2 weeks
        distributor.fund{value: 10e18}(address(stickyToken), IERC20(JBConstants.NATIVE_TOKEN), 0, 2000);

        (uint208 amount,,,, uint208 totalStake, uint48 snapshotEpoch) = distributor.rewardRoundOf(
            address(stickyToken), 2000, IERC20(JBConstants.NATIVE_TOKEN), distributor.currentRound()
        );
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
        assertEq(snapshotEpoch, 14);
    }

    function test_denominatorSumsOnlyAgedBuckets() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        vm.warp(13 weeks + 1);
        _stake(bob, 300e18); // too fresh for min=2 at epoch 14
        vm.warp(14 weeks + 1);

        _fundGroup(10e18, 2000);
        (,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 2000, reward, distributor.currentRound());
        assertEq(totalStake, 100e18); // only alice's epoch-10 bucket is <= 14 - 2
    }

    function test_denominatorZeroWhenNothingAged() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        _fundGroup(10e18, 52_000); // nothing is a year old
        (,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 52_000, reward, distributor.currentRound());
        assertEq(totalStake, 0);
    }

    function test_secondFundingSameRoundKeepsPinnedDenominator() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        vm.warp(12 weeks + 1);
        _fundGroup(10e18, 1000);
        _stake(bob, 900e18); // same round, after the pin
        _fundGroup(5e18, 1000); // must not re-walk
        (uint208 amount,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 1000, reward, distributor.currentRound());
        assertEq(amount, 15e18);
        assertEq(totalStake, 100e18);
    }

    function test_claimSplitsProRataAcrossAgedTranches() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        vm.warp(13 weeks + 1);
        _stake(bob, 600e18); // fresh bob tranche won't count for min=2 at epoch 14
        vm.warp(14 weeks + 1);
        _fundGroup(100e18, 2000); // denominator = 400e18

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 2000);
        _beginVestingGroupFor(bob, 2000);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 2000), 25e18);
        assertEq(_collectGroupFor(bob, 2000), 75e18);
    }

    function test_postSnapshotDeepExitForfeitsAgedWeight() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        vm.warp(12 weeks + 1);
        _fundGroup(100e18, 1000); // denominator 200e18

        // Bob unsticks 80 after the snapshot: LIFO eats into his only (aged) tranche.
        _unstake(bob, 80e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 1000);
        _beginVestingGroupFor(bob, 1000);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 1000), 50e18); // alice's share unaffected
        assertEq(_collectGroupFor(bob, 1000), 10e18); // 20/200 of the pot; 40e18 stays for recycle
    }

    function test_lateStakeCannotClaimOldRound() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18);
        vm.warp(12 weeks + 1);
        _fundGroup(100e18, 1000);
        _stake(carol, 500e18); // staked after snapshot

        vm.warp(vm.getBlockTimestamp() + 30 weeks); // carol's tranche is now ancient in wall-time
        _beginVestingGroupFor(carol, 1000);
        assertEq(_collectableGroupFor(carol, 1000), 0); // epoch 12 > snapshotEpoch(12) - 1
    }

    function test_transferDoesNotInheritAgeForCriteriaClaims() public {
        // A transferable sticky project, independent of this file's soulbound `stickyToken`.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 openProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Open Sticky",
            symbol: "OSTICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        IJBToken openToken = jbTokens().tokenOf(openProjectId);

        vm.warp(10 weeks + 1);
        staked.mint({to: alice, amount: 100e18});
        vm.startPrank(alice);
        staked.approve({spender: address(jbMultiTerminal()), value: 100e18});
        jbMultiTerminal()
            .pay({
            projectId: openProjectId,
            token: address(staked),
            amount: 100e18,
            beneficiary: alice,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();

        vm.warp(12 weeks + 1);
        reward.mint({to: funder, amount: 100e18});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: 100e18});
        distributor.fund({hook: address(openToken), token: IERC20(address(reward)), amount: 100e18, groupId: 1000});
        vm.stopPrank();

        // Alice transfers half her position to carol AFTER the snapshot, in the same epoch it was funded. LIFO
        // consumes her only (aged) tranche, splitting it: her remaining 50e18 keeps the aged epoch-10 timestamp,
        // and carol's new 50e18 tranche is timestamped now — too young to age into this round's cutoff (epoch
        // 12 - 1 = 11). The receiver never inherits the sender's age.
        vm.prank(alice);
        IERC20(address(openToken)).transfer({to: carol, value: 50e18});

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        distributor.beginVesting({
            hook: address(openToken), groupId: 1000, tokenIds: _tokenIds(alice), tokens: _rewardTokens()
        });
        distributor.beginVesting({
            hook: address(openToken), groupId: 1000, tokenIds: _tokenIds(carol), tokens: _rewardTokens()
        });
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        uint256 aliceBalanceBefore = reward.balanceOf(alice);
        distributor.collectVestedRewards({
            hook: address(openToken),
            groupId: 1000,
            tokenIds: _tokenIds(alice),
            tokens: _rewardTokens(),
            beneficiary: alice
        });
        // The denominator was pinned at fund time (100e18, all alice's). Her surviving aged tranche is only half
        // of that, so she claims half the pot; the other half is forfeit (available for recycle), matching the
        // deep-exit forfeiture pattern — a transfer-out behaves like a partial unstake for aged weight.
        assertEq(reward.balanceOf(alice) - aliceBalanceBefore, 50e18);

        uint256 carolBalanceBefore = reward.balanceOf(carol);
        distributor.collectVestedRewards({
            hook: address(openToken),
            groupId: 1000,
            tokenIds: _tokenIds(carol),
            tokens: _rewardTokens(),
            beneficiary: carol
        });
        assertEq(reward.balanceOf(carol) - carolBalanceBefore, 0);
    }

    //*********************************************************************//
    // --------------------- criteria-window generalization --------------- //
    //*********************************************************************//

    function test_cohortDenominatorOnlyMiddleBucketsCount() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18); // epoch 10 — below the (4, 8) window at snapshot epoch 20
        vm.warp(14 weeks + 1);
        _stake(bob, 200e18); // epoch 14 — inside [12, 16]
        vm.warp(18 weeks + 1);
        _stake(carol, 300e18); // epoch 18 — above the window (too fresh for min = 4)
        vm.warp(20 weeks + 1);

        _fundGroup(10e18, 4008); // cohort: 4 to 8 weeks
        (,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 4008, reward, distributor.currentRound());
        assertEq(totalStake, 200e18); // only bob's epoch-14 bucket falls inside [12, 16]
    }

    function test_cohortNumeratorClaimsOnlyDepositCohortSlice() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18); // epoch 10 — below the (4, 8) window
        vm.warp(14 weeks + 1);
        _stake(alice, 100e18); // epoch 14 — inside [12, 16]
        _stake(bob, 100e18); // epoch 14 — inside [12, 16], matches alice's in-window slice
        vm.warp(18 weeks + 1);
        _stake(alice, 100e18); // epoch 18 — above the window (too fresh)
        vm.warp(20 weeks + 1);

        _fundGroup(100e18, 4008); // denominator = alice's epoch-14 100e18 + bob's epoch-14 100e18 = 200e18

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 4008);
        _beginVestingGroupFor(bob, 4008);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        // Alice staked 300e18 across three tranches, but only her epoch-14 deposit-cohort slice counts — so she
        // splits the pot evenly with bob rather than claiming 3x his share.
        assertEq(_collectGroupFor(alice, 4008), 50e18);
        assertEq(_collectGroupFor(bob, 4008), 50e18);
    }

    function test_recencyPaysNewestWeeksExcludesOldTenure() public {
        vm.warp(10 weeks + 1);
        _stake(alice, 100e18); // epoch 10 — older tenure, outside the recency window
        vm.warp(18 weeks + 1);
        _stake(bob, 100e18); // epoch 18 — inside the last-4-completed-weeks window [16, 19] at snapshot 20
        vm.warp(20 weeks + 1);

        _fundGroup(100e18, 1004); // recency: last 4 completed weeks
        (,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 1004, reward, distributor.currentRound());
        assertEq(totalStake, 100e18); // only bob's recent stake counts; alice's old tenure is excluded

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 1004);
        _beginVestingGroupFor(bob, 1004);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 1004), 0);
        assertEq(_collectGroupFor(bob, 1004), 100e18);
    }

    function test_recencyPotInsolvencyGuardAgainstSameEpochLateStake() public {
        vm.warp(18 weeks + 1);
        _stake(alice, 100e18); // epoch 18 — inside the (1, 4) window at snapshot epoch 20

        vm.warp(20 weeks + 1);
        _fundGroup(100e18, 1004); // recency window [16, 19]; denominator = alice's 100e18
        _stake(bob, 500e18); // epoch 20 — staked in the SAME epoch as the fund tx, right after it

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 1004);
        _beginVestingGroupFor(bob, 1004);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        // Bob's tranche lands in epoch 20 == snapshotEpoch, strictly above hi = 19 — min >= 1 keeps the snapshot
        // epoch itself out of every window — so it contributes zero to his claim regardless of the recorded
        // denominator. This is the guard that keeps the sum of claims from ever exceeding the funded pot.
        assertEq(_collectableGroupFor(bob, 1004), 0);
        uint256 aliceClaim = _collectGroupFor(alice, 1004);
        uint256 bobClaim = _collectGroupFor(bob, 1004);
        assertEq(aliceClaim, 100e18);
        assertEq(bobClaim, 0);
        assertEq(aliceClaim + bobClaim, 100e18); // sum of claims never exceeds the pot
    }

    function test_splitLockedUntilSelectsCohortGroup() public {
        vm.warp(14 weeks + 1);
        _stake(alice, 100e18); // epoch 14 — inside a (4, 8) window at snapshot epoch 20
        vm.warp(20 weeks + 1);

        _processSplitWithLockedUntil({amount: 10e18, lockedUntil: 4008});
        (uint208 amount,,,, uint208 totalStake,) =
            distributor.rewardRoundOf(address(stickyToken), 4008, reward, distributor.currentRound());
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18); // alice's epoch-14 tranche falls inside [12, 16]
    }

    function test_splitStaleEncodingFallsToGroupZero() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // lockedUntil = 4 is the old bare-k encoding, which decodes to minWeeks == 0 and is invalid — it must fall
        // to group 0 rather than reverting, same as a real lock timestamp.
        _processSplitWithLockedUntil({amount: 10e18, lockedUntil: 4});
        (uint208 amount,,,,,) = distributor.rewardRoundOf(address(stickyToken), 0, reward, distributor.currentRound());
        assertEq(amount, 10e18);
    }
}
