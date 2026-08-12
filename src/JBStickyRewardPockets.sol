// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {IJBStickyRewardPockets} from "./interfaces/IJBStickyRewardPockets.sol";
import {JBStickyRewardPocket} from "./JBStickyRewardPocket.sol";

/// @notice Deploys deterministic reward pockets that turn cross-chain arrivals into sticky rewards. A funder on any
/// chain bridges sucker-mapped project tokens with the pocket as beneficiary; when the claim lands on this chain,
/// anyone settles the pocket and the arrival becomes a reward round for the sticky token's holders — the streaks
/// project itself never needs suckers, only the reward token does.
contract JBStickyRewardPockets is IJBStickyRewardPockets {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The distributor pockets settle rewards into.
    IJBDistributor public immutable override DISTRIBUTOR;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The pocket deployed for a sticky token, or the zero address if it hasn't been deployed yet.
    /// @custom:param stickyToken The sticky token the pocket collects rewards for.
    mapping(address stickyToken => address) public override pocketOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param distributor The distributor pockets settle rewards into.
    constructor(IJBDistributor distributor) {
        DISTRIBUTOR = distributor;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys the pocket for a sticky token at its deterministic address.
    /// @param stickyToken The sticky token the pocket collects rewards for.
    /// @return pocket The deployed pocket.
    function deployPocketFor(address stickyToken) public override returns (address pocket) {
        // Reuse the pocket if it's already deployed.
        pocket = pocketOf[stickyToken];
        if (pocket != address(0)) return pocket;

        // Deploy the pocket at its deterministic address.
        pocket = address(
            new JBStickyRewardPocket{salt: bytes32(uint256(uint160(stickyToken)))}({
                distributor: DISTRIBUTOR, stickyToken: stickyToken
            })
        );

        // Store the pocket.
        pocketOf[stickyToken] = pocket;

        emit DeployPocket({stickyToken: stickyToken, pocket: pocket, caller: msg.sender});
    }

    /// @notice Settles a pocket's balance of a token into the rewards distributor, deploying the pocket if needed.
    /// @param stickyToken The sticky token whose holders should be rewarded.
    /// @param token The reward token to settle.
    /// @return amount The amount settled.
    function settleFor(address stickyToken, IERC20 token) external override returns (uint256 amount) {
        amount = JBStickyRewardPocket(deployPocketFor(stickyToken)).settle(token);

        emit Settle({stickyToken: stickyToken, token: token, amount: amount, caller: msg.sender});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The deterministic pocket address for a sticky token, whether or not it has been deployed.
    /// @dev Identical on every chain this factory is deployed to (the factory and distributor are deployed with
    /// chain-identical addresses), so it can be predicted from anywhere.
    /// @param stickyToken The sticky token to predict the pocket of.
    function predictPocketOf(address stickyToken) external view override returns (address) {
        return Create2.computeAddress({
            salt: bytes32(uint256(uint160(stickyToken))),
            bytecodeHash: keccak256(
                abi.encodePacked(type(JBStickyRewardPocket).creationCode, abi.encode(DISTRIBUTOR, stickyToken))
            )
        });
    }
}
