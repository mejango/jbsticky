// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A reward amount assigned to a specific distributor round.
/// @custom:member amount The reward amount assigned to the round.
/// @custom:member snapshotBlock The block used for group-0 historical stake lookups.
/// @custom:member claimedAmount The reward amount already materialized into vesting.
/// @custom:member claimDeadline The timestamp used by expiration logic. Zero means no expiration.
/// @custom:member totalStake The aggregate stake denominator used to split the round.
/// @custom:member snapshotEpoch The stick-age epoch at the first funding, used by criteria groups (0 for group 0).
struct JBStickyRewardRoundData {
    uint208 amount;
    uint48 snapshotBlock;
    uint208 claimedAmount;
    uint48 claimDeadline;
    uint208 totalStake;
    uint48 snapshotEpoch;
}
