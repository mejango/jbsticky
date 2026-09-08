// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Holds cross-chain reward arrivals for one sticky token until anyone settles them into the rewards
/// distributor.
/// @dev The pocket's deterministic address can receive tokens before deployment. Its address matches across chains
/// only when the factory address, distributor address, pocket creation code, and sticky token address all match.
contract JBStickyRewardPocket {
    // A library that safely interacts with ERC-20 tokens.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The distributor rewards are settled into.
    IJBDistributor public immutable DISTRIBUTOR;

    /// @notice The sticky token whose holders this pocket rewards.
    address public immutable STICKY_TOKEN;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initializes the pocket's distributor and sticky token.
    /// @param distributor The distributor rewards are settled into.
    /// @param stickyToken The sticky token whose holders this pocket rewards.
    constructor(IJBDistributor distributor, address stickyToken) {
        DISTRIBUTOR = distributor;
        STICKY_TOKEN = stickyToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Settles this pocket's full balance of a token into the distributor as rewards for the sticky
    /// token's holders. Permissionless — settling early or on someone's behalf only delivers rewards sooner.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settle(IERC20 token) external returns (uint256 amount) {
        amount = token.balanceOf(address(this));

        // Nothing to settle is a no-op; every positive balance can still be settled.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;

        // Fund the distributor's current reward round for the sticky token's holders.
        token.forceApprove({spender: address(DISTRIBUTOR), value: amount});
        DISTRIBUTOR.fund({hook: STICKY_TOKEN, token: token, amount: amount});
    }
}
