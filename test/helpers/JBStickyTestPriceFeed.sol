// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";

/// @notice A fixed denominator used to test that protocol fallback prices cannot change Sticky issuance.
contract JBStickyTestPriceFeed is IJBPriceFeed {
    /// @notice The fixed denominator returned for every requested precision.
    uint256 public immutable PRICE;

    /// @notice Sets the deliberately incorrect fallback denominator.
    /// @param price The denominator to return.
    constructor(uint256 price) {
        PRICE = price;
    }

    /// @notice Returns the fixed denominator regardless of the requested precision.
    /// @return price The fixed denominator.
    function currentUnitPrice(uint256) external view override returns (uint256 price) {
        return PRICE;
    }
}
