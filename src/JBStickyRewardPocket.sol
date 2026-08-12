// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

/// @notice Holds cross-chain reward arrivals for one sticky token until anyone settles them into the rewards
/// distributor. The pocket's address is deterministic and chain-identical, so it works as a sucker-bridge beneficiary
/// before it's even deployed — tokens can land first and the pocket can be deployed and settled afterwards.
contract JBStickyRewardPocket {
    using SafeERC20 for IERC20;

    /// @notice The distributor rewards are settled into.
    IJBDistributor public immutable DISTRIBUTOR;

    /// @notice The sticky token whose holders this pocket rewards.
    address public immutable STICKY_TOKEN;

    /// @param distributor The distributor rewards are settled into.
    /// @param stickyToken The sticky token whose holders this pocket rewards.
    constructor(IJBDistributor distributor, address stickyToken) {
        DISTRIBUTOR = distributor;
        STICKY_TOKEN = stickyToken;
    }

    /// @notice Settles this pocket's full balance of a token into the distributor as rewards for the streaking
    /// token's holders. Permissionless — settling early or on someone's behalf only delivers rewards sooner.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settle(IERC20 token) external returns (uint256 amount) {
        amount = token.balanceOf(address(this));

        // Nothing to settle is a no-op, so double-settles are harmless.
        if (amount == 0) return 0;

        // Fund the distributor's current reward round for the sticky token's holders.
        token.forceApprove({spender: address(DISTRIBUTOR), value: amount});
        DISTRIBUTOR.fund({hook: STICKY_TOKEN, token: token, amount: amount});
    }
}
