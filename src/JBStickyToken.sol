// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IJBActiveVotes} from "@bananapus/core-v6/src/interfaces/IJBActiveVotes.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";

/// @notice An ERC-20 representing a staked position in a sticky project, minted by staking and burned by cashing out
/// or voluntarily through the controller.
/// Deployed soulbound (transfers revert — locked means locked) or transferable (transfers restart the streak clock on
/// the moved tokens: the sender's newest tranches are consumed and the receiver gets a fresh tranche, so durations
/// can't be laundered between wallets either way).
/// @dev Checkpointed votes make the token a valid stake source for `JBTokenDistributor` rewards: every holder is
/// self-delegated automatically on first mint and delegation can never be changed, so each holder's voting power
/// always equals their staked balance and the active-vote total always equals the total supply.
contract JBStickyToken is ERC20Votes, IJBActiveVotes, IJBToken {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when calling `initialize`. This token is initialized by its constructor.
    error JBStickyToken_AlreadyInitialized();

    /// @notice Thrown when attempting to change delegation. Reward weight always stays with the holder.
    error JBStickyToken_DelegationLocked();

    /// @notice Thrown when calling `setMetadata`. This token's name and symbol are immutable.
    error JBStickyToken_MetadataIsImmutable();

    /// @notice Thrown when attempting to transfer the token between accounts.
    error JBStickyToken_Soulbound();

    /// @notice Thrown when the caller is not the `JBTokens` contract that manages this token.
    error JBStickyToken_Unauthorized(address caller, address tokens);

    /// @notice Thrown when tokens move before a pending payment's minted tranche has been recorded.
    error JBStickyToken_UnrecordedMint(address holder, uint256 tokenBalance, uint256 stakedBalance);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The hook that tracks tranches and streaks, notified when tokens burn or transfer between holders.
    IJBStickyHook public immutable HOOK;

    /// @notice The ID of the sticky project this token belongs to. This token can't be attached to any other project.
    uint256 public immutable PROJECT_ID;

    /// @notice Whether transfers between accounts revert.
    bool public immutable SOULBOUND;

    /// @notice The contract that manages minting and burning of this token.
    IJBTokens public immutable TOKENS;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Create an immutable sticky token and bind it to its project's accounting hook.
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
        TOKENS = tokens;
        PROJECT_ID = projectId;
        HOOK = hook;
        SOULBOUND = soulbound;
    }

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    /// @notice Only the `JBTokens` contract can call this function.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyTokens() {
        if (msg.sender != address(TOKENS)) {
            revert JBStickyToken_Unauthorized({caller: msg.sender, tokens: address(TOKENS)});
        }
        _;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Burn some outstanding tokens.
    /// @dev Can only be called by the `JBTokens` contract.
    /// @param account The address to burn tokens from.
    /// @param amount The amount of tokens to burn, as a fixed point number with 18 decimals.
    function burn(address account, uint256 amount) external override onlyTokens {
        _burn({account: account, value: amount});
    }

    /// @notice This token is initialized by its constructor and can't be initialized again.
    /// @param name The unused proposed token name.
    /// @param symbol The unused proposed token symbol.
    /// @param tokensAddress The unused proposed token manager.
    function initialize(string memory name, string memory symbol, address tokensAddress) external pure override {
        revert JBStickyToken_AlreadyInitialized();
    }

    /// @notice Mints more of this token.
    /// @dev Can only be called by the `JBTokens` contract.
    /// @param account The address to mint the new tokens to.
    /// @param amount The amount of tokens to mint, as a fixed point number with 18 decimals.
    function mint(address account, uint256 amount) external override onlyTokens {
        _mint({account: account, value: amount});
    }

    /// @notice This token's name and symbol are immutable.
    /// @param name The unused proposed token name.
    /// @param symbol The unused proposed token symbol.
    function setMetadata(string memory name, string memory symbol) external pure override {
        revert JBStickyToken_MetadataIsImmutable();
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice This token can only be attached to the sticky project it was deployed for.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the token can be added to the project.
    function canBeAddedTo(uint256 projectId) external view override returns (bool) {
        return projectId == PROJECT_ID;
    }

    /// @notice The total delegated voting units at a past block.
    /// @dev Every unit is always self-delegated because delegation is locked, so the active total
    /// is exactly the total supply.
    /// @param blockNumber The past block number to look up.
    /// @return activeVotes The total voting units delegated at `blockNumber`.
    function getPastTotalActiveVotes(uint256 blockNumber) external view override returns (uint256 activeVotes) {
        return getPastTotalSupply(blockNumber);
    }

    /// @notice The current total delegated voting units.
    /// @return activeVotes The current total voting units delegated.
    function getTotalActiveVotes() external view override returns (uint256 activeVotes) {
        return totalSupply();
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The balance of the given address.
    /// @param account The account to get the balance of.
    /// @return The number of tokens owned by the `account`, as a fixed point number with 18 decimals.
    function balanceOf(address account) public view override(ERC20, IJBToken) returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice The number of decimals used for this token's fixed point accounting.
    /// @return The number of decimals.
    function decimals() public view override(ERC20, IJBToken) returns (uint8) {
        return super.decimals();
    }

    /// @notice The total supply of this token.
    /// @return The total supply of this token, as a fixed point number with 18 decimals.
    function totalSupply() public view override(ERC20, IJBToken) returns (uint256) {
        return super.totalSupply();
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Delegation is locked — reward weight always stays with the holder.
    /// @param delegatee The unused proposed delegate.
    function delegate(address delegatee) public pure override {
        revert JBStickyToken_DelegationLocked();
    }

    /// @notice Delegation is locked — reward weight always stays with the holder.
    /// @param delegatee The unused proposed delegate.
    /// @param nonce The unused signature nonce.
    /// @param expiry The unused signature expiry.
    /// @param v The unused recovery identifier.
    /// @param r The unused first signature word.
    /// @param s The unused second signature word.
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        pure
        override
    {
        revert JBStickyToken_DelegationLocked();
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Allow minting and burning. Transfers between accounts revert when soulbound; otherwise the hook is
    /// notified so the moved tokens restart their streak clock with the receiver. Every positive burn consumes
    /// accounting here, including voluntary controller burns that do not trigger a terminal cash out callback.
    /// @dev Every receiver is self-delegated on first receipt so reward weight always tracks balance.
    /// The terminal can call the staked token between minting and its pay hook. Outgoing movements during that gap
    /// must revert; otherwise they would consume older tranches before the newly minted tranche is recorded.
    /// @param from The address tokens are moving from. `address(0)` means the tokens are being minted.
    /// @param to The address tokens are moving to. `address(0)` means the tokens are being burned.
    /// @param value The amount of tokens moving.
    function _update(address from, address to, uint256 value) internal override {
        if (value != 0 && from != address(0) && from != to) {
            uint256 tokenBalance = balanceOf(from);
            uint256 stakedBalance = HOOK.stakedBalanceOf({projectId: PROJECT_ID, holder: from});
            if (tokenBalance != stakedBalance) {
                revert JBStickyToken_UnrecordedMint({
                    holder: from, tokenBalance: tokenBalance, stakedBalance: stakedBalance
                });
            }
        }

        if (from != address(0) && to != address(0)) {
            if (SOULBOUND) revert JBStickyToken_Soulbound();

            // Move the staked accounting: consume the sender's newest tranches, restart the clock for the receiver.
            if (value != 0 && from != to) {
                HOOK.recordTransfer({projectId: PROJECT_ID, from: from, to: to, amount: value});
            }
        } else if (from != address(0) && value != 0) {
            HOOK.recordBurn({projectId: PROJECT_ID, holder: from, amount: value});
        }

        // Self-delegate first-time receivers so voting power always tracks staked balance.
        if (value != 0 && to != address(0) && delegates(to) == address(0)) _delegate({account: to, delegatee: to});

        super._update({from: from, to: to, value: value});
    }
}
