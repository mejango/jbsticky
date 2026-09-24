// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";

import {JBStickyDeployment} from "./helpers/JBStickyDeployment.sol";
import {JBStickyCoreDeployment} from "./structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "./structs/JBStickyDeploymentAddresses.sol";

/// @notice Proposes the deterministic Sticky singleton suite through the Juicebox V6 Sphinx workflow.
contract Deploy is JBStickyDeployment, Sphinx {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when Sphinx resolves a Safe other than the reviewed V6 deployment Safe.
    error Deploy_UnexpectedSafe(address expected, address actual);

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    /// @notice The registered `v6-deployment` 4-of-8 Safe used by deploy-all-v6.
    address private constant _EXPECTED_SAFE = 0x4dc161eF837fF1C4485b08DDFcDB182F2157bE18;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Verified core dependencies for the current chain.
    JBStickyCoreDeployment internal _core;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Configures the Sphinx project and supported RPC aliases.
    function configureSphinx() public override {
        sphinxConfig.projectName = "v6-deployment";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    /// @notice Collects only missing deployment transactions and validates every new or reused contract.
    function deploy() public sphinx {
        JBStickyDeploymentAddresses memory deployed = _deploy(_core);
        _writeManifest({core: _core, deployed: deployed, kind: "simulation"});
    }

    /// @notice Validates connected-chain dependencies before collecting the Sphinx proposal.
    function run() public {
        address actualSafe = safeAddress();
        if (actualSafe != _EXPECTED_SAFE) {
            revert Deploy_UnexpectedSafe({expected: _EXPECTED_SAFE, actual: actualSafe});
        }
        _core = _loadCore();
        deploy();
    }
}
