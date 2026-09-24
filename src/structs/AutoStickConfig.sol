// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A holder's auto-stick preferences for one sticky project. Packs into a single storage slot.
/// @custom:member minimumAmount The smallest underlying-token reward worth compounding, in the underlying token's
/// decimals. Always non-zero while configured.
/// @custom:member cooldown The minimum number of seconds between compounds.
/// @custom:member lastCompoundedAt The timestamp of the holder's last successful automated compound. Disabling keeps
/// it so toggling the configuration cannot bypass the cooldown. Manual reward stakes do not update it.
/// @custom:member enabled Whether auto-stick is currently on for the holder.
// Keep the shared Juicebox acronym intact in public types throughout V6.
// forge-lint: disable-next-line(pascal-case-struct)
struct AutoStickConfig {
    uint128 minimumAmount;
    uint48 cooldown;
    uint48 lastCompoundedAt;
    bool enabled;
}
