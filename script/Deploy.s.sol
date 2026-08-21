// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBStickyAutoStick} from "src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "src/JBStickyDistributor.sol";
import {JBStickyRewardPockets} from "src/JBStickyRewardPockets.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice the salt that is used to deploy the contracts.
    bytes32 stickyDeployer = "JBStickyDeployerV6";

    /// @notice the salt that is used to deploy the auto-stick adapter.
    bytes32 stickyAutoStick = "JBStickyAutoStickV6";

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-sticky-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        // Deploy the streaks deployer, which deploys and owns the sticky hook.
        JBStickyDeployer deployer =
            new JBStickyDeployer{salt: stickyDeployer}({controller: core.controller, terminal: core.terminal});

        // Deploy a rewards distributor tuned for sticky tokens: weekly rounds, fully unlocked after 4 rounds,
        // 28-day claim window before unclaimed rewards recycle to the current round.
        JBStickyDistributor distributor = new JBStickyDistributor{salt: stickyDeployer}({
            directory: core.directory,
            stickyHook: deployer.HOOK(),
            initialRoundDuration: 7 days,
            initialVestingRounds: 4,
            initialClaimDuration: 28 days
        });

        // Deploy the reward pockets factory. Its address is chain-identical, so pocket addresses predicted on any
        // chain are valid sucker-bridge beneficiaries on every other chain.
        new JBStickyRewardPockets{salt: stickyDeployer}(IJBDistributor(address(distributor)));

        // Deploy the auto-stick adapter after both of its dependencies exist.
        new JBStickyAutoStick{salt: stickyAutoStick}({
            deployer: deployer, distributor: IJBDistributor(address(distributor))
        });
    }
}
