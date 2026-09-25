// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IStickyHook} from "./interfaces/IStickyHook.sol";

import {StickyPricing} from "./libraries/StickyPricing.sol";

import {StickyPaySnapshot} from "./structs/StickyPaySnapshot.sol";
import {StickyTranche} from "./structs/StickyTranche.sol";

/// @notice A data hook that tracks staking positions for sticky projects. Each stake joins the holder's newest
/// tranche when both were created in the same epoch and otherwise creates a tranche with its own timestamp, unstakes
/// consume tranches newest-first (splitting the newest tranche if needed, without resetting its timestamp), and each
/// holder has a streak clock that starts when their staked balance becomes non-zero and resets only when it returns
/// to zero. Net stake is also bucketed by the epoch it joined in, so the distributor can weigh tenure rewards by
/// tranche age without checkpoints. Streak views are informational; default-group rewards use the token's voting
/// checkpoints.
// Callbacks are payable to implement the core interfaces, but both explicitly reject ETH.
// slither-disable-next-line locked-ether
contract StickyHook is ERC165, ERC2771Context, IStickyHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a pay or cash out hook callback comes from an address that isn't a terminal of the project.
    error StickyHook_CallerNotTerminal(address caller);

    /// @notice Thrown when a transfer or burn report comes from an address other than the project's registered token.
    error StickyHook_CallerNotToken(address caller, address token);

    /// @notice Thrown when a token reports more tokens leaving than the holder has staked.
    error StickyHook_InsufficientStakedBalance(uint256 projectId, address holder, uint256 balance, uint256 count);

    /// @notice Thrown when the terminal's backing is below the excluded orphaned balance, since share-owned backing
    /// cannot be negative.
    error StickyHook_InvalidBacking(uint256 projectId, uint256 backing, uint256 orphanedBalance);

    /// @notice Thrown when an epoch range ends before it starts, so it selects no buckets.
    error StickyHook_InvalidEpochRange(uint256 fromEpoch, uint256 toEpoch);

    /// @notice Thrown when a payment callback does not carry the pricing snapshot produced by this hook, so its
    /// issuance cannot be authenticated.
    error StickyHook_InvalidPricingMetadata(uint256 projectId, uint256 length);

    /// @notice Thrown when a token callback changes aggregate pricing state before this payment is accounted for, so a
    /// stale quote cannot issue shares.
    error StickyHook_PricingStateChanged(
        uint256 projectId, uint256 expectedSupply, uint256 actualSupply, uint256 expectedBacking, uint256 actualBacking
    );

    /// @notice Thrown when a payer stakes to a beneficiary who hasn't trusted them, without being one of the
    /// project's granters.
    error StickyHook_SenderNotTrusted(address payer, address beneficiary);

    /// @notice Thrown when an address other than the deployer attempts to set a project's granters or token.
    error StickyHook_Unauthorized(address caller, address deployer);

    /// @notice Thrown when the terminal issues a share count other than the one priced by the authenticated
    /// pre-payment snapshot.
    error StickyHook_UnexpectedIssuedCount(uint256 projectId, uint256 expected, uint256 actual);

    /// @notice Thrown when a callback receives native funds, which this hook has no path to withdraw.
    error StickyHook_UnexpectedValue(uint256 value);

    /// @notice Thrown when pricing a payment for a project without a registered Sticky token, since issuance depends on
    /// its share supply.
    error StickyHook_UnknownProject(uint256 projectId);

    /// @notice Thrown when a positive payment would issue no sticky tokens, so the payer keeps funds that bought no
    /// shares.
    error StickyHook_ZeroIssuance(uint256 projectId, uint256 amount);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The duration of one stake-age epoch. Tranches created in the same epoch merge, and net stake is
    /// bucketed by the epoch it joined in.
    uint256 public constant override EPOCH_DURATION = 1 weeks;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The most tranches returned by a bounded query, limiting RPC response size.
    uint256 internal constant _MAX_TRANCHE_PAGE = 256;

    /// @notice The seed of each project's transient slot counting payments whose minted shares are not yet recorded.
    /// @dev Solidity 0.8.28 gives the transient data location to value types only, so per-project counters live in
    /// keyed slots read with `tload` and written with `tstore`.
    bytes32 internal constant _PAYING_SLOT_SEED = keccak256("StickyHook.payingOf");

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

    /// @notice The net stake still held from tranches created in each epoch, as a fixed point number with 18
    /// decimals.
    /// @dev Grows when tokens join a position during the epoch and shrinks when a tranche created in the epoch is
    /// later consumed, so a project's buckets always sum to its holders' staked balances.
    /// @custom:param projectId The ID of the sticky project.
    /// @custom:param epoch The epoch, measured as `timestamp / EPOCH_DURATION`.
    mapping(uint256 projectId => mapping(uint256 epoch => uint256)) public override netStakedIn;

    /// @notice Underlying backing permanently excluded because it was present when the project had no shares.
    /// @dev Refreshed when the next positive stake establishes a new supply. With zero supply all current backing
    /// is unowned, including donations received since this value was last stored.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => uint256) public override orphanedBalanceOf;

    /// @notice The total number of staked project tokens a holder has, as a fixed point number with 18 decimals.
    /// @custom:param projectId The ID of the sticky project the balance belongs to.
    /// @custom:param holder The address the balance belongs to.
    mapping(uint256 projectId => mapping(address holder => uint256)) public override stakedBalanceOf;

    /// @notice The timestamp at which a holder's active streak started, or 0 if nothing is staked.
    /// @dev Staking more never moves this timestamp. It resets only when the holder's staked balance returns to zero.
    /// @custom:param projectId The ID of the sticky project the streak belongs to.
    /// @custom:param holder The address the streak belongs to.
    mapping(uint256 projectId => mapping(address holder => uint256)) public override streakStartOf;

    /// @notice The sticky token allowed to report transfers and burns for a project.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => address) public override tokenOf;

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
    /// @dev Only entries below `_trancheCountOf` are active, and each active tranche was created in a distinct epoch.
    /// Logical truncation plus same-epoch merging keeps an exit's cost bounded by the number of epochs it consumes
    /// even after arbitrary incoming dust transfers.
    /// @custom:param projectId The ID of the sticky project the tranches belong to.
    /// @custom:param holder The address the tranches belong to.
    /// @custom:param index The tranche's zero-based index.
    mapping(uint256 projectId => mapping(address holder => mapping(uint256 index => StickyTranche))) internal
        _tranchesOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Binds position accounting to the trusted project directory and sticky deployer.
    /// @param directory The directory of terminals and controllers for projects.
    /// @param deployer The address allowed to set a project's granters, once, at launch.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    // The Sticky deployer creates its hook with its own nonzero address as the immutable registrar.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IJBDirectory directory, address deployer, address trustedForwarder) ERC2771Context(trustedForwarder) {
        // Use the project's directory to authenticate terminal callbacks against its registered terminals.
        DIRECTORY = directory;

        // Keep registration authority fixed so only the launch deployer can bind tokens and granters.
        DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accepts a terminal's cash out callback without modifying token accounting.
    /// @dev Burns are recorded by the registered token, including direct controller burns. Recording them here as
    /// well would consume the holder's tranches twice. This compatibility callback is not requested by the hook.
    /// @param context The cash out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        // This callback only acknowledges accounting; accepting ETH would leave it without a withdrawal path.
        if (msg.value != 0) revert StickyHook_UnexpectedValue(msg.value);

        // Restrict callback entry to a terminal registered for the project whose cash out is being reported.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            // Reject unrelated callers even though this compatibility callback makes no accounting changes.
            revert StickyHook_CallerNotTerminal(msg.sender);
        }
    }

    /// @notice Records a stake for the payment's beneficiary, joining their newest tranche when it was created in the
    /// same epoch and creating a new tranche otherwise. If the beneficiary's staked balance was zero, their streak
    /// starts. Staking more never moves an existing streak's start, and a tranche's timestamp only ever moves
    /// forward, so a recorded age cannot be backdated by topping up. Tenure rewards weigh tranche age through the
    /// epoch buckets; default-group rewards use voting checkpoints.
    /// @dev Can only be called by a terminal of the project. No funds are forwarded to this hook.
    /// @param context The payment context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Deposits belong in the terminal's backing; this hook only records the resulting position.
        if (msg.value != 0) revert StickyHook_UnexpectedValue(msg.value);

        // Only a registered terminal can authenticate the payment and its pre-payment pricing snapshot.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            // Prevent an arbitrary caller from fabricating a stake or changing the excluded orphaned balance.
            revert StickyHook_CallerNotTerminal(msg.sender);
        }

        // Account for shares actually issued by the terminal, then verify them against the quoted payment.
        uint256 count = context.newlyIssuedTokenCount;

        // A callback with no issued shares must either be an empty payment or fail without taking the deposit.
        if (count == 0) {
            // A positive payment cannot silently donate backing when its issuance rounds down to zero.
            if (context.amount.value != 0) {
                // Revert the terminal's payment too, so the payer keeps funds that bought no shares.
                revert StickyHook_ZeroIssuance({projectId: context.projectId, amount: context.amount.value});
            }

            // An empty payment cannot create a tranche, start a streak, or establish new orphaned backing.
            return;
        }

        // The terminal mints before calling this hook. Its approve(0) token interaction can invoke arbitrary token
        // code in between, so neither nested payments nor burns/donations may cross this pricing snapshot.
        if (context.hookMetadata.length != 96) {
            // Require exactly the three encoded pricing values before attempting to interpret the snapshot.
            revert StickyHook_InvalidPricingMetadata({
                projectId: context.projectId, length: context.hookMetadata.length
            });
        }

        // Recover the pre-payment supply and backing that this hook supplied to the authenticated terminal.
        StickyPaySnapshot memory snapshot = abi.decode(context.hookMetadata, (StickyPaySnapshot));

        // A missing or failed project feed must never make a fallback price dilute existing holders.
        // Empty supply starts at one share per underlying unit; later deposits buy a proportional backing claim.
        uint256 expectedCount = Math.mulDiv({
            x: context.amount.value,
            y: snapshot.supply == 0 ? 1e18 : snapshot.supply,
            denominator: snapshot.supply == 0
                ? 10 ** context.amount.decimals
                : snapshot.backing - snapshot.orphanedBalance
        });

        // The terminal's issuance must match the direct quote, including its downward rounding to whole share atoms.
        if (count != expectedCount) {
            // Reject any alternate terminal or feed calculation that changes the payer's backing-priced issuance.
            revert StickyHook_UnexpectedIssuedCount({
                projectId: context.projectId, expected: expectedCount, actual: count
            });
        }

        // Read supply after minting to detect intervening mints or burns that would invalidate the quote.
        uint256 actualSupply = IJBToken(tokenOf[context.projectId]).totalSupply();

        // Read backing in the same token units as the snapshot so donations and nested payments are detectable.
        uint256 actualBacking = _backingOf({
            terminal: IJBTerminal(msg.sender),
            projectId: context.projectId,
            token: context.amount.token,
            decimals: context.amount.decimals,
            currency: context.amount.currency
        });

        // Only the shares issued for this payment may have been added to the quoted supply.
        uint256 expectedSupply = snapshot.supply + count;

        // Only this payment's deposit may have been added to the quoted terminal backing.
        uint256 expectedBacking = snapshot.backing + context.amount.value;

        // Require both sides of the share price to reflect exactly this payment before recording its position.
        if (actualSupply != expectedSupply || actualBacking != expectedBacking) {
            // Roll back a payment whose intervening token activity would otherwise use a stale issuance price.
            revert StickyHook_PricingStateChanged({
                projectId: context.projectId,
                expectedSupply: expectedSupply,
                actualSupply: actualSupply,
                expectedBacking: expectedBacking,
                actualBacking: actualBacking
            });
        }

        // A bootstrap can discover additional funds left without shares; persist that exclusion when it changes.
        if (orphanedBalanceOf[context.projectId] != snapshot.orphanedBalance) {
            // Establish the excluded balance only after the terminal has authenticated the bootstrap payment.
            orphanedBalanceOf[context.projectId] = snapshot.orphanedBalance;

            // Let observers reconcile the backing excluded from holders' share claims.
            // All preceding external calls are reads under STATICCALL, so none can reorder these state updates.
            // forge-lint: disable-next-item(reentrancy-events)
            emit ExcludeOrphanedBalance({
                projectId: context.projectId, amount: snapshot.orphanedBalance, caller: msg.sender
            });
        }

        // Record the stake in the beneficiary's newest tranche, starting their streak if their balance was zero.
        uint256 stakedBalance = _addTo({projectId: context.projectId, holder: context.beneficiary, count: count});

        // The minted shares now have a tranche, so the buckets agree with the supply again for this payment.
        _settlePayingFor(context.projectId);

        // Publish the authenticated deposit and resulting balance for position histories.
        // All preceding external calls are reads under STATICCALL; position accounting makes no external calls.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Staked({
            projectId: context.projectId,
            holder: context.beneficiary,
            payer: context.payer,
            count: count,
            stakedBalance: stakedBalance,
            caller: msg.sender
        });
    }

    /// @notice Consumes the newest tranches for every token burn, including burns that reclaim no backing.
    /// @dev Only the project's registered sticky token can report burns. Zero burns leave accounting unchanged.
    /// A holder's exit never depends on the share supply left with other holders. Small supplies can make later
    /// deposits unissuable, in which case the payment's rounding checks reject them without taking funds.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose tokens were burned.
    /// @param amount The number of tokens burned, as a fixed point number with 18 decimals.
    function recordBurn(uint256 projectId, address holder, uint256 amount) external override {
        // Only the registered share token can report a burn as part of its authenticated balance update.
        if (msg.sender != tokenOf[projectId]) {
            // Reject fabricated burns that would reduce another holder's tranches without reducing their tokens.
            revert StickyHook_CallerNotToken({caller: msg.sender, token: tokenOf[projectId]});
        }

        // A zero burn must not alter tranche ages, streaks, or the holder's activity history.
        if (amount == 0) return;

        // Remove the burned amount from the newest tranches, preserving the age of any retained shares.
        uint256 stakedBalance = _consumeFrom({projectId: projectId, holder: holder, count: amount});

        // Report exits even when they came from a direct burn that reclaimed no terminal backing.
        emit Unstaked({
            projectId: projectId, holder: holder, count: amount, stakedBalance: stakedBalance, caller: msg.sender
        });
    }

    /// @notice Counts a mint whose tranche this hook has not yet recorded, flagging the project's payment as in
    /// progress until the terminal's after-pay callback records it.
    /// @dev Can only be called by the project's registered sticky token, which mints only when a terminal pays the
    /// project. The count lives in transient storage, so a payment that reverts leaves no flag behind.
    /// @param projectId The ID of the sticky project whose token was minted.
    function recordMint(uint256 projectId) external override {
        // Only the registered share token can report a mint as part of its authenticated balance update.
        if (msg.sender != tokenOf[projectId]) {
            // Reject fabricated mints that would block tenure funding for a project without a payment in flight.
            revert StickyHook_CallerNotToken({caller: msg.sender, token: tokenOf[projectId]});
        }

        // Nested payments to the same project each add one, and each after-pay callback removes one.
        _setPayingCountOf({projectId: projectId, count: _payingCountOf(projectId) + 1});
    }

    /// @notice Moves staked accounting between holders for a transferable sticky token: the sender's newest
    /// tranches are consumed and the moved tokens join the receiver's newest tranche of the current epoch, or a fresh
    /// one. The receiver's existing streak continues.
    /// @dev Can only be called by the project's registered sticky token.
    /// @param projectId The ID of the sticky project the transfer belongs to.
    /// @param from The holder the tokens moved from.
    /// @param to The holder the tokens moved to.
    /// @param amount The number of tokens moved, as a fixed point number with 18 decimals.
    function recordTransfer(uint256 projectId, address from, address to, uint256 amount) external override {
        // Only the registered share token can report a transfer as part of its authenticated balance update.
        if (msg.sender != tokenOf[projectId]) {
            // Reject fabricated transfers that would change tranche ownership without moving any shares.
            revert StickyHook_CallerNotToken({caller: msg.sender, token: tokenOf[projectId]});
        }

        // Zero movements and self transfers cannot create tranches or restart an existing position.
        if (amount == 0 || from == to) return;

        // Consume the sender's newest tranches, ending their streak if their balance reached zero.
        uint256 fromBalance = _consumeFrom({projectId: projectId, holder: from, count: amount});

        // Expose the sender's exit and retained balance to the same position history used for burns.
        emit Unstaked({
            projectId: projectId, holder: from, count: amount, stakedBalance: fromBalance, caller: msg.sender
        });

        // The moved tokens restart their clock in the receiver's newest tranche.
        uint256 toBalance = _addTo({projectId: projectId, holder: to, count: amount});

        // Attribute the receiver's added stake to the sender while preserving their resulting balance.
        emit Staked({
            projectId: projectId, holder: to, payer: from, count: amount, stakedBalance: toBalance, caller: msg.sender
        });
    }

    /// @notice Allows addresses to airdrop stakes to any holder of a sticky project.
    /// @dev Can only be called by the deployer, which calls it once at launch — a project's granters are permanent.
    /// @param projectId The ID of the sticky project the senders can airdrop to.
    /// @param granters The addresses allowed to airdrop.
    function setGrantersFor(uint256 projectId, address[] calldata granters) external override {
        // Only the launch deployer may grant permission to add stakes without each beneficiary's consent.
        if (msg.sender != DEPLOYER) revert StickyHook_Unauthorized({caller: msg.sender, deployer: DEPLOYER});

        // Solidity initializes the index to zero, covering every granter supplied at launch.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < granters.length; i++) {
            // A project-wide granter can add stakes without requiring each beneficiary's individual trust.
            // Each launch-time granter needs a separate permission entry; the caller pays for the list it chose.
            // forge-lint: disable-next-line(costly-loop)
            isGranterOf[projectId][granters[i]] = true;

            // Publish each address that beneficiaries must treat as a project-wide authorized sender.
            emit SetGranter({projectId: projectId, granter: granters[i], caller: msg.sender});
        }
    }

    /// @notice Registers the sticky token allowed to report transfers and burns for a project.
    /// @dev Can only be called by the deployer, which calls it once at launch.
    /// @param projectId The ID of the sticky project.
    /// @param token The sticky token.
    function setTokenFor(uint256 projectId, address token) external override {
        // Only the launch deployer may choose the token trusted to report this project's ownership changes.
        if (msg.sender != DEPLOYER) revert StickyHook_Unauthorized({caller: msg.sender, deployer: DEPLOYER});

        // Bind movement reports to the share token so external callers cannot change position accounting.
        // The SetToken event below records both the project and the token receiving this permission.
        // forge-lint: disable-next-line(missing-events-access-control)
        tokenOf[projectId] = token;

        // Expose the token binding so consumers can identify the authoritative share supply and movement source.
        emit SetToken({projectId: projectId, token: token, caller: msg.sender});
    }

    /// @notice Allows or disallows a sender to add stakes to the caller's position.
    /// @param projectId The ID of the sticky project the trust applies to.
    /// @param sender The sender to trust or untrust.
    /// @param trusted Whether the sender should be trusted.
    function setTrustedSenderFor(uint256 projectId, address sender, bool trusted) external override {
        // Scope consent to the caller's own position; this never grants access to their underlying tokens.
        isTrustedSenderOf[projectId][_msgSender()][sender] = trusted;

        // Let holders and senders track whether beneficiary consent has been granted or revoked.
        emit SetTrustedSender({projectId: projectId, holder: _msgSender(), sender: sender, trusted: trusted});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Prices a cash out against share-owned backing, excluding funds that existed without any shares.
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
        // The token reports every burn, so no additional callback is needed to account for this exit.
        hookSpecifications = new JBCashOutHookSpecification[](0);

        // Funds left without any shares must remain excluded from subsequent holders' redemption claims.
        uint256 orphanedBalance = orphanedBalanceOf[context.projectId];

        // Verify that the terminal can still cover the excluded funds before subtracting them from surplus.
        if (context.surplus.value < orphanedBalance) {
            // An inconsistent backing balance cannot safely price a holder's redemption.
            revert StickyHook_InvalidBacking({
                projectId: context.projectId, backing: context.surplus.value, orphanedBalance: orphanedBalance
            });
        }

        // Preserve the ruleset's cash out curve and share counts, changing only the backing holders can reclaim.
        return (
            context.cashOutTaxRate,
            context.cashOutCount,
            context.totalSupply,
            // Orphaned funds have no share owner and cannot subsidize this cash out.
            context.surplus.value - orphanedBalance,
            // Burn accounting belongs to the token, so the terminal has no follow-up hook to invoke.
            hookSpecifications
        );
    }

    /// @notice Prices new shares against their pre-payment backing and requests a callback to record the stake.
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
        ) revert StickyHook_SenderNotTrusted({payer: context.payer, beneficiary: context.beneficiary});

        // Use the launch-registered share token as the source of outstanding claims on the project's backing.
        address token = tokenOf[context.projectId];

        // An unregistered project has no authoritative share supply from which to calculate issuance.
        if (token == address(0)) revert StickyHook_UnknownProject(context.projectId);

        // Existing supply determines whether issuance bootstraps or preserves holders' proportional backing.
        uint256 supply = IJBToken(token).totalSupply();

        // Price the deposit against backing before this payment, expressed in the payment token's accounting units.
        uint256 backing = _backingOf({
            terminal: IJBTerminal(context.terminal),
            projectId: context.projectId,
            token: context.amount.token,
            decimals: context.amount.decimals,
            currency: context.amount.currency
        });

        // An empty project cannot transfer ownership of its existing backing to the next depositor.
        uint256 orphanedBalance = supply == 0 ? backing : orphanedBalanceOf[context.projectId];

        // The excluded amount must fit within the terminal's balance before deriving share-owned backing.
        if (backing < orphanedBalance) {
            // Reject inconsistent backing instead of attempting to quote issuance from a negative owned balance.
            revert StickyHook_InvalidBacking({
                projectId: context.projectId, backing: backing, orphanedBalance: orphanedBalance
            });
        }

        // Convert the backing-based share quote into the core terminal's issuance weight with rounding checks.
        weight = StickyPricing.weightFrom({
            amount: context.amount.value,
            supply: supply,
            backing: backing - orphanedBalance,
            decimals: context.amount.decimals
        });

        // Reserve one callback so every successful positive payment records exactly one beneficiary tranche.
        hookSpecifications = new JBPayHookSpecification[](1);

        // Request position accounting after minting while keeping the entire deposit in terminal backing.
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(address(this)),
            noop: false,
            amount: 0,
            // Carry the quote's inputs through the terminal so the callback can reject intervening pricing changes.
            metadata: abi.encode(
                StickyPaySnapshot({supply: supply, backing: backing, orphanedBalance: orphanedBalance})
            )
        });

        // Give the terminal both the issuance price and the callback needed to verify and record the resulting stake.
        return (weight, hookSpecifications);
    }

    /// @notice No address can mint a sticky project's tokens on demand; tokens only exist against stakes.
    /// @dev The project ID, ruleset and address do not affect the unconditional denial.
    /// @inheritdoc IJBRulesetDataHook
    /// @return permitted Always false.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool permitted) {
        // Unbacked discretionary issuance would dilute holders, so this hook never grants mint permission.
        return false;
    }

    /// @notice Whether a payment to a project has minted shares this hook has not yet recorded.
    /// @dev The terminal mints before it calls `afterPayRecordedWith`, so during that gap the token's supply exceeds
    /// the sum of the project's epoch buckets. The distributor refuses to read a tenure denominator while this is set.
    /// @param projectId The ID of the sticky project to check.
    /// @return isPaying Whether a payment's minted shares are still waiting for their tranche.
    function isPayingFor(uint256 projectId) external view override returns (bool isPaying) {
        return _payingCountOf(projectId) != 0;
    }

    /// @notice The longest streak a holder has ever had, including their active streak.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    /// @return duration The holder's longest streak duration, in seconds.
    function longestStreakOf(uint256 projectId, address holder) external view override returns (uint256 duration) {
        // Include an ongoing streak because it can exceed every streak the holder has already completed.
        uint256 current = currentStreakOf({projectId: projectId, holder: holder});

        // Preserve the holder's historical record when their current position is shorter or empty.
        uint256 longestCompleted = _longestCompletedStreakOf[projectId][holder];

        // Report the best duration across completed history and uninterrupted current ownership.
        return current > longestCompleted ? current : longestCompleted;
    }

    /// @notice The net stake still held from tranches created within an inclusive epoch range, as a fixed point
    /// number with 18 decimals.
    /// @param projectId The ID of the sticky project.
    /// @param fromEpoch The first epoch to include.
    /// @param toEpoch The last epoch to include.
    /// @return amount The sum of the range's net stake buckets.
    function netStakedWithin(
        uint256 projectId,
        uint256 fromEpoch,
        uint256 toEpoch
    )
        external
        view
        override
        returns (uint256 amount)
    {
        // An inverted range selects no buckets, so reject it instead of silently reporting zero.
        if (fromEpoch > toEpoch) revert StickyHook_InvalidEpochRange({fromEpoch: fromEpoch, toEpoch: toEpoch});

        // Sum every bucket in the range; callers bound the range to the weeks their reward window spans.
        for (uint256 epoch = fromEpoch; epoch <= toEpoch; epoch++) {
            // Each bucket holds only stake that joined in its epoch and is still held.
            amount += netStakedIn[projectId][epoch];
        }
    }

    /// @notice A holder's staked balance held in tranches created through an epoch, as a fixed point number with 18
    /// decimals.
    /// @dev Tranche timestamps never decrease with their index, so a binary search finds the newest tranche created
    /// in or before the epoch and its cumulative endpoint is the balance through that epoch.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose tranches to read.
    /// @param epoch The last epoch to include.
    /// @return balance The staked balance from tranches created in or before the epoch.
    function stakedBalanceThroughEpochOf(
        uint256 projectId,
        address holder,
        uint256 epoch
    )
        external
        view
        override
        returns (uint256 balance)
    {
        // Start at the oldest tranche so the search can include every active tranche.
        uint256 low;

        // Search the whole active prefix; discarded entries above it are never read.
        uint256 high = _trancheCountOf[projectId][holder];

        // Find the number of active tranches created through the epoch. Each iteration halves the range.
        // Solidity initializes low to zero, including the oldest active tranche in the search.
        // forge-lint: disable-next-line(uninitialized-local)
        while (low < high) {
            // Split the remaining range without adding its two indices, which could overflow.
            uint256 middle = low + (high - low) / 2;

            // A tranche created through the epoch means the boundary lies strictly after it.
            if (uint256(_tranchesOf[projectId][holder][middle].timestamp) / EPOCH_DURATION <= epoch) low = middle + 1;
            // Otherwise this tranche is too new, and so is everything after it.
            else high = middle;
        }

        // The cumulative endpoint of the newest qualifying tranche is the balance through the epoch.
        return low == 0 ? 0 : _trancheEndOf[projectId][holder][low - 1];
    }

    /// @notice The number of tranches a holder has.
    /// @param projectId The ID of the sticky project to check the tranches of.
    /// @param holder The address to check the tranches of.
    /// @return count The number of active tranches.
    function trancheCountOf(uint256 projectId, address holder) external view override returns (uint256 count) {
        // Count only the active prefix; consumed entries can remain in storage for later reuse.
        return _trancheCountOf[projectId][holder];
    }

    /// @notice A holder's tranches, oldest first.
    /// @dev Copies every active tranche. Use the paginated overload for positions with many deposits or transfers.
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
        returns (StickyTranche[] memory tranches)
    {
        // Copy the complete active prefix in deposit order without exposing entries discarded by prior exits.
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
        returns (StickyTranche[] memory tranches)
    {
        // Limit each page's allocation and RPC response size even when a holder has many incoming tranches.
        if (count > _MAX_TRANCHE_PAGE) count = _MAX_TRANCHE_PAGE;

        // Clamp the requested page to active entries while preserving their oldest-first ordering.
        return _tranchesIn({projectId: projectId, holder: holder, start: start, count: count});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The duration of a holder's active streak, in seconds.
    /// @param projectId The ID of the sticky project to check the streak of.
    /// @param holder The address to check the streak of.
    /// @return duration The number of seconds since the holder's staked balance last became non-zero, or 0 if nothing
    /// is staked.
    function currentStreakOf(uint256 projectId, address holder) public view override returns (uint256 duration) {
        // The saved start tracks uninterrupted positive ownership, independently of individual tranche ages.
        uint256 streakStart = streakStartOf[projectId][holder];

        // An empty position has no active duration; otherwise measure time since its balance first became positive.
        return streakStart == 0 ? 0 : block.timestamp - streakStart;
    }

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return supported Whether the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool supported) {
        // Advertise the Sticky and core hook entry points while retaining the inherited ERC165 support.
        return interfaceId == type(IStickyHook).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBPayHook).interfaceId || interfaceId == type(IJBCashOutHook).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Records tokens joining a holder's position, merging them into the newest tranche when it was created
    /// in the current epoch and appending a fresh tranche otherwise, and starts their streak if their staked balance
    /// was zero.
    /// @dev Merging keeps every active tranche in a distinct epoch, which bounds the bucket updates an exit makes to
    /// the number of epochs the holder staked in. A merged tranche takes the current timestamp, so its recorded age
    /// never overstates the age of the tokens that joined last.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder the tokens joined.
    /// @param count The number of tokens joining, as a fixed point number with 18 decimals.
    /// @return stakedBalance The holder's staked balance after the addition.
    function _addTo(uint256 projectId, address holder, uint256 count) internal returns (uint256 stakedBalance) {
        // Extend the existing position so a top-up preserves earlier tranches and any uninterrupted streak.
        stakedBalance = stakedBalanceOf[projectId][holder];

        // Empty additions must not create zero-sized tranches or start an ownership clock.
        if (count == 0) return stakedBalance;

        // Append to the active prefix, reusing discarded storage while preserving cumulative-balance ordering.
        uint256 index = _trancheCountOf[projectId][holder];

        // The resulting total is both the holder's balance and the newest tranche's cumulative endpoint.
        stakedBalance += count;

        // Bucket the addition by the epoch it joins in, so aged stake can be totaled without checkpoints.
        uint256 epoch = block.timestamp / EPOCH_DURATION;

        // Tokens joining in the epoch of the newest tranche share its age, so they extend it instead of a new entry.
        // Whole-epoch comparison; a validator moving the timestamp within a block cannot change entitlements.
        // forge-lint: disable-next-item(block-timestamp)
        // slither-disable-next-line incorrect-equality
        if (index != 0 && uint256(_tranchesOf[projectId][holder][index - 1].timestamp) / EPOCH_DURATION == epoch) {
            // Edit the newest tranche in place; its index becomes the cumulative endpoint written below.
            index -= 1;

            // Read the tranche once for both the amount extension and the timestamp refresh.
            StickyTranche storage tranche = _tranchesOf[projectId][holder][index];

            // Grow the tranche by the joining tokens; the checked cast prevents truncating the amount.
            tranche.amount = SafeCast.toUint208(uint256(tranche.amount) + count);

            // Move the tranche's age to the latest joining, so it never overstates how long its tokens have stuck.
            tranche.timestamp = SafeCast.toUint48(block.timestamp);
        } else {
            // Give incoming shares their own deposit age; checked casts prevent truncating the amount or timestamp.
            _tranchesOf[projectId][holder][index] =
                StickyTranche({amount: SafeCast.toUint208(count), timestamp: SafeCast.toUint48(block.timestamp)});

            // Include the appended tranche in the logical stack without reactivating any later discarded storage.
            _trancheCountOf[projectId][holder] = index + 1;
        }

        // Store the cumulative endpoint so a later newest-first exit can locate its retained tail by binary search.
        _trancheEndOf[projectId][holder][index] = stakedBalance;

        // Credit the epoch's bucket; the matching exit debits the same epoch, so buckets always sum to balances.
        netStakedIn[projectId][epoch] += count;

        // Keep aggregate position accounting aligned with the sum of the holder's active tranches.
        stakedBalanceOf[projectId][holder] = stakedBalance;

        // Only the first positive addition starts a streak; top-ups must not reset uninterrupted ownership.
        if (streakStartOf[projectId][holder] == 0) {
            // Anchor the streak to the moment this holder first enters their current nonzero position.
            streakStartOf[projectId][holder] = block.timestamp;

            // Publish the ownership clock's start separately from the caller's stake event.
            // This helper makes no external calls; its callers only read external state under STATICCALL.
            // forge-lint: disable-next-line(reentrancy-events)
            emit StreakStarted({projectId: projectId, holder: holder, caller: msg.sender});
        }
    }

    /// @notice Consumes a holder's newest tranches to cover tokens leaving their position, splitting the last tranche
    /// in place (keeping its original timestamp), debiting each consumed tranche's original epoch bucket, and ending
    /// the holder's streak if their balance reached zero.
    /// @dev The retained tail is found by binary search. Each fully consumed tranche then debits its own epoch's
    /// bucket, so an exit's cost grows with the number of distinct epochs it consumes, not with the number of
    /// deposits made in them.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder the tokens left.
    /// @param count The number of tokens leaving, as a fixed point number with 18 decimals.
    /// @return stakedBalance The holder's staked balance after the consumption.
    function _consumeFrom(uint256 projectId, address holder, uint256 count) internal returns (uint256 stakedBalance) {
        // Use the aggregate tracked balance to bound the exit before touching individual tranche records.
        stakedBalance = stakedBalanceOf[projectId][holder];

        // A zero exit leaves tranche ages and the holder's active streak intact.
        if (count == 0) return stakedBalance;

        // Token movement reports cannot remove more shares than this hook has recorded for the holder.
        if (count > stakedBalance) {
            // Fail with the accounting mismatch instead of underflowing or consuming another position's shares.
            revert StickyHook_InsufficientStakedBalance({
                projectId: projectId, holder: holder, balance: stakedBalance, count: count
            });
        }

        // The balance left after this exit determines the oldest prefix of tranches that must remain active.
        stakedBalance -= count;

        // Keep the aggregate synchronized with the retained prefix before adjusting its tranche boundary.
        stakedBalanceOf[projectId][holder] = stakedBalance;

        // Every tranche at or above this index leaves the position entirely and must debit its epoch bucket.
        uint256 activeCount = _trancheCountOf[projectId][holder];

        // The oldest tranche that leaves entirely; a full exit removes them all, starting at the oldest.
        uint256 removedFrom;

        // A full exit needs no search because every tranche can be removed from the logical stack at once.
        if (stakedBalance == 0) {
            // Discard the entire logical stack; the bucket loop below still visits each removed tranche's epoch.
            _trancheCountOf[projectId][holder] = 0;
        } else {
            // Start at the oldest tranche so the search includes every possible retained prefix.
            uint256 low;

            // A positive retained balance guarantees an active tranche and bounds the search at its newest entry.
            uint256 high = activeCount - 1;

            // Find the first cumulative tranche balance that contains the retained balance. Each iteration halves
            // the range, so even a dust-filled position can exit without scanning or deleting its newest tranches.
            // Solidity initializes low to zero, including the oldest active tranche in the search.
            // forge-lint: disable-next-line(uninitialized-local)
            while (low < high) {
                // Split the remaining range without adding its two indices, which could overflow.
                uint256 middle = low + (high - low) / 2;

                // An endpoint below the retained balance means the boundary lies strictly after this tranche.
                if (_trancheEndOf[projectId][holder][middle] < stakedBalance) low = middle + 1;
                // Otherwise this tranche can contain the boundary, so keep it while dropping later candidates.
                else high = middle;
            }

            // Edit the last retained tranche in place so its surviving shares keep their original deposit timestamp.
            StickyTranche storage tranche = _tranchesOf[projectId][holder][low];

            // Only the part above the retained balance leaves; an exact endpoint leaves this tranche intact.
            uint256 trimmed = _trancheEndOf[projectId][holder][low] - stakedBalance;

            // Remove the trimmed part while keeping the tranche's original timestamp.
            tranche.amount = SafeCast.toUint208(tranche.amount - trimmed);

            // Debit the trimmed part from the epoch this tranche joined in, not the epoch it leaves in.
            netStakedIn[projectId][uint256(tranche.timestamp) / EPOCH_DURATION] -= trimmed;

            // Align the retained tail's cumulative endpoint with the holder's reduced aggregate balance.
            _trancheEndOf[projectId][holder][low] = stakedBalance;

            // Discard all newer tranches logically; only their epoch buckets still need debiting below.
            _trancheCountOf[projectId][holder] = low + 1;

            // Every tranche after the retained tail leaves entirely.
            removedFrom = low + 1;
        }

        // Debit each fully removed tranche from its original epoch bucket. Merging keeps active tranches in distinct
        // epochs, so this loop runs once per epoch the exit consumes rather than once per deposit.
        // Solidity initializes `removedFrom` to zero, which a full exit relies on to visit every active tranche.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i = removedFrom; i < activeCount; i++) {
            // Read the removed tranche once for both its epoch and its amount.
            StickyTranche storage removed = _tranchesOf[projectId][holder][i];

            // Return the tranche's full amount to the bucket it was credited to when it joined.
            // Each consumed epoch needs its own bucket debit; the exiting holder pays for the epochs they staked in.
            // forge-lint: disable-next-line(costly-loop)
            netStakedIn[projectId][uint256(removed.timestamp) / EPOCH_DURATION] -= removed.amount;
        }

        // Partial exits preserve uninterrupted positive ownership; only a complete exit ends the streak.
        if (stakedBalance == 0) {
            // Read the active start before clearing it so the completed duration can be preserved.
            uint256 streakStart = streakStartOf[projectId][holder];

            // Only an active streak has a duration to record or an ending event to publish.
            if (streakStart != 0) {
                // Measure the ownership interval through this exit, independently of which tranches it consumed.
                uint256 duration = block.timestamp - streakStart;

                // Preserve the maximum completed duration without replacing a longer historical streak.
                // Streak durations are informational and never determine balances or reward entitlements.
                // forge-lint: disable-next-line(block-timestamp)
                if (duration > _longestCompletedStreakOf[projectId][holder]) {
                    // Save the record so it remains queryable while the holder is unstaked or starts over.
                    _longestCompletedStreakOf[projectId][holder] = duration;
                }

                // Mark ownership as interrupted so a later positive addition must start a fresh streak.
                streakStartOf[projectId][holder] = 0;

                // Publish the completed duration for histories that track uninterrupted ownership over time.
                emit StreakEnded({projectId: projectId, holder: holder, duration: duration, caller: msg.sender});
            }
        }
    }

    /// @notice Writes a project's count of payments whose minted shares are not yet recorded.
    /// @param projectId The ID of the sticky project.
    /// @param count The number of payments in flight.
    function _setPayingCountOf(uint256 projectId, uint256 count) internal {
        // Locate the project's keyed transient counter.
        bytes32 slot = _payingSlotOf(projectId);

        // Transient storage resets at the end of the transaction, so a reverted payment leaves nothing behind.
        // Solidity has no keyed transient variables, so the write goes straight to the slot.
        // forge-lint: disable-next-item(inline-assembly)
        assembly ("memory-safe") {
            tstore(slot, count)
        }
    }

    /// @notice Removes one payment from a project's count of unrecorded mints once its tranche is recorded.
    /// @param projectId The ID of the sticky project.
    function _settlePayingFor(uint256 projectId) internal {
        // Read how many payments to the project still have unrecorded mints in this transaction.
        uint256 paying = _payingCountOf(projectId);

        // Nothing is cleared when no mint was counted in this transaction, so a callback on its own cannot underflow.
        if (paying != 0) _setPayingCountOf({projectId: projectId, count: paying - 1});
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice The transient slot counting a project's payments whose minted shares are not yet recorded.
    /// @param projectId The ID of the sticky project.
    /// @return slot The project's keyed transient slot.
    function _payingSlotOf(uint256 projectId) internal pure returns (bytes32 slot) {
        // Fixed-width encoding under a contract-specific seed keeps every project's slot distinct. The hash runs once
        // per mint and once per callback, so an assembly hash would save little for the readability it costs.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(_PAYING_SLOT_SEED, projectId));
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Reads pre-payment or post-payment backing in the project's single accepted token.
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
        // The terminal accepts a token list, while each Sticky project prices shares against one underlying token.
        address[] memory tokens = new address[](1);

        // Restrict the surplus query to the accepted underlying so unrelated terminal assets cannot affect pricing.
        tokens[0] = token;

        // Express gross backing in the payment's accounting units; callers separately exclude orphaned funds.
        return terminal.currentSurplusOf({projectId: projectId, tokens: tokens, decimals: decimals, currency: currency});
    }

    /// @notice Reads a project's count of payments whose minted shares are not yet recorded.
    /// @param projectId The ID of the sticky project.
    /// @return count The number of payments in flight.
    function _payingCountOf(uint256 projectId) internal view returns (uint256 count) {
        // Locate the project's keyed transient counter.
        bytes32 slot = _payingSlotOf(projectId);

        // The slot is keyed by project, so payments to other projects never appear in this count.
        // Solidity has no keyed transient variables, so the read comes straight from the slot.
        // forge-lint: disable-next-item(inline-assembly)
        assembly ("memory-safe") {
            count := tload(slot)
        }
    }

    /// @notice Copies a bounded range of active tranches without exposing logically discarded entries.
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
        returns (StickyTranche[] memory tranches)
    {
        // Bound the copy to active entries so logically discarded tranches are never exposed.
        uint256 activeCount = _trancheCountOf[projectId][holder];

        // An out-of-range page has no active entries, including when the holder has exited every tranche.
        if (start >= activeCount) return new StickyTranche[](0);

        // Subtraction is safe after the bounds check and avoids overflowing a caller-supplied start plus count.
        uint256 available = activeCount - start;

        // Shorten the final page so it cannot include inactive storage awaiting reuse.
        if (count > available) count = available;

        // Allocate only the entries this page can actually return.
        tranches = new StickyTranche[](count);

        // Solidity initializes the index to zero, filling the result from its first element.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < count; i++) {
            // Preserve storage order so the returned page runs from older deposits toward newer ones.
            tranches[i] = _tranchesOf[projectId][holder][start + i];
        }
    }
}
