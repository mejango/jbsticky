// SPDX-License-Identifier: MIT
// forge-lint: disable-next-line(pragma-inconsistent)
pragma solidity 0.8.28;

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";

import {StickyDeployment} from "./helpers/StickyDeployment.sol";
import {StickyCoreDeployment} from "./structs/StickyCoreDeployment.sol";
import {StickyDeploymentAddresses} from "./structs/StickyDeploymentAddresses.sol";

/// @notice Proposes the deterministic Sticky singleton suite through the Juicebox V6 Sphinx workflow.
contract Deploy is StickyDeployment, Sphinx {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when Sphinx resolves a Safe other than the reviewed `sticky` project Safe.
    error Deploy_UnexpectedSafe(address expected, address actual);

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    /// @notice The registered `sticky` project's 1-of-3 `V6 Jango` Safe.
    address private constant _EXPECTED_SAFE = 0xd5136c794ee43BEf1eD4cF1eB6DEe45b7F803437;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Verified core dependencies for the current chain.
    StickyCoreDeployment internal _core;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Configures the Sphinx project and supported RPC aliases.
    function configureSphinx() public override {
        sphinxConfig.projectName = "sticky";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    /// @notice Collects only missing deployment transactions and validates every new or reused contract.
    function deploy() public sphinx {
        StickyDeploymentAddresses memory deployed = _deploy(_core);
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
