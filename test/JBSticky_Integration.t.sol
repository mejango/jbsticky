// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JBStickyAutoStick} from "../src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {JBStickyRewardReceiver} from "../src/JBStickyRewardReceiver.sol";
import {JBStickyRewardReceiverFactory} from "../src/JBStickyRewardReceiverFactory.sol";
import {JBStickyToken} from "../src/JBStickyToken.sol";

import {JBAutoStickStatus} from "../src/enums/JBAutoStickStatus.sol";

import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";

import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice A 6-decimal token standing in for a project token to be staked (e.g. ART).
contract MockArt is ERC20 {
    /// @notice Deploys the token with its fixed name and symbol.
    constructor() ERC20("Art", "ART") {}

    /// @notice The number of decimals the token uses.
    /// @return tokenDecimals The number of decimals.
    function decimals() public pure override returns (uint8 tokenDecimals) {
        return 6;
    }

    /// @notice Mints tokens to an account.
    /// @param to The account to mint to.
    /// @param amount The amount to mint.
    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice Sticky projects deployed through the real Juicebox controller and terminal: staking, unstaking, streaks,
/// distributor rewards, cross-chain reward receivers, and auto-stick compounding end to end.
contract JBStickyIntegrationTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The token staked into the sticky project.
    MockArt internal _art;

    /// @notice The Sticky factory.
    JBStickyDeployer internal _deployer;

    /// @notice A granter of the sticky project, who can stake on behalf of holders.
    address internal _granter = makeAddr("granter");

    /// @notice The hook shared by every project the factory deploys.
    IJBStickyHook internal _hook;

    /// @notice The ID of the sticky project deployed in `setUp`.
    uint256 internal _projectId;

    /// @notice The sticky project's share token.
    IJBToken internal _token;

    /// @notice The holder who stakes into the sticky project.
    address internal _user = makeAddr("user");

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();

        _art = new MockArt();
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = _deployer.HOOK();

        // Deploy a sticky project for ART, forwarding the project creation fee.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        _projectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_art)),
            name: "Streaking ART",
            symbol: "STREAKART",
            projectUri: "ipfs://streaks",
            cashOutTaxRate: 0,
            granters: _granters(_granter),
            soulbound: true
        });
        _token = jbTokens().tokenOf(_projectId);

        _art.mint({to: _user, amount: 100e6});
        vm.prank(_user);
        _art.approve({spender: address(jbMultiTerminal()), value: type(uint256).max});
    }

    function test_autoStickAfterFullUnstickRestartsPosition() public {
        (, JBStickyAutoStick adapter) = _autoStickFixture();
        _enableAutoStick(adapter, 1e6, 1 days);

        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        adapter.beginVestingFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);

        // The user fully unsticks but leaves auto-stick enabled — a later compound reopens the position with a
        // fresh streak. This is why the UI's full-exit flow must disable auto-stick first.
        _unstake(_user, 30e18);
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 0);
        uint256 restart = vm.getBlockTimestamp();
        adapter.compoundFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 75e18);
        assertEq(_hook.streakStartOf(_projectId, _user), restart);
    }

    function test_autoStickCompoundsVestedRewardsIntoNewTranche() public {
        uint256 start = vm.getBlockTimestamp();
        (, JBStickyAutoStick adapter) = _autoStickFixture();
        _enableAutoStick(adapter, 1e6, 1 days);

        // After the round completes, any keeper starts vesting through the adapter.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        adapter.beginVestingFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});

        // Once fully vested and a week past the original stake, the keeper compounds: the user's 75 ART share is
        // collected, pulled, and restuck into a tranche of its own rather than merging into the same-week one.
        vm.warp(start + 1 weeks);
        vm.roll(vm.getBlockNumber() + 1);
        (JBAutoStickStatus status,,,) = adapter.statusOf(_projectId, _user, _defaultGroup());
        assertEq(uint256(status), uint256(JBAutoStickStatus.Ready));
        uint256 walletBefore = _art.balanceOf(_user);
        vm.prank(keeper);
        (uint256 underlyingAmount, uint256 stickyTokenCount) =
            adapter.compoundFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});
        assertEq(underlyingAmount, 75e6);
        assertEq(stickyTokenCount, 75e18);

        // The reward passes through the user's wallet and ends up staked — a fresh tranche at the compound
        // timestamp because a week has passed, with the original streak untouched.
        assertEq(_art.balanceOf(_user), walletBefore);
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 105e18);
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, _user);
        assertEq(tranches.length, 2);
        assertEq(tranches[1].amount, 75e18);
        assertEq(tranches[1].timestamp, vm.getBlockTimestamp());
        assertEq(_hook.streakStartOf(_projectId, _user), start);

        // No custody left behind, and the cooldown gates the next compound.
        assertEq(_art.balanceOf(address(adapter)), 0);
        (JBAutoStickStatus afterStatus,,, uint256 nextCompoundAt) = adapter.statusOf(_projectId, _user, _defaultGroup());
        assertEq(uint256(afterStatus), uint256(JBAutoStickStatus.Cooldown));
        assertEq(nextCompoundAt, vm.getBlockTimestamp() + 1 days);
    }

    function test_autoStickGranterProjectSkipsPerHolderTrust() public {
        (JBStickyDistributor distributor, JBStickyAutoStick adapter) = _autoStickFixture();

        // A creator launches a project with the adapter pre-approved as a granter.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 granterProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_art)),
            name: "Granter ART",
            symbol: "GRANTART",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: _granters(address(adapter)),
            soulbound: true
        });
        IJBToken granterToken = jbTokens().tokenOf(granterProjectId);

        // The holder stakes and enables auto-stick WITHOUT a trust tx: just allowance + config.
        _art.mint({to: _user, amount: 20e6});
        vm.startPrank(_user);
        jbMultiTerminal().pay({
            projectId: granterProjectId,
            token: address(_art),
            amount: 20e6,
            beneficiary: _user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        _art.approve({spender: address(adapter), value: type(uint256).max});
        adapter.setConfigFor({projectId: granterProjectId, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);

        // Move to a fresh round so its snapshot lands after the holder's stake (the fixture's earlier funding
        // already pinned the current round's snapshot).
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);

        // Fund, roll the round, vest, and compound — the hook accepts the adapter through granter status.
        address funder = makeAddr("granter-funder");
        _art.mint({to: funder, amount: 40e6});
        vm.startPrank(funder);
        _art.approve({spender: address(distributor), value: 40e6});
        distributor.fund({hook: address(granterToken), token: IERC20(address(_art)), amount: 40e6});
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        adapter.beginVestingFor({projectId: granterProjectId, holder: _user, groupIds: _defaultGroup()});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);
        assertFalse(_hook.isTrustedSenderOf(granterProjectId, _user, address(adapter)));
        (uint256 underlyingAmount,) =
            adapter.compoundFor({projectId: granterProjectId, holder: _user, groupIds: _defaultGroup()});
        assertEq(underlyingAmount, 40e6);
        assertEq(_hook.stakedBalanceOf(granterProjectId, _user), 60e18);
    }

    function test_autoStickRevokingAnyLegBlocksCompound() public {
        (, JBStickyAutoStick adapter) = _autoStickFixture();
        _enableAutoStick(adapter, 1e6, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        adapter.beginVestingFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);

        // Revoking hook trust alone blocks the compound.
        vm.prank(_user);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(adapter), trusted: false});
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector, _projectId, _user)
        );
        adapter.compoundFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});

        // Restoring trust but revoking the allowance alone blocks it too.
        vm.startPrank(_user);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(adapter), trusted: true});
        _art.approve({spender: address(adapter), value: 0});
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InsufficientAllowance.selector, 0, 75e6)
        );
        adapter.compoundFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});

        // Restoring the allowance but disabling the config alone blocks it as well; re-enabling compounds.
        vm.startPrank(_user);
        _art.approve({spender: address(adapter), value: type(uint256).max});
        adapter.setConfigFor({projectId: _projectId, enabled: false, minimumAmount: 1e6, cooldown: 1 days});
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Disabled.selector, _projectId, _user)
        );
        adapter.compoundFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});

        vm.prank(_user);
        adapter.setConfigFor({projectId: _projectId, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
        (uint256 underlyingAmount,) =
            adapter.compoundFor({projectId: _projectId, holder: _user, groupIds: _defaultGroup()});
        assertEq(underlyingAmount, 75e6);
    }

    function test_commitmentRewardTaxesLeaversAndRewardsStayers() public {
        // Deploy a second sticky project with a 50% commitment reward.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 rewardProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_art)),
            name: "Hard ART",
            symbol: "HARDART",
            projectUri: "",
            cashOutTaxRate: 5000,
            granters: new address[](0),
            soulbound: true
        });
        assertEq(_deployer.cashOutTaxRateOf(rewardProjectId), 5000);

        // Two equal stakers.
        _art.mint({to: _granter, amount: 10e6});
        vm.startPrank(_granter);
        _art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal().pay({
            projectId: rewardProjectId,
            token: address(_art),
            amount: 10e6,
            beneficiary: _granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.prank(_user);
        jbMultiTerminal().pay({
            projectId: rewardProjectId,
            token: address(_art),
            amount: 10e6,
            beneficiary: _user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });

        // The leaver's reclaim follows the bonding curve — proportional 10, taxed to 7.5 — minus the 2.5% protocol
        // fee that applies to taxed cash outs.
        vm.prank(_user);
        uint256 leaverReclaim = jbMultiTerminal().cashOutTokensOf({
            holder: _user,
            projectId: rewardProjectId,
            cashOutCount: 10e18,
            tokenToReclaim: address(_art),
            minTokensReclaimed: 0,
            beneficiary: payable(_user),
            metadata: bytes("")
        });
        // The leaver reclaims 7.5 ART * 0.975.
        assertEq(leaverReclaim, 7_312_500);

        // The stayer's eventual unwind collects more than they put in: the leaver's forfeited share stayed behind.
        vm.prank(_granter);
        uint256 stayerReclaim = jbMultiTerminal().cashOutTokensOf({
            holder: _granter,
            projectId: rewardProjectId,
            cashOutCount: 10e18,
            tokenToReclaim: address(_art),
            minTokensReclaimed: 0,
            beneficiary: payable(_granter),
            metadata: bytes("")
        });
        assertGt(stayerReclaim, 10e6);
    }

    function test_crossChainRewardReceiversSettleArrivalsIntoRewards() public {
        JBStickyDistributor distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        JBStickyRewardReceiverFactory receiverFactory = new JBStickyRewardReceiverFactory(distributor);

        // Two streakers: 30 and 10 ART locked.
        _stake(_user, _user, 30e6);
        _art.mint({to: _granter, amount: 10e6});
        vm.startPrank(_granter);
        _art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_art),
            amount: 10e6,
            beneficiary: _granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);

        // A cross-chain arrival lands at the PREDICTED receiver address before the receiver exists — exactly how a
        // sucker claim would deliver bridged project tokens to a counterfactual beneficiary.
        address receiver = receiverFactory.predictReceiverOf({stickyToken: address(_token), groupId: 0});
        assertEq(receiver.code.length, 0);
        _art.mint({to: receiver, amount: 100e6});

        // Anyone settles: the receiver is deployed at the predicted address and the arrival becomes a reward round.
        uint256 settled =
            receiverFactory.settleFor({stickyToken: address(_token), groupId: 0, token: IERC20(address(_art))});
        assertEq(settled, 100e6);
        assertEq(receiverFactory.receiverOf({stickyToken: address(_token), groupId: 0}), receiver);
        assertEq(distributor.balanceOf(address(_token), IERC20(address(_art))), 100e6);

        // Settling again with nothing in the receiver is a harmless no-op.
        assertEq(receiverFactory.settleFor({stickyToken: address(_token), groupId: 0, token: IERC20(address(_art))}), 0);

        // The streakers collect their shares of the arrival like any other reward round.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = uint256(uint160(_user));
        tokenIds[1] = uint256(uint160(_granter));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_art));
        distributor.beginVesting({hook: address(_token), tokenIds: tokenIds, tokens: tokens});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 userBalanceBefore = _art.balanceOf(_user);
        uint256[] memory userId = new uint256[](1);
        userId[0] = uint256(uint160(_user));
        distributor.collectVestedRewards({hook: address(_token), tokenIds: userId, tokens: tokens, beneficiary: _user});
        assertEq(_art.balanceOf(_user) - userBalanceBefore, 75e6);
    }

    function test_distributorRewardsStreakersAcrossPositions() public {
        // A sticky-tuned distributor: 1-day rounds, fully vested after 2 rounds, 30-day claim window.
        JBStickyDistributor distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });

        // Two streakers: 30 and 10 ART locked.
        _stake(_user, _user, 30e6);
        _art.mint({to: _granter, amount: 10e6});
        vm.startPrank(_granter);
        _art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_art),
            amount: 10e6,
            beneficiary: _granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();

        // Move past the stakes so the funding snapshot sees them.
        vm.roll(block.number + 1);

        // A third party funds 100 ART of rewards for this round's streakers.
        address funder = makeAddr("funder");
        _art.mint({to: funder, amount: 100e6});
        vm.startPrank(funder);
        _art.approve({spender: address(distributor), value: 100e6});
        distributor.fund({hook: address(_token), token: IERC20(address(_art)), amount: 100e6});
        vm.stopPrank();

        // After the round completes, anyone can start vesting for the streakers.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(block.number + 1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = uint256(uint160(_user));
        tokenIds[1] = uint256(uint160(_granter));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_art));
        distributor.beginVesting({hook: address(_token), tokenIds: tokenIds, tokens: tokens});

        // Once fully vested, each streaker collects their staked-balance share: 75 and 25 ART.
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(block.number + 1);
        uint256 userBalanceBefore = _art.balanceOf(_user);
        uint256 granterBalanceBefore = _art.balanceOf(_granter);
        uint256[] memory userId = new uint256[](1);
        userId[0] = uint256(uint160(_user));
        distributor.collectVestedRewards({hook: address(_token), tokenIds: userId, tokens: tokens, beneficiary: _user});
        uint256[] memory granterId = new uint256[](1);
        granterId[0] = uint256(uint160(_granter));
        distributor.collectVestedRewards({
            hook: address(_token), tokenIds: granterId, tokens: tokens, beneficiary: _granter
        });
        assertEq(_art.balanceOf(_user) - userBalanceBefore, 75e6);
        assertEq(_art.balanceOf(_granter) - granterBalanceBefore, 25e6);
    }

    function test_donationsAccrueToRemainingStakers() public {
        _stake(_user, _user, 10e6);

        // A donation to the project's balance (without staking) raises the surplus above 1:1.
        _art.mint({to: _granter, amount: 10e6});
        vm.startPrank(_granter);
        _art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal().addToBalanceOf({
            projectId: _projectId,
            token: address(_art),
            amount: 10e6,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();

        // The lone staker unwinds into the full surplus: 10 staked + 10 donated.
        uint256 reclaimed = _unstake(_user, 10e18);
        assertEq(reclaimed, 20e6);
    }

    function test_grantsAutoAddTranchesWithoutTouchingTheStreak() public {
        uint256 start = vm.getBlockTimestamp();
        _stake(_user, _user, 10e6);
        vm.warp(start + 300 days);

        // A third party (e.g. the protocol granting rewards) stakes on the user's behalf: no user action needed.
        _art.mint({to: _granter, amount: 5e6});
        vm.startPrank(_granter);
        _art.approve({spender: address(jbMultiTerminal()), value: 5e6});
        vm.stopPrank();
        _stake(_granter, _user, 5e6);

        // The grant is its own tranche with its own timestamp — the streak isn't backdated or broken.
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, _user);
        assertEq(tranches.length, 2);
        assertEq(tranches[1].amount, 5e18);
        assertEq(tranches[1].timestamp, start + 300 days);
        assertEq(_hook.streakStartOf(_projectId, _user), start);
    }

    function test_oneClickClaimAndStickNeedsNoConfig() public {
        (JBStickyDistributor distributor, JBStickyAutoStick adapter) = _autoStickFixture();

        // The holder trusts the adapter and grants an allowance — but never touches setConfigFor.
        vm.startPrank(_user);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(adapter), trusted: true});
        _art.approve({spender: address(adapter), value: type(uint256).max});
        vm.stopPrank();

        // Vesting starts permissionlessly on the distributor itself; no adapter config is required.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(_user));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_art));
        distributor.beginVesting({hook: address(_token), tokenIds: tokenIds, tokens: tokens});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);

        // One click: the claim sticks atomically, straight into a fresh tranche.
        vm.prank(_user);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.stickRewardsFor(_projectId, _defaultGroup());
        assertEq(underlyingAmount, 75e6);
        assertEq(stickyTokenCount, 75e18);
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 105e18);
        (,,, bool enabled) = adapter.configOf(_projectId, _user);
        assertFalse(enabled);
    }

    function test_perGroupReceiversFundSeparatePots() public {
        JBStickyDistributor distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        JBStickyRewardReceiverFactory receiverFactory = new JBStickyRewardReceiverFactory(distributor);

        // A holder stakes, then two weeks pass so their tranche is old enough for a one-week tenure window.
        _stake(_user, _user, 30e6);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        vm.roll(vm.getBlockNumber() + 1);

        // The default group's receiver and the tenure group's receiver are different counterfactual addresses.
        address defaultReceiver = receiverFactory.predictReceiverOf({stickyToken: address(_token), groupId: 0});
        address tenureReceiver = receiverFactory.predictReceiverOf({stickyToken: address(_token), groupId: 1000});
        assertTrue(defaultReceiver != tenureReceiver);

        // A group the distributor rejects has no receiver to predict or deploy.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyRewardReceiverFactory.JBStickyRewardReceiverFactory_InvalidGroupId.selector, 4
            )
        );
        receiverFactory.predictReceiverOf({stickyToken: address(_token), groupId: 4});
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyRewardReceiverFactory.JBStickyRewardReceiverFactory_InvalidGroupId.selector, 4
            )
        );
        receiverFactory.deployReceiverFor({stickyToken: address(_token), groupId: 4});

        // Arrivals at each receiver settle into their own pots.
        _art.mint({to: defaultReceiver, amount: 40e6});
        _art.mint({to: tenureReceiver, amount: 60e6});
        assertEq(
            receiverFactory.settleFor({stickyToken: address(_token), groupId: 0, token: IERC20(address(_art))}), 40e6
        );
        assertEq(
            receiverFactory.settleFor({stickyToken: address(_token), groupId: 1000, token: IERC20(address(_art))}), 60e6
        );
        assertEq(receiverFactory.receiverOf({stickyToken: address(_token), groupId: 0}), defaultReceiver);
        assertEq(receiverFactory.receiverOf({stickyToken: address(_token), groupId: 1000}), tenureReceiver);
        assertEq(JBStickyRewardReceiver(tenureReceiver).GROUP_ID(), 1000);
        assertEq(JBStickyRewardReceiver(tenureReceiver).STICKY_TOKEN(), address(_token));
        assertEq(address(JBStickyRewardReceiver(tenureReceiver).DISTRIBUTOR()), address(distributor));
        (uint208 defaultPot,,,, uint208 defaultStake) =
            distributor.rewardRoundOf(address(_token), 0, IERC20(address(_art)), distributor.currentRound());
        (uint208 tenurePot,,,, uint208 tenureStake) =
            distributor.rewardRoundOf(address(_token), 1000, IERC20(address(_art)), distributor.currentRound());
        assertEq(defaultPot, 40e6);
        assertEq(tenurePot, 60e6);
        assertEq(defaultStake, 30e18);
        assertEq(tenureStake, 30e18);

        // Once the round completes, both pots start vesting; two rounds later they are fully unlocked.
        uint256[] memory groupIds = new uint256[](2);
        groupIds[1] = 1000;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(_user));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_art));
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        distributor.beginVesting({hook: address(_token), groupId: 0, tokenIds: tokenIds, tokens: tokens});
        distributor.beginVesting({hook: address(_token), groupId: 1000, tokenIds: tokenIds, tokens: tokens});
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.roll(vm.getBlockNumber() + 1);

        // The holder collects from both groups in one auto-stick call.
        JBStickyAutoStick adapter = new JBStickyAutoStick({deployer: _deployer, distributor: distributor});
        vm.startPrank(_user);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(adapter), trusted: true});
        _art.approve({spender: address(adapter), value: type(uint256).max});
        vm.stopPrank();
        vm.prank(_user);
        (uint256 underlyingAmount,) = adapter.stickRewardsFor({projectId: _projectId, groupIds: groupIds});
        assertEq(underlyingAmount, 100e6);
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 130e18);
    }

    function test_stakeUnstakeRoundTrip() public {
        uint256 start = vm.getBlockTimestamp();

        // Staking 10 ART (6 decimals) mints 10 sART (18 decimals), 1:1.
        uint256 minted = _stake(_user, _user, 10e6);
        assertEq(minted, 10e18);
        assertEq(jbTokens().totalBalanceOf(_user, _projectId), 10e18);
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 10e18);
        assertEq(_hook.streakStartOf(_projectId, _user), start);

        // Stake 5 more a month later: a second tranche, same streak.
        vm.warp(start + 30 days);
        _stake(_user, _user, 5e6);
        assertEq(_hook.trancheCountOf(_projectId, _user), 2);
        assertEq(_hook.streakStartOf(_projectId, _user), start);

        // Unstake 7: LIFO consumes the newest tranche (5) and splits the oldest down to 8, keeping its timestamp.
        vm.warp(start + 40 days);
        uint256 reclaimed = _unstake(_user, 7e18);
        assertEq(reclaimed, 7e6);
        assertEq(_art.balanceOf(_user), 100e6 - 15e6 + 7e6);
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, _user);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 8e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(_hook.currentStreakOf(_projectId, _user), 40 days);

        // Unstake the rest: all ART returned 1:1, streak ends, longest streak recorded.
        reclaimed = _unstake(_user, 8e18);
        assertEq(reclaimed, 8e6);
        assertEq(_art.balanceOf(_user), 100e6);
        assertEq(_hook.stakedBalanceOf(_projectId, _user), 0);
        assertEq(_hook.currentStreakOf(_projectId, _user), 0);
        assertEq(_hook.longestStreakOf(_projectId, _user), 40 days);
    }

    function test_tokenIsSoulbound() public {
        _stake(_user, _user, 10e6);

        // Stakes mint the soulbound ERC-20 directly, and it can't be transferred.
        assertEq(_token.balanceOf(_user), 10e18);
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(JBStickyToken.JBStickyToken_Soulbound.selector, _user, _granter));
        IERC20(address(_token)).transfer({to: _granter, value: 1e18});

        // The soulbound tokens can still be unstaked.
        uint256 reclaimed = _unstake(_user, 10e18);
        assertEq(reclaimed, 10e6);
    }

    function test_transferableModeMovesAccountingAndRestartsClock() public {
        // Deploy a transferable sticky project.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 openProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_art)),
            name: "Open ART",
            symbol: "OPENART",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        IJBToken openToken = jbTokens().tokenOf(openProjectId);

        // Stake two tranches a month apart.
        uint256 start = vm.getBlockTimestamp();
        vm.prank(_user);
        jbMultiTerminal().pay({
            projectId: openProjectId,
            token: address(_art),
            amount: 10e6,
            beneficiary: _user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.warp(start + 30 days);
        vm.prank(_user);
        jbMultiTerminal().pay({
            projectId: openProjectId,
            token: address(_art),
            amount: 5e6,
            beneficiary: _user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });

        // Transferring 7 restarts the clock on the moved tokens: the sender's newest tranches are consumed (the
        // oldest keeps its timestamp) and the receiver's streak starts at the transfer.
        vm.prank(_user);
        IERC20(address(openToken)).transfer({to: _granter, value: 7e18});

        JBStickyTranche[] memory senderTranches = _hook.tranchesOf(openProjectId, _user);
        assertEq(senderTranches.length, 1);
        assertEq(senderTranches[0].amount, 8e18);
        assertEq(senderTranches[0].timestamp, start);
        assertEq(_hook.streakStartOf(openProjectId, _user), start);

        JBStickyTranche[] memory receiverTranches = _hook.tranchesOf(openProjectId, _granter);
        assertEq(receiverTranches.length, 1);
        assertEq(receiverTranches[0].amount, 7e18);
        assertEq(receiverTranches[0].timestamp, start + 30 days);
        assertEq(_hook.streakStartOf(openProjectId, _granter), start + 30 days);

        // The receiver can unwind what they received.
        vm.prank(_granter);
        uint256 reclaimed = jbMultiTerminal().cashOutTokensOf({
            holder: _granter,
            projectId: openProjectId,
            cashOutCount: 7e18,
            tokenToReclaim: address(_art),
            minTokensReclaimed: 0,
            beneficiary: payable(_granter),
            metadata: bytes("")
        });
        assertEq(reclaimed, 7e6);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys a sticky-tuned distributor and an auto-stick adapter, stakes 30/10 ART for the user/granter,
    /// and funds 100 ART of rewards so the user's fully-vested share is 75 ART.
    /// @return distributor The distributor holding the funded round.
    /// @return adapter The auto-stick adapter wired to the deployer and distributor.
    function _autoStickFixture() internal returns (JBStickyDistributor distributor, JBStickyAutoStick adapter) {
        distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        adapter = new JBStickyAutoStick({deployer: _deployer, distributor: distributor});

        _stake(_user, _user, 30e6);
        _art.mint({to: _granter, amount: 10e6});
        vm.startPrank(_granter);
        _art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_art),
            amount: 10e6,
            beneficiary: _granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(block.number + 1);

        address funder = makeAddr("funder");
        _art.mint({to: funder, amount: 100e6});
        vm.startPrank(funder);
        _art.approve({spender: address(distributor), value: 100e6});
        distributor.fund({hook: address(_token), token: IERC20(address(_art)), amount: 100e6});
        vm.stopPrank();
    }

    /// @notice Performs the holder's three-step auto-stick opt-in: allowance, hook trust, then config enabled last.
    /// @param adapter The auto-stick adapter to opt into.
    /// @param minimumAmount The minimum reward amount worth compounding.
    /// @param cooldown The minimum seconds between keeper compounds.
    function _enableAutoStick(JBStickyAutoStick adapter, uint128 minimumAmount, uint48 cooldown) internal {
        vm.startPrank(_user);
        _art.approve({spender: address(adapter), value: type(uint256).max});
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(adapter), trusted: true});
        adapter.setConfigFor({projectId: _projectId, enabled: true, minimumAmount: minimumAmount, cooldown: cooldown});
        vm.stopPrank();
    }

    /// @notice Stakes ART into the sticky project on behalf of a beneficiary.
    /// @param payer The account paying the ART.
    /// @param beneficiary The account receiving the sticky shares.
    /// @param amount The amount of ART to stake.
    /// @return mintedCount The number of sticky shares minted to the beneficiary.
    function _stake(address payer, address beneficiary, uint256 amount) internal returns (uint256 mintedCount) {
        vm.prank(payer);
        return jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_art),
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
    }

    /// @notice Cashes out sticky shares back into ART.
    /// @param holder The account cashing out.
    /// @param count The number of sticky shares to cash out.
    /// @return reclaimedAmount The amount of ART reclaimed.
    function _unstake(address holder, uint256 count) internal returns (uint256 reclaimedAmount) {
        vm.prank(holder);
        return jbMultiTerminal().cashOutTokensOf({
            holder: holder,
            projectId: _projectId,
            cashOutCount: count,
            tokenToReclaim: address(_art),
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: bytes("")
        });
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Builds the group list holding only the default reward group.
    /// @return groupIds A single-entry list containing group 0.
    function _defaultGroup() internal pure returns (uint256[] memory groupIds) {
        groupIds = new uint256[](1);
    }

    /// @notice Builds a single-entry granter list.
    /// @param granter The granter to include.
    /// @return granters A list containing only the granter.
    function _granters(address granter) internal pure returns (address[] memory granters) {
        granters = new address[](1);
        granters[0] = granter;
    }
}
