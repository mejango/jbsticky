// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";

import {IJBStickyDeployer} from "../../src/interfaces/IJBStickyDeployer.sol";

/// @notice Records creation-fee attribution and optionally launches a nested project during fee receipt.
contract JBStickyTestFeeReceiver {
    address[] public payers;
    address public restoredPayer;
    uint256 public nestedProjectId;

    IJBStickyDeployer internal _deployer;
    IERC20Metadata internal _underlying;

    receive() external payable {
        payers.push(IJBPayerTracker(msg.sender).originalPayer());
        if (address(_deployer) != address(0) && payers.length == 1) {
            nestedProjectId = _deployer.deployStickyFor{value: msg.value}({
                stakedToken: _underlying,
                name: "Nested Sticky",
                symbol: "stNEST",
                projectUri: "",
                cashOutTaxRate: 0,
                granters: new address[](0),
                soulbound: true
            });
            restoredPayer = _deployer.originalPayer();
        }
    }

    /// @notice Configure a nested project launch on the next fee receipt.
    /// @param deployer The factory to reenter.
    /// @param underlying The token accepted by the nested project.
    function configureReentry(IJBStickyDeployer deployer, IERC20Metadata underlying) external {
        _deployer = deployer;
        _underlying = underlying;
    }
}
