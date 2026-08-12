// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {JBStickyTranche} from "./structs/JBStickyTranche.sol";

/// @notice A data hook that tracks staking positions for sticky projects. Each stake creates a tranche with its own
/// timestamp, unstakes consume tranches newest-first (splitting the newest tranche if needed, without resetting its
/// timestamp), and each holder has a streak clock that starts when their staked balance becomes non-zero and resets
/// only when it returns to zero. The hook is silent on rewards — reward math happens off-chain from the events and
/// views this hook exposes.
contract JBStickyHook is ERC165, IJBStickyHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a pay or cash out hook callback comes from an address that isn't a terminal of the project.
    error JBStickyHook_CallerNotTerminal(address caller);

    /// @notice Thrown when a transfer report comes from an address that isn't the project's registered token.
    error JBStickyHook_CallerNotToken(address caller, address token);

    /// @notice Thrown when a payer stakes to a beneficiary who hasn't trusted them, without being one of the
    /// project's granters.
    error JBStickyHook_SenderNotTrusted(address payer, address beneficiary);

    /// @notice Thrown when an address other than the deployer attempts to set a project's granters.
    error JBStickyHook_Unauthorized(address caller, address deployer);

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

    /// @notice The sticky token allowed to report transfers for a project.
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

    /// @notice Each holder's staking tranches, oldest first.
    /// @custom:param projectId The ID of the sticky project the tranches belong to.
    /// @custom:param holder The address the tranches belong to.
    mapping(uint256 projectId => mapping(address holder => JBStickyTranche[])) internal _tranchesOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers for projects.
    /// @param deployer The address allowed to set a project's granters, once, at launch.
    constructor(IJBDirectory directory, address deployer) {
        DIRECTORY = directory;
        DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Consume a holder's tranches to account for an unstake, newest-first. If the unstake ends partway
    /// through a tranche, the tranche keeps its original timestamp so the remainder's duration isn't reset. If the
    /// holder's staked balance reaches zero, their streak ends.
    /// @dev Can only be called by a terminal of the project. No funds are forwarded to this hook.
    /// @param context The cash out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        // Make sure the caller is a terminal of the project.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBStickyHook_CallerNotTerminal(msg.sender);
        }

        // Consume the holder's newest tranches and end their streak if their staked balance reached zero.
        uint256 stakedBalance =
            _consumeFrom({projectId: context.projectId, holder: context.holder, count: context.cashOutCount});

        emit Unstaked({
            projectId: context.projectId,
            holder: context.holder,
            count: context.cashOutCount,
            stakedBalance: stakedBalance,
            caller: msg.sender
        });
    }

    /// @notice Record a stake as a new tranche for the payment's beneficiary. If the beneficiary's staked balance was
    /// zero, their streak starts. Staking more never moves an existing streak's start — each tranche keeps its own
    /// timestamp so amount-weighted reward math can't be backdated by topping up.
    /// @dev Can only be called by a terminal of the project. No funds are forwarded to this hook.
    /// @param context The payment context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Make sure the caller is a terminal of the project.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBStickyHook_CallerNotTerminal(msg.sender);
        }

        // Keep a reference to the number of staked project tokens minted for the stake.
        uint256 count = context.newlyIssuedTokenCount;

        // If no tokens were minted, there's no position to track.
        if (count == 0) return;

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

    /// @notice Registers the sticky token allowed to report transfers for a project.
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

    /// @notice Pass the cash out through untouched, and have the terminal call back into this hook so the unstake can
    /// be accounted for.
    /// @param context The cash out context passed to this hook by the terminal.
    /// @return cashOutTaxRate The ruleset's cash out tax rate, unchanged.
    /// @return effectiveCashOutCount The number of tokens being cashed out, unchanged.
    /// @return effectiveTotalSupply The project token's total supply, unchanged.
    /// @return effectiveSurplusValue The project's surplus, unchanged.
    /// @return hookSpecifications A specification instructing the terminal to call this hook with no funds forwarded.
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
        // Have the terminal call back into this hook, with no funds forwarded.
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)), noop: false, amount: 0, metadata: bytes("")
        });

        return
            (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
    }

    /// @notice Make sure the payer is allowed to stake for the beneficiary, pass the ruleset's weight through
    /// untouched, and have the terminal call back into this hook so the stake can be accounted for.
    /// @dev Self-stakes are always allowed. Stakes to someone else require the payer to be one of the project's
    /// granters or a sender the beneficiary has trusted — so nobody can pad a stranger's position.
    /// @param context The payment context passed to this hook by the terminal.
    /// @return weight The ruleset's weight, unchanged.
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

        // Have the terminal call back into this hook, with no funds forwarded.
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] =
            JBPayHookSpecification({hook: IJBPayHook(address(this)), noop: false, amount: 0, metadata: bytes("")});

        return (context.weight, hookSpecifications);
    }

    /// @notice No address can mint a sticky project's tokens on demand — staked tokens only exist against stakes.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool) {
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
    function trancheCountOf(uint256 projectId, address holder) external view override returns (uint256) {
        return _tranchesOf[projectId][holder].length;
    }

    /// @notice A holder's tranches, oldest first.
    /// @param projectId The ID of the sticky project to get the tranches of.
    /// @param holder The address to get the tranches of.
    function tranchesOf(uint256 projectId, address holder) external view override returns (JBStickyTranche[] memory) {
        return _tranchesOf[projectId][holder];
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
        // Record a new tranche with its own timestamp.
        _tranchesOf[projectId][holder].push(
            JBStickyTranche({amount: SafeCast.toUint208(count), timestamp: SafeCast.toUint48(block.timestamp)})
        );

        // Store the holder's new staked balance.
        stakedBalance = stakedBalanceOf[projectId][holder] + count;
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
        // Keep a reference to the number of tokens left to consume from tranches.
        uint256 remaining = count;

        // Keep a reference to the holder's tranches.
        JBStickyTranche[] storage tranches = _tranchesOf[projectId][holder];

        // Keep a reference to the number of tranches the holder has.
        uint256 numberOfTranches = tranches.length;

        // Consume tranches newest-first until the amount is covered.
        while (remaining != 0 && numberOfTranches != 0) {
            // Keep a reference to the newest tranche.
            JBStickyTranche memory tranche = tranches[numberOfTranches - 1];

            if (tranche.amount > remaining) {
                // If the newest tranche more than covers the amount, split it: shrink its amount and keep its
                // original timestamp so the remainder's duration isn't reset.
                // casting to 'uint208' is safe because `remaining` is less than `tranche.amount`, a uint208.
                // forge-lint: disable-next-line(unsafe-typecast)
                tranches[numberOfTranches - 1].amount = tranche.amount - uint208(remaining);
                remaining = 0;
            } else {
                // Otherwise consume the whole tranche and move on to the next-newest.
                remaining -= tranche.amount;
                tranches.pop();
                numberOfTranches--;
            }
        }

        // The staked balance always equals the sum of the tranches, so the consumed amount can be subtracted safely.
        stakedBalance = stakedBalanceOf[projectId][holder] - (count - remaining);
        stakedBalanceOf[projectId][holder] = stakedBalance;

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
}
