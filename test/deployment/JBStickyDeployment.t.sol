// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBStickyDeployment} from "../../script/helpers/JBStickyDeployment.sol";
import {MockArt} from "../../script/mocks/MockArt.sol";
import {JBStickyDeployer} from "../../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../../src/JBStickyDistributor.sol";
import {JBStickyHook} from "../../src/JBStickyHook.sol";
import {JBStickyPriceFeed} from "../../src/JBStickyPriceFeed.sol";
import {JBStickyToken} from "../../src/JBStickyToken.sol";

import {JBStickyCoreDeployment} from "../../script/structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "../../script/structs/JBStickyDeploymentAddresses.sol";
import {JBStickyImmutableReference} from "../../script/structs/JBStickyImmutableReference.sol";

import {JBStickyDeploymentHarness} from "./JBStickyDeploymentHarness.sol";

/// @notice Tests the production deployment helper against real core contracts, without live network writes.
contract JBStickyDeploymentTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The local V6 core contracts the deployment binds to.
    JBStickyCoreDeployment internal _core;

    /// @notice The production deployment helper under test.
    JBStickyDeploymentHarness internal _deployment;

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function test_allNetworkFoldersMatchCurrentCoreLayout() public view {
        assertEq(_deployment.network(1), "ethereum");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(10), "optimism");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(8453), "base");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(42_161), "arbitrum");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(11_155_111), "sepolia");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(11_155_420), "optimism_sepolia");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(84_532), "base_sepolia");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_deployment.network(421_614), "arbitrum_sepolia");
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        _deployment = new JBStickyDeploymentHarness();
        _core =
            JBStickyCoreDeployment({controller: jbController(), directory: jbDirectory(), terminal: jbMultiTerminal()});
        vm.etch(
            _deployment.DETERMINISTIC_FACTORY(),
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
    }

    function test_cleanDeploymentAndRepeatPreserveEveryAddressAndOriginalTimestamp() public {
        JBStickyDeploymentAddresses memory predicted = _deployment.predict(_core);
        assertEq(predicted.deployer.code.length, 0);
        JBStickyDeploymentAddresses memory first = _deployment.deployFor(_core);
        assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(predicted)));
        bytes32 firstHash = first.distributor.codehash;
        uint256 firstTimestamp = JBStickyDistributor(payable(first.distributor)).STARTING_TIMESTAMP();
        vm.warp(block.timestamp + 10 days);
        vm.recordLogs();
        JBStickyDeploymentAddresses memory second = _deployment.deployFor(_core);
        assertEq(vm.getRecordedLogs().length, 0, "repeat creates no contracts or transactions with logs");
        assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(second)));
        assertEq(second.distributor.codehash, firstHash);
        assertEq(JBStickyDistributor(payable(second.distributor)).STARTING_TIMESTAMP(), firstTimestamp);
        _deployment.verify(_core, second);
    }

    function test_deployedFactoryLaunchesTokenWithCanonicalHookAndRegistryBindings() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        JBStickyDeployer factory = JBStickyDeployer(deployed.deployer);
        MockArt underlying = new MockArt();
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        address[] memory granters = new address[](1);
        granters[0] = deployed.autoStick;
        // forge-lint: disable-next-item(arbitrary-send-eth)
        uint256 projectId = factory.deployStickyFor{value: fee}({
            stakedToken: underlying,
            name: "Deployment rehearsal",
            symbol: "STICKY",
            projectUri: "ipfs://deployment-rehearsal",
            cashOutTaxRate: 0,
            granters: granters,
            soulbound: true
        });
        JBStickyToken token = JBStickyToken(address(jbTokens().tokenOf(projectId)));
        assertEq(jbProjects().ownerOf(projectId), deployed.deployer);
        assertEq(address(token.HOOK()), deployed.hook);
        assertEq(address(token.TOKENS()), address(jbTokens()));
        assertEq(token.PROJECT_ID(), projectId);
        assertTrue(token.SOULBOUND());
        assertEq(factory.HOOK().tokenOf(projectId), address(token));
        assertEq(address(factory.stakedTokenOf(projectId)), address(underlying));
        JBStickyPriceFeed feed = JBStickyPriceFeed(address(factory.priceFeedOf(projectId)));
        assertGt(address(feed).code.length, 0);
        assertEq(address(feed.HOOK()), deployed.hook);
        assertEq(address(feed.TOKEN()), address(token));
        assertEq(address(feed.TERMINAL()), address(_core.terminal));
        assertEq(feed.PROJECT_ID(), projectId);
        assertEq(feed.UNDERLYING_TOKEN(), address(underlying));
        assertEq(feed.DECIMALS(), 18);
        _deployment.verify(_core, deployed);
    }

    function test_distributorBindsTheDeployedHookWithProductionPolicy() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        JBStickyDistributor distributor = JBStickyDistributor(payable(deployed.distributor));
        assertEq(address(distributor.STICKY_HOOK()), deployed.hook);
        assertEq(distributor.EPOCH_DURATION(), JBStickyHook(deployed.hook).EPOCH_DURATION());
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(distributor.EPOCH_DURATION(), 1 weeks);
        assertEq(address(distributor.CONTROLLER()), address(_core.controller));
        assertEq(address(distributor.DIRECTORY()), address(_core.directory));
        assertEq(address(distributor.REV_LOANS()), address(0));
        assertEq(address(distributor.REV_OWNER()), address(0));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(distributor.ROUND_DURATION(), 7 days);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(distributor.VESTING_ROUNDS(), 4);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(distributor.CLAIM_DURATION(), 2 * 365 days);
        assertLe(deployed.distributor.code.length, 24_576);

        // A distributor bound to a different hook has identical opcodes and fails the binding check.
        JBStickyDeployer other = new JBStickyDeployer({controller: _core.controller, terminal: _core.terminal});
        JBStickyDistributor different = new JBStickyDistributor({
            controller: _core.controller,
            directory: _core.directory,
            stickyHook: other.HOOK(),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            initialRoundDuration: 7 days,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            initialVestingRounds: 4,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            initialClaimDuration: uint48(2 * 365 days)
        });
        vm.etch(deployed.distributor, address(different).code);
        _deployment.verifyRuntime("JBStickyDistributor", deployed.distributor);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        _deployment.verify(_core, deployed);
    }

    function test_loadsFlatCoreArtifactsWithoutForwarder() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.chainId(11_155_111);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        string memory root = _writeCoreArtifacts(11_155_111);
        JBStickyCoreDeployment memory loaded = _deployment.loadCore(root);
        assertEq(address(loaded.controller), address(_core.controller));
        assertEq(address(loaded.terminal), address(_core.terminal));
    }

    function test_manifestDistinguishesRpcBlockFromEvmHeight() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.chainId(42_161);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.roll(42);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STICKY_RPC_BLOCK_NUMBER", "100");
        bytes32 rpcBlockHash = keccak256("canonical RPC block");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STICKY_RPC_BLOCK_HASH", vm.toString(rpcBlockHash));
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        _deployment.writeManifest(_core, deployed);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("deployments/arbitrum/test.json");
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(vm.parseJsonUint(json, ".evmBlockNumber"), 42);
        assertEq(vm.parseJsonUint(json, ".rpcBlockNumber"), 100);
        assertEq(vm.parseJsonBytes32(json, ".rpcBlockHash"), rpcBlockHash);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STICKY_RPC_BLOCK_NUMBER", "0");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STICKY_RPC_BLOCK_HASH", vm.toString(bytes32(0)));
    }

    function test_partialDeploymentResumesWithoutReplacingFactoryOrHook() public {
        _deployment.deployDeployerOnly(_core);
        JBStickyDeploymentAddresses memory predicted = _deployment.predict(_core);
        bytes32 deployerHash = predicted.deployer.codehash;
        bytes32 hookHash = predicted.hook.codehash;
        assertGt(predicted.deployer.code.length, 0);
        assertEq(predicted.distributor.code.length, 0);
        JBStickyDeploymentAddresses memory resumed = _deployment.deployFor(_core);
        assertEq(resumed.deployer.codehash, deployerHash);
        assertEq(resumed.hook.codehash, hookHash);
        _deployment.verify(_core, resumed);
    }

    function test_rejectsConsistentlyWrongImmutableDependency() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        // A legitimate second factory has identical opcodes and different constructor-created HOOK references.
        JBStickyDeployer different = new JBStickyDeployer({controller: _core.controller, terminal: _core.terminal});
        vm.etch(deployed.deployer, address(different).code);
        _deployment.verifyRuntime("JBStickyDeployer", deployed.deployer);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsControllerWithoutProjectLaunchAuthorization() public {
        vm.mockCall(
            address(_core.directory),
            abi.encodeWithSignature("isAllowedToSetFirstController(address)", address(_core.controller)),
            abi.encode(false)
        );
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsDifferentCorePriceRegistriesBeforeAnyDeployment() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(address(_core.terminal.STORE()), abi.encodeWithSignature("PRICES()"), abi.encode(address(0xdead)));
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsDifferentCoreRulesetRegistries() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(address(_core.terminal.STORE()), abi.encodeWithSignature("RULESETS()"), abi.encode(address(0xdead)));
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsMismatchedExistingOpcode() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        bytes memory code = deployed.deployer.code;
        code[0] = bytes1(uint8(code[0]) ^ 1);
        vm.etch(deployed.deployer, code);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsMissingCoreCodeBeforeAnyDeployment() public {
        vm.etch(address(_core.terminal), hex"");
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_MissingCode.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsNoncanonicalUpperBitsInImmutableAddress() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("out/JBStickyDeployer.sol/JBStickyDeployer.json");
        string memory root = ".deployedBytecode.immutableReferences";
        string[] memory keys = vm.parseJsonKeys(json, root);
        JBStickyImmutableReference[] memory refs =
            abi.decode(vm.parseJson(json, string.concat(root, ".", keys[0])), (JBStickyImmutableReference[]));
        bytes memory code = deployed.deployer.code;
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < refs.length; i++) {
            code[refs[i].start] = 0x01;
        }
        vm.etch(deployed.deployer, code);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        _deployment.verifyRuntime("JBStickyDeployer", deployed.deployer);
    }

    function test_rejectsOneInconsistentImmutableOccurrence() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("out/JBStickyDeployer.sol/JBStickyDeployer.json");
        string memory root = ".deployedBytecode.immutableReferences";
        string[] memory keys = vm.parseJsonKeys(json, root);
        bool mutated;
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < keys.length; i++) {
            JBStickyImmutableReference[] memory refs =
            // forge-lint: disable-next-line(calls-loop)
            abi.decode(vm.parseJson(json, string.concat(root, ".", keys[i])), (JBStickyImmutableReference[]));
            if (refs.length < 2) continue;
            bytes memory code = deployed.deployer.code;
            // forge-lint: disable-next-line(literal-instead-of-constant)
            code[refs[1].start + 31] = bytes1(uint8(code[refs[1].start + 31]) ^ 1);
            // forge-lint: disable-next-line(calls-loop)
            vm.etch(deployed.deployer, code);
            mutated = true;
            break;
        }
        // forge-lint: disable-next-line(uninitialized-local)
        assertTrue(mutated, "fixture must modify a repeated immutable");
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        _deployment.verifyRuntime("JBStickyDeployer", deployed.deployer);
    }

    function test_rejectsUnsupportedChain() public {
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_UnsupportedChain.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.network(31_337);
    }

    function test_rejectsWrongCanonicalFactoryRuntime() public {
        vm.etch(_deployment.DETERMINISTIC_FACTORY(), hex"00");
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsWrongCoreArtifactChain() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.chainId(11_155_111);
        string memory root = _writeCoreArtifacts(1);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_ChainMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.loadCore(root);
    }

    function test_rejectsWrongCoreBindingBeforeAnyDeployment() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.mockCall(address(_core.terminal), abi.encodeWithSignature("DIRECTORY()"), abi.encode(address(0xdead)));
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        // forge-lint: disable-next-line(unused-return)
        _deployment.deployFor(_core);
    }

    function test_rejectsWrongRpcChainBeforeReadingArtifacts() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.chainId(10);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STICKY_EXPECTED_CHAIN_ID", "1");
        vm.expectRevert(
            abi.encodeWithSelector(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                JBStickyDeployment.JBStickyDeployment_ChainMismatch.selector,
                "RPC",
                uint256(1),
                // forge-lint: disable-next-line(literal-instead-of-constant)
                uint256(10)
            )
        );
        // forge-lint: disable-next-line(unused-return)
        _deployment.loadCore("deployments/_missing");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STICKY_EXPECTED_CHAIN_ID", "0");
    }

    function test_sameArtifactsAndCoreBindingsPredictSameAddressesOnEverySupportedChain() public {
        bytes32 expected = keccak256(abi.encode(_deployment.predict(_core)));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256[8] memory chainIds = [uint256(1), 10, 8453, 42_161, 11_155_111, 11_155_420, 84_532, 421_614];
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < chainIds.length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            vm.chainId(chainIds[i]);
            // forge-lint: disable-next-line(calls-loop)
            assertEq(keccak256(abi.encode(_deployment.predict(_core))), expected);
        }
    }

    function test_verifiedManifestRecordsAllRuntimeHashes() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.chainId(11_155_111);
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        _deployment.writeManifest(_core, deployed);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("deployments/sepolia/test.json");
        assertEq(vm.parseJsonAddress(json, ".deployer"), deployed.deployer);
        assertEq(vm.parseJsonBytes32(json, ".hookCodehash"), deployed.hook.codehash);
        assertEq(vm.parseJsonBytes32(json, ".autoStickCodehash"), deployed.autoStick.codehash);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(vm.parseJsonUint(json, ".chainId"), 11_155_111);
        assertEq(vm.parseJsonString(json, ".kind"), "test");
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Writes one core artifact file in the flat sepolia layout under a test root.
    /// @param root The directory holding the test artifacts.
    /// @param name The core contract name used as the artifact file name.
    /// @param target The deployed address recorded in the artifact.
    /// @param chainId The chain ID recorded in the artifact.
    function _writeArtifact(string memory root, string memory name, address target, uint256 chainId) internal {
        string memory key = string.concat("artifact-", name);
        // forge-lint: disable-next-line(unused-return)
        vm.serializeAddress(key, "address", target);
        string memory json = vm.serializeString(key, "chainId", vm.toString(bytes32(chainId)));
        vm.writeJson(json, string.concat(root, "/sepolia/", name, ".json"));
    }

    /// @notice Writes the local core contracts as artifacts for a chain under a fresh test root.
    /// @param chainId The chain ID recorded in every artifact.
    /// @return root The directory holding the written artifacts.
    function _writeCoreArtifacts(uint256 chainId) internal returns (string memory root) {
        root = string.concat("deployments/_test/", vm.toString(chainId));
        vm.createDir(string.concat(root, "/sepolia"), true);
        _writeArtifact(root, "JBController", address(_core.controller), chainId);
        _writeArtifact(root, "JBDirectory", address(_core.directory), chainId);
        _writeArtifact(root, "JBMultiTerminal", address(_core.terminal), chainId);
    }
}
