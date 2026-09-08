// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyHook} from "../src/JBStickyHook.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyPricing} from "../src/libraries/JBStickyPricing.sol";
import {JBStickyPricingToken} from "./helpers/JBStickyPricingToken.sol";

/// @notice Economic regressions use the real V6 terminal, controller, token registry, and cash-out curve.
contract JBStickyPricingRegressionTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    address internal _incumbent = makeAddr("pricing incumbent");
    address internal _newcomer = makeAddr("pricing newcomer");
    address internal _donor = makeAddr("pricing donor");
    JBStickyDeployer internal _deployer;
    IJBStickyHook internal _hook;
    JBStickyPricingToken internal _underlying;
    uint256 internal _projectId;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = _deployer.HOOK();
        _underlying = new JBStickyPricingToken(6);
        _projectId = _deploy({underlying: _underlying, tax: 0});
    }

    function testFuzz_newcomerNeverExtractsDonatedBacking(
        uint256 incumbentAmount,
        uint256 donation,
        uint256 newcomerAmount,
        bool newcomerExitsFirst
    )
        public
    {
        incumbentAmount = bound(incumbentAmount, 1e6, 1e15);
        donation = bound(donation, 1, 1e15);
        newcomerAmount = bound(newcomerAmount, 1e6, 1e15);
        uint256 incumbentShares = _stake({holder: _incumbent, amount: incumbentAmount, minimum: 1});
        _donate(donation);
        uint256 newcomerShares = _stake({holder: _newcomer, amount: newcomerAmount, minimum: 1});

        // A depositor cannot leave with someone else's donated assets. Remaining holders receive all rounding dust.
        uint256 newcomerReclaim;
        uint256 incumbentReclaim;
        if (newcomerExitsFirst) {
            newcomerReclaim = _cashOut({holder: _newcomer, count: newcomerShares});
            incumbentReclaim = _cashOut({holder: _incumbent, count: incumbentShares});
        } else if (newcomerShares < 1e12) {
            // An enormous donation can price the newcomer's whole deposit below the supply floor. The incumbent
            // then cannot be the one to leave a positive dust supply behind, but nobody's backing is lost: the
            // newcomer exits in full and the incumbent follows.
            vm.expectRevert(
                abi.encodeWithSelector(
                    JBStickyHook.JBStickyHook_SupplyBelowMinimum.selector, _projectId, newcomerShares, 1e12
                )
            );
            _cashOut({holder: _incumbent, count: incumbentShares});
            newcomerReclaim = _cashOut({holder: _newcomer, count: newcomerShares});
            incumbentReclaim = _cashOut({holder: _incumbent, count: incumbentShares});
        } else {
            incumbentReclaim = _cashOut({holder: _incumbent, count: incumbentShares});
            newcomerReclaim = _cashOut({holder: _newcomer, count: newcomerShares});
        }
        assertLe(newcomerReclaim, newcomerAmount);
        assertGe(incumbentReclaim, incumbentAmount + donation);
        assertEq(incumbentReclaim + newcomerReclaim, incumbentAmount + donation + newcomerAmount);
        assertEq(_backing(), 0);
        assertEq(_shares().totalSupply(), 0);
    }

    function testFuzz_nonzeroWeightPreservesShareValueAndBoundsRounding(
        uint256 amount,
        uint256 supply,
        uint256 backing,
        uint8 decimals
    )
        public
        pure
    {
        amount = bound(amount, 1, 1e24);
        supply = bound(supply, 1, 1e24);
        backing = bound(backing, 1, 1e24);
        decimals = uint8(bound(decimals, 0, 36));
        uint256 weight =
            JBStickyPricing.weightFrom({amount: amount, supply: supply, backing: backing, decimals: decimals});
        if (weight == 0) return;

        // Check value conservation with exact integer cross-products, independently of the pricing implementation.
        uint256 issued = Math.mulDiv({x: amount, y: weight, denominator: backing});
        assertGt(issued, 0);
        assertLe(issued * backing, amount * supply);
        assertGe(issued * backing * 10_000, amount * supply * 9999);
        assertGe((backing + amount) * supply, backing * (supply + issued));
    }

    function testFuzz_orphanBackingCannotEscapeAcrossBurnedAndRedeemedSupplies(
        uint256 prefunding,
        uint256 burnedDeposit,
        uint256 laterDeposit,
        uint256 liveDonation
    )
        public
    {
        prefunding = bound(prefunding, 1, 1e15);
        burnedDeposit = bound(burnedDeposit, 1, 1e15);
        laterDeposit = bound(laterDeposit, 1, 1e15);
        liveDonation = bound(liveDonation, 1, 1e15);
        _donate(prefunding);
        uint256 firstShares = _stake({holder: _incumbent, amount: burnedDeposit, minimum: 1});
        _burn({holder: _incumbent, count: firstShares});

        uint256 secondShares = _stake({holder: _newcomer, amount: laterDeposit, minimum: 1});
        _donate(liveDonation);
        assertEq(_cashOut({holder: _newcomer, count: secondShares}), laterDeposit + liveDonation);
        assertEq(_backing(), prefunding + burnedDeposit);
        assertEq(_hook.orphanedBalanceOf(_projectId), prefunding + burnedDeposit);

        uint256 finalShares = _stake({holder: _incumbent, amount: 1e6, minimum: 1});
        assertEq(_cashOut({holder: _incumbent, count: finalShares}), 1e6);
        assertEq(_backing(), prefunding + burnedDeposit);
        assertEq(_shares().totalSupply(), 0);
        assertEq(_hook.stakedBalanceOf(_projectId, _incumbent), 0);
        assertEq(_hook.stakedBalanceOf(_projectId, _newcomer), 0);
    }

    function test_bootstrapRoundingLossAboveOneBasisPointReverts() public {
        _underlying = new JBStickyPricingToken(24);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        assertEq(_preview({holder: _newcomer, amount: 1_999_999}), 0);
        _assertZeroIssuanceRevertsAtomically(1_999_999);
        assertEq(_hook.orphanedBalanceOf(_projectId), 0);
    }

    function test_bootstrapRoundingProtectionHasOneBasisPointBoundary() public {
        _underlying = new JBStickyPricingToken(24);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        // Bootstrap one whole token so later deposits are priced at the same one-to-one rate.
        assertEq(_stake({holder: _incumbent, amount: 1e24, minimum: 1e18}), 1e18);
        // A loss of almost one share atom is too large for 9,999 ideal atoms, but within tolerance for 10,000.
        assertEq(_preview({holder: _newcomer, amount: 9_998_999_999}), 0);
        assertEq(_preview({holder: _newcomer, amount: 9_999_999_999}), 9999);
        assertEq(_stake({holder: _newcomer, amount: 9_999_999_999, minimum: 9999}), 9999);
        uint256 reclaim = _cashOut({holder: _newcomer, count: 9999});
        assertGe(reclaim, 9_999_000_000);
        assertLe(reclaim, 9_999_999_999);
    }

    function test_bootstrapBelowSupplyFloorPreviewsZeroAndRevertsAtomically() public {
        _underlying = new JBStickyPricingToken(18);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        assertEq(_preview({holder: _newcomer, amount: 1e12 - 1}), 0);
        _assertZeroIssuanceRevertsAtomically(1e12 - 1);
        assertEq(_stake({holder: _incumbent, amount: 1e12, minimum: 1e12}), 1e12);
    }

    function test_decimals0RoundTrip() public {
        _exercisePrecision(0);
    }

    function test_decimals18RoundTrip() public {
        _exercisePrecision(18);
    }

    function test_decimals24RoundTrip() public {
        _exercisePrecision(24);
    }

    function test_decimals36RoundTrip() public {
        _exercisePrecision(36);
    }

    function test_decimals6RoundTrip() public {
        _exercisePrecision(6);
    }

    function test_donationFrontRunningCannotBypassReviewedMintMinimum() public {
        _stake({holder: _incumbent, amount: 10e6, minimum: 10e18});
        uint256 reviewedMinimum = _preview({holder: _newcomer, amount: 10e6});
        assertEq(reviewedMinimum, 10e18);
        _donate(10e6);
        _fund({holder: _newcomer, amount: 10e6});
        vm.expectRevert(abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, 5e18, 10e18));
        _pay({holder: _newcomer, amount: 10e6, minimum: reviewedMinimum});
        assertEq(_underlying.balanceOf(_newcomer), 10e6);
        assertEq(_backing(), 20e6);
        assertEq(_shares().totalSupply(), 10e18);
        assertEq(_shares().balanceOf(_newcomer), 0);
        assertEq(_hook.stakedBalanceOf(_projectId, _newcomer), 0);
        assertEq(_hook.trancheCountOf(_projectId, _newcomer), 0);
    }

    function test_emptyProjectPrefundingNeverBelongsToFirstDepositor() public {
        _donate(17e6);
        assertEq(_preview({holder: _newcomer, amount: 10e6}), 10e18);
        uint256 shares = _stake({holder: _newcomer, amount: 10e6, minimum: 10e18});
        assertEq(_hook.orphanedBalanceOf(_projectId), 17e6);
        assertEq(_cashOut({holder: _newcomer, count: shares}), 10e6);
        assertEq(_backing(), 17e6);
        assertEq(_shares().totalSupply(), 0);

        // The same donor cannot retrieve the orphan by repeatedly starting and ending a new share supply.
        uint256 nextShares = _stake({holder: _donor, amount: 3e6, minimum: 3e18});
        assertEq(_cashOut({holder: _donor, count: nextShares}), 3e6);
        assertEq(_backing(), 17e6);
    }

    function test_fullVoluntaryBurnResetsOrphanBaselineForNewSupply() public {
        _donate(7e6);
        uint256 shares = _stake({holder: _incumbent, amount: 10e6, minimum: 10e18});
        _donate(13e6);
        _burn({holder: _incumbent, count: shares});
        assertEq(_shares().totalSupply(), 0);
        assertEq(_hook.stakedBalanceOf(_projectId, _incumbent), 0);

        // All old backing, including later donations, becomes orphaned after the last share is voluntarily burned.
        uint256 newShares = _stake({holder: _newcomer, amount: 5e6, minimum: 5e18});
        assertEq(_hook.orphanedBalanceOf(_projectId), 30e6);
        assertEq(_cashOut({holder: _newcomer, count: newShares}), 5e6);
        assertEq(_backing(), 30e6);
    }

    function test_hundredPercentTaxLeavesOrphanForNextSupply() public {
        _projectId = _deploy({underlying: _underlying, tax: 10_000});
        uint256 shares = _stake({holder: _incumbent, amount: 10e6, minimum: 10e18});
        assertEq(_cashOut({holder: _incumbent, count: shares}), 0);
        assertEq(_backing(), 10e6);
        assertEq(_shares().totalSupply(), 0);
        uint256 nextShares = _stake({holder: _newcomer, amount: 5e6, minimum: 5e18});
        assertEq(nextShares, 5e18);
        assertEq(_hook.orphanedBalanceOf(_projectId), 10e6);
        assertEq(_cashOut({holder: _newcomer, count: nextShares}), 0);

        _stake({holder: _donor, amount: 2e6, minimum: 2e18});
        assertEq(_hook.orphanedBalanceOf(_projectId), 15e6);
        assertEq(_backing(), 17e6);
    }

    function test_newcomerPaysForShareOfDonatedBacking() public {
        uint256 incumbentShares = _stake({holder: _incumbent, amount: 10e6, minimum: 10e18});
        _donate(10e6);
        assertEq(_preview({holder: _newcomer, amount: 10e6}), 5e18);
        uint256 newcomerShares = _stake({holder: _newcomer, amount: 10e6, minimum: 5e18});
        assertEq(newcomerShares, 5e18);
        assertEq(_cashOut({holder: _newcomer, count: newcomerShares}), 10e6);
        assertEq(_cashOut({holder: _incumbent, count: incumbentShares}), 20e6);
        assertEq(_backing(), 0);
    }

    function test_partialVoluntaryBurnRaisesPriceForNewDepositors() public {
        uint256 incumbentShares = _stake({holder: _incumbent, amount: 10e6, minimum: 10e18});
        _burn({holder: _incumbent, count: incumbentShares / 2});
        assertEq(_preview({holder: _newcomer, amount: 10e6}), 5e18);
        uint256 newcomerShares = _stake({holder: _newcomer, amount: 10e6, minimum: 5e18});
        assertEq(newcomerShares, 5e18);
        assertEq(_cashOut({holder: _newcomer, count: newcomerShares}), 10e6);
        assertEq(_cashOut({holder: _incumbent, count: incumbentShares / 2}), 10e6);
        assertEq(_backing(), 0);
    }

    function test_roundingLossAboveOneBasisPointPreviewsZeroAndRevertsAtomically() public {
        _underlying = new JBStickyPricingToken(18);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        _stake({holder: _incumbent, amount: 1e12, minimum: 1e12});
        _donate(1e12);
        // Three underlying atoms should buy 1.5 share atoms; accepting one would sacrifice a third of their value.
        assertEq(_preview({holder: _newcomer, amount: 3}), 0);
        _assertZeroIssuanceRevertsAtomically(3);
        assertEq(_cashOut({holder: _incumbent, count: 1e12}), 2e12);
    }

    function test_eighteenDecimalsFirstMintBoundary() public {
        _exerciseFirstMintBoundary(18);
    }

    function test_thirtySixDecimalsFirstMintBoundary() public {
        _exerciseFirstMintBoundary(36);
    }

    function test_tinySupplyAndOneTokenDonationStillPricesInexactDeposits() public {
        _exerciseTinySupplyDonation(1e18);
    }

    function test_tinySupplyAndTwentyTokenDonationStillPricesInexactDeposits() public {
        _exerciseTinySupplyDonation(20e18);
    }

    function test_twentyFourDecimalsFirstMintBoundary() public {
        _exerciseFirstMintBoundary(24);
    }

    function test_soleHolderDonationCannotForceExactMultipleDeposits() public {
        _underlying = new JBStickyPricingToken(18);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        // The smallest allowed bootstrap plus a large donation is the coarsest atom price a sole holder can set.
        assertEq(_stake({holder: _incumbent, amount: 1e12, minimum: 1e12}), 1e12);
        _donate(1000e18);
        uint256 quote = _preview({holder: _newcomer, amount: 100e18 + 1});
        assertGt(quote, 0);
        // A one-wei donation front-run changes the price by less than the rounding tolerance.
        _donate(1);
        uint256 shares = _stake({holder: _newcomer, amount: 100e18 + 1, minimum: quote - 1});
        assertGe(shares, quote - 1);
        assertLe(_cashOut({holder: _newcomer, count: shares}), 100e18 + 1);
    }

    function test_voluntaryBurnCannotLeaveSupplyBelowFloor() public {
        _underlying = new JBStickyPricingToken(18);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        _stake({holder: _incumbent, amount: 1e18, minimum: 1e18});
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_SupplyBelowMinimum.selector, _projectId, 1, 1e12)
        );
        _burn({holder: _incumbent, count: 1e18 - 1});
        _burn({holder: _incumbent, count: 1e18 - 1e12});
        assertEq(_shares().totalSupply(), 1e12);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_SupplyBelowMinimum.selector, _projectId, 1e12 - 1, 1e12)
        );
        _burn({holder: _incumbent, count: 1});
        _donate(20e18);
        // Deposits that are not whole multiples of the atom price still issue shares.
        uint256 quote = _preview({holder: _newcomer, amount: 21e18 + 3});
        assertGt(quote, 0);
        assertEq(_stake({holder: _newcomer, amount: 21e18 + 3, minimum: quote}), quote);
        // Emptying the supply entirely remains allowed.
        _cashOut({holder: _newcomer, count: quote});
        _burn({holder: _incumbent, count: 1e12});
        assertEq(_shares().totalSupply(), 0);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    function _assertZeroIssuanceRevertsAtomically(uint256 amount) internal {
        _fund({holder: _newcomer, amount: amount});
        uint256 backingBefore = _backing();
        uint256 supplyBefore = _shares().totalSupply();
        uint256 orphanBefore = _hook.orphanedBalanceOf(_projectId);
        uint256 balanceBefore = _underlying.balanceOf(_newcomer);
        vm.expectRevert(abi.encodeWithSelector(JBStickyHook.JBStickyHook_ZeroIssuance.selector, _projectId, amount));
        _pay({holder: _newcomer, amount: amount, minimum: 0});
        assertEq(_underlying.balanceOf(_newcomer), balanceBefore);
        assertEq(_backing(), backingBefore);
        assertEq(_shares().totalSupply(), supplyBefore);
        assertEq(_hook.orphanedBalanceOf(_projectId), orphanBefore);
        assertEq(_hook.stakedBalanceOf(_projectId, _newcomer), 0);
        assertEq(_hook.trancheCountOf(_projectId, _newcomer), 0);
    }

    function _burn(address holder, uint256 count) internal {
        vm.prank(holder);
        jbController().burnTokensOf({holder: holder, projectId: _projectId, tokenCount: count, memo: ""});
    }

    function _cashOut(address holder, uint256 count) internal returns (uint256) {
        vm.prank(holder);
        return jbMultiTerminal().cashOutTokensOf({
            holder: holder,
            projectId: _projectId,
            cashOutCount: count,
            tokenToReclaim: address(_underlying),
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: bytes("")
        });
    }

    function _deploy(JBStickyPricingToken underlying, uint256 tax) internal returns (uint256) {
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        return _deployer.deployStickyFor{value: fee}({
            stakedToken: underlying,
            name: "Sticky pricing",
            symbol: "stPRICE",
            projectUri: "",
            cashOutTaxRate: tax,
            granters: new address[](0),
            soulbound: true
        });
    }

    function _donate(uint256 amount) internal {
        _fund({holder: _donor, amount: amount});
        vm.prank(_donor);
        jbMultiTerminal().addToBalanceOf({
            projectId: _projectId,
            token: address(_underlying),
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: bytes("")
        });
    }

    function _exerciseFirstMintBoundary(uint8 decimals) internal {
        _underlying = new JBStickyPricingToken(decimals);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        uint256 oneShareAtom = 10 ** (decimals - 18);
        // The bootstrap must reach the supply floor; one atom short previews zero and reverts atomically.
        uint256 floorAmount = oneShareAtom * 1e12;
        assertEq(_preview({holder: _newcomer, amount: floorAmount - 1}), 0);
        _assertZeroIssuanceRevertsAtomically(floorAmount - 1);
        assertEq(_stake({holder: _incumbent, amount: floorAmount, minimum: 1e12}), 1e12);
        // Once bootstrapped, a single share atom is the smallest deposit at the one-to-one rate. A zero payment is
        // not a rounding case, so only precisions above 18 have an amount just short of one atom.
        if (oneShareAtom > 1) {
            assertEq(_preview({holder: _newcomer, amount: oneShareAtom - 1}), 0);
            _assertZeroIssuanceRevertsAtomically(oneShareAtom - 1);
        }
        assertEq(_stake({holder: _newcomer, amount: oneShareAtom, minimum: 1}), 1);
        assertEq(_cashOut({holder: _newcomer, count: 1}), oneShareAtom);
        assertEq(_cashOut({holder: _incumbent, count: 1e12}), floorAmount);
    }

    function _exercisePrecision(uint8 decimals) internal {
        _underlying = new JBStickyPricingToken(decimals);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        uint256 unit = 10 ** decimals;
        uint256 incumbentShares = _stake({holder: _incumbent, amount: 10 * unit, minimum: 10e18});
        assertEq(incumbentShares, 10e18);
        _donate(10 * unit);
        uint256 newcomerShares = _stake({holder: _newcomer, amount: 10 * unit, minimum: 5e18});
        assertEq(newcomerShares, 5e18);
        assertEq(_cashOut({holder: _newcomer, count: newcomerShares}), 10 * unit);
        assertEq(_cashOut({holder: _incumbent, count: incumbentShares}), 20 * unit);
        assertEq(_backing(), 0);
    }

    function _exerciseTinySupplyDonation(uint256 donation) internal {
        _underlying = new JBStickyPricingToken(18);
        _projectId = _deploy({underlying: _underlying, tax: 0});
        assertEq(_stake({holder: _incumbent, amount: 1e12, minimum: 1e12}), 1e12);
        _donate(donation);
        uint256 backing = donation + 1e12;

        // Rounding an exchange rate before multiplication previously made every payment return zero here. The exact
        // backing denominator and the supply floor let a deposit that is not a whole multiple of the atom price buy
        // shares without minting extra claims.
        uint256 quote = _preview({holder: _newcomer, amount: backing + 7});
        assertGt(quote, 0);
        assertEq(_stake({holder: _newcomer, amount: backing + 7, minimum: quote}), quote);
        assertLe(_cashOut({holder: _newcomer, count: quote}), backing + 7);
        assertGe(_cashOut({holder: _incumbent, count: 1e12}), backing);
        assertEq(_backing(), 0);
        assertEq(_shares().totalSupply(), 0);
    }

    function _fund(address holder, uint256 amount) internal {
        _underlying.mint({account: holder, amount: amount});
        vm.prank(holder);
        _underlying.approve({spender: address(jbMultiTerminal()), value: type(uint256).max});
    }

    function _pay(address holder, uint256 amount, uint256 minimum) internal returns (uint256) {
        vm.prank(holder);
        return jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: amount,
            beneficiary: holder,
            minReturnedTokens: minimum,
            memo: "",
            metadata: bytes("")
        });
    }

    function _preview(address holder, uint256 amount) internal returns (uint256 shares) {
        vm.prank(holder);
        (, shares,,) = jbMultiTerminal().previewPayFor({
            projectId: _projectId, token: address(_underlying), amount: amount, beneficiary: holder, metadata: bytes("")
        });
    }

    function _stake(address holder, uint256 amount, uint256 minimum) internal returns (uint256) {
        _fund({holder: holder, amount: amount});
        return _pay({holder: holder, amount: amount, minimum: minimum});
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    function _backing() internal view returns (uint256) {
        return jbTerminalStore().balanceOf(address(jbMultiTerminal()), _projectId, address(_underlying));
    }

    function _shares() internal view returns (IJBToken) {
        return jbTokens().tokenOf(_projectId);
    }
}
