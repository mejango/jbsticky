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
/// Core accepts the numerator through the pay hook and the denominator through `IJBPriceFeed`. Its feed call only
/// passes a requested precision, so this per-project adapter binds the terminal, token and project ID needed to
/// read the correct backing. The shared Sticky hook cannot infer those bindings from the feed call alone.
contract JBStickyPriceFeed is IJBPriceFeed {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when existing shares have no positive backing, so their issuance ratio cannot be priced.
    error JBStickyPriceFeed_InvalidBacking(uint256 backing, uint256 orphanedBalance);

    /// @notice Thrown when the requested precision exceeds the core's supported accounting precision.
    error JBStickyPriceFeed_UnsupportedDecimals(uint256 decimals);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The greatest precision supported by the core's accounting conversions.
    uint256 internal constant _MAX_DECIMALS = 36;

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
    // The Sticky deployer binds the feed to the accepted ERC-20 it validated when launching the project.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IJBStickyHook hook, IJBTerminal terminal, IJBToken token, uint256 projectId, address underlyingToken) {
        // Cache the terminal's registered context so later token metadata changes cannot alter issuance precision.
        JBAccountingContext memory context =
            terminal.accountingContextForTokenOf({projectId: projectId, token: underlyingToken});

        // Reject precision the core cannot convert before fixing the feed's accounting units permanently.
        if (context.decimals > _MAX_DECIMALS) revert JBStickyPriceFeed_UnsupportedDecimals(context.decimals);

        // Query surplus in the same currency the terminal uses to account for the underlying token.
        CURRENCY = context.currency;

        // Keep the denominator in the terminal's cached precision so issuance does not round an exchange rate.
        DECIMALS = context.decimals;

        // Read excluded backing from the same hook that authenticates payments and records positions.
        HOOK = hook;

        // Scope every backing query to the project whose shares this feed prices.
        PROJECT_ID = projectId;

        // Use the staking terminal's recorded balance as the source of backing.
        TERMINAL = terminal;

        // Use this project's share supply to distinguish initial issuance from deposits into an existing supply.
        TOKEN = token;

        // Restrict backing queries to the asset accepted for staking.
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
        // Bound requested precision before exponentiation or the core's decimal conversion.
        if (decimals > _MAX_DECIMALS) revert JBStickyPriceFeed_UnsupportedDecimals(decimals);

        // Empty projects use the decimal-normalized bootstrap ratio and do not price existing unowned backing.
        if (TOKEN.totalSupply() == 0) return 10 ** decimals;

        // The terminal accepts a token list; reserve one entry for the project's single staking asset.
        address[] memory tokens = new address[](1);

        // Exclude other assets held by the terminal from this project's issuance denominator.
        tokens[0] = UNDERLYING_TOKEN;

        // Read recorded backing in its original accounting units to retain the exact issuance denominator.
        uint256 backing =
            TERMINAL.currentSurplusOf({projectId: PROJECT_ID, tokens: tokens, decimals: DECIMALS, currency: CURRENCY});

        // Backing excluded when supply began cannot be sold to subsequent depositors as existing share value.
        uint256 orphanedBalance = HOOK.orphanedBalanceOf(PROJECT_ID);

        // Existing shares need positive owned backing to define a usable issuance denominator.
        if (backing <= orphanedBalance) {
            revert JBStickyPriceFeed_InvalidBacking({backing: backing, orphanedBalance: orphanedBalance});
        }

        // Return only share-owned backing, adjusting units for callers that request a different precision.
        return JBFixedPointNumber.adjustDecimals({
            value: backing - orphanedBalance, decimals: DECIMALS, targetDecimals: decimals
        });
    }
}
