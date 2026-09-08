// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token that can make one arbitrary call when a terminal clears its allowance to the Sticky hook.
contract JBStickyCallbackToken is ERC20 {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice The configured test callback failed before reaching the Sticky pricing guard.
    error JBStickyCallbackToken_CallFailed(bytes reason);

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The number of callbacks completed without reverting.
    uint256 public callbackCount;

    /// @notice Whether the next matching approval should execute the callback.
    bool public callbackEnabled;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The calldata to execute during the matching approval.
    bytes internal _callbackData;

    /// @notice The contract called during the matching approval.
    address internal _callbackTarget;

    /// @notice The hook whose approval triggers the callback.
    address internal _hook;

    /// @notice The terminal whose approval triggers the callback.
    address internal _terminal;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initialize an 18-decimal underlying token.
    constructor() ERC20("Callback Underlying", "CALL") {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Give the terminal permission to spend tokens owned by this token contract itself.
    /// @param spender The spender to approve.
    /// @param amount The allowance in token atoms.
    function approveFromSelf(address spender, uint256 amount) external {
        _approve({owner: address(this), spender: spender, value: amount});
    }

    /// @notice Arm one callback during the terminal's approval immediately before the pay hook.
    /// @param terminal The terminal whose approval should trigger the callback.
    /// @param hook The spender whose approval should trigger the callback.
    /// @param target The contract to call.
    /// @param data The calldata to send to the target.
    function configureCallback(address terminal, address hook, address target, bytes calldata data) external {
        _terminal = terminal;
        _hook = hook;
        _callbackTarget = target;
        _callbackData = data;
        callbackEnabled = true;
    }

    /// @notice Execute a call from the token contract to establish its own initial stake.
    /// @param target The contract to call.
    /// @param data The calldata to send to the target.
    function execute(address target, bytes calldata data) external {
        _execute({target: target, data: data});
    }

    /// @notice Mint test underlying tokens.
    /// @param beneficiary The account receiving the tokens.
    /// @param amount The amount in token atoms.
    function mint(address beneficiary, uint256 amount) external {
        _mint({account: beneficiary, value: amount});
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Execute the armed callback once before returning from a matching zero approval.
    /// @param spender The account whose allowance is set.
    /// @param value The new allowance in token atoms.
    /// @return approved Whether the allowance was set successfully.
    function approve(address spender, uint256 value) public override returns (bool approved) {
        approved = super.approve({spender: spender, value: value});
        if (callbackEnabled && msg.sender == _terminal && spender == _hook && value == 0) {
            // Disable before calling out so a nested payment can reach its own pay hook successfully.
            callbackEnabled = false;
            _execute({target: _callbackTarget, data: _callbackData});
            callbackCount++;
        }
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Execute the configured call and surface unexpected callback failures.
    /// @param target The contract to call.
    /// @param data The calldata to send to the target.
    function _execute(address target, bytes memory data) internal {
        (bool success, bytes memory reason) = target.call(data);
        if (!success) revert JBStickyCallbackToken_CallFailed(reason);
    }
}
