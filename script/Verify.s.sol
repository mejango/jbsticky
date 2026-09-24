// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StickyDeployment} from "./helpers/StickyDeployment.sol";
import {StickyCoreDeployment} from "./structs/StickyCoreDeployment.sol";

/// @notice Verifies a deployed Sticky suite without sending transactions, and writes its live manifest.
contract Verify is StickyDeployment {
    /// @notice Checks current artifacts, predictions, bytecode and immutable bindings against the connected RPC.
    function run() public {
        StickyCoreDeployment memory core = _loadCore();
        _writeManifest({core: core, deployed: _predict(core), kind: "verified"});
    }
}
