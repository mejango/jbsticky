// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJBStickyHook} from "./IJBStickyHook.sol";

/// @notice A round-based reward distributor for sticky projects. Stakers claim their share of funded reward rounds,
/// and claimed amounts vest linearly over a configurable number of rounds.
/// @dev Also implements `IJBSplitHook` so it can receive rewards from Juicebox payout splits. Projects configure their
/// split with `hook = distributor` and `beneficiary = their sticky token`.
interface IJBStickyDistributor is IJBSplitHook {
    //*********************************************************************//
    // -------------------------------- events --------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a staker begins vesting tokens.
    /// @param hook The sticky token whose stakers are vesting.
    /// @param tokenId The ID of the staked token that is claiming.
    /// @param groupId The reward group claimed from (0 = the default group).
    /// @param token The address of the token to vest.
    /// @param amount The amount of tokens to vest.
    /// @param vestingReleaseRound The round at which the tokens will be fully released.
    /// @param caller The address that triggered the claim.
    event Claimed(
        address indexed hook,
        uint256 indexed tokenId,
        uint256 groupId,
        IERC20 token,
        uint256 amount,
        uint256 vestingReleaseRound,
        address caller
    );

    /// @notice Emitted when vested tokens are collected.
    /// @param hook The sticky token whose stakers are collecting.
    /// @param tokenId The ID of the staked token collecting.
    /// @param groupId The reward group collected from (0 = the default group).
    /// @param token The address of the token collected.
    /// @param amount The amount of tokens collected.
    /// @param vestingReleaseRound The round at which the tokens will be fully released.
    /// @param caller The address that triggered the collection.
    event Collected(
        address indexed hook,
        uint256 indexed tokenId,
        uint256 groupId,
        IERC20 token,
        uint256 amount,
        uint256 vestingReleaseRound,
        address caller
    );

    /// @notice Emitted when an expired reward round's unclaimed amount is recycled into a later reward round.
    /// @param hook The sticky token whose expired rewards were recycled.
    /// @param fromRound The expired reward round.
    /// @param toRound The reward round receiving the recycled rewards.
    /// @param token The reward token that was recycled.
    /// @param amount The unclaimed reward amount recycled.
    /// @param caller The address that triggered the recycle.
    event ExpiredRewardsRecycled(
        address indexed hook,
        uint256 indexed fromRound,
        uint256 indexed toRound,
        IERC20 token,
        uint256 amount,
        address caller
    );

    /// @notice Emitted when a snapshot block is first recorded for a round.
    /// @param round The round the snapshot block was recorded for.
    /// @param snapshotBlock The block number recorded as the snapshot point.
    /// @param caller The address that triggered the snapshot recording.
    event RoundSnapshotRecorded(uint256 indexed round, uint256 snapshotBlock, address caller);

    //*********************************************************************//
    // ----------------------------- views ------------------------------- //
    //*********************************************************************//

    /// @notice The number of seconds after a reward round becomes claimable before unclaimed rewards expire.
    /// @dev A zero duration means reward rounds do not expire.
    /// @return claimDuration The claim duration, in seconds.
    function CLAIM_DURATION() external view returns (uint48 claimDuration);

    /// @notice The divisor used to encode a criteria group ID as `minWeeks * CRITERIA_BASE + maxWeeks`.
    /// @return criteriaBase The criteria encoding base.
    function CRITERIA_BASE() external view returns (uint256 criteriaBase);

    /// @notice The JB directory used to verify terminal/controller callers.
    /// @return directory The JB directory.
    function DIRECTORY() external view returns (IJBDirectory directory);

    /// @notice The duration of one stick-age epoch, cached from `STICKY_HOOK.EPOCH_DURATION()` at deployment.
    /// @return epochDuration The stick-age epoch duration, in seconds.
    function EPOCH_DURATION() external view returns (uint256 epochDuration);

    /// @notice The highest value either the `minWeeks` or `maxWeeks` parameter of a criteria group ID can take.
    /// @return maxCriteriaWeeks The highest supported criteria parameter value.
    function MAX_CRITERIA_WEEKS() external view returns (uint256 maxCriteriaWeeks);

    /// @notice The duration of each round, specified in seconds.
    /// @return roundDuration The round duration, in seconds.
    function ROUND_DURATION() external view returns (uint256 roundDuration);

    /// @notice The starting timestamp of the distributor.
    /// @return startingTimestamp The starting timestamp.
    function STARTING_TIMESTAMP() external view returns (uint256 startingTimestamp);

    /// @notice The hook that tracks the tranches and stick-age epochs of the sticky projects being rewarded.
    /// @return stickyHook The sticky hook.
    function STICKY_HOOK() external view returns (IJBStickyHook stickyHook);

    /// @notice The number of rounds until tokens are fully vested.
    /// @return vestingRounds The number of rounds until tokens are fully vested.
    function VESTING_ROUNDS() external view returns (uint256 vestingRounds);

    /// @notice The balance of a token held for a specific sticky token's stakers.
    /// @param hook The sticky token whose balance to check.
    /// @param token The token to check the balance of.
    /// @return balance The token balance held for the sticky token's stakers.
    function balanceOf(address hook, IERC20 token) external view returns (uint256 balance);

