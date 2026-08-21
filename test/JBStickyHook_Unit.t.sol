// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {JBStickyHook} from "../src/JBStickyHook.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

contract JBStickyHookUnitTest is Test {
    uint256 constant PROJECT_ID = 7;

    address deployer = makeAddr("deployer");
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    address terminal = makeAddr("terminal");
    address holder = makeAddr("holder");
    address payer = makeAddr("payer");

    JBStickyHook hook;

    function setUp() public {
        hook = new JBStickyHook({directory: directory, deployer: deployer});

        // The terminal is a terminal of the project; other addresses aren't.
        vm.mockCall({
            callee: address(directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (PROJECT_ID, IJBTerminal(terminal))),
            returnData: abi.encode(true)
        });
    }

    //*********************************************************************//
    // ------------------------------ helpers ---------------------------- //
    //*********************************************************************//

    function _pay(address beneficiary, uint256 count) internal {
        vm.prank(terminal);
        hook.afterPayRecordedWith(
            JBAfterPayRecordedContext({
                payer: payer,
                projectId: PROJECT_ID,
                rulesetId: 1,
                amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: count}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                weight: 1e18,
                newlyIssuedTokenCount: count,
                beneficiary: beneficiary,
                hookMetadata: bytes(""),
                payerMetadata: bytes("")
            })
        );
    }

    function _cashOut(address account, uint256 count) internal {
        vm.prank(terminal);
        hook.afterCashOutRecordedWith(
            JBAfterCashOutRecordedContext({
                holder: account,
                projectId: PROJECT_ID,
                rulesetId: 1,
                cashOutCount: count,
                reclaimedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: count}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                cashOutTaxRate: 0,
                beneficiary: payable(account),
                hookMetadata: bytes(""),
                cashOutMetadata: bytes("")
            })
        );
    }

    //*********************************************************************//
    // ------------------------------- tests ----------------------------- //
    //*********************************************************************//

    function test_afterCashOut_endsStreakAtZeroAndTracksLongest() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(holder, 10e18);
        vm.warp(start + 40 days);
        _cashOut(holder, 10e18);

        assertEq(hook.stakedBalanceOf(PROJECT_ID, holder), 0);
        assertEq(hook.trancheCountOf(PROJECT_ID, holder), 0);
        assertEq(hook.streakStartOf(PROJECT_ID, holder), 0);
        assertEq(hook.currentStreakOf(PROJECT_ID, holder), 0);
        assertEq(hook.longestStreakOf(PROJECT_ID, holder), 40 days);

        // Restaking starts a fresh streak; the longest completed streak is retained until beaten.
        _pay(holder, 1e18);
        vm.warp(start + 50 days);
        assertEq(hook.currentStreakOf(PROJECT_ID, holder), 10 days);
        assertEq(hook.longestStreakOf(PROJECT_ID, holder), 40 days);

        // Once the active streak outlasts the longest completed one, it becomes the longest.
        vm.warp(start + 100 days);
        assertEq(hook.longestStreakOf(PROJECT_ID, holder), 60 days);
    }

    function test_afterCashOut_lifoSplitsNewestTrancheAndKeepsTimestamp() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(holder, 10e18);
        vm.warp(start + 30 days);
        _pay(holder, 5e18);
        vm.warp(start + 40 days);

        // Unstaking 7 consumes the newest tranche (5) fully and splits 2 out of the oldest.
        _cashOut(holder, 7e18);

        JBStickyTranche[] memory tranches = hook.tranchesOf(PROJECT_ID, holder);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 8e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(hook.stakedBalanceOf(PROJECT_ID, holder), 8e18);

        // A partial unstake doesn't touch the streak.
        assertEq(hook.streakStartOf(PROJECT_ID, holder), start);
        assertEq(hook.currentStreakOf(PROJECT_ID, holder), 40 days);
    }

    function test_afterCashOut_revertsWhenCallerIsNotTerminal() public {
        vm.mockCall({
            callee: address(directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (PROJECT_ID, IJBTerminal(address(this)))),
            returnData: abi.encode(false)
        });
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_CallerNotTerminal.selector, address(this)));
        hook.afterCashOutRecordedWith(
            JBAfterCashOutRecordedContext({
                holder: holder,
                projectId: PROJECT_ID,
                rulesetId: 1,
                cashOutCount: 1,
                reclaimedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 1}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                cashOutTaxRate: 0,
                beneficiary: payable(holder),
                hookMetadata: bytes(""),
                cashOutMetadata: bytes("")
            })
        );
    }

    function test_afterCashOut_spansMultipleTranches() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(holder, 4e18);
        vm.warp(start + 1 days);
        _pay(holder, 3e18);
        vm.warp(start + 2 days);
        _pay(holder, 2e18);

        // Unstaking 6 consumes the two newest tranches (2 + 3) and splits 1 out of the oldest.
        _cashOut(holder, 6e18);

        JBStickyTranche[] memory tranches = hook.tranchesOf(PROJECT_ID, holder);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 3e18);
        assertEq(tranches[0].timestamp, start);
    }

    function test_afterPay_recordsTranchesAndStartsStreakOnce() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(holder, 10e18);

        assertEq(hook.stakedBalanceOf(PROJECT_ID, holder), 10e18);
        assertEq(hook.streakStartOf(PROJECT_ID, holder), start);

        // A second stake adds a tranche with its own timestamp without moving the streak's start.
        vm.warp(start + 30 days);
        _pay(holder, 5e18);

        JBStickyTranche[] memory tranches = hook.tranchesOf(PROJECT_ID, holder);
        assertEq(tranches.length, 2);
        assertEq(tranches[0].amount, 10e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(tranches[1].amount, 5e18);
        assertEq(tranches[1].timestamp, start + 30 days);
        assertEq(hook.stakedBalanceOf(PROJECT_ID, holder), 15e18);
        assertEq(hook.streakStartOf(PROJECT_ID, holder), start);
        assertEq(hook.currentStreakOf(PROJECT_ID, holder), 30 days);
    }

    function test_afterPay_revertsWhenCallerIsNotTerminal() public {
        vm.mockCall({
            callee: address(directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (PROJECT_ID, IJBTerminal(address(this)))),
            returnData: abi.encode(false)
        });
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_CallerNotTerminal.selector, address(this)));
        hook.afterPayRecordedWith(
            JBAfterPayRecordedContext({
                payer: payer,
                projectId: PROJECT_ID,
                rulesetId: 1,
                amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 1}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                weight: 1e18,
                newlyIssuedTokenCount: 1,
                beneficiary: holder,
                hookMetadata: bytes(""),
                payerMetadata: bytes("")
            })
        );
    }

    function test_beforeCashOut_passesContextThroughAndRequestsCallback() public view {
        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory specifications
        ) = hook.beforeCashOutRecordedWith(
            JBBeforeCashOutRecordedContext({
                terminal: terminal,
                holder: holder,
                projectId: PROJECT_ID,
                rulesetId: 1,
                cashOutCount: 5e18,
                totalSupply: 100e18,
                surplus: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 100e18}),
                scopeCashOutsToLocalBalances: false,
                cashOutTaxRate: 0,
                beneficiaryIsFeeless: false,
                metadata: bytes("")
            })
        );

        assertEq(cashOutTaxRate, 0);
        assertEq(effectiveCashOutCount, 5e18);
        assertEq(effectiveTotalSupply, 100e18);
        assertEq(effectiveSurplusValue, 100e18);
        assertEq(specifications.length, 1);
        assertEq(address(specifications[0].hook), address(hook));
        assertEq(specifications[0].noop, false);
        assertEq(specifications[0].amount, 0);
    }

    function test_beforePay_passesWeightThroughAndRequestsCallback() public view {
        (uint256 weight, JBPayHookSpecification[] memory specifications) =
            hook.beforePayRecordedWith(_beforePayContext(1e18));
        assertEq(weight, 1e18);
        assertEq(specifications.length, 1);
        assertEq(address(specifications[0].hook), address(hook));
        assertEq(specifications[0].noop, false);
        assertEq(specifications[0].amount, 0);
    }

    function test_beforePay_gatesThirdPartyStakes() public {
        // A stranger can't stake to someone else's position.
        JBBeforePayRecordedContext memory context = _beforePayContext(1e18);
        context.payer = payer;
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_SenderNotTrusted.selector, payer, holder));
        hook.beforePayRecordedWith(context);

        // A project granter can.
        address[] memory granters = new address[](1);
        granters[0] = payer;
        vm.prank(deployer);
        hook.setGrantersFor({projectId: PROJECT_ID, granters: granters});
        hook.beforePayRecordedWith(context);

        // A holder-trusted sender can, until untrusted.
        address friend = makeAddr("friend");
        context.payer = friend;
        vm.prank(holder);
        hook.setTrustedSenderFor({projectId: PROJECT_ID, sender: friend, trusted: true});
        hook.beforePayRecordedWith(context);
        vm.prank(holder);
        hook.setTrustedSenderFor({projectId: PROJECT_ID, sender: friend, trusted: false});
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_SenderNotTrusted.selector, friend, holder));
        hook.beforePayRecordedWith(context);
    }

    function test_setGranters_revertsWhenCallerIsNotDeployer() public {
        address[] memory granters = new address[](1);
        granters[0] = payer;
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_Unauthorized.selector, address(this), deployer)
        );
        hook.setGrantersFor({projectId: PROJECT_ID, granters: granters});
    }

    function test_hasMintPermissionFor_isAlwaysFalse() public view {
        JBRuleset memory ruleset;
        assertEq(hook.hasMintPermissionFor(PROJECT_ID, ruleset, holder), false);
    }

    function test_bucketsTrackStakeByEpoch() public {
        vm.warp(10 weeks + 1);
        _pay(holder, 100e18);
        assertEq(hook.netStakedIn(PROJECT_ID, 10), 100e18);
        assertEq(hook.firstStakeEpochPlusOneOf(PROJECT_ID), 11);

        vm.warp(12 weeks + 1);
        _pay(holder, 50e18);
        assertEq(hook.netStakedIn(PROJECT_ID, 12), 50e18);
        // First-stake marker doesn't move.
        assertEq(hook.firstStakeEpochPlusOneOf(PROJECT_ID), 11);
    }

    function test_bucketsDecrementByConsumedTrancheEpoch() public {
        vm.warp(10 weeks + 1);
        _pay(holder, 100e18);
        vm.warp(12 weeks + 1);
        _pay(holder, 50e18);

        // Unstake 120: LIFO consumes the epoch-12 tranche fully (50) and 70 of the epoch-10 tranche.
        _cashOut(holder, 120e18);
        assertEq(hook.netStakedIn(PROJECT_ID, 12), 0);
        assertEq(hook.netStakedIn(PROJECT_ID, 10), 30e18);
    }

    function test_bucketConservation() public {
        address holder2 = makeAddr("holder2");

        vm.warp(10 weeks + 1);
        _pay(holder, 100e18);
        vm.warp(11 weeks + 1);
        _pay(holder2, 40e18);
        _cashOut(holder, 25e18);
        assertEq(
            hook.netStakedIn(PROJECT_ID, 10) + hook.netStakedIn(PROJECT_ID, 11),
            hook.stakedBalanceOf(PROJECT_ID, holder) + hook.stakedBalanceOf(PROJECT_ID, holder2)
        );
    }

    function test_netStakedInEpochsRange() public {
        vm.warp(10 weeks + 1);
        _pay(holder, 100e18);
        vm.warp(12 weeks + 1);
        _pay(holder, 50e18);

        uint256[] memory amounts = hook.netStakedInEpochs(PROJECT_ID, 10, 12);
        assertEq(amounts.length, 3);
        assertEq(amounts[0], 100e18);
        assertEq(amounts[1], 0);
        assertEq(amounts[2], 50e18);

        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_InvalidEpochRange.selector, 12, 10)
        );
        hook.netStakedInEpochs(PROJECT_ID, 12, 10);
    }

    function test_recordTransfer_zeroAmountCreatesNoTrancheAndStartsNoStreak() public {
        address token = makeAddr("token");
        vm.prank(deployer);
        hook.setTokenFor({projectId: PROJECT_ID, token: token});

        // Holder already has a position; a zero-value transfer must not touch it.
        _pay(holder, 10e18);
        uint256 streakStart = hook.streakStartOf(PROJECT_ID, holder);

        address receiver = makeAddr("receiver");
        vm.prank(token);
        hook.recordTransfer({projectId: PROJECT_ID, from: holder, to: receiver, amount: 0});

        // The sender's position is untouched.
        assertEq(hook.trancheCountOf(PROJECT_ID, holder), 1);
        assertEq(hook.stakedBalanceOf(PROJECT_ID, holder), 10e18);
        assertEq(hook.streakStartOf(PROJECT_ID, holder), streakStart);

        // The receiver gets nothing: no tranche, no streak, no balance.
        assertEq(hook.trancheCountOf(PROJECT_ID, receiver), 0);
        assertEq(hook.streakStartOf(PROJECT_ID, receiver), 0);
        assertEq(hook.stakedBalanceOf(PROJECT_ID, receiver), 0);
    }

    function _beforePayContext(uint256 value) internal view returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: terminal,
            payer: holder,
            amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: value}),
            projectId: PROJECT_ID,
            rulesetId: 1,
            beneficiary: holder,
            weight: 1e18,
            reservedPercent: 0,
            metadata: bytes("")
        });
    }
}
