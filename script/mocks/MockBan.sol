// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A permissionless mintable token for the explicitly opted-in local deployment demo.
contract MockBan is ERC20 {
    /// @notice Initializes the demo token.
    constructor() ERC20("Banana", "BAN") {}

    /// @notice Mints disposable demo tokens.
    /// @param to The recipient.
    /// @param amount The number of token atoms to mint.
    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }
}