    /// @notice Calculate how much of the token has been claimed for the given tokenId in the default group.
    /// @param hook The sticky token the tokenId belongs to.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    /// @return tokenAmount The claimed token amount.
    function claimedFor(address hook, uint256 tokenId, IERC20 token) external view returns (uint256 tokenAmount);

    /// @notice Calculate the collectible token amount for a token ID in the default group.
    /// @param hook The sticky token the tokenId belongs to.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    /// @return tokenAmount The currently collectable token amount.
    function collectableFor(address hook, uint256 tokenId, IERC20 token) external view returns (uint256 tokenAmount);

    /// @notice Calculate the collectible token amount for a token ID in a specific reward group.
    /// @param hook The sticky token the tokenId belongs to.
    /// @param groupId The reward group to check (0 = the default group).
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    /// @return tokenAmount The currently collectable token amount.
    function collectableFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        returns (uint256 tokenAmount);

    /// @notice The number of the current round.
    /// @return round The current round number.
    function currentRound() external view returns (uint256 round);

    /// @notice The block number recorded as the snapshot point for a round.
    /// @dev Returns 0 if no snapshot block has been recorded yet for this round.
    /// @param round The round to get the snapshot block of.
    /// @return snapshotBlock The snapshot block recorded for the round.
    function roundSnapshotBlock(uint256 round) external view returns (uint256 snapshotBlock);

    /// @notice The timestamp at which a round started.
    /// @param round The round to get the start timestamp of.
    /// @return timestamp The round's start timestamp.
    function roundStartTimestamp(uint256 round) external view returns (uint256 timestamp);

    /// @notice The amount of a token that is currently vesting for a sticky token's stakers.
    /// @param hook The sticky token whose vesting amount to check.
    /// @param token The address of the token that is vesting.
    /// @return tokenAmount The amount of the token currently vesting.
    function totalVestingAmountOf(address hook, IERC20 token) external view returns (uint256 tokenAmount);

    //*********************************************************************//
    // ---------------------------- transactions ------------------------- //
    //*********************************************************************//

    /// @notice Claims tokens and begins vesting from the default group.
    /// @dev Permissionless. No reward tokens leave the distributor.
    /// @param hook The sticky token whose stakers are vesting.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param tokens The tokens to claim.
    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) external;

    /// @notice Claims tokens and begins vesting from a specific reward group.
    /// @dev Permissionless. No reward tokens leave the distributor. Group 0 is the default group; groups encoded as
    /// `minWeeks * CRITERIA_BASE + maxWeeks` are stick-time criteria pots that require the staker's tranche to fall
    /// within that epoch window.
    /// @param hook The sticky token whose stakers are vesting.
    /// @param groupId The reward group to vest from (0 = the default group).
    /// @param tokenIds The IDs to claim rewards for.
    /// @param tokens The tokens to claim.
    function beginVesting(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external;

    /// @notice Collect vested tokens from the default group.
    /// @dev Authorized holders can collect to any beneficiary. Helpers can collect only to the canonical beneficiary
    /// of every token ID they do not control.
    /// @param hook The sticky token whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for.
    /// @param tokens The addresses of the tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;

    /// @notice Collect vested tokens from a specific reward group.
    /// @dev Authorized holders can collect to any beneficiary. Helpers can collect only to the canonical beneficiary
    /// of every token ID they do not control.
    /// @param hook The sticky token whose stakers are collecting.
    /// @param groupId The reward group to collect from (0 = the default group).
    /// @param tokenIds The IDs of the tokens to collect for.
    /// @param tokens The addresses of the tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;

    /// @notice Fund the distributor's default group for a specific sticky token.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token.
    /// @param hook The sticky token to fund.
    /// @param token The token to fund with.
    /// @param amount The amount to fund.
    function fund(address hook, IERC20 token, uint256 amount) external payable;

    /// @notice Fund the distributor for a specific sticky token and reward group.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token. Group 0 is the default
    /// (votes-weighted) group; groups encoded as `minWeeks * CRITERIA_BASE + maxWeeks` are stick-time criteria
    /// pots.
    /// @param hook The sticky token to fund.
    /// @param token The token to fund with.
    /// @param amount The amount to fund.
    /// @param groupId The reward group to fund (0 = the default group).
    function fund(address hook, IERC20 token, uint256 amount, uint256 groupId) external payable;

    /// @notice Record the snapshot block for the current round. Callable by anyone (keepers, frontends).
    function poke() external;

    /// @notice Recycle unclaimed rewards from eligible prior default-group reward rounds into the current reward
    /// round.
    /// @dev Passing the current round is a no-op, including for zero-stake rounds.
    /// @param hook The sticky token whose expired reward rounds should be recycled.
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function recycleExpiredRewards(
        address hook,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        returns (uint256 amount);

    /// @notice Recycle unclaimed rewards from eligible prior reward rounds in a specific group into the current
    /// reward round.
    /// @dev Passing the current round is a no-op, including for zero-stake rounds.
    /// @param hook The sticky token whose expired reward rounds should be recycled.
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
