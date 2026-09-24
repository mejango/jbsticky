// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StickyDeployment} from "./helpers/StickyDeployment.sol";
import {StickyCoreDeployment} from "./structs/StickyCoreDeployment.sol";

/// @notice Runs the production deployment helper twice in a fork simulation, without broadcasting.
contract Rehearse is StickyDeployment {
    /// @notice Exercises fresh/partial deployment or verified reuse, then repeats against the resulting state.
    function run() public {
        StickyCoreDeployment memory core = _loadCore();
        _deploy(core);
        _writeManifest({core: core, deployed: _deploy(core), kind: "simulation"});
    }
}
