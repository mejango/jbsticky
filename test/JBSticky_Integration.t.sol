// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {JBStickyRewardPockets} from "../src/JBStickyRewardPockets.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";

import {JBStickyAutoStick} from "../src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {JBStickyHook} from "../src/JBStickyHook.sol";
import {JBStickyToken} from "../src/JBStickyToken.sol";
import {JBAutoStickStatus} from "../src/enums/JBAutoStickStatus.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice A 6-decimal token standing in for a project token to be staked (e.g. ART).
contract MockArt is ERC20 {
    constructor() ERC20("Art", "ART") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice An 18-decimal reward token routed through a payout split in the criteria-pot integration test.
contract MockRwd is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

contract JBStickyIntegrationTest is TestBaseWorkflow {
    address user = makeAddr("user");
    address granter = makeAddr("granter");

    MockArt art;
    JBStickyDeployer deployer;
    IJBStickyHook hook;
    uint256 projectId;
    IJBToken token;

    function setUp() public override {
        super.setUp();

        art = new MockArt();
        deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        hook = deployer.HOOK();

        // Deploy a sticky project for ART, forwarding the project creation fee.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(art)),
            name: "Streaking ART",
            symbol: "STREAKART",
            projectUri: "ipfs://streaks",
            cashOutTaxRate: 0,
            granters: _granters(granter),
            soulbound: true
        });
        token = jbTokens().tokenOf(projectId);

        art.mint({to: user, amount: 100e6});
        vm.prank(user);
        art.approve({spender: address(jbMultiTerminal()), value: type(uint256).max});
    }

    //*********************************************************************//
    // ------------------------------ helpers ---------------------------- //
    //*********************************************************************//

    function _granters(address granter_) internal pure returns (address[] memory granters) {
        granters = new address[](1);
        granters[0] = granter_;
    }

    function _stake(address payer, address beneficiary, uint256 amount) internal returns (uint256) {
        vm.prank(payer);
        return jbMultiTerminal()
            .pay({
            projectId: projectId,
            token: address(art),
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
    }

    function _unstake(address holder, uint256 count) internal returns (uint256) {
        vm.prank(holder);
        return jbMultiTerminal()
            .cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: address(art),
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: bytes("")
        });
    }

    //*********************************************************************//
    // ------------------------------- tests ----------------------------- //
    //*********************************************************************//

    function test_distributorRewardsStreakersAcrossPositions() public {
        // A sticky-tuned distributor: 1-day rounds, fully vested after 2 rounds, 30-day claim window.
        JBTokenDistributor distributor = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });

        // Two streakers: 30 and 10 ART locked.
        _stake(user, user, 30e6);
        art.mint({to: granter, amount: 10e6});
        vm.startPrank(granter);
        art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal()
            .pay({
            projectId: projectId,
            token: address(art),
            amount: 10e6,
            beneficiary: granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();

        // Move past the stakes so the funding snapshot sees them.
        vm.roll(block.number + 1);

        // A third party funds 100 ART of rewards for this round's streakers.
        address funder = makeAddr("funder");
        art.mint({to: funder, amount: 100e6});
        vm.startPrank(funder);
        art.approve({spender: address(distributor), value: 100e6});
        distributor.fund({hook: address(token), token: IERC20(address(art)), amount: 100e6});
        vm.stopPrank();

        // After the round completes, anyone can start vesting for the streakers.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(block.number + 1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = uint256(uint160(user));
        tokenIds[1] = uint256(uint160(granter));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(art));
        distributor.beginVesting({hook: address(token), tokenIds: tokenIds, tokens: tokens});

        // Once fully vested, each streaker collects their staked-balance share: 75 and 25 ART.
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(block.number + 1);
        uint256 userBalanceBefore = art.balanceOf(user);
        uint256 granterBalanceBefore = art.balanceOf(granter);
        uint256[] memory userId = new uint256[](1);
        userId[0] = uint256(uint160(user));
        distributor.collectVestedRewards({hook: address(token), tokenIds: userId, tokens: tokens, beneficiary: user});
        uint256[] memory granterId = new uint256[](1);
        granterId[0] = uint256(uint160(granter));
        distributor.collectVestedRewards({
            hook: address(token), tokenIds: granterId, tokens: tokens, beneficiary: granter
        });
        assertEq(art.balanceOf(user) - userBalanceBefore, 75e6);
        assertEq(art.balanceOf(granter) - granterBalanceBefore, 25e6);
    }

    function test_crossChainRewardPocketsSettleArrivalsIntoRewards() public {
        JBTokenDistributor distributor = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        JBStickyRewardPockets pockets = new JBStickyRewardPockets(IJBDistributor(address(distributor)));

        // Two streakers: 30 and 10 ART locked.
        _stake(user, user, 30e6);
        art.mint({to: granter, amount: 10e6});
        vm.startPrank(granter);
        art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal()
            .pay({
            projectId: projectId,
            token: address(art),
            amount: 10e6,
            beneficiary: granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);

        // A cross-chain arrival lands at the PREDICTED pocket address before the pocket exists — exactly how a
        // sucker claim would deliver bridged project tokens to a counterfactual beneficiary.
        address pocket = pockets.predictPocketOf(address(token));
        assertEq(pocket.code.length, 0);
        art.mint({to: pocket, amount: 100e6});

        // Anyone settles: the pocket is deployed at the predicted address and the arrival becomes a reward round.
        uint256 settled = pockets.settleFor({stickyToken: address(token), token: IERC20(address(art))});
        assertEq(settled, 100e6);
        assertEq(pockets.pocketOf(address(token)), pocket);
        assertEq(distributor.balanceOf(address(token), IERC20(address(art))), 100e6);

        // Settling again with nothing in the pocket is a harmless no-op.
        assertEq(pockets.settleFor({stickyToken: address(token), token: IERC20(address(art))}), 0);

        // The streakers collect their shares of the arrival like any other reward round.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = uint256(uint160(user));
        tokenIds[1] = uint256(uint160(granter));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(art));
        distributor.beginVesting({hook: address(token), tokenIds: tokenIds, tokens: tokens});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 userBalanceBefore = art.balanceOf(user);
        uint256[] memory userId = new uint256[](1);
        userId[0] = uint256(uint160(user));
        distributor.collectVestedRewards({hook: address(token), tokenIds: userId, tokens: tokens, beneficiary: user});
        assertEq(art.balanceOf(user) - userBalanceBefore, 75e6);
    }

    function test_donationsAccrueToRemainingStakers() public {
        _stake(user, user, 10e6);

        // A donation to the project's balance (without staking) raises the surplus above 1:1.
        art.mint({to: granter, amount: 10e6});
        vm.startPrank(granter);
        art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal()
            .addToBalanceOf({
            projectId: projectId,
            token: address(art),
            amount: 10e6,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();

        // The lone staker unwinds into the full surplus: 10 staked + 10 donated.
        uint256 reclaimed = _unstake(user, 10e18);
        assertEq(reclaimed, 20e6);
    }

    function test_grantsAutoAddTranchesWithoutTouchingTheStreak() public {
        uint256 start = vm.getBlockTimestamp();
        _stake(user, user, 10e6);
        vm.warp(start + 300 days);

        // A third party (e.g. the protocol granting rewards) stakes on the user's behalf: no user action needed.
        art.mint({to: granter, amount: 5e6});
        vm.startPrank(granter);
        art.approve({spender: address(jbMultiTerminal()), value: 5e6});
        vm.stopPrank();
        _stake(granter, user, 5e6);

        // The grant is its own tranche with its own timestamp — the streak isn't backdated or broken.
        JBStickyTranche[] memory tranches = hook.tranchesOf(projectId, user);
        assertEq(tranches.length, 2);
        assertEq(tranches[1].amount, 5e18);
        assertEq(tranches[1].timestamp, start + 300 days);
        assertEq(hook.streakStartOf(projectId, user), start);
    }

    function test_commitmentRewardTaxesLeaversAndRewardsStayers() public {
        // Deploy a second sticky project with a 50% commitment reward.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 rewardProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(art)),
            name: "Hard ART",
            symbol: "HARDART",
            projectUri: "",
            cashOutTaxRate: 5000,
            granters: new address[](0),
            soulbound: true
        });
        assertEq(deployer.cashOutTaxRateOf(rewardProjectId), 5000);

        // Two equal stakers.
        art.mint({to: granter, amount: 10e6});
        vm.startPrank(granter);
        art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal()
            .pay({
            projectId: rewardProjectId,
            token: address(art),
            amount: 10e6,
            beneficiary: granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.prank(user);
        jbMultiTerminal()
            .pay({
            projectId: rewardProjectId,
            token: address(art),
            amount: 10e6,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });

        // The leaver's reclaim follows the bonding curve — proportional 10, taxed to 7.5 — minus the 2.5% protocol
        // fee that applies to taxed cash outs.
        vm.prank(user);
        uint256 leaverReclaim = jbMultiTerminal()
            .cashOutTokensOf({
            holder: user,
            projectId: rewardProjectId,
            cashOutCount: 10e18,
            tokenToReclaim: address(art),
            minTokensReclaimed: 0,
            beneficiary: payable(user),
            metadata: bytes("")
        });
        assertEq(leaverReclaim, 7_312_500); // 7.5 ART * 0.975

        // The stayer's eventual unwind collects more than they put in: the leaver's forfeited share stayed behind.
        vm.prank(granter);
        uint256 stayerReclaim = jbMultiTerminal()
            .cashOutTokensOf({
            holder: granter,
            projectId: rewardProjectId,
            cashOutCount: 10e18,
            tokenToReclaim: address(art),
            minTokensReclaimed: 0,
            beneficiary: payable(granter),
            metadata: bytes("")
        });
        assertGt(stayerReclaim, 10e6);
    }

    function test_stakeUnstakeRoundTrip() public {
        uint256 start = vm.getBlockTimestamp();

        // Staking 10 ART (6 decimals) mints 10 sART (18 decimals), 1:1.
        uint256 minted = _stake(user, user, 10e6);
        assertEq(minted, 10e18);
        assertEq(jbTokens().totalBalanceOf(user, projectId), 10e18);
        assertEq(hook.stakedBalanceOf(projectId, user), 10e18);
        assertEq(hook.streakStartOf(projectId, user), start);

        // Stake 5 more a month later: a second tranche, same streak.
        vm.warp(start + 30 days);
        _stake(user, user, 5e6);
        assertEq(hook.trancheCountOf(projectId, user), 2);
        assertEq(hook.streakStartOf(projectId, user), start);

        // Unstake 7: LIFO consumes the newest tranche (5) and splits the oldest down to 8, keeping its timestamp.
        vm.warp(start + 40 days);
        uint256 reclaimed = _unstake(user, 7e18);
        assertEq(reclaimed, 7e6);
        assertEq(art.balanceOf(user), 100e6 - 15e6 + 7e6);
        JBStickyTranche[] memory tranches = hook.tranchesOf(projectId, user);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 8e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(hook.currentStreakOf(projectId, user), 40 days);

        // Unstake the rest: all ART returned 1:1, streak ends, longest streak recorded.
        reclaimed = _unstake(user, 8e18);
        assertEq(reclaimed, 8e6);
        assertEq(art.balanceOf(user), 100e6);
        assertEq(hook.stakedBalanceOf(projectId, user), 0);
        assertEq(hook.currentStreakOf(projectId, user), 0);
        assertEq(hook.longestStreakOf(projectId, user), 40 days);
    }

    function test_transferableModeMovesAccountingAndRestartsClock() public {
        // Deploy a transferable sticky project.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 openProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(art)),
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
        vm.prank(user);
        jbMultiTerminal()
            .pay({
            projectId: openProjectId,
            token: address(art),
            amount: 10e6,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.warp(start + 30 days);
        vm.prank(user);
        jbMultiTerminal()
            .pay({
            projectId: openProjectId,
            token: address(art),
            amount: 5e6,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });

        // Transferring 7 restarts the clock on the moved tokens: the sender's newest tranches are consumed (the
        // oldest keeps its timestamp) and the receiver's streak starts now.
        vm.prank(user);
        IERC20(address(openToken)).transfer({to: granter, value: 7e18});

        JBStickyTranche[] memory senderTranches = hook.tranchesOf(openProjectId, user);
        assertEq(senderTranches.length, 1);
        assertEq(senderTranches[0].amount, 8e18);
        assertEq(senderTranches[0].timestamp, start);
        assertEq(hook.streakStartOf(openProjectId, user), start);

        JBStickyTranche[] memory receiverTranches = hook.tranchesOf(openProjectId, granter);
        assertEq(receiverTranches.length, 1);
        assertEq(receiverTranches[0].amount, 7e18);
        assertEq(receiverTranches[0].timestamp, start + 30 days);
        assertEq(hook.streakStartOf(openProjectId, granter), start + 30 days);

        // The receiver can unwind what they received.
        vm.prank(granter);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
            holder: granter,
            projectId: openProjectId,
            cashOutCount: 7e18,
            tokenToReclaim: address(art),
            minTokensReclaimed: 0,
            beneficiary: payable(granter),
            metadata: bytes("")
        });
        assertEq(reclaimed, 7e6);
    }

    // Deploy a sticky-tuned distributor and an auto-stick adapter, stake 30/10 for user/granter, and fund
    // 100 ART of rewards so the user's fully-vested share is 75 ART.
    function _autoStickFixture() internal returns (JBTokenDistributor distributor, JBStickyAutoStick adapter) {
        distributor = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        adapter = new JBStickyAutoStick({deployer: deployer, distributor: IJBDistributor(address(distributor))});

        _stake(user, user, 30e6);
        art.mint({to: granter, amount: 10e6});
        vm.startPrank(granter);
        art.approve({spender: address(jbMultiTerminal()), value: 10e6});
        jbMultiTerminal()
            .pay({
            projectId: projectId,
            token: address(art),
            amount: 10e6,
            beneficiary: granter,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(block.number + 1);

        address funder = makeAddr("funder");
        art.mint({to: funder, amount: 100e6});
        vm.startPrank(funder);
        art.approve({spender: address(distributor), value: 100e6});
        distributor.fund({hook: address(token), token: IERC20(address(art)), amount: 100e6});
        vm.stopPrank();
    }

    // The holder's three-step opt-in: allowance, hook trust, config — config enabled last.
    function _enableAutoStick(JBStickyAutoStick adapter, uint128 minimumAmount, uint48 cooldown) internal {
        vm.startPrank(user);
        art.approve({spender: address(adapter), value: type(uint256).max});
        hook.setTrustedSenderFor({projectId: projectId, sender: address(adapter), trusted: true});
        adapter.setConfigFor({projectId: projectId, enabled: true, minimumAmount: minimumAmount, cooldown: cooldown});
        vm.stopPrank();
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
        adapter.beginVestingFor({projectId: projectId, holder: user});

        // Once fully vested, the keeper compounds: the user's 75 ART share is collected, pulled, and restuck.
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);
        (JBAutoStickStatus status,,,) = adapter.statusOf(projectId, user);
        assertEq(uint256(status), uint256(JBAutoStickStatus.READY));
        uint256 walletBefore = art.balanceOf(user);
        vm.prank(keeper);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.compoundFor({projectId: projectId, holder: user});
        assertEq(underlyingAmount, 75e6);
        assertEq(stickyTokenCount, 75e18);

        // The reward passed through the user's wallet and ended up staked — a fresh tranche at the compound
        // timestamp, with the original streak untouched.
        assertEq(art.balanceOf(user), walletBefore);
        assertEq(hook.stakedBalanceOf(projectId, user), 105e18);
        JBStickyTranche[] memory tranches = hook.tranchesOf(projectId, user);
        assertEq(tranches.length, 2);
        assertEq(tranches[1].amount, 75e18);
        assertEq(tranches[1].timestamp, vm.getBlockTimestamp());
        assertEq(hook.streakStartOf(projectId, user), start);

        // No custody left behind, and the cooldown now gates the next compound.
        assertEq(art.balanceOf(address(adapter)), 0);
        (JBAutoStickStatus afterStatus,,, uint256 nextCompoundAt) = adapter.statusOf(projectId, user);
        assertEq(uint256(afterStatus), uint256(JBAutoStickStatus.COOLDOWN));
        assertEq(nextCompoundAt, vm.getBlockTimestamp() + 1 days);
    }

    function test_autoStickAfterFullUnstickRestartsPosition() public {
        (, JBStickyAutoStick adapter) = _autoStickFixture();
        _enableAutoStick(adapter, 1e6, 1 days);

        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        adapter.beginVestingFor({projectId: projectId, holder: user});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);

        // The user fully unsticks but leaves auto-stick enabled — a later compound reopens the position with a
        // fresh streak. This is why the UI's full-exit flow must disable auto-stick first.
        _unstake(user, 30e18);
        assertEq(hook.stakedBalanceOf(projectId, user), 0);
        uint256 restart = vm.getBlockTimestamp();
        adapter.compoundFor({projectId: projectId, holder: user});
        assertEq(hook.stakedBalanceOf(projectId, user), 75e18);
        assertEq(hook.streakStartOf(projectId, user), restart);
    }

    function test_autoStickGranterProjectSkipsPerHolderTrust() public {
        (JBTokenDistributor distributor, JBStickyAutoStick adapter) = _autoStickFixture();

        // A creator launches a project with the adapter pre-approved as a granter.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 granterProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(art)),
            name: "Granter ART",
            symbol: "GRANTART",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: _granters(address(adapter)),
            soulbound: true
        });
        IJBToken granterToken = jbTokens().tokenOf(granterProjectId);

        // The holder stakes and enables auto-stick WITHOUT a trust tx: just allowance + config.
        art.mint({to: user, amount: 20e6});
        vm.startPrank(user);
        jbMultiTerminal()
            .pay({
            projectId: granterProjectId,
            token: address(art),
            amount: 20e6,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        art.approve({spender: address(adapter), value: type(uint256).max});
        adapter.setConfigFor({projectId: granterProjectId, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);

        // Move to a fresh round so its snapshot lands after the holder's stake (the fixture's earlier funding
        // already pinned the current round's snapshot).
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);

        // Fund, roll the round, vest, and compound — the hook accepts the adapter through granter status.
        address funder = makeAddr("granter-funder");
        art.mint({to: funder, amount: 40e6});
        vm.startPrank(funder);
        art.approve({spender: address(distributor), value: 40e6});
        distributor.fund({hook: address(granterToken), token: IERC20(address(art)), amount: 40e6});
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        adapter.beginVestingFor({projectId: granterProjectId, holder: user});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);
        assertFalse(hook.isTrustedSenderOf(granterProjectId, user, address(adapter)));
        (uint256 underlyingAmount,) = adapter.compoundFor({projectId: granterProjectId, holder: user});
        assertEq(underlyingAmount, 40e6);
        assertEq(hook.stakedBalanceOf(granterProjectId, user), 60e18);
    }

    function test_oneClickClaimAndStickNeedsNoConfig() public {
        (JBTokenDistributor distributor, JBStickyAutoStick adapter) = _autoStickFixture();

        // The holder trusts the adapter and grants an allowance — but never touches setConfigFor.
        vm.startPrank(user);
        hook.setTrustedSenderFor({projectId: projectId, sender: address(adapter), trusted: true});
        art.approve({spender: address(adapter), value: type(uint256).max});
        vm.stopPrank();

        // Vesting starts permissionlessly on the distributor itself; no adapter config is required.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(user));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(art));
        distributor.beginVesting({hook: address(token), tokenIds: tokenIds, tokens: tokens});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);

        // One click: the claim sticks atomically, straight into a fresh tranche.
        vm.prank(user);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.stickRewardsFor(projectId);
        assertEq(underlyingAmount, 75e6);
        assertEq(stickyTokenCount, 75e18);
        assertEq(hook.stakedBalanceOf(projectId, user), 105e18);
        (,,, bool enabled) = adapter.configOf(projectId, user);
        assertFalse(enabled);
    }

    function test_autoStickRevokingAnyLegBlocksCompound() public {
        (, JBStickyAutoStick adapter) = _autoStickFixture();
        _enableAutoStick(adapter, 1e6, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        adapter.beginVestingFor({projectId: projectId, holder: user});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.roll(vm.getBlockNumber() + 1);

        // Revoking hook trust alone blocks the compound.
        vm.prank(user);
        hook.setTrustedSenderFor({projectId: projectId, sender: address(adapter), trusted: false});
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector, projectId, user)
        );
        adapter.compoundFor({projectId: projectId, holder: user});

        // Restoring trust but revoking the allowance alone blocks it too.
        vm.startPrank(user);
        hook.setTrustedSenderFor({projectId: projectId, sender: address(adapter), trusted: true});
        art.approve({spender: address(adapter), value: 0});
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InsufficientAllowance.selector, 0, 75e6)
        );
        adapter.compoundFor({projectId: projectId, holder: user});

        // Restoring the allowance but disabling the config alone blocks it as well; re-enabling compounds.
        vm.startPrank(user);
        art.approve({spender: address(adapter), value: type(uint256).max});
        adapter.setConfigFor({projectId: projectId, enabled: false, minimumAmount: 1e6, cooldown: 1 days});
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Disabled.selector, projectId, user)
        );
        adapter.compoundFor({projectId: projectId, holder: user});

        vm.prank(user);
        adapter.setConfigFor({projectId: projectId, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
        (uint256 underlyingAmount,) = adapter.compoundFor({projectId: projectId, holder: user});
        assertEq(underlyingAmount, 75e6);
    }

    function test_tokenIsSoulbound() public {
        _stake(user, user, 10e6);

        // Stakes mint the soulbound ERC-20 directly, and it can't be transferred.
        assertEq(token.balanceOf(user), 10e18);
        vm.prank(user);
        vm.expectRevert(JBStickyToken.JBStickyToken_Soulbound.selector);
        IERC20(address(token)).transfer({to: granter, value: 1e18});

        // The soulbound tokens can still be unstaked.
        uint256 reclaimed = _unstake(user, 10e18);
        assertEq(reclaimed, 10e6);
    }

    //*********************************************************************//
    // --------------------- criteria pot integration --------------------- //
    //*********************************************************************//

    /// @notice Mint, approve, and stake `amount` of ART for a fresh holder.
    function _stakeArt(address holder, uint256 amount) internal {
        art.mint({to: holder, amount: amount});
        vm.prank(holder);
        art.approve({spender: address(jbMultiTerminal()), value: amount});
        _stake(holder, holder, amount);
    }

    /// @notice Directly fund a criteria group's ART pot for `hookAddr`, matching `JBStickyDistributor.fund`.
    function _fundArtGroup(JBStickyDistributor distributor_, address hookAddr, uint256 amount, uint256 groupId) internal {
        address funder = makeAddr("criteria-funder");
        art.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        art.approve({spender: address(distributor_), value: amount});
        distributor_.fund({hook: hookAddr, token: IERC20(address(art)), amount: amount, groupId: groupId});
        vm.stopPrank();
    }

    /// @notice Fund a criteria group's pot for `hookAddr` through a payout split, pranking the registered terminal
    /// as the caller — the same pattern the unit tests use for `processSplitWith`.
    function _fundGroupViaSplit(
        JBStickyDistributor distributor_,
        address hookAddr,
        MockRwd token_,
        uint256 amount,
        uint48 lockedUntil
    )
        internal
    {
        address terminal = address(jbMultiTerminal());
        token_.mint({to: terminal, amount: amount});
        vm.startPrank(terminal);
        token_.approve({spender: address(distributor_), value: amount});
        distributor_.processSplitWith(
            JBSplitHookContext({
                token: address(token_),
                amount: amount,
                decimals: 18,
                projectId: projectId,
                groupId: uint256(uint160(address(token_))),
                split: JBSplit({
                    percent: 0,
                    projectId: 0,
                    beneficiary: payable(hookAddr),
                    preferAddToBalance: false,
                    lockedUntil: lockedUntil,
                    hook: IJBSplitHook(address(distributor_))
                })
            })
        );
        vm.stopPrank();
    }

    /// @notice Begin vesting `holder`'s unclaimed rewards in a specific criteria group and reward token.
    function _beginVestingGroupFor(
        JBStickyDistributor distributor_,
        address hookAddr,
        address holder,
        uint256 groupId,
        IERC20 token_
    )
        internal
    {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = token_;
        distributor_.beginVesting({hook: hookAddr, groupId: groupId, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Collect everything unlocked for `holder` in a specific criteria group and reward token.
    function _collectGroupFor(
        JBStickyDistributor distributor_,
        address hookAddr,
        address holder,
        uint256 groupId,
        IERC20 token_
    )
        internal
        returns (uint256 collected)
    {
        uint256 balanceBefore = token_.balanceOf(holder);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = token_;
        distributor_.collectVestedRewards({
            hook: hookAddr, groupId: groupId, tokenIds: tokenIds, tokens: tokens, beneficiary: holder
        });
        collected = token_.balanceOf(holder) - balanceBefore;
    }

    function test_integration_criteriaPotEndToEnd() public {
        address alice = makeAddr("criteria-alice");
        address bob = makeAddr("criteria-bob");
        address carol = makeAddr("criteria-carol");

        // Deploy the distributor the way the deploy scripts do: directory + the project's sticky hook, no
        // controller/revLoans/revOwner wiring.
        JBStickyDistributor distributor = new JBStickyDistributor({
            directory: jbDirectory(),
            stickyHook: hook,
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        MockRwd reward2 = new MockRwd();

        // Wiring sanity check: an out-of-range criteria group reverts through the real deploy-shaped distributor.
        // The full boundary sweep (521 and 1 << 240) is covered at the unit level.
        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidCriteria.selector, 521));
        distributor.fund({hook: address(token), token: IERC20(address(art)), amount: 1e6, groupId: 521});

        // Two holders stake a week apart.
        vm.warp(10 weeks + 1);
        _stakeArt(alice, 100e6);
        vm.warp(13 weeks + 1);
        _stakeArt(bob, 100e6);
        vm.warp(14 weeks + 1);

        // Fund a k = 2 ("stuck >= 2 weeks") pot through both entry paths: a direct fund in ART, and a payout split
        // carrying lockedUntil = 2 in a second reward token.
        _fundArtGroup(distributor, address(token), 90e6, 2);
        _fundGroupViaSplit(distributor, address(token), reward2, 60e18, 2);

        // Complete the funding round and fully vest.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _beginVestingGroupFor(distributor, address(token), alice, 2, IERC20(address(art)));
        _beginVestingGroupFor(distributor, address(token), bob, 2, IERC20(address(art)));
        _beginVestingGroupFor(distributor, address(token), alice, 2, IERC20(address(reward2)));
        _beginVestingGroupFor(distributor, address(token), bob, 2, IERC20(address(reward2)));
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // Bob's tranche is one week too fresh for k = 2 at the funding snapshot: he carries no aged weight in
        // either pot, and alice — the only aged staker — claims each pot in full.
        assertEq(_collectGroupFor(distributor, address(token), alice, 2, IERC20(address(art))), 90e6);
        assertEq(_collectGroupFor(distributor, address(token), bob, 2, IERC20(address(art))), 0);
        assertEq(_collectGroupFor(distributor, address(token), alice, 2, IERC20(address(reward2))), 60e18);
        assertEq(_collectGroupFor(distributor, address(token), bob, 2, IERC20(address(reward2))), 0);

        // A later ART pot: bob has now aged into the criteria too, so he shares it with alice — but carol, who
        // stakes right as this round is funded, is still too fresh to count.
        vm.warp(60 weeks + 1);
        _stakeArt(carol, 100e6);
        _fundArtGroup(distributor, address(token), 200e6, 2);
        uint256 expiredRound = distributor.currentRound();

        // Complete the round so the funded round becomes claimable, then only alice claims before the round's
        // claim window closes; bob's half is left to expire.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _beginVestingGroupFor(distributor, address(token), alice, 2, IERC20(address(art)));

        // Past the claim deadline, carol's tranche has aged into the criteria too — recycling re-walks the
        // denominator at the CURRENT epoch and buckets rather than reusing the expired round's stale total.
        vm.warp(vm.getBlockTimestamp() + 40 days);
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = expiredRound;
        uint256 recycled = distributor.recycleExpiredRewards({
            hook: address(token), groupId: 2, token: IERC20(address(art)), rounds: rounds
        });
        assertEq(recycled, 100e6);

        (uint208 freshAmount,,,, uint208 freshTotalStake,) =
            distributor.rewardRoundOf(address(token), 2, IERC20(address(art)), distributor.currentRound());
        assertEq(freshAmount, 100e6);
        assertEq(freshTotalStake, 300e18);
    }
}
