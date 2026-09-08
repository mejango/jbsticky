// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBStickyDeployment} from "./helpers/JBStickyDeployment.sol";
import {JBStickyCoreDeployment} from "./structs/JBStickyCoreDeployment.sol";

/// @notice Verifies a deployed Sticky suite without sending transactions, and writes its live manifest.
contract Verify is JBStickyDeployment {
    /// @notice Checks current artifacts, predictions, bytecode and immutable bindings against the connected RPC.
    function run() public {
        JBStickyCoreDeployment memory core = _loadCore();
        _writeManifest({core: core, deployed: _predict(core), kind: "verified"});
    }
}
