// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Deterministic addresses for the Sticky singleton deployment.
/// @custom:member deployer The project factory.
/// @custom:member hook The factory's constructor-created accounting hook.
/// @custom:member distributor The shared reward distributor.
/// @custom:member pockets The reward pocket factory.
/// @custom:member autoStick The opt-in compounding adapter.
struct JBStickyDeploymentAddresses {
    address deployer;
    address hook;
    address distributor;
    address pockets;
    address autoStick;
}
