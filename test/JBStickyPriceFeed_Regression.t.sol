// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyHook} from "../src/JBStickyHook.sol";
import {JBStickyPriceFeed} from "../src/JBStickyPriceFeed.sol";

import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";

import {JBStickyPricingToken} from "./helpers/JBStickyPricingToken.sol";
import {JBStickyTestPriceFeed} from "./helpers/JBStickyTestPriceFeed.sol";

/// @notice Real core pricing registers and preserves Sticky's exact, immutable share-issuance denominator.
contract JBStickyPriceFeedRegressionTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The project creation fee cached before tests install expected reverts.
    uint256 internal _creationFee;

    /// @notice The factory registering each project's exact accounting feed.
    JBStickyDeployer internal _deployer;

    /// @notice The project's exact-denominator feed.
    JBStickyPriceFeed internal _feed;

    /// @notice The account that stakes and donates test underlying tokens.
    address internal _holder = makeAddr("price feed holder");

    /// @notice The hook accounting for share positions and orphaned backing.
    IJBStickyHook internal _hook;

    /// @notice The project used for the ordinary six-decimal feed tests.
    uint256 internal _projectId;

    /// @notice The Sticky share token issued by the project.
    IJBToken internal _token;

    /// @notice The project's six-decimal underlying token.
    JBStickyPricingToken internal _underlying;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Launch a Sticky project through the real controller, terminal, store and price registry.
    function setUp() public override {
        super.setUp();
        _creationFee = jbProjects().creationFee();
        _underlying = new JBStickyPricingToken(6);
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _projectId = _launch(IERC20Metadata(address(_underlying)));
        _feed = JBStickyPriceFeed(address(_deployer.priceFeedOf(_projectId)));
        _hook = _deployer.HOOK();
        _token = jbTokens().tokenOf(_projectId);
        _underlying.mint({account: _holder, amount: 200e6});
        vm.prank(_holder);
        _underlying.approve({spender: address(jbMultiTerminal()), value: 200e6});
    }

    /// @notice Later metadata changes do not change feed precision, terminal accounting or minted shares.
    function test_cachedDecimalsIgnoreLaterTokenMetadataChanges() public {
        _stake(10e6);
        vm.mockCall(address(_underlying), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));
        assertEq(_underlying.decimals(), 18);
        assertEq(_feed.DECIMALS(), 6);
        assertEq(_feed.currentUnitPrice(6), 10e6);
        assertEq(_feed.currentUnitPrice(18), 10e18);
        assertEq(_stake(5e6), 5e18);
        assertEq(_feed.currentUnitPrice(6), 15e6);
        assertEq(_cashOut(5e18), 5e6);
        assertEq(_feed.currentUnitPrice(6), 10e6);
    }

    /// @notice Feed registration cannot diverge from the registry that the payment terminal reads.
    function test_constructorRejectsPriceRegistryMismatch() public {
        address otherPrices = makeAddr("wrong terminal prices");
        vm.mockCall(address(jbTerminalStore()), abi.encodeCall(IJBTerminalStore.PRICES, ()), abi.encode(otherPrices));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDeployer.JBStickyDeployer_PriceRegistryMismatch.selector, address(jbPrices()), otherPrices
            )
        );
        new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
    }

    /// @notice A wrong default used after the project feed fails cannot overmint or change any holder position.
    function test_defaultFallbackCannotChangeExactIssuance() public {
        _stake(10e6);
        _donate(10e6);
        uint256 currency = _feed.CURRENCY();
        uint256 baseCurrency = type(uint32).max;
        JBStickyTestPriceFeed wrongFeed = new JBStickyTestPriceFeed(5e6);
        vm.prank(jbPrices().owner());
        jbPrices().addPriceFeedFor({
            projectId: 0, pricingCurrency: currency, unitCurrency: baseCurrency, feed: wrongFeed
        });
        vm.mockCallRevert(address(_feed), abi.encodeCall(IJBPriceFeed.currentUnitPrice, (6)), bytes("feed failed"));
        assertEq(
            jbPrices().pricePerUnitOf({
                projectId: _projectId, pricingCurrency: currency, unitCurrency: baseCurrency, decimals: 6
            }),
            5e6,
            "the wrong default must actually be selected"
        );
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyHook.JBStickyHook_UnexpectedIssuedCount.selector, _projectId, 5e18, 20e18)
        );
        _stake(10e6);
        assertEq(_stateHash(), beforeState, "fallback issuance must revert balances and position atomically");

        // Restoring the exact feed makes the same payment safe without altering the project's configuration.
        vm.clearMockedCalls();
        assertEq(_stake(10e6), 5e18);
        assertEq(_token.totalSupply(), 15e18);
    }

    /// @notice Empty supply uses one unit; existing supply excludes orphaned donations through exit and restart.
    function test_feedBootstrapsAndExcludesOrphanBackingAcrossLifecycle() public {
        assertEq(_feed.currentUnitPrice(6), 1e6);
        _donate(7e6);
        assertEq(_feed.currentUnitPrice(6), 1e6);
        assertEq(_stake(10e6), 10e18);
        assertEq(_hook.orphanedBalanceOf(_projectId), 7e6);
        assertEq(_feed.currentUnitPrice(6), 10e6);
        _donate(3e6);
        assertEq(_feed.currentUnitPrice(6), 13e6);
        assertEq(_stake(13e6), 10e18);
        assertEq(_feed.currentUnitPrice(6), 26e6);
        assertEq(_cashOut(20e18), 26e6);
        assertEq(_backing(), 7e6);
        assertEq(_feed.currentUnitPrice(6), 1e6);
        _donate(4e6);
        assertEq(_feed.currentUnitPrice(6), 1e6);
        assertEq(_stake(2e6), 2e18);
        assertEq(_hook.orphanedBalanceOf(_projectId), 11e6);
        assertEq(_feed.currentUnitPrice(6), 2e6);
        assertEq(_cashOut(2e18), 2e6);
        assertEq(_backing(), 11e6);
    }

    /// @notice The feed converts supported output precisions and rejects unsupported precision explicitly.
    function test_feedPrecisionBoundaries() public {
        assertEq(_feed.currentUnitPrice(0), 1);
        assertEq(_feed.currentUnitPrice(18), 1e18);
        assertEq(_feed.currentUnitPrice(36), 1e36);
        _stake(10e6);
        assertEq(_feed.currentUnitPrice(0), 10);
        assertEq(_feed.currentUnitPrice(18), 10e18);
        assertEq(_feed.currentUnitPrice(36), 10e36);
        vm.expectRevert(abi.encodeWithSelector(JBStickyPriceFeed.JBStickyPriceFeed_UnsupportedDecimals.selector, 37));
        _feed.currentUnitPrice(37);
    }

    /// @notice Feed registration uses the exact direct pair and permanently captures the project's dependencies.
    function test_feedRegisteredWithExactPairAndImmutableBindings() public view {
        uint256 currency = uint32(uint160(address(_underlying)));
        uint256 baseCurrency = JBRulesetMetadataResolver.baseCurrency(jbRulesets().currentOf(_projectId));
        assertEq(baseCurrency, type(uint32).max);
        assertEq(jbPrices().priceFeedCountFor(_projectId, currency, baseCurrency), 1);
        assertEq(jbPrices().priceFeedCountFor(_projectId, baseCurrency, currency), 0);
        assertEq(address(jbPrices().priceFeedFor(_projectId, currency, baseCurrency)), address(_feed));
        assertEq(address(_feed.HOOK()), address(_hook));
        assertEq(_feed.PROJECT_ID(), _projectId);
        assertEq(address(_feed.TERMINAL()), address(jbMultiTerminal()));
        assertEq(address(_feed.TOKEN()), address(_token));
        assertEq(_feed.UNDERLYING_TOKEN(), address(_underlying));
        assertEq(_feed.DECIMALS(), 6);
        assertEq(_feed.CURRENCY(), currency);
    }

    /// @notice A token whose currency equals MAX32 receives a different synthetic currency and prices correctly.
    function test_maxCurrencyUsesDistinctSyntheticPair() public {
        address collisionToken = address(uint160(0x1ffffffff));
        vm.etch(collisionToken, address(_underlying).code);
        uint256 projectId = _launch(IERC20Metadata(collisionToken));
        JBStickyPriceFeed feed = JBStickyPriceFeed(address(_deployer.priceFeedOf(projectId)));
        uint256 baseCurrency = JBRulesetMetadataResolver.baseCurrency(jbRulesets().currentOf(projectId));
        assertEq(feed.CURRENCY(), type(uint32).max);
        assertEq(baseCurrency, type(uint32).max - 1);
        assertEq(address(jbPrices().priceFeedFor(projectId, type(uint32).max, type(uint32).max - 1)), address(feed));
        JBStickyPricingToken(collisionToken).mint({account: _holder, amount: 12e6});
        vm.startPrank(_holder);
        JBStickyPricingToken(collisionToken).approve({spender: address(jbMultiTerminal()), value: 12e6});
        uint256 minted = jbMultiTerminal().pay({
            projectId: projectId,
            token: collisionToken,
            amount: 12e6,
            beneficiary: _holder,
            minReturnedTokens: 12e18,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        assertEq(minted, 12e18);
        assertEq(feed.currentUnitPrice(6), 12e6);
    }

    /// @notice A nonzero token address whose low 32 bits are zero fails before launching an unusable project.
    function test_zeroCurrencyIsRejectedBeforeProjectCreation() public {
        address zeroCurrencyToken = address(uint160(0x100000000));
        vm.etch(zeroCurrencyToken, address(_underlying).code);
        uint256 projectCount = jbProjects().count();
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyDeployer.JBStickyDeployer_InvalidCurrency.selector, zeroCurrencyToken)
        );
        _launch(IERC20Metadata(zeroCurrencyToken));
        assertEq(jbProjects().count(), projectCount);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Cash out shares through the actual terminal.
    /// @param count The share count to burn.
    /// @return reclaimed The underlying amount returned.
    function _cashOut(uint256 count) internal returns (uint256 reclaimed) {
        vm.prank(_holder);
        return jbMultiTerminal().cashOutTokensOf({
            holder: _holder,
            projectId: _projectId,
            cashOutCount: count,
            tokenToReclaim: address(_underlying),
            minTokensReclaimed: 0,
            beneficiary: payable(_holder),
            metadata: bytes("")
        });
    }

    /// @notice Add underlying backing without minting shares.
    /// @param amount The amount to donate, in underlying token atoms.
    function _donate(uint256 amount) internal {
        vm.prank(_holder);
        jbMultiTerminal().addToBalanceOf({
            projectId: _projectId,
            token: address(_underlying),
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: bytes("")
        });
    }

    /// @notice Launch a zero-tax Sticky project for an arbitrary test token.
    /// @param underlying The token the new project accepts.
    /// @return projectId The new project's ID.
    function _launch(IERC20Metadata underlying) internal returns (uint256 projectId) {
        vm.deal(address(this), _creationFee);
        return _deployer.deployStickyFor{value: _creationFee}({
            stakedToken: underlying,
            name: "Sticky Feed",
            symbol: "stFEED",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
    }

    /// @notice Stake underlying tokens from the test holder.
    /// @param amount The amount to stake, in underlying token atoms.
    /// @return minted The number of shares issued.
    function _stake(uint256 amount) internal returns (uint256 minted) {
        vm.prank(_holder);
        return jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: amount,
            beneficiary: _holder,
            minReturnedTokens: 1,
            memo: "",
            metadata: bytes("")
        });
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Read all underlying backing, including the excluded orphan balance.
    /// @return backing The terminal's accounted underlying balance.
    function _backing() internal view returns (uint256 backing) {
        return jbTerminalStore().balanceOf(address(jbMultiTerminal()), _projectId, address(_underlying));
    }

    /// @notice Hash the holder's position and all payment balances affected by a failed feed-based mint.
    /// @return stateHash The observed accounting state hash.
    function _stateHash() internal view returns (bytes32 stateHash) {
        return keccak256(
            abi.encode(
                _backing(),
                _underlying.balanceOf(_holder),
                _underlying.balanceOf(address(jbMultiTerminal())),
                _underlying.allowance(_holder, address(jbMultiTerminal())),
                _token.balanceOf(_holder),
                _token.totalSupply(),
                _hook.stakedBalanceOf(_projectId, _holder),
                _hook.tranchesOf(_projectId, _holder),
                _hook.streakStartOf(_projectId, _holder),
                _hook.longestStreakOf(_projectId, _holder),
                _hook.orphanedBalanceOf(_projectId)
            )
        );
    }
}
