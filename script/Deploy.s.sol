// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";

import {JBStickyDeployment} from "./helpers/JBStickyDeployment.sol";
import {JBStickyCoreDeployment} from "./structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "./structs/JBStickyDeploymentAddresses.sol";

/// @notice Proposes the deterministic Sticky singleton suite through the Juicebox V6 Sphinx workflow.
contract Deploy is JBStickyDeployment, Sphinx {
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
        sphinxConfig.projectName = "nana-sticky-v6";
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
        _core = _loadCore();
        deploy();
    }
}
