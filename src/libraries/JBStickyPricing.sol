// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Prices new Sticky shares against existing backing without diluting outstanding shares.
library JBStickyPricing {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice The terminal's supported accounting precision cannot exceed 36 decimals.
    error JBStickyPricing_UnsupportedDecimals(uint256 decimals);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The smallest non-zero share supply, in share atoms: one millionth of a whole underlying token.
    /// @dev A bootstrap must issue at least this many atoms and burns cannot leave fewer without leaving zero. A
    /// sole holder could otherwise pin the supply at one atom, donate backing, and make every later deposit below
    /// ten thousand share atoms revert unless it was an exact multiple of the inflated atom price.
    uint256 internal constant MIN_SUPPLY = 1e12;

    /// @notice One basis point of ideal share issuance is the largest permitted rounding loss.
    uint256 internal constant _ROUNDING_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Calculate the numerator of the exact share issuance ratio for a payment.
    /// @dev Empty projects begin with decimal-normalized one-for-one issuance. Their previous backing must be
    /// excluded separately. Returning zero lets terminal previews report an unissuable amount; the pay callback
    /// must reject positive payments that issue nothing. The loss bound concerns shares, not cash-out rounding.
    /// @param amount The accepted payment amount, in the underlying token's decimals.
    /// @param supply The outstanding Sticky share supply, with 18 decimals.
    /// @param backing The underlying backing belonging to those shares, in the underlying token's decimals.
    /// @param decimals The underlying token's accounting decimals.
    /// @return weight The share supply to pass to the terminal, or zero if issuance is unsafe. The project's
    /// immutable price feed supplies the backing denominator in the same accounting precision as the payment.
    function weightFrom(
        uint256 amount,
        uint256 supply,
        uint256 backing,
        uint8 decimals
    )
        internal
        pure
        returns (uint256 weight)
    {
        if (decimals > 36) revert JBStickyPricing_UnsupportedDecimals(decimals);
        uint256 scale = 10 ** decimals;
        bool bootstrap = supply == 0;
        if (bootstrap) {
            // Apply the same precision protection to initial decimal-normalized issuance. These values only
            // define the initial exchange rate; no virtual shares or backing enter the project's accounting.
            supply = 1e18;
            backing = scale;
        } else if (backing == 0) {
            return 0;
        }
        weight = supply;
        uint256 issuedCount = Math.mulDiv({x: amount, y: supply, denominator: backing});

        // A bootstrap below the supply floor would let its sole holder set an arbitrarily coarse atom price.
        if (bootstrap && issuedCount < MIN_SUPPLY) return 0;

        uint256 idealCount = Math.mulDiv({x: amount, y: supply, denominator: backing, rounding: Math.Rounding.Ceil});

        // Using the ceiling also rejects payments whose ideal issuance is only slightly above one share atom.
        // A positive one-atom mint alone does not establish acceptable issuance precision.
        if (issuedCount < idealCount - idealCount / _ROUNDING_DENOMINATOR) return 0;
    }
}
