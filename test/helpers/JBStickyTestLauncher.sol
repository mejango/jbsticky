// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";

import {IJBStickyDeployer} from "../../src/interfaces/IJBStickyDeployer.sol";

/// @notice Forwards a Sticky launch while exposing the fee payer to downstream contracts.
contract JBStickyTestLauncher is IJBPayerTracker {
    address public transient override originalPayer;

    /// @notice Launch on behalf of the caller and forward their creation fee.
    /// @param deployer The Sticky factory.
    /// @param underlying The token accepted by the new project.
    /// @return projectId The ID of the new project.
    function launch(IJBStickyDeployer deployer, IERC20Metadata underlying)
        external
        payable
        returns (uint256 projectId)
    {
        originalPayer = msg.sender;
        projectId = deployer.deployStickyFor{value: msg.value}({
            stakedToken: underlying,
            name: "Forwarded Sticky",
            symbol: "stFWD",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        originalPayer = address(0);
    }
}
