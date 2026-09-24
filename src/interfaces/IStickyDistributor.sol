// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTokenDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBTokenDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStickyHook} from "./IStickyHook.sol";

/// @notice A round-based reward distributor for Sticky projects. The default group (0) weighs holders by their
/// delegated voting power at the round's snapshot block, exactly like a token distributor. Every other group is a
/// tenure window encoded as `minWeeks * CRITERIA_BASE + maxWeeks`: it weighs holders by the stake they held in
/// tranches created between `maxWeeks` and `minWeeks` before the round started, with `maxWeeks == 0` meaning no
/// upper bound.
/// @dev Splits select a group through `split.projectId`, which core never reads while the split's hook is set.
interface IStickyDistributor is IJBTokenDistributor {
    /// @notice Emitted when rewards are accepted into a hook's group for the current round.
    /// @param hook The sticky token whose holders receive the rewards.
    /// @param groupId The reward group funded (0 = the default group).
    /// @param token The reward token.
    /// @param round The round the rewards belong to.
    /// @param amount The amount accepted, after any transfer fees.
    /// @param caller The address that funded the rewards.
    event Fund(
        address indexed hook,
        uint256 indexed groupId,
        IERC20 indexed token,
        uint256 round,
        uint256 amount,
        address caller
    );

    /// @notice The multiplier used to encode a tenure group ID as `minWeeks * CRITERIA_BASE + maxWeeks`.
    /// @return criteriaBase The group ID encoding base.
    function CRITERIA_BASE() external view returns (uint256 criteriaBase);

    /// @notice The duration of one stake-age epoch, which must match the Sticky hook's.
    /// @return duration The epoch duration, in seconds.
    function EPOCH_DURATION() external view returns (uint256 duration);

    /// @notice The highest value either `minWeeks` or `maxWeeks` of a tenure group ID can take.
    /// @return maxCriteriaWeeks The highest supported number of weeks.
    function MAX_CRITERIA_WEEKS() external view returns (uint256 maxCriteriaWeeks);

    /// @notice The hook that records the tranches and epoch buckets tenure rewards are weighed by.
    /// @return stickyHook The Sticky hook.
    function STICKY_HOOK() external view returns (IStickyHook stickyHook);

    /// @notice The amount of a reward token that has been claimed for a token ID in a group but not yet collected.
    /// @param hook The sticky token the token ID belongs to.
    /// @param groupId The reward group to check (0 = the default group).
    /// @param tokenId The encoded holder address.
    /// @param token The reward token to check.
    /// @return tokenAmount The uncollected amount, vesting and unlocked.
    function claimedFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        returns (uint256 tokenAmount);

    /// @notice The amount of a reward token currently unlocked and collectable for a token ID in a group.
    /// @param hook The sticky token the token ID belongs to.
    /// @param groupId The reward group to check (0 = the default group).
    /// @param tokenId The encoded holder address.
    /// @param token The reward token to check.
    /// @return tokenAmount The collectable amount.
    function collectableFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        returns (uint256 tokenAmount);

    /// @notice Whether a group ID is the default group or a valid tenure window.
    /// @dev A tenure window needs `minWeeks` in `[1, MAX_CRITERIA_WEEKS]` and `maxWeeks` either 0 or in
    /// `[minWeeks, MAX_CRITERIA_WEEKS]`.
    /// @param groupId The group ID to check.
    /// @return isValid Whether the group can be funded and claimed from.
    function isValidGroupId(uint256 groupId) external pure returns (bool isValid);

    /// @notice The next reward round a holder has not yet claimed in a group.
    /// @param hook The sticky token the token ID belongs to.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenId The encoded holder address.
    /// @param token The reward token being claimed.
    /// @return round The next unclaimed round.
    function nextClaimRoundOf(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        returns (uint256 round);

    /// @notice The epoch a round's tenure windows are measured from: the epoch the round started in.
    /// @param round The round to get the snapshot epoch of.
    /// @return epoch The round's snapshot epoch.
    function snapshotEpochOf(uint256 round) external view returns (uint256 epoch);

    /// @notice Claims a group's completed reward rounds for the given token IDs and starts vesting them.
    /// @dev Permissionless. No reward tokens leave the distributor.
    /// @param hook The sticky token whose holders are vesting.
    /// @param groupId The reward group to vest from (0 = the default group).
    /// @param tokenIds The encoded holder addresses to claim for.
    /// @param tokens The reward tokens to claim.
    function beginVesting(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external;

    /// @notice Claims a group's completed reward rounds, then collects everything that has unlocked.
    /// @dev Holders can collect to any beneficiary. Helpers can collect only to the encoded holder.
    /// @param hook The sticky token whose holders are collecting.
    /// @param groupId The reward group to collect from (0 = the default group).
    /// @param tokenIds The encoded holder addresses to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;

    /// @notice Funds a group of a sticky token's holders for the current round.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token. A tenure group can only
    /// be funded for a token registered with the Sticky hook.
    /// @param hook The sticky token whose holders receive the rewards.
    /// @param token The reward token.
    /// @param amount The amount to fund, ignored for native ETH.
    /// @param groupId The reward group to fund (0 = the default group).
    function fund(address hook, IERC20 token, uint256 amount, uint256 groupId) external payable;

    /// @notice Recycles a group's expired reward rounds into the current round.
    /// @dev Passing the current round is a no-op, including for zero-stake rounds.
    /// @param hook The sticky token whose expired rewards should be recycled.
    /// @param groupId The reward group to recycle (0 = the default group).
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function recycleExpiredRewards(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        returns (uint256 amount);
}
