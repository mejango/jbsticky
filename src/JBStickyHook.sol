// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {JBStickyPricing} from "./libraries/JBStickyPricing.sol";
import {JBStickyPaySnapshot} from "./structs/JBStickyPaySnapshot.sol";
import {JBStickyTranche} from "./structs/JBStickyTranche.sol";

/// @notice A data hook that tracks staking positions for sticky projects. Each stake creates a tranche with its own
/// timestamp, unstakes consume tranches newest-first (splitting the newest tranche if needed, without resetting its
/// timestamp), and each holder has a streak clock that starts when their staked balance becomes non-zero and resets
/// only when it returns to zero. Tranche and streak views are informational; reward distributions use the token's
/// voting checkpoints.
// Callbacks are payable to implement the core interfaces, but both explicitly reject ETH.
// slither-disable-next-line locked-ether
contract JBStickyHook is ERC165, IJBStickyHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a pay or cash out hook callback comes from an address that isn't a terminal of the project.
    error JBStickyHook_CallerNotTerminal(address caller);

    /// @notice Thrown when a transfer report comes from an address that isn't the project's registered token.
    error JBStickyHook_CallerNotToken(address caller, address token);

    /// @notice Thrown when a token reports more tokens leaving than the holder has staked.
    error JBStickyHook_InsufficientStakedBalance(uint256 projectId, address holder, uint256 balance, uint256 count);

    /// @notice The terminal's backing cannot be below the excluded orphaned balance.
    error JBStickyHook_InvalidBacking(uint256 projectId, uint256 backing, uint256 orphanedBalance);

    /// @notice A payment callback did not carry the pricing snapshot produced by this hook.
    error JBStickyHook_InvalidPricingMetadata(uint256 projectId, uint256 length);

    /// @notice A token callback changed aggregate pricing state before this payment could be accounted for.
    error JBStickyHook_PricingStateChanged(
        uint256 projectId, uint256 expectedSupply, uint256 actualSupply, uint256 expectedBacking, uint256 actualBacking
    );

    /// @notice Thrown when a payer stakes to a beneficiary who hasn't trusted them, without being one of the
    /// project's granters.
    error JBStickyHook_SenderNotTrusted(address payer, address beneficiary);

    /// @notice A burn cannot leave a positive share supply below the floor that keeps atom pricing fine-grained.
    error JBStickyHook_SupplyBelowMinimum(uint256 projectId, uint256 remainingSupply, uint256 minimumSupply);

    /// @notice Thrown when an address other than the deployer attempts to set a project's granters.
    error JBStickyHook_Unauthorized(address caller, address deployer);

    /// @notice The terminal must issue exactly the shares priced by the authenticated pre-payment snapshot.
    error JBStickyHook_UnexpectedIssuedCount(uint256 projectId, uint256 expected, uint256 actual);

    /// @notice Sticky callbacks never receive forwarded native funds.
    error JBStickyHook_UnexpectedValue(uint256 value);

    /// @notice Pricing requires the token registered for a Sticky project.
    error JBStickyHook_UnknownProject(uint256 projectId);

    /// @notice Thrown when a positive payment would issue no sticky tokens.
    error JBStickyHook_ZeroIssuance(uint256 projectId, uint256 amount);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The address allowed to set a project's granters, once, at launch.
    address public immutable override DEPLOYER;

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The sticky token allowed to report transfers and burns for a project.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => address) public override tokenOf;

    /// @notice Whether an address can airdrop stakes to any holder of a sticky project.
    /// @custom:param projectId The ID of the sticky project the granter can airdrop to.
    /// @custom:param granter The address allowed to airdrop.
    mapping(uint256 projectId => mapping(address granter => bool)) public override isGranterOf;

    /// @notice Whether a holder allows a sender to add stakes to their position.
    /// @custom:param projectId The ID of the sticky project the trust applies to.
    /// @custom:param holder The holder whose position the sender can add to.
    /// @custom:param sender The trusted sender.
    mapping(uint256 projectId => mapping(address holder => mapping(address sender => bool)))
        public
        override isTrustedSenderOf;

    /// @notice The total number of staked project tokens a holder has, as a fixed point number with 18 decimals.
    /// @custom:param projectId The ID of the sticky project the balance belongs to.
    /// @custom:param holder The address the balance belongs to.
    mapping(uint256 projectId => mapping(address holder => uint256)) public override stakedBalanceOf;

    /// @notice Underlying backing permanently excluded because it was present when the project had no shares.
    /// @dev Refreshed when the next positive stake establishes a new supply. With zero supply all current backing
    /// is unowned, including donations received since this value was last stored.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => uint256) public override orphanedBalanceOf;

    /// @notice The timestamp at which a holder's active streak started, or 0 if nothing is staked.
    /// @dev Staking more never moves this timestamp. It resets only when the holder's staked balance returns to zero.
    /// @custom:param projectId The ID of the sticky project the streak belongs to.
    /// @custom:param holder The address the streak belongs to.
    mapping(uint256 projectId => mapping(address holder => uint256)) public override streakStartOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The longest completed streak a holder has had, in seconds.
    /// @dev Does not include the holder's active streak. Use `longestStreakOf(...)` for the combined value.
    /// @custom:param projectId The ID of the sticky project the streak belongs to.
    /// @custom:param holder The address the streak belongs to.
    mapping(uint256 projectId => mapping(address holder => uint256)) internal _longestCompletedStreakOf;

    /// @notice The number of active tranches for each holder.
    /// @dev Entries at or above this count are discarded and can be overwritten by later stakes.
    /// @custom:param projectId The ID of the sticky project.
    /// @custom:param holder The holder whose tranches are counted.
    mapping(uint256 projectId => mapping(address holder => uint256)) internal _trancheCountOf;

    /// @notice The cumulative staked balance through each active tranche, oldest first.
    /// @dev Strictly increasing because zero additions are ignored. Binary search finds a partial exit's retained
    /// tail without iterating over discarded tranches. Entries outside the active count are never read.
    /// @custom:param projectId The ID of the sticky project.
    /// @custom:param holder The holder whose tranches are indexed.
    /// @custom:param index The tranche's zero-based index.
    mapping(uint256 projectId => mapping(address holder => mapping(uint256 index => uint256))) internal _trancheEndOf;

    /// @notice Each holder's staking tranches, oldest first, including inactive storage awaiting reuse.
    /// @dev Only entries below `_trancheCountOf` are active. Logical truncation keeps full exits constant cost and
    /// partial exits logarithmic even after arbitrary incoming dust transfers.
    /// @custom:param projectId The ID of the sticky project the tranches belong to.
    /// @custom:param holder The address the tranches belong to.
    /// @custom:param index The tranche's zero-based index.
    mapping(uint256 projectId => mapping(address holder => mapping(uint256 index => JBStickyTranche))) internal
        _tranchesOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Bind position accounting to the trusted project directory and sticky deployer.
    /// @param directory The directory of terminals and controllers for projects.
    /// @param deployer The address allowed to set a project's granters, once, at launch.
    constructor(IJBDirectory directory, address deployer) {
        DIRECTORY = directory;
        DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept a terminal's cash out callback without modifying token accounting.
    /// @dev Burns are recorded by the registered token, including direct controller burns. Recording them here as
    /// well would consume the holder's tranches twice. This compatibility callback is not requested by the hook.
    /// @param context The cash out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        if (msg.value != 0) revert JBStickyHook_UnexpectedValue(msg.value);
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBStickyHook_CallerNotTerminal(msg.sender);
        }
    }

    /// @notice Record a stake as a new tranche for the payment's beneficiary. If the beneficiary's staked balance was
    /// zero, their streak starts. Staking more never moves an existing streak's start — each tranche keeps its own
    /// timestamp so amount-weighted reward math can't be backdated by topping up.
    /// @dev Can only be called by a terminal of the project. No funds are forwarded to this hook.
    /// @param context The payment context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        if (msg.value != 0) revert JBStickyHook_UnexpectedValue(msg.value);
        // Make sure the caller is a terminal of the project.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBStickyHook_CallerNotTerminal(msg.sender);
        }

        // Keep a reference to the number of staked project tokens minted for the stake.
        uint256 count = context.newlyIssuedTokenCount;

        // A positive payment cannot silently donate backing when its issuance rounds down to zero.
        if (count == 0) {
            if (context.amount.value != 0) {
                revert JBStickyHook_ZeroIssuance({projectId: context.projectId, amount: context.amount.value});
            }
            return;
        }

        // The terminal mints before calling this hook. Its approve(0) token interaction can invoke arbitrary token
        // code in between, so neither nested payments nor burns/donations may cross this pricing snapshot.
        if (context.hookMetadata.length != 96) {
            revert JBStickyHook_InvalidPricingMetadata({
                projectId: context.projectId, length: context.hookMetadata.length
            });
        }
        JBStickyPaySnapshot memory snapshot = abi.decode(context.hookMetadata, (JBStickyPaySnapshot));
        // A missing or failed project feed must never make a fallback price dilute existing holders.
        uint256 expectedCount = Math.mulDiv({
            x: context.amount.value,
            y: snapshot.supply == 0 ? 1e18 : snapshot.supply,
            denominator: snapshot.supply == 0
                ? 10 ** context.amount.decimals
                : snapshot.backing - snapshot.orphanedBalance
        });
        if (count != expectedCount) {
            revert JBStickyHook_UnexpectedIssuedCount({
                projectId: context.projectId, expected: expectedCount, actual: count
            });
        }
        uint256 actualSupply = IJBToken(tokenOf[context.projectId]).totalSupply();
        uint256 actualBacking = _backingOf({
            terminal: IJBTerminal(msg.sender),
            projectId: context.projectId,
            token: context.amount.token,
            decimals: context.amount.decimals,
            currency: context.amount.currency
        });
        uint256 expectedSupply = snapshot.supply + count;
        uint256 expectedBacking = snapshot.backing + context.amount.value;
        if (actualSupply != expectedSupply || actualBacking != expectedBacking) {
            revert JBStickyHook_PricingStateChanged({
                projectId: context.projectId,
                expectedSupply: expectedSupply,
                actualSupply: actualSupply,
                expectedBacking: expectedBacking,
                actualBacking: actualBacking
            });
        }
        if (orphanedBalanceOf[context.projectId] != snapshot.orphanedBalance) {
            orphanedBalanceOf[context.projectId] = snapshot.orphanedBalance;
            emit ExcludeOrphanedBalance({
                projectId: context.projectId, amount: snapshot.orphanedBalance, caller: msg.sender
            });
        }

        // Record the stake as a new tranche, starting the beneficiary's streak if their balance was zero.
        uint256 stakedBalance = _addTo({projectId: context.projectId, holder: context.beneficiary, count: count});

        emit Staked({
            projectId: context.projectId,
            holder: context.beneficiary,
            payer: context.payer,
            count: count,
            stakedBalance: stakedBalance,
            caller: msg.sender
        });
    }

    /// @notice Consume the newest tranches for every token burn, including burns that reclaim no backing.
    /// @dev Only the project's registered sticky token can report burns. Zero burns leave accounting unchanged. A
    /// burn may empty the supply, but cannot leave it positive below the floor: a sole holder could otherwise burn
    /// down to one atom, donate, and price every later deposit in whole atoms worth more than a newcomer can pay.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose tokens were burned.
    /// @param amount The number of tokens burned, as a fixed point number with 18 decimals.
    function recordBurn(uint256 projectId, address holder, uint256 amount) external override {
        if (msg.sender != tokenOf[projectId]) {
            revert JBStickyHook_CallerNotToken({caller: msg.sender, token: tokenOf[projectId]});
        }
        if (amount == 0) return;

        // The token reports before it burns, so its supply still includes the amount leaving.
        uint256 remainingSupply = IJBToken(msg.sender).totalSupply() - amount;
        if (remainingSupply != 0 && remainingSupply < JBStickyPricing.MIN_SUPPLY) {
            revert JBStickyHook_SupplyBelowMinimum({
                projectId: projectId, remainingSupply: remainingSupply, minimumSupply: JBStickyPricing.MIN_SUPPLY
            });
        }

        uint256 stakedBalance = _consumeFrom({projectId: projectId, holder: holder, count: amount});
        emit Unstaked({
            projectId: projectId, holder: holder, count: amount, stakedBalance: stakedBalance, caller: msg.sender
        });
    }

    /// @notice Moves staked accounting between holders for a transferable sticky token: the sender's newest
    /// tranches are consumed and the receiver gets a fresh tranche — transfers restart the clock on moved tokens.
    /// @dev Can only be called by the project's registered sticky token.
    /// @param projectId The ID of the sticky project the transfer belongs to.
    /// @param from The holder the tokens moved from.
    /// @param to The holder the tokens moved to.
    /// @param amount The number of tokens moved, as a fixed point number with 18 decimals.
    function recordTransfer(uint256 projectId, address from, address to, uint256 amount) external override {
        // Make sure the caller is the project's registered sticky token.
        if (msg.sender != tokenOf[projectId]) {
            revert JBStickyHook_CallerNotToken({caller: msg.sender, token: tokenOf[projectId]});
        }

        // Zero movements and self transfers cannot create tranches or restart an existing position.
        if (amount == 0 || from == to) return;

        // Consume the sender's newest tranches, ending their streak if their balance reached zero.
        uint256 fromBalance = _consumeFrom({projectId: projectId, holder: from, count: amount});

        emit Unstaked({
            projectId: projectId, holder: from, count: amount, stakedBalance: fromBalance, caller: msg.sender
        });

        // The moved tokens restart their clock as the receiver's newest tranche.
        uint256 toBalance = _addTo({projectId: projectId, holder: to, count: amount});

        emit Staked({
            projectId: projectId, holder: to, payer: from, count: amount, stakedBalance: toBalance, caller: msg.sender
        });
    }

    /// @notice Allows addresses to airdrop stakes to any holder of a sticky project.
    /// @dev Can only be called by the deployer, which calls it once at launch — a project's granters are permanent.
    /// @param projectId The ID of the sticky project the senders can airdrop to.
    /// @param granters The addresses allowed to airdrop.
    function setGrantersFor(uint256 projectId, address[] calldata granters) external override {
        // Make sure the caller is the deployer.
        if (msg.sender != DEPLOYER) revert JBStickyHook_Unauthorized({caller: msg.sender, deployer: DEPLOYER});

        for (uint256 i; i < granters.length; i++) {
            // Store the granter.
            isGranterOf[projectId][granters[i]] = true;

            emit SetGranter({projectId: projectId, granter: granters[i], caller: msg.sender});
        }
    }

    /// @notice Registers the sticky token allowed to report transfers and burns for a project.
    /// @dev Can only be called by the deployer, which calls it once at launch.
    /// @param projectId The ID of the sticky project.
    /// @param token The sticky token.
    function setTokenFor(uint256 projectId, address token) external override {
        // Make sure the caller is the deployer.
        if (msg.sender != DEPLOYER) revert JBStickyHook_Unauthorized({caller: msg.sender, deployer: DEPLOYER});

        // Store the token.
        tokenOf[projectId] = token;

        emit SetToken({projectId: projectId, token: token, caller: msg.sender});
    }

    /// @notice Allows or disallows a sender to add stakes to the caller's position.
    /// @param projectId The ID of the sticky project the trust applies to.
    /// @param sender The sender to trust or untrust.
    /// @param trusted Whether the sender should be trusted.
    function setTrustedSenderFor(uint256 projectId, address sender, bool trusted) external override {
        // Store the trust.
        isTrustedSenderOf[projectId][msg.sender][sender] = trusted;

        emit SetTrustedSender({projectId: projectId, holder: msg.sender, sender: sender, trusted: trusted});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Cash out against share-owned backing, excluding funds that existed without any shares.
    /// @param context The cash out context passed to this hook by the terminal.
    /// @return cashOutTaxRate The ruleset's cash out tax rate, unchanged.
    /// @return effectiveCashOutCount The number of tokens being cashed out, unchanged.
    /// @return effectiveTotalSupply The project token's total supply, unchanged.
    /// @return effectiveSurplusValue The project's surplus less the excluded orphaned backing.
    /// @return hookSpecifications No cash out callbacks; the token records every burn exactly once.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        hookSpecifications = new JBCashOutHookSpecification[](0);

        uint256 orphanedBalance = orphanedBalanceOf[context.projectId];
        if (context.surplus.value < orphanedBalance) {
            revert JBStickyHook_InvalidBacking({
                projectId: context.projectId, backing: context.surplus.value, orphanedBalance: orphanedBalance
            });
        }

        return (
            context.cashOutTaxRate,
            context.cashOutCount,
            context.totalSupply,
            context.surplus.value - orphanedBalance,
            hookSpecifications
        );
    }

    /// @notice Price new shares against their pre-payment backing and request a callback to record the stake.
    /// @dev Self-stakes are always allowed. Stakes to someone else require the payer to be one of the project's
    /// granters or a sender the beneficiary has trusted — so nobody can pad a stranger's position.
    /// @param context The payment context passed to this hook by the terminal.
    /// @return weight The backing-priced issuance weight, or zero if issuance would lose too much to rounding.
    /// @return hookSpecifications A specification instructing the terminal to call this hook with no funds forwarded.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Self-stakes are always allowed; stakes to someone else need the beneficiary's trust or granter status.
        if (
            context.payer != context.beneficiary && !isGranterOf[context.projectId][context.payer]
                && !isTrustedSenderOf[context.projectId][context.beneficiary][context.payer]
        ) revert JBStickyHook_SenderNotTrusted({payer: context.payer, beneficiary: context.beneficiary});

        address token = tokenOf[context.projectId];
        if (token == address(0)) revert JBStickyHook_UnknownProject(context.projectId);
        uint256 supply = IJBToken(token).totalSupply();
        uint256 backing = _backingOf({
            terminal: IJBTerminal(context.terminal),
            projectId: context.projectId,
            token: context.amount.token,
            decimals: context.amount.decimals,
            currency: context.amount.currency
        });
        uint256 orphanedBalance = supply == 0 ? backing : orphanedBalanceOf[context.projectId];
        if (backing < orphanedBalance) {
            revert JBStickyHook_InvalidBacking({
                projectId: context.projectId, backing: backing, orphanedBalance: orphanedBalance
            });
        }
        weight = JBStickyPricing.weightFrom({
            amount: context.amount.value,
            supply: supply,
            backing: backing - orphanedBalance,
            decimals: context.amount.decimals
        });

        // Have the terminal call back into this hook, with no funds forwarded.
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(address(this)),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                JBStickyPaySnapshot({supply: supply, backing: backing, orphanedBalance: orphanedBalance})
            )
        });

        return (weight, hookSpecifications);
    }

    /// @notice No address can mint a sticky project's tokens on demand; tokens only exist against stakes.
    /// @param projectId The ID of the project whose mint permission is being checked.
    /// @param ruleset The ruleset whose mint permission is being checked.
    /// @param addr The address whose mint permission is being checked.
    /// @return permitted Always false.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset memory ruleset,
        address addr
    )
        external
        pure
        override
        returns (bool permitted)
    {
        return false;
    }

    /// @notice The longest streak a holder has ever had, including their active streak.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    /// @return The holder's longest streak duration, in seconds.
    function longestStreakOf(uint256 projectId, address holder) external view override returns (uint256) {
        // Keep a reference to the holder's active streak duration.
        uint256 current = currentStreakOf({projectId: projectId, holder: holder});

        // Keep a reference to the holder's longest completed streak.
        uint256 longestCompleted = _longestCompletedStreakOf[projectId][holder];

        return current > longestCompleted ? current : longestCompleted;
    }

    /// @notice The number of tranches a holder has.
    /// @param projectId The ID of the sticky project to check the tranches of.
    /// @param holder The address to check the tranches of.
    /// @return count The number of active tranches.
    function trancheCountOf(uint256 projectId, address holder) external view override returns (uint256 count) {
        return _trancheCountOf[projectId][holder];
    }

    /// @notice A holder's tranches, oldest first.
    /// @param projectId The ID of the sticky project to get the tranches of.
    /// @param holder The address to get the tranches of.
    /// @return tranches The active tranches, oldest first.
    function tranchesOf(
        uint256 projectId,
        address holder
    )
        external
        view
        override
        returns (JBStickyTranche[] memory tranches)
    {
        return _tranchesIn({projectId: projectId, holder: holder, start: 0, count: _trancheCountOf[projectId][holder]});
    }

    /// @notice A bounded range of a holder's active tranches, oldest first.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose tranches to read.
    /// @param start The zero-based index of the first tranche to read.
    /// @param count The maximum number of tranches to return, capped at 256.
    /// @return tranches The requested tranches, ending at the active count if fewer remain.
    function tranchesOf(
        uint256 projectId,
        address holder,
        uint256 start,
        uint256 count
    )
        external
        view
        override
        returns (JBStickyTranche[] memory tranches)
    {
        if (count > 256) count = 256;
        return _tranchesIn({projectId: projectId, holder: holder, start: start, count: count});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The duration of a holder's active streak, in seconds.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    /// @return The number of seconds since the holder's staked balance last became non-zero, or 0 if nothing is
    /// staked.
    function currentStreakOf(uint256 projectId, address holder) public view override returns (uint256) {
        // Keep a reference to the streak's start.
        uint256 streakStart = streakStartOf[projectId][holder];

        return streakStart == 0 ? 0 : block.timestamp - streakStart;
    }

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBStickyHook).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBPayHook).interfaceId || interfaceId == type(IJBCashOutHook).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Records tokens joining a holder's position as a fresh tranche, starting their streak if their staked
    /// balance was zero.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder the tokens joined.
    /// @param count The number of tokens joining, as a fixed point number with 18 decimals.
    /// @return stakedBalance The holder's staked balance after the addition.
    function _addTo(uint256 projectId, address holder, uint256 count) internal returns (uint256 stakedBalance) {
        stakedBalance = stakedBalanceOf[projectId][holder];
        if (count == 0) return stakedBalance;

        uint256 index = _trancheCountOf[projectId][holder];
        stakedBalance += count;
        _tranchesOf[projectId][holder][index] =
            JBStickyTranche({amount: SafeCast.toUint208(count), timestamp: SafeCast.toUint48(block.timestamp)});
        _trancheEndOf[projectId][holder][index] = stakedBalance;
        _trancheCountOf[projectId][holder] = index + 1;
        stakedBalanceOf[projectId][holder] = stakedBalance;

        // If the holder doesn't have an active streak, start one.
        if (streakStartOf[projectId][holder] == 0) {
            streakStartOf[projectId][holder] = block.timestamp;

            emit StreakStarted({projectId: projectId, holder: holder, caller: msg.sender});
        }
    }

    /// @notice Consumes a holder's newest tranches to cover tokens leaving their position, splitting the last tranche
    /// in place (keeping its original timestamp) and ending the holder's streak if their balance reached zero.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder the tokens left.
    /// @param count The number of tokens leaving, as a fixed point number with 18 decimals.
    /// @return stakedBalance The holder's staked balance after the consumption.
    function _consumeFrom(uint256 projectId, address holder, uint256 count) internal returns (uint256 stakedBalance) {
        stakedBalance = stakedBalanceOf[projectId][holder];
        if (count == 0) return stakedBalance;
        if (count > stakedBalance) {
            revert JBStickyHook_InsufficientStakedBalance({
                projectId: projectId, holder: holder, balance: stakedBalance, count: count
            });
        }
        stakedBalance -= count;
        stakedBalanceOf[projectId][holder] = stakedBalance;

        if (stakedBalance == 0) {
            // Discard the entire logical stack without clearing storage proportional to its length.
            _trancheCountOf[projectId][holder] = 0;
        } else {
            uint256 low;
            uint256 high = _trancheCountOf[projectId][holder] - 1;

            // Find the first cumulative tranche balance that contains the retained balance. Each iteration halves
            // the range, so even a dust-filled position can exit without scanning or deleting its newest tranches.
            while (low < high) {
                uint256 middle = low + (high - low) / 2;
                if (_trancheEndOf[projectId][holder][middle] < stakedBalance) low = middle + 1;
                else high = middle;
            }

            JBStickyTranche storage tranche = _tranchesOf[projectId][holder][low];
            tranche.amount =
                SafeCast.toUint208(tranche.amount - (_trancheEndOf[projectId][holder][low] - stakedBalance));
            _trancheEndOf[projectId][holder][low] = stakedBalance;
            _trancheCountOf[projectId][holder] = low + 1;
        }

        // If the holder's staked balance reached zero, end their streak.
        if (stakedBalance == 0) {
            // Keep a reference to the streak's start.
            uint256 streakStart = streakStartOf[projectId][holder];

            if (streakStart != 0) {
                // Keep a reference to the streak's duration.
                uint256 duration = block.timestamp - streakStart;

                // If this streak is the holder's longest, store it.
                if (duration > _longestCompletedStreakOf[projectId][holder]) {
                    _longestCompletedStreakOf[projectId][holder] = duration;
                }

                // Reset the streak.
                streakStartOf[projectId][holder] = 0;

                emit StreakEnded({projectId: projectId, holder: holder, duration: duration, caller: msg.sender});
            }
        }
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Read pre-payment or post-payment backing in the project's single accepted token.
    /// @param terminal The project's immutable terminal.
    /// @param projectId The ID of the sticky project.
    /// @param token The accepted underlying token.
    /// @param decimals The underlying token's accounting decimals.
    /// @param currency The underlying token's accounting currency.
    /// @return backing The terminal backing in underlying token atoms, including excluded orphaned funds.
    function _backingOf(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint8 decimals,
        uint32 currency
    )
        internal
        view
        returns (uint256 backing)
    {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return terminal.currentSurplusOf({projectId: projectId, tokens: tokens, decimals: decimals, currency: currency});
    }

    /// @notice Copy a bounded range of active tranches without exposing logically discarded entries.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose tranches to read.
    /// @param start The zero-based index of the first tranche to read.
    /// @param count The maximum number of tranches to return.
    /// @return tranches The requested range of active tranches.
    function _tranchesIn(
        uint256 projectId,
        address holder,
        uint256 start,
        uint256 count
    )
        internal
        view
        returns (JBStickyTranche[] memory tranches)
    {
        uint256 activeCount = _trancheCountOf[projectId][holder];
        if (start >= activeCount) return new JBStickyTranche[](0);
        uint256 available = activeCount - start;
        if (count > available) count = available;
        tranches = new JBStickyTranche[](count);
        for (uint256 i; i < count; i++) {
            tranches[i] = _tranchesOf[projectId][holder][start + i];
        }
    }
}
