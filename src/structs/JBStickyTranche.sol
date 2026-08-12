// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A single staking deposit. Each deposit is tracked separately so the amount and duration of every stake can
/// be queried per holder.
/// @custom:member amount The number of staked project tokens this tranche represents, as a fixed point number with 18
/// decimals.
/// @custom:member timestamp The timestamp at which this tranche was created. Partial unstakes keep the remainder's
/// original timestamp.
struct JBStickyTranche {
    uint208 amount;
    uint48 timestamp;
}
