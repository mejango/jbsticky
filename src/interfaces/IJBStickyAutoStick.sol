// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBAutoStickStatus} from "../enums/JBAutoStickStatus.sol";
import {IJBStickyDeployer} from "./IJBStickyDeployer.sol";
import {IJBStickyHook} from "./IJBStickyHook.sol";

/// @notice Auto-compounds vested underlying-token rewards back into the same holder's sticky position.
interface IJBStickyAutoStick {
    /// @notice Emitted when a keeper starts vesting a holder's eligible reward rounds.
    /// @param projectId The ID of the sticky project the vesting belongs to.
    /// @param holder The holder whose rewards began vesting.
    /// @param token The underlying token that began vesting.
    /// @param caller The address that triggered the vesting.
    event BeganAutoStickVesting(
        uint256 indexed projectId, address indexed holder, address indexed token, address caller
    );

    /// @notice Emitted when vested rewards are collected and stuck back into the holder's position.
    /// @param projectId The ID of the sticky project compounded into.
    /// @param holder The holder whose rewards were compounded.
    /// @param token The underlying token that was compounded.
    /// @param underlyingAmount The underlying-token amount collected and stuck.
    /// @param stickyTokenCount The sticky tokens minted to the holder, as a fixed point number with 18 decimals.
    /// @param caller The address that triggered the compound.
    event AutoStuck(
        uint256 indexed projectId,
        address indexed holder,
        address indexed token,
        uint256 underlyingAmount,
        uint256 stickyTokenCount,
        address caller
    );

    /// @notice Emitted when a holder changes their auto-stick configuration.
    /// @param projectId The ID of the sticky project the configuration applies to.
    /// @param holder The holder whose configuration changed.
    /// @param enabled Whether auto-stick is now on.
    /// @param minimumAmount The smallest reward worth compounding, in the underlying token's decimals.
    /// @param cooldown The minimum number of seconds between compounds.
    /// @param caller The address that set the configuration.
    event SetAutoStick(
        uint256 indexed projectId,
        address indexed holder,
        bool enabled,
        uint128 minimumAmount,
        uint48 cooldown,
        address caller
    );

    /// @notice The deployer whose sticky projects this adapter serves.
    function DEPLOYER() external view returns (IJBStickyDeployer);

    /// @notice The distributor vested rewards are collected from.
    function DISTRIBUTOR() external view returns (IJBDistributor);

    /// @notice The data hook that gates third-party stakes and tracks positions.
    function HOOK() external view returns (IJBStickyHook);

    /// @notice The terminal sticky projects are paid through.
    function TERMINAL() external view returns (IJBTerminal);

    /// @notice The contract managing token minting and burning for projects.
    function TOKENS() external view returns (IJBTokens);

    /// @notice A holder's auto-stick configuration for a sticky project.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder to get the configuration of.
    function configOf(
        uint256 projectId,
        address holder
    )
        external
        view
        returns (uint128 minimumAmount, uint48 cooldown, uint48 lastCompoundedAt, bool enabled);

    /// @notice Why a holder's next compound can or cannot happen right now, plus the reads the UI needs.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder to check.
    /// @return status The current auto-stick status.
    /// @return collectableAmount The underlying-token amount currently collectable from the distributor.
    /// @return allowance The holder's current underlying-token allowance to this adapter.
    /// @return nextCompoundAt The earliest timestamp the next compound can happen.
    function statusOf(
        uint256 projectId,
        address holder
    )
        external
        view
        returns (JBAutoStickStatus status, uint256 collectableAmount, uint256 allowance, uint256 nextCompoundAt);

    /// @notice Starts vesting a holder's eligible reward rounds for the project's underlying token.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose rewards should begin vesting.
    function beginVestingFor(uint256 projectId, address holder) external;

    /// @notice Collects a holder's vested underlying-token rewards and sticks them back into their position.
    /// @param projectId The ID of the sticky project to compound into.
    /// @param holder The holder whose rewards are compounded.
    /// @return underlyingAmount The underlying-token amount collected and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the holder, as a fixed point number with 18 decimals.
    function compoundFor(uint256 projectId, address holder)
        external
        returns (uint256 underlyingAmount, uint256 stickyTokenCount);

    /// @notice Claims the caller's vested underlying-token rewards and sticks them, atomically, in one call.
    /// @param projectId The ID of the sticky project whose rewards are claimed and stuck.
    /// @return underlyingAmount The underlying-token amount claimed and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the caller, as a fixed point number with 18 decimals.
    function stickRewardsFor(uint256 projectId)
        external
        returns (uint256 underlyingAmount, uint256 stickyTokenCount);

    /// @notice Sets the caller's auto-stick configuration for a sticky project.
    /// @param projectId The ID of the sticky project.
    /// @param enabled Whether auto-stick should be on.
    /// @param minimumAmount The smallest reward worth compounding, in the underlying token's decimals. Non-zero.
    /// @param cooldown The minimum number of seconds between compounds.
    function setConfigFor(uint256 projectId, bool enabled, uint128 minimumAmount, uint48 cooldown) external;
}
