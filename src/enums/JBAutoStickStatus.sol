// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Why a `(projectId, holder)` pair can or cannot compound right now.
/// @dev Existing ordinal values are stable; new statuses are appended.
enum JBAutoStickStatus {
    Ready,
    Disabled,
    InvalidProject,
    Cooldown,
    BelowMinimum,
    NotTrusted,
    InsufficientAllowance,
    ZeroIssuance
}
