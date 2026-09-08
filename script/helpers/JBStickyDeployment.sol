// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {Script} from "forge-std/Script.sol";

import {JBStickyAutoStick} from "../../src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "../../src/JBStickyDeployer.sol";
import {JBStickyHook} from "../../src/JBStickyHook.sol";
import {JBStickyRewardPockets} from "../../src/JBStickyRewardPockets.sol";
import {JBStickyCoreDeployment} from "../structs/JBStickyCoreDeployment.sol";
import {JBStickyDeploymentAddresses} from "../structs/JBStickyDeploymentAddresses.sol";
import {JBStickyImmutableReference} from "../structs/JBStickyImmutableReference.sol";

/// @notice Shared, restartable Sticky deployment and verification logic.
/// @dev Only the canonical CREATE2 factory receives transactions. Runtime comparison uses compiler-reported
/// immutable offsets, followed by explicit checks of every immutable dependency and distributor setting.
abstract contract JBStickyDeployment is Script {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice A deployed contract has unexpected immutable dependencies or configuration.
    error JBStickyDeployment_BindingMismatch(address target, string binding);
    /// @notice A core deployment artifact belongs to a different chain than the connected RPC.
    error JBStickyDeployment_ChainMismatch(string path, uint256 expected, uint256 actual);
    /// @notice The deterministic factory did not deploy code at the predicted address.
    error JBStickyDeployment_DeploymentFailed(address predicted);
    /// @notice The compiler artifact has unsupported or inconsistent immutable reference data.
    error JBStickyDeployment_InvalidArtifact(string name);
    /// @notice A required deployed contract has no runtime code.
    error JBStickyDeployment_MissingCode(address target);
    /// @notice Deployed executable bytecode differs from the expected compiled artifact.
    error JBStickyDeployment_RuntimeMismatch(address target, string name);
    /// @notice The connected chain has no supported core deployment folder.
    error JBStickyDeployment_UnsupportedChain(uint256 chainId);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The canonical deterministic deployment proxy used throughout Juicebox V6.
    address public constant DETERMINISTIC_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Salt retained from the original Sticky deployment script.
    bytes32 public constant STICKY_SALT = "JBStickyDeployerV6";

    /// @notice Salt retained from the original auto-stick deployment script.
    bytes32 public constant AUTO_STICK_SALT = "JBStickyAutoStickV6";

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    bytes32 private constant _FACTORY_CODEHASH = keccak256(
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    );

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys missing singletons, preserving and checking already deployed contracts.
    /// @param core The already verified core deployment.
    /// @return deployed The complete deployment addresses.
    function _deploy(JBStickyCoreDeployment memory core)
        internal
        returns (JBStickyDeploymentAddresses memory deployed)
    {
        _verifyCore(core);
        _verifyFactory();
        deployed = _predict(core);
        _deployIfNeeded({name: "JBStickyDeployer", salt: STICKY_SALT, args: abi.encode(core.controller, core.terminal)});
        _verifyDeployer({core: core, deployed: deployed});
        _deployIfNeeded({name: "JBTokenDistributor", salt: STICKY_SALT, args: _distributorArgs(core)});
        _verifyDistributor({core: core, deployed: deployed});
        _deployIfNeeded({name: "JBStickyRewardPockets", salt: STICKY_SALT, args: abi.encode(deployed.distributor)});
        _deployIfNeeded({
            name: "JBStickyAutoStick", salt: AUTO_STICK_SALT, args: abi.encode(deployed.deployer, deployed.distributor)
        });
        _verify({core: core, deployed: deployed});
    }

    /// @notice Deploys a contract through the canonical factory if its predicted address has no code.
    /// @param name The compiled artifact name.
    /// @param salt The deployment salt.
    /// @param args The ABI-encoded constructor arguments.
    /// @return predicted The expected deployment address.
    function _deployIfNeeded(string memory name, bytes32 salt, bytes memory args) internal returns (address predicted) {
        bytes memory initCode = abi.encodePacked(vm.getCode(string.concat(name, ".sol:", name)), args);
        predicted =
            vm.computeCreate2Address({salt: salt, initCodeHash: keccak256(initCode), deployer: DETERMINISTIC_FACTORY});
        if (predicted.code.length == 0) {
            (bool success,) = DETERMINISTIC_FACTORY.call(abi.encodePacked(salt, initCode));
            if (!success || predicted.code.length == 0) revert JBStickyDeployment_DeploymentFailed(predicted);
        }
        _verifyRuntime({name: name, target: predicted});
    }

    /// @notice Writes a manifest only after validating all deployed code and bindings.
    /// @dev A deployment simulation is deliberately a separate file from a read-only live verification.
    /// @param core The core dependencies.
    /// @param deployed The deployed Sticky addresses.
    /// @param kind Either `simulation` or `verified`; callers define which state they inspected.
    function _writeManifest(
        JBStickyCoreDeployment memory core,
        JBStickyDeploymentAddresses memory deployed,
        string memory kind
    )
        internal
    {
        _verify({core: core, deployed: deployed});
        string memory key = string.concat("sticky-", vm.toString(block.chainid), "-", kind);
        vm.serializeString({objectKey: key, valueKey: "kind", value: kind});
        vm.serializeUint({objectKey: key, valueKey: "chainId", value: block.chainid});
        vm.serializeUint({objectKey: key, valueKey: "blockNumber", value: block.number});
        vm.serializeUint({objectKey: key, valueKey: "timestamp", value: block.timestamp});
        vm.serializeBytes32({
            objectKey: key,
            valueKey: "parentBlockHash",
            value: block.number == 0 ? bytes32(0) : blockhash(block.number - 1)
        });
        vm.serializeString({
            objectKey: key,
            valueKey: "revision",
            value: vm.envOr({name: "STICKY_REVISION", defaultValue: string("unrecorded")})
        });
        _serializeContract({key: key, name: "create2Factory", target: DETERMINISTIC_FACTORY});
        _serializeContract({key: key, name: "controller", target: address(core.controller)});
        _serializeContract({key: key, name: "directory", target: address(core.directory)});
        _serializeContract({key: key, name: "terminal", target: address(core.terminal)});
        _serializeContract({key: key, name: "deployer", target: deployed.deployer});
        _serializeContract({key: key, name: "hook", target: deployed.hook});
        _serializeContract({key: key, name: "distributor", target: deployed.distributor});
        _serializeContract({key: key, name: "pockets", target: deployed.pockets});
        _serializeContract({key: key, name: "autoStick", target: deployed.autoStick});
        vm.serializeBytes32({objectKey: key, valueKey: "stickySalt", value: STICKY_SALT});
        string memory json = vm.serializeBytes32({objectKey: key, valueKey: "autoStickSalt", value: AUTO_STICK_SALT});
        string memory directory = string.concat("deployments/", _network(block.chainid));
        vm.createDir({path: directory, recursive: true});
        vm.writeJson({json: json, path: string.concat(directory, "/", kind, ".json")});
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Loads exactly the three required artifacts from the core's flat deployment tree.
    /// @return core The validated core dependencies for the connected chain.
    function _loadCore() internal view returns (JBStickyCoreDeployment memory core) {
        return _loadCoreFrom(
            vm.envOr({
                name: "NANA_CORE_DEPLOYMENT_PATH", defaultValue: string("node_modules/@bananapus/core-v6/deployments")
            })
        );
    }

    /// @notice Loads the required core artifacts from a specified flat deployment directory.
    /// @param root The path containing one folder per network.
    /// @return core The validated core dependencies.
    function _loadCoreFrom(string memory root) internal view returns (JBStickyCoreDeployment memory core) {
        string memory directory = string.concat(root, "/", _network(block.chainid), "/");
        core.controller = IJBController(_readAddress(string.concat(directory, "JBController.json")));
        core.directory = IJBDirectory(_readAddress(string.concat(directory, "JBDirectory.json")));
        core.terminal = IJBMultiTerminal(_readAddress(string.concat(directory, "JBMultiTerminal.json")));
        _verifyCore(core);
    }

    /// @notice Maps supported chain IDs to the committed core artifact folder names.
    /// @param chainId The chain ID to resolve.
    /// @return network The core artifact folder name.
    function _network(uint256 chainId) internal pure returns (string memory network) {
        if (chainId == 1) return "ethereum";
        if (chainId == 10) return "optimism";
        if (chainId == 8453) return "base";
        if (chainId == 42_161) return "arbitrum";
        if (chainId == 11_155_111) return "sepolia";
        if (chainId == 11_155_420) return "optimism_sepolia";
        if (chainId == 84_532) return "base_sepolia";
        if (chainId == 421_614) return "arbitrum_sepolia";
        revert JBStickyDeployment_UnsupportedChain(chainId);
    }

    /// @notice Predicts every singleton, including the hook created by the deployer's constructor.
    /// @param core The core dependencies included in constructor arguments.
    /// @return deployed The predicted deployment addresses.
    function _predict(JBStickyCoreDeployment memory core)
        internal
        view
        returns (JBStickyDeploymentAddresses memory deployed)
    {
        deployed.deployer = _predictContract({
            name: "JBStickyDeployer", salt: STICKY_SALT, args: abi.encode(core.controller, core.terminal)
        });
        deployed.hook = vm.computeCreateAddress({deployer: deployed.deployer, nonce: 1});
        deployed.distributor =
            _predictContract({name: "JBTokenDistributor", salt: STICKY_SALT, args: _distributorArgs(core)});
        deployed.pockets = _predictContract({
            name: "JBStickyRewardPockets", salt: STICKY_SALT, args: abi.encode(deployed.distributor)
        });
        deployed.autoStick = _predictContract({
            name: "JBStickyAutoStick", salt: AUTO_STICK_SALT, args: abi.encode(deployed.deployer, deployed.distributor)
        });
    }

    /// @notice Checks a complete deployment against current compilation and all intended immutable settings.
    /// @param core The expected core dependencies.
    /// @param deployed The expected Sticky addresses.
    function _verify(JBStickyCoreDeployment memory core, JBStickyDeploymentAddresses memory deployed) internal view {
        _verifyCore(core);
        _verifyFactory();
        if (keccak256(abi.encode(deployed)) != keccak256(abi.encode(_predict(core)))) {
            revert JBStickyDeployment_BindingMismatch({target: deployed.deployer, binding: "CREATE2 predictions"});
        }
        _verifyDeployer({core: core, deployed: deployed});
        _verifyDistributor({core: core, deployed: deployed});
        _verifyRuntime({name: "JBStickyRewardPockets", target: deployed.pockets});
        _verifyRuntime({name: "JBStickyAutoStick", target: deployed.autoStick});
        if (address(JBStickyRewardPockets(deployed.pockets).DISTRIBUTOR()) != deployed.distributor) {
            revert JBStickyDeployment_BindingMismatch({target: deployed.pockets, binding: "DISTRIBUTOR"});
        }
        JBStickyAutoStick adapter = JBStickyAutoStick(deployed.autoStick);
        if (
            address(adapter.DEPLOYER()) != deployed.deployer || address(adapter.DISTRIBUTOR()) != deployed.distributor
                || address(adapter.HOOK()) != deployed.hook || address(adapter.TERMINAL()) != address(core.terminal)
                || address(adapter.TOKENS()) != address(core.controller.TOKENS())
        ) {
            revert JBStickyDeployment_BindingMismatch({target: deployed.autoStick, binding: "adapter dependencies"});
        }
    }

    /// @notice Validates code existence and the shared core controller, directory, terminal, and registry bindings.
    /// @param core The core deployment to inspect.
    function _verifyCore(JBStickyCoreDeployment memory core) internal view {
        _requireCode(address(core.controller));
        _requireCode(address(core.directory));
        _requireCode(address(core.terminal));
        _requireCode(address(core.controller.TOKENS()));
        _requireCode(address(core.controller.PROJECTS()));
        _requireCode(address(core.controller.PRICES()));
        _requireCode(address(core.controller.RULESETS()));
        _requireCode(address(core.controller.SPLITS()));
        _requireCode(address(core.terminal.STORE()));
        if (
            address(core.controller.DIRECTORY()) != address(core.directory)
                || address(core.terminal.DIRECTORY()) != address(core.directory)
                || address(core.terminal.STORE().DIRECTORY()) != address(core.directory)
                || address(core.terminal.STORE().PRICES()) != address(core.controller.PRICES())
                || address(core.directory.PROJECTS()) != address(core.controller.PROJECTS())
                || address(core.terminal.PROJECTS()) != address(core.controller.PROJECTS())
                || address(core.terminal.TOKENS()) != address(core.controller.TOKENS())
                || address(core.terminal.SPLITS()) != address(core.controller.SPLITS())
        ) {
            revert JBStickyDeployment_BindingMismatch({target: address(core.controller), binding: "core dependencies"});
        }
    }

    /// @notice Checks exact compiled runtime, masking only compiler-declared immutable words.
    /// @dev Callers separately check every immutable value; runtime equality alone is insufficient.
    /// @param name The compiled artifact name.
    /// @param target The deployed contract to inspect.
    function _verifyRuntime(string memory name, address target) internal view {
        _requireCode(target);
        string memory artifact = string.concat("out/", name, ".sol/", name, ".json");
        string memory json = vm.readFile(artifact);
        bytes memory expected = vm.getDeployedCode(artifact);
        bytes memory actual = target.code;
        if (expected.length != actual.length) revert JBStickyDeployment_RuntimeMismatch({target: target, name: name});
        string memory root = ".deployedBytecode.immutableReferences";
        string[] memory keys = vm.parseJsonKeys({json: json, key: root});
        // Fail closed when future source changes add an immutable without adding its binding check below.
        if (keys.length != _immutableCount(name)) revert JBStickyDeployment_InvalidArtifact(name);
        // Foundry encodes the JSON object as one dynamic tuple: [offset, group offsets, group arrays].
        // Replace its leading tuple offset with the array length, then prepend the outer array offset. Child
        // offsets remain relative to the same group-offset block. Parse the large artifact only once.
        bytes memory groups = vm.parseJson({json: json, key: root});
        if (groups.length < 32 || _immutableWord({code: groups, start: 0}) != bytes32(uint256(32))) {
            revert JBStickyDeployment_InvalidArtifact(name);
        }
        uint256 count = keys.length;
        assembly ("memory-safe") {
            mstore(add(groups, 0x20), count)
        }
        JBStickyImmutableReference[][] memory references =
            abi.decode(abi.encodePacked(uint256(32), groups), (JBStickyImmutableReference[][]));
        for (uint256 i; i < references.length; i++) {
            JBStickyImmutableReference[] memory refs = references[i];
            if (refs.length == 0) revert JBStickyDeployment_InvalidArtifact(name);
            bytes32 immutableWord;
            for (uint256 j; j < refs.length; j++) {
                if (refs[j].length != 32 || refs[j].start + refs[j].length > actual.length) {
                    revert JBStickyDeployment_InvalidArtifact(name);
                }
                // Every occurrence of one immutable must agree, including uses outside its public getter.
                bytes32 word = _immutableWord({code: actual, start: refs[j].start});
                // Every current binding is an address or a bounded timing setting. Reject upper-bit pollution
                // before an address getter can normalize it while other code still consumes the original word.
                if (uint256(word) > type(uint160).max) {
                    revert JBStickyDeployment_RuntimeMismatch({target: target, name: name});
                }
                if (j == 0) immutableWord = word;
                else if (word != immutableWord) revert JBStickyDeployment_RuntimeMismatch({target: target, name: name});
                for (uint256 k; k < refs[j].length; k++) {
                    expected[refs[j].start + k] = 0;
                    actual[refs[j].start + k] = 0;
                }
            }
        }
        if (keccak256(actual) != keccak256(expected)) {
            revert JBStickyDeployment_RuntimeMismatch({target: target, name: name});
        }
    }

    //*********************************************************************//
    // ----------------------- private helpers --------------------------- //
    //*********************************************************************//

    /// @notice Encodes the immutable distributor policy.
    /// @param core The core dependencies.
    /// @return args The constructor arguments.
    function _distributorArgs(JBStickyCoreDeployment memory core) private pure returns (bytes memory args) {
        return abi.encode(
            core.directory, core.controller, address(0), address(0), uint256(7 days), uint256(4), uint48(3 * 365 days)
        );
    }

    /// @notice The number of immutable bindings explicitly checked for each deployment artifact.
    /// @param name The compiled artifact name.
    /// @return count The expected number of distinct compiler immutable groups.
    function _immutableCount(string memory name) private pure returns (uint256 count) {
        bytes32 nameHash = keccak256(bytes(name));
        if (nameHash == keccak256("JBStickyDeployer")) return 4;
        if (nameHash == keccak256("JBStickyHook")) return 2;
        if (nameHash == keccak256("JBTokenDistributor")) return 8;
        if (nameHash == keccak256("JBStickyRewardPockets")) return 1;
        if (nameHash == keccak256("JBStickyAutoStick")) return 5;
        revert JBStickyDeployment_InvalidArtifact(name);
    }

    /// @notice Reads an already range-checked immutable word.
    /// @param code The runtime bytecode.
    /// @param start The word's offset.
    /// @return word The immutable value.
    function _immutableWord(bytes memory code, uint256 start) private pure returns (bytes32 word) {
        assembly ("memory-safe") {
            word := mload(add(add(code, 0x20), start))
        }
    }

    /// @notice Predicts a contract's canonical CREATE2 address.
    /// @param name The compiled artifact name.
    /// @param salt The salt.
    /// @param args The constructor arguments.
    /// @return predicted The resulting address.
    function _predictContract(
        string memory name,
        bytes32 salt,
        bytes memory args
    )
        private
        view
        returns (address predicted)
    {
        return vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(vm.getCode(string.concat(name, ".sol:", name)), args)),
            deployer: DETERMINISTIC_FACTORY
        });
    }

    /// @notice Reads an artifact address only if its recorded chain matches the connected chain.
    /// @param path The artifact path.
    /// @return target The recorded deployed address.
    function _readAddress(string memory path) private view returns (address target) {
        string memory json = vm.readFile(path);
        uint256 chainId = vm.parseJsonUint({json: json, key: ".chainId"});
        if (chainId != block.chainid) {
            revert JBStickyDeployment_ChainMismatch({path: path, expected: block.chainid, actual: chainId});
        }
        target = vm.parseJsonAddress({json: json, key: ".address"});
        _requireCode(target);
    }

    /// @notice Rejects absent dependencies.
    /// @param target The expected contract address.
    function _requireCode(address target) private view {
        if (target.code.length == 0) revert JBStickyDeployment_MissingCode(target);
    }

    /// @notice Records an address and its complete live runtime hash in a manifest.
    /// @param key The manifest object key.
    /// @param name The manifest field prefix.
    /// @param target The contract to record.
    function _serializeContract(string memory key, string memory name, address target) private {
        vm.serializeAddress({objectKey: key, valueKey: name, value: target});
        vm.serializeBytes32({objectKey: key, valueKey: string.concat(name, "Codehash"), value: target.codehash});
    }

    /// @notice Verifies the factory and its constructor-created hook.
    /// @param core The expected core dependencies.
    /// @param deployed The predicted Sticky addresses.
    function _verifyDeployer(
        JBStickyCoreDeployment memory core,
        JBStickyDeploymentAddresses memory deployed
    )
        private
        view
    {
        _verifyRuntime({name: "JBStickyDeployer", target: deployed.deployer});
        _verifyRuntime({name: "JBStickyHook", target: deployed.hook});
        JBStickyDeployer factory = JBStickyDeployer(deployed.deployer);
        JBStickyHook hook = JBStickyHook(deployed.hook);
        if (
            address(factory.CONTROLLER()) != address(core.controller)
                || address(factory.TERMINAL()) != address(core.terminal)
                || address(factory.TOKENS()) != address(core.controller.TOKENS())
                || address(factory.HOOK()) != deployed.hook || hook.DEPLOYER() != deployed.deployer
                || address(hook.DIRECTORY()) != address(core.directory)
        ) {
            revert JBStickyDeployment_BindingMismatch({
                target: deployed.deployer, binding: "factory and hook dependencies"
            });
        }
    }

    /// @notice Verifies the distributor's immutable dependencies, policy, and creation time.
    /// @param core The expected core dependencies.
    /// @param deployed The predicted Sticky addresses.
    function _verifyDistributor(
        JBStickyCoreDeployment memory core,
        JBStickyDeploymentAddresses memory deployed
    )
        private
        view
    {
        _verifyRuntime({name: "JBTokenDistributor", target: deployed.distributor});
        JBTokenDistributor distributor = JBTokenDistributor(payable(deployed.distributor));
        if (
            address(distributor.DIRECTORY()) != address(core.directory)
                || address(distributor.CONTROLLER()) != address(core.controller)
                || address(distributor.REV_LOANS()) != address(0) || address(distributor.REV_OWNER()) != address(0)
                || distributor.ROUND_DURATION() != 7 days || distributor.VESTING_ROUNDS() != 4
                || distributor.CLAIM_DURATION() != 3 * 365 days || distributor.STARTING_TIMESTAMP() == 0
                || distributor.STARTING_TIMESTAMP() > block.timestamp
        ) {
            revert JBStickyDeployment_BindingMismatch({
                target: deployed.distributor, binding: "distributor dependencies and policy"
            });
        }
    }

    /// @notice Checks the canonical factory's exact runtime before making or trusting any deployments.
    function _verifyFactory() private view {
        if (DETERMINISTIC_FACTORY.codehash != _FACTORY_CODEHASH) {
            revert JBStickyDeployment_RuntimeMismatch({
                target: DETERMINISTIC_FACTORY, name: "canonical CREATE2 factory"
            });
        }
    }
}
