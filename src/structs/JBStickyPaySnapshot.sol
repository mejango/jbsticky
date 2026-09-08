// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The pricing state authenticated by the terminal's before-pay and after-pay hook calls.
/// @custom:member supply The share supply immediately before recording the payment.
/// @custom:member backing The terminal backing immediately before recording the payment, in underlying token atoms.
/// @custom:member orphanedBalance Backing excluded from all share holders because it existed without any shares.
struct JBStickyPaySnapshot {
    uint256 supply;
    uint256 backing;
    uint256 orphanedBalance;
}
