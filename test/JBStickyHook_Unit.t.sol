// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {Test} from "forge-std/Test.sol";

import {JBStickyHook} from "../src/JBStickyHook.sol";

import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice The sticky hook's pay and cash-out callbacks against mocked directory, terminal, and token dependencies.
contract JBStickyHookUnitTest is Test {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID of the project the hook is registered for.
    uint256 internal constant _PROJECT_ID = 7;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The deployer allowed to register tokens and granters.
    address internal _deployer = makeAddr("deployer");

    /// @notice The mocked directory that decides which addresses are terminals.
    IJBDirectory internal _directory = IJBDirectory(makeAddr("directory"));

    /// @notice The holder whose position the tests track.
    address internal _holder = makeAddr("holder");

    /// @notice The hook under test.
    JBStickyHook internal _hook;

    /// @notice A third-party payer.
    address internal _payer = makeAddr("payer");

    /// @notice The total supply the mocked token reports.
    uint256 internal _reportedSupply;

    /// @notice The mocked terminal address the directory recognizes.
    address internal _terminal = makeAddr("terminal");

    /// @notice The mocked project token address.
    address internal _token = makeAddr("token");

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public {
        _hook = new JBStickyHook({directory: _directory, deployer: _deployer});
        vm.prank(_deployer);
        _hook.setTokenFor({projectId: _PROJECT_ID, token: _token});
        vm.mockCall({
            callee: _token, data: abi.encodeCall(IJBToken.totalSupply, ()), returnData: abi.encode(uint256(0))
        });
        vm.mockCall({
            callee: _terminal,
            data: abi.encodePacked(IJBTerminal.currentSurplusOf.selector),
            returnData: abi.encode(uint256(0))
        });

        // The terminal is a terminal of the project; other addresses aren't.
        vm.mockCall({
            callee: address(_directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (_PROJECT_ID, IJBTerminal(_terminal))),
            returnData: abi.encode(true)
        });
    }

    function test_afterCashOut_endsStreakAtZeroAndTracksLongest() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(_holder, 10e18);
        vm.warp(start + 40 days);
        _cashOut(_holder, 10e18);

        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _holder), 0);
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _holder), 0);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _holder), 0);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _holder), 0);
        assertEq(_hook.longestStreakOf(_PROJECT_ID, _holder), 40 days);

        // Restaking starts a fresh streak; the longest completed streak is retained until beaten.
        _pay(_holder, 1e18);
        vm.warp(start + 50 days);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _holder), 10 days);
        assertEq(_hook.longestStreakOf(_PROJECT_ID, _holder), 40 days);

        // Once the active streak outlasts the longest completed one, it becomes the longest.
        vm.warp(start + 100 days);
        assertEq(_hook.longestStreakOf(_PROJECT_ID, _holder), 60 days);
    }

    function test_afterCashOut_lifoSplitsNewestTrancheAndKeepsTimestamp() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(_holder, 10e18);
        vm.warp(start + 30 days);
        _pay(_holder, 5e18);
        vm.warp(start + 40 days);

        // Unstaking 7 consumes the newest tranche (5) fully and splits 2 out of the oldest.
        _cashOut(_holder, 7e18);

        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _holder);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 8e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _holder), 8e18);

        // A partial unstake doesn't touch the streak.
        assertEq(_hook.streakStartOf(_PROJECT_ID, _holder), start);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _holder), 40 days);
    }

    function test_afterCashOut_revertsWhenCallerIsNotTerminal() public {
        vm.mockCall({
            callee: address(_directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (_PROJECT_ID, IJBTerminal(address(this)))),
            returnData: abi.encode(false)
        });
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_CallerNotTerminal.selector, address(this)));
        _hook.afterCashOutRecordedWith(
            JBAfterCashOutRecordedContext({
                holder: _holder,
                projectId: _PROJECT_ID,
                rulesetId: 1,
                cashOutCount: 1,
                reclaimedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 1}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                cashOutTaxRate: 0,
                beneficiary: payable(_holder),
                hookMetadata: bytes(""),
                cashOutMetadata: bytes("")
            })
        );
    }

    function test_afterCashOut_spansMultipleTranches() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(_holder, 4e18);
        vm.warp(start + 1 weeks);
        _pay(_holder, 3e18);
        vm.warp(start + 2 weeks);
        _pay(_holder, 2e18);

        // Unstaking 6 consumes the two newest tranches (2 + 3) and splits 1 out of the oldest.
        _cashOut(_holder, 6e18);

        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _holder);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 3e18);
        assertEq(tranches[0].timestamp, start);
    }

    function test_afterPay_recordsTranchesAndStartsStreakOnce() public {
        uint256 start = vm.getBlockTimestamp();
        _pay(_holder, 10e18);

        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _holder), 10e18);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _holder), start);

        // A second stake adds a tranche with its own timestamp without moving the streak's start.
        vm.warp(start + 30 days);
        _pay(_holder, 5e18);

        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _holder);
        assertEq(tranches.length, 2);
        assertEq(tranches[0].amount, 10e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(tranches[1].amount, 5e18);
        assertEq(tranches[1].timestamp, start + 30 days);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _holder), 15e18);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _holder), start);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _holder), 30 days);
    }

    function test_afterPay_revertsWhenCallerIsNotTerminal() public {
        vm.mockCall({
            callee: address(_directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (_PROJECT_ID, IJBTerminal(address(this)))),
            returnData: abi.encode(false)
        });
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_CallerNotTerminal.selector, address(this)));
        _hook.afterPayRecordedWith(
            JBAfterPayRecordedContext({
                payer: _payer,
                projectId: _PROJECT_ID,
                rulesetId: 1,
                amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 1}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                weight: 1e18,
                newlyIssuedTokenCount: 1,
                beneficiary: _holder,
                hookMetadata: abi.encode(uint256(0)),
                payerMetadata: bytes("")
            })
        );
    }

    function test_beforePay_gatesThirdPartyStakes() public {
        // A stranger can't stake to someone else's position.
        JBBeforePayRecordedContext memory context = _beforePayContext(1e18);
        context.payer = _payer;
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_SenderNotTrusted.selector, _payer, _holder));
        _hook.beforePayRecordedWith(context);

        // A project granter can.
        address[] memory granters = new address[](1);
        granters[0] = _payer;
        vm.prank(_deployer);
        _hook.setGrantersFor({projectId: _PROJECT_ID, granters: granters});
        _hook.beforePayRecordedWith(context);

        // A holder-trusted sender can, until untrusted.
        address friend = makeAddr("friend");
        context.payer = friend;
        vm.prank(_holder);
        _hook.setTrustedSenderFor({projectId: _PROJECT_ID, sender: friend, trusted: true});
        _hook.beforePayRecordedWith(context);
        vm.prank(_holder);
        _hook.setTrustedSenderFor({projectId: _PROJECT_ID, sender: friend, trusted: false});
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_SenderNotTrusted.selector, friend, _holder));
        _hook.beforePayRecordedWith(context);
    }

    function test_setGranters_revertsWhenCallerIsNotDeployer() public {
        address[] memory granters = new address[](1);
        granters[0] = _payer;
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_Unauthorized.selector, address(this), _deployer)
        );
        _hook.setGrantersFor({projectId: _PROJECT_ID, granters: granters});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function test_beforeCashOut_passesContextThroughWithoutDoubleAccountingCallback() public view {
        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory specifications
        ) = _hook.beforeCashOutRecordedWith(
            JBBeforeCashOutRecordedContext({
                terminal: _terminal,
                holder: _holder,
                projectId: _PROJECT_ID,
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
        assertEq(specifications.length, 0);
    }

    function test_beforePay_passesWeightThroughAndRequestsCallback() public view {
        (uint256 weight, JBPayHookSpecification[] memory specifications) =
            _hook.beforePayRecordedWith(_beforePayContext(1e18));
        assertEq(weight, 1e18);
        assertEq(specifications.length, 1);
        assertEq(address(specifications[0].hook), address(_hook));
        assertEq(specifications[0].noop, false);
        assertEq(specifications[0].amount, 0);
    }

    function test_hasMintPermissionFor_isAlwaysFalse() public view {
        JBRuleset memory ruleset;
        assertEq(_hook.hasMintPermissionFor(_PROJECT_ID, ruleset, _holder), false);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Reports a burn of `count` shares from `account` through the token, updating the mocked supply.
    /// @param account The holder whose shares are burned.
    /// @param count The number of shares burned.
    function _cashOut(address account, uint256 count) internal {
        // The token reports a burn before reducing its supply, so the hook reads the pre-burn total.
        vm.mockCall({
            callee: _token, data: abi.encodeCall(IJBToken.totalSupply, ()), returnData: abi.encode(_reportedSupply)
        });
        vm.prank(_token);
        _hook.recordBurn({projectId: _PROJECT_ID, holder: account, amount: count});
        _reportedSupply -= count;
        vm.mockCall({
            callee: _token, data: abi.encodeCall(IJBToken.totalSupply, ()), returnData: abi.encode(_reportedSupply)
        });
        vm.mockCall({
            callee: _terminal,
            data: abi.encodePacked(IJBTerminal.currentSurplusOf.selector),
            returnData: abi.encode(_reportedSupply)
        });
    }

    /// @notice Records a payment of `count` shares to `beneficiary` through the terminal, raising the mocked supply
    /// and surplus to match.
    /// @param beneficiary The account receiving the shares.
    /// @param count The number of shares issued.
    function _pay(address beneficiary, uint256 count) internal {
        uint256 supplyBefore = _reportedSupply;
        _reportedSupply += count;
        vm.mockCall({
            callee: _token, data: abi.encodeCall(IJBToken.totalSupply, ()), returnData: abi.encode(_reportedSupply)
        });
        vm.mockCall({
            callee: _terminal,
            data: abi.encodePacked(IJBTerminal.currentSurplusOf.selector),
            returnData: abi.encode(_reportedSupply)
        });
        vm.prank(_terminal);
        _hook.afterPayRecordedWith(
            JBAfterPayRecordedContext({
                payer: _payer,
                projectId: _PROJECT_ID,
                rulesetId: 1,
                amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: count}),
                forwardedAmount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: 0}),
                weight: 1e18,
                newlyIssuedTokenCount: count,
                beneficiary: beneficiary,
                hookMetadata: abi.encode(supplyBefore, supplyBefore, uint256(0)),
                payerMetadata: bytes("")
            })
        );
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Builds a before-pay context for the holder paying themselves.
    /// @param value The payment's value.
    /// @return context The before-pay context.
    function _beforePayContext(uint256 value) internal view returns (JBBeforePayRecordedContext memory context) {
        return JBBeforePayRecordedContext({
            terminal: _terminal,
            payer: _holder,
            amount: JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: value}),
            projectId: _PROJECT_ID,
            rulesetId: 1,
            beneficiary: _holder,
            weight: 1e18,
            reservedPercent: 0,
            metadata: bytes("")
        });
    }
}
