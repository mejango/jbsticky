// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Holds cross-chain reward arrivals for one sticky token until anyone settles them into the rewards
/// distributor.
/// @dev Each Sticky token has its own receiver address so plain ERC-20 arrivals identify the rewarded holder pool
/// without bridge-specific metadata or a shared deposit ledger. The factory creates and locates these receivers;
/// each receiver fixes its reward pool and settles its full token balance, without ordering individual arrivals.
/// The receiver's deterministic address can receive tokens before deployment. Its address matches across chains
/// only when the factory address, distributor address, receiver creation code, and sticky token address all match.
/// @dev Settles ERC-20 balances only. Project-token credits minted by a sucker claim, which is what a destination
/// project without an ERC-20 receives, and native ETH cannot be settled and stay in the receiver. Funders must bridge
/// only to chains where the reward project has an ERC-20 and must not send ETH.
contract JBStickyRewardReceiver {
    // A library that safely interacts with ERC-20 tokens.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the distributor is the zero address, since the immutable settlement destination cannot be
    /// corrected after deployment.
    /// @param distributor The distributor provided for the receiver.
    error JBStickyRewardReceiver_InvalidDistributor(IJBDistributor distributor);

    /// @notice Thrown when the Sticky token is the zero address, since arrivals would have no rewarded holder pool.
    /// @param stickyToken The Sticky token provided for the receiver.
    error JBStickyRewardReceiver_InvalidStickyToken(address stickyToken);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The distributor rewards are settled into.
    IJBDistributor public immutable DISTRIBUTOR;

    /// @notice The sticky token whose holders this receiver rewards.
    address public immutable STICKY_TOKEN;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initializes the receiver's distributor and sticky token.
    /// @param distributor The distributor rewards are settled into.
    /// @param stickyToken The sticky token whose holders this receiver rewards.
    constructor(IJBDistributor distributor, address stickyToken) {
        // Require a settlement destination because the immutable distributor cannot be corrected after deployment.
        if (address(distributor) == address(0)) revert JBStickyRewardReceiver_InvalidDistributor(distributor);

        // Require a reward-bearing token so arrivals cannot be assigned to an empty holder identity.
        if (stickyToken == address(0)) revert JBStickyRewardReceiver_InvalidStickyToken(stickyToken);

        // Fix the destination so permissionless callers cannot redirect the receiver's rewards.
        DISTRIBUTOR = distributor;

        // Fix the rewarded holders independently of who sends or settles the arriving tokens.
        STICKY_TOKEN = stickyToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Settles this receiver's full balance of a token into the distributor as rewards for the sticky
    /// token's holders.
    /// @dev Anyone can settle. The settlement time selects the distributor round, whose snapshot determines reward
    /// eligibility; the receiver does not reserve rewards for holders present when tokens arrive.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settle(IERC20 token) external returns (uint256 amount) {
        // Settle all tokens currently available, including arrivals sent before this receiver was deployed.
        amount = token.balanceOf(address(this));

        // Nothing to settle is a no-op; every positive balance can still be settled.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;

        // Let the distributor pull exactly this settlement's balance, including tokens requiring an allowance reset.
        token.forceApprove({spender: address(DISTRIBUTOR), value: amount});

        // Assign the pulled tokens to the fixed Sticky token's current reward round and snapshot eligibility.
        DISTRIBUTOR.fund({hook: STICKY_TOKEN, token: token, amount: amount});
    }
}
