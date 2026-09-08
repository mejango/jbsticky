// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {JBStickyHook} from "../src/JBStickyHook.sol";
import {JBStickyToken} from "../src/JBStickyToken.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice Regression and reference-model coverage for token-driven position accounting.
contract JBStickyAccountingTest is Test {
    uint256 internal constant _PROJECT_ID = 7;
    address internal _alice = makeAddr("alice");
    address internal _bob = makeAddr("bob");
    address internal _stranger = makeAddr("stranger");
    address internal _terminal = makeAddr("terminal");
    JBStickyHook internal _hook;
    JBStickyToken internal _token;
    mapping(address holder => JBStickyTranche[]) internal _modelTranches;
    mapping(address holder => uint256) internal _modelBalance;
    mapping(address holder => uint256) internal _modelStart;
    mapping(address holder => uint256) internal _modelLongest;

    function setUp() public {
        IJBDirectory directory = IJBDirectory(makeAddr("directory"));
        _hook = new JBStickyHook({directory: directory, deployer: address(this)});
        _token = new JBStickyToken({
            name: "Sticky",
            symbol: "STICKY",
            tokens: IJBTokens(address(this)),
            projectId: _PROJECT_ID,
            hook: _hook,
            soulbound: false
        });
        _hook.setTokenFor({projectId: _PROJECT_ID, token: address(_token)});
        vm.mockCall({
            callee: address(directory),
            data: abi.encodeCall(IJBDirectory.isTerminalOf, (_PROJECT_ID, IJBTerminal(_terminal))),
            returnData: abi.encode(true)
        });
    }

    function test_zeroTransferFromCannotStartOrBackdateStreak() public {
        vm.recordLogs();
        vm.prank(_stranger);
        _token.transferFrom({from: _alice, to: _alice, value: 0});
        vm.prank(_stranger);
        _token.transferFrom({from: _alice, to: _bob, value: 0});
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(_hook));
        }
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _bob), 0);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _bob), 0);
        assertEq(_token.delegates(_alice), address(0));
        assertEq(_token.delegates(_bob), address(0));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _mintAndRecord(_alice, 1e18);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _alice), 0);
    }

    function test_selfTransferDoesNotChangeAnyPositionOrTimestamp() public {
        _mintAndRecord(_alice, 10e18);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 days);
        vm.recordLogs();
        vm.prank(_alice);
        _token.transfer({to: _alice, value: 10e18});
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(_hook));
        }
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].timestamp, start);
        assertEq(tranches[0].amount, 10e18);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _alice), 30 days);
    }

    function test_burnConsumesExactlyOnceAndCallbackCannotConsumeAgain() public {
        _mintAndRecord(_alice, 10e18);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 days);
        _mintAndRecord(_alice, 5e18);
        _token.burn({account: _alice, amount: 7e18});
        _callback(_alice, 7e18);
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 8e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), _token.balanceOf(_alice));
        _token.burn({account: _alice, amount: 8e18});
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.longestStreakOf(_PROJECT_ID, _alice), 30 days);
    }

    function test_onlyRegisteredTokenCanReportBurnOrTransfer() public {
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_CallerNotToken.selector, address(this), address(_token))
        );
        _hook.recordBurn({projectId: _PROJECT_ID, holder: _alice, amount: 0});
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_CallerNotToken.selector, address(this), address(_token))
        );
        _hook.recordTransfer({projectId: _PROJECT_ID, from: _alice, to: _bob, amount: 0});
    }

    function test_pendingMintCannotTransferOrBurnAnOlderTrancheBeforePayHook() public {
        _mintAndRecord(_alice, 10e18);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 days);

        // The real terminal mints, calls the staked token's approve(0), then records the payment hook. A callback
        // during approve(0) must not move older tranches while the new mint is still absent from accounting.
        _token.mint({account: _alice, amount: 5e18});
        bytes memory expectedError =
            abi.encodeWithSelector(JBStickyToken.JBStickyToken_UnrecordedMint.selector, _alice, 15e18, 10e18);
        vm.expectRevert(expectedError);
        vm.prank(_alice);
        _token.transfer({to: _bob, value: 10e18});
        vm.expectRevert(expectedError);
        _token.burn({account: _alice, amount: 5e18});
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _alice), 30 days);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), 10e18);

        // Harmless zero and self movements remain no-ops during the gap.
        vm.prank(_alice);
        _token.transfer({to: _bob, value: 0});
        vm.prank(_alice);
        _token.transfer({to: _alice, value: 15e18});

        _recordMint(_alice, 5e18);
        vm.prank(_alice);
        _token.transfer({to: _bob, value: 10e18});
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 5e18);
        assertEq(tranches[0].timestamp, start);
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _alice), 30 days);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), _token.balanceOf(_alice));
        _token.burn({account: _alice, amount: 5e18});
        assertEq(_hook.currentStreakOf(_PROJECT_ID, _alice), 0);
    }

    function test_rejectsPositivePaymentWithZeroIssuance() public {
        JBAfterPayRecordedContext memory context = _payContext(_alice, 0);
        context.amount.value = 1;
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_ZeroIssuance.selector, _PROJECT_ID, 1));
        vm.prank(_terminal);
        _hook.afterPayRecordedWith(context);
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
    }

    function test_paymentCallbackRejectsUnexpectedEth() public {
        JBAfterPayRecordedContext memory context = _payContext(_alice, 0);
        vm.deal(address(this), 1);
        vm.deal(_terminal, 1);
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_UnexpectedValue.selector, 1));
        vm.prank(_terminal);
        _hook.afterPayRecordedWith{value: 1}(context);
        assertEq(address(_hook).balance, 0);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), 0);
    }

    function test_cashOutCallbackRejectsUnexpectedEth() public {
        JBAfterCashOutRecordedContext memory context;
        context.projectId = _PROJECT_ID;
        context.holder = _alice;
        vm.deal(address(this), 1);
        vm.deal(_terminal, 1);
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_UnexpectedValue.selector, 1));
        vm.prank(_terminal);
        _hook.afterCashOutRecordedWith{value: 1}(context);
        assertEq(address(_hook).balance, 0);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), 0);
    }

    function test_zeroMintBurnAndCallbacksHaveNoAccountingEffect() public {
        _mintAndRecord(_alice, 0);
        _token.burn({account: _alice, amount: 0});
        vm.prank(address(_token));
        _hook.recordBurn({projectId: _PROJECT_ID, holder: _alice, amount: 0});
        vm.prank(address(_token));
        _hook.recordTransfer({projectId: _PROJECT_ID, from: _alice, to: _bob, amount: 0});
        _callback(_alice, 0);
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _alice), 0);
        assertEq(_token.delegates(_alice), address(0));
    }

    function test_partialExitAcrossThousandPositiveDustTransfersHasBoundedGas() public {
        _dustPosition();
        vm.cool(address(_hook));
        vm.cool(address(_token));
        uint256 beforeGas = gasleft();
        (bool success,) = address(_token).call{gas: 250_000}(abi.encodeCall(JBStickyToken.burn, (_alice, 1001)));
        emit log_named_uint("Cold partial burn through 1,000 dust tranches", beforeGas - gasleft());
        assertTrue(success, "partial exit must fit the fixed gas budget");
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 10e18 - 1);
        assertEq(tranches[0].timestamp, 1);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), _token.balanceOf(_alice));
    }

    function test_fullExitAcrossThousandPositiveDustTransfersHasBoundedGas() public {
        _dustPosition();
        vm.cool(address(_hook));
        vm.cool(address(_token));
        uint256 beforeGas = gasleft();
        (bool success,) = address(_token).call{gas: 200_000}(abi.encodeCall(JBStickyToken.burn, (_alice, 10e18 + 1000)));
        emit log_named_uint("Cold full burn through 1,000 dust tranches", beforeGas - gasleft());
        assertTrue(success, "full exit must fit the fixed gas budget");
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _alice), 0);
        _mintAndRecord(_alice, 123);
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 123);
        assertEq(tranches[0].timestamp, vm.getBlockTimestamp());
    }

    function test_paginationCapsResultsAndNeverRevealsDiscardedTail() public {
        _dustPosition();
        JBStickyTranche[] memory page = _hook.tranchesOf(_PROJECT_ID, _alice, 0, type(uint256).max);
        assertEq(page.length, 256);
        assertEq(page[0].amount, 10e18);
        page = _hook.tranchesOf(_PROJECT_ID, _alice, 1000, 256);
        assertEq(page.length, 1);
        page = _hook.tranchesOf(_PROJECT_ID, _alice, type(uint256).max, type(uint256).max);
        assertEq(page.length, 0);
        _token.burn({account: _alice, amount: 1000});
        page = _hook.tranchesOf(_PROJECT_ID, _alice, 1, 256);
        assertEq(page.length, 0);
        _mintAndRecord(_alice, 321);
        page = _hook.tranchesOf(_PROJECT_ID, _alice, 1, 256);
        assertEq(page.length, 1);
        assertEq(page[0].amount, 321);
    }

    function testFuzz_mixedMovementsMatchLifoReferenceModel(uint256 seed) public {
        for (uint256 i; i < 64; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + seed % 100);
            address from = seed & 1 == 0 ? _alice : _bob;
            address to = seed & 2 == 0 ? _alice : _bob;
            uint256 operation = (seed >> 2) % 5;
            uint256 amount = (seed >> 8) % 1e20;
            if (operation == 0) {
                _mintAndRecord(from, amount);
                _modelAdd(from, amount);
            } else if (operation == 1) {
                amount %= _modelBalance[from] + 1;
                _token.burn({account: from, amount: amount});
                _modelConsume(from, amount);
            } else {
                amount = operation == 2 ? 0 : amount % (_modelBalance[from] + 1);
                if (operation == 3) to = from;
                vm.prank(from);
                _token.transfer({to: to, value: amount});
                if (from != to && amount != 0) {
                    _modelConsume(from, amount);
                    _modelAdd(to, amount);
                }
            }
            _assertPosition(_alice);
            _assertPosition(_bob);
            assertEq(_token.totalSupply(), _modelBalance[_alice] + _modelBalance[_bob]);
            assertEq(_token.getTotalActiveVotes(), _token.totalSupply());
        }
    }

    function _assertPosition(address holder) internal view {
        JBStickyTranche[] memory actual = _hook.tranchesOf(_PROJECT_ID, holder);
        assertEq(actual.length, _modelTranches[holder].length);
        uint256 sum;
        for (uint256 i; i < actual.length; i++) {
            assertEq(actual[i].amount, _modelTranches[holder][i].amount);
            assertEq(actual[i].timestamp, _modelTranches[holder][i].timestamp);
            assertGt(actual[i].amount, 0);
            sum += actual[i].amount;
        }
        assertEq(sum, _modelBalance[holder]);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, holder), sum);
        assertEq(_token.balanceOf(holder), sum);
        assertEq(_token.getVotes(holder), sum);
        assertEq(_hook.streakStartOf(_PROJECT_ID, holder), _modelStart[holder]);
        uint256 current = sum == 0 ? 0 : vm.getBlockTimestamp() - _modelStart[holder];
        assertEq(_hook.currentStreakOf(_PROJECT_ID, holder), current);
        assertEq(
            _hook.longestStreakOf(_PROJECT_ID, holder),
            current > _modelLongest[holder] ? current : _modelLongest[holder]
        );
    }

    function _callback(address holder, uint256 amount) internal {
        JBAfterCashOutRecordedContext memory context;
        context.projectId = _PROJECT_ID;
        context.holder = holder;
        context.cashOutCount = amount;
        vm.prank(_terminal);
        _hook.afterCashOutRecordedWith(context);
    }

    function _dustPosition() internal {
        vm.warp(1);
        _mintAndRecord(_alice, 10e18);
        _mintAndRecord(_stranger, 1000);
        vm.startPrank(_stranger);
        for (uint256 i; i < 1000; i++) {
            vm.warp(i + 2);
            _token.transfer({to: _alice, value: 1});
        }
        vm.stopPrank();
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 1001);
    }

    function _mintAndRecord(address holder, uint256 amount) internal {
        _token.mint({account: holder, amount: amount});
        _recordMint(holder, amount);
    }

    function _recordMint(address holder, uint256 amount) internal {
        vm.mockCall({
            callee: _terminal,
            data: abi.encodePacked(IJBTerminal.currentSurplusOf.selector),
            returnData: abi.encode(_token.totalSupply())
        });
        JBAfterPayRecordedContext memory context = _payContext(holder, amount);
        vm.prank(_terminal);
        _hook.afterPayRecordedWith(context);
    }

    function _modelAdd(address holder, uint256 amount) internal {
        if (amount == 0) return;
        if (_modelBalance[holder] == 0) _modelStart[holder] = vm.getBlockTimestamp();
        _modelBalance[holder] += amount;
        _modelTranches[holder].push(
            JBStickyTranche({amount: uint208(amount), timestamp: uint48(vm.getBlockTimestamp())})
        );
    }

    function _modelConsume(address holder, uint256 amount) internal {
        if (amount == 0) return;
        _modelBalance[holder] -= amount;
        while (amount != 0) {
            JBStickyTranche storage tranche = _modelTranches[holder][_modelTranches[holder].length - 1];
            if (tranche.amount > amount) {
                tranche.amount -= uint208(amount);
                amount = 0;
            } else {
                amount -= tranche.amount;
                _modelTranches[holder].pop();
            }
        }
        if (_modelBalance[holder] == 0) {
            uint256 duration = vm.getBlockTimestamp() - _modelStart[holder];
            if (duration > _modelLongest[holder]) _modelLongest[holder] = duration;
            _modelStart[holder] = 0;
        }
    }

    function _payContext(
        address holder,
        uint256 amount
    )
        internal
        view
        returns (JBAfterPayRecordedContext memory context)
    {
        context.projectId = _PROJECT_ID;
        context.payer = holder;
        context.beneficiary = holder;
        context.amount = JBTokenAmount({token: address(0), decimals: 18, currency: 0, value: amount});
        context.newlyIssuedTokenCount = amount;
        // This accounting fixture models proportional, zero-tax cashouts, keeping backing equal to supply.
        // Real controller burns and their changed share price are covered by JBStickyBurnIntegrationTest.
        uint256 supplyBefore = _token.totalSupply() - amount;
        context.hookMetadata = abi.encode(supplyBefore, supplyBefore, uint256(0));
    }
}
