// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";

import {JBStickyPriceFeed} from "../../src/JBStickyPriceFeed.sol";
import {JBStickyToken} from "../../src/JBStickyToken.sol";
import {MockArt} from "../../script/mocks/MockArt.sol";

import {JBStickyDeployer} from "../../src/JBStickyDeployer.sol";
import {JBStickyDeployment} from "../../script/helpers/JBStickyDeployment.sol";
import {JBStickyCoreDeployment} from "../../script/structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "../../script/structs/JBStickyDeploymentAddresses.sol";
import {JBStickyImmutableReference} from "../../script/structs/JBStickyImmutableReference.sol";
import {JBStickyDeploymentHarness} from "./JBStickyDeploymentHarness.sol";

/// @notice Tests the production deployment helper against real core contracts, without live network writes.
contract JBStickyDeploymentTest is TestBaseWorkflow {
    JBStickyDeploymentHarness internal _deployment;
    JBStickyCoreDeployment internal _core;

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
        uint256 firstTimestamp = JBTokenDistributor(payable(first.distributor)).STARTING_TIMESTAMP();
        vm.warp(block.timestamp + 10 days);
        vm.recordLogs();
        JBStickyDeploymentAddresses memory second = _deployment.deployFor(_core);
        assertEq(vm.getRecordedLogs().length, 0, "repeat creates no contracts or transactions with logs");
        assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(second)));
        assertEq(second.distributor.codehash, firstHash);
        assertEq(JBTokenDistributor(payable(second.distributor)).STARTING_TIMESTAMP(), firstTimestamp);
        _deployment.verify(_core, second);
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

    function test_deployedFactoryLaunchesTokenWithCanonicalHookAndRegistryBindings() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        JBStickyDeployer factory = JBStickyDeployer(deployed.deployer);
        MockArt underlying = new MockArt();
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        address[] memory granters = new address[](1);
        granters[0] = deployed.autoStick;
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

    function test_sameArtifactsAndCoreBindingsPredictSameAddressesOnEverySupportedChain() public {
        bytes32 expected = keccak256(abi.encode(_deployment.predict(_core)));
        uint256[8] memory chainIds = [uint256(1), 10, 8453, 42_161, 11_155_111, 11_155_420, 84_532, 421_614];
        for (uint256 i; i < chainIds.length; i++) {
            vm.chainId(chainIds[i]);
            assertEq(keccak256(abi.encode(_deployment.predict(_core))), expected);
        }
    }

    function test_rejectsWrongCanonicalFactoryRuntime() public {
        vm.etch(_deployment.DETERMINISTIC_FACTORY(), hex"00");
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        _deployment.deployFor(_core);
    }

    function test_rejectsMismatchedExistingOpcode() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        bytes memory code = deployed.deployer.code;
        code[0] = bytes1(uint8(code[0]) ^ 1);
        vm.etch(deployed.deployer, code);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        _deployment.deployFor(_core);
    }

    function test_rejectsOneInconsistentImmutableOccurrence() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        string memory json = vm.readFile("out/JBStickyDeployer.sol/JBStickyDeployer.json");
        string memory root = ".deployedBytecode.immutableReferences";
        string[] memory keys = vm.parseJsonKeys(json, root);
        bool mutated;
        for (uint256 i; i < keys.length; i++) {
            JBStickyImmutableReference[] memory refs =
                abi.decode(vm.parseJson(json, string.concat(root, ".", keys[i])), (JBStickyImmutableReference[]));
            if (refs.length < 2) continue;
            bytes memory code = deployed.deployer.code;
            code[refs[1].start + 31] = bytes1(uint8(code[refs[1].start + 31]) ^ 1);
            vm.etch(deployed.deployer, code);
            mutated = true;
            break;
        }
        assertTrue(mutated, "fixture must modify a repeated immutable");
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_RuntimeMismatch.selector);
        _deployment.verifyRuntime("JBStickyDeployer", deployed.deployer);
    }

    function test_rejectsConsistentlyWrongImmutableDependency() public {
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        // A legitimate second factory has identical opcodes and different constructor-created HOOK references.
        JBStickyDeployer different = new JBStickyDeployer({controller: _core.controller, terminal: _core.terminal});
        vm.etch(deployed.deployer, address(different).code);
        _deployment.verifyRuntime("JBStickyDeployer", deployed.deployer);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        _deployment.deployFor(_core);
    }

    function test_rejectsMissingCoreCodeBeforeAnyDeployment() public {
        vm.etch(address(_core.terminal), hex"");
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_MissingCode.selector);
        _deployment.deployFor(_core);
    }

    function test_rejectsWrongCoreBindingBeforeAnyDeployment() public {
        vm.mockCall(address(_core.terminal), abi.encodeWithSignature("DIRECTORY()"), abi.encode(address(0xdead)));
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        _deployment.deployFor(_core);
    }

    function test_rejectsDifferentCorePriceRegistriesBeforeAnyDeployment() public {
        vm.mockCall(address(_core.terminal.STORE()), abi.encodeWithSignature("PRICES()"), abi.encode(address(0xdead)));
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_BindingMismatch.selector);
        _deployment.deployFor(_core);
    }

    function test_allNetworkFoldersMatchCurrentCoreLayout() public view {
        assertEq(_deployment.network(1), "ethereum");
        assertEq(_deployment.network(10), "optimism");
        assertEq(_deployment.network(8453), "base");
        assertEq(_deployment.network(42_161), "arbitrum");
        assertEq(_deployment.network(11_155_111), "sepolia");
        assertEq(_deployment.network(11_155_420), "optimism_sepolia");
        assertEq(_deployment.network(84_532), "base_sepolia");
        assertEq(_deployment.network(421_614), "arbitrum_sepolia");
    }

    function test_rejectsUnsupportedChain() public {
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_UnsupportedChain.selector);
        _deployment.network(31_337);
    }

    function test_loadsFlatCoreArtifactsWithoutForwarder() public {
        vm.chainId(11_155_111);
        string memory root = _writeCoreArtifacts(11_155_111);
        JBStickyCoreDeployment memory loaded = _deployment.loadCore(root);
        assertEq(address(loaded.controller), address(_core.controller));
        assertEq(address(loaded.terminal), address(_core.terminal));
    }

    function test_rejectsWrongCoreArtifactChain() public {
        vm.chainId(11_155_111);
        string memory root = _writeCoreArtifacts(1);
        vm.expectPartialRevert(JBStickyDeployment.JBStickyDeployment_ChainMismatch.selector);
        _deployment.loadCore(root);
    }

    function test_verifiedManifestRecordsAllRuntimeHashes() public {
        vm.chainId(11_155_111);
        JBStickyDeploymentAddresses memory deployed = _deployment.deployFor(_core);
        _deployment.writeManifest(_core, deployed);
        string memory json = vm.readFile("deployments/sepolia/test.json");
        assertEq(vm.parseJsonAddress(json, ".deployer"), deployed.deployer);
        assertEq(vm.parseJsonBytes32(json, ".hookCodehash"), deployed.hook.codehash);
        assertEq(vm.parseJsonBytes32(json, ".autoStickCodehash"), deployed.autoStick.codehash);
        assertEq(vm.parseJsonUint(json, ".chainId"), 11_155_111);
        assertEq(vm.parseJsonString(json, ".kind"), "test");
    }

    function _writeCoreArtifacts(uint256 chainId) internal returns (string memory root) {
        root = string.concat("deployments/_test/", vm.toString(chainId));
        vm.createDir(string.concat(root, "/sepolia"), true);
        _writeArtifact(root, "JBController", address(_core.controller), chainId);
        _writeArtifact(root, "JBDirectory", address(_core.directory), chainId);
        _writeArtifact(root, "JBMultiTerminal", address(_core.terminal), chainId);
    }

    function _writeArtifact(string memory root, string memory name, address target, uint256 chainId) internal {
        string memory key = string.concat("artifact-", name);
        vm.serializeAddress(key, "address", target);
        string memory json = vm.serializeString(key, "chainId", vm.toString(bytes32(chainId)));
        vm.writeJson(json, string.concat(root, "/sepolia/", name, ".json"));
    }
}
