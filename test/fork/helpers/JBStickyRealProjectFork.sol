// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JBStickyDeployer} from "../../../src/JBStickyDeployer.sol";
import {JBStickyToken} from "../../../src/JBStickyToken.sol";
import {JBStickyCoreDeployment} from "../../../script/structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "../../../script/structs/JBStickyDeploymentAddresses.sol";
import {JBStickyDeploymentHarness} from "../../deployment/JBStickyDeploymentHarness.sol";

/// @notice A live underlying project and the Sticky suite deployed locally on its pinned fork.
/// @custom:member forkId The Foundry fork identifier.
/// @custom:member underlyingProjectId The existing project's local V6 ID.
/// @custom:member core The deployed V6 core contracts loaded from production artifacts.
/// @custom:member suite The locally deployed Sticky singleton addresses.
/// @custom:member underlying The existing project's ERC-20 token.
/// @custom:member nativeTerminal The existing project's primary native-token payment terminal.
// Keep the shared Juicebox acronym intact in test types throughout V6.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBStickyRealProjectContext {
    uint256 forkId;
    uint256 underlyingProjectId;
    JBStickyCoreDeployment core;
    JBStickyDeploymentAddresses suite;
    IERC20Metadata underlying;
    IJBTerminal nativeTerminal;
}

