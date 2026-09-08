// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";

/// @notice A fixed denominator used to test that protocol fallback prices cannot change Sticky issuance.
contract JBStickyTestPriceFeed is IJBPriceFeed {
    /// @notice The fixed denominator returned for every requested precision.
    uint256 public immutable PRICE;

    /// @notice Set the deliberately incorrect fallback denominator.
    /// @param price The denominator to return.
    constructor(uint256 price) {
        PRICE = price;
    }

    /// @notice Return the configured denominator.
    /// @param decimals The requested precision, deliberately ignored by this test feed.
    /// @return price The fixed test denominator.
    function currentUnitPrice(uint256 decimals) external view override returns (uint256 price) {
        return PRICE;
    }
}
