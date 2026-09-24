// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBActiveVotes} from "@bananapus/core-v6/src/interfaces/IJBActiveVotes.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBDistributor} from "@bananapus/distributor-v6/src/JBDistributor.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IJBTokenDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBTokenDistributor.sol";
import {JBClaimContext} from "@bananapus/distributor-v6/src/structs/JBClaimContext.sol";
import {JBRewardRoundData} from "@bananapus/distributor-v6/src/structs/JBRewardRoundData.sol";
import {JBVestingData} from "@bananapus/distributor-v6/src/structs/JBVestingData.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {IJBStickyDistributor} from "./interfaces/IJBStickyDistributor.sol";
import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {IJBStickyToken} from "./interfaces/IJBStickyToken.sol";

/// @notice A singleton distributor that hands ERC-20 rewards (or native ETH) to the holders of Sticky tokens with
/// linear vesting. Funders choose who a pot rewards: the default group (0) splits it across delegated voting power
/// at the round's snapshot block, exactly like a token distributor, while a tenure group splits it across the stake
/// each holder still holds in tranches created between `maxWeeks` and `minWeeks` before the round started.
/// @dev The `hook` in every function is the Sticky token whose holders are rewarded. Tenure groups read the Sticky
/// hook's tranches and epoch buckets, so they can only be funded for tokens registered with it. Tranches are
/// append-only with current timestamps and `minWeeks >= 1` keeps the round's own epoch out of every window, so
/// nothing staked after a round's denominator is read can enter that round's window: claims only ever shrink as
/// holders exit. Holders claim completed rounds lazily; unclaimed rewards vest from the claim, not the funding.
/// A Sticky token funded as a reward gives this distributor reward weight in that token's rounds; that allocation
/// recycles into the current round when collected, since the distributor cannot pay itself.
/// @dev Implements `IJBSplitHook` so it can receive rewards directly from Juicebox payout and reserved-token splits.
/// Revnet loan-backed collection is disabled: no loans contract or REVOwner is configured.
contract JBStickyDistributor is JBDistributor, IJBStickyDistributor {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the Sticky hook measures stake age in a different epoch than this distributor.
    error JBStickyDistributor_EpochDurationMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when a group ID is neither the default group nor a valid tenure window.
    error JBStickyDistributor_InvalidGroupId(uint256 groupId);

    /// @notice Thrown when a token ID has non-zero bits above 160, which would alias another holder's address.
    error JBStickyDistributor_InvalidTokenId(uint256 tokenId);

    /// @notice Thrown when the native ETH sent with a split does not match the split's amount.
    error JBStickyDistributor_NativeAmountMismatch(uint256 msgValue, uint256 contextAmount);

    /// @notice Thrown when a tenure denominator is read while a payment's minted shares have no tranche yet, since the
    /// hook's buckets would not yet include them.
    error JBStickyDistributor_PaymentInProgress(address hook, uint256 projectId);

    /// @notice Thrown when native ETH is sent with a split for an ERC-20 token.
    error JBStickyDistributor_TokenMismatch(address token, address expectedToken, uint256 msgValue);

    /// @notice Thrown when a split comes from an address that is neither a terminal nor the controller of its project.
    error JBStickyDistributor_Unauthorized(uint256 projectId, address caller);

    /// @notice Thrown when a tenure group is funded for a token the Sticky hook does not track tranches for.
    error JBStickyDistributor_UnregisteredStickyToken(address hook);

    /// @notice Thrown when the claim duration is zero, which would let a tenure pot whose eligible holders all exited
    /// sit unclaimable forever instead of recycling.
    error JBStickyDistributor_ZeroClaimDuration();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The multiplier used to encode a tenure group ID as `minWeeks * CRITERIA_BASE + maxWeeks`.
    uint256 public constant override CRITERIA_BASE = 1000;

    /// @notice The duration of one stake-age epoch, which must match the Sticky hook's.
    uint256 public constant override EPOCH_DURATION = 1 weeks;

    /// @notice The highest value either `minWeeks` or `maxWeeks` of a tenure group ID can take.
    uint256 public constant override MAX_CRITERIA_WEEKS = 520;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The directory used to verify that splits come from a project's terminal or controller.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The hook that records the tranches and epoch buckets tenure rewards are weighed by.
    IJBStickyHook public immutable override STICKY_HOOK;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The next reward round a holder has not yet claimed in a group.
    /// @custom:param hook The sticky token the token ID belongs to.
    /// @custom:param groupId The reward group (0 = the default group).
    /// @custom:param tokenId The encoded holder address.
    /// @custom:param token The reward token being claimed.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => uint256)))
    )
        public
        override nextClaimRoundOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Binds the distributor to the Sticky hook whose tranches weigh tenure rewards.
    /// @param controller The controller used for token registry lookups.
    /// @param directory The directory used to verify that splits come from a project's terminal or controller.
    /// @param stickyHook The hook that records the tranches and epoch buckets tenure rewards are weighed by.
    /// @param initialRoundDuration The duration of each round, in seconds.
    /// @param initialVestingRounds The number of rounds until claimed rewards are fully vested.
    /// @param initialClaimDuration The number of seconds a completed round stays claimable. Must be non-zero so a
    /// forfeited tenure pot can recycle.
    constructor(
        IJBController controller,
        IJBDirectory directory,
        IJBStickyHook stickyHook,
        uint256 initialRoundDuration,
        uint256 initialVestingRounds,
        uint48 initialClaimDuration
    )
        JBDistributor(
            controller,
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            initialRoundDuration,
            initialVestingRounds,
            initialClaimDuration
        )
    {
        // Tenure claims read live tranches, so a pot whose eligible holders all exited can only ever recycle by
        // expiring; a zero duration never expires and would strand it.
        if (initialClaimDuration == 0) revert JBStickyDistributor_ZeroClaimDuration();

        // Window bounds are converted to epochs with this contract's constant, so the hook's buckets must agree.
        uint256 hookEpochDuration = stickyHook.EPOCH_DURATION();

        // Reject a hook whose epochs would make window bounds select the wrong buckets.
        if (hookEpochDuration != EPOCH_DURATION) {
            revert JBStickyDistributor_EpochDurationMismatch({expected: EPOCH_DURATION, actual: hookEpochDuration});
        }

        // Fix the directory used to authenticate split callbacks.
        DIRECTORY = directory;

        // Fix the hook whose tranches and epoch buckets weigh tenure rewards.
        STICKY_HOOK = stickyHook;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Allows the contract to receive native ETH, such as from payout splits.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claims a group's completed reward rounds for the given token IDs and starts vesting them.
    /// @dev Permissionless. Materializes each holder's pro-rata share of every completed reward round into a fresh
    /// vesting entry that unlocks over `VESTING_ROUNDS`. The current round's funding is excluded until it completes.
    /// @param hook The sticky token whose holders are vesting.
    /// @param groupId The reward group to vest from (0 = the default group).
    /// @param tokenIds The encoded holder addresses to claim for.
    /// @param tokens The reward tokens to claim.
    function beginVesting(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external
        override
    {
        // Reject groups that can never hold a pot before touching any claim cursor.
        _requireValidGroupId(groupId);

        // Materialize each holder's completed rounds into vesting entries.
        _beginVesting({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Claims a group's completed reward rounds, then collects everything that has unlocked.
    /// @dev Holders can collect to any beneficiary. Helpers can collect only to the encoded holder. Collecting this
    /// distributor's own allocation to itself recycles it into the current round instead of transferring.
    /// @param hook The sticky token whose holders are collecting.
    /// @param groupId The reward group to collect from (0 = the default group).
    /// @param tokenIds The encoded holder addresses to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        // Reject groups that can never hold a pot before touching any claim cursor.
        _requireValidGroupId(groupId);

        // Collect to the beneficiary, or recycle when the beneficiary is this distributor.
        _collectOrRecycle({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary});
    }

    /// @notice Funds the default group of a sticky token's holders for the current round.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token. ERC-20 funding is
    /// measured by balance delta, so fee-on-transfer tokens credit only what arrives.
    /// @param hook The sticky token whose holders receive the rewards.
    /// @param token The reward token.
    /// @param amount The amount to fund, ignored for native ETH.
    function fund(address hook, IERC20 token, uint256 amount) external payable override(IJBDistributor, JBDistributor) {
        // The stock signature always funds the vote-weighted default group.
        _fundGroup({hook: hook, groupId: 0, token: token, amount: amount});
    }

    /// @notice Funds a group of a sticky token's holders for the current round.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token. A tenure group can only
    /// be funded for a token registered with the Sticky hook, since its weights come from that hook's tranches.
    /// @param hook The sticky token whose holders receive the rewards.
    /// @param token The reward token.
    /// @param amount The amount to fund, ignored for native ETH.
    /// @param groupId The reward group to fund (0 = the default group).
    function fund(address hook, IERC20 token, uint256 amount, uint256 groupId) external payable override {
        // Reject groups that can never be claimed before accepting any funds.
        _requireValidGroupId(groupId);

        // Tenure weights are read from the hook's tranches, which only exist for tokens it tracks.
        if (groupId != 0 && !_isRegisteredStickyToken(hook)) revert JBStickyDistributor_UnregisteredStickyToken(hook);

        // Accept the funds and record them as the current round's pot for the group.
        _fundGroup({hook: hook, groupId: groupId, token: token, amount: amount});
    }

    /// @notice Receives rewards from a Juicebox payout or reserved-token split.
    /// @dev Only callable by a terminal or the controller of the split's project. The sticky token being funded is
    /// the split's beneficiary and the group is the split's `projectId`, which core reads only in the branch that
    /// pays a project directly, never while the split's hook is set. A split can therefore be both locked and
    /// group-carrying. A `projectId` that is not a valid tenure window, or a beneficiary the Sticky hook does not
    /// track, funds the default group instead of reverting, because a split-hook revert silently returns the funds
    /// to the project.
    /// @param context The split context passed in by the terminal or controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Only the project's own terminals and controller can route its splits here.
        if (
            !DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})
                && DIRECTORY.controllerOf(context.projectId) != IERC165(msg.sender)
        ) revert JBStickyDistributor_Unauthorized({projectId: context.projectId, caller: msg.sender});

        // The rewarded holders are the split beneficiary's.
        address hook = address(context.split.beneficiary);

        // Read the requested group from the split's project ID, falling back to the default group when it cannot be
        // honored so the split's funds still distribute.
        uint256 groupId = context.split.projectId;

        // A window the distributor cannot serve, or a beneficiary the hook does not track, funds the default group.
        if (!isValidGroupId(groupId) || (groupId != 0 && !_isRegisteredStickyToken(hook))) groupId = 0;

        // Native splits must deliver exactly the stated amount.
        if (context.token == JBConstants.NATIVE_TOKEN) {
            // Reject a native split whose value differs from the amount core recorded for it.
            if (msg.value != context.amount) {
                revert JBStickyDistributor_NativeAmountMismatch({msgValue: msg.value, contextAmount: context.amount});
            }

            // Book the delivered ETH as the current round's pot.
            _recordFunding({hook: hook, groupId: groupId, token: IERC20(context.token), amount: msg.value});
        } else {
            // Native ETH must not be booked under an ERC-20 reward token.
            if (msg.value != 0) {
                revert JBStickyDistributor_TokenMismatch({
                    token: context.token, expectedToken: JBConstants.NATIVE_TOKEN, msgValue: msg.value
                });
            }

            // An empty split has nothing to pull or record.
            if (context.amount == 0) return;

            // Terminals and the controller approve the split's amount before calling, so pull it and credit only
            // what actually arrives.
            uint256 delta =
                _acceptErc20FundsFrom({token: IERC20(context.token), from: msg.sender, amount: context.amount});

            // Book only the delivered ERC-20 amount as the current round's pot.
            _recordFunding({hook: hook, groupId: groupId, token: IERC20(context.token), amount: delta});
        }
    }

    /// @notice Recycles a group's expired reward rounds into the current round.
    /// @dev Permissionless. Passing the current round is a no-op, including for zero-stake rounds.
    /// @param hook The sticky token whose expired rewards should be recycled.
    /// @param groupId The reward group to recycle (0 = the default group).
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function recycleExpiredRewards(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        override
        returns (uint256 amount)
    {
        // Reject groups that can never hold a pot before reading any round.
        _requireValidGroupId(groupId);

        // Move each expired round's unclaimed inventory into the current round.
        amount = _recycleExpiredRewards({hook: hook, groupId: groupId, token: token, rounds: rounds});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The amount of a reward token that has been claimed for a token ID in a group but not yet collected.
    /// @param hook The sticky token the token ID belongs to.
    /// @param groupId The reward group to check (0 = the default group).
    /// @param tokenId The encoded holder address.
    /// @param token The reward token to check.
    /// @return tokenAmount The uncollected amount, vesting and unlocked.
    function claimedFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        // Report the vesting entries' remaining balance, whether or not it has unlocked.
        tokenAmount = _unclaimedVestingAmountOf({hook: hook, groupId: groupId, tokenId: tokenId, token: token});
    }

    /// @notice The amount of a reward token currently unlocked and collectable for a token ID in a group.
    /// @param hook The sticky token the token ID belongs to.
    /// @param groupId The reward group to check (0 = the default group).
    /// @param tokenId The encoded holder address.
    /// @param token The reward token to check.
    /// @return tokenAmount The collectable amount.
    function collectableFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        // Report only the portion of the vesting entries that has unlocked so far.
        tokenAmount = _collectableFor({hook: hook, groupId: groupId, tokenId: tokenId, token: token});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Whether a group ID is the default group or a valid tenure window.
    /// @dev `minWeeks >= 1` is what keeps a round's own epoch out of its window, so stake added after the round's
    /// denominator is read can never share the round's pot.
    /// @param groupId The group ID to check.
    /// @return isValid Whether the group can be funded and claimed from.
    function isValidGroupId(uint256 groupId) public pure override returns (bool isValid) {
        // The default group is always fundable.
        if (groupId == 0) return true;

        // Decode the window's bounds, in weeks before the round's snapshot epoch.
        uint256 minWeeks = groupId / CRITERIA_BASE;

        // The low digits carry the window's upper bound; zero means unbounded.
        uint256 maxWeeks = groupId % CRITERIA_BASE;

        // Both bounds stay within the supported range, and a bounded window must end at or after it starts.
        return minWeeks != 0 && minWeeks <= MAX_CRITERIA_WEEKS && maxWeeks <= MAX_CRITERIA_WEEKS
            && (maxWeeks == 0 || maxWeeks >= minWeeks);
    }

    /// @notice The epoch a round's tenure windows are measured from: the epoch the round started in.
    /// @dev Pinned to the round start so every funding of a round, whenever it lands, weighs the same tranches.
    /// @param round The round to get the snapshot epoch of.
    /// @return epoch The round's snapshot epoch.
    function snapshotEpochOf(uint256 round) public view override returns (uint256 epoch) {
        // Convert the round's start into the hook's epoch numbering.
        epoch = roundStartTimestamp(round) / EPOCH_DURATION;
    }

    /// @notice Indicates whether this contract supports the given interface.
    /// @param interfaceId The interface ID to check.
    /// @return supported Whether the interface is supported.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool supported) {
        // Advertise the Sticky, token-distributor and split-hook entry points alongside ERC165 itself.
        return interfaceId == type(IJBStickyDistributor).interfaceId
            || interfaceId == type(IJBTokenDistributor).interfaceId || interfaceId == type(IJBSplitHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claims the default group's completed reward rounds, then collects everything that has unlocked.
    /// @dev Holders can collect to any beneficiary. Helpers can collect only to the encoded holder. Collecting this
    /// distributor's own allocation to itself recycles it into the current round instead of transferring.
    /// @param hook The sticky token whose holders are collecting.
    /// @param tokenIds The encoded holder addresses to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        public
        override(IJBDistributor, JBDistributor)
    {
        // The stock signature always collects from the vote-weighted default group.
        _collectOrRecycle({hook: hook, groupId: 0, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary});
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claims every completed reward round for the given token IDs and reward tokens into fresh vesting
    /// entries.
    /// @param hook The sticky token whose holders are claiming.
    /// @param groupId The reward group being claimed (0 = the default group).
    /// @param tokenIds The encoded holder addresses to claim for.
    /// @param tokens The reward tokens to claim.
    function _claimPastRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
        override
    {
        // Round 0 has no completed reward rounds behind it, so nothing can be claimed yet.
        uint256 round = currentRound();

        // Nothing is claimable until at least one round has completed.
        // slither-disable-next-line incorrect-equality
        if (round == 0) return;

        // The current round's funding becomes claimable only once a later round starts. Sticky holders have no tier
        // concept, so `tierIds` stays empty; the group only selects the pot and its weighting.
        JBClaimContext memory ctx = JBClaimContext({
            hook: hook,
            groupId: groupId,
            tierIds: new uint256[](0),
            lastClaimableRound: round - 1,
            vestingReleaseRound: round + VESTING_ROUNDS
        });

        // Each reward token has its own round funding and claim cursor, so process them independently.
        // Solidity initializes the index to zero, covering every reward token supplied.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < tokens.length;) {
            // Resolve the reward token whose rounds this pass settles.
            IERC20 token = tokens[i];

            // Accumulate every holder's claim before the single vesting-total write below.
            uint256 totalVestingAmount = 0;

            // Materialize this reward token for every holder encoded in the token IDs.
            // Solidity initializes the index to zero, covering every token ID supplied.
            // forge-lint: disable-next-line(uninitialized-local)
            for (uint256 j; j < tokenIds.length;) {
                totalVestingAmount += _claimPastRewardsForTokenId({ctx: ctx, tokenId: tokenIds[j], token: token});

                unchecked {
                    ++j;
                }
            }

            // Track the newly claimed amount as vesting so later collections unlock against it.
            // One write per reward token; the caller pays for the token list it chose.
            // forge-lint: disable-next-line(costly-loop)
            if (totalVestingAmount != 0) totalVestingAmountOf[hook][token] += totalVestingAmount;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claims every completed reward round for one token ID into one fresh vesting entry.
    /// @param ctx The claim context.
    /// @param tokenId The encoded holder address to claim for.
    /// @param token The reward token to claim.
    /// @return tokenAmount The amount added to vesting.
    function _claimPastRewardsForTokenId(
        JBClaimContext memory ctx,
        uint256 tokenId,
        IERC20 token
    )
        internal
        returns (uint256 tokenAmount)
    {
        // Every round before the cursor has already been settled for this holder.
        uint256 nextClaimRound = nextClaimRoundOf[ctx.hook][ctx.groupId][tokenId][token];

        // A cursor past the last completed round means the holder is current.
        if (nextClaimRound > ctx.lastClaimableRound) return 0;

        // Sum the holder's pro-rata share of every unresolved completed round.
        uint256 newNextClaimRound;

        // Walk every unresolved completed round and total the holder's allocation.
        (tokenAmount, newNextClaimRound) = _claimRewardsFor({
            hook: ctx.hook,
            groupId: ctx.groupId,
            tokenId: tokenId,
            token: token,
            firstRound: nextClaimRound,
            lastRound: ctx.lastClaimableRound
        });

        // Advance the cursor past the resolved rounds.
        nextClaimRoundOf[ctx.hook][ctx.groupId][tokenId][token] = newNextClaimRound;

        // Avoid an empty vesting entry when no past round allocates rewards to this holder.
        // slither-disable-next-line incorrect-equality
        if (tokenAmount == 0) return 0;

        // All accumulated past rewards start a single fresh vesting schedule at the claim round.
        vestingDataOf[ctx.hook][ctx.groupId][tokenId][token].push(
            JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmount, shareClaimed: 0})
        );

        // The preceding external calls only read the Sticky hook and token under STATICCALL.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Claimed({
            hook: ctx.hook,
            tokenId: tokenId,
            groupId: ctx.groupId,
            token: token,
            amount: tokenAmount,
            vestingReleaseRound: ctx.vestingReleaseRound,
            caller: msg.sender
        });
    }

    /// @notice Claims one reward round using its recorded denominator.
    /// @param hook The sticky token whose holders are claiming.
    /// @param groupId The reward group being claimed (0 = the default group).
    /// @param projectId The sticky project the hook tracks, unused for the default group.
    /// @param tokenId The encoded holder address.
    /// @param round The reward round being claimed.
    /// @param rewardRound The stored reward round.
    /// @return tokenAmount The amount added to vesting.
    function _claimRewardRoundFor(
        address hook,
        uint256 groupId,
        uint256 projectId,
        uint256 tokenId,
        uint256 round,
        JBRewardRoundData storage rewardRound
    )
        internal
        returns (uint256 tokenAmount)
    {
        // A round with no denominator has no pro-rata basis, so it allocates nothing.
        if (rewardRound.totalStake == 0) return 0;

        // The default group weighs delegated votes at the round's snapshot block. Tenure groups weigh the stake still
        // held in the round's window, read live: exits only shrink it, and nothing newer can enter.
        // slither-disable-next-line incorrect-equality
        uint256 tokenStakeAmount = groupId == 0
            ? _tokenStakeAt({hook: hook, tokenId: tokenId, blockNumber: rewardRound.snapshotBlock})
            : _windowStakeOf({
                projectId: projectId,
                holder: _claimBeneficiaryOf({hook: hook, tokenId: tokenId}),
                groupId: groupId,
                round: round
            });

        // Zero-weight holders advance their cursor without consuming inventory.
        // slither-disable-next-line incorrect-equality
        if (tokenStakeAmount == 0) return 0;

        // Split the pot pro-rata across the recorded denominator.
        uint256 claimAmount = mulDiv({x: rewardRound.amount, y: tokenStakeAmount, denominator: rewardRound.totalStake});

        // Never materialize more than the pot still holds, so claims can never exceed funding.
        uint256 remainingPot = uint256(rewardRound.amount) - uint256(rewardRound.claimedAmount);

        // Cap the allocation at what is left.
        if (claimAmount > remainingPot) claimAmount = remainingPot;

        // Skip floor-rounded zero claims to avoid needless storage writes.
        if (claimAmount == 0) return 0;

        // Track the portion that started vesting so expiry recycles only the remainder.
        rewardRound.claimedAmount = _toUint208(uint256(rewardRound.claimedAmount) + claimAmount);

        // Report the allocation so the caller can add it to the holder's vesting entry.
        tokenAmount = claimAmount;
    }

    /// @notice Claims a holder's unclaimed rewards across a range of completed reward rounds.
    /// @param hook The sticky token whose holders are claiming.
    /// @param groupId The reward group being claimed (0 = the default group).
    /// @param tokenId The encoded holder address.
    /// @param token The reward token.
    /// @param firstRound The first reward round to include.
    /// @param lastRound The last reward round to include.
    /// @return tokenAmount The cumulative unclaimed reward amount.
    /// @return newNextClaimRound The next reward round this holder has not yet resolved.
    function _claimRewardsFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token,
        uint256 firstRound,
        uint256 lastRound
    )
        internal
        returns (uint256 tokenAmount, uint256 newNextClaimRound)
    {
        // Every round through the last completed one is resolved by this walk.
        newNextClaimRound = lastRound + 1;

        // Tenure groups resolve the hook's project once for the whole walk; the default group never needs it.
        // One read per claimed holder and reward token, not per round.
        // forge-lint: disable-next-item(calls-loop)
        // slither-disable-next-line incorrect-equality
        uint256 projectId = groupId == 0 ? 0 : IJBStickyToken(hook).PROJECT_ID();

        // Walk every unclaimed round; the caller bounds the range to completed rounds.
        for (uint256 round = firstRound; round <= lastRound;) {
            // Read the round's pot once for both the expiry check and the claim.
            JBRewardRoundData storage rewardRound = rewardRoundOf[hook][groupId][token][round];

            // Rounds that never received funding have nothing to claim or recycle.
            if (rewardRound.amount != 0) {
                // Expired rounds forfeit their unclaimed inventory into the current round.
                if (_rewardRoundExpired(rewardRound)) {
                    _recycleExpiredRewardRound({hook: hook, groupId: groupId, token: token, round: round});
                } else {
                    tokenAmount += _claimRewardRoundFor({
                        hook: hook,
                        groupId: groupId,
                        projectId: projectId,
                        tokenId: tokenId,
                        round: round,
                        rewardRound: rewardRound
                    });
                }
            }

            unchecked {
                ++round;
            }
        }
    }

    /// @notice Collects unlocked rewards to a beneficiary, or recycles them into the current round when the
    /// beneficiary is this distributor.
    /// @dev A Sticky token funded as a reward leaves this distributor holding shares that earn reward weight in that
    /// token's rounds. Helpers can only collect that allocation to the distributor itself, which would move nothing
    /// while the ledger forgot the amount. It is treated as forfeited instead: only this distributor's own token ID
    /// passes the forfeiture check, and its unlocked rewards recycle into the current round of the same hook, group
    /// and token. Every other token ID collected to this distributor is rejected.
    /// @param hook The sticky token whose holders are collecting.
    /// @param groupId The reward group to collect from (0 = the default group).
    /// @param tokenIds The encoded holder addresses to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function _collectOrRecycle(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        internal
    {
        // Only the distributor's own allocation is collected to itself; the stock path serves everyone else.
        if (beneficiary == address(this)) {
            // Inventory stays in custody and the current holders get a fresh claimable round.
            _releaseForfeitedRewards({
                hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary
            });
        } else {
            // Transfer every unlocked reward to the beneficiary.
            _collectVestedRewards({
                hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary
            });
        }
    }

    /// @notice Accepts funds from the caller and records them as the current round's pot for a group.
    /// @param hook The sticky token whose holders receive the rewards.
    /// @param groupId The reward group being funded (0 = the default group).
    /// @param token The reward token.
    /// @param amount The nominal amount to pull, ignored for native ETH.
    function _fundGroup(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Native funding is measured by `msg.value`, not the stated amount.
        if (address(token) == JBConstants.NATIVE_TOKEN) {
            amount = msg.value;
        } else {
            // ERC-20 funding must not carry native ETH.
            if (msg.value != 0) {
                revert JBDistributor_UnexpectedNativeValue({msgValue: msg.value, token: address(token)});
            }

            // Credit only the balance delta so fee-on-transfer tokens cannot over-promise.
            amount = _acceptErc20FundsFrom({token: token, from: msg.sender, amount: amount});
        }

        // Book the accepted amount as the current round's pot.
        _recordFunding({hook: hook, groupId: groupId, token: token, amount: amount});
    }

    /// @notice Records accepted funds as the current round's pot for a group and publishes the funding.
    /// @param hook The sticky token whose holders receive the rewards.
    /// @param groupId The reward group being funded (0 = the default group).
    /// @param token The reward token.
    /// @param amount The accepted amount.
    function _recordFunding(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Zero-value funding creates no reward round and changes no balance.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return;

        // Record the round's denominator on first funding and add the amount to its pot.
        _recordRewardFunding({hook: hook, groupId: groupId, token: token, amount: amount});

        // The ledger is settled before this log. Reentering through the reward token cannot reorder it: every
        // funding and claim entry point rejects calls while an inbound transfer is being measured.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Fund({
            hook: hook, groupId: groupId, token: token, round: currentRound(), amount: amount, caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Whether an account is the holder encoded in a token ID.
    /// @param hook Unused; access is determined by the token ID encoding.
    /// @param tokenId The encoded holder address.
    /// @param account The account to check.
    /// @return canClaim Whether the account is the encoded holder.
    function _canClaim(address hook, uint256 tokenId, address account) internal pure override returns (bool canClaim) {
        // Sticky holders are addresses, so control follows the encoded address exactly.
        canClaim = _claimBeneficiaryOf({hook: hook, tokenId: tokenId}) == account;
    }

    /// @notice The holder encoded in a token ID, who receives permissionless collections.
    /// @dev Reverts on high-bit aliasing so every token ID maps to exactly one address.
    /// @param hook Unused; the beneficiary is determined by the token ID encoding.
    /// @param tokenId The encoded holder address.
    /// @return beneficiary The holder encoded in the token ID.
    function _claimBeneficiaryOf(address hook, uint256 tokenId) internal pure override returns (address beneficiary) {
        // The stock signature carries the hook; the encoding alone determines the beneficiary.
        hook;

        // Reject IDs whose high bits would alias another holder's address after the cast below.
        if (tokenId >> 160 != 0) revert JBStickyDistributor_InvalidTokenId({tokenId: tokenId});

        // The high bits were checked above, so this cast recovers the encoded address.
        // forge-lint: disable-next-line(unsafe-typecast)
        beneficiary = address(uint160(tokenId));
    }

    /// @notice Reverts unless a group ID is the default group or a valid tenure window.
    /// @param groupId The group ID to validate.
    function _requireValidGroupId(uint256 groupId) internal pure {
        // Share one rule with the public view so callers can pre-check the same condition.
        if (!isValidGroupId(groupId)) revert JBStickyDistributor_InvalidGroupId(groupId);
    }

    /// @notice Reverts unless every token ID decodes to a holder address.
    /// @param hook The sticky token the token IDs belong to.
    /// @param tokenIds The encoded holder addresses to validate.
    function _validateTokenIds(address hook, uint256[] calldata tokenIds) internal pure override {
        // Solidity initializes the index to zero, covering every token ID supplied.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < tokenIds.length;) {
            // Decoding reverts on any ID that does not fit an address.
            _claimBeneficiaryOf({hook: hook, tokenId: tokenIds[i]});

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Whether the Sticky hook tracks tranches for a token.
    /// @dev Reads the token's project through a low-level call so a beneficiary that is not a Sticky token, or not a
    /// contract at all, reports unregistered instead of reverting a split.
    /// @param hook The token to check.
    /// @return isRegistered Whether the token is the Sticky hook's registered token for its project.
    function _isRegisteredStickyToken(address hook) internal view returns (bool isRegistered) {
        // An arbitrary beneficiary may not expose a project ID; treat any failure or malformed answer as unregistered.
        // A typed call would revert on an answer it cannot decode, which a split must survive.
        // forge-lint: disable-next-line(low-level-calls)
        (bool success, bytes memory data) = hook.staticcall(abi.encodeCall(IJBStickyToken.PROJECT_ID, ()));

        // Anything other than one word is not a Sticky token's project ID.
        if (!success || data.length != 32) return false;

        // Only the token the hook records movements from is a valid tenure source for its project.
        isRegistered = STICKY_HOOK.tokenOf(abi.decode(data, (uint256))) == hook;
    }

    /// @notice Reverts unless the caller is the holder encoded in each token ID.
    /// @param hook The sticky token the token IDs belong to.
    /// @param tokenIds The encoded holder addresses to check.
    function _requireCanClaimTokenIds(address hook, uint256[] calldata tokenIds) internal view override {
        // Solidity initializes the index to zero, covering every token ID supplied.
        // forge-lint: disable-next-line(uninitialized-local)
        for (uint256 i; i < tokenIds.length;) {
            // Fail on the first token ID the caller does not control; the rest are never read.
            // forge-lint: disable-next-item(require-revert-in-loop)
            if (!_canClaim({hook: hook, tokenId: tokenIds[i], account: msg.sender})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Whether a token ID's rewards are forfeited to the pot. Sticky holders are addresses, which cannot be
    /// burned, so only this distributor's own encoded address is: the shares it holds as reward inventory earn weight
    /// it can never collect.
    /// @param hook Unused; forfeiture is determined by the token ID encoding.
    /// @param tokenId The encoded holder address.
    /// @return tokenWasBurned Whether the token ID encodes this distributor.
    function _tokenBurned(address hook, uint256 tokenId) internal view override returns (bool tokenWasBurned) {
        // The stock signature carries the hook; forfeiture depends only on the encoded address.
        hook;

        // Only the distributor's own encoded address forfeits.
        tokenWasBurned = tokenId == uint256(uint160(address(this)));
    }

    /// @notice A holder's delegated voting power at the current round's snapshot block.
    /// @param hook The sticky token.
    /// @param tokenId The encoded holder address.
    /// @return tokenStakeAmount The delegated voting power at the round's snapshot block.
    function _tokenStake(address hook, uint256 tokenId) internal view override returns (uint256 tokenStakeAmount) {
        // Read the holder's checkpointed votes at the current round's snapshot.
        tokenStakeAmount =
            _tokenStakeAt({hook: hook, tokenId: tokenId, blockNumber: roundSnapshotBlock[currentRound()]});
    }

    /// @notice A holder's delegated voting power at a snapshot block.
    /// @param hook The sticky token.
    /// @param tokenId The encoded holder address.
    /// @param blockNumber The historical block to query.
    /// @return tokenStakeAmount The delegated voting power at the block.
    function _tokenStakeAt(
        address hook,
        uint256 tokenId,
        uint256 blockNumber
    )
        internal
        view
        returns (uint256 tokenStakeAmount)
    {
        // One checkpoint read per claimed round; the holder pays for the rounds they left unclaimed.
        // forge-lint: disable-next-item(calls-loop)
        tokenStakeAmount = IVotes(hook).getPastVotes({
            account: _claimBeneficiaryOf({hook: hook, tokenId: tokenId}), timepoint: blockNumber
        });
    }

    /// @notice The denominator recorded when a group's round is first funded.
    /// @dev The default group uses the active vote total at the snapshot block, so undelegated balances never share
    /// rewards. Tenure groups total the stake in the current round's window, read from the hook's epoch buckets at
    /// funding time. Those buckets are frozen for the window because nothing joins an epoch before the round's own.
    /// @param hook The sticky token.
    /// @param groupId The reward group (0 = the default group).
    /// @param blockNumber The snapshot block, used by the default group only.
    /// @return totalStakedAmount The denominator to record for the funded round.
    function _totalStake(
        address hook,
        uint256 groupId,
        uint256 blockNumber
    )
        internal
        view
        override
        returns (uint256 totalStakedAmount)
    {
        // Group 0 is the default vote-weighted pot; every other ID encodes a tenure window.
        // slither-disable-next-line incorrect-equality
        if (groupId == 0) return IJBActiveVotes(hook).getPastTotalActiveVotes(blockNumber);

        // Funding always lands in the current round, whose start pins the window.
        totalStakedAmount = _windowTotalStakeOf({hook: hook, groupId: groupId, round: currentRound()});
    }

    /// @notice The epoch window a tenure group selects for a round.
    /// @dev Measured back from the round's snapshot epoch. `minWeeks >= 1` keeps that epoch itself out of the window.
    /// @param groupId The tenure group, encoded as `minWeeks * CRITERIA_BASE + maxWeeks`.
    /// @param round The reward round.
    /// @return lo The first eligible epoch, or 0 when the window has no lower bound.
    /// @return hi The last eligible epoch.
    /// @return isEmpty Whether no epoch can qualify because the chain is younger than `minWeeks`.
    function _windowOf(uint256 groupId, uint256 round) internal view returns (uint256 lo, uint256 hi, bool isEmpty) {
        // Measure the window back from the epoch the round started in.
        uint256 snapshotEpoch = snapshotEpochOf(round);

        // The high digits carry the window's lower bound in weeks.
        uint256 minWeeks = groupId / CRITERIA_BASE;

        // Decodes the group ID's low digits; nothing here is random.
        // slither-disable-next-line weak-prng
        uint256 maxWeeks = groupId % CRITERIA_BASE;

        // The window's top would sit before the first epoch, so nothing can be old enough.
        isEmpty = snapshotEpoch < minWeeks;

        // An empty window has no bounds worth computing.
        if (isEmpty) return (lo, hi, isEmpty);

        // The newest eligible epoch sits `minWeeks` before the snapshot.
        hi = snapshotEpoch - minWeeks;

        // A zero `maxWeeks` encodes an unbounded window, not a computed amount.
        // slither-disable-next-line incorrect-equality
        lo = (maxWeeks == 0 || snapshotEpoch < maxWeeks) ? 0 : snapshotEpoch - maxWeeks;
    }

    /// @notice A holder's stake still held in tranches created within a group's window for a round.
    /// @dev Cumulative balances through the window's bounds come from the hook, so the read costs two binary searches
    /// at most regardless of how many tranches the holder has.
    /// @param projectId The sticky project the hook tracks.
    /// @param holder The holder whose tranches to weigh.
    /// @param groupId The tenure group whose window bounds the sum.
    /// @param round The reward round.
    /// @return amount The holder's in-window stake.
    function _windowStakeOf(
        uint256 projectId,
        address holder,
        uint256 groupId,
        uint256 round
    )
        internal
        view
        returns (uint256 amount)
    {
        // Resolve the epochs the group's window covers for this round.
        (uint256 lo, uint256 hi, bool isEmpty) = _windowOf({groupId: groupId, round: round});

        // A window before the first epoch holds no stake.
        if (isEmpty) return 0;

        // Everything created through the window's top, less everything created before its bottom. At most two
        // reads per claimed round; the holder pays for the rounds they left unclaimed.
        // forge-lint: disable-next-line(calls-loop)
        amount = STICKY_HOOK.stakedBalanceThroughEpochOf({projectId: projectId, holder: holder, epoch: hi});

        // A bounded window excludes everything created before its bottom.
        if (lo != 0) {
            // forge-lint: disable-next-line(calls-loop)
            amount -= STICKY_HOOK.stakedBalanceThroughEpochOf({projectId: projectId, holder: holder, epoch: lo - 1});
        }
    }

    /// @notice The total stake still held in tranches created within a group's window for a round.
    /// @dev An unbounded window is the token's supply less every bucket newer than the window, so its cost grows
    /// with `minWeeks` rather than the project's age. A bounded window sums its own buckets. Both walks are capped
    /// by `MAX_CRITERIA_WEEKS` plus the epochs elapsed since the round started. Reverts while a payment to the
    /// project is in progress: the terminal mints before the hook records the tranche, so the buckets lag the supply
    /// until the after-pay callback runs, and a denominator read in that gap would count shares without a tranche.
    /// @param hook The sticky token.
    /// @param groupId The tenure group whose window bounds the sum.
    /// @param round The reward round.
    /// @return amount The window's total stake.
    function _windowTotalStakeOf(address hook, uint256 groupId, uint256 round) internal view returns (uint256 amount) {
        // Resolve the project whose buckets the hook keeps for this token.
        uint256 projectId = IJBStickyToken(hook).PROJECT_ID();

        // Only an underlying token with transfer callbacks can reach this read mid-payment; refuse it rather than
        // record a denominator the pot's holders could never fully claim.
        if (STICKY_HOOK.isPayingFor(projectId)) {
            revert JBStickyDistributor_PaymentInProgress({hook: hook, projectId: projectId});
        }

        // Resolve the epochs the group's window covers for this round.
        (uint256 lo, uint256 hi, bool isEmpty) = _windowOf({groupId: groupId, round: round});

        // A window before the first epoch holds no stake.
        if (isEmpty) return 0;

        // Bounded windows sum exactly their buckets. The modulo decodes the group ID's `maxWeeks` digits.
        // slither-disable-next-line weak-prng
        if (groupId % CRITERIA_BASE != 0) {
            return STICKY_HOOK.netStakedWithin({projectId: projectId, fromEpoch: lo, toEpoch: hi});
        }

        // Buckets always sum to the supply, so everything through the window's top is the supply minus what joined
        // after it. The current epoch is never below the round's, which is above the window's top.
        uint256 newerStake = STICKY_HOOK.netStakedWithin({
            projectId: projectId, fromEpoch: hi + 1, toEpoch: block.timestamp / EPOCH_DURATION
        });

        // Everything the newer buckets do not hold sits in the window or below it.
        amount = IJBToken(hook).totalSupply() - newerStake;
    }
}
