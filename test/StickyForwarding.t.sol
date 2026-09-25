// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBDistributor} from "@bananapus/distributor-v6/src/JBDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StickyAutoStick} from "../src/StickyAutoStick.sol";
import {StickyDeployer} from "../src/StickyDeployer.sol";
import {StickyDistributor} from "../src/StickyDistributor.sol";
import {StickyHook} from "../src/StickyHook.sol";
import {IStickyDistributor} from "../src/interfaces/IStickyDistributor.sol";
import {IStickyHook} from "../src/interfaces/IStickyHook.sol";

/// @notice A sponsor relays launches and holder actions through core's trusted forwarder, which appends the signer.
contract StickyForwardingTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The Sticky factory.
    StickyDeployer internal _deployer;

    /// @notice The reward distributor.
    StickyDistributor internal _distributor;

    /// @notice The auto-stick adapter.
    StickyAutoStick internal _autoStick;

    /// @notice The account that signs relayed requests.
    // forge-lint: disable-next-line(function-init-state)
    address internal _signer = makeAddr("signer");

    /// @notice An account that is not the forwarder.
    // forge-lint: disable-next-line(function-init-state)
    address internal _stranger = makeAddr("stranger");

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploys the Sticky suite against core, whose forwarder every Sticky contract adopts.
    function setUp() public override {
        super.setUp();
        _deployer = new StickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _distributor = new StickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: IStickyHook(address(_deployer.HOOK())),
            initialRoundDuration: 7 days,
            initialVestingRounds: 4,
            initialClaimDuration: 2 * 365 days
        });
        _autoStick = new StickyAutoStick({deployer: _deployer, distributor: IStickyDistributor(address(_distributor))});
    }

    /// @notice Every Sticky contract trusts exactly core's forwarder.
    function test_everyContractTrustsCoreForwarder() public view {
        assertEq(_deployer.trustedForwarder(), trustedForwarder());
        assertEq(StickyHook(address(_deployer.HOOK())).trustedForwarder(), trustedForwarder());
        assertEq(_distributor.trustedForwarder(), trustedForwarder());
        assertEq(_autoStick.trustedForwarder(), trustedForwarder());
    }

    /// @notice A relayed launch binds the share token's address to the signer, as a direct launch would.
    function test_relayedLaunchBindsTheSigner() public {
        uint256 projectId = _relayedLaunch();

        IJBToken token = jbTokens().tokenOf(projectId);
        address predicted = _deployer.predictStickyTokenOf({
            launcher: _signer,
            projectId: projectId,
            stakedToken: IERC20Metadata(address(usdcToken())),
            name: "Relayed",
            symbol: "RLY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        assertEq(address(token), predicted, "the token address is bound to the signer, not the forwarder");
        assertEq(jbProjects().ownerOf(projectId), address(_deployer));
    }

    /// @notice A relayed trust update applies to the signer's own position.
    function test_relayedTrustIsTheSigners() public {
        uint256 projectId = _relayedLaunch();
        StickyHook hook = StickyHook(address(_deployer.HOOK()));

        _relay({
            caller: trustedForwarder(),
            target: address(hook),
            // forge-lint: disable-next-line(boolean-cst)
            data: abi.encodeCall(StickyHook.setTrustedSenderFor, (projectId, _stranger, true)),
            signer: _signer
        });

        assertTrue(hook.isTrustedSenderOf({projectId: projectId, holder: _signer, sender: _stranger}));
        assertFalse(hook.isTrustedSenderOf({projectId: projectId, holder: trustedForwarder(), sender: _stranger}));
    }

    /// @notice An address appended by anyone but the forwarder is ignored.
    function test_anUntrustedSuffixCannotActForAnotherHolder() public {
        uint256 projectId = _relayedLaunch();
        StickyHook hook = StickyHook(address(_deployer.HOOK()));

        _relay({
            caller: _stranger,
            target: address(hook),
            // forge-lint: disable-next-line(boolean-cst)
            data: abi.encodeCall(StickyHook.setTrustedSenderFor, (projectId, _stranger, true)),
            signer: _signer
        });

        assertFalse(hook.isTrustedSenderOf({projectId: projectId, holder: _signer, sender: _stranger}));
        assertTrue(hook.isTrustedSenderOf({projectId: projectId, holder: _stranger, sender: _stranger}));
    }

    /// @notice A relayed auto-stick configuration is saved for the signer.
    function test_relayedAutoStickConfigIsTheSigners() public {
        uint256 projectId = _relayedLaunch();

        _relay({
            caller: trustedForwarder(),
            target: address(_autoStick),
            // forge-lint: disable-next-line(boolean-cst)
            data: abi.encodeCall(StickyAutoStick.setConfigFor, (projectId, true, 1, 1 days)),
            signer: _signer
        });

        // forge-lint: disable-next-line(unused-return)
        (,,, bool signerEnabled) = _autoStick.configOf({projectId: projectId, holder: _signer});
        // forge-lint: disable-next-line(unused-return)
        (,,, bool forwarderEnabled) = _autoStick.configOf({projectId: projectId, holder: trustedForwarder()});
        assertTrue(signerEnabled);
        assertFalse(forwarderEnabled);
    }

    /// @notice A relayed claim is authorized as the signer, so it cannot collect another holder's rewards.
    function test_relayedClaimIsAuthorizedAsTheSigner() public {
        uint256 projectId = _relayedLaunch();
        address hook = address(jbTokens().tokenOf(projectId));
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(_stranger));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdcToken()));

        (bool success, bytes memory reason) = _tryRelay({
            caller: trustedForwarder(),
            target: address(_distributor),
            data: abi.encodeCall(JBDistributor.collectVestedRewards, (hook, tokenIds, tokens, _signer)),
            signer: _signer
        });

        assertFalse(success);
        assertEq(
            reason, abi.encodeWithSelector(JBDistributor.JBDistributor_NoAccess.selector, hook, tokenIds[0], _signer)
        );
    }

    /// @notice Relayed ERC-20 funding pulls from the signer, never from the forwarder, even when the forwarder
    /// approved.
    function test_relayedFundPullsFromTheSigner() public {
        address hook = address(jbTokens().tokenOf(_relayedLaunch()));
        uint256 amount = 100e6;
        bytes memory data = abi.encodeWithSignature("fund(address,address,uint256)", hook, usdcToken(), amount);

        // Only the forwarder has funds and an allowance, so the relayed call cannot be paid from them.
        usdcToken().mint(trustedForwarder(), amount);
        vm.prank(trustedForwarder());
        // forge-lint: disable-next-line(unused-return)
        usdcToken().approve(address(_distributor), type(uint256).max);
        (bool success,) =
            _tryRelay({caller: trustedForwarder(), target: address(_distributor), data: data, signer: _signer});
        assertFalse(success, "the forwarder's allowance never funds a relayed call");

        // Once the signer approves, the same relayed call pulls from the signer.
        usdcToken().mint(_signer, amount);
        vm.prank(_signer);
        // forge-lint: disable-next-line(unused-return)
        usdcToken().approve(address(_distributor), type(uint256).max);
        _relay({caller: trustedForwarder(), target: address(_distributor), data: data, signer: _signer});

        assertEq(usdcToken().balanceOf(_signer), 0);
        assertEq(usdcToken().balanceOf(trustedForwarder()), amount);
        assertEq(usdcToken().balanceOf(address(_distributor)), amount);
    }

    /// @notice Terminal-only hook callbacks never accept the forwarder, even with a terminal address appended.
    function test_terminalCallbacksNeverTrustTheForwarder() public {
        uint256 projectId = _relayedLaunch();
        StickyHook hook = StickyHook(address(_deployer.HOOK()));
        JBAfterPayRecordedContext memory context;
        context.projectId = projectId;

        (bool success, bytes memory reason) = _tryRelay({
            caller: trustedForwarder(),
            target: address(hook),
            data: abi.encodeCall(StickyHook.afterPayRecordedWith, (context)),
            signer: address(jbMultiTerminal())
        });

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(StickyHook.StickyHook_CallerNotTerminal.selector, trustedForwarder()));
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Launches a Sticky project through the forwarder on the signer's behalf.
    /// @return projectId The launched project's ID.
    function _relayedLaunch() internal returns (uint256 projectId) {
        bytes memory result = _relay({
            caller: trustedForwarder(),
            target: address(_deployer),
            data: abi.encodeCall(
                StickyDeployer.deployStickyFor,
                // forge-lint: disable-next-line(boolean-cst)
                (IERC20Metadata(address(usdcToken())), "Relayed", "RLY", "", 0, new address[](0), false)
            ),
            signer: _signer
        });
        projectId = abi.decode(result, (uint256));
    }

    /// @notice Calls a target with the signer appended to the calldata, as an ERC-2771 forwarder does.
    /// @param caller The account making the call.
    /// @param target The contract to call.
    /// @param data The calldata before the appended signer.
    /// @param signer The address appended to the calldata.
    /// @return result The call's return data.
    function _relay(
        address caller,
        address target,
        bytes memory data,
        address signer
    )
        internal
        returns (bytes memory result)
    {
        bool success;
        (success, result) = _tryRelay({caller: caller, target: target, data: data, signer: signer});
        if (!success) {
            // forge-lint: disable-next-line(inline-assembly)
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @notice Calls a target with the signer appended to the calldata and returns the outcome instead of reverting.
    /// @param caller The account making the call.
    /// @param target The contract to call.
    /// @param data The calldata before the appended signer.
    /// @param signer The address appended to the calldata.
    /// @return success Whether the call succeeded.
    /// @return result The call's return or revert data.
    function _tryRelay(
        address caller,
        address target,
        bytes memory data,
        address signer
    )
        internal
        returns (bool success, bytes memory result)
    {
        vm.prank(caller);
        // forge-lint: disable-next-line(low-level-calls)
        (success, result) = target.call(abi.encodePacked(data, signer));
    }
}
