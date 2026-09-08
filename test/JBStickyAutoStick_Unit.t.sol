// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBStickyDeployer} from "../src/interfaces/IJBStickyDeployer.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBStickyAutoStick} from "../src/JBStickyAutoStick.sol";
import {IJBStickyAutoStick} from "../src/interfaces/IJBStickyAutoStick.sol";
import {JBAutoStickStatus} from "../src/enums/JBAutoStickStatus.sol";

/// @notice A mintable test token with configurable decimals and an optional transfer fee.
contract MockToken is ERC20 {
    uint8 immutable DECIMALS;
    uint256 public feeBps; // taken out of every transfer when non-zero

    constructor(uint8 decimals_) ERC20("Mock", "MOCK") {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        if (fee != 0 && from != address(0) && to != address(0)) {
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Delivers a configured collectable amount to the beneficiary on collection.
contract StubDistributor {
    MockToken public token;
    uint256 public collectable;
    uint256 public beginVestingCalls;
    uint256 public collectionCalls;
    uint256 public deliveryOverride;
    bool public hasDeliveryOverride;
    address public lastBeneficiary;
    address public lastBeginVestingHook;
    uint256 public lastBeginVestingTokenId;

    constructor(MockToken token_) {
        token = token_;
    }

    function setCollectable(uint256 amount) external {
        collectable = amount;
    }

    function setDeliveryOverride(uint256 amount) external {
        deliveryOverride = amount;
        hasDeliveryOverride = true;
    }

    function collectableFor(address, uint256, IERC20) external view returns (uint256) {
        return collectable;
    }

    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata) external {
        beginVestingCalls++;
        lastBeginVestingHook = hook;
        lastBeginVestingTokenId = tokenIds[0];
    }

    function collectVestedRewards(address, uint256[] calldata, IERC20[] calldata, address beneficiary) external {
        collectionCalls++;
        lastBeneficiary = beneficiary;
        token.mint(beneficiary, hasDeliveryOverride ? deliveryOverride : collectable);
        collectable = 0;
    }
}

/// @notice Models canonical terminal previews and payments, with configurable share pricing and short mints.
contract StubTerminal {
    using SafeERC20 for IERC20;

    MockToken public token;
    uint256 public shortfall; // shaves the returned mint when non-zero, to test the mint floor
    uint256 public sharePrice = 1;
    uint256 public lastProjectId;
    uint256 public lastMinimum;
    address public lastPayer;
    address public lastBeneficiary;
    bool public ignoreMinimum;

    constructor(MockToken token_) {
        token = token_;
    }

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    function setSharePrice(uint256 price) external {
        sharePrice = price;
    }

    function setIgnoreMinimum(bool shouldIgnore) external {
        ignoreMinimum = shouldIgnore;
    }

    function previewPayFor(
        uint256,
        address,
        uint256 amount,
        address,
        bytes calldata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        beneficiaryTokenCount = _quote(amount);
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function _quote(uint256 amount) internal view returns (uint256 count) {
        count = JBFixedPointNumber.adjustDecimals({value: amount, decimals: token.decimals(), targetDecimals: 18})
            / sharePrice;
    }

    function pay(
        uint256 projectId,
        address token_,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 count)
    {
        IERC20(token_).safeTransferFrom(msg.sender, address(this), amount);
        count = _quote(amount) - shortfall;
        if (!ignoreMinimum) require(count >= minReturnedTokens, "UnderMinReturnedTokens");
        lastProjectId = projectId;
        lastMinimum = minReturnedTokens;
        lastPayer = msg.sender;
        lastBeneficiary = beneficiary;
    }
}

contract JBStickyAutoStickUnitTest is Test {
    uint256 constant PROJECT_ID = 7;

    address holder = makeAddr("holder");
    address keeper = makeAddr("keeper");
    address deployer = makeAddr("deployer");
    address tokens = makeAddr("tokens");
    address hook = makeAddr("hook");
    address stickyToken = makeAddr("stickyToken");

    MockToken underlying;
    StubDistributor distributor;
    StubTerminal terminal;
    JBStickyAutoStick adapter;

    function setUp() public {
        _setUpWithDecimals(6);
    }

    function _setUpWithDecimals(uint8 decimals) internal {
        underlying = new MockToken(decimals);
        distributor = new StubDistributor(underlying);
        terminal = new StubTerminal(underlying);

        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.HOOK, ()), abi.encode(hook));
        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.TOKENS, ()), abi.encode(tokens));
        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.TERMINAL, ()), abi.encode(address(terminal)));
        adapter = new JBStickyAutoStick({
            deployer: IJBStickyDeployer(deployer), distributor: IJBDistributor(address(distributor))
        });

        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (PROJECT_ID)), abi.encode(underlying));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(stickyToken));
        _mockTrust(true);
        _mockGranter(false);
    }

    function _mockTrust(bool trusted) internal {
        vm.mockCall(
            hook,
            abi.encodeCall(IJBStickyHook.isTrustedSenderOf, (PROJECT_ID, holder, address(adapter))),
            abi.encode(trusted)
        );
    }

    function _mockGranter(bool granter) internal {
        vm.mockCall(
            hook, abi.encodeCall(IJBStickyHook.isGranterOf, (PROJECT_ID, address(adapter))), abi.encode(granter)
        );
    }

    // Enable with the default happy-path setup: config on, trust mocked on, unlimited allowance.
    function _enable(uint128 minimumAmount, uint48 cooldown) internal {
        vm.prank(holder);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: true, minimumAmount: minimumAmount, cooldown: cooldown});
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
    }

    //*********************************************************************//
    // ------------------------- configuration --------------------------- //
    //*********************************************************************//

    function test_setConfigStoresAndEmits() public {
        vm.expectEmit();
        emit IJBStickyAutoStick.SetAutoStick(PROJECT_ID, holder, true, 5e6, 2 days, holder);
        vm.prank(holder);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: true, minimumAmount: 5e6, cooldown: 2 days});

        (uint128 minimumAmount, uint48 cooldown, uint48 lastCompoundedAt, bool enabled) =
            adapter.configOf(PROJECT_ID, holder);
        assertEq(minimumAmount, 5e6);
        assertEq(cooldown, 2 days);
        assertEq(lastCompoundedAt, 0);
        assertTrue(enabled);
    }

    function test_setConfigOnlyAffectsCaller() public {
        vm.prank(keeper);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
        (,,, bool enabled) = adapter.configOf(PROJECT_ID, holder);
        assertFalse(enabled);
    }

    function test_setConfigRevertsOnZeroMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidMinimum.selector, 0));
        vm.prank(holder);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: true, minimumAmount: 0, cooldown: 1 days});
    }

    function test_setConfigRevertsOnCooldownOutOfRange() public {
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidCooldown.selector, 1 days - 1)
        );
        vm.prank(holder);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: true, minimumAmount: 1e6, cooldown: 1 days - 1});

        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidCooldown.selector, 30 days + 1)
        );
        vm.prank(holder);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: true, minimumAmount: 1e6, cooldown: 30 days + 1});
    }

    function test_setConfigRevertsOnUnknownProject() public {
        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (99)), abi.encode(address(0)));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (99)), abi.encode(address(0)));
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidProject.selector, 99));
        vm.prank(holder);
        adapter.setConfigFor({projectId: 99, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
    }

    function test_disablePreservesLastCompoundedAt() public {
        _enable(1e6, 1 days);
        distributor.setCollectable(5e6);
        adapter.compoundFor(PROJECT_ID, holder);
        (,, uint48 lastCompoundedAt,) = adapter.configOf(PROJECT_ID, holder);
        assertEq(lastCompoundedAt, block.timestamp);

        vm.prank(holder);
        adapter.setConfigFor({projectId: PROJECT_ID, enabled: false, minimumAmount: 1e6, cooldown: 1 days});
        (,, uint48 kept, bool enabled) = adapter.configOf(PROJECT_ID, holder);
        assertEq(kept, lastCompoundedAt);
        assertFalse(enabled);
    }

    //*********************************************************************//
    // -------------------------- permissions ---------------------------- //
    //*********************************************************************//

    function test_compoundRevertsWhenDisabled() public {
        distributor.setCollectable(5e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Disabled.selector, PROJECT_ID, holder)
        );
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_compoundRevertsWithoutTrust() public {
        _enable(1e6, 1 days);
        _mockTrust(false);
        distributor.setCollectable(5e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector, PROJECT_ID, holder)
        );
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_projectGranterStatusStandsInForTrust() public {
        // A project whose creator pre-approved the adapter as a granter needs no per-holder trust tx.
        _enable(1e6, 1 days);
        _mockTrust(false);
        _mockGranter(true);
        distributor.setCollectable(5e6);
        (JBAutoStickStatus status,,,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.Ready));
        (uint256 underlyingAmount,) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(underlyingAmount, 5e6);
    }

    function test_compoundRevertsWithoutAllowance() public {
        _enable(1e6, 1 days);
        vm.prank(holder);
        underlying.approve(address(adapter), 3e6);
        distributor.setCollectable(5e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InsufficientAllowance.selector, 3e6, 5e6)
        );
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_finiteAllowanceCompoundsUntilExhausted() public {
        _enable(1e6, 1 days);
        vm.prank(holder);
        underlying.approve(address(adapter), 5e6);
        distributor.setCollectable(5e6);
        adapter.compoundFor(PROJECT_ID, holder);

        vm.warp(block.timestamp + 1 days);
        distributor.setCollectable(5e6);
        (JBAutoStickStatus status,, uint256 allowance,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(allowance, 0);
        assertEq(uint256(status), uint256(JBAutoStickStatus.InsufficientAllowance));
    }

    function test_compoundRevertsOnUnknownProject() public {
        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (99)), abi.encode(address(0)));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (99)), abi.encode(address(0)));
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidProject.selector, 99));
        adapter.compoundFor(99, holder);
    }

    //*********************************************************************//
    // ------------------------- reward + amounts ------------------------ //
    //*********************************************************************//

    function test_compoundPullsExactlyTheCollectedAmount() public {
        _enable(1e6, 1 days);
        underlying.mint(holder, 100e6); // pre-existing balance stays untouched
        distributor.setCollectable(5e6);

        vm.expectEmit();
        emit IJBStickyAutoStick.AutoStuck(PROJECT_ID, holder, address(underlying), 5e6, 5e18, keeper);
        vm.prank(keeper);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.compoundFor(PROJECT_ID, holder);

        assertEq(underlyingAmount, 5e6);
        assertEq(stickyTokenCount, 5e18);
        // The holder keeps their pre-existing balance; the collected reward moved through to the terminal.
        assertEq(underlying.balanceOf(holder), 100e6);
        assertEq(underlying.balanceOf(address(terminal)), 5e6);
        // No custody or allowance left behind.
        assertEq(underlying.balanceOf(address(adapter)), 0);
        assertEq(underlying.allowance(address(adapter), address(terminal)), 0);
    }

    function test_compoundRevertsBelowMinimum() public {
        _enable(10e6, 1 days);
        distributor.setCollectable(9e6);
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector, 9e6, 10e6));
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_compoundNormalizes18DecimalMint() public {
        _setUpWithDecimals(18);
        _enable(1e18, 1 days);
        distributor.setCollectable(7e18);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(underlyingAmount, 7e18);
        assertEq(stickyTokenCount, 7e18);
    }

    function test_compoundRevertsOnShortMint() public {
        _enable(1e6, 1 days);
        distributor.setCollectable(5e6);
        terminal.setShortfall(1);
        // The terminal's own min-returned-tokens floor trips first; the adapter's expected count is the floor.
        vm.expectRevert("UnderMinReturnedTokens");
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_compoundRevertsOnFeeOnTransferToken() public {
        _enable(1e6, 1 days);
        distributor.setCollectable(5e6);
        underlying.setFeeBps(100);
        vm.expectRevert(); // UnexpectedTokenDelta — the adapter receives less than it pulled
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_beginVestingRequiresEnabledConfig() public {
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Disabled.selector, PROJECT_ID, holder)
        );
        adapter.beginVestingFor(PROJECT_ID, holder);

        _enable(1e6, 1 days);
        adapter.beginVestingFor(PROJECT_ID, holder);
        assertEq(distributor.beginVestingCalls(), 1);
        assertEq(distributor.lastBeginVestingHook(), stickyToken);
        assertEq(distributor.lastBeginVestingTokenId(), uint256(uint160(holder)));
    }

    function test_compoundRejectsZeroIssuanceBeforeCollection() public {
        _setUpWithDecimals(24);
        _enable(1, 1 days);
        underlying.mint(holder, 123);
        distributor.setCollectable(999_999);
        vm.mockCallRevert(
            address(distributor),
            abi.encodeWithSignature("collectVestedRewards(address,uint256[],address[],address)"),
            "collection must not be reached"
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, PROJECT_ID, 999_999)
        );
        adapter.compoundFor(PROJECT_ID, holder);

        assertEq(distributor.collectable(), 999_999);
        assertEq(distributor.collectionCalls(), 0);
        assertEq(underlying.balanceOf(holder), 123);
        assertEq(underlying.balanceOf(address(adapter)), 0);
        assertEq(underlying.balanceOf(address(terminal)), 0);
        assertEq(underlying.allowance(address(adapter), address(terminal)), 0);
        (,, uint48 lastCompoundedAt,) = adapter.configOf(PROJECT_ID, holder);
        assertEq(lastCompoundedAt, 0);
    }

    function test_stickRewardsRejectsZeroIssuanceBeforeCollection() public {
        _setUpWithDecimals(24);
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        distributor.setCollectable(999_999);

        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, PROJECT_ID, 999_999)
        );
        vm.prank(holder);
        adapter.stickRewardsFor(PROJECT_ID);
        assertEq(distributor.collectable(), 999_999);
        assertEq(underlying.balanceOf(holder), 0);
        assertEq(underlying.balanceOf(address(terminal)), 0);
    }

    function test_compoundRechecksActualDeliveredIssuanceBeforePull() public {
        _setUpWithDecimals(24);
        _enable(1, 1 days);
        distributor.setCollectable(1e6);
        distributor.setDeliveryOverride(999_999);
        vm.mockCallRevert(
            address(underlying),
            abi.encodeCall(IERC20.transferFrom, (holder, address(adapter), 999_999)),
            "pull must not be reached"
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, PROJECT_ID, 999_999)
        );
        adapter.compoundFor(PROJECT_ID, holder);
        assertEq(distributor.collectable(), 1e6);
        assertEq(underlying.balanceOf(holder), 0);
        assertEq(underlying.balanceOf(address(terminal)), 0);
    }

    function test_compoundQuotesAndPullsOnlyTheActualDelivery() public {
        _enable(1, 1 days);
        underlying.mint(holder, 10e6);
        distributor.setCollectable(5e6);
        distributor.setDeliveryOverride(3e6);
        (uint256 amount, uint256 count) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(amount, 3e6);
        assertEq(count, 3e18);
        assertEq(terminal.lastMinimum(), 3e18);
        assertEq(underlying.balanceOf(holder), 10e6);
        assertEq(underlying.balanceOf(address(adapter)), 0);
        assertEq(underlying.balanceOf(address(terminal)), 3e6);
    }

    function test_compoundAcceptsSmallestPositive24DecimalIssuance() public {
        _setUpWithDecimals(24);
        _enable(1, 1 days);
        distributor.setCollectable(1e6);
        (uint256 amount, uint256 count) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(amount, 1e6);
        assertEq(count, 1);
        assertEq(terminal.lastMinimum(), 1);
        assertEq(underlying.allowance(address(adapter), address(terminal)), 0);
    }

    function test_compoundUsesCurrentSharePriceAndCanonicalBeneficiary() public {
        _enable(1, 1 days);
        distributor.setCollectable(10e6);
        terminal.setSharePrice(2);
        vm.prank(keeper);
        (uint256 amount, uint256 count) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(amount, 10e6);
        assertEq(count, 5e18);
        assertEq(terminal.lastMinimum(), 5e18);
        assertEq(terminal.lastProjectId(), PROJECT_ID);
        assertEq(terminal.lastPayer(), address(adapter));
        assertEq(terminal.lastBeneficiary(), holder);
        assertEq(distributor.lastBeneficiary(), holder);
        assertEq(underlying.balanceOf(keeper), 0);
    }

    function test_compoundRejectsPriceRoundingToZeroWith18Decimals() public {
        _setUpWithDecimals(18);
        _enable(1, 1 days);
        distributor.setCollectable(1);
        terminal.setSharePrice(2);
        (JBAutoStickStatus status,,,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), 7);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, PROJECT_ID, 1)
        );
        adapter.compoundFor(PROJECT_ID, holder);
    }

    function test_compoundRejectsShortMintEvenIfTerminalIgnoresMinimum() public {
        _enable(1, 1 days);
        distributor.setCollectable(5e6);
        terminal.setShortfall(1);
        terminal.setIgnoreMinimum(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyAutoStick.JBStickyAutoStick_InsufficientStickyTokens.selector, 5e18 - 1, 5e18
            )
        );
        adapter.compoundFor(PROJECT_ID, holder);
        assertEq(distributor.collectable(), 5e6);
        assertEq(underlying.balanceOf(address(terminal)), 0);
        assertEq(underlying.allowance(address(adapter), address(terminal)), 0);
    }

    //*********************************************************************//
    // ------------------------- one-click claim ------------------------- //
    //*********************************************************************//

    function test_stickRewardsNeedsNoConfig() public {
        // No setConfigFor, no cooldown, no minimum — the holder's own call is the consent.
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        distributor.setCollectable(3e6);
        vm.prank(holder);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.stickRewardsFor(PROJECT_ID);
        assertEq(underlyingAmount, 3e6);
        assertEq(stickyTokenCount, 3e18);
        assertEq(underlying.balanceOf(address(adapter)), 0);

        // Immediately again — no cooldown for holder-initiated claims.
        distributor.setCollectable(2e6);
        vm.prank(holder);
        (underlyingAmount,) = adapter.stickRewardsFor(PROJECT_ID);
        assertEq(underlyingAmount, 2e6);
    }

    function test_stickRewardsUsesCallerAsHolder() public {
        // A third party calling sticks THEIR OWN (empty) rewards — they cannot touch the holder's.
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        distributor.setCollectable(3e6);
        vm.mockCall(
            hook,
            abi.encodeCall(IJBStickyHook.isTrustedSenderOf, (PROJECT_ID, keeper, address(adapter))),
            abi.encode(true)
        );
        vm.prank(keeper);
        vm.expectRevert(); // keeper has no allowance set; their claim path is their own, not the holder's
        adapter.stickRewardsFor(PROJECT_ID);
        assertEq(underlying.balanceOf(holder), 0);
    }

    function test_stickRewardsRevertsWithNothingClaimable() public {
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector, 0, 1));
        vm.prank(holder);
        adapter.stickRewardsFor(PROJECT_ID);
    }

    function test_stickRewardsWorksThroughGranterStatus() public {
        _mockTrust(false);
        _mockGranter(true);
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        distributor.setCollectable(3e6);
        vm.prank(holder);
        (uint256 underlyingAmount,) = adapter.stickRewardsFor(PROJECT_ID);
        assertEq(underlyingAmount, 3e6);
    }

    function test_stickRewardsRevertsWithoutTrustOrGranter() public {
        _mockTrust(false);
        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        distributor.setCollectable(3e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector, PROJECT_ID, holder)
        );
        vm.prank(holder);
        adapter.stickRewardsFor(PROJECT_ID);
    }

    //*********************************************************************//
    // --------------------------- cooldown ------------------------------ //
    //*********************************************************************//

    function test_cooldownBlocksAndBoundarySucceeds() public {
        _enable(1e6, 1 days);
        distributor.setCollectable(5e6);
        adapter.compoundFor(PROJECT_ID, holder);

        distributor.setCollectable(5e6);
        uint256 availableAt = block.timestamp + 1 days;
        vm.warp(availableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Cooldown.selector, availableAt));
        adapter.compoundFor(PROJECT_ID, holder);

        vm.warp(availableAt);
        (uint256 underlyingAmount,) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(underlyingAmount, 5e6);
    }

    //*********************************************************************//
    // ---------------------------- statusOf ------------------------------ //
    //*********************************************************************//

    function test_statusOrdinalsRemainCompatibleWithClients() public pure {
        assertEq(uint256(JBAutoStickStatus.Ready), 0);
        assertEq(uint256(JBAutoStickStatus.Disabled), 1);
        assertEq(uint256(JBAutoStickStatus.InvalidProject), 2);
        assertEq(uint256(JBAutoStickStatus.Cooldown), 3);
        assertEq(uint256(JBAutoStickStatus.BelowMinimum), 4);
        assertEq(uint256(JBAutoStickStatus.NotTrusted), 5);
        assertEq(uint256(JBAutoStickStatus.InsufficientAllowance), 6);
        assertEq(uint256(JBAutoStickStatus.ZeroIssuance), 7);
    }

    function test_statusOfWalksTheLadder() public {
        vm.mockCall(deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (99)), abi.encode(address(0)));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (99)), abi.encode(address(0)));
        (JBAutoStickStatus status,,,) = adapter.statusOf(99, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.InvalidProject));

        (status,,,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.Disabled));

        _enable(10e6, 1 days);
        distributor.setCollectable(5e6);
        (status,,,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.BelowMinimum));

        distributor.setCollectable(20e6);
        _mockTrust(false);
        (status,,,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.NotTrusted));

        _mockTrust(true);
        vm.prank(holder);
        underlying.approve(address(adapter), 1e6);
        (status,,,) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.InsufficientAllowance));

        vm.prank(holder);
        underlying.approve(address(adapter), type(uint256).max);
        (JBAutoStickStatus ready, uint256 collectable, uint256 allowance, uint256 nextCompoundAt) =
            adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(ready), uint256(JBAutoStickStatus.Ready));
        assertEq(collectable, 20e6);
        assertEq(allowance, type(uint256).max);
        assertEq(nextCompoundAt, 0);

        adapter.compoundFor(PROJECT_ID, holder);
        (status,,, nextCompoundAt) = adapter.statusOf(PROJECT_ID, holder);
        assertEq(uint256(status), uint256(JBAutoStickStatus.Cooldown));
        assertEq(nextCompoundAt, block.timestamp + 1 days);
    }

    //*********************************************************************//
    // ------------------------------ fuzz -------------------------------- //
    //*********************************************************************//

    function testFuzz_compoundNormalizesAcrossAmounts(uint256 amount, uint256 preExisting) public {
        amount = bound(amount, 1e6, 1e32);
        preExisting = bound(preExisting, 0, 1e32);
        _enable(1e6, 1 days);
        underlying.mint(holder, preExisting);
        distributor.setCollectable(amount);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = adapter.compoundFor(PROJECT_ID, holder);
        assertEq(underlyingAmount, amount);
        assertEq(stickyTokenCount, amount * 1e12);
        assertEq(underlying.balanceOf(holder), preExisting);
        assertEq(underlying.balanceOf(address(adapter)), 0);
    }
}
