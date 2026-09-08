// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable underlying token used to exercise real terminal accounting across token precisions.
contract JBStickyPricingToken is ERC20 {
    /// @notice The underlying token's immutable accounting precision.
    uint8 internal immutable _DECIMALS;

    /// @notice Initialize a token with the requested precision.
    /// @param tokenDecimals The accounting precision reported to the terminal at launch.
    constructor(uint8 tokenDecimals) ERC20("Pricing underlying", "PRICE") {
        _DECIMALS = tokenDecimals;
    }

    /// @notice Create underlying tokens for a regression participant.
    /// @param account The account receiving the underlying tokens.
    /// @param amount The number of underlying token atoms to mint.
    function mint(address account, uint256 amount) external {
        _mint({account: account, value: amount});
    }

    /// @notice Report the token's configured accounting precision.
    /// @return tokenDecimals The number of decimals.
    function decimals() public view override returns (uint8 tokenDecimals) {
        return _DECIMALS;
    }
}
