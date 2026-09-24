// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

import {JBStickyAutoStick} from "../src/JBStickyAutoStick.sol";

import {JBAutoStickStatus} from "../src/enums/JBAutoStickStatus.sol";

import {IJBStickyAutoStick} from "../src/interfaces/IJBStickyAutoStick.sol";
import {IJBStickyDeployer} from "../src/interfaces/IJBStickyDeployer.sol";
import {IJBStickyDistributor} from "../src/interfaces/IJBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";

/// @notice A mintable test token with configurable decimals and an optional transfer fee.
// forge-lint: disable-next-line(multi-contract-file)
contract MockToken is ERC20 {
    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The number of decimals the token reports.
    uint8 internal immutable _DECIMALS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The fee taken out of every transfer, in basis points, when non-zero.
    uint256 public feeBps;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Deploys the token with the given number of decimals.
    /// @param tokenDecimals The number of decimals the token reports.
    constructor(uint8 tokenDecimals) ERC20("Mock", "MOCK") {
        _DECIMALS = tokenDecimals;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Mints tokens to an account.
    /// @param to The account to mint to.
    /// @param amount The amount to mint.
    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }

    /// @notice Sets the fee taken out of every transfer.
    /// @param bps The fee in basis points.
    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The number of decimals the token uses.
    /// @return tokenDecimals The number of decimals.
    function decimals() public view override returns (uint8 tokenDecimals) {
        return _DECIMALS;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Moves tokens, burning the configured fee out of every transfer between accounts.
    /// @param from The account tokens move from.
    /// @param to The account tokens move to.
    /// @param value The amount moved before the fee.
    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        if (fee != 0 && from != address(0) && to != address(0)) {
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Delivers a configured per-group collectable amount to the beneficiary on collection.
// forge-lint: disable-next-line(multi-contract-file)
contract StubDistributor {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The number of `beginVesting` calls received.
    uint256 public beginVestingCalls;

    /// @notice The collectable amount configured for each group.
    /// @custom:param groupId The ID of the reward group.
    mapping(uint256 groupId => uint256) public collectableOf;

    /// @notice The group IDs passed to `beginVesting` and `collectVestedRewards`, in call order.
    uint256[] public collectedGroupIds;

    /// @notice The number of `collectVestedRewards` calls received.
    uint256 public collectionCalls;

    /// @notice The amount delivered on the next collection instead of the configured collectable.
    uint256 public deliveryOverride;

    /// @notice Whether the next collection delivers `deliveryOverride`.
    bool public hasDeliveryOverride;

    /// @notice The hook passed to the last `beginVesting` call.
    address public lastBeginVestingHook;

    /// @notice The first token ID passed to the last `beginVesting` call.
    uint256 public lastBeginVestingTokenId;

    /// @notice The beneficiary of the last collection.
    address public lastBeneficiary;

    /// @notice The token delivered on collection.
    MockToken public token;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Deploys the stub delivering the given token.
    /// @param rewardToken The token delivered on collection.
    constructor(MockToken rewardToken) {
        token = rewardToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Records a vesting start for the first token ID.
    /// @param hook The sticky token whose rewards vest.
    /// @param groupId The ID of the reward group.
    /// @param tokenIds The IDs of the positions to vest.
    // forge-lint: disable-next-line(missing-zero-check)
    function beginVesting(address hook, uint256 groupId, uint256[] calldata tokenIds, IERC20[] calldata) external {
        beginVestingCalls++;
        lastBeginVestingHook = hook;
        lastBeginVestingTokenId = tokenIds[0];
        collectedGroupIds.push(groupId);
    }

    /// @notice Mints the group's collectable amount (or the delivery override) to the beneficiary.
    /// @param groupId The ID of the reward group.
    /// @param beneficiary The account receiving the rewards.
    function collectVestedRewards(
        address,
        uint256 groupId,
        uint256[] calldata,
        IERC20[] calldata,
        // forge-lint: disable-next-line(missing-zero-check)
        address beneficiary
    )
        external
    {
        collectionCalls++;
        lastBeneficiary = beneficiary;
        collectedGroupIds.push(groupId);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        token.mint(beneficiary, hasDeliveryOverride ? deliveryOverride : collectableOf[groupId]);
        collectableOf[groupId] = 0;
        hasDeliveryOverride = false;
    }

    /// @notice Sets the default group's collectable amount.
    /// @param amount The collectable amount.
    function setCollectable(uint256 amount) external {
        collectableOf[0] = amount;
    }

    /// @notice Sets a group's collectable amount.
    /// @param groupId The ID of the reward group.
    /// @param amount The collectable amount.
    function setCollectableFor(uint256 groupId, uint256 amount) external {
        collectableOf[groupId] = amount;
    }

    /// @notice Makes the next collection deliver a different amount than the configured collectable.
    /// @param amount The amount to deliver.
    function setDeliveryOverride(uint256 amount) external {
        deliveryOverride = amount;
        hasDeliveryOverride = true;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The default group's collectable amount.
    /// @return amount The collectable amount.
    function collectable() external view returns (uint256 amount) {
        return collectableOf[0];
    }

    /// @notice The collectable amount for a group.
    /// @param groupId The ID of the reward group.
    /// @return amount The collectable amount.
    function collectableFor(address, uint256 groupId, uint256, IERC20) external view returns (uint256 amount) {
        return collectableOf[groupId];
    }

    /// @notice Mirrors the Sticky distributor's group rule: 0, or `minWeeks * 1000 + maxWeeks` within bounds.
    /// @param groupId The ID of the reward group.
    /// @return isValid Whether the group ID is valid.
    function isValidGroupId(uint256 groupId) external pure returns (bool isValid) {
        if (groupId == 0) return true;
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 minWeeks = groupId / 1000;
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 maxWeeks = groupId % 1000;
        // forge-lint: disable-next-line(literal-instead-of-constant)
        return minWeeks != 0 && minWeeks <= 520 && maxWeeks <= 520 && (maxWeeks == 0 || maxWeeks >= minWeeks);
    }
}

/// @notice Models canonical terminal previews and payments, with configurable share pricing and short mints.
// forge-lint: disable-next-line(locked-ether,multi-contract-file)
contract StubTerminal {
    // A library that safely pulls the payment token.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Whether `pay` skips its own minimum-returned-tokens check.
    bool public ignoreMinimum;

    /// @notice The beneficiary of the last payment.
    address public lastBeneficiary;

    /// @notice The minimum returned tokens requested by the last payment.
    uint256 public lastMinimum;

    /// @notice The sender of the last payment.
    address public lastPayer;

    /// @notice The project ID of the last payment.
    uint256 public lastProjectId;

    /// @notice The number of 18-decimal payment units per share.
    uint256 public sharePrice = 1;

    /// @notice The amount shaved off the returned mint when non-zero, to test the mint floor.
    uint256 public shortfall;

    /// @notice The token the terminal accepts.
    MockToken public token;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Deploys the stub accepting the given token.
    /// @param paymentToken The token the terminal accepts.
    constructor(MockToken paymentToken) {
        token = paymentToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Pulls the payment and returns the quoted share count minus any configured shortfall.
    /// @param projectId The ID of the project paid.
    /// @param paymentToken The token paid.
    /// @param amount The amount paid.
    /// @param beneficiary The account receiving the shares.
    /// @param minReturnedTokens The minimum share count the payer accepts.
    /// @return count The number of shares returned.
    function pay(
        uint256 projectId,
        address paymentToken,
        uint256 amount,
        // forge-lint: disable-next-line(missing-zero-check)
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 count)
    {
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        count = _quote(amount) - shortfall;
        if (!ignoreMinimum) require(count >= minReturnedTokens, "UnderMinReturnedTokens");
        lastProjectId = projectId;
        lastMinimum = minReturnedTokens;
        lastPayer = msg.sender;
        lastBeneficiary = beneficiary;
    }

    /// @notice Sets whether `pay` skips its own minimum-returned-tokens check.
    /// @param shouldIgnore Whether to skip the check.
    function setIgnoreMinimum(bool shouldIgnore) external {
        ignoreMinimum = shouldIgnore;
    }

    /// @notice Sets the number of 18-decimal payment units per share.
    /// @param price The share price.
    function setSharePrice(uint256 price) external {
        sharePrice = price;
    }

    /// @notice Sets the amount shaved off every returned mint.
    /// @param amount The shortfall.
    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Quotes the shares a payment would return, without any shortfall.
    /// @param amount The amount paid.
    /// @return ruleset An empty ruleset.
    /// @return beneficiaryTokenCount The number of shares the beneficiary would receive.
    /// @return reservedTokenCount Always zero.
    /// @return hookSpecifications An empty list.
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
        return (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications);
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Converts a payment amount into 18-decimal shares at the current share price.
    /// @param amount The amount paid.
    /// @return count The number of shares.
    function _quote(uint256 amount) internal view returns (uint256 count) {
        count = JBFixedPointNumber.adjustDecimals({value: amount, decimals: token.decimals(), targetDecimals: 18})
            / sharePrice;
    }
}

/// @notice The auto-stick adapter against a stub distributor, a stub terminal, and mocked deployer and hook reads.
// forge-lint: disable-next-line(multi-contract-file)
contract JBStickyAutoStickUnitTest is Test {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID of the sticky project the tests use.
    uint256 internal constant _PROJECT_ID = 7;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The adapter under test.
    JBStickyAutoStick internal _adapter;

    /// @notice The mocked Sticky factory address.
    // forge-lint: disable-next-line(function-init-state)
    address internal _deployer = makeAddr("deployer");

    /// @notice The stub distributor delivering rewards.
    StubDistributor internal _distributor;

    /// @notice The holder whose rewards are compounded.
    // forge-lint: disable-next-line(function-init-state)
    address internal _holder = makeAddr("holder");

    /// @notice The mocked sticky hook address.
    // forge-lint: disable-next-line(function-init-state)
    address internal _hook = makeAddr("hook");

    /// @notice A third-party keeper who triggers compounds.
    // forge-lint: disable-next-line(function-init-state)
    address internal _keeper = makeAddr("keeper");

    /// @notice The mocked sticky token address.
    // forge-lint: disable-next-line(function-init-state)
    address internal _stickyToken = makeAddr("stickyToken");

    /// @notice The stub terminal receiving payments.
    StubTerminal internal _terminal;

    /// @notice The mocked tokens registry address.
    // forge-lint: disable-next-line(function-init-state)
    address internal _tokens = makeAddr("tokens");

    /// @notice The underlying token staked into the project.
    MockToken internal _underlying;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(6);
    }

    function test_beginVestingCoversEveryRequestedGroup() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        vm.expectEmit();
        // forge-lint: disable-next-item(reentrancy-events)
        emit IJBStickyAutoStick.BeganAutoStickVesting(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _PROJECT_ID,
            _holder,
            address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _groups(0, 4000),
            _keeper
        );
        vm.prank(_keeper);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.beginVestingFor(_PROJECT_ID, _holder, _groups(0, 4000));
        assertEq(_distributor.beginVestingCalls(), 2);
        assertEq(_distributor.collectedGroupIds(0), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.collectedGroupIds(1), 4000);
    }

    function test_beginVestingRequiresEnabledConfig() public {
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Disabled.selector, _PROJECT_ID, _holder)
        );
        _adapter.beginVestingFor(_PROJECT_ID, _holder, _group0());

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        _adapter.beginVestingFor(_PROJECT_ID, _holder, _group0());
        assertEq(_distributor.beginVestingCalls(), 1);
        assertEq(_distributor.lastBeginVestingHook(), _stickyToken);
        assertEq(_distributor.lastBeginVestingTokenId(), uint256(uint160(_holder)));
    }

    function test_compoundAcceptsSmallestPositive24DecimalIssuance() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(24);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(1e6);
        (uint256 amount, uint256 count) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 1e6);
        assertEq(count, 1);
        assertEq(_terminal.lastMinimum(), 1);
        assertEq(_underlying.allowance(address(_adapter), address(_terminal)), 0);
    }

    function test_compoundNormalizes18DecimalMint() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e18, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(7e18);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 7e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(stickyTokenCount, 7e18);
    }

    function test_compoundPullsExactlyTheCollectedAmount() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // The pre-existing balance stays untouched.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _underlying.mint(_holder, 100e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);

        vm.expectEmit();
        // forge-lint: disable-next-line(literal-instead-of-constant,reentrancy-events)
        emit IJBStickyAutoStick.AutoStuck(_PROJECT_ID, _holder, address(_underlying), _group0(), 5e6, 5e18, _keeper);
        vm.prank(_keeper);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());

        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(stickyTokenCount, 5e18);
        // The holder keeps their pre-existing balance; the collected reward moved through to the terminal.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(_holder), 100e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(address(_terminal)), 5e6);
        // No custody or allowance left behind.
        assertEq(_underlying.balanceOf(address(_adapter)), 0);
        assertEq(_underlying.allowance(address(_adapter), address(_terminal)), 0);
    }

    function test_compoundQuotesAndPullsOnlyTheActualDelivery() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _underlying.mint(_holder, 10e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setDeliveryOverride(3e6);
        (uint256 amount, uint256 count) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 3e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(count, 3e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_terminal.lastMinimum(), 3e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(_holder), 10e6);
        assertEq(_underlying.balanceOf(address(_adapter)), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(address(_terminal)), 3e6);
    }

    function test_compoundRechecksActualDeliveredIssuanceBeforePull() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(24);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(1e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setDeliveryOverride(999_999);
        vm.mockCallRevert(
            address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeCall(IERC20.transferFrom, (_holder, address(_adapter), 999_999)),
            "pull must not be reached"
        );

        vm.expectRevert(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, _PROJECT_ID, 999_999)
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.collectable(), 1e6);
        assertEq(_underlying.balanceOf(_holder), 0);
        assertEq(_underlying.balanceOf(address(_terminal)), 0);
    }

    function test_compoundRejectsPriceRoundingToZeroWith18Decimals() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        _distributor.setCollectable(1);
        _terminal.setSharePrice(2);
        // forge-lint: disable-next-line(unused-return)
        (JBAutoStickStatus status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(uint256(status), 7);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, _PROJECT_ID, 1)
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundRejectsShortMintEvenIfTerminalIgnoresMinimum() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        _terminal.setShortfall(1);
        _terminal.setIgnoreMinimum(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                JBStickyAutoStick.JBStickyAutoStick_InsufficientStickyTokens.selector,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                5e18 - 1,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                5e18
            )
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.collectable(), 5e6);
        assertEq(_underlying.balanceOf(address(_terminal)), 0);
        assertEq(_underlying.allowance(address(_adapter), address(_terminal)), 0);
    }

    function test_compoundRejectsZeroIssuanceBeforeCollection() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(24);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _underlying.mint(_holder, 123);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(999_999);
        vm.mockCallRevert(
            address(_distributor),
            abi.encodeWithSignature("collectVestedRewards(address,uint256,uint256[],address[],address)"),
            "collection must not be reached"
        );

        vm.expectRevert(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, _PROJECT_ID, 999_999)
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());

        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.collectable(), 999_999);
        assertEq(_distributor.collectionCalls(), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(_holder), 123);
        assertEq(_underlying.balanceOf(address(_adapter)), 0);
        assertEq(_underlying.balanceOf(address(_terminal)), 0);
        assertEq(_underlying.allowance(address(_adapter), address(_terminal)), 0);
        // forge-lint: disable-next-line(unused-return)
        (,, uint48 lastCompoundedAt,) = _adapter.configOf(_PROJECT_ID, _holder);
        assertEq(lastCompoundedAt, 0);
    }

    function test_compoundRevertsBelowMinimum() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(10e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(9e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector, 9e6, 10e6));
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundRevertsOnFeeOnTransferToken() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        _underlying.setFeeBps(100);
        // The adapter receives less than it pulled, so it reverts with an unexpected token delta.
        vm.expectRevert();
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundRevertsOnShortMint() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        _terminal.setShortfall(1);
        // The terminal's own min-returned-tokens floor trips first; the adapter's expected count is the floor.
        vm.expectRevert("UnderMinReturnedTokens");
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundRevertsOnUnknownProject() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (99)), abi.encode(address(0)));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(_tokens, abi.encodeCall(IJBTokens.tokenOf, (99)), abi.encode(address(0)));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidProject.selector, 99));
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _adapter.compoundFor(99, _holder, _group0());
    }

    function test_compoundRevertsWhenDisabled() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Disabled.selector, _PROJECT_ID, _holder)
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundRevertsWithoutAllowance() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _underlying.approve(address(_adapter), 3e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        vm.expectRevert(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InsufficientAllowance.selector, 3e6, 5e6)
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundRevertsWithoutTrust() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        _mockTrust(false);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector, _PROJECT_ID, _holder)
        );
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
    }

    function test_compoundUsesCurrentSharePriceAndCanonicalBeneficiary() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(10e6);
        _terminal.setSharePrice(2);
        vm.prank(_keeper);
        (uint256 amount, uint256 count) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(count, 5e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_terminal.lastMinimum(), 5e18);
        assertEq(_terminal.lastProjectId(), _PROJECT_ID);
        assertEq(_terminal.lastPayer(), address(_adapter));
        assertEq(_terminal.lastBeneficiary(), _holder);
        assertEq(_distributor.lastBeneficiary(), _holder);
        assertEq(_underlying.balanceOf(_keeper), 0);
    }

    function test_cooldownBlocksAndBoundarySucceeds() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 availableAt = block.timestamp + 1 days;
        vm.warp(availableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_Cooldown.selector, availableAt));
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());

        vm.warp(availableAt);
        // forge-lint: disable-next-line(unused-return)
        (uint256 underlyingAmount,) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 5e6);
    }

    function test_disablePreservesLastCompoundedAt() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(unused-return)
        (,, uint48 lastCompoundedAt,) = _adapter.configOf(_PROJECT_ID, _holder);
        assertEq(lastCompoundedAt, block.timestamp);

        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: false, minimumAmount: 1e6, cooldown: 1 days});
        // forge-lint: disable-next-line(unused-return)
        (,, uint48 kept, bool enabled) = _adapter.configOf(_PROJECT_ID, _holder);
        assertEq(kept, lastCompoundedAt);
        assertFalse(enabled);
    }

    function test_emptyGroupIdsRevertOnEveryEntryPoint() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        uint256[] memory none = new uint256[](0);
        bytes memory expected = abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_EmptyGroupIds.selector, 0);

        vm.expectRevert(expected);
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, none);
        vm.expectRevert(expected);
        _adapter.beginVestingFor(_PROJECT_ID, _holder, none);
        vm.expectRevert(expected);
        // forge-lint: disable-next-line(unused-return)
        _adapter.statusOf(_PROJECT_ID, _holder, none);
        vm.expectRevert(expected);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _adapter.stickRewardsFor(_PROJECT_ID, none);
    }

    function test_finiteAllowanceCompoundsUntilExhausted() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _underlying.approve(address(_adapter), 5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());

        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(block.timestamp + 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(unused-return)
        (JBAutoStickStatus status,, uint256 allowance,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(allowance, 0);
        assertEq(uint256(status), uint256(JBAutoStickStatus.InsufficientAllowance));
    }

    function test_groupIdsMustBeStrictlyAscendingOnEveryEntryPoint() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[] memory duplicated = _groups(1000, 1000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[] memory descending = _groups(1000, 0);
        bytes memory duplicatedError = abi.encodeWithSelector(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            JBStickyAutoStick.JBStickyAutoStick_GroupIdsNotAscending.selector,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            uint256(1000),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            uint256(1000)
        );
        bytes memory descendingError = abi.encodeWithSelector(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            JBStickyAutoStick.JBStickyAutoStick_GroupIdsNotAscending.selector,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            uint256(1000),
            uint256(0)
        );

        vm.expectRevert(duplicatedError);
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, duplicated);
        vm.expectRevert(descendingError);
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, descending);
        vm.expectRevert(duplicatedError);
        _adapter.beginVestingFor(_PROJECT_ID, _holder, duplicated);
        vm.expectRevert(descendingError);
        // forge-lint: disable-next-line(unused-return)
        _adapter.statusOf(_PROJECT_ID, _holder, descending);
        vm.expectRevert(duplicatedError);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _adapter.stickRewardsFor(_PROJECT_ID, duplicated);

        // The same groups in ascending order are accepted.
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        (JBAutoStickStatus status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _groups(0, 1000));
        assertEq(uint256(status), uint256(JBAutoStickStatus.Ready));
    }

    function test_minimumAppliesToTheCombinedTotal() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(5e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(3e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectableFor(2000, 2e6);

        // forge-lint: disable-next-line(unused-return)
        (JBAutoStickStatus status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.BelowMinimum));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector, 3e6, 5e6));
        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());

        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        (uint256 underlyingAmount,) = _adapter.compoundFor(_PROJECT_ID, _holder, _groups(0, 2000));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 5e6);
    }

    function test_multiGroupCompoundSumsEveryGroupAndCollectsEach() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(3e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectableFor(2000, 2e6);

        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        (JBAutoStickStatus status, uint256 collectable,,) = _adapter.statusOf(_PROJECT_ID, _holder, _groups(0, 2000));
        assertEq(uint256(status), uint256(JBAutoStickStatus.Ready));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(collectable, 5e6);

        vm.expectEmit();
        // forge-lint: disable-next-item(reentrancy-events)
        emit IJBStickyAutoStick.AutoStuck(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _PROJECT_ID,
            _holder,
            address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            _groups(0, 2000),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            5e6,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            5e18,
            _keeper
        );
        vm.prank(_keeper);
        (
            uint256 underlyingAmount,
            uint256 stickyTokenCount
            // forge-lint: disable-next-line(literal-instead-of-constant)
        ) = _adapter.compoundFor(_PROJECT_ID, _holder, _groups(0, 2000));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(stickyTokenCount, 5e18);
        assertEq(_distributor.collectionCalls(), 2);
        assertEq(_distributor.collectedGroupIds(0), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.collectedGroupIds(1), 2000);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(address(_terminal)), 5e6);
        assertEq(_underlying.balanceOf(_holder), 0);
    }

    function test_projectGranterStatusStandsInForTrust() public {
        // A project whose creator pre-approved the adapter as a granter needs no per-holder trust tx.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        _mockTrust(false);
        _mockGranter(true);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(unused-return)
        (JBAutoStickStatus status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.Ready));
        // forge-lint: disable-next-line(unused-return)
        (uint256 underlyingAmount,) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 5e6);
    }

    function test_setConfigOnlyAffectsCaller() public {
        vm.prank(_keeper);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
        // forge-lint: disable-next-line(unused-return)
        (,,, bool enabled) = _adapter.configOf(_PROJECT_ID, _holder);
        assertFalse(enabled);
    }

    function test_setConfigRevertsOnCooldownOutOfRange() public {
        vm.expectRevert(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidCooldown.selector, 1 days - 1)
        );
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: true, minimumAmount: 1e6, cooldown: 1 days - 1});

        vm.expectRevert(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidCooldown.selector, 30 days + 1)
        );
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: true, minimumAmount: 1e6, cooldown: 30 days + 1});
    }

    function test_setConfigRevertsOnUnknownProject() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (99)), abi.encode(address(0)));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(_tokens, abi.encodeCall(IJBTokens.tokenOf, (99)), abi.encode(address(0)));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidProject.selector, 99));
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: 99, enabled: true, minimumAmount: 1e6, cooldown: 1 days});
    }

    function test_setConfigRevertsOnZeroMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidMinimum.selector, 0));
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: true, minimumAmount: 0, cooldown: 1 days});
    }

    function test_setConfigStoresAndEmits() public {
        vm.expectEmit();
        // forge-lint: disable-next-line(literal-instead-of-constant,reentrancy-events)
        emit IJBStickyAutoStick.SetAutoStick(_PROJECT_ID, _holder, true, 5e6, 2 days, _holder);
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: true, minimumAmount: 5e6, cooldown: 2 days});

        (uint128 minimumAmount, uint48 cooldown, uint48 lastCompoundedAt, bool enabled) =
            _adapter.configOf(_PROJECT_ID, _holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(minimumAmount, 5e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(cooldown, 2 days);
        assertEq(lastCompoundedAt, 0);
        assertTrue(enabled);
    }

    function test_statusOfRejectsGroupsTheDistributorCannotServe() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);

        // Group 7 has no `minWeeks`, so the distributor would reject its collection while quoting nothing for it.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_InvalidGroupId.selector, 7));
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _adapter.statusOf(_PROJECT_ID, _holder, _groups(0, 7));

        // Every valid group encoding passes the check.
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        (JBAutoStickStatus status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _groups(1000, 520_520));
        assertEq(uint256(status), uint256(JBAutoStickStatus.BelowMinimum));
    }

    function test_statusOfWalksTheLadder() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (99)), abi.encode(address(0)));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(_tokens, abi.encodeCall(IJBTokens.tokenOf, (99)), abi.encode(address(0)));
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        (JBAutoStickStatus status,,,) = _adapter.statusOf(99, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.InvalidProject));

        // forge-lint: disable-next-line(unused-return)
        (status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.Disabled));

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(10e6, 1 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(5e6);
        // forge-lint: disable-next-line(unused-return)
        (status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.BelowMinimum));

        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(20e6);
        _mockTrust(false);
        // forge-lint: disable-next-line(unused-return)
        (status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.NotTrusted));

        _mockTrust(true);
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _underlying.approve(address(_adapter), 1e6);
        // forge-lint: disable-next-line(unused-return)
        (status,,,) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.InsufficientAllowance));

        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        (JBAutoStickStatus ready, uint256 collectable, uint256 allowance, uint256 nextCompoundAt) =
            _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(ready), uint256(JBAutoStickStatus.Ready));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(collectable, 20e6);
        assertEq(allowance, type(uint256).max);
        assertEq(nextCompoundAt, 0);

        // forge-lint: disable-next-line(unused-return)
        _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        // forge-lint: disable-next-line(unused-return)
        (status,,, nextCompoundAt) = _adapter.statusOf(_PROJECT_ID, _holder, _group0());
        assertEq(uint256(status), uint256(JBAutoStickStatus.Cooldown));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(nextCompoundAt, block.timestamp + 1 days);
    }

    function test_stickRewardsNeedsNoConfig() public {
        // No setConfigFor, no cooldown, no minimum — the holder's own call is the consent.
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(3e6);
        vm.prank(_holder);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = _adapter.stickRewardsFor(_PROJECT_ID, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 3e6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(stickyTokenCount, 3e18);
        assertEq(_underlying.balanceOf(address(_adapter)), 0);

        // Immediately again — no cooldown for holder-initiated claims.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(2e6);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        (underlyingAmount,) = _adapter.stickRewardsFor(_PROJECT_ID, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 2e6);
    }

    function test_stickRewardsRejectsZeroIssuanceBeforeCollection() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _setUpWithDecimals(24);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(999_999);

        vm.expectRevert(
            // forge-lint: disable-next-line(literal-instead-of-constant)
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, _PROJECT_ID, 999_999)
        );
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _adapter.stickRewardsFor(_PROJECT_ID, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.collectable(), 999_999);
        assertEq(_underlying.balanceOf(_holder), 0);
        assertEq(_underlying.balanceOf(address(_terminal)), 0);
    }

    function test_stickRewardsRevertsWithNothingClaimable() public {
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector, 0, 1));
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _adapter.stickRewardsFor(_PROJECT_ID, _group0());
    }

    function test_stickRewardsRevertsWithoutTrustOrGranter() public {
        _mockTrust(false);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(3e6);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_NotTrusted.selector, _PROJECT_ID, _holder)
        );
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _adapter.stickRewardsFor(_PROJECT_ID, _group0());
    }

    function test_stickRewardsUsesCallerAsHolder() public {
        // A third party calling sticks THEIR OWN (empty) rewards — they cannot touch the holder's.
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(3e6);
        vm.mockCall(
            _hook,
            abi.encodeCall(IJBStickyHook.isTrustedSenderOf, (_PROJECT_ID, _keeper, address(_adapter))),
            abi.encode(true)
        );
        vm.prank(_keeper);
        // The keeper has no allowance set; their claim path is their own, not the holder's.
        vm.expectRevert();
        // forge-lint: disable-next-line(unused-return)
        _adapter.stickRewardsFor(_PROJECT_ID, _group0());
        assertEq(_underlying.balanceOf(_holder), 0);
    }

    function test_stickRewardsWorksThroughGranterStatus() public {
        _mockTrust(false);
        _mockGranter(true);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _distributor.setCollectable(3e6);
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        (uint256 underlyingAmount,) = _adapter.stickRewardsFor(_PROJECT_ID, _group0());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(underlyingAmount, 3e6);
    }

    function testFuzz_compoundNormalizesAcrossAmounts(uint256 amount, uint256 preExisting) public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        amount = bound(amount, 1e6, 1e32);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        preExisting = bound(preExisting, 0, 1e32);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _enable(1e6, 1 days);
        _underlying.mint(_holder, preExisting);
        _distributor.setCollectable(amount);
        (uint256 underlyingAmount, uint256 stickyTokenCount) = _adapter.compoundFor(_PROJECT_ID, _holder, _group0());
        assertEq(underlyingAmount, amount);
        assertEq(stickyTokenCount, amount * 1e12);
        assertEq(_underlying.balanceOf(_holder), preExisting);
        assertEq(_underlying.balanceOf(address(_adapter)), 0);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function test_statusOrdinalsRemainCompatibleWithClients() public pure {
        assertEq(uint256(JBAutoStickStatus.Ready), 0);
        assertEq(uint256(JBAutoStickStatus.Disabled), 1);
        assertEq(uint256(JBAutoStickStatus.InvalidProject), 2);
        assertEq(uint256(JBAutoStickStatus.Cooldown), 3);
        assertEq(uint256(JBAutoStickStatus.BelowMinimum), 4);
        assertEq(uint256(JBAutoStickStatus.NotTrusted), 5);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(uint256(JBAutoStickStatus.InsufficientAllowance), 6);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(uint256(JBAutoStickStatus.ZeroIssuance), 7);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Enables auto-stick for the holder with the default happy-path setup: config on, trust mocked on,
    /// unlimited allowance.
    /// @param minimumAmount The minimum reward amount worth compounding.
    /// @param cooldown The minimum seconds between keeper compounds.
    function _enable(uint128 minimumAmount, uint48 cooldown) internal {
        vm.prank(_holder);
        _adapter.setConfigFor({projectId: _PROJECT_ID, enabled: true, minimumAmount: minimumAmount, cooldown: cooldown});
        vm.prank(_holder);
        // forge-lint: disable-next-line(unused-return)
        _underlying.approve(address(_adapter), type(uint256).max);
    }

    /// @notice Mocks whether the hook treats the adapter as a project granter.
    /// @param granter Whether the adapter is a granter.
    function _mockGranter(bool granter) internal {
        vm.mockCall(
            _hook, abi.encodeCall(IJBStickyHook.isGranterOf, (_PROJECT_ID, address(_adapter))), abi.encode(granter)
        );
    }

    /// @notice Mocks whether the holder trusts the adapter on the hook.
    /// @param trusted Whether the adapter is trusted.
    function _mockTrust(bool trusted) internal {
        vm.mockCall(
            _hook,
            abi.encodeCall(IJBStickyHook.isTrustedSenderOf, (_PROJECT_ID, _holder, address(_adapter))),
            abi.encode(trusted)
        );
    }

    /// @notice Deploys the underlying token, stubs, and adapter for a project whose underlying has the given
    /// decimals, and mocks the deployer, tokens registry, and hook reads.
    /// @param decimals The underlying token's decimals.
    function _setUpWithDecimals(uint8 decimals) internal {
        _underlying = new MockToken(decimals);
        _distributor = new StubDistributor(_underlying);
        _terminal = new StubTerminal(_underlying);

        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.HOOK, ()), abi.encode(_hook));
        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.TOKENS, ()), abi.encode(_tokens));
        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.TERMINAL, ()), abi.encode(address(_terminal)));
        _adapter = new JBStickyAutoStick({
            deployer: IJBStickyDeployer(_deployer), distributor: IJBStickyDistributor(address(_distributor))
        });

        vm.mockCall(_deployer, abi.encodeCall(IJBStickyDeployer.stakedTokenOf, (_PROJECT_ID)), abi.encode(_underlying));
        vm.mockCall(_tokens, abi.encodeCall(IJBTokens.tokenOf, (_PROJECT_ID)), abi.encode(_stickyToken));
        _mockTrust(true);
        _mockGranter(false);
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Builds the group list holding only the default reward group.
    /// @return groupIds A single-entry list containing group 0.
    function _group0() internal pure returns (uint256[] memory groupIds) {
        groupIds = new uint256[](1);
    }

    /// @notice Builds a two-entry group list.
    /// @param first The first group ID.
    /// @param second The second group ID.
    /// @return groupIds The two group IDs in order.
    function _groups(uint256 first, uint256 second) internal pure returns (uint256[] memory groupIds) {
        groupIds = new uint256[](2);
        groupIds[0] = first;
        groupIds[1] = second;
    }
}
