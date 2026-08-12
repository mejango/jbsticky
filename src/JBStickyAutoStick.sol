// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBAutoStickStatus} from "./enums/JBAutoStickStatus.sol";
import {IJBStickyAutoStick} from "./interfaces/IJBStickyAutoStick.sol";
import {IJBStickyDeployer} from "./interfaces/IJBStickyDeployer.sol";
import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {JBAutoStickConfig} from "./structs/JBAutoStickConfig.sol";

/// @notice Auto-compounds vested underlying-token rewards back into the same holder's sticky position: collects a
/// holder's vested rewards from the distributor, pulls exactly what was delivered, and pays it into the same sticky
/// project with the holder as beneficiary. Opt-in per holder per project, permissionless to execute, and immutable —
/// keepers never hold funds and cannot choose the project, token, amount, or beneficiary.
contract JBStickyAutoStick is ReentrancyGuard, IJBStickyAutoStick {
    using SafeERC20 for IERC20Metadata;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBStickyAutoStick_BelowMinimum(uint256 collectable, uint256 minimum);
    error JBStickyAutoStick_Cooldown(uint256 availableAt);
    error JBStickyAutoStick_Disabled(uint256 projectId, address holder);
    error JBStickyAutoStick_InsufficientAllowance(uint256 allowance, uint256 needed);
    error JBStickyAutoStick_InsufficientStickyTokens(uint256 received, uint256 minimum);
    error JBStickyAutoStick_InvalidCooldown(uint256 cooldown);
    error JBStickyAutoStick_InvalidMinimum(uint256 minimumAmount);
    error JBStickyAutoStick_InvalidProject(uint256 projectId);
    error JBStickyAutoStick_NotTrusted(uint256 projectId, address holder);
    error JBStickyAutoStick_UnexpectedTokenDelta(uint256 expected, uint256 received);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The shortest cooldown a holder can configure, preventing dust-tranche griefing.
    uint48 public constant MIN_COOLDOWN = 1 days;

    /// @notice The longest cooldown a holder can configure.
    uint48 public constant MAX_COOLDOWN = 30 days;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The deployer whose sticky projects this adapter serves.
    IJBStickyDeployer public immutable override DEPLOYER;

    /// @notice The distributor vested rewards are collected from.
    IJBDistributor public immutable override DISTRIBUTOR;

    /// @notice The data hook that gates third-party stakes and tracks positions.
    IJBStickyHook public immutable override HOOK;

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
    mapping(uint256 projectId => mapping(address holder => JBAutoStickConfig)) public override configOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param deployer The deployer whose sticky projects this adapter serves.
    /// @param distributor The distributor vested rewards are collected from.
    constructor(IJBStickyDeployer deployer, IJBDistributor distributor) {
        DEPLOYER = deployer;
        DISTRIBUTOR = distributor;
        HOOK = deployer.HOOK();
        TOKENS = deployer.TOKENS();
        TERMINAL = deployer.TERMINAL();
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Why a holder's next compound can or cannot happen right now, plus the reads the UI needs.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder to check.
    /// @return status The current auto-stick status.
    /// @return collectableAmount The underlying-token amount currently collectable from the distributor.
    /// @return allowance The holder's current underlying-token allowance to this adapter.
    /// @return nextCompoundAt The earliest timestamp the next compound can happen.
    function statusOf(
        uint256 projectId,
        address holder
    )
        external
        view
        override
        returns (JBAutoStickStatus status, uint256 collectableAmount, uint256 allowance, uint256 nextCompoundAt)
    {
        // An unknown project has nothing to report.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            return (JBAutoStickStatus.INVALID_PROJECT, 0, 0, 0);
        }

        // Populate the reads regardless of status so the UI can always render them.
        JBAutoStickConfig memory config = configOf[projectId][holder];
        collectableAmount = DISTRIBUTOR.collectableFor({
            hook: address(stickyToken), tokenId: uint256(uint160(holder)), token: underlying
        });
        allowance = underlying.allowance(holder, address(this));
        // The cooldown only applies between compounds — a fresh config is immediately eligible.
        nextCompoundAt = config.lastCompoundedAt == 0 ? 0 : uint256(config.lastCompoundedAt) + config.cooldown;

        if (!config.enabled) status = JBAutoStickStatus.DISABLED;
        else if (block.timestamp < nextCompoundAt) status = JBAutoStickStatus.COOLDOWN;
        else if (collectableAmount < config.minimumAmount) status = JBAutoStickStatus.BELOW_MINIMUM;
        else if (!_canStakeFor({projectId: projectId, holder: holder})) status = JBAutoStickStatus.NOT_TRUSTED;
        else if (allowance < collectableAmount) status = JBAutoStickStatus.INSUFFICIENT_ALLOWANCE;
        else status = JBAutoStickStatus.READY;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Starts vesting a holder's eligible reward rounds for the project's underlying token.
    /// @dev Permissionless, but only for holders with auto-stick enabled. Moves no reward tokens.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose rewards should begin vesting.
    function beginVestingFor(uint256 projectId, address holder) external override {
        // Resolve and validate the project through the deployer.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert JBStickyAutoStick_InvalidProject(projectId);
        }

        // Only holders who opted in get keeper-driven vesting.
        if (!configOf[projectId][holder].enabled) revert JBStickyAutoStick_Disabled(projectId, holder);

        DISTRIBUTOR.beginVesting({
            hook: address(stickyToken),
            tokenIds: _singletonId(uint256(uint160(holder))),
            tokens: _singletonToken(underlying)
        });

        emit BeganAutoStickVesting({
            projectId: projectId, holder: holder, token: address(underlying), caller: msg.sender
        });
    }

    /// @notice Collects a holder's vested underlying-token rewards and sticks them back into their position.
    /// @dev Permissionless, but entirely constrained by on-chain configuration: the caller cannot choose the token,
    /// amount, terminal, or beneficiary. The whole flow is atomic — if any step fails, the collection reverts too.
    /// @param projectId The ID of the sticky project to compound into.
    /// @param holder The holder whose rewards are compounded.
    /// @return underlyingAmount The underlying-token amount collected and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the holder, as a fixed point number with 18 decimals.
    function compoundFor(
        uint256 projectId,
        address holder
    )
        external
        override
        nonReentrant
        returns (uint256 underlyingAmount, uint256 stickyTokenCount)
    {
        // Resolve and validate the project through the deployer. Nothing is caller-provided.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert JBStickyAutoStick_InvalidProject(projectId);
        }

        // Validate the holder's configuration.
        JBAutoStickConfig memory config = configOf[projectId][holder];
        if (!config.enabled) revert JBStickyAutoStick_Disabled(projectId, holder);
        // The cooldown only applies between compounds — a fresh config is immediately eligible.
        uint256 availableAt = uint256(config.lastCompoundedAt) + config.cooldown;
        if (config.lastCompoundedAt != 0 && block.timestamp < availableAt) {
            revert JBStickyAutoStick_Cooldown(availableAt);
        }

        (underlyingAmount, stickyTokenCount) = _collectAndStick({
            projectId: projectId,
            holder: holder,
            underlying: underlying,
            stickyToken: stickyToken,
            minimumAmount: config.minimumAmount
        });

        // Casting to `uint48` is safe until the year 8_921_556.
        // forge-lint: disable-next-line(unsafe-typecast)
        configOf[projectId][holder].lastCompoundedAt = uint48(block.timestamp);
    }

    /// @notice Claims the caller's vested underlying-token rewards and sticks them, atomically, in one call.
    /// @dev The holder's own call is the consent: no configuration, minimum, or cooldown applies. The caller only
    /// needs an underlying-token allowance covering this claim (the rewards route through their wallet), and the
    /// hook must accept this adapter as a payer — per-holder trust or launch-time project pre-approval.
    /// @param projectId The ID of the sticky project whose rewards are claimed and stuck.
    /// @return underlyingAmount The underlying-token amount claimed and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the caller, as a fixed point number with 18 decimals.
    function stickRewardsFor(uint256 projectId)
        external
        override
        nonReentrant
        returns (uint256 underlyingAmount, uint256 stickyTokenCount)
    {
        // Resolve and validate the project through the deployer.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert JBStickyAutoStick_InvalidProject(projectId);
        }

        // Anything claimable is worth sticking when the holder themself asks.
        (underlyingAmount, stickyTokenCount) = _collectAndStick({
            projectId: projectId,
            holder: msg.sender,
            underlying: underlying,
            stickyToken: stickyToken,
            minimumAmount: 1
        });
    }

    /// @notice Sets the caller's auto-stick configuration for a sticky project.
    /// @dev Only the holder can configure their own auto-stick. Disabling keeps `lastCompoundedAt` for history.
    /// @param projectId The ID of the sticky project.
    /// @param enabled Whether auto-stick should be on.
    /// @param minimumAmount The smallest reward worth compounding, in the underlying token's decimals. Non-zero.
    /// @param cooldown The minimum number of seconds between compounds.
    function setConfigFor(
        uint256 projectId,
        bool enabled,
        uint128 minimumAmount,
        uint48 cooldown
    )
        external
        override
    {
        // Resolve and validate the project through the deployer.
        (IERC20Metadata underlying, IJBToken stickyToken) = _resolveProject(projectId);
        if (address(underlying) == address(0) || address(stickyToken) == address(0)) {
            revert JBStickyAutoStick_InvalidProject(projectId);
        }

        if (minimumAmount == 0) revert JBStickyAutoStick_InvalidMinimum(minimumAmount);
        if (cooldown < MIN_COOLDOWN || cooldown > MAX_COOLDOWN) revert JBStickyAutoStick_InvalidCooldown(cooldown);

        JBAutoStickConfig storage config = configOf[projectId][msg.sender];
        config.minimumAmount = minimumAmount;
        config.cooldown = cooldown;
        config.enabled = enabled;

        emit SetAutoStick({
            projectId: projectId,
            holder: msg.sender,
            enabled: enabled,
            minimumAmount: minimumAmount,
            cooldown: cooldown,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ------------------- internal transactions ------------------------- //
    //*********************************************************************//

    /// @notice The shared collect-pull-pay core: collects a holder's vested rewards to their wallet, pulls exactly
    /// the delivered amount, and pays it into the same sticky project for the same holder.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder whose rewards are collected and stuck.
    /// @param underlying The project's underlying token, already resolved and validated.
    /// @param stickyToken The project's sticky token, already resolved and validated.
    /// @param minimumAmount The smallest amount worth sticking.
    /// @return underlyingAmount The underlying-token amount collected and stuck.
    /// @return stickyTokenCount The sticky tokens minted to the holder, as a fixed point number with 18 decimals.
    function _collectAndStick(
        uint256 projectId,
        address holder,
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
            revert JBStickyAutoStick_NotTrusted(projectId, holder);
        }

        // Check the reward clears the minimum before any external state changes.
        uint256 tokenId = uint256(uint160(holder));
        uint256 collectable =
            DISTRIBUTOR.collectableFor({hook: address(stickyToken), tokenId: tokenId, token: underlying});
        if (collectable < minimumAmount) revert JBStickyAutoStick_BelowMinimum(collectable, minimumAmount);

        // Early diagnostic; the amount actually pulled is still derived from the holder's balance delta below.
        uint256 allowance = underlying.allowance(holder, address(this));
        if (allowance < collectable) revert JBStickyAutoStick_InsufficientAllowance(allowance, collectable);

        // Collect to the token ID's canonical beneficiary — the holder — never to this adapter.
        uint256 holderBalanceBefore = underlying.balanceOf(holder);
        DISTRIBUTOR.collectVestedRewards({
            hook: address(stickyToken),
            tokenIds: _singletonId(tokenId),
            tokens: _singletonToken(underlying),
            beneficiary: holder
        });
        underlyingAmount = underlying.balanceOf(holder) - holderBalanceBefore;
        if (underlyingAmount < minimumAmount) {
            revert JBStickyAutoStick_BelowMinimum(underlyingAmount, minimumAmount);
        }

        // Pull exactly the newly collected amount, rejecting fee-on-transfer and rebasing behavior outright.
        uint256 adapterBalanceBefore = underlying.balanceOf(address(this));
        underlying.safeTransferFrom({from: holder, to: address(this), value: underlyingAmount});
        uint256 received = underlying.balanceOf(address(this)) - adapterBalanceBefore;
        if (received != underlyingAmount) {
            revert JBStickyAutoStick_UnexpectedTokenDelta({expected: underlyingAmount, received: received});
        }

        // Sticky projects mint 1:1 at 18 decimals, so the exact expected mint is a decimal adjustment.
        uint256 expectedStickyTokenCount = JBFixedPointNumber.adjustDecimals({
            value: underlyingAmount, decimals: underlying.decimals(), targetDecimals: 18
        });

        // Pay the sticky project with this adapter as payer and the holder as beneficiary.
        underlying.forceApprove({spender: address(TERMINAL), value: underlyingAmount});
        stickyTokenCount = TERMINAL.pay({
            projectId: projectId,
            token: address(underlying),
            amount: underlyingAmount,
            beneficiary: holder,
            minReturnedTokens: expectedStickyTokenCount,
            memo: "Auto-stick rewards",
            metadata: bytes("")
        });
        if (stickyTokenCount < expectedStickyTokenCount) {
            revert JBStickyAutoStick_InsufficientStickyTokens(stickyTokenCount, expectedStickyTokenCount);
        }

        // Leave no allowance or custody behind.
        underlying.forceApprove({spender: address(TERMINAL), value: 0});

        emit AutoStuck({
            projectId: projectId,
            holder: holder,
            token: address(underlying),
            underlyingAmount: underlyingAmount,
            stickyTokenCount: stickyTokenCount,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Whether the hook will accept this adapter staking for a holder: per-holder trust, or launch-time
    /// project-granter status chosen by the project's creator.
    /// @param projectId The ID of the sticky project.
    /// @param holder The holder being staked for.
    function _canStakeFor(uint256 projectId, address holder) internal view returns (bool) {
        return HOOK.isTrustedSenderOf({projectId: projectId, holder: holder, sender: address(this)})
            || HOOK.isGranterOf({projectId: projectId, granter: address(this)});
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
        underlying = DEPLOYER.stakedTokenOf(projectId);
        stickyToken = TOKENS.tokenOf(projectId);
    }

    /// @notice Wraps a token ID in a one-element array for distributor calls.
    function _singletonId(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }

    /// @notice Wraps a token in a one-element array for distributor calls.
    function _singletonToken(IERC20Metadata token) internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = token;
    }
}
