// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {IJBStickyHook} from "./IJBStickyHook.sol";

/// @notice Deploys permanently configured projects that issue backing-priced shares for stakes and allow cash-outs
/// under their chosen tax and transfer policy.
interface IJBStickyDeployer {
    /// @notice Emitted when a sticky project is deployed.
    /// @param projectId The ID of the sticky project.
    /// @param stakedToken The token the project accepts for staking.
    /// @param token The share token issued to represent staked positions.
    /// @param cashOutTaxRate The portion of an unwind left behind for remaining stakers — the project's commitment
    /// reward — out of `JBConstants.MAX_CASH_OUT_TAX_RATE`.
    /// @param soulbound Whether the staked copy's transfers revert.
    /// @param caller The address that deployed the sticky project.
    event DeploySticky(
        uint256 indexed projectId,
        IERC20Metadata indexed stakedToken,
        IJBToken token,
        uint256 cashOutTaxRate,
        bool soulbound,
        address caller
    );

    /// @notice The controller used to launch and manage sticky projects.
    /// @return controller The immutable project controller.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The data hook that tracks staking positions for sticky projects.
    /// @return hook The immutable pricing and accounting hook.
    function HOOK() external view returns (IJBStickyHook);

    /// @notice The terminal sticky projects accept their staked token through.
    /// @return terminal The immutable staking terminal.
    function TERMINAL() external view returns (IJBTerminal);

    /// @notice The contract managing token minting and burning for projects.
    /// @return tokens The controller's token registry.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The portion of an unwind a sticky project leaves behind for remaining stakers — its commitment
    /// reward — out of `JBConstants.MAX_CASH_OUT_TAX_RATE`.
    /// @param projectId The ID of the sticky project to get the cash out tax rate of.
    /// @return rate The project's permanent tax rate, out of the protocol maximum.
    function cashOutTaxRateOf(uint256 projectId) external view returns (uint256);

    /// @notice The immutable accounting feed supplying the denominator of the share issuance ratio.
    /// @param projectId The ID of the sticky project.
    /// @return feed The project's feed, or the zero address for an unknown project.
    function priceFeedOf(uint256 projectId) external view returns (IJBPriceFeed);

    /// @notice The token a sticky project accepts for staking.
    /// @param projectId The ID of the sticky project to get the staked token of.
    /// @return token The underlying token, or the zero address for an unknown project.
    function stakedTokenOf(uint256 projectId) external view returns (IERC20Metadata);

    /// @notice Deploys a sticky project for a token.
    /// @dev The `msg.value` must equal the project creation fee required by `JBProjects`.
    /// @param stakedToken The token the project accepts for staking.
    /// @param name The name of the share token issued to represent staked positions.
    /// @param symbol The symbol of the share token issued to represent staked positions.
    /// @param projectUri The sticky project's metadata URI.
    /// @param cashOutTaxRate The portion of an unwind left behind for remaining stakers — the project's commitment
    /// reward — out of `JBConstants.MAX_CASH_OUT_TAX_RATE`. Zero uses proportional share-owned backing; positive
    /// values apply the protocol's cash-out curve. The maximum returns no backing. Terminal fee rules still apply.
    /// @param granters Addresses allowed to airdrop stakes to any holder (e.g. the community's grant program).
    /// Permanent — holders can additionally trust senders for their own position at any time.
    /// @param soulbound Whether transfers between holders revert; otherwise moved shares receive fresh timestamps.
    /// @return projectId The ID of the sticky project.
    function deployStickyFor(
        IERC20Metadata stakedToken,
        string calldata name,
        string calldata symbol,
        string calldata projectUri,
        uint256 cashOutTaxRate,
        address[] calldata granters,
        bool soulbound
    )
        external
        payable
        returns (uint256 projectId);
}
