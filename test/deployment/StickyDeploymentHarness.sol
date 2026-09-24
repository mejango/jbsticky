// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StickyDeployment} from "../../script/helpers/StickyDeployment.sol";

import {StickyCoreDeployment} from "../../script/structs/StickyCoreDeployment.sol";
import {StickyDeploymentAddresses} from "../../script/structs/StickyDeploymentAddresses.sol";

/// @notice Exposes the production deployment helpers to local and fork regression tests.
contract StickyDeploymentHarness is StickyDeployment {
    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys only the factory so a later full deployment resumes from partial state.
    /// @param core The V6 core contracts the factory binds to.
    function deployDeployerOnly(StickyCoreDeployment memory core) external {
        _verifyCore(core);
        _deployIfNeeded({name: "StickyDeployer", salt: STICKY_SALT, args: abi.encode(core.controller, core.terminal)});
    }

    /// @notice Deploys, or resumes deploying, the full Sticky suite bound to the given core contracts.
    /// @param core The V6 core contracts the suite binds to.
    /// @return deployed The addresses of the deployed suite.
    function deployFor(StickyCoreDeployment memory core) external returns (StickyDeploymentAddresses memory deployed) {
        return _deploy(core);
    }

    /// @notice Writes the test manifest for a deployed suite.
    /// @param core The V6 core contracts the suite binds to.
    /// @param deployed The addresses of the deployed suite.
    function writeManifest(StickyCoreDeployment memory core, StickyDeploymentAddresses memory deployed) external {
        _writeManifest({core: core, deployed: deployed, kind: "test"});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Loads the V6 core contracts from deployment artifacts under a root directory.
    /// @param root The directory holding the per-network artifact folders.
    /// @return core The loaded core contracts.
    function loadCore(string memory root) external view returns (StickyCoreDeployment memory core) {
        return _loadCoreFrom(root);
    }

    /// @notice Resolves the deployment folder name for a chain.
    /// @param chainId The chain ID to resolve.
    /// @return name The network folder name.
    function network(uint256 chainId) external pure returns (string memory name) {
        return _network(chainId);
    }

    /// @notice Predicts the suite addresses for the given core contracts without deploying.
    /// @param core The V6 core contracts the suite binds to.
    /// @return predicted The predicted suite addresses.
    function predict(StickyCoreDeployment memory core)
        external
        view
        returns (StickyDeploymentAddresses memory predicted)
    {
        return _predict(core);
    }

    /// @notice Verifies a deployed suite's runtime code and bindings against the given core contracts.
    /// @param core The V6 core contracts the suite binds to.
    /// @param deployed The addresses of the deployed suite.
    function verify(StickyCoreDeployment memory core, StickyDeploymentAddresses memory deployed) external view {
        _verify({core: core, deployed: deployed});
    }

    /// @notice Verifies that a deployed contract's runtime code matches its compiled artifact.
    /// @param name The contract name whose artifact is compared.
    /// @param target The deployed address to check.
    function verifyRuntime(string memory name, address target) external view {
        _verifyRuntime({name: name, target: target});
    }
}
