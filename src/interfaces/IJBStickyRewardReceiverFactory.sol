// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJBStickyDistributor} from "./IJBStickyDistributor.sol";

/// @notice Creates and locates per-(Sticky token, reward group) reward receivers and forwards settlement requests.
/// @dev Each receiver address identifies its rewarded holder pool and group when a bridge delivers plain ERC-20
/// tokens. A receiver's address can be used as a sucker-bridge beneficiary before the receiver is deployed.
/// @dev Receiver addresses match across chains only when the factory address, distributor address, receiver creation
/// code, sticky token address and group all match. ERC-20 tokens arriving in a receiver can be settled as rewards
/// for its holders. Project-token credits minted by a sucker claim (a destination project without an ERC-20) and
/// native ETH cannot be settled, so funders must bridge only to chains where the reward project has an ERC-20 and
/// must not send ETH.
interface IJBStickyRewardReceiverFactory {
    /// @notice Emitted when a receiver is deployed for a sticky token and reward group.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @param receiver The deployed receiver.
    /// @param caller The address that deployed the receiver.
    event DeployReceiver(address indexed stickyToken, uint256 indexed groupId, address receiver, address caller);

    /// @notice Emitted when a receiver's balance is settled into the rewards distributor.
    /// @param stickyToken The sticky token whose holders were rewarded.
    /// @param groupId The reward group funded (0 = the default group).
    /// @param token The reward token settled.
    /// @param amount The amount settled.
    /// @param caller The address that triggered the settlement.
    event Settle(
        address indexed stickyToken, uint256 indexed groupId, IERC20 indexed token, uint256 amount, address caller
    );

    /// @notice The distributor receivers settle rewards into.
    /// @return distributor The distributor receivers settle rewards into.
    function DISTRIBUTOR() external view returns (IJBStickyDistributor distributor);

    /// @notice The deterministic receiver address for a sticky token and reward group, whether or not it has been
    /// deployed.
    /// @dev Matches across chains only when the factory address, distributor address, receiver creation code, sticky
    /// token address and group all match. Reverts for a group the distributor cannot fund.
    /// @param stickyToken The sticky token to predict the receiver of.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @return receiver The predicted receiver address.
    function predictReceiverOf(address stickyToken, uint256 groupId) external view returns (address receiver);

    /// @notice The receiver deployed for a sticky token and reward group, or the zero address if it hasn't been
    /// deployed yet.
    /// @param stickyToken The sticky token to get the receiver of.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @return receiver The deployed receiver, or the zero address if it has not been deployed.
    function receiverOf(address stickyToken, uint256 groupId) external view returns (address receiver);

    /// @notice Deploys the receiver for a sticky token and reward group at its deterministic address.
    /// @dev Reverts for a group the distributor cannot fund.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @return receiver The deployed receiver.
    function deployReceiverFor(address stickyToken, uint256 groupId) external returns (address receiver);

    /// @notice Settles a receiver's balance of a token into the rewards distributor, deploying the receiver if needed.
    /// @param stickyToken The sticky token whose holders should be rewarded.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settleFor(address stickyToken, uint256 groupId, IERC20 token) external returns (uint256 amount);
}
