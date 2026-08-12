// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBActiveVotes} from "@bananapus/core-v6/src/interfaces/IJBActiveVotes.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBVestingMath} from "@bananapus/distributor-v6/src/libraries/JBVestingMath.sol";
import {JBClaimContext} from "@bananapus/distributor-v6/src/structs/JBClaimContext.sol";
import {JBVestingData} from "@bananapus/distributor-v6/src/structs/JBVestingData.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBStickyDistributor} from "./interfaces/IJBStickyDistributor.sol";
import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {JBStickyRewardRoundData} from "./structs/JBStickyRewardRoundData.sol";

/// @notice A singleton distributor that hands ERC-20 rewards (or native ETH) to the stakers of a sticky project with
/// linear vesting. Each round, a snapshot is taken of the funded amount and of the stake that shares it, and stakers
/// claim their pro-rata share lazily. Claimed tokens vest linearly over `VESTING_ROUNDS` rounds and can be collected
/// as they unlock.
/// @dev The `hook` in every function is the sticky token whose stakers are being rewarded. It MUST implement
/// `IJBActiveVotes` (a `JBStickyToken` does): the default group weighs each staker by their delegated voting power at
/// the funded round's snapshot block, and the round's denominator is the active-vote total at that same block.
/// @dev Funded rewards are assigned to the funding round. Holders claim historical rounds lazily; all unclaimed past
/// rewards begin vesting when the holder claims, not when the rewards were funded.
/// @dev Implements `IJBSplitHook` so it can receive tokens directly from Juicebox project payout splits.
contract JBStickyDistributor is IJBStickyDistributor {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an empty tokenIds array is passed.
    error JBStickyDistributor_EmptyTokenIds(uint256 tokenIdCount);

    /// @notice Thrown when the round duration is zero.
    error JBStickyDistributor_InvalidRoundDuration(uint256 roundDuration);

    /// @notice Thrown when a tokenId has non-zero upper bits (above 160), which would alias to the same holder
    /// address.
    error JBStickyDistributor_InvalidTokenId(uint256 tokenId);

    /// @notice Thrown when native ETH does not match the split hook context amount.
    error JBStickyDistributor_NativeAmountMismatch(uint256 msgValue, uint256 contextAmount);

    /// @notice Thrown when a native ETH transfer fails.
    error JBStickyDistributor_NativeTransferFailed(address beneficiary, uint256 amount);

    /// @notice Thrown when the caller does not have access to the token.
    error JBStickyDistributor_NoAccess(address hook, uint256 tokenId, address account);

    /// @notice Thrown when an ERC-20 reenters a funding balance-delta measurement.
    error JBStickyDistributor_ReentrantTokenTransfer(address token);

    /// @notice Thrown when native ETH is sent but context.token is not NATIVE_TOKEN.
    error JBStickyDistributor_TokenMismatch(address token, address expectedToken, uint256 msgValue);

    /// @notice Thrown when the caller is not a terminal or controller for the project.
    error JBStickyDistributor_Unauthorized(uint256 projectId, address caller);

    /// @notice Thrown when unexpected native ETH is sent with an ERC-20 operation.
    error JBStickyDistributor_UnexpectedNativeValue(uint256 msgValue, address token);

    /// @notice Thrown when a value cannot fit in a uint208 reward-round field.
    error JBStickyDistributor_Uint208Overflow(uint256 value);

    /// @notice Thrown when a value cannot fit in a uint48 field.
    error JBStickyDistributor_Uint48Overflow(uint256 value);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The number of shares that represent 100%.
    uint256 public constant MAX_SHARE = 100_000;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The number of seconds after a reward round becomes claimable before unclaimed rewards expire.
    /// @dev A zero duration means reward rounds do not expire.
    uint48 public immutable override CLAIM_DURATION;

    /// @notice The JB directory used to verify terminal/controller callers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The duration of each round, specified in seconds.
    uint256 public immutable override ROUND_DURATION;

    /// @notice The starting timestamp of the distributor.
    uint256 public immutable override STARTING_TIMESTAMP;

    /// @notice The hook that tracks the tranches and stick-age epochs of the sticky projects being rewarded.
    IJBStickyHook public immutable override STICKY_HOOK;

    /// @notice The number of rounds until tokens are fully vested.
    uint256 public immutable override VESTING_ROUNDS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The index within `vestingDataOf` of the latest vest.
    /// @custom:param hook The sticky token the tokenId belongs to.
    /// @custom:param groupId The reward group (0 = the default group).
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => uint256)))
    ) public latestVestedIndexOf;

    /// @notice The next reward round a staker has not yet claimed.
    /// @custom:param hook The sticky token whose stakers are claiming.
    /// @custom:param groupId The reward group (0 = the default group).
    /// @custom:param tokenId The encoded staker address.
    /// @custom:param token The reward token being claimed.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => uint256)))
    ) public nextClaimRoundOf;

    /// @notice Reward data assigned to each funding round.
    /// @custom:param hook The sticky token whose stakers receive rewards.
    /// @custom:param groupId The reward group (0 = the default group).
    /// @custom:param token The reward token.
    /// @custom:param round The reward round.
    mapping(
        address hook
            => mapping(uint256 groupId => mapping(IERC20 token => mapping(uint256 round => JBStickyRewardRoundData)))
    ) public rewardRoundOf;

    /// @notice The block number recorded as the snapshot point for each round.
    /// @dev Set to `block.number - 1` on first interaction in a round, so that `IVotes.getPastVotes` works.
    /// @custom:param round The round whose snapshot block is being recorded.
    mapping(uint256 round => uint256) public override roundSnapshotBlock;

    /// @notice The amount of a token that is currently vesting for a sticky token's stakers.
    /// @custom:param hook The sticky token whose stakers are vesting.
    /// @custom:param token The address of the token that is vesting.
    mapping(address hook => mapping(IERC20 token => uint256 amount)) public override totalVestingAmountOf;

    /// @notice All vesting data of a tokenId for any number of vesting tokens.
    /// @custom:param hook The sticky token the tokenId belongs to.
    /// @custom:param groupId The reward group (0 = the default group).
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => JBVestingData[])))
    ) public vestingDataOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The total accounted balance of each token across all sticky tokens.
    /// @custom:param token The token to check the accounted balance of.
    mapping(IERC20 token => uint256) internal _accountedBalanceOf;

    /// @notice The balance of a token held for a specific sticky token's stakers.
    /// @custom:param hook The sticky token whose balance to check.
    /// @custom:param token The token to check the balance of.
    mapping(address hook => mapping(IERC20 token => uint256)) internal _balanceOf;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice The ERC-20 whose incoming balance delta is currently being measured.
    address transient _acceptingToken;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The JB directory used to verify terminal/controller callers.
    /// @param stickyHook The hook that tracks the tranches and stick-age epochs of the sticky projects being rewarded.
    /// @param initialRoundDuration The duration of each round, specified in seconds.
    /// @param initialVestingRounds The number of rounds until tokens are fully vested.
    /// @param initialClaimDuration The number of seconds claimants have after each reward round becomes claimable.
    constructor(
        IJBDirectory directory,
        IJBStickyHook stickyHook,
        uint256 initialRoundDuration,
        uint256 initialVestingRounds,
        uint48 initialClaimDuration
    ) {
        if (initialRoundDuration == 0) {
            revert JBStickyDistributor_InvalidRoundDuration({roundDuration: initialRoundDuration});
        }
        CLAIM_DURATION = initialClaimDuration;
        DIRECTORY = directory;
        ROUND_DURATION = initialRoundDuration;
        STARTING_TIMESTAMP = block.timestamp;
        STICKY_HOOK = stickyHook;
        VESTING_ROUNDS = initialVestingRounds;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Allows the contract to receive native ETH (e.g. from payout splits).
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Begin vesting all unclaimed past reward rounds for the specified token IDs.
    /// @dev Permissionless. Materializes each token ID's pro-rata share of every past reward round into fresh vesting
    /// entries that start now and unlock over `VESTING_ROUNDS`. Current-round funding is excluded until a later round
    /// starts.
    /// @param hook The sticky token whose stakers are vesting.
    /// @param tokenIds The staker token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) external override {
        _beginVesting({hook: hook, groupId: 0, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Begin vesting any unclaimed past reward rounds, then collect everything that has since unlocked and
    /// transfer it to the beneficiary — so callers don't need to separately call `beginVesting`.
    /// @dev Authorized holders can collect to any beneficiary. Helpers can collect only to the canonical beneficiary
    /// for every token ID they do not control.
    /// @param hook The sticky token whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for.
    /// @param tokens The reward tokens to collect vested amounts of.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        _collectVestedRewards({hook: hook, groupId: 0, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary});
    }

    /// @notice Directly fund the distributor for a specific sticky token by pulling tokens from the caller. An
    /// alternative to split-based funding — useful for one-off deposits or external reward sources.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token. Uses balance
    /// delta to handle fee-on-transfer tokens correctly.
    /// @param hook The sticky token to fund (determines which staker pool receives the tokens).
    /// @param token The token to fund with.
    /// @param amount The amount to fund (ignored for native ETH — `msg.value` is used instead).
    function fund(address hook, IERC20 token, uint256 amount) external payable override {
        _fund({hook: hook, groupId: 0, token: token, amount: amount});
    }

    /// @notice Record the snapshot block for the current round (and eagerly for the next round). Callable by anyone —
    /// keepers or frontends can call this early in a round to lock the snapshot block before any claims occur.
    function poke() external override {
        uint256 round = currentRound();
        _ensureSnapshotBlockFor(round);

        // Eagerly lock the next round's snapshot to prevent first-caller manipulation.
        _ensureSnapshotBlockFor(round + 1);
    }

    /// @notice Receives tokens from a Juicebox payout split.
    /// @dev Only callable by a terminal or controller for the project in the context.
    /// @dev The sticky token being funded is read from `context.split.beneficiary`.
    /// @param context The split hook context from the terminal or controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Only terminals and controllers for the project can call this.
        if (
            !DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})
                && DIRECTORY.controllerOf(context.projectId) != IERC165(msg.sender)
        ) revert JBStickyDistributor_Unauthorized({projectId: context.projectId, caller: msg.sender});

        // The target sticky token is the split's beneficiary.
        address hook = address(context.split.beneficiary);

        // Native splits must conserve the terminal's stated context amount exactly.
        if (context.token == JBConstants.NATIVE_TOKEN) {
            if (msg.value != context.amount) {
                revert JBStickyDistributor_NativeAmountMismatch({msgValue: msg.value, contextAmount: context.amount});
            }

            if (msg.value != 0) {
                // Split-funded pots go to the default group (0).
                _recordRewardFunding({hook: hook, groupId: 0, token: IERC20(context.token), amount: msg.value});
            }
        } else {
            // Validate that native ETH is not cross-booked under an ERC-20 token.
            if (msg.value != 0) {
                revert JBStickyDistributor_TokenMismatch({
                    token: context.token, expectedToken: JBConstants.NATIVE_TOKEN, msgValue: msg.value
                });
            }

            if (context.amount == 0) return;

            // Pull tokens via transferFrom. Both terminals and controllers grant an ERC-20
            // allowance before calling. Balance delta handles fee-on-transfer tokens correctly.
            uint256 delta =
                _acceptErc20FundsFrom({token: IERC20(context.token), from: msg.sender, amount: context.amount});

            // Assign only the amount actually received to this round's reward pot (default group, 0).
            _recordRewardFunding({hook: hook, groupId: 0, token: IERC20(context.token), amount: delta});
        }
    }

    /// @notice Recycle unclaimed rewards from expired reward rounds into the current reward round.
    /// @dev Recycling is permissionless; any keeper or frontend can sweep an eligible prior round. Passing the current
    /// reward round is a no-op, even when its snapshot stake is zero.
    /// @param hook The sticky token whose expired rewards should be recycled.
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function recycleExpiredRewards(
        address hook,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        override
        returns (uint256 amount)
    {
        amount = _recycleExpiredRewards({hook: hook, groupId: 0, token: token, rounds: rounds});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The balance of a token held for a specific sticky token's stakers.
    /// @param hook The sticky token whose balance to check.
    /// @param token The token to check the balance of.
    function balanceOf(address hook, IERC20 token) external view override returns (uint256) {
        return _balanceOf[hook][token];
    }

    /// @notice Calculate the total amount of a reward token that has been claimed (began vesting) for a given
    /// staker token ID but has not yet been collected. Includes both locked (still vesting) and unlocked amounts.
    /// @param hook The sticky token the tokenId belongs to.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The total uncollected amount (vesting + vested-but-uncollected).
    function claimedFor(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount = _unclaimedVestingAmountOf({hook: hook, groupId: 0, tokenId: tokenId, token: token});
    }

    /// @notice Calculate how much of a reward token is currently unlocked and ready to be collected for a given
    /// staker token ID. Only includes the vested portion — excludes amounts still locked in vesting.
    /// @param hook The sticky token the tokenId belongs to.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now via `collectVestedRewards`.
    function collectableFor(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount = _collectableFor({hook: hook, groupId: 0, tokenId: tokenId, token: token});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The number of the current round.
    function currentRound() public view override returns (uint256) {
        return (block.timestamp - STARTING_TIMESTAMP) / ROUND_DURATION;
    }

    /// @notice The timestamp at which a round started.
    /// @param round The round to get the start timestamp of.
    function roundStartTimestamp(uint256 round) public view override returns (uint256) {
        return STARTING_TIMESTAMP + ROUND_DURATION * round;
    }

    /// @notice Indicates whether this contract supports the given interface.
    /// @param interfaceId The interface ID to check.
    /// @return A flag indicating support.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBStickyDistributor).interfaceId || interfaceId == type(IJBSplitHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accepts an ERC-20 funding transfer and returns the actual balance delta.
    /// @param token The ERC-20 token to accept.
    /// @param from The address to pull tokens from.
    /// @param amount The nominal amount to pull.
    /// @return acceptedAmount The actual amount received.
    function _acceptErc20FundsFrom(
        IERC20 token,
        address from,
        uint256 amount
    )
        internal
        returns (uint256 acceptedAmount)
    {
        // Arm the scoped guard before any token call, including `balanceOf`, because reward tokens are arbitrary and
        // an upgradeable or adversarial token can reenter from either the snapshot or transfer path.
        address tokenBeingAccepted = _acceptingToken;
        if (tokenBeingAccepted != address(0)) revert JBStickyDistributor_ReentrantTokenTransfer(tokenBeingAccepted);
        _acceptingToken = address(token);

        // Snapshot this contract's token balance after the guard is armed so fee-on-transfer tokens are credited by the
        // actual amount received instead of the caller-provided nominal `amount`.
        uint256 balanceBefore = token.balanceOf(address(this));

        // Pull the nominal amount from the funder; SafeERC20 handles tokens that do not return a boolean.
        token.safeTransferFrom({from: from, to: address(this), value: amount});

        // Credit only the balance delta. This supports fee-on-transfer tokens and ignores any overstatement in
        // `amount`.
        acceptedAmount = token.balanceOf(address(this)) - balanceBefore;

        // Close the transfer window after the token balance has been measured.
        _acceptingToken = address(0);
    }

    /// @notice Shared begin-vesting logic across reward groups.
    /// @param hook The sticky token whose stakers are vesting.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenIds The staker token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function _beginVesting(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
    {
        // Reward accounting cannot change while an ERC-20 `transferFrom` is in progress.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBStickyDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Validate token IDs before a permissionless helper can materialize vesting state.
        _validateTokenIds({hook: hook, tokenIds: tokenIds});

        // Materialize all unclaimed historical reward rounds into fresh vesting entries that start now.
        _claimPastRewards({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Claim all past reward rounds for the given token IDs and reward tokens into fresh vesting entries.
    /// @param hook The sticky token whose stakers are claiming.
    /// @param groupId The reward group being claimed (0 = the default group).
    /// @param tokenIds The encoded staker addresses to claim for.
    /// @param tokens The reward tokens to claim.
    function _claimPastRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
    {
        // Round 0 has no completed reward rounds behind it, so nothing can be claimed yet.
        uint256 round = currentRound();
        if (round == 0) return;

        // Current-round funding is excluded. It becomes claimable only after a later round starts. Sticky stakers have
        // no tier concept, so `tierIds` stays empty; the group only isolates reward storage.
        JBClaimContext memory ctx = JBClaimContext({
            hook: hook,
            groupId: groupId,
            tierIds: new uint256[](0),
            lastClaimableRound: round - 1,
            vestingReleaseRound: round + VESTING_ROUNDS
        });

        // Process each reward token independently because each token has its own round funding and claim cursor.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];
            uint256 totalVestingAmount;

            // Materialize this reward token for every staker address encoded in tokenIds.
            for (uint256 j; j < tokenIds.length;) {
                uint256 tokenId = tokenIds[j];
                uint256 tokenAmount = _claimPastRewardsForTokenId({ctx: ctx, tokenId: tokenId, token: token});

                // Accumulate once per reward token so totalVestingAmountOf is updated with one storage write.
                totalVestingAmount += tokenAmount;

                unchecked {
                    ++j;
                }
            }

            // Track the newly claimed amount as vesting, so later collections unlock against it over time.
            if (totalVestingAmount != 0) totalVestingAmountOf[hook][token] += totalVestingAmount;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claim all past reward rounds for one token ID into one fresh vesting entry.
    /// @param ctx The claim-round context.
    /// @param tokenId The encoded staker address to claim for.
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
        // Load this staker's cursor for the reward token. All earlier rounds have already been settled.
        uint256 nextClaimRound = nextClaimRoundOf[ctx.hook][ctx.groupId][tokenId][token];

        // If the cursor is already past the last completed round, this staker is current.
        if (nextClaimRound > ctx.lastClaimableRound) return 0;

        // Sum this staker's pro-rata share from every resolved completed reward round.
        uint256 newNextClaimRound;
        (tokenAmount, newNextClaimRound) = _claimRewardsFor({
            hook: ctx.hook,
            groupId: ctx.groupId,
            tokenId: tokenId,
            token: token,
            firstRound: nextClaimRound,
            lastRound: ctx.lastClaimableRound
        });

        // Advance the cursor through resolved rounds.
        nextClaimRoundOf[ctx.hook][ctx.groupId][tokenId][token] = newNextClaimRound;

        // Avoid writing empty vesting entries when no past round allocates rewards to this staker.
        if (tokenAmount == 0) return 0;

        // All accumulated past rewards start a single fresh vesting schedule at the claim round.
        vestingDataOf[ctx.hook][ctx.groupId][tokenId][token].push(
            JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmount, shareClaimed: 0})
        );

        // Emit once per staker and reward token so offchain systems can track the materialized vesting entry.
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

    /// @notice Claim one reward round using its recorded denominator.
    /// @param hook The sticky token whose stakers are claiming.
    /// @param tokenId The encoded staker address.
    /// @param rewardRound The stored reward-round data.
    /// @return tokenAmount The amount added to vesting.
    function _claimRewardRoundFor(
        address hook,
        uint256 tokenId,
        JBStickyRewardRoundData storage rewardRound
    )
        internal
        returns (uint256 tokenAmount)
    {
        // Empty-denominator rounds have no pro-rata basis, so they cannot allocate rewards to any staker.
        if (rewardRound.totalStake == 0) return 0;

        // Use the funding round's snapshot block, not the block at which the staker finally claims.
        uint256 tokenStakeAmount = _tokenStakeAt({hook: hook, tokenId: tokenId, blockNumber: rewardRound.snapshotBlock});

        // Zero-vote stakers advance their cursor but do not consume reward inventory.
        if (tokenStakeAmount == 0) return 0;

        // The round's reward pot is split pro-rata across checkpointed voting power.
        uint256 claimAmount = mulDiv({x: rewardRound.amount, y: tokenStakeAmount, denominator: rewardRound.totalStake});

        // Ignore floor-rounded zero claims to avoid unnecessary storage writes.
        if (claimAmount == 0) return 0;

        // Track the portion that has started vesting so expiry recycles only the remainder.
        rewardRound.claimedAmount = _toUint208(uint256(rewardRound.claimedAmount) + claimAmount);

        // Return the exact amount that the caller should append to the staker's vesting entry.
        tokenAmount = claimAmount;
    }

    /// @notice Claim a staker's unclaimed rewards across a range of historical reward rounds.
    /// @param hook The sticky token whose stakers are claiming.
    /// @param groupId The reward group being claimed (0 = the default group).
    /// @param tokenId The encoded staker address.
    /// @param token The reward token.
    /// @param firstRound The first reward round to include.
    /// @param lastRound The last reward round to include.
    /// @return tokenAmount The cumulative unclaimed reward amount.
    /// @return newNextClaimRound The next reward round this staker has not yet resolved.
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
        newNextClaimRound = lastRound + 1;

        // Walk every unclaimed historical round. The caller bounds this to completed rounds only.
        for (uint256 rewardRoundNumber = firstRound; rewardRoundNumber <= lastRound;) {
            // Load this round's reward data for the sticky token, group, and reward token.
            JBStickyRewardRoundData storage rewardRound = rewardRoundOf[hook][groupId][token][rewardRoundNumber];

            // Skip rounds that never received funding.
            if (rewardRound.amount != 0) {
                // Expired rounds forfeit unmaterialized inventory into the current active-voter set.
                if (_rewardRoundExpired(rewardRound)) {
                    _recycleExpiredRewardRound({hook: hook, groupId: groupId, token: token, round: rewardRoundNumber});
                } else {
                    // Live rounds can still be materialized by snapshot voters into fresh vesting entries.
                    tokenAmount += _claimRewardRoundFor({hook: hook, tokenId: tokenId, rewardRound: rewardRound});
                }
            }

            unchecked {
                ++rewardRoundNumber;
            }
        }
    }

    /// @notice Shared begin-vesting-then-collect logic across reward groups.
    /// @param hook The sticky token whose stakers are collecting.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenIds The token IDs to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function _collectVestedRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        internal
    {
        // Collections transfer reward tokens out; block them mid inbound transfer.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBStickyDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Validate token IDs before a permissionless helper can materialize vesting state.
        _validateTokenIds({hook: hook, tokenIds: tokenIds});

        // Only authorized holders can redirect rewards; helpers must send them to the canonical beneficiary.
        _requireCanCollectTo({hook: hook, tokenIds: tokenIds, beneficiary: beneficiary});

        // Before collecting, bring the token IDs current by starting vesting for any past reward rounds.
        _claimPastRewards({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens});

        // Release whatever portion of vesting entries has unlocked by this round.
        _unlockRewards({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary});
    }

    /// @notice Ensures that a snapshot block is recorded for exactly the given round.
    /// @dev Uses `block.number - 1` because `IVotes.getPastVotes` requires a strictly past block. Funding uses this to
    /// assign rewards to the funding round without also freezing the next round earlier than necessary.
    /// @param round The round to ensure a snapshot block for.
    /// @return snapshotBlock The snapshot block recorded for the round.
    function _ensureSnapshotBlockFor(uint256 round) internal returns (uint256 snapshotBlock) {
        snapshotBlock = roundSnapshotBlock[round];
        if (snapshotBlock == 0) {
            snapshotBlock = block.number - 1;
            roundSnapshotBlock[round] = snapshotBlock;
            emit RoundSnapshotRecorded({round: round, snapshotBlock: snapshotBlock, caller: msg.sender});
        }
    }

    /// @notice Accept funds and assign them to this round's reward ledger.
    /// @param hook The sticky token whose stakers receive the rewards.
    /// @param groupId The reward group being funded (0 = the default group).
    /// @param token The reward token being funded.
    /// @param amount The nominal amount to fund.
    function _fund(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Native funding is measured by msg.value, not the caller-provided amount.
        if (address(token) == JBConstants.NATIVE_TOKEN) {
            amount = msg.value;
        } else {
            // ERC-20 funding must not carry native ETH.
            if (msg.value != 0) {
                revert JBStickyDistributor_UnexpectedNativeValue({msgValue: msg.value, token: address(token)});
            }

            // ERC-20 funding is measured by balance delta so fee-on-transfer tokens are accounted correctly.
            amount = _acceptErc20FundsFrom({token: token, from: msg.sender, amount: amount});
        }

        // Store the accepted amount in this round's historical reward ledger.
        _recordRewardFunding({hook: hook, groupId: groupId, token: token, amount: amount});
    }

    /// @notice Record accepted funding as the current round's reward pot.
    /// @param hook The sticky token whose stakers receive the rewards.
    /// @param groupId The reward group (0 = the default group).
    /// @param token The reward token.
    /// @param amount The accepted funding amount.
    function _recordRewardFunding(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Zero-value transfers do not create reward rounds or alter tracked balances.
        if (amount == 0) return;

        // Add the accepted amount to the current reward ledger.
        _recordRewardRound({hook: hook, groupId: groupId, token: token, amount: amount});

        // Keep the distributor's balance accounting in sync for collection and conservation checks. Balances
        // are tracked per (hook, token) across all groups because they share one token custody pool.
        _balanceOf[hook][token] += amount;
        _accountedBalanceOf[token] += amount;
    }

    /// @notice Record rewards as the current round's claimable historical reward pot.
    /// @param hook The sticky token whose stakers receive the rewards.
    /// @param groupId The reward group (0 = the default group).
    /// @param token The reward token.
    /// @param amount The amount to add to the current reward round.
    function _recordRewardRound(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Zero-value rewards do not create reward rounds.
        if (amount == 0) return;

        // Rewards belong to the round in progress when they enter the ledger.
        uint256 round = currentRound();

        // Load the current round's ledger entry for this sticky token, group, and reward token.
        JBStickyRewardRoundData storage rewardRound = rewardRoundOf[hook][groupId][token][round];

        // Every reward round in this contract uses the same immutable claim duration.
        uint48 claimDeadline = _claimDeadlineFor(round);

        // First value in a round locks that round's snapshot block and total stake.
        if (rewardRound.amount == 0) {
            // Record the exact historical block used for all stake lookups in this round.
            uint256 snapshotBlock = _ensureSnapshotBlockFor(round);

            // Store the snapshot block in the packed uint48 field.
            rewardRound.snapshotBlock = _toUint48(snapshotBlock);

            // Store the packed claim deadline fixed for this distributor.
            rewardRound.claimDeadline = claimDeadline;

            // Store the packed total stake that shares this group's round reward pot.
            rewardRound.totalStake = _toUint208(_totalStake({hook: hook, blockNumber: snapshotBlock}));
        }

        // Multiple additions in the same round share the same snapshot and reward pot.
        rewardRound.amount = _toUint208(uint256(rewardRound.amount) + amount);
    }

    /// @notice Shared expired-reward recycling logic across reward groups.
    /// @param hook The sticky token whose expired rewards should be recycled.
    /// @param groupId The reward group (0 = the default group).
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function _recycleExpiredRewards(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256[] calldata rounds
    )
        internal
        returns (uint256 amount)
    {
        // Do not let reward-token callbacks recycle inventory during an inbound balance-delta measurement.
        _requireNotAcceptingToken();

        // Process every requested round independently so callers can batch keeper work.
        for (uint256 i; i < rounds.length;) {
            amount += _recycleExpiredRewardRound({hook: hook, groupId: groupId, token: token, round: rounds[i]});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Recycle one expired reward round's unclaimed inventory into the current reward round.
    /// @param hook The sticky token whose expired rewards should be recycled.
    /// @param groupId The reward group (0 = the default group).
    /// @param token The reward token to recycle.
    /// @param round The reward round to recycle.
    /// @return recycleAmount The amount recycled.
    function _recycleExpiredRewardRound(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256 round
    )
        internal
        returns (uint256 recycleAmount)
    {
        // Never recycle a round into itself. This keeps raw round accounting stable for zero-stake current rounds; the
        // same inventory can be swept once a later round is current.
        uint256 recycledToRound = currentRound();
        if (round == recycledToRound) return 0;

        // Load the reward round once so expiry, claimed amount, and funded amount stay in sync.
        JBStickyRewardRoundData storage rewardRound = rewardRoundOf[hook][groupId][token][round];

        // Ignore rounds that have not reached their deadline yet — UNLESS the round can never be claimed because its
        // snapshot `totalStake` is zero (e.g. funded before anyone staked). Such a round's funds are unclaimable;
        // gating recycle on expiry would strand them forever when `CLAIM_DURATION == 0` (a zero deadline never
        // expires), so allow recycling a zero-stake round regardless of deadline. There is no claimant to protect.
        if (!_rewardRoundExpired(rewardRound) && rewardRound.totalStake != 0) return 0;

        // If prior claims have already materialized the whole round, there is nothing left to recycle.
        if (rewardRound.claimedAmount >= rewardRound.amount) return 0;

        // Recycle only the unclaimed remainder, preserving amounts that already started vesting.
        recycleAmount = uint256(rewardRound.amount) - uint256(rewardRound.claimedAmount);

        // Mark the whole round settled before writing the recycled amount into a fresh round.
        rewardRound.claimedAmount = rewardRound.amount;

        // Keep the inventory in the distributor and give the current staker set a new claimable round.
        _recordRewardRound({hook: hook, groupId: groupId, token: token, amount: recycleAmount});

        // Surface the permissionless recycle for off-chain accounting.
        emit ExpiredRewardsRecycled({
            hook: hook,
            fromRound: round,
            toRound: recycledToRound,
            token: token,
            amount: recycleAmount,
            caller: msg.sender
        });
    }

    /// @notice Unlocks the vested portion of rewards for the given token IDs and tokens, and transfers it out.
    /// @param hook The sticky token the token IDs belong to.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param tokens The addresses of the tokens to unlock.
    /// @param beneficiary The recipient of the unlocked tokens.
    function _unlockRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        internal
    {
        uint256 round = currentRound();

        // Loop through each token for which vested rewards are being collected.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Process all token IDs for this reward token.
            uint256 totalTokenAmount =
                _unlockTokenIds({hook: hook, groupId: groupId, tokenIds: tokenIds, token: token, round: round});

            // Perform the transfer.
            if (totalTokenAmount != 0) {
                unchecked {
                    // Update the amount that is left vesting.
                    totalVestingAmountOf[hook][token] -= totalTokenAmount;
                }

                // Decrement the sticky token's balance and transfer tokens out.
                _balanceOf[hook][token] -= totalTokenAmount;
                _accountedBalanceOf[token] -= totalTokenAmount;

                if (address(token) == JBConstants.NATIVE_TOKEN) {
                    (bool success,) = beneficiary.call{value: totalTokenAmount}("");
                    if (!success) {
                        revert JBStickyDistributor_NativeTransferFailed({
                            beneficiary: beneficiary, amount: totalTokenAmount
                        });
                    }
                } else {
                    token.safeTransfer({to: beneficiary, value: totalTokenAmount});
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unlocks rewards for a set of token IDs for a single reward token.
    /// @param hook The sticky token the token IDs belong to.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param token The reward token to unlock.
    /// @param round The current round.
    /// @return totalTokenAmount The total amount of reward tokens unlocked.
    function _unlockTokenIds(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20 token,
        uint256 round
    )
        internal
        returns (uint256 totalTokenAmount)
    {
        for (uint256 j; j < tokenIds.length;) {
            uint256 tokenId = tokenIds[j];

            // Keep a reference to the latest vested index.
            uint256 vestedIndex = latestVestedIndexOf[hook][groupId][tokenId][token];

            // Keep a reference to the vesting data array.
            JBVestingData[] storage vestings = vestingDataOf[hook][groupId][tokenId][token];
            uint256 numberOfVestingRounds = vestings.length;

            // Keep a reference to a vested index that will be incremented.
            uint256 newLatestVestedIndex = vestedIndex;

            while (vestedIndex < numberOfVestingRounds) {
                // Keep a reference to the vested data being iterated on.
                JBVestingData memory vesting = vestings[vestedIndex];

                uint256 lockedShare = JBVestingMath.lockedShareOf({
                    releaseRound: vesting.releaseRound,
                    currentRound: round,
                    vestingRounds: VESTING_ROUNDS,
                    maxShare: MAX_SHARE
                });

                // Match `claimedFor`/`collectableFor` by using the difference between cumulative rounded claims.
                // Rounding each incremental share independently can underpay partial unlocks and leave
                // `totalVestingAmountOf` larger than the remaining claims.
                (uint256 claimAmount,) = JBVestingMath.newlyClaimableAmountOf({
                    amount: vesting.amount,
                    shareClaimed: vesting.shareClaimed,
                    lockedShare: lockedShare,
                    maxShare: MAX_SHARE
                });

                if (claimAmount != 0) {
                    // Persist the cumulative unlocked share, not just this round's delta, so later collections
                    // compare against the same rounded checkpoint that produced `claimAmount`.
                    vestings[vestedIndex].shareClaimed = MAX_SHARE - lockedShare;
                    totalTokenAmount += claimAmount;
                    emit Collected({
                        hook: hook,
                        tokenId: tokenId,
                        groupId: groupId,
                        token: token,
                        amount: claimAmount,
                        vestingReleaseRound: vesting.releaseRound,
                        caller: msg.sender
                    });
                }

                unchecked {
                    ++vestedIndex;

                    // Only advance the latest-vested index contiguously past fully exhausted entries.
                    // An entry is exhausted only when its entire share has been claimed (lockedShare == 0).
                    if (
                        lockedShare == 0 && vestings[vestedIndex - 1].shareClaimed == MAX_SHARE
                            && vestedIndex == newLatestVestedIndex + 1
                    ) {
                        ++newLatestVestedIndex;
                    }
                }
            }

            latestVestedIndexOf[hook][groupId][tokenId][token] = newLatestVestedIndex;

            unchecked {
                ++j;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Check if the account matches the staker address encoded in the token ID.
    /// @dev The token ID encodes the staker address as `uint256(uint160(stakerAddress))`.
    /// @param hook Unused — access is determined by the tokenId encoding.
    /// @param tokenId The encoded staker address.
    /// @param account The account to check.
    /// @return canClaim True if the account matches the encoded address.
    function _canClaim(address hook, uint256 tokenId, address account) internal pure returns (bool canClaim) {
        canClaim = _claimBeneficiaryOf({hook: hook, tokenId: tokenId}) == account;
    }

    /// @notice The deadline for a reward round using this distributor's immutable claim duration.
    /// @param round The reward round.
    /// @return claimDeadline The deadline timestamp. Zero means no expiration.
    function _claimDeadlineFor(uint256 round) internal view returns (uint48 claimDeadline) {
        // A zero claim duration means the round never expires.
        if (CLAIM_DURATION == 0) return 0;

        // Start the window at the next round boundary, when the funded round first becomes claimable.
        claimDeadline = _toUint48(roundStartTimestamp(round + 1) + CLAIM_DURATION);
    }

    /// @notice The encoded staker address that receives permissionless collections.
    /// @dev Reverts on high-bit aliasing so every token ID maps to exactly one address.
    /// @param hook Unused — the beneficiary is determined by the token ID encoding.
    /// @param tokenId The encoded staker address.
    /// @return beneficiary The staker address encoded in `tokenId`.
    function _claimBeneficiaryOf(address hook, uint256 tokenId) internal pure returns (address beneficiary) {
        hook; // Silence unused variable warning.
        if (tokenId >> 160 != 0) revert JBStickyDistributor_InvalidTokenId({tokenId: tokenId});
        // The high bits were checked above, so this cast recovers the encoded address.
        // forge-lint: disable-next-line(unsafe-typecast)
        beneficiary = address(uint160(tokenId));
    }

    /// @notice The collectable (unlocked, uncollected) amount for a token ID in a specific reward group.
    /// @param hook The sticky token the tokenId belongs to.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now.
    function _collectableFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        internal
        view
        returns (uint256 tokenAmount)
    {
        // The round that we are in right now.
        uint256 round = currentRound();

        // Keep a reference to the latest vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][groupId][tokenId][token];

        // Keep a reference to the vesting data array.
        JBVestingData[] storage vestings = vestingDataOf[hook][groupId][tokenId][token];
        uint256 numberOfVestingRounds = vestings.length;

        while (vestedIndex < numberOfVestingRounds) {
            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestings[vestedIndex];

            uint256 lockedShare = JBVestingMath.lockedShareOf({
                releaseRound: vesting.releaseRound,
                currentRound: round,
                vestingRounds: VESTING_ROUNDS,
                maxShare: MAX_SHARE
            });

            // Calculate the newly unlocked amount from cumulative shares rather than the incremental share delta.
            // Incremental floor rounding can otherwise underpay partial collections and leave dust stranded.
            (uint256 claimAmount,) = JBVestingMath.newlyClaimableAmountOf({
                amount: vesting.amount,
                shareClaimed: vesting.shareClaimed,
                lockedShare: lockedShare,
                maxShare: MAX_SHARE
            });
            tokenAmount += claimAmount;

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice Revert unless the caller can collect the requested token IDs to the beneficiary.
    /// @dev A caller that controls a token ID can route that token ID's collected rewards anywhere. A helper that
    /// does not control the token ID can only collect to that token ID's canonical beneficiary.
    /// @param hook The sticky token the token IDs belong to.
    /// @param tokenIds The token IDs whose collected rewards will be transferred.
    /// @param beneficiary The address that will receive the collected rewards.
    function _requireCanCollectTo(address hook, uint256[] calldata tokenIds, address beneficiary) internal view {
        for (uint256 i; i < tokenIds.length;) {
            uint256 tokenId = tokenIds[i];

            // Holders can choose any beneficiary for token IDs they control.
            if (!_canClaim({hook: hook, tokenId: tokenId, account: msg.sender})) {
                // Helpers can only send rewards to the token ID's canonical beneficiary.
                if (beneficiary != _claimBeneficiaryOf({hook: hook, tokenId: tokenId})) {
                    revert JBStickyDistributor_NoAccess({hook: hook, tokenId: tokenId, account: msg.sender});
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Revert if called while an inbound ERC-20 transfer is being measured.
    /// @dev Reward tokens are arbitrary contracts. This guard prevents token callbacks from mutating distributor
    /// accounting midway through a balance-delta measurement.
    function _requireNotAcceptingToken() internal view {
        address token = _acceptingToken;
        if (token != address(0)) revert JBStickyDistributor_ReentrantTokenTransfer(token);
    }

    /// @notice Whether a reward round has passed its claim deadline.
    /// @param rewardRound The reward round data.
    /// @return expired True if unclaimed rewards can be recycled.
    function _rewardRoundExpired(JBStickyRewardRoundData storage rewardRound) internal view returns (bool expired) {
        // Copy the packed deadline into memory so the zero check and timestamp compare use the same value.
        uint48 claimDeadline = rewardRound.claimDeadline;

        // A zero deadline never expires; non-zero deadlines expire at or after the configured timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        expired = claimDeadline != 0 && block.timestamp >= claimDeadline;
    }

    /// @notice The delegated voting power of a staker at an explicit snapshot block.
    /// @param hook The sticky token being staked.
    /// @param tokenId The encoded staker address.
    /// @param blockNumber The historical block to query.
    /// @return tokenStakeAmount The delegated voting power at `blockNumber`.
    function _tokenStakeAt(
        address hook,
        uint256 tokenId,
        uint256 blockNumber
    )
        internal
        view
        returns (uint256 tokenStakeAmount)
    {
        // Reject aliases where high bits would be truncated by the address cast below.
        if (tokenId >> 160 != 0) revert JBStickyDistributor_InvalidTokenId({tokenId: tokenId});

        // The high bits were checked above, so this cast recovers the encoded address.
        // forge-lint: disable-next-line(unsafe-typecast)
        address account = address(uint160(tokenId));

        // Query the staker's delegated votes at the reward round's fixed snapshot block.
        tokenStakeAmount = IVotes(hook).getPastVotes({account: account, timepoint: blockNumber});
    }

    /// @notice The total stake denominator recorded when a reward round is first funded.
    /// @dev Always uses `IJBActiveVotes.getPastTotalActiveVotes`, so undelegated balances do not share rewards.
    /// `CLAIM_DURATION` only controls whether unmaterialized allocations can expire.
    /// @param hook The sticky token being staked.
    /// @param blockNumber The block number to get the active total at.
    /// @return totalStakedAmount The stake denominator to record for the funded round.
    function _totalStake(address hook, uint256 blockNumber) internal view returns (uint256 totalStakedAmount) {
        // All reward rounds split only across units delegated to nonzero delegates at the snapshot block.
        totalStakedAmount = IJBActiveVotes(hook).getPastTotalActiveVotes(blockNumber);
    }

    /// @notice Cast a reward-round value to uint208.
    /// @param value The value to cast.
    /// @return castValue The cast value.
    function _toUint208(uint256 value) internal pure returns (uint208 castValue) {
        if (value > type(uint208).max) revert JBStickyDistributor_Uint208Overflow({value: value});
        // forge-lint: disable-next-line(unsafe-typecast)
        castValue = uint208(value);
    }

    /// @notice Cast a value to uint48.
    /// @param value The value to cast.
    /// @return castValue The cast value.
    function _toUint48(uint256 value) internal pure returns (uint48 castValue) {
        if (value > type(uint48).max) revert JBStickyDistributor_Uint48Overflow({value: value});
        // forge-lint: disable-next-line(unsafe-typecast)
        castValue = uint48(value);
    }

    /// @notice The remaining uncollected vesting amount for one token ID and reward token.
    /// @param hook The sticky token the token ID belongs to.
    /// @param groupId The reward group (0 = the default group).
    /// @param tokenId The token ID to check.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount still locked or unlocked-but-uncollected.
    function _unclaimedVestingAmountOf(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        internal
        view
        returns (uint256 tokenAmount)
    {
        // Keep a reference to the latest fully vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][groupId][tokenId][token];

        // Keep a reference to the vesting data array.
        JBVestingData[] storage vestings = vestingDataOf[hook][groupId][tokenId][token];
        uint256 numberOfVestingRounds = vestings.length;

        while (vestedIndex < numberOfVestingRounds) {
            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestings[vestedIndex];

            // Use `original - alreadyPaid` to include rounding dust in the remaining amount.
            tokenAmount += JBVestingMath.unclaimedAmountOf({
                amount: vesting.amount, shareClaimed: vesting.shareClaimed, maxShare: MAX_SHARE
            });

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice Revert unless every token ID can be decoded as a staker address.
    /// @param hook The sticky token whose staker slots are being validated.
    /// @param tokenIds The encoded staker addresses to validate.
    function _validateTokenIds(address hook, uint256[] calldata tokenIds) internal pure {
        // Permissionless helpers can start vesting for any valid encoded staker slot.
        for (uint256 i; i < tokenIds.length;) {
            _claimBeneficiaryOf({hook: hook, tokenId: tokenIds[i]});

            unchecked {
                ++i;
            }
        }
    }
}
