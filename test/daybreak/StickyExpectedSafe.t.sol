// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";

/// @notice Verifies that Sphinx Safe drift is rejected before deployment dependencies are loaded.
contract StickyExpectedSafeTest is Test {
    /// @notice The pinned Sphinx version stores its helper at slot 17 in the deployment script.
    bytes32 private constant _SPHINX_UTILS_SLOT = bytes32(uint256(17));

    /// @notice A wrong Safe returned by Sphinx stops `run` before its missing core artifacts can be read.
    function test_runRejectsUnexpectedSafeBeforeLoadingCore() public {
        Deploy deployment = new Deploy();
        address sphinxUtils = address(uint160(uint256(vm.load(address(deployment), _SPHINX_UTILS_SLOT))));
        address unexpected = makeAddr("unexpected Sphinx Safe");

        vm.mockCall(
            sphinxUtils,
            abi.encodeWithSignature("getGnosisSafeProxyAddress(address)", address(deployment)),
            abi.encode(unexpected)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.Deploy_UnexpectedSafe.selector, 0xd5136c794ee43BEf1eD4cF1eB6DEe45b7F803437, unexpected
            )
        );
        deployment.run();
    }
}
