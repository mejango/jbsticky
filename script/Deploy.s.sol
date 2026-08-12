// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBStickyAutoStick} from "src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "src/JBStickyDeployer.sol";
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
        // 3-year claim window (effectively forever, but still finite so abandoned rewards can recycle). Loans off.
        JBTokenDistributor distributor = new JBTokenDistributor{salt: stickyDeployer}({
            directory: core.directory,
            controller: core.controller,
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 7 days,
            initialVestingRounds: 4,
            initialClaimDuration: 3 * 365 days
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
