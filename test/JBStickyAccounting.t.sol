// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBStickyHook} from "../src/JBStickyHook.sol";
import {JBStickyToken} from "../src/JBStickyToken.sol";

import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice Regression and reference-model coverage for token-driven position accounting.
contract JBStickyAccountingTest is Test {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The project whose positions the hook accounts for.
    uint256 internal constant _PROJECT_ID = 7;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The first holder exercised by the tests.
    address internal _alice = makeAddr("alice");

    /// @notice The second holder exercised by the tests.
    address internal _bob = makeAddr("bob");

    /// @notice The hook accounting for tranches, streaks and epoch buckets.
    JBStickyHook internal _hook;

    /// @notice The reference model's staked balance per holder.
    /// @custom:param holder The holder whose balance is modeled.
    mapping(address holder => uint256) internal _modelBalance;

    /// @notice The reference model's net staked amount per epoch.
    /// @custom:param epoch The epoch whose bucket is modeled.
    mapping(uint256 epoch => uint256) internal _modelBucket;

    /// @notice Every epoch the reference model has credited.
    uint256[] internal _modelEpochs;

    /// @notice The reference model's longest completed streak per holder.
    /// @custom:param holder The holder whose longest streak is modeled.
    mapping(address holder => uint256) internal _modelLongest;

    /// @notice The reference model's current streak start per holder.
    /// @custom:param holder The holder whose streak start is modeled.
    mapping(address holder => uint256) internal _modelStart;

    /// @notice The reference model's active tranches per holder.
    /// @custom:param holder The holder whose tranches are modeled.
    mapping(address holder => JBStickyTranche[]) internal _modelTranches;

    /// @notice An unrelated account that sends dust transfers and unauthorized calls.
    address internal _stranger = makeAddr("stranger");

    /// @notice The mocked terminal allowed to call the hook.
    address internal _terminal = makeAddr("terminal");

    /// @notice The Sticky share token wired to the hook.
    JBStickyToken internal _token;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

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

    function test_exitGasGrowsWithDistinctWeeksNotDeposits() public {
        // Ten years of weekly dust: 520 tranches in 520 distinct epochs, the most tenure rewards can distinguish.
        _weeklyPosition(520);
        vm.cool(address(_hook));
        vm.cool(address(_token));
        uint256 beforeGas = gasleft();
        (bool success,) =
            address(_token).call{gas: 5_000_000}(abi.encodeCall(JBStickyToken.burn, (_alice, 10e18 + 520)));
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Cold full burn through 520 weekly tranches", used);
        assertTrue(success, "a full exit across 520 weekly tranches must fit the recorded budget");
        // About 7,600 gas per distinct week: one tranche read and one bucket debit each. Recorded in RISKS.md.
        assertLt(used, 4_200_000);
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), 0);
        for (uint256 epoch; epoch <= 520; epoch++) {
            assertEq(_hook.netStakedIn(_PROJECT_ID, epoch), 0);
        }
    }

    function test_fullExitAcrossThousandSameWeekDustTransfersHasBoundedGas() public {
        _dustPosition();
        vm.cool(address(_hook));
        vm.cool(address(_token));
        uint256 beforeGas = gasleft();
        (bool success,) = address(_token).call{gas: 200_000}(abi.encodeCall(JBStickyToken.burn, (_alice, 10e18 + 1000)));
        emit log_named_uint("Cold full burn through 1,000 same-week dust transfers", beforeGas - gasleft());
        assertTrue(success, "full exit must fit the fixed gas budget");
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.streakStartOf(_PROJECT_ID, _alice), 0);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 0), 0);
        _mintAndRecord(_alice, 123);
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 123);
        assertEq(tranches[0].timestamp, vm.getBlockTimestamp());
    }

    function test_netStakedWithinRejectsInvertedRange() public {
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_InvalidEpochRange.selector, 3, 2));
        _hook.netStakedWithin(_PROJECT_ID, 3, 2);
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

    function test_paginationCapsResultsAndNeverRevealsDiscardedTail() public {
        _weeklyPosition(1000);
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

    function test_partialExitAcrossThousandSameWeekDustTransfersHasBoundedGas() public {
        _dustPosition();
        vm.cool(address(_hook));
        vm.cool(address(_token));
        uint256 beforeGas = gasleft();
        (bool success,) = address(_token).call{gas: 250_000}(abi.encodeCall(JBStickyToken.burn, (_alice, 1001)));
        emit log_named_uint("Cold partial burn through 1,000 same-week dust transfers", beforeGas - gasleft());
        assertTrue(success, "partial exit must fit the fixed gas budget");
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 10e18 - 1);
        assertEq(tranches[0].timestamp, 1001);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 0), 10e18 - 1);
        assertEq(_hook.stakedBalanceOf(_PROJECT_ID, _alice), _token.balanceOf(_alice));
    }

    function test_partialExitDebitsEachConsumedWeekAtItsOriginalEpoch() public {
        _weeklyPosition(3);
        // Alice: 10e18 in epoch 0, then 1 unit in each of epochs 1, 2, 3.
        assertEq(_hook.netStakedIn(_PROJECT_ID, 0), 10e18);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 1), 1);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 2), 1);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 3), 1);
        assertEq(_hook.netStakedWithin(_PROJECT_ID, 0, 3), 10e18 + 3);
        assertEq(_hook.netStakedWithin(_PROJECT_ID, 1, 2), 2);

        // Burning 2 + a slice of epoch 1 leaves epoch 0 whole, trims epoch 1, and empties epochs 2 and 3.
        vm.warp(10 weeks);
        _token.burn({account: _alice, amount: 2});
        assertEq(_hook.netStakedIn(_PROJECT_ID, 0), 10e18);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 1), 1);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 2), 0);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 3), 0);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 10), 0);
        _token.burn({account: _alice, amount: 5});
        assertEq(_hook.netStakedIn(_PROJECT_ID, 0), 10e18 - 4);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 1), 0);
        assertEq(_hook.stakedBalanceThroughEpochOf(_PROJECT_ID, _alice, 0), 10e18 - 4);
        assertEq(_hook.stakedBalanceThroughEpochOf(_PROJECT_ID, _alice, 9), 10e18 - 4);
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 1);
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

    function test_sameWeekDustTransfersMergeIntoTheNewestTranche() public {
        _dustPosition();
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].amount, 10e18 + 1000);
        // The merged tranche carries the latest joining's timestamp, never an earlier one.
        assertEq(tranches[0].timestamp, 1001);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 0), 10e18 + 1000);
        assertEq(_hook.stakedBalanceThroughEpochOf(_PROJECT_ID, _alice, 0), 10e18 + 1000);

        // The next week starts a new tranche instead of extending the merged one.
        vm.warp(1 weeks + 5);
        _mintAndRecord(_alice, 7);
        tranches = _hook.tranchesOf(_PROJECT_ID, _alice);
        assertEq(tranches.length, 2);
        assertEq(tranches[1].amount, 7);
        assertEq(tranches[1].timestamp, 1 weeks + 5);
        assertEq(_hook.netStakedIn(_PROJECT_ID, 1), 7);
        assertEq(_hook.stakedBalanceThroughEpochOf(_PROJECT_ID, _alice, 0), 10e18 + 1000);
        assertEq(_hook.stakedBalanceThroughEpochOf(_PROJECT_ID, _alice, 1), 10e18 + 1007);
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

    function testFuzz_mixedMovementsMatchLifoReferenceModel(uint256 seed) public {
        for (uint256 i; i < 64; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // Jumps under a week keep merges common; the occasional multi-day jump crosses epoch boundaries.
            vm.warp(vm.getBlockTimestamp() + seed % 4 days);
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
            _assertBuckets();
            assertEq(_token.totalSupply(), _modelBalance[_alice] + _modelBalance[_bob]);
            assertEq(_token.getTotalActiveVotes(), _token.totalSupply());
        }
    }

    function testFuzz_stakedBalanceThroughEpochMatchesBruteForce(uint256 seed) public {
        for (uint256 i; i < 48; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + seed % 10 days);
            uint256 amount = (seed >> 8) % 1e20;
            if (seed & 1 == 0) {
                _mintAndRecord(_alice, amount);
                _modelAdd(_alice, amount);
            } else {
                amount %= _modelBalance[_alice] + 1;
                _token.burn({account: _alice, amount: amount});
                _modelConsume(_alice, amount);
            }
            _assertThroughEpochs(_alice);
        }
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Report a cash out of `amount` shares for `holder` through the hook's after-cash-out callback.
    /// @param holder The holder whose shares are cashed out.
    /// @param amount The number of shares cashed out.
    function _callback(address holder, uint256 amount) internal {
        JBAfterCashOutRecordedContext memory context;
        context.projectId = _PROJECT_ID;
        context.holder = holder;
        context.cashOutCount = amount;
        vm.prank(_terminal);
        _hook.afterCashOutRecordedWith(context);
    }

    /// @notice Alice holds 10e18 plus 1,000 same-week dust transfers, which all merge into one tranche.
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
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), 1);
    }

    /// @notice Mint `amount` shares to `holder` and record the matching payment with the hook.
    /// @param holder The account receiving the shares.
    /// @param amount The number of shares to mint.
    function _mintAndRecord(address holder, uint256 amount) internal {
        _token.mint({account: holder, amount: amount});
        _recordMint(holder, amount);
    }

    /// @notice Add `amount` to the reference model's position for `holder` at the current timestamp.
    /// @param holder The holder whose position grows.
    /// @param amount The number of shares added.
    function _modelAdd(address holder, uint256 amount) internal {
        if (amount == 0) return;
        if (_modelBalance[holder] == 0) _modelStart[holder] = vm.getBlockTimestamp();
        _modelBalance[holder] += amount;
        uint256 epoch = vm.getBlockTimestamp() / 1 weeks;
        _modelCredit(epoch, amount);
        JBStickyTranche[] storage tranches = _modelTranches[holder];
        // Same-epoch joins extend the newest tranche and move its timestamp to now.
        if (tranches.length != 0 && uint256(tranches[tranches.length - 1].timestamp) / 1 weeks == epoch) {
            tranches[tranches.length - 1].amount += uint208(amount);
            tranches[tranches.length - 1].timestamp = uint48(vm.getBlockTimestamp());
            return;
        }
        tranches.push(JBStickyTranche({amount: uint208(amount), timestamp: uint48(vm.getBlockTimestamp())}));
    }

    /// @notice Consume `amount` from the reference model's position for `holder`, newest tranche first.
    /// @param holder The holder whose position shrinks.
    /// @param amount The number of shares consumed.
    function _modelConsume(address holder, uint256 amount) internal {
        if (amount == 0) return;
        _modelBalance[holder] -= amount;
        while (amount != 0) {
            JBStickyTranche storage tranche = _modelTranches[holder][_modelTranches[holder].length - 1];
            uint256 epoch = uint256(tranche.timestamp) / 1 weeks;
            if (tranche.amount > amount) {
                tranche.amount -= uint208(amount);
                _modelBucket[epoch] -= amount;
                amount = 0;
            } else {
                amount -= tranche.amount;
                _modelBucket[epoch] -= tranche.amount;
                _modelTranches[holder].pop();
            }
        }
        if (_modelBalance[holder] == 0) {
            uint256 duration = vm.getBlockTimestamp() - _modelStart[holder];
            if (duration > _modelLongest[holder]) _modelLongest[holder] = duration;
            _modelStart[holder] = 0;
        }
    }

    /// @notice Credit `amount` to the reference model's bucket for `epoch`, tracking the epoch when first touched.
    /// @param epoch The epoch whose bucket grows.
    /// @param amount The number of shares credited.
    function _modelCredit(uint256 epoch, uint256 amount) internal {
        if (_modelBucket[epoch] == 0) {
            bool known;
            for (uint256 i; i < _modelEpochs.length; i++) {
                if (_modelEpochs[i] == epoch) known = true;
            }
            if (!known) _modelEpochs.push(epoch);
        }
        _modelBucket[epoch] += amount;
    }

    /// @notice Record a payment issuing `amount` shares to `holder` through the hook's after-pay callback.
    /// @param holder The payment beneficiary.
    /// @param amount The number of shares the payment issued.
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

    /// @notice Alice holds 10e18 plus one dust transfer in each of the next `weekCount` weeks: `weekCount + 1`
    /// tranches.
    /// @param weekCount The number of weekly dust transfers to make.
    function _weeklyPosition(uint256 weekCount) internal {
        vm.warp(1);
        _mintAndRecord(_alice, 10e18);
        _mintAndRecord(_stranger, weekCount);
        vm.startPrank(_stranger);
        for (uint256 i; i < weekCount; i++) {
            vm.warp((i + 1) * 1 weeks + 1);
            _token.transfer({to: _alice, value: 1});
        }
        vm.stopPrank();
        assertEq(_hook.trancheCountOf(_PROJECT_ID, _alice), weekCount + 1);
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Checks every touched epoch bucket against the model, and that the buckets sum to the balances.
    function _assertBuckets() internal view {
        uint256 sum;
        for (uint256 i; i < _modelEpochs.length; i++) {
            uint256 epoch = _modelEpochs[i];
            assertEq(_hook.netStakedIn(_PROJECT_ID, epoch), _modelBucket[epoch]);
            sum += _modelBucket[epoch];
        }
        assertEq(sum, _modelBalance[_alice] + _modelBalance[_bob]);
    }

    /// @notice Checks the hook's tranches, balances, votes and streaks for `holder` against the reference model.
    /// @param holder The holder whose position is checked.
    function _assertPosition(address holder) internal view {
        JBStickyTranche[] memory actual = _hook.tranchesOf(_PROJECT_ID, holder);
        assertEq(actual.length, _modelTranches[holder].length);
        uint256 sum;
        for (uint256 i; i < actual.length; i++) {
            assertEq(actual[i].amount, _modelTranches[holder][i].amount);
            assertEq(actual[i].timestamp, _modelTranches[holder][i].timestamp);
            assertGt(actual[i].amount, 0);
            // Merging keeps every active tranche in a distinct, increasing epoch.
            if (i != 0) assertGt(uint256(actual[i].timestamp) / 1 weeks, uint256(actual[i - 1].timestamp) / 1 weeks);
            sum += actual[i].amount;
        }
        _assertThroughEpochs(holder);
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

    /// @notice Checks `stakedBalanceThroughEpochOf` against a brute-force sum of the model's tranches at every epoch
    /// boundary the holder's tranches touch, plus the edges.
    /// @param holder The holder whose epoch balances are checked.
    function _assertThroughEpochs(address holder) internal view {
        JBStickyTranche[] storage model = _modelTranches[holder];
        uint256 probes = model.length * 3 + 2;
        for (uint256 p; p < probes; p++) {
            uint256 epoch;
            if (p == probes - 2) {
                epoch = 0;
            } else if (p == probes - 1) {
                epoch = type(uint256).max;
            } else {
                uint256 base = uint256(model[p / 3].timestamp) / 1 weeks;
                epoch = p % 3 == 0 ? base : (p % 3 == 1 ? base + 1 : (base == 0 ? 0 : base - 1));
            }
            uint256 expected;
            for (uint256 i; i < model.length; i++) {
                if (uint256(model[i].timestamp) / 1 weeks <= epoch) expected += model[i].amount;
            }
            assertEq(_hook.stakedBalanceThroughEpochOf(_PROJECT_ID, holder, epoch), expected);
        }
    }

    /// @notice Build an after-pay context that issues `amount` shares to `holder` at a proportional share price.
    /// @param holder The payer and beneficiary of the modeled payment.
    /// @param amount The payment value and the number of shares it issues.
    /// @return context The after-pay context handed to the hook.
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
