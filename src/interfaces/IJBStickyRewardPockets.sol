// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

/// @notice Deploys deterministic reward pockets that turn cross-chain arrivals into sticky rewards. A pocket's
/// address is the same on every chain, so a funder anywhere can bridge sucker-mapped project tokens with the pocket
/// as beneficiary — whatever lands in the pocket becomes rewards for its sticky token's holders.
interface IJBStickyRewardPockets {
    /// @notice Emitted when a pocket is deployed for a sticky token.
    /// @param stickyToken The sticky token the pocket collects rewards for.
    /// @param pocket The deployed pocket.
    /// @param caller The address that deployed the pocket.
    event DeployPocket(address indexed stickyToken, address pocket, address caller);

    /// @notice Emitted when a pocket's balance is settled into the rewards distributor.
    /// @param stickyToken The sticky token whose holders were rewarded.
    /// @param token The reward token settled.
    /// @param amount The amount settled.
    /// @param caller The address that triggered the settlement.
    event Settle(address indexed stickyToken, IERC20 indexed token, uint256 amount, address caller);

    /// @notice The distributor pockets settle rewards into.
    function DISTRIBUTOR() external view returns (IJBDistributor);

    /// @notice The pocket deployed for a sticky token, or the zero address if it hasn't been deployed yet.
    /// @param stickyToken The sticky token to get the pocket of.
    function pocketOf(address stickyToken) external view returns (address);

    /// @notice The deterministic pocket address for a sticky token, whether or not it has been deployed.
    /// @dev Identical on every chain this factory is deployed to, so it can be predicted from anywhere.
    /// @param stickyToken The sticky token to predict the pocket of.
    function predictPocketOf(address stickyToken) external view returns (address);

    /// @notice Deploys the pocket for a sticky token at its deterministic address.
    /// @param stickyToken The sticky token the pocket collects rewards for.
    /// @return pocket The deployed pocket.
    function deployPocketFor(address stickyToken) external returns (address pocket);

    /// @notice Settles a pocket's balance of a token into the rewards distributor, deploying the pocket if needed.
    /// @param stickyToken The sticky token whose holders should be rewarded.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settleFor(address stickyToken, IERC20 token) external returns (uint256 amount);
}
