// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {IJBStickyHook} from "./IJBStickyHook.sol";

/// @notice The immutable bindings of a Sticky token: the project it represents, the hook that records its tranches,
/// its transfer policy, and the registry that mints and burns it.
interface IJBStickyToken {
    /// @notice The hook that tracks tranches and streaks, notified when tokens burn or transfer between holders.
    /// @return hook The Sticky hook.
    function HOOK() external view returns (IJBStickyHook hook);

    /// @notice The ID of the sticky project this token belongs to.
    /// @return projectId The project ID the token is permanently bound to.
    function PROJECT_ID() external view returns (uint256 projectId);

    /// @notice Whether transfers between accounts revert.
    /// @return soulbound Whether the token is soulbound.
    function SOULBOUND() external view returns (bool soulbound);

    /// @notice The contract that manages minting and burning of this token.
    /// @return tokens The token registry.
    function TOKENS() external view returns (IJBTokens tokens);
}
