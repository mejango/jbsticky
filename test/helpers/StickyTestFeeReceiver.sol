// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStickyDeployer} from "../../src/interfaces/IStickyDeployer.sol";

/// @notice Records creation-fee attribution and optionally launches a nested project during fee receipt.
contract StickyTestFeeReceiver {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The project launched from inside the first fee receipt, or zero if none was configured.
    uint256 public nestedProjectId;

    /// @notice The payer each fee sender reported, in receipt order.
    address[] public payers;

    /// @notice The deployer's payer after the nested launch returned.
    address public restoredPayer;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The factory to reenter on the first fee receipt, or zero to only record payers.
    IStickyDeployer internal _deployer;

    /// @notice The token accepted by the nested project.
    IERC20Metadata internal _underlying;

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Records the fee sender's payer and launches the configured nested project on the first receipt.
    receive() external payable {
        payers.push(IJBPayerTracker(msg.sender).originalPayer());
        if (address(_deployer) != address(0) && payers.length == 1) {
            // forge-lint: disable-next-item(arbitrary-send-eth)
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

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Configures a nested project launch on the next fee receipt.
    /// @param deployer The factory to reenter.
    /// @param underlying The token accepted by the nested project.
    function configureReentry(IStickyDeployer deployer, IERC20Metadata underlying) external {
        _deployer = deployer;
        _underlying = underlying;
    }
}