/// @notice Shared real-project fork operations; underlying balances always originate from live payment contracts.
/// @dev Fork creation and time travel are local. No contract code, project configuration, or ERC-20 storage is
/// replaced.
abstract contract JBStickyRealProjectFork is Test {
    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The Ethereum mainnet block containing the project and bridge configuration under test.
    uint256 internal constant _ETHEREUM_BLOCK = 25_962_175;

    /// @notice The Base mainnet block containing the project and bridge configuration under test.
    uint256 internal constant _BASE_BLOCK = 51_218_441;

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Acquires the existing project's tokens through its real native-token payment path.
    /// @param context The selected fork's project and contracts.
    /// @param holder The payer and token beneficiary.
    /// @param nativeAmount The payment amount, in wei.
    /// @return acquired The ERC-20 amount actually received by the holder.
    function _buyUnderlying(
        JBStickyRealProjectContext memory context,
        address holder,
        uint256 nativeAmount
    )
        internal
        returns (uint256 acquired)
    {
        uint256 beforeBalance = context.underlying.balanceOf(holder);
        vm.deal(holder, holder.balance + nativeAmount);
        vm.prank(holder);
        uint256 issued = context.nativeTerminal.pay{value: nativeAmount}({
            projectId: context.underlyingProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: nativeAmount,
            beneficiary: holder,
            minReturnedTokens: 1,
            memo: "Sticky real-project fork",
            metadata: bytes("")
        });
        acquired = context.underlying.balanceOf(holder) - beforeBalance;
        assertGt(acquired, 0, "real payment must deliver ERC-20 project tokens");
        assertEq(acquired, issued, "payment receipt must match wallet delta");
    }

    /// @notice Redeems a holder's Sticky shares through the deployed V6 terminal.
    /// @param context The selected fork's project and contracts.
    /// @param projectId The locally launched Sticky project.
    /// @param holder The share holder and underlying-token beneficiary.
    /// @param count The shares to burn, in 18-decimal atoms.
    /// @param minimum The minimum acceptable net receipt, in underlying-token atoms.
    /// @return reclaimed The underlying amount received after fees.
    function _cashOut(
        JBStickyRealProjectContext memory context,
        uint256 projectId,
        address holder,
        uint256 count,
        uint256 minimum
    )
        internal
        returns (uint256 reclaimed)
    {
        uint256 beforeBalance = context.underlying.balanceOf(holder);
        vm.prank(holder);
        reclaimed = context.core.terminal
            .cashOutTokensOf({
                holder: holder,
                projectId: projectId,
                cashOutCount: count,
                tokenToReclaim: address(context.underlying),
                minTokensReclaimed: minimum,
                beneficiary: payable(holder),
                metadata: bytes("")
            });
        assertEq(context.underlying.balanceOf(holder) - beforeBalance, reclaimed, "cash-out wallet receipt");
    }

    /// @notice Selects a pinned fork, verifies live V6 bindings, and deploys Sticky through its production helper.
    /// @param rpcAlias The named Foundry RPC endpoint.
    /// @param forkBlock The explicit mainnet block to use.
    /// @param chainId The expected chain ID.
    /// @param underlyingProjectId The existing project whose tokens will be staked.
    /// @return context The selected fork and its live and locally deployed contracts.
    function _createProjectFork(
        string memory rpcAlias,
        uint256 forkBlock,
        uint256 chainId,
        uint256 underlyingProjectId
    )
        internal
        returns (JBStickyRealProjectContext memory context)
    {
        context.forkId = vm.createSelectFork({urlOrAlias: rpcAlias, blockNumber: forkBlock});
        assertEq(block.chainid, chainId, "RPC must match the requested chain");
        assertEq(block.number, forkBlock, "fork must remain pinned");
        context.underlyingProjectId = underlyingProjectId;
        JBStickyDeploymentHarness deployment = new JBStickyDeploymentHarness();
        context.core = deployment.loadCore("../../nana-core-v6/deployments");
        assertEq(
            address(context.core.directory.controllerOf(underlyingProjectId)),
            address(context.core.controller),
            "underlying project must use the production V6 controller"
        );
        context.underlying = IERC20Metadata(address(context.core.controller.TOKENS().tokenOf(underlyingProjectId)));
        assertGt(address(context.underlying).code.length, 0, "underlying ERC-20 must already exist");
        assertEq(context.underlying.decimals(), 18, "real project tokens use 18 decimals");
        context.nativeTerminal =
            context.core.directory.primaryTerminalOf({projectId: underlyingProjectId, token: JBConstants.NATIVE_TOKEN});
        assertGt(address(context.nativeTerminal).code.length, 0, "native payment route must already exist");
        context.suite = deployment.deployFor(context.core);
        deployment.verify({core: context.core, deployed: context.suite});
    }

    /// @notice Launches a permanently configured Sticky project backed by the existing project's token.
    /// @param context The selected fork's project and contracts.
    /// @param soulbound Whether holder-to-holder share transfers are disabled.
    /// @param cashOutTaxRate The cash-out curve parameter, out of 10,000.
    /// @return projectId The locally launched Sticky project ID.
    /// @return token The new Sticky share token.
    function _launchSticky(
        JBStickyRealProjectContext memory context,
        bool soulbound,
        uint256 cashOutTaxRate
    )
        internal
        returns (uint256 projectId, JBStickyToken token)
    {
        address[] memory granters = new address[](1);
        granters[0] = makeAddr("granter");
        uint256 fee = context.core.controller.PROJECTS().creationFee();
        vm.deal(address(this), address(this).balance + fee);
        projectId = JBStickyDeployer(context.suite.deployer).deployStickyFor{value: fee}({
            stakedToken: context.underlying,
            name: string.concat("Sticky ", context.underlying.name()),
            symbol: string.concat("s", context.underlying.symbol()),
            projectUri: "ipfs://sticky-real-project-fork",
            cashOutTaxRate: cashOutTaxRate,
            granters: granters,
            soulbound: soulbound
        });
        token = JBStickyToken(address(context.core.controller.TOKENS().tokenOf(projectId)));
    }

    /// @notice Previews and stakes existing project tokens, requiring the exact reviewed share count.
    /// @param context The selected fork's project and contracts.
    /// @param projectId The locally launched Sticky project.
    /// @param payer The underlying-token payer.
    /// @param beneficiary The Sticky-share beneficiary.
    /// @param amount The underlying amount to stake, in token atoms.
    /// @return shares The issued Sticky shares, in 18-decimal atoms.
    function _stake(
        JBStickyRealProjectContext memory context,
        uint256 projectId,
        address payer,
        address beneficiary,
        uint256 amount
    )
        internal
        returns (uint256 shares)
    {
        vm.startPrank(payer);
        (, uint256 preview,,) = context.core.terminal
            .previewPayFor({
                projectId: projectId,
                token: address(context.underlying),
                amount: amount,
                beneficiary: beneficiary,
                metadata: bytes("")
            });
        assertGt(preview, 0, "reviewed stake must issue shares");
        context.underlying.approve({spender: address(context.core.terminal), value: amount});
        shares = context.core.terminal
            .pay({
                projectId: projectId,
                token: address(context.underlying),
                amount: amount,
                beneficiary: beneficiary,
                minReturnedTokens: preview,
                memo: "",
                metadata: bytes("")
            });
        vm.stopPrank();
        assertEq(shares, preview, "reviewed stake preview must match execution");
    }
}
