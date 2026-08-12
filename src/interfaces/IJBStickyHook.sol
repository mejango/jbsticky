// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import {JBStickyTranche} from "../structs/JBStickyTranche.sol";

/// @notice A data hook that tracks staking positions for sticky projects: per-deposit tranches, LIFO unstaking, and a
/// person-level streak clock.
interface IJBStickyHook is IJBRulesetDataHook, IJBPayHook, IJBCashOutHook {
    /// @notice Emitted when an address is allowed to airdrop stakes to any holder of a sticky project.
    /// @param projectId The ID of the sticky project the sender can airdrop to.
    /// @param granter The address allowed to airdrop.
    /// @param caller The address that set the granter.
    event SetGranter(uint256 indexed projectId, address indexed granter, address caller);

    /// @notice Emitted when a sticky project's token is registered as its transfer reporter.
    /// @param projectId The ID of the sticky project.
    /// @param token The sticky token allowed to report transfers.
    /// @param caller The address that registered the token.
    event SetToken(uint256 indexed projectId, address token, address caller);

    /// @notice Emitted when a holder allows or disallows a sender to add stakes to their position.
    /// @param projectId The ID of the sticky project the trust applies to.
    /// @param holder The holder whose position the sender can add to.
    /// @param sender The sender being trusted or untrusted.
    /// @param trusted Whether the sender is now trusted.
    event SetTrustedSender(uint256 indexed projectId, address indexed holder, address indexed sender, bool trusted);

    /// @notice Emitted when tokens are staked, creating a new tranche.
    /// @param projectId The ID of the sticky project being staked to.
    /// @param holder The address the staked position belongs to.
    /// @param payer The address the staked tokens came from.
    /// @param count The number of staked project tokens minted for the stake, as a fixed point number with 18 decimals.
    /// @param stakedBalance The holder's staked balance after the stake, as a fixed point number with 18 decimals.
    /// @param caller The address that triggered the stake.
    event Staked(
        uint256 indexed projectId,
        address indexed holder,
        address payer,
        uint256 count,
        uint256 stakedBalance,
        address caller
    );

    /// @notice Emitted when a holder's streak ends because their staked balance reached zero.
    /// @param projectId The ID of the sticky project the streak belongs to.
    /// @param holder The address whose streak ended.
    /// @param duration The number of seconds the streak lasted.
    /// @param caller The address that triggered the unstake which ended the streak.
    event StreakEnded(uint256 indexed projectId, address indexed holder, uint256 duration, address caller);

    /// @notice Emitted when a holder's streak starts because their staked balance became non-zero.
    /// @param projectId The ID of the sticky project the streak belongs to.
    /// @param holder The address whose streak started.
    /// @param caller The address that triggered the stake which started the streak.
    event StreakStarted(uint256 indexed projectId, address indexed holder, address caller);

    /// @notice Emitted when tokens are unstaked, consuming tranches newest-first.
    /// @param projectId The ID of the sticky project being unstaked from.
    /// @param holder The address the staked position belongs to.
    /// @param count The number of staked project tokens burned by the unstake, as a fixed point number with 18
    /// decimals.
    /// @param stakedBalance The holder's staked balance after the unstake, as a fixed point number with 18 decimals.
    /// @param caller The address that triggered the unstake.
    event Unstaked(
        uint256 indexed projectId, address indexed holder, uint256 count, uint256 stakedBalance, address caller
    );

    /// @notice The address allowed to set a project's granters, once, at launch.
    function DEPLOYER() external view returns (address);

    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The duration of a holder's active streak, in seconds.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    /// @return The number of seconds since the holder's staked balance last became non-zero, or 0 if nothing is
    /// staked.
    function currentStreakOf(uint256 projectId, address holder) external view returns (uint256);

    /// @notice Whether an address can airdrop stakes to any holder of a sticky project.
    /// @param projectId The ID of the sticky project to check.
    /// @param granter The address to check.
    function isGranterOf(uint256 projectId, address granter) external view returns (bool);

    /// @notice Whether a holder allows a sender to add stakes to their position.
    /// @param projectId The ID of the sticky project to check.
    /// @param holder The holder whose position would be added to.
    /// @param sender The sender to check.
    function isTrustedSenderOf(uint256 projectId, address holder, address sender) external view returns (bool);

    /// @notice The longest streak a holder has ever had, including their active streak.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    /// @return The holder's longest streak duration, in seconds.
    function longestStreakOf(uint256 projectId, address holder) external view returns (uint256);

    /// @notice The total number of staked project tokens a holder has, as a fixed point number with 18 decimals.
    /// @param projectId The ID of the sticky project to check the balance of.
    /// @param holder The address to check the balance of.
    function stakedBalanceOf(uint256 projectId, address holder) external view returns (uint256);

    /// @notice The timestamp at which a holder's active streak started, or 0 if nothing is staked.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    function streakStartOf(uint256 projectId, address holder) external view returns (uint256);

    /// @notice The sticky token allowed to report transfers for a project.
    /// @param projectId The ID of the sticky project to get the token of.
    function tokenOf(uint256 projectId) external view returns (address);

    /// @notice The number of tranches a holder has.
    /// @param projectId The ID of the sticky project to check the tranches of.
    /// @param holder The address to check the tranches of.
    function trancheCountOf(uint256 projectId, address holder) external view returns (uint256);

    /// @notice A holder's tranches, oldest first.
    /// @param projectId The ID of the sticky project to get the tranches of.
    /// @param holder The address to get the tranches of.
    function tranchesOf(uint256 projectId, address holder) external view returns (JBStickyTranche[] memory);

    /// @notice Moves staked accounting between holders for a transferable sticky token: the sender's newest
    /// tranches are consumed and the receiver gets a fresh tranche — transfers restart the clock on moved tokens.
    /// @dev Can only be called by the project's registered sticky token.
    /// @param projectId The ID of the sticky project the transfer belongs to.
    /// @param from The holder the tokens moved from.
    /// @param to The holder the tokens moved to.
    /// @param amount The number of tokens moved, as a fixed point number with 18 decimals.
    function recordTransfer(uint256 projectId, address from, address to, uint256 amount) external;

    /// @notice Registers the sticky token allowed to report transfers for a project.
    /// @dev Can only be called by the deployer, which calls it once at launch.
    /// @param projectId The ID of the sticky project.
    /// @param token The sticky token.
    function setTokenFor(uint256 projectId, address token) external;

    /// @notice Allows addresses to airdrop stakes to any holder of a sticky project.
    /// @dev Can only be called by the deployer, which calls it once at launch.
    /// @param projectId The ID of the sticky project the senders can airdrop to.
    /// @param granters The addresses allowed to airdrop.
    function setGrantersFor(uint256 projectId, address[] calldata granters) external;

    /// @notice Allows or disallows a sender to add stakes to the caller's position.
    /// @param projectId The ID of the sticky project the trust applies to.
    /// @param sender The sender to trust or untrust.
    /// @param trusted Whether the sender should be trusted.
    function setTrustedSenderFor(uint256 projectId, address sender, bool trusted) external;
}
