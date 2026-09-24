// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBStickyAutoStick} from "../../src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "../../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../../src/JBStickyDistributor.sol";
import {JBStickyHook} from "../../src/JBStickyHook.sol";
import {JBStickyToken} from "../../src/JBStickyToken.sol";
import {JBAutoStickStatus} from "../../src/enums/JBAutoStickStatus.sol";
import {JBStickyTranche} from "../../src/structs/JBStickyTranche.sol";
import {JBStickyRealProjectContext, JBStickyRealProjectFork} from "./helpers/JBStickyRealProjectFork.sol";

/// @notice Exercises the same holder lifecycle against real V6 projects on Ethereum and Base.
/// @dev The concrete suites select pinned mainnet state; only Sticky is deployed locally, with its production settings.
abstract contract JBStickyRealProjectLifecycle is JBStickyRealProjectFork {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The selected mainnet fork and its contracts.
    JBStickyRealProjectContext internal _context;

    /// @notice The Sticky project launched for each test.
    uint256 internal _projectId;

    /// @notice The Sticky shares issued by the test project.
    JBStickyToken internal _token;

    /// @notice The suite's position-accounting hook.
    JBStickyHook internal _hook;

    /// @notice The suite's weekly, four-round vesting distributor.
    JBStickyDistributor internal _distributor;

    /// @notice The suite's opt-in compounding adapter.
    JBStickyAutoStick internal _autoStick;

    /// @notice The primary holder paying into the underlying project and Sticky.
    address internal _alice;

    /// @notice The independent holder used for shared-backing checks.
    address internal _bob;

    /// @notice The permanently authorized grant sender.
    address internal _granter;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Compounding uses the current backing price after a donation and spends only the newly collected reward.
    function test_autoStickAfterDonationMintsTheReviewedReducedShareCount() public {
        uint256 reward = _prepareVestedRewards();
        uint256 sharesBefore = _token.balanceOf(_alice);
        uint256 walletBefore = _context.underlying.balanceOf(_alice);
        _donate(_backing());
        vm.prank(address(_autoStick));
        (, uint256 preview,,) = _context.core.terminal
            .previewPayFor({
                projectId: _projectId,
                token: address(_context.underlying),
                amount: reward,
                beneficiary: _alice,
                metadata: bytes("")
            });
        (uint256 compounded, uint256 minted) =
            _autoStick.compoundFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(compounded, reward);
        assertEq(minted, preview);
        assertEq(minted, reward / 2);
        assertEq(_token.balanceOf(_alice), sharesBefore + preview);
        assertEq(_context.underlying.balanceOf(_alice), walletBefore);
        _assertPosition(_alice);
    }

    /// @notice Historical snapshot rewards can restart an exited holder only while that holder's consent remains valid.
    function test_autoStickAfterFullExitRequiresTrustAndStartsFreshStreak() public {
        uint256 reward = _prepareVestedRewards();
        _cashOut({
            context: _context, projectId: _projectId, holder: _alice, count: _token.balanceOf(_alice), minimum: 1
        });
        assertEq(_hook.streakStartOf(_projectId, _alice), 0);
        vm.prank(_alice);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(_autoStick), trusted: false});
        vm.expectPartialRevert(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector);
        _autoStick.compoundFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(_distributor.collectableFor(address(_token), uint256(uint160(_alice)), _rewardToken()), reward);
        vm.prank(_alice);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(_autoStick), trusted: true});
        _autoStick.compoundFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(_token.balanceOf(_alice), reward);
        assertEq(_hook.streakStartOf(_projectId, _alice), vm.getBlockTimestamp());
        assertEq(_hook.trancheCountOf(_projectId, _alice), 1);
        _assertPosition(_alice);
    }

    /// @notice Revoking compounding approval cannot collect rewards or pull unrelated wallet funds.
    function test_autoStickApprovalFailureIsAtomicAndRetryCompoundsOnlyRewards() public {
        uint256 reward = _prepareVestedRewards();
        uint256 originalStreak = _hook.streakStartOf(_projectId, _alice);
        uint256 sharesBefore = _token.balanceOf(_alice);
        uint256 walletBefore = _context.underlying.balanceOf(_alice);
        vm.prank(_alice);
        _context.underlying.approve({spender: address(_autoStick), value: 0});
        vm.expectPartialRevert(JBStickyAutoStick.JBStickyAutoStick_InsufficientAllowance.selector);
        _autoStick.compoundFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(_distributor.collectableFor(address(_token), uint256(uint160(_alice)), _rewardToken()), reward);
        assertEq(_context.underlying.balanceOf(_alice), walletBefore);
        assertEq(_token.balanceOf(_alice), sharesBefore);

        vm.prank(_alice);
        _context.underlying.approve({spender: address(_autoStick), value: reward});
        (JBAutoStickStatus status,,,) = _autoStick.statusOf(_projectId, _alice, _defaultGroup());
        assertEq(uint256(status), uint256(JBAutoStickStatus.Ready));
        (uint256 compounded, uint256 minted) =
            _autoStick.compoundFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(compounded, reward);
        assertEq(minted, reward);
        assertEq(_context.underlying.balanceOf(_alice), walletBefore, "unrelated wallet balance is untouched");
        assertEq(_token.balanceOf(_alice), sharesBefore + reward);
        assertEq(_context.underlying.balanceOf(address(_autoStick)), 0);
        assertEq(_hook.streakStartOf(_projectId, _alice), originalStreak);
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, _alice);
        assertEq(tranches.length, 2);
        assertEq(tranches[1].amount, reward);
        assertEq(tranches[1].timestamp, vm.getBlockTimestamp());
        _assertPosition(_alice);
    }

    /// @notice The permissionless collector pays the holder and leaves no wallet reward for a later automatic pull.
    function test_collectingVestedRewardsPreventsLaterCompoundFromSpendingWalletTokens() public {
        uint256 reward = _prepareVestedRewards();
        uint256 walletBefore = _context.underlying.balanceOf(_alice);
        _distributor.collectVestedRewards({
            hook: address(_token), tokenIds: _ids(_alice), tokens: _rewardTokens(), beneficiary: _alice
        });
        assertEq(_context.underlying.balanceOf(_alice), walletBefore + reward);
        vm.expectPartialRevert(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector);
        _autoStick.compoundFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(_context.underlying.balanceOf(_alice), walletBefore + reward);
        _assertPosition(_alice);
    }

    /// @notice Donations raise the share price; an outdated minimum rejects the entire payment without donating it.
    function test_donationRepricesNewStakeAndReviewedMinimumProtectsWallet() public {
        uint256 amount = _context.underlying.balanceOf(_alice) / 10;
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        vm.prank(_bob);
        (, uint256 reviewed,,) = _context.core.terminal
            .previewPayFor({
                projectId: _projectId,
                token: address(_context.underlying),
                amount: amount,
                beneficiary: _bob,
                metadata: bytes("")
            });
        _donate(amount);
        uint256 walletBefore = _context.underlying.balanceOf(_bob);
        vm.startPrank(_bob);
        _context.underlying.approve({spender: address(_context.core.terminal), value: amount});
        vm.expectPartialRevert(JBMultiTerminal.JBMultiTerminal_UnderMin.selector);
        _context.core.terminal
            .pay({
                projectId: _projectId,
                token: address(_context.underlying),
                amount: amount,
                beneficiary: _bob,
                minReturnedTokens: reviewed,
                memo: "",
                metadata: bytes("")
            });
        vm.stopPrank();
        assertEq(_context.underlying.balanceOf(_bob), walletBefore);
        assertEq(_backing(), 2 * amount);
        assertEq(_token.balanceOf(_bob), 0);
        uint256 minted =
            _stake({context: _context, projectId: _projectId, payer: _bob, beneficiary: _bob, amount: amount});
        assertEq(minted, amount / 2);
        assertEq(_backing(), 3 * amount);
        _assertPosition(_alice);
        _assertPosition(_bob);
    }

    /// @notice Burning the entire supply leaves orphaned backing that a later first depositor cannot extract.
    function test_fullVoluntaryBurnAndEmptyDonationCannotBeCapturedOnRestart() public {
        uint256 amount = _context.underlying.balanceOf(_alice) / 10;
        uint256 shares =
            _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _burn({holder: _alice, count: shares});
        assertEq(_token.totalSupply(), 0);
        assertEq(_hook.streakStartOf(_projectId, _alice), 0);
        assertEq(_hook.longestStreakOf(_projectId, _alice), 3 days);
        _donate(amount);
        uint256 bobShares =
            _stake({context: _context, projectId: _projectId, payer: _bob, beneficiary: _bob, amount: amount});
        assertEq(bobShares, amount);
        assertEq(_hook.orphanedBalanceOf(_projectId), 2 * amount);
        assertEq(
            _cashOut({context: _context, projectId: _projectId, holder: _bob, count: bobShares, minimum: amount}),
            amount
        );
        assertEq(_backing(), 2 * amount);
        assertEq(_token.totalSupply(), 0);
        _assertPosition(_alice);
        _assertPosition(_bob);
    }

    /// @notice Global grants and holder-specific trust add fresh tranches without resetting an active streak.
    function test_grantsTrustRevocationAndSoulboundTransfersPreserveHolderConsent() public {
        uint256 amount = _context.underlying.balanceOf(_alice) / 20;
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        uint256 start = _hook.streakStartOf(_projectId, _alice);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        _stake({context: _context, projectId: _projectId, payer: _granter, beneficiary: _alice, amount: amount});
        vm.expectPartialRevert(JBStickyHook.JBStickyHook_SenderNotTrusted.selector);
        vm.prank(_bob);
        _context.core.terminal
            .previewPayFor({
                projectId: _projectId,
                token: address(_context.underlying),
                amount: amount,
                beneficiary: _alice,
                metadata: bytes("")
            });
        vm.prank(_alice);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: _bob, trusted: true});
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        _stake({context: _context, projectId: _projectId, payer: _bob, beneficiary: _alice, amount: amount});
        assertEq(_hook.streakStartOf(_projectId, _alice), start);
        assertEq(_hook.trancheCountOf(_projectId, _alice), 3);
        vm.startPrank(_alice);
        _hook.setTrustedSenderFor({projectId: _projectId, sender: _bob, trusted: false});
        vm.expectRevert(abi.encodeWithSelector(JBStickyToken.JBStickyToken_Soulbound.selector, _alice, _bob));
        _token.transfer({to: _bob, value: amount});
        vm.stopPrank();
        assertFalse(_hook.isTrustedSenderOf(_projectId, _alice, _bob));
        uint256 walletBefore = _context.underlying.balanceOf(_bob);
        vm.startPrank(_bob);
        _context.underlying.approve({spender: address(_context.core.terminal), value: amount});
        vm.expectPartialRevert(JBStickyHook.JBStickyHook_SenderNotTrusted.selector);
        _context.core.terminal
            .pay({
                projectId: _projectId,
                token: address(_context.underlying),
                amount: amount,
                beneficiary: _alice,
                minReturnedTokens: 0,
                memo: "",
                metadata: bytes("")
            });
        vm.stopPrank();
        assertEq(_context.underlying.balanceOf(_bob), walletBefore);
        assertEq(_token.balanceOf(_alice), 3 * amount);
        _assertPosition(_alice);
    }

    /// @notice A soulbound holder can redeem every share while an independent account retains one share atom.
    function test_holderFullyExitsWhileAnotherSoulboundHolderKeepsDust() public {
        _exerciseDustExit();
    }

    /// @notice A transferable holder can redeem every share while an independent account retains one share atom.
    function test_holderFullyExitsWhileAnotherTransferableHolderKeepsDust() public {
        (_projectId, _token) = _launchSticky({context: _context, soulbound: false, cashOutTaxRate: 0});
        _exerciseDustExit();
    }

    /// @notice Launch fixes ownership, accepted asset, data hooks, payout permissions, and reward timing.
    function test_launchUsesPermanentV6ConfigurationAndProductionRewardSettings() public view {
        JBStickyDeployer deployer = JBStickyDeployer(_context.suite.deployer);
        (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) =
            _context.core.controller.currentRulesetOf(_projectId);
        assertEq(_context.core.controller.PROJECTS().ownerOf(_projectId), address(deployer));
        assertEq(address(_context.core.directory.controllerOf(_projectId)), address(_context.core.controller));
        assertEq(address(deployer.stakedTokenOf(_projectId)), address(_context.underlying));
        assertEq(address(_token.HOOK()), address(_hook));
        assertEq(address(_token.TOKENS()), address(_context.core.controller.TOKENS()));
        assertEq(_token.PROJECT_ID(), _projectId);
        assertTrue(_token.SOULBOUND());
        assertEq(ruleset.duration, 0);
        assertEq(ruleset.weightCutPercent, 0);
        assertEq(address(ruleset.approvalHook), address(0));
        assertEq(metadata.reservedPercent, 0);
        assertEq(metadata.cashOutTaxRate, 0);
        assertEq(metadata.dataHook, address(_hook));
        assertTrue(metadata.useDataHookForPay);
        assertTrue(metadata.useDataHookForCashOut);
        assertTrue(metadata.pauseCreditTransfers);
        assertFalse(metadata.allowOwnerMinting);
        assertFalse(metadata.allowSetTerminals);
        assertFalse(metadata.allowSetController);
        assertFalse(metadata.allowTerminalMigration);
        assertFalse(metadata.allowAddAccountingContext);
        JBAccountingContext[] memory contexts = _context.core.terminal.accountingContextsOf(_projectId);
        assertEq(contexts.length, 1);
        assertEq(contexts[0].token, address(_context.underlying));
        assertEq(contexts[0].decimals, 18);
        assertEq(
            _context.core.controller.FUND_ACCESS_LIMITS().payoutLimitsOf({
                projectId: _projectId,
                rulesetId: ruleset.id,
                terminal: address(_context.core.terminal),
                token: address(_context.underlying)
            }).length,
            0
        );
        assertEq(
            _context.core.controller.FUND_ACCESS_LIMITS().surplusAllowancesOf({
                projectId: _projectId,
                rulesetId: ruleset.id,
                terminal: address(_context.core.terminal),
                token: address(_context.underlying)
            }).length,
            0
        );
        assertEq(_distributor.ROUND_DURATION(), 7 days);
        assertEq(_distributor.VESTING_ROUNDS(), 4);
        assertEq(_distributor.CLAIM_DURATION(), 2 * 365 days);
    }

    /// @notice Historical rewards follow unequal snapshot balances after transfers, burns, and a late deposit.
    function test_rewardSnapshotSurvivesTransferBurnAndLateDeposit() public {
        (_projectId, _token) = _launchSticky({context: _context, soulbound: false, cashOutTaxRate: 0});
        uint256 unit = _context.underlying.balanceOf(_alice) / 20;
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: 3 * unit});
        _stake({context: _context, projectId: _projectId, payer: _bob, beneficiary: _bob, amount: unit});
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(_granter);
        _context.underlying.approve({spender: address(_distributor), value: 4 * unit});
        _distributor.fund({hook: address(_token), token: _rewardToken(), amount: 4 * unit});
        vm.stopPrank();

        // Later ownership does not rewrite the distributor's completed balance checkpoint.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(_alice);
        _token.transfer({to: _granter, value: 3 * unit});
        _burn({holder: _bob, count: unit});
        _stake({context: _context, projectId: _projectId, payer: _granter, beneficiary: _granter, amount: unit});
        vm.warp(vm.getBlockTimestamp() + _distributor.ROUND_DURATION() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory ids = new uint256[](3);
        ids[0] = uint256(uint160(_alice));
        ids[1] = uint256(uint160(_bob));
        ids[2] = uint256(uint160(_granter));
        _distributor.beginVesting({hook: address(_token), tokenIds: ids, tokens: _rewardTokens()});
        vm.warp(vm.getBlockTimestamp() + (_distributor.VESTING_ROUNDS() + 1) * _distributor.ROUND_DURATION());
        vm.roll(vm.getBlockNumber() + 1);
        uint256 aliceBefore = _context.underlying.balanceOf(_alice);
        uint256 bobBefore = _context.underlying.balanceOf(_bob);
        _distributor.collectVestedRewards({
            hook: address(_token), tokenIds: _ids(_alice), tokens: _rewardTokens(), beneficiary: _alice
        });
        _distributor.collectVestedRewards({
            hook: address(_token), tokenIds: _ids(_bob), tokens: _rewardTokens(), beneficiary: _bob
        });
        assertEq(_context.underlying.balanceOf(_alice) - aliceBefore, 3 * unit);
        assertEq(_context.underlying.balanceOf(_bob) - bobBefore, unit);
        assertEq(_distributor.collectableFor(address(_token), uint256(uint160(_granter)), _rewardToken()), 0);
        assertEq(_distributor.balanceOf(address(_token), _rewardToken()), 0);
        _assertPosition(_alice);
        _assertPosition(_bob);
        _assertPosition(_granter);
    }

    /// @notice Partial and complete exits match the live store's curve preview and the terminal's protocol fee.
    function test_taxedPartialAndFullCashOutMatchGrossPreviewAndNetWalletReceipt() public {
        (_projectId, _token) = _launchSticky({context: _context, soulbound: true, cashOutTaxRate: 5000});
        uint256 amount = _context.underlying.balanceOf(_alice) / 10;
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        _stake({context: _context, projectId: _projectId, payer: _bob, beneficiary: _bob, amount: amount});
        uint256 first = _assertTaxedCashOut({holder: _alice, count: amount / 2});
        uint256 second = _assertTaxedCashOut({holder: _alice, count: amount - amount / 2});
        assertLt(first + second, amount, "cash-out curve rewards continuing holders");
        assertEq(_token.balanceOf(_alice), 0);
        assertEq(_hook.streakStartOf(_projectId, _alice), 0);
        uint256 stayer = _assertTaxedCashOut({holder: _bob, count: amount});
        assertGt(stayer, amount, "continuing holder owns retained backing");
        assertEq(_token.totalSupply(), 0);
        _assertPosition(_alice);
        _assertPosition(_bob);
    }

    /// @notice Transferable shares move votes and tranches; voluntary burns retain backing for remaining shares.
    function test_transferBurnAndCashOutKeepCheckpointsTranchesAndBackingConsistent() public {
        (_projectId, _token) = _launchSticky({context: _context, soulbound: false, cashOutTaxRate: 0});
        uint256 amount = _context.underlying.balanceOf(_alice) / 10;
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        uint256 initialBlock = vm.getBlockNumber();
        uint256 aliceStart = _hook.streakStartOf(_projectId, _alice);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 moved = amount / 4;
        vm.prank(_alice);
        _token.transfer({to: _bob, value: moved});
        assertEq(_token.getPastVotes(_alice, initialBlock), amount);
        assertEq(_token.getPastVotes(_bob, initialBlock), 0);
        assertEq(_token.getVotes(_alice), amount - moved);
        assertEq(_token.getVotes(_bob), moved);
        assertEq(_hook.streakStartOf(_projectId, _alice), aliceStart);
        assertEq(_hook.streakStartOf(_projectId, _bob), vm.getBlockTimestamp());
        _burn({holder: _alice, count: moved});
        assertEq(_backing(), amount, "voluntary burn does not reclaim underlying");
        _assertPosition(_alice);
        _assertPosition(_bob);
        _cashOut({context: _context, projectId: _projectId, holder: _bob, count: moved, minimum: moved});
        _cashOut({
            context: _context, projectId: _projectId, holder: _alice, count: _token.balanceOf(_alice), minimum: 1
        });
        assertEq(_backing(), 0);
        assertEq(_token.totalSupply(), 0);
        _assertPosition(_alice);
        _assertPosition(_bob);
    }

    /// @notice A real-token round trip consumes the newest tranche first and preserves the remaining deposit's age.
    function test_twoDepositsPartialExitAndFullExitReturnUnderlyingAndPreserveTrancheAge() public {
        uint256 walletBefore = _context.underlying.balanceOf(_alice);
        uint256 amount = walletBefore / 10;
        uint256 start = vm.getBlockTimestamp();
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _cashOut({
            context: _context,
            projectId: _projectId,
            holder: _alice,
            count: amount + amount / 2,
            minimum: amount + amount / 2
        });
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, _alice);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].timestamp, start);
        assertEq(tranches[0].amount, amount - amount / 2);
        assertEq(_hook.streakStartOf(_projectId, _alice), start);
        _cashOut({
            context: _context,
            projectId: _projectId,
            holder: _alice,
            count: _token.balanceOf(_alice),
            minimum: amount - amount / 2
        });
        assertEq(_context.underlying.balanceOf(_alice), walletBefore);
        assertEq(_backing(), 0);
        assertEq(_token.totalSupply(), 0);
        assertEq(_hook.streakStartOf(_projectId, _alice), 0);
        assertEq(_hook.longestStreakOf(_projectId, _alice), 1 weeks + 1 days);
        _assertPosition(_alice);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Checks the fee-adjusted preview against both the cash-out return and actual ERC-20 wallet receipt.
    /// @param holder The holder and beneficiary.
    /// @param count The Sticky share count to redeem.
    /// @return net The received amount after the protocol fee.
    function _assertTaxedCashOut(address holder, uint256 count) internal returns (uint256 net) {
        (, uint256 gross, uint256 tax,) = _context.core.terminal.STORE().previewCashOutFrom({
            terminal: address(_context.core.terminal),
            holder: holder,
            projectId: _projectId,
            cashOutCount: count,
            tokenToReclaim: address(_context.underlying),
            beneficiaryIsFeeless: false,
            metadata: bytes("")
        });
        assertEq(tax, 5000);
        uint256 expectedNet = gross - JBFees.standardFeeAmountFrom(gross);
        net = _cashOut({context: _context, projectId: _projectId, holder: holder, count: count, minimum: expectedNet});
        assertEq(net, expectedNet, "store preview is gross; the wallet receives net");
    }

    /// @notice Burns shares through the live controller without withdrawing their backing.
    /// @param holder The holder authorizing the burn.
    /// @param count The share atoms to burn.
    function _burn(address holder, uint256 count) internal {
        vm.prank(holder);
        _context.core.controller.burnTokensOf({holder: holder, projectId: _projectId, tokenCount: count, memo: ""});
    }

    /// @notice Adds real underlying tokens to backing without issuing Sticky shares.
    /// @param amount The underlying-token amount to donate.
    function _donate(uint256 amount) internal {
        vm.startPrank(_granter);
        _context.underlying.approve({spender: address(_context.core.terminal), value: amount});
        _context.core.terminal
            .addToBalanceOf({
                projectId: _projectId,
                token: address(_context.underlying),
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });
        vm.stopPrank();
    }

    /// @notice Leaves one holder with a share atom and confirms another holder's full exit remains independent.
    function _exerciseDustExit() internal {
        uint256 amount = 1e12;
        // Use an exact integer price while sizing the donation from tokens obtained through real payments.
        uint256 backing = _context.underlying.balanceOf(_granter) / 4 / amount * amount;
        uint256 perShareAtom = backing / amount;
        assertGt(backing, amount);
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        _donate(backing - amount);
        _stake({context: _context, projectId: _projectId, payer: _bob, beneficiary: _bob, amount: 2 * backing});
        _cashOut({
            context: _context, projectId: _projectId, holder: _alice, count: amount - 1, minimum: backing - perShareAtom
        });
        assertEq(_token.balanceOf(_alice), 1);
        _cashOut({
            context: _context, projectId: _projectId, holder: _bob, count: amount + 1, minimum: backing + perShareAtom
        });
        assertEq(_token.totalSupply(), amount);
        uint256 finalCount = _token.balanceOf(_bob);
        _cashOut({
            context: _context, projectId: _projectId, holder: _bob, count: finalCount, minimum: backing - perShareAtom
        });
        assertEq(_token.balanceOf(_bob), 0);
        assertEq(_token.totalSupply(), 1);
        assertEq(_backing(), perShareAtom);
        _assertPosition(_alice);
        _assertPosition(_bob);
    }

    /// @notice Funds real underlying rewards after a share checkpoint and advances the production vesting schedule.
    /// @return reward The fully vested amount belonging to the single snapshot holder.
    function _prepareVestedRewards() internal returns (uint256 reward) {
        uint256 amount = _context.underlying.balanceOf(_alice) / 10;
        reward = amount / 2;
        _stake({context: _context, projectId: _projectId, payer: _alice, beneficiary: _alice, amount: amount});
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(_granter);
        _context.underlying.approve({spender: address(_distributor), value: reward});
        _distributor.fund({hook: address(_token), token: _rewardToken(), amount: reward});
        vm.stopPrank();
        vm.startPrank(_alice);
        _context.underlying.approve({spender: address(_autoStick), value: type(uint256).max});
        _hook.setTrustedSenderFor({projectId: _projectId, sender: address(_autoStick), trusted: true});
        _autoStick.setConfigFor({projectId: _projectId, enabled: true, minimumAmount: 1, cooldown: 1 days});
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + _distributor.ROUND_DURATION() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        _autoStick.beginVestingFor({projectId: _projectId, holder: _alice, groupIds: _defaultGroup()});
        assertEq(_distributor.collectableFor(address(_token), uint256(uint160(_alice)), _rewardToken()), 0);
        vm.warp(vm.getBlockTimestamp() + (_distributor.VESTING_ROUNDS() + 1) * _distributor.ROUND_DURATION());
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_distributor.collectableFor(address(_token), uint256(uint160(_alice)), _rewardToken()), reward);
    }

    /// @notice Initializes common actors, launches Sticky, and acquires every test token through real native payments.
    function _setUpLifecycle() internal {
        _alice = makeAddr("alice");
        _bob = makeAddr("bob");
        _granter = makeAddr("granter");
        _hook = JBStickyHook(_context.suite.hook);
        _distributor = JBStickyDistributor(payable(_context.suite.distributor));
        _autoStick = JBStickyAutoStick(_context.suite.autoStick);
        (_projectId, _token) = _launchSticky({context: _context, soulbound: true, cashOutTaxRate: 0});
        _buyUnderlying({context: _context, holder: _alice, nativeAmount: 0.1 ether});
        _buyUnderlying({context: _context, holder: _bob, nativeAmount: 0.1 ether});
        _buyUnderlying({context: _context, holder: _granter, nativeAmount: 0.1 ether});
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Confirms every recorded tranche and stake equals the holder's actual ERC-20 balance.
    /// @param holder The holder whose position is checked.
    function _assertPosition(address holder) internal view {
        JBStickyTranche[] memory tranches = _hook.tranchesOf(_projectId, holder);
        uint256 sum;
        for (uint256 i; i < tranches.length; i++) {
            sum += tranches[i].amount;
        }
        assertEq(sum, _token.balanceOf(holder));
        assertEq(_hook.stakedBalanceOf(_projectId, holder), _token.balanceOf(holder));
    }

    /// @notice Reads the Sticky project's recorded underlying balance from the live terminal store.
    /// @return backing The backing amount, in underlying-token atoms.
    function _backing() internal view returns (uint256 backing) {
        return _context.core
            .terminal
            .STORE()
            .balanceOf(address(_context.core.terminal), _projectId, address(_context.underlying));
    }

    /// @notice The default reward group, as a one-element list.
    /// @return groupIds The default group.
    function _defaultGroup() internal pure returns (uint256[] memory groupIds) {
        groupIds = new uint256[](1);
    }

    /// @notice Builds the distributor's single-holder account identifier.
    /// @param holder The reward recipient.
    /// @return tokenIds The holder address encoded as its voting token ID.
    function _ids(address holder) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
    }

    /// @notice Returns the existing project's token using the distributor's interface.
    /// @return token The reward asset.
    function _rewardToken() internal view returns (IERC20 token) {
        return IERC20(address(_context.underlying));
    }

    /// @notice Builds the distributor's single-token reward list.
    /// @return tokens The existing project's token.
    function _rewardTokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = _rewardToken();
    }
}

/// @notice Runs every Sticky lifecycle against the existing Base project 6 and its real project token.
contract JBStickyBase6ForkTest is JBStickyRealProjectLifecycle {
    /// @notice Selects pinned Base mainnet state and prepares the real-project lifecycle.
    function setUp() public {
        _context = _createProjectFork({rpcAlias: "base", forkBlock: _BASE_BLOCK, chainId: 8453, underlyingProjectId: 6});
        _setUpLifecycle();
    }
}

/// @notice Runs every Sticky lifecycle against the existing Ethereum project 3 and its real project token.
contract JBStickyEthereum3ForkTest is JBStickyRealProjectLifecycle {
    /// @notice Selects pinned Ethereum mainnet state and prepares the real-project lifecycle.
    function setUp() public {
        _context =
            _createProjectFork({rpcAlias: "ethereum", forkBlock: _ETHEREUM_BLOCK, chainId: 1, underlyingProjectId: 3});
        _setUpLifecycle();
    }
}
