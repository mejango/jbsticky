// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {StickyRewardReceiver} from "./StickyRewardReceiver.sol";

import {IStickyDistributor} from "./interfaces/IStickyDistributor.sol";
import {IStickyRewardReceiverFactory} from "./interfaces/IStickyRewardReceiverFactory.sol";

/// @notice Creates and locates a separate reward receiver for each Sticky token and reward group, and forwards
/// settlement requests.
/// @dev Funds arrive at the per-(token, group) receiver, whose address identifies the rewarded holder pool and how
/// it is weighed. This factory predicts that address before deployment and deploys its immutable settlement logic
/// when needed. A funder can bridge sucker-mapped reward tokens to the receiver without adding suckers to the Sticky
/// project itself.
/// @dev Receivers settle ERC-20 balances only. Project-token credits minted by a sucker claim, which is what a
/// destination project without an ERC-20 receives, and native ETH cannot be settled and stay in the receiver.
/// Funders must bridge only to chains where the reward project has an ERC-20 and must not send ETH.
contract StickyRewardReceiverFactory is IStickyRewardReceiverFactory {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a receiver is requested for a group the distributor cannot fund.
    error StickyRewardReceiverFactory_InvalidGroupId(uint256 groupId);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The distributor receivers settle rewards into.
    IStickyDistributor public immutable override DISTRIBUTOR;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The receiver deployed for a sticky token and reward group, or the zero address if it hasn't been
    /// deployed yet.
    /// @custom:param stickyToken The sticky token the receiver collects rewards for.
    /// @custom:param groupId The reward group the receiver funds (0 = the default group).
    mapping(address stickyToken => mapping(uint256 groupId => address)) public override receiverOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initializes the factory's rewards distributor.
    /// @param distributor The distributor receivers settle rewards into.
    constructor(IStickyDistributor distributor) {
        // Give every receiver the same immutable settlement destination, which also enters its CREATE2 address.
        DISTRIBUTOR = distributor;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Settles a receiver's balance of a token into the rewards distributor, deploying the receiver if needed.
    /// @param stickyToken The sticky token whose holders should be rewarded.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settleFor(address stickyToken, uint256 groupId, IERC20 token) external override returns (uint256 amount) {
        // Materialize the destination if needed so even arrivals sent before deployment can fund rewards.
        amount = StickyRewardReceiver(deployReceiverFor({stickyToken: stickyToken, groupId: groupId})).settle(token);

        // This reports the completed call's gross amount; reward accounting belongs to the guarded distributor.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Settle({stickyToken: stickyToken, groupId: groupId, token: token, amount: amount, caller: msg.sender});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The deterministic receiver address for a sticky token and reward group, whether or not it has been
    /// deployed.
    /// @dev Matches across chains only when the factory address, distributor address, receiver creation code, sticky
    /// token address and group all match.
    /// @param stickyToken The sticky token to predict the receiver of.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @return receiver The predicted receiver address.
    function predictReceiverOf(address stickyToken, uint256 groupId) external view override returns (address receiver) {
        // Never predict an address whose receiver could not be deployed, so nothing is bridged to a dead end.
        _requireValidGroupId(groupId);

        // Reproduce this factory's deployment address so funders can route tokens before the receiver exists.
        return Create2.computeAddress({
            salt: _saltOf({stickyToken: stickyToken, groupId: groupId}),
            // Include the constructor arguments because they permanently select the distributor, holders and group.
            bytecodeHash: keccak256(
                bytes.concat(type(StickyRewardReceiver).creationCode, abi.encode(DISTRIBUTOR, stickyToken, groupId))
            )
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploys the receiver for a sticky token and reward group at its deterministic address.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @param groupId The reward group the receiver funds (0 = the default group).
    /// @return receiver The deployed receiver.
    function deployReceiverFor(address stickyToken, uint256 groupId) public override returns (address receiver) {
        // Look up the existing destination before attempting a deployment at its unique CREATE2 address.
        receiver = receiverOf[stickyToken][groupId];

        // Reuse a deployed receiver so repeated settlement never attempts to deploy over existing code.
        if (receiver != address(0)) return receiver;

        // A receiver for a group the distributor rejects could never settle.
        _requireValidGroupId(groupId);

        // Match the predicted salt and constructor arguments so tokens already sent to that address become usable.
        receiver = address(
            new StickyRewardReceiver{salt: _saltOf({stickyToken: stickyToken, groupId: groupId})}({
                distributor: DISTRIBUTOR, stickyToken: stickyToken, groupId: groupId
            })
        );

        // Record the deployed receiver so subsequent settlement calls reuse the same destination.
        receiverOf[stickyToken][groupId] = receiver;

        // Publish the destination for funders and indexers. The receiver constructor only validates and sets
        // immutables, so it cannot call back into this factory before the deployment is recorded.
        // forge-lint: disable-next-line(reentrancy-events)
        emit DeployReceiver({stickyToken: stickyToken, groupId: groupId, receiver: receiver, caller: msg.sender});
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice The CREATE2 salt for a sticky token and reward group's receiver.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @param groupId The reward group the receiver funds.
    /// @return salt The salt, distinct for every (token, group) pair.
    function _saltOf(address stickyToken, uint256 groupId) internal pure returns (bytes32 salt) {
        // Fixed-width encoding keeps every pair distinct without depending on deployment order or the caller.
        salt = keccak256(abi.encode(stickyToken, groupId));
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Reverts unless the distributor can fund the reward group.
    /// @param groupId The reward group to validate.
    function _requireValidGroupId(uint256 groupId) internal view {
        // Defer to the distributor so the factory never encodes a group rule of its own.
        if (!DISTRIBUTOR.isValidGroupId(groupId)) revert StickyRewardReceiverFactory_InvalidGroupId(groupId);
    }
}
