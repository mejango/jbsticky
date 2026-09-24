// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {console2} from "forge-std/console2.sol";

import {StickyAutoStick} from "../src/StickyAutoStick.sol";
import {StickyDeployer} from "../src/StickyDeployer.sol";
import {StickyDistributor} from "../src/StickyDistributor.sol";
import {StickyRewardReceiverFactory} from "../src/StickyRewardReceiverFactory.sol";

import {StickyDeployment} from "./helpers/StickyDeployment.sol";
import {MockArt} from "./mocks/MockArt.sol";
import {MockBan} from "./mocks/MockBan.sol";
import {StickyCoreDeployment} from "./structs/StickyCoreDeployment.sol";

/// @notice Deploys Sticky plus a mintable test token to a local fork of a chain with nana core, and launches a
/// sticky project for it. For local development only.
contract DeployLocal is StickyDeployment {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the disposable local demo is not explicitly enabled, so it cannot run by accident.
    error DeployLocal_LocalDemoNotEnabled();

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploys disposable demo tokens and projects on an explicitly opted-in local fork.
    /// @dev This non-idempotent fixture deliberately uses shortened distributor durations. Never use it for production.
    function run() public {
        if (!vm.envOr({name: "STICKY_LOCAL_DEMO", defaultValue: false})) revert DeployLocal_LocalDemoNotEnabled();
        StickyCoreDeployment memory core = _loadCore();
        IJBController controller = core.controller;
        IJBTerminal terminal = core.terminal;

        uint256 fee = controller.PROJECTS().creationFee();

        // Fund the simulation's caller so the payable creation-fee call simulates; the broadcast tx is funded by the
        // sender EOA.
        vm.deal({account: msg.sender, newBalance: 100 ether});

        vm.startBroadcast();

        MockArt art = new MockArt();
        MockBan ban = new MockBan();
        StickyDeployer deployer = new StickyDeployer({controller: controller, terminal: terminal});

        // A demo rewards distributor with fast rounds: 10-minute rounds, vested after 2 rounds, 7-day claims.
        StickyDistributor distributor = new StickyDistributor({
            controller: controller,
            directory: controller.DIRECTORY(),
            stickyHook: deployer.HOOK(),
            initialRoundDuration: 600,
            initialVestingRounds: 2,
            initialClaimDuration: 7 days
        });

        StickyAutoStick autoStick = new StickyAutoStick({deployer: deployer, distributor: distributor});
        StickyRewardReceiverFactory rewardReceiverFactory = new StickyRewardReceiverFactory(distributor);

        // The immutable adapter is available to every holder from launch. This does not enable auto-stick or grant a
        // token allowance for anyone; each holder still opts in and approves their own underlying token.
        address[] memory granters = new address[](2);
        granters[0] = msg.sender;
        granters[1] = address(autoStick);

        // ART: zero cash-out tax; redemption follows the configured backing economics.
        // forge-lint: disable-next-item(arbitrary-send-eth)
        uint256 projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(art)),
            name: "Streaking ART",
            symbol: "STICKYART",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: granters,
            soulbound: true
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        art.mint({to: msg.sender, amount: 1_000_000e18});

        // BAN: applies the protocol's 10% cash-out tax curve and applicable fees.
        // forge-lint: disable-next-item(arbitrary-send-eth)
        uint256 banProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(ban)),
            name: "Streaking BAN",
            symbol: "STICKYBAN",
            projectUri: "",
            cashOutTaxRate: 1000,
            granters: granters,
            soulbound: true
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        ban.mint({to: msg.sender, amount: 1_000_000e18});

        vm.stopBroadcast();

        console2.log({p0: "ART", p1: address(art)});
        console2.log({p0: "BAN", p1: address(ban)});
        console2.log({p0: "StickyDeployer", p1: address(deployer)});
        console2.log({p0: "StickyHook", p1: address(deployer.HOOK())});
        console2.log({p0: "projectId", p1: projectId});
        console2.log({p0: "banProjectId", p1: banProjectId});
        console2.log({p0: "StickyDistributor", p1: address(distributor)});
        console2.log({p0: "StickyAutoStick", p1: address(autoStick)});
        console2.log({p0: "StickyRewardReceiverFactory", p1: address(rewardReceiverFactory)});
    }
}
