// SPDX-License-Identifier: MIT
// Runtime code pins the compiler; shared interfaces and value types retain V6's compatible ^0.8.0 pragma.
// forge-lint: disable-next-line(pragma-inconsistent)
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AutoStickStatus} from "./enums/AutoStickStatus.sol";

import {IStickyAutoStick} from "./interfaces/IStickyAutoStick.sol";
import {IStickyDeployer} from "./interfaces/IStickyDeployer.sol";
import {IStickyDistributor} from "./interfaces/IStickyDistributor.sol";
import {IStickyHook} from "./interfaces/IStickyHook.sol";

import {AutoStickConfig} from "./structs/AutoStickConfig.sol";

/// @notice Auto-compounds vested underlying-token rewards back into the same holder's sticky position: collects a
/// holder's vested rewards from the distributor's chosen reward groups, pulls exactly what was delivered, and pays it
/// into the same sticky project with the holder as beneficiary. Opt-in per holder per project, permissionless to
/// execute, and immutable — keepers never hold funds and cannot choose the project, token, amount, or beneficiary.
/// @dev Best effort: rewards collected to the holder before execution must be staked separately. Callers choose the
/// reward groups to collect from; the holder's minimum applies to the combined amount.
contract StickyAutoStick is ERC2771Context, ReentrancyGuard, IStickyAutoStick {
    // A library that safely approves and transfers the project's underlying token.
    using SafeERC20 for IERC20Metadata;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the collectable or delivered reward is below the required minimum, so a dust reward cannot
    /// create another tranche.
    /// @param collectable The available reward amount in underlying-token decimals.
    /// @param minimum The required minimum reward amount in underlying-token decimals.
    error StickyAutoStick_BelowMinimum(uint256 collectable, uint256 minimum);

    /// @notice Thrown when the holder's previous automated compound is more recent than their cooldown allows.
    /// @param availableAt The earliest timestamp another compound is allowed.
    error StickyAutoStick_Cooldown(uint256 availableAt);

    /// @notice Thrown when a keeper acts for a holder who has not enabled auto-stick for this project.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose configuration is disabled.
    error StickyAutoStick_Disabled(uint256 projectId, address holder);

    /// @notice Thrown when no reward groups are requested, since a compound with nothing to collect cannot stake.
    /// @param count The number of reward groups requested.
    error StickyAutoStick_EmptyGroupIds(uint256 count);

    /// @notice Thrown when the requested reward groups are not strictly ascending, so a repeated group cannot count
    /// its collectable amount twice toward the holder's minimum.
    /// @param previous The group ID before the offending entry.
    /// @param next The offending group ID.
    error StickyAutoStick_GroupIdsNotAscending(uint256 previous, uint256 next);

    /// @notice Thrown when the holder's allowance cannot cover the collectable reward, which is collected to their
    /// wallet before being staked.
    /// @param allowance The current allowance to this adapter.
    /// @param needed The underlying-token allowance required for this reward.
    error StickyAutoStick_InsufficientAllowance(uint256 allowance, uint256 needed);

    /// @notice Thrown when the terminal returns fewer shares than its preview quoted for the delivered reward.
    /// @param received The Sticky token count returned by the terminal.
    /// @param minimum The minimum Sticky token count required by the preview.
    error StickyAutoStick_InsufficientStickyTokens(uint256 received, uint256 minimum);

    /// @notice Thrown when the requested cooldown is outside the supported range, which bounds keeper-driven tranche
    /// growth.
    /// @param cooldown The requested cooldown in seconds.
    error StickyAutoStick_InvalidCooldown(uint256 cooldown);

    /// @notice Thrown when a status check names a reward group the distributor cannot fund or collect from, which
    /// execution would reject.
    /// @param groupId The rejected group ID.
    error StickyAutoStick_InvalidGroupId(uint256 groupId);

    /// @notice Thrown when the requested minimum reward amount is zero, so every saved configuration stays usable.
    /// @param minimumAmount The requested minimum in underlying-token decimals.
    error StickyAutoStick_InvalidMinimum(uint256 minimumAmount);

    /// @notice Thrown when the configured deployer cannot resolve a complete Sticky project to compound into.
    /// @param projectId The unrecognized project ID.
    error StickyAutoStick_InvalidProject(uint256 projectId);

    /// @notice Thrown when the holder has not trusted this adapter and the project has not approved it as a granter, so
    /// the hook would reject the stake.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose position the adapter cannot add to.
    error StickyAutoStick_NotTrusted(uint256 projectId, address holder);

    /// @notice Thrown when the adapter receives a different amount than it transferred from the holder, so the payment
    /// cannot consume unrelated adapter funds.
    /// @param expected The amount transferred from the holder.
    /// @param received The actual increase in the adapter's underlying-token balance.
    error StickyAutoStick_UnexpectedTokenDelta(uint256 expected, uint256 received);

    /// @notice Thrown when the terminal preview cannot issue any Sticky shares for the reward, which would otherwise be
    /// donated.
    /// @param projectId The ID of the sticky project.
    /// @param underlyingAmount The reward amount in underlying-token decimals.
    error StickyAutoStick_ZeroIssuance(uint256 projectId, uint256 underlyingAmount);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The longest cooldown a holder can configure.
    uint48 public constant MAX_COOLDOWN = 30 days;

    /// @notice The shortest cooldown a holder can configure, limiting keeper-driven tranche growth.
    uint48 public constant MIN_COOLDOWN = 1 days;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The deployer whose sticky projects this adapter serves.
    IStickyDeployer public immutable override DEPLOYER;

    /// @notice The distributor vested rewards are collected from.
    IStickyDistributor public immutable override DISTRIBUTOR;

    /// @notice The data hook that gates third-party stakes and tracks positions.
    IStickyHook public immutable override HOOK;

    /// @notice The terminal sticky projects are paid through.
    IJBTerminal public immutable override TERMINAL;

    /// @notice The contract managing token minting and burning for projects.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice A holder's auto-stick configuration for a sticky project.
    /// @custom:param projectId The ID of the sticky project.
    /// @custom:param holder The holder the configuration belongs to.
    mapping(uint256 projectId => mapping(address holder => AutoStickConfig)) public override configOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Creates an adapter bound to one Sticky deployer and rewards distributor.
    /// @param deployer The deployer whose sticky projects this adapter serves.
    /// @param distributor The distributor vested rewards are collected from.
    constructor(
        IStickyDeployer deployer,
        IStickyDistributor distributor
    )
        // Trust the deployer's forwarder, so a sponsor can relay a holder's configuration and compounds.
        ERC2771Context(ERC2771Context(address(deployer)).trustedForwarder())
    {
        // Restrict project resolution to the Sticky deployment this adapter serves.
        DEPLOYER = deployer;

        // Bind reward reads and collection to the same distributor for the adapter's lifetime.
        DISTRIBUTOR = distributor;

        // Use the deployer's hook so permission checks match the hook that records each stake.
        HOOK = deployer.HOOK();

        // Resolve Sticky shares through the same token registry the deployer uses.
        TOKENS = deployer.TOKENS();

        // Route every compound through the terminal configured by the Sticky deployer.
        TERMINAL = deployer.TERMINAL();
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Starts vesting a holder's eligible reward rounds for the project's underlying token.
    /// @dev Permissionless, but only for holders with auto-stick enabled. Moves no reward tokens.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose rewards should begin vesting.
    /// @param groupIds The reward groups to begin vesting, strictly ascending.
    function beginVestingFor(uint256 projectId, address holder, uint256[] calldata groupIds) external override {
        // Vesting nothing would only spend the keeper's gas.
        _requireGroupIds(groupIds);

        // Derive the reward asset and share token from the configured deployment rather than caller input.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);

        // Both tokens must exist before the distributor can identify this Sticky project's rewards.
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert StickyAutoStick_InvalidProject(projectId);
        }

        // Only holders who opted in get keeper-driven vesting.
        if (!configOf[projectId][holder].enabled) {
            revert StickyAutoStick_Disabled({projectId: projectId, holder: holder});
        }

        // Start vesting only this holder's underlying-token rewards, using their address as the distributor token ID.
        uint256[] memory tokenIds = _singletonId(uint256(uint160(holder)));

        // Restrict every group's claim to the project's underlying token.
        IERC20[] memory tokens = _singletonToken(underlying);

        // Each group keeps its own claim cursor, so every requested group is materialized separately.
        // Solidity initializes the index to zero, covering every requested group.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < groupIds.length; i++) {
            // The caller pays for the group list it chose.
            // forge-lint: disable-next-item(calls-loop)
            DISTRIBUTOR.beginVesting({
                hook: address(stickyToken), groupId: groupIds[i], tokenIds: tokenIds, tokens: tokens
            });
        }

        // Let keepers track which holder's rewards were started and who initiated vesting.
        // The immutable distributor starts vesting without transferring tokens or changing adapter configuration.
        // forge-lint: disable-next-item(reentrancy-events)
        emit BeganAutoStickVesting({
            projectId: projectId, holder: holder, token: address(underlying), groupIds: groupIds, caller: _msgSender()
        });
    }

    /// @notice Collects a holder's vested underlying-token rewards and sticks them back into their position.
    /// @dev Permissionless, but entirely constrained by on-chain configuration: the caller cannot choose the token,
    /// amount, terminal, or beneficiary. The whole flow is atomic — if any step fails, the collection reverts too.
    /// @param projectId The ID of the sticky project to compound into.
    /// @param holder The holder whose rewards are compounded.
    /// @param groupIds The reward groups to collect from, strictly ascending.
    /// @return underlyingAmount The underlying-token amount collected and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the holder, as a fixed point number with 18 decimals.
    function compoundFor(
        uint256 projectId,
        address holder,
        uint256[] calldata groupIds
    )
        external
        override
        nonReentrant
        returns (uint256 underlyingAmount, uint256 stickyTokenCount)
    {
        // A compound with no groups to collect from has nothing to stake.
        _requireGroupIds(groupIds);

        // Derive the reward asset and share token so a keeper cannot substitute the assets being compounded.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);

        // Reject incomplete project registrations before reading consent or moving rewards.
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert StickyAutoStick_InvalidProject(projectId);
        }

        // Use one configuration snapshot for the holder's consent, cooldown, and minimum reward amount.
        AutoStickConfig memory config = configOf[projectId][holder];

        // Permissionless callers can compound only while the holder's explicit opt-in remains enabled.
        if (!config.enabled) revert StickyAutoStick_Disabled({projectId: projectId, holder: holder});

        // Calculate the next eligible time from the last successful compound and the holder's chosen interval.
        uint256 availableAt = uint256(config.lastCompoundedAt) + config.cooldown;

        // Enforce spacing between keeper-driven tranches; the first compound has no prior timestamp to wait for.
        // Cooldowns last at least a day; block-scale timestamp variance does not change holder entitlement.
        // forge-lint: disable-next-line(block-timestamp)
        if (config.lastCompoundedAt != 0 && block.timestamp < availableAt) {
            revert StickyAutoStick_Cooldown(availableAt);
        }

        // Atomically collect and reinvest rewards for the same holder, subject to their configured minimum.
        // Both asset-moving entry points are nonReentrant; other configuration writes are scoped to the caller.
        // slither-disable-next-line reentrancy-no-eth
        (underlyingAmount, stickyTokenCount) = _collectAndStick({
            projectId: projectId,
            holder: holder,
            groupIds: groupIds,
            underlying: underlying,
            stickyToken: stickyToken,
            minimumAmount: config.minimumAmount
        });

        // Start the cooldown only after a successful compound, so a failed attempt cannot delay the holder.
        // Casting to `uint48` is safe until the year 8_921_556.
        // forge-lint: disable-next-line(unsafe-typecast)
        configOf[projectId][holder].lastCompoundedAt = uint48(block.timestamp);
    }

    /// @notice Sets the caller's auto-stick configuration for a sticky project.
    /// @dev Only the holder can configure their own auto-stick. Disabling preserves `lastCompoundedAt`, so toggling
    /// the configuration cannot bypass the cooldown. The minimum and cooldown must be valid even when disabling.
    /// @param projectId The ID of the sticky project.
    /// @param enabled Whether auto-stick should be on.
    /// @param minimumAmount The smallest reward worth compounding, in the underlying token's decimals. Non-zero.
    /// @param cooldown The minimum number of seconds between compounds.
    function setConfigFor(uint256 projectId, bool enabled, uint128 minimumAmount, uint48 cooldown) external override {
        // Resolve both assets to establish that this configuration belongs to a supported Sticky project.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);

        // Avoid saving an opt-in that cannot be used to collect rewards or issue Sticky shares.
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert StickyAutoStick_InvalidProject(projectId);
        }

        // Require a positive reward threshold even while disabled, so every saved configuration is usable.
        if (minimumAmount == 0) revert StickyAutoStick_InvalidMinimum(minimumAmount);

        // Bound keeper-driven tranche frequency and keep the configured interval within the supported range.
        if (cooldown < MIN_COOLDOWN || cooldown > MAX_COOLDOWN) revert StickyAutoStick_InvalidCooldown(cooldown);

        // Scope changes to the caller's own position and retain the timestamp of their last successful compound.
        AutoStickConfig storage config = configOf[projectId][_msgSender()];

        // Let the holder decide how much reward justifies creating another tranche.
        config.minimumAmount = minimumAmount;

        // Apply the holder's chosen spacing to subsequent keeper-driven compounds.
        config.cooldown = cooldown;

        // Record or revoke consent without resetting the cooldown history.
        config.enabled = enabled;

        // Expose the complete configuration so holders and keepers can track changes in eligibility.
        emit SetAutoStick({
            projectId: projectId,
            holder: _msgSender(),
            enabled: enabled,
            minimumAmount: minimumAmount,
            cooldown: cooldown,
            caller: _msgSender()
        });
    }

    /// @notice Claims the caller's vested underlying-token rewards and sticks them, atomically, in one call.
    /// @dev The holder's own call is the consent: no configured minimum or cooldown applies. Issuance must be non-zero.
    /// The rewards route through the holder's wallet, so their allowance must cover the claim. The hook must accept
    /// this adapter as a payer through per-holder trust or launch-time project pre-approval.
    /// @param projectId The ID of the sticky project whose rewards are claimed and stuck.
    /// @param groupIds The reward groups to collect from, strictly ascending.
    /// @return underlyingAmount The underlying-token amount claimed and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the caller, as a fixed point number with 18 decimals.
    function stickRewardsFor(
        uint256 projectId,
        uint256[] calldata groupIds
    )
        external
        override
        nonReentrant
        returns (uint256 underlyingAmount, uint256 stickyTokenCount)
    {
        // A compound with no groups to collect from has nothing to stake.
        _requireGroupIds(groupIds);

        // Derive the assets from the deployment so a manual compound follows the same project routing as automation.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);

        // Reject projects without both a recognized reward asset and a registered share token.
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert StickyAutoStick_InvalidProject(projectId);
        }

        // The caller's consent allows any positive reward that issues shares, without an automation cooldown.
        (underlyingAmount, stickyTokenCount) = _collectAndStick({
            projectId: projectId,
            holder: _msgSender(),
            groupIds: groupIds,
            underlying: underlying,
            stickyToken: stickyToken,
            minimumAmount: 1
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The first condition preventing a holder's next automated compound, with reward and approval amounts.
    /// @dev A ready status is a preview; balances, approvals, backing and configuration can change before execution.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder to check.
    /// @param groupIds The reward groups to collect from, strictly ascending.
    /// @return status The current auto-stick status.
    /// @return collectableAmount The underlying-token amount currently collectable across the groups.
    /// @return allowance The holder's current underlying-token allowance to this adapter.
    /// @return nextCompoundAt The earliest timestamp the next compound can happen.
    function statusOf(
        uint256 projectId,
        address holder,
        uint256[] calldata groupIds
    )
        external
        view
        override
        returns (AutoStickStatus status, uint256 collectableAmount, uint256 allowance, uint256 nextCompoundAt)
    {
        // Mirror execution, which rejects an empty or unordered group list before reading anything.
        _requireGroupIds(groupIds);

        // The distributor rejects an invalid group on collection but reports nothing collectable for it, so a status
        // for one would otherwise read as ready.
        _requireValidGroupIds(groupIds);

        // Resolve the exact assets that execution would use before querying rewards or approvals.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);

        // An incomplete project cannot compound; return empty amounts without calling unresolved token contracts.
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            return (AutoStickStatus.InvalidProject, 0, 0, 0);
        }

        // Read one holder configuration snapshot to keep the reported threshold and cooldown consistent.
        AutoStickConfig memory config = configOf[projectId][holder];

        // Report vested rewards even when another condition blocks execution, so the holder can inspect the amount.
        collectableAmount = _collectableFor({
            stickyToken: stickyToken, tokenId: uint256(uint160(holder)), groupIds: groupIds, underlying: underlying
        });

        // Show the approval available for moving collected rewards from the holder's wallet into this adapter.
        allowance = underlying.allowance({owner: holder, spender: address(this)});

        // The cooldown only applies between compounds — a fresh config is immediately eligible.
        nextCompoundAt = config.lastCompoundedAt == 0 ? 0 : uint256(config.lastCompoundedAt) + config.cooldown;

        // Report one blocking condition at a time, beginning with the holder's consent.
        if (!config.enabled) {
            // A disabled opt-in prevents keeper execution regardless of reward size or approvals.
            status = AutoStickStatus.Disabled;
        } else if (
            // Cooldowns last at least a day; this view mirrors the same eligibility check used during execution.
            // forge-lint: disable-next-line(block-timestamp)
            block.timestamp < nextCompoundAt
        ) {
            // The holder is opted in, but another keeper-driven tranche must wait until the reported timestamp.
            status = AutoStickStatus.Cooldown;
        } else if (collectableAmount < config.minimumAmount) {
            // Waiting for more vested rewards is necessary to satisfy the holder's compounding threshold.
            status = AutoStickStatus.BelowMinimum;
        } else if (!_canStakeFor({projectId: projectId, holder: holder})) {
            // The hook must authorize this adapter as payer before it can add shares to the holder's position.
            status = AutoStickStatus.NotTrusted;
        } else if (allowance < collectableAmount) {
            // Collection pays the holder, so their approval must cover moving the reward back into the adapter.
            status = AutoStickStatus.InsufficientAllowance;
        } else if (
            // A zero quote means there are no shares to issue, so this guard prevents a donation.
            // slither-disable-next-line incorrect-equality
            _previewStickyTokenCountFor({
                    projectId: projectId, holder: holder, underlying: underlying, amount: collectableAmount
                }) == 0
        ) {
            // Surface issuance rounding that would turn the reward payment into a donation with no Sticky shares.
            status = AutoStickStatus.ZeroIssuance;
        } else {
            // All observable prerequisites pass, allowing keepers to attempt the atomic compound.
            status = AutoStickStatus.Ready;
        }
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Collects a holder's vested rewards to their wallet and pays the delivered amount into their sticky
    /// project for the same holder.
    /// @dev Both callers guard against reentrancy. The holder's balance increase determines the transfer amount;
    /// this requires an underlying token whose balances do not rebase during collection or payment.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose rewards are collected and stuck.
    /// @param groupIds The reward groups to collect from, strictly ascending.
    /// @param underlying The project's underlying token, already resolved and validated.
    /// @param stickyToken The project's sticky token, already resolved and validated.
    /// @param minimumAmount The smallest combined amount worth sticking.
    /// @return underlyingAmount The underlying-token amount collected and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the holder, as a fixed point number with 18 decimals.
    function _collectAndStick(
        uint256 projectId,
        address holder,
        uint256[] calldata groupIds,
        IERC20Metadata underlying,
        IJBToken stickyToken,
        uint256 minimumAmount
    )
        internal
        returns (uint256 underlyingAmount, uint256 stickyTokenCount)
    {
        // The hook must accept this adapter as the payer: either the holder trusted it, or the project's creator
        // pre-approved it as a granter at launch.
        if (!_canStakeFor({projectId: projectId, holder: holder})) {
            revert StickyAutoStick_NotTrusted({projectId: projectId, holder: holder});
        }

        // Sticky uses the holder's address as its distributor token ID, binding rewards to the same beneficiary.
        uint256 tokenId = uint256(uint160(holder));

        // Quote only this project's vested underlying-token rewards, across the requested groups, for the minimum and
        // approval checks.
        uint256 collectable =
            _collectableFor({stickyToken: stickyToken, tokenId: tokenId, groupIds: groupIds, underlying: underlying});

        // Avoid changing distributor state for a reward smaller than the amount this call permits.
        if (collectable < minimumAmount) {
            revert StickyAutoStick_BelowMinimum({collectable: collectable, minimum: minimumAmount});
        }

        // Early diagnostic; the amount actually pulled is still derived from the holder's balance delta below.
        uint256 allowance = underlying.allowance({owner: holder, spender: address(this)});

        // Rewards first reach the holder's wallet, so collection is useful only if the adapter can pull them back.
        if (allowance < collectable) {
            revert StickyAutoStick_InsufficientAllowance({allowance: allowance, needed: collectable});
        }

        // Reject rewards that would issue no shares before collection changes the distributor or holder balances.
        if (
            // Any positive issuance is accepted here; zero is the exact value that must be rejected.
            // slither-disable-next-line incorrect-equality
            _previewStickyTokenCountFor({
                    projectId: projectId, holder: holder, underlying: underlying, amount: collectable
                }) == 0
        ) {
            revert StickyAutoStick_ZeroIssuance({projectId: projectId, underlyingAmount: collectable});
        }

        // Snapshot the holder's balance so pre-existing wallet funds cannot be mistaken for newly collected rewards.
        uint256 holderBalanceBefore = underlying.balanceOf(holder);

        // Collect only this holder's position, using their address as the distributor token ID.
        uint256[] memory tokenIds = _singletonId(tokenId);

        // Restrict every group's collection to the project's underlying token.
        IERC20[] memory tokens = _singletonToken(underlying);

        // Collect every requested group to the token ID's canonical beneficiary, preserving the distributor's
        // holder-bound reward routing. Both callers hold the reentrancy guard; only the holder can change their own
        // configuration.
        // Solidity initializes the index to zero, covering every requested group.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < groupIds.length; i++) {
            // Each group vests separately, so each is collected separately; the caller pays for the list it chose.
            // forge-lint: disable-next-item(reentrancy-no-eth,calls-loop)
            DISTRIBUTOR.collectVestedRewards({
                hook: address(stickyToken),
                groupId: groupIds[i],
                tokenIds: tokenIds,
                tokens: tokens,
                beneficiary: holder
            });
        }

        // Reinvest only the actual balance increase across every collection, accounting for any difference from the
        // distributor's quote.
        underlyingAmount = underlying.balanceOf(holder) - holderBalanceBefore;

        // Enforce the minimum on delivered rewards as well, so an optimistic quote cannot bypass the threshold.
        if (underlyingAmount < minimumAmount) {
            revert StickyAutoStick_BelowMinimum({collectable: underlyingAmount, minimum: minimumAmount});
        }

        // Reprice the amount actually delivered, using the same payer, beneficiary, and metadata as the payment.
        // The terminal preview incorporates current backing and all issuance rounding; a 1:1 normalization does not.
        uint256 expectedStickyTokenCount = _previewStickyTokenCountFor({
            projectId: projectId, holder: holder, underlying: underlying, amount: underlyingAmount
        });
        // Zero shares must be rejected regardless of the positive underlying-token amount.
        // slither-disable-next-line incorrect-equality
        if (expectedStickyTokenCount == 0) {
            revert StickyAutoStick_ZeroIssuance({projectId: projectId, underlyingAmount: underlyingAmount});
        }

        // Exclude any tokens already held by the adapter when measuring what the holder's transfer delivers.
        uint256 adapterBalanceBefore = underlying.balanceOf(address(this));

        // The holder authorized this path; only newly collected rewards return to their own project's position.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        underlying.safeTransferFrom({from: holder, to: address(this), value: underlyingAmount});

        // Measure the transfer itself instead of assuming the token delivered the requested amount.
        uint256 received = underlying.balanceOf(address(this)) - adapterBalanceBefore;

        // Reject transfer taxes or other balance changes that would make the payment consume unrelated adapter funds.
        if (received != underlyingAmount) {
            revert StickyAutoStick_UnexpectedTokenDelta({expected: underlyingAmount, received: received});
        }

        // Authorize the terminal to pull only this compound's amount, including for tokens requiring approval resets.
        underlying.forceApprove({spender: address(TERMINAL), value: underlyingAmount});

        // Issue shares to the same holder and require at least the terminal's quote for the delivered rewards.
        // Both callers hold the reentrancy guard across payment and any later configuration updates.
        // forge-lint: disable-next-item(reentrancy-no-eth)
        stickyTokenCount = TERMINAL.pay({
            projectId: projectId,
            token: address(underlying),
            amount: underlyingAmount,
            beneficiary: holder,
            minReturnedTokens: expectedStickyTokenCount,
            memo: "Auto-stick rewards",
            metadata: bytes("")
        });

        // Check the reported issuance as well, so a terminal result below the quote rolls back the whole compound.
        if (stickyTokenCount < expectedStickyTokenCount) {
            revert StickyAutoStick_InsufficientStickyTokens({
                received: stickyTokenCount, minimum: expectedStickyTokenCount
            });
        }

        // Leave no residual approval that could expose unrelated tokens sent to the adapter after this payment.
        underlying.forceApprove({spender: address(TERMINAL), value: 0});

        // Record the reward reinvested and shares issued so the holder and keeper can reconcile the compound.
        // Both callers hold the reentrancy guard, so another compound cannot interleave this completion event.
        // forge-lint: disable-next-item(reentrancy-events)
        emit AutoStuck({
            projectId: projectId,
            holder: holder,
            token: address(underlying),
            groupIds: groupIds,
            underlyingAmount: underlyingAmount,
            stickyTokenCount: stickyTokenCount,
            caller: _msgSender()
        });
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Reverts when no reward groups are requested or the groups are not strictly ascending.
    /// @param groupIds The reward groups requested.
    function _requireGroupIds(uint256[] calldata groupIds) internal pure {
        // Every entry point needs at least one group to read or collect from.
        if (groupIds.length == 0) revert StickyAutoStick_EmptyGroupIds(groupIds.length);

        // A repeated group would count its collectable amount once per entry toward the holder's minimum.
        for (uint256 i = 1; i < groupIds.length; i++) {
            // Fail on the first entry out of order; the rest are never read.
            // forge-lint: disable-next-item(require-revert-in-loop)
            if (groupIds[i] <= groupIds[i - 1]) {
                revert StickyAutoStick_GroupIdsNotAscending({previous: groupIds[i - 1], next: groupIds[i]});
            }
        }
    }

    /// @notice Wraps a token ID in a one-element array for distributor calls.
    /// @param tokenId The token ID to wrap.
    /// @return tokenIds The singleton array.
    function _singletonId(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        // Adapt one holder's reward identity to the distributor's batch interface.
        tokenIds = new uint256[](1);

        // Limit vesting or collection to the intended holder instead of including other positions.
        tokenIds[0] = tokenId;
    }

    /// @notice Wraps a token in a one-element array for distributor calls.
    /// @param token The token to wrap.
    /// @return tokens The singleton array.
    function _singletonToken(IERC20Metadata token) internal pure returns (IERC20[] memory tokens) {
        // Adapt the project's single reward asset to the distributor's batch interface.
        tokens = new IERC20[](1);

        // Restrict the request to underlying-token rewards, leaving other distributed assets untouched.
        tokens[0] = token;
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Whether the hook will accept this adapter staking for a holder: per-holder trust, or launch-time
    /// project-granter status chosen by the project's creator.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder being staked for.
    /// @return canStake Whether this adapter can add to the holder's position.
    function _canStakeFor(uint256 projectId, address holder) internal view returns (bool canStake) {
        // Mirror the hook's two authorization paths so holder trust or project-wide granter status permits payment.
        return HOOK.isTrustedSenderOf({projectId: projectId, holder: holder, sender: address(this)})
            || HOOK.isGranterOf({projectId: projectId, granter: address(this)});
    }

    /// @notice The vested underlying-token rewards a holder can collect right now across the requested groups.
    /// @param stickyToken The project's sticky token, used as the distributor's reward hook.
    /// @param tokenId The holder's distributor token ID.
    /// @param groupIds The reward groups to sum.
    /// @param underlying The project's underlying token.
    /// @return collectable The combined collectable amount, in the underlying token's decimals.
    function _collectableFor(
        IJBToken stickyToken,
        uint256 tokenId,
        uint256[] calldata groupIds,
        IERC20Metadata underlying
    )
        internal
        view
        returns (uint256 collectable)
    {
        // Solidity initializes the index to zero, covering every requested group.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < groupIds.length; i++) {
            // Each group vests separately, so the quote is the sum of every requested group's unlocked amount.
            // The caller pays for the group list it chose.
            // forge-lint: disable-next-item(calls-loop)
            collectable += DISTRIBUTOR.collectableFor({
                hook: address(stickyToken), groupId: groupIds[i], tokenId: tokenId, token: underlying
            });
        }
    }

    /// @notice Previews the exact share issuance for this adapter's payment to a holder.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder who receives the issued shares.
    /// @param underlying The project's underlying token.
    /// @param amount The underlying-token amount to preview, in the token's decimals.
    /// @return stickyTokenCount The number of Sticky token atoms the terminal would issue to the holder.
    function _previewStickyTokenCountFor(
        uint256 projectId,
        address holder,
        IERC20Metadata underlying,
        uint256 amount
    )
        internal
        view
        returns (uint256 stickyTokenCount)
    {
        // Only the beneficiary's issued count sets our minimum; the terminal applies the ruleset and hook outputs.
        // forge-lint: disable-next-item(unused-return)
        // slither-disable-next-line unused-return
        (, stickyTokenCount,,) = TERMINAL.previewPayFor({
            projectId: projectId, token: address(underlying), amount: amount, beneficiary: holder, metadata: bytes("")
        });
    }

    /// @notice Reverts when any requested reward group is one the distributor cannot fund or collect from.
    /// @param groupIds The reward groups requested.
    function _requireValidGroupIds(uint256[] calldata groupIds) internal view {
        // Solidity initializes the index to zero, covering every requested group.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < groupIds.length; i++) {
            // The caller pays for the group list it chose; fail on the first group the distributor rejects.
            // forge-lint: disable-next-item(calls-loop,require-revert-in-loop)
            if (!DISTRIBUTOR.isValidGroupId(groupIds[i])) revert StickyAutoStick_InvalidGroupId(groupIds[i]);
        }
    }

    /// @notice Resolves a project's underlying and sticky tokens through the configured deployer.
    /// @param projectId The ID of the sticky project.
    /// @return underlying The token the project accepts for staking, or zero if not a sticky project.
    /// @return stickyToken The project's sticky token, or zero if none is set.
    function _resolveProject(uint256 projectId)
        internal
        view
        returns (IERC20Metadata underlying, IJBToken stickyToken)
    {
        // Let the deployer's registration determine whether the project belongs to Sticky and which asset it accepts.
        underlying = DEPLOYER.stakedTokenOf(projectId);

        // Pair the registered asset with the live project share token used as the distributor's reward hook.
        stickyToken = TOKENS.tokenOf(projectId);
    }
}
