// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Why a `(projectId, holder)` pair can or cannot compound right now, checked in this order.
enum JBAutoStickStatus {
    READY,
    DISABLED,
    INVALID_PROJECT,
    COOLDOWN,
    BELOW_MINIMUM,
    NOT_TRUSTED,
    INSUFFICIENT_ALLOWANCE
}
