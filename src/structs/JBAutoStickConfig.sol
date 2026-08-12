// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A holder's auto-stick preferences for one sticky project. Packs into a single storage slot.
/// @custom:member minimumAmount The smallest underlying-token reward worth compounding, in the underlying token's
/// decimals. Always non-zero while configured.
/// @custom:member cooldown The minimum number of seconds between compounds.
/// @custom:member lastCompoundedAt The timestamp of the holder's last successful compound, kept across disables for
/// history.
/// @custom:member enabled Whether auto-stick is currently on for the holder.
struct JBAutoStickConfig {
    uint128 minimumAmount;
    uint48 cooldown;
    uint48 lastCompoundedAt;
    bool enabled;
}
