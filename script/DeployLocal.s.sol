// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBStickyAutoStick} from "src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "src/JBStickyDistributor.sol";
import {JBStickyRewardPockets} from "src/JBStickyRewardPockets.sol";

/// @notice A test token to stake on a local fork.
contract MockArt is ERC20 {
    constructor() ERC20("Art", "ART") {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice A second test token, staked with a stickiness bonus on a local fork.
contract MockBan is ERC20 {
    constructor() ERC20("Banana", "BAN") {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}

/// @notice Deploys JBSticky plus a mintable test token to a local fork of a chain with nana core, and launches a
/// sticky project for it. For local development only.
contract DeployLocalScript is Script {
    function run() public {
        // Read the core controller and terminal addresses for the forked network directly from the checked-in
        // deployment artifacts.
        string memory network = vm.envOr("NANA_CORE_NETWORK", string("sepolia"));
        string memory base = string.concat("deployments-local/nana-core-v6/", network, "/");
        IJBController controller = IJBController(
            stdJson.readAddress({json: vm.readFile(string.concat(base, "JBController.json")), key: ".address"})
        );
        IJBTerminal terminal = IJBTerminal(
            stdJson.readAddress({json: vm.readFile(string.concat(base, "JBMultiTerminal.json")), key: ".address"})
        );

        uint256 fee = controller.PROJECTS().creationFee();

        // Fund the simulation's caller so the payable creation-fee call simulates; the broadcast tx is funded by the
        // sender EOA.
        vm.deal({account: msg.sender, newBalance: 100 ether});

        vm.startBroadcast();

        MockArt art = new MockArt();
        MockBan ban = new MockBan();
        JBStickyDeployer deployer = new JBStickyDeployer({controller: controller, terminal: terminal});

        // A demo rewards distributor with fast rounds: 10-minute rounds, vested after 4 rounds, 40-minute claims.
        JBStickyDistributor distributor = new JBStickyDistributor({
            directory: IJBDirectory(address(controller.DIRECTORY())),
            stickyHook: deployer.HOOK(),
            initialRoundDuration: 600,
            initialVestingRounds: 4,
            initialClaimDuration: 2400
        });

        JBStickyAutoStick autoStick =
            new JBStickyAutoStick({deployer: deployer, distributor: IJBDistributor(address(distributor))});
        JBStickyRewardPockets pockets = new JBStickyRewardPockets(IJBDistributor(address(distributor)));

        // The immutable adapter is available to every holder from launch. This does not enable auto-stick or grant a
        // token allowance for anyone; each holder still opts in and approves their own underlying token.
        address[] memory granters = new address[](2);
        granters[0] = msg.sender;
        granters[1] = address(autoStick);

        // ART: a pure wrapper — no stickiness bonus, fee-free unsticks.
        uint256 projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(art)),
            name: "Streaking ART",
            symbol: "STICKYART",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: granters,
            soulbound: true
        });
        art.mint({to: msg.sender, amount: 1_000_000e18});

        // BAN: carries a 10% stickiness bonus, so unsticks reward those who stay.
        uint256 banProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(ban)),
            name: "Streaking BAN",
            symbol: "STICKYBAN",
            projectUri: "",
            cashOutTaxRate: 1000,
            granters: granters,
            soulbound: true
        });
        ban.mint({to: msg.sender, amount: 1_000_000e18});

        vm.stopBroadcast();

        console2.log("ART", address(art));
        console2.log("BAN", address(ban));
        console2.log("JBStickyDeployer", address(deployer));
        console2.log("JBStickyHook", address(deployer.HOOK()));
        console2.log("projectId", projectId);
        console2.log("banProjectId", banProjectId);
        console2.log("JBStickyDistributor", address(distributor));
        console2.log("JBStickyAutoStick", address(autoStick));
        console2.log("JBStickyRewardPockets", address(pockets));
    }
}
