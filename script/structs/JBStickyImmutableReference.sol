// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice One compiler-reported immutable location, ordered to match Foundry JSON decoding.
/// @custom:member length The number of bytes occupied by the immutable.
/// @custom:member start The byte offset within deployed code.
struct JBStickyImmutableReference {
    uint256 length;
    uint256 start;
}
