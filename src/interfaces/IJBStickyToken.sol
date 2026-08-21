// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The subset of `JBStickyToken` that `JBStickyDistributor` needs to resolve the sticky project a token
/// belongs to.
interface IJBStickyToken {
    /// @notice The ID of the sticky project this token belongs to.
    function PROJECT_ID() external view returns (uint256);
}
