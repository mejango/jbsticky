// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Creates and locates per-Sticky-token reward receivers and forwards settlement requests.
/// @dev Each receiver address identifies its rewarded holder pool when a bridge delivers plain ERC-20 tokens.
/// A receiver's address can be used as a sucker-bridge beneficiary before the receiver is deployed.
/// @dev Receiver addresses match across chains only when the factory address, distributor address, receiver creation
/// code, and sticky token address all match. ERC-20 tokens arriving in a receiver can be settled as rewards for its
/// holders. Project-token credits minted by a sucker claim (a destination project without an ERC-20) and native ETH
/// cannot be settled, so funders must bridge only to chains where the reward project has an ERC-20 and must not send
/// ETH.
interface IJBStickyRewardReceiverFactory {
    /// @notice Emitted when a receiver is deployed for a sticky token.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @param receiver The deployed receiver.
    /// @param caller The address that deployed the receiver.
    event DeployReceiver(address indexed stickyToken, address receiver, address caller);

    /// @notice Emitted when a receiver's balance is settled into the rewards distributor.
    /// @param stickyToken The sticky token whose holders were rewarded.
    /// @param token The reward token settled.
    /// @param amount The amount settled.
    /// @param caller The address that triggered the settlement.
    event Settle(address indexed stickyToken, IERC20 indexed token, uint256 amount, address caller);

    /// @notice The distributor receivers settle rewards into.
    /// @return distributor The distributor receivers settle rewards into.
    function DISTRIBUTOR() external view returns (IJBDistributor distributor);

    /// @notice The receiver deployed for a sticky token, or the zero address if it hasn't been deployed yet.
    /// @param stickyToken The sticky token to get the receiver of.
    /// @return receiver The deployed receiver, or the zero address if it has not been deployed.
    function receiverOf(address stickyToken) external view returns (address receiver);

    /// @notice The deterministic receiver address for a sticky token, whether or not it has been deployed.
    /// @dev Matches across chains only when the factory address, distributor address, receiver creation code, and
    /// sticky token address all match.
    /// @param stickyToken The sticky token to predict the receiver of.
    /// @return receiver The predicted receiver address.
    function predictReceiverOf(address stickyToken) external view returns (address receiver);

    /// @notice Deploys the receiver for a sticky token at its deterministic address.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @return receiver The deployed receiver.
    function deployReceiverFor(address stickyToken) external returns (address receiver);

    /// @notice Settles a receiver's balance of a token into the rewards distributor, deploying the receiver if needed.
    /// @param stickyToken The sticky token whose holders should be rewarded.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settleFor(address stickyToken, IERC20 token) external returns (uint256 amount);
}
