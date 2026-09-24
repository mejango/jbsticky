// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBActiveVotes} from "@bananapus/core-v6/src/interfaces/IJBActiveVotes.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {IJBStickyToken} from "./interfaces/IJBStickyToken.sol";

/// @notice An ERC-20 representing a staked position in a sticky project, minted by staking and burned by cashing out
/// or voluntarily through the controller. Its transfer policy is permanent: soulbound tokens reject transfers;
/// transferable tokens consume the sender's newest tranches and create a fresh tranche for the recipient.
/// @dev Checkpointed votes make the token a valid stake source for `JBStickyDistributor` default-group rewards: every
/// holder is self-delegated automatically on first mint and delegation can never be changed, so each holder's voting
/// power always equals their staked balance and the active-vote total always equals the total supply. Tenure rewards
/// read the hook's tranches instead. A recipient's existing streak continues when tokens arrive; the incoming tokens
/// join the recipient's newest tranche of the current epoch or start a new one.
contract JBStickyToken is ERC20Votes, IJBActiveVotes, IJBStickyToken, IJBToken {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when calling `initialize`. This token is initialized by its constructor.
    error JBStickyToken_AlreadyInitialized();

    /// @notice Thrown when attempting to change delegation. Reward weight always stays with the holder.
    error JBStickyToken_DelegationLocked(address delegatee);

    /// @notice Thrown when calling `setMetadata`. This token's name and symbol are immutable.
    error JBStickyToken_MetadataIsImmutable();

    /// @notice Thrown when attempting a transfer while the token is soulbound, preserving its transfer policy.
    error JBStickyToken_Soulbound(address from, address to);

    /// @notice Thrown when the caller is not the `JBTokens` contract that manages this token, so supply changes follow
    /// the controller's authorization.
    error JBStickyToken_Unauthorized(address caller, address tokens);

    /// @notice Thrown when tokens move before a pending payment's minted tranche has been recorded, which would consume
    /// older tranches out of order.
    error JBStickyToken_UnrecordedMint(address holder, uint256 tokenBalance, uint256 stakedBalance);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The hook that tracks tranches and streaks, notified when tokens burn or transfer between holders.
    IJBStickyHook public immutable override HOOK;

    /// @notice The ID of the sticky project this token belongs to. This token can't be attached to any other project.
    uint256 public immutable override PROJECT_ID;

    /// @notice Whether transfers between accounts revert.
    bool public immutable override SOULBOUND;

    /// @notice The contract that manages minting and burning of this token.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Creates an immutable sticky token and binds it to its project's accounting hook.
    /// @param name The token's name.
    /// @param symbol The token's symbol.
    /// @param tokens The contract that manages minting and burning of this token.
    /// @param projectId The ID of the sticky project this token belongs to.
    /// @param hook The hook that tracks tranches and streaks.
    /// @param soulbound Whether transfers between accounts revert.
    constructor(
        string memory name,
        string memory symbol,
        IJBTokens tokens,
        uint256 projectId,
        IJBStickyHook hook,
        bool soulbound
    )
        ERC20(name, symbol)
        EIP712(name, "1")
    {
        // Restrict supply changes to the token manager used by the project's controller.
        TOKENS = tokens;

        // Bind this token permanently to one project so balances cannot be shared across staking ledgers.
        PROJECT_ID = projectId;

        // Keep transfers and burns connected to the same authority that records payment tranches and streaks.
        HOOK = hook;

        // Fix whether holder-to-holder transfers are allowed so the policy cannot change after staking.
        SOULBOUND = soulbound;
    }

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    /// @notice Only the `JBTokens` contract can call this function.
    // Keep the single access check beside its modifier; a forwarding helper would add no shared behavior.
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyTokens() {
        // Reject direct supply changes that would bypass the controller's authorization and accounting.
        if (msg.sender != address(TOKENS)) {
            revert JBStickyToken_Unauthorized({caller: msg.sender, tokens: address(TOKENS)});
        }

        // Run the mint or burn only after authenticating the project's token manager.
        _;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Burns some outstanding tokens.
    /// @dev Can only be called by the `JBTokens` contract.
    /// @param account The address to burn tokens from.
    /// @param amount The amount of tokens to burn, as a fixed point number with 18 decimals.
    function burn(address account, uint256 amount) external override onlyTokens {
        // Use the ERC-20 burn path so `_update` consumes stake accounting and checkpoints the reduced balance.
        _burn({account: account, value: amount});
    }

    /// @notice This token is initialized by its constructor and can't be initialized again.
    /// @dev The proposed name, symbol and token manager are unused; every call reverts.
    /// @inheritdoc IJBToken
    function initialize(string memory, string memory, address) external pure override {
        // Preserve the constructor's immutable bindings instead of allowing an initializer to replace them.
        revert JBStickyToken_AlreadyInitialized();
    }

    /// @notice Mints more of this token.
    /// @dev Can only be called by the `JBTokens` contract.
    /// @param account The address to mint the new tokens to.
    /// @param amount The amount of tokens to mint, as a fixed point number with 18 decimals.
    function mint(address account, uint256 amount) external override onlyTokens {
        // Use the ERC-20 mint path so `_update` establishes self-delegation and checkpoints the issued shares.
        _mint({account: account, value: amount});
    }

    /// @notice This token's name and symbol are immutable.
    /// @dev The proposed name and symbol are unused; every call reverts.
    /// @inheritdoc IJBToken
    function setMetadata(string memory, string memory) external pure override {
        // Keep the token's public identity fixed for every holder throughout the project's lifetime.
        revert JBStickyToken_MetadataIsImmutable();
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice This token can only be attached to the sticky project it was deployed for.
    /// @param projectId The ID of the project to check.
    /// @return canBeAdded Whether the token can be added to the project.
    function canBeAddedTo(uint256 projectId) external view override returns (bool canBeAdded) {
        // Permit attachment only to the project whose tranches and streaks this token reports to the hook.
        return projectId == PROJECT_ID;
    }

    /// @notice The total delegated voting units at a past block.
    /// @dev Every unit is always self-delegated because delegation is locked, so the active total
    /// is exactly the total supply.
    /// @param blockNumber The past block number to look up.
    /// @return activeVotes The total voting units delegated at `blockNumber`.
    function getPastTotalActiveVotes(uint256 blockNumber) external view override returns (uint256 activeVotes) {
        // Every share is self-delegated, so the supply checkpoint is also the historical reward-weight total.
        return getPastTotalSupply(blockNumber);
    }

    /// @notice The current total delegated voting units.
    /// @return activeVotes The current total voting units delegated.
    function getTotalActiveVotes() external view override returns (uint256 activeVotes) {
        // Locked self-delegation leaves no undelegated supply to subtract from the current reward-weight total.
        return totalSupply();
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The balance of the given address.
    /// @param account The account to get the balance of.
    /// @return balance The number of tokens owned by the account, as a fixed point number with 18 decimals.
    function balanceOf(address account) public view override(ERC20, IJBToken) returns (uint256 balance) {
        // Expose the ERC-20 ledger through IJBToken so core accounting reads the same balance that transfers update.
        return super.balanceOf(account);
    }

    /// @notice The number of decimals used for this token's fixed point accounting.
    /// @return tokenDecimals The number of decimals.
    function decimals() public view override(ERC20, IJBToken) returns (uint8 tokenDecimals) {
        // Retain the ERC-20 default of 18 decimals used by Juicebox's project-token accounting.
        return super.decimals();
    }

    /// @notice The total supply of this token.
    /// @return supply The total supply of this token, as a fixed point number with 18 decimals.
    function totalSupply() public view override(ERC20, IJBToken) returns (uint256 supply) {
        // Expose the ERC-20 supply through IJBToken so issuance and redemption use the outstanding share count.
        return super.totalSupply();
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Delegation is locked — reward weight always stays with the holder.
    /// @dev Every call reverts.
    /// @param delegatee The proposed delegate, reported in the revert.
    function delegate(address delegatee) public pure override {
        // Keep reward weight with the account holding the shares so balance snapshots determine entitlement.
        revert JBStickyToken_DelegationLocked(delegatee);
    }

    /// @notice Delegation is locked — reward weight always stays with the holder.
    /// @dev The nonce, expiry and signature components (`v`, `r`, `s`) are unused; every call reverts.
    /// @param delegatee The proposed delegate, reported in the revert.
    function delegateBySig(address delegatee, uint256, uint256, uint8, bytes32, bytes32) public pure override {
        // Close the signature-based delegation path so it cannot bypass the same fixed reward-weight policy.
        revert JBStickyToken_DelegationLocked(delegatee);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Allows minting and burning. Transfers between accounts revert when soulbound; otherwise the hook
    /// records a fresh tranche for the recipient. Every positive burn consumes
    /// accounting here, including voluntary controller burns that do not trigger a terminal cash out callback.
    /// @dev Every receiver is self-delegated on first receipt so reward weight always tracks balance.
    /// The terminal can call the staked token between minting and its pay hook. Outgoing movements during that gap
    /// must revert; otherwise they would consume older tranches before the newly minted tranche is recorded.
    /// @param from The address tokens are moving from. `address(0)` means the tokens are being minted.
    /// @param to The address tokens are moving to. `address(0)` means the tokens are being burned.
    /// @param value The amount of tokens moving.
    function _update(address from, address to, uint256 value) internal override {
        // Minted shares cannot consume earlier tranches before the terminal records their own payment tranche.
        if (value != 0 && from != address(0) && from != to) {
            // Read the share balance, which already includes shares minted before the pay callback completes.
            uint256 tokenBalance = balanceOf(from);

            // Compare it with recorded tranches to detect a payment whose accounting callback is still pending.
            uint256 stakedBalance = HOOK.stakedBalanceOf({projectId: PROJECT_ID, holder: from});

            // Block outgoing shares until every minted share has a tranche available for correct age consumption.
            if (tokenBalance != stakedBalance) {
                revert JBStickyToken_UnrecordedMint({
                    holder: from, tokenBalance: tokenBalance, stakedBalance: stakedBalance
                });
            }
        }

        // Apply the transfer policy only to movements between holders; minting and burning remain available.
        if (from != address(0) && to != address(0)) {
            // Reject every holder-to-holder transfer when the project's permanent policy is soulbound.
            if (SOULBOUND) revert JBStickyToken_Soulbound({from: from, to: to});

            // Zero-value and self-transfers leave ownership unchanged, so they must not reset tranche ages.
            if (value != 0 && from != to) {
                // Consume the sender's newest tranches and record fresh recipient age before balances move.
                HOOK.recordTransfer({projectId: PROJECT_ID, from: from, to: to, amount: value});
            }
        } else if (from != address(0) && value != 0) {
            // Every positive burn consumes stake accounting, including voluntary burns without a cash out callback.
            // Zero-value burns skip this path.
            HOOK.recordBurn({projectId: PROJECT_ID, holder: from, amount: value});
        } else if (from == address(0) && value != 0) {
            // The pay callback records minted tranches; until it runs, the hook flags the payment as in progress so
            // no tenure denominator counts these shares before they have a tranche.
            HOOK.recordMint(PROJECT_ID);
        }

        // Self-delegate first-time receivers so voting power always tracks staked balance.
        if (value != 0 && to != address(0) && delegates(to) == address(0)) _delegate({account: to, delegatee: to});

        // Update balances, supply and vote checkpoints after stake bookkeeping and recipient delegation are ready.
        super._update({from: from, to: to, value: value});
    }
}
