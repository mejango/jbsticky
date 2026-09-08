// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";

/// @notice Supplies a Sticky project's exact share-owned backing as the denominator of its issuance ratio.
/// @dev This is an accounting feed, not an external market price. The hook supplies the share supply as the
/// numerator, so the terminal issues floor(payment * supply / backing) without first rounding an exchange rate.
contract JBStickyPriceFeed is IJBPriceFeed {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Existing shares must have positive backing after excluding funds that had no owners.
    error JBStickyPriceFeed_InvalidBacking(uint256 backing, uint256 orphanedBalance);

    /// @notice Price precision cannot exceed the core's supported accounting precision.
    error JBStickyPriceFeed_UnsupportedDecimals(uint256 decimals);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The underlying token's currency in the terminal's immutable accounting context.
    uint32 public immutable CURRENCY;

    /// @notice The underlying token's cached accounting precision, independent of later token metadata changes.
    uint8 public immutable DECIMALS;

    /// @notice The hook tracking backing excluded from share ownership.
    IJBStickyHook public immutable HOOK;

    /// @notice The project whose backing is priced.
    uint256 public immutable PROJECT_ID;

    /// @notice The project's immutable staking terminal.
    IJBTerminal public immutable TERMINAL;

    /// @notice The project's share token.
    IJBToken public immutable TOKEN;

    /// @notice The only token accepted by the staking terminal for this project.
    address public immutable UNDERLYING_TOKEN;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Bind the feed to a launched project's terminal, share token and cached accounting context.
    /// @param hook The project's pricing and position-accounting hook.
    /// @param terminal The project's staking terminal.
    /// @param token The project's share token.
    /// @param projectId The ID of the launched project.
    /// @param underlyingToken The token accepted for staking.
    constructor(IJBStickyHook hook, IJBTerminal terminal, IJBToken token, uint256 projectId, address underlyingToken) {
        JBAccountingContext memory context =
            terminal.accountingContextForTokenOf({projectId: projectId, token: underlyingToken});
        if (context.decimals > 36) revert JBStickyPriceFeed_UnsupportedDecimals(context.decimals);
        CURRENCY = context.currency;
        DECIMALS = context.decimals;
        HOOK = hook;
        PROJECT_ID = projectId;
        TERMINAL = terminal;
        TOKEN = token;
        UNDERLYING_TOKEN = underlyingToken;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Return exact share-owned backing, or one underlying unit when bootstrapping an empty project.
    /// @dev The terminal asks for `DECIMALS`, making this denominator exact. Other precisions are adjusted using
    /// the core's standard conversion. The hook rejects zero backing before core can try fallback feeds.
    /// @param decimals The precision requested for the returned denominator, up to 36.
    /// @return price The issuance denominator in the requested precision.
    function currentUnitPrice(uint256 decimals) external view override returns (uint256 price) {
        if (decimals > 36) revert JBStickyPriceFeed_UnsupportedDecimals(decimals);
        if (TOKEN.totalSupply() == 0) return 10 ** decimals;

        address[] memory tokens = new address[](1);
        tokens[0] = UNDERLYING_TOKEN;
        uint256 backing =
            TERMINAL.currentSurplusOf({projectId: PROJECT_ID, tokens: tokens, decimals: DECIMALS, currency: CURRENCY});
        uint256 orphanedBalance = HOOK.orphanedBalanceOf(PROJECT_ID);
        if (backing <= orphanedBalance) {
            revert JBStickyPriceFeed_InvalidBacking({backing: backing, orphanedBalance: orphanedBalance});
        }
        return JBFixedPointNumber.adjustDecimals({
            value: backing - orphanedBalance, decimals: DECIMALS, targetDecimals: decimals
        });
    }
}
