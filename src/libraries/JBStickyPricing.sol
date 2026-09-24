// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Prices new Sticky shares against existing backing without diluting outstanding shares.
library JBStickyPricing {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the payment's accounting precision exceeds the 36 decimals the terminal supports.
    error JBStickyPricing_UnsupportedDecimals(uint256 decimals);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The smallest initial issuance, in share atoms: one millionth of a whole underlying token.
    /// @dev This keeps initial share precision useful without restricting later exits. Burns may leave fewer
    /// shares; every later deposit must independently satisfy the rounding limit.
    uint256 internal constant _MIN_INITIAL_SUPPLY = 1e12;

    /// @notice One basis point of ideal share issuance is the largest permitted rounding loss.
    uint256 internal constant _ROUNDING_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Calculates the numerator of the exact share issuance ratio for a payment.
    /// @dev Empty projects begin with decimal-normalized one-for-one issuance. Their previous backing must be
    /// excluded separately. Returning zero lets terminal previews report an unissuable amount; the pay callback
    /// must reject positive payments that issue nothing. The loss bound concerns shares, not cash-out rounding.
    /// @param amount The accepted payment amount, in the underlying token's decimals.
    /// @param supply The outstanding Sticky share supply, with 18 decimals.
    /// @param backing The underlying backing belonging to those shares, in the underlying token's decimals.
    /// @param decimals The underlying token's accounting decimals.
    /// @return weight The share supply to pass to the terminal, or zero if issuance is unsafe. The project's
    /// immutable price feed supplies the backing denominator in the same accounting precision as the payment.
    // Isolate the pure pricing invariant so its boundary behavior can be exercised independently of callbacks.
    // forge-lint: disable-next-line(internal-function-used-once)
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
        // Stay within the core's supported accounting precision before calculating the underlying unit scale.
        if (decimals > 36) revert JBStickyPricing_UnsupportedDecimals(decimals);

        // Express one whole underlying token in its accounting units for the initial one-for-one exchange rate.
        uint256 scale = 10 ** decimals;

        // Remember whether shares exist before substituting the initial issuance ratio below.
        bool bootstrap = supply == 0;

        // With no outstanding shares there is no existing holder exchange rate to preserve.
        if (bootstrap) {
            // Use one whole 18-decimal share as the numerator, without adding virtual shares to actual supply.
            supply = 1e18;

            // Pair it with one whole underlying token so initial issuance normalizes the token's decimals.
            backing = scale;
        } else if (backing == 0) {
            // No finite exchange rate exists for unbacked shares; signal that the payment cannot issue shares.
            return 0;
        }

        // Pass the numerator to the terminal; the project's price feed supplies the exact backing denominator.
        weight = supply;

        // Match the terminal's floor rounding to assess the number of shares the payment would actually receive.
        uint256 issuedCount = Math.mulDiv({x: amount, y: supply, denominator: backing});

        // Start an empty project with enough share atoms for useful initial precision.
        if (bootstrap && issuedCount < _MIN_INITIAL_SUPPLY) return 0;

        // Round the ideal issuance up to measure a conservative whole-atom bound on the payer's rounding loss.
        uint256 idealCount = Math.mulDiv({x: amount, y: supply, denominator: backing, rounding: Math.Rounding.Ceil});

        // Reject loss above one basis point of the ceiling, including issuance just above one share atom.
        // Passing this check leaves the named return value set to the validated issuance numerator.
        if (issuedCount < idealCount - idealCount / _ROUNDING_DENOMINATOR) return 0;
    }
}
