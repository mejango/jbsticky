// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Why a `(projectId, holder)` pair can or cannot compound right now.
/// @dev `Ready` means all previewed conditions permit an automated compound.
/// `Disabled` means the holder has not enabled auto-stick.
/// `InvalidProject` means the deployer cannot resolve the project's underlying and share tokens.
/// `Cooldown` means the minimum time since the last automated compound has not elapsed.
/// `BelowMinimum` means the collectable reward is below the holder's configured minimum.
/// `NotTrusted` means the hook does not accept the adapter as a payer for the holder.
/// `InsufficientAllowance` means the holder's underlying-token approval cannot cover the reward.
/// `ZeroIssuance` means the terminal preview cannot issue shares for the reward.
enum AutoStickStatus {
    Ready,
    Disabled,
    InvalidProject,
    Cooldown,
    BelowMinimum,
    NotTrusted,
    InsufficientAllowance,
    ZeroIssuance
}
