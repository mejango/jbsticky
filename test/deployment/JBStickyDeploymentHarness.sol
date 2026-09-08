// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBStickyDeployment} from "../../script/helpers/JBStickyDeployment.sol";
import {JBStickyCoreDeployment} from "../../script/structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "../../script/structs/JBStickyDeploymentAddresses.sol";

/// @notice Exposes the production deployment helpers to local and fork regression tests.
contract JBStickyDeploymentHarness is JBStickyDeployment {
    function deployFor(JBStickyCoreDeployment memory core) external returns (JBStickyDeploymentAddresses memory) {
        return _deploy(core);
    }

    function deployDeployerOnly(JBStickyCoreDeployment memory core) external {
        _verifyCore(core);
        _deployIfNeeded({name: "JBStickyDeployer", salt: STICKY_SALT, args: abi.encode(core.controller, core.terminal)});
    }

    function loadCore(string memory root) external view returns (JBStickyCoreDeployment memory) {
        return _loadCoreFrom(root);
    }

    function network(uint256 chainId) external pure returns (string memory) {
        return _network(chainId);
    }

    function predict(JBStickyCoreDeployment memory core) external view returns (JBStickyDeploymentAddresses memory) {
        return _predict(core);
    }

    function verify(JBStickyCoreDeployment memory core, JBStickyDeploymentAddresses memory deployed) external view {
        _verify({core: core, deployed: deployed});
    }

    function verifyRuntime(string memory name, address target) external view {
        _verifyRuntime({name: name, target: target});
    }

    function writeManifest(JBStickyCoreDeployment memory core, JBStickyDeploymentAddresses memory deployed) external {
        _writeManifest({core: core, deployed: deployed, kind: "test"});
    }
}
