// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {JBStickyRewardReceiver} from "./JBStickyRewardReceiver.sol";

import {IJBStickyRewardReceiverFactory} from "./interfaces/IJBStickyRewardReceiverFactory.sol";

/// @notice Creates and locates a separate reward receiver for each Sticky token, and forwards settlement requests.
/// @dev Funds arrive at the per-token receiver, whose address identifies the rewarded holder pool. This factory
/// predicts that address before deployment and deploys its immutable settlement logic when needed. A funder can
/// bridge sucker-mapped reward tokens to the receiver without adding suckers to the Sticky project itself.
/// @dev Receivers settle ERC-20 balances only. Project-token credits minted by a sucker claim, which is what a
/// destination project without an ERC-20 receives, and native ETH cannot be settled and stay in the receiver.
/// Funders must bridge only to chains where the reward project has an ERC-20 and must not send ETH.
contract JBStickyRewardReceiverFactory is IJBStickyRewardReceiverFactory {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The distributor receivers settle rewards into.
    IJBDistributor public immutable override DISTRIBUTOR;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The receiver deployed for a sticky token, or the zero address if it hasn't been deployed yet.
    /// @custom:param stickyToken The sticky token the receiver collects rewards for.
    mapping(address stickyToken => address) public override receiverOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initializes the factory's rewards distributor.
    /// @param distributor The distributor receivers settle rewards into.
    constructor(IJBDistributor distributor) {
        // Give every receiver the same immutable settlement destination, which also enters its CREATE2 address.
        DISTRIBUTOR = distributor;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Settles a receiver's balance of a token into the rewards distributor, deploying the receiver if needed.
    /// @param stickyToken The sticky token whose holders should be rewarded.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settleFor(address stickyToken, IERC20 token) external override returns (uint256 amount) {
        // Materialize the destination if needed so even arrivals sent before deployment can fund rewards.
        amount = JBStickyRewardReceiver(deployReceiverFor(stickyToken)).settle(token);

        // This reports the completed call's gross amount; reward accounting belongs to the guarded distributor.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Settle({stickyToken: stickyToken, token: token, amount: amount, caller: msg.sender});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The deterministic receiver address for a sticky token, whether or not it has been deployed.
    /// @dev Matches across chains only when the factory address, distributor address, receiver creation code, and
    /// sticky token address all match.
    /// @param stickyToken The sticky token to predict the receiver of.
    /// @return receiver The predicted receiver address.
    function predictReceiverOf(address stickyToken) external view override returns (address receiver) {
        // Reproduce this factory's deployment address so funders can route tokens before the receiver exists.
        return Create2.computeAddress({
            // Give each Sticky token a distinct salt without depending on deployment order or the caller.
            salt: bytes32(uint256(uint160(stickyToken))),
            // Include the constructor arguments because they permanently select the distributor and rewarded holders.
            bytecodeHash: keccak256(
                // Fixed creation code followed by two fixed-width addresses has an unambiguous boundary.
                // forge-lint: disable-next-line(encode-packed-collision)
                abi.encodePacked(type(JBStickyRewardReceiver).creationCode, abi.encode(DISTRIBUTOR, stickyToken))
            )
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploys the receiver for a sticky token at its deterministic address.
    /// @param stickyToken The sticky token the receiver collects rewards for.
    /// @return receiver The deployed receiver.
    function deployReceiverFor(address stickyToken) public override returns (address receiver) {
        // Look up the existing destination before attempting a deployment at its unique CREATE2 address.
        receiver = receiverOf[stickyToken];

        // Reuse a deployed receiver so repeated settlement never attempts to deploy over existing code.
        if (receiver != address(0)) return receiver;

        // Match the predicted salt and constructor arguments so tokens already sent to that address become usable.
        receiver = address(
            new JBStickyRewardReceiver{salt: bytes32(uint256(uint160(stickyToken)))}({
                distributor: DISTRIBUTOR, stickyToken: stickyToken
            })
        );

        // Record the deployed receiver so subsequent settlement calls reuse the same destination.
        receiverOf[stickyToken] = receiver;

        // Publish the destination for funders and indexers. The receiver constructor only validates and sets
        // immutables, so it cannot call back into this factory before the deployment is recorded.
        // forge-lint: disable-next-line(reentrancy-events)
        emit DeployReceiver({stickyToken: stickyToken, receiver: receiver, caller: msg.sender});
    }
}
