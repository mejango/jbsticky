// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBDistributor} from "@bananapus/distributor-v6/src/JBDistributor.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {IJBTokenDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBTokenDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {JBStickyToken} from "../src/JBStickyToken.sol";
import {IJBStickyDistributor} from "../src/interfaces/IJBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";

/// @notice An 18-decimal ERC-20 standing in for a token that gets staked or handed out as a reward.
contract MockErc20 is ERC20 {
    uint256 public feeBps; // taken out of every transfer when non-zero

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        if (fee != 0 && from != address(0) && to != address(0)) {
            super._update({from: from, to: address(0xdead), value: fee});
            value -= fee;
        }
        super._update({from: from, to: to, value: value});
    }
}

/// @notice Unit coverage for the Sticky distributor: default-group parity with the stock token distributor, tenure
/// windows pinned at round start, split routing, and funding validation.
/// @dev Rounds last one day and the distributor starts on a week boundary, so a round that starts `n` weeks after
/// `_start` has snapshot epoch `_startEpoch + n`.
contract JBStickyDistributorUnitTest is TestBaseWorkflow {
    uint256 constant ROUND_DURATION = 1 days;
    uint256 constant VESTING_ROUNDS = 2;
    uint48 constant CLAIM_DURATION = 30 days;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address funder = makeAddr("funder");

    MockErc20 staked;
    MockErc20 reward;
    JBStickyDeployer deployer;
    IJBStickyHook hook;
    JBStickyDistributor distributor;
    uint256 projectId;
    IJBToken stickyToken;
    uint256 _start;
    uint256 _startEpoch;

    function setUp() public override {
        super.setUp();

        staked = new MockErc20("Staked", "STK");
        reward = new MockErc20("Reward", "RWD");

        deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        hook = deployer.HOOK();

        // Deploy a sticky project for the staked token, forwarding the project creation fee.
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Sticky",
            symbol: "STICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        stickyToken = jbTokens().tokenOf(projectId);

        // Start the distributor on a week boundary so day-long rounds line up with epochs.
        _start = (vm.getBlockTimestamp() / 1 weeks + 1) * 1 weeks;
        _startEpoch = _start / 1 weeks;
        vm.warp(_start);
        vm.roll(vm.getBlockNumber() + 1);

        distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: hook,
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: CLAIM_DURATION
        });
    }

    //*********************************************************************//
    // ------------------------------ helpers ---------------------------- //
    //*********************************************************************//

    /// @notice Warps to one second into the round that starts `weeks_` weeks after the distributor started.
    function _warpWeeks(uint256 weeks_) internal {
        vm.warp(_start + weeks_ * 1 weeks + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice Stake `amount` of the underlying for `holder`, minting them an equal count of sticky tokens.
    function _stake(address holder, uint256 amount) internal {
        _stakeIn({holder: holder, amount: amount, targetProjectId: projectId});
    }

    function _stakeIn(address holder, uint256 amount, uint256 targetProjectId) internal {
        staked.mint({to: holder, amount: amount});
        vm.startPrank(holder);
        staked.approve({spender: address(jbMultiTerminal()), value: amount});
        jbMultiTerminal().pay({
            projectId: targetProjectId,
            token: address(staked),
            amount: amount,
            beneficiary: holder,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
    }

    /// @notice Unstake `count` sticky tokens for `holder`.
    function _unstake(address holder, uint256 count) internal {
        vm.prank(holder);
        jbMultiTerminal().cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: address(staked),
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: bytes("")
        });
    }

    function _tokenIds(address holder) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
    }

    function _rewardTokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));
    }

    function _nativeTokens() internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);
    }

    /// @notice A payout-split context routing `amount` of `token` to the sticky token's holders.
    function _splitContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory context) {
        context = _splitContext({token: token, amount: amount, groupId: 0, lockedUntil: 0});
    }

    /// @notice A payout-split context carrying `groupId` on the split's `projectId`, optionally locked.
    function _splitContext(
        address token,
        uint256 amount,
        uint64 groupId,
        uint48 lockedUntil
    )
        internal
        view
        returns (JBSplitHookContext memory context)
    {
        context = JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: uint256(uint160(token)),
            split: JBSplit({
                percent: 0,
                projectId: groupId,
                beneficiary: payable(address(stickyToken)),
                preferAddToBalance: false,
                lockedUntil: lockedUntil,
                hook: IJBSplitHook(address(distributor))
            })
        });
    }

    /// @notice Routes `amount` of the reward token through a payout split carrying `groupId`, as the terminal.
    function _processSplitWithGroup(uint256 amount, uint64 groupId) internal {
        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: amount});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: amount});
        distributor.processSplitWith(
            _splitContext({token: address(reward), amount: amount, groupId: groupId, lockedUntil: 0})
        );
        vm.stopPrank();
    }

    /// @notice The current round's pot and denominator for a group and reward token.
    function _currentRewardRoundOf(
        address token,
        uint256 groupId
    )
        internal
        view
        returns (uint208 amount, uint208 totalStake)
    {
        (amount,,,, totalStake) =
            distributor.rewardRoundOf(address(stickyToken), groupId, IERC20(token), distributor.currentRound());
    }

    function _fund(uint256 amount) internal {
        reward.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: amount});
        distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount});
        vm.stopPrank();
    }

    /// @notice Fund `amount` of the reward token into a group's pot for the sticky token.
    function _fundGroup(uint256 amount, uint256 groupId) internal {
        reward.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: amount});
        distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount, groupId: groupId});
        vm.stopPrank();
    }

    function _beginVestingFor(address holder) internal {
        distributor.beginVesting({hook: address(stickyToken), tokenIds: _tokenIds(holder), tokens: _rewardTokens()});
    }

    /// @notice Collect everything unlocked for `holder`, returning the amount that landed in their wallet.
    function _collectFor(address holder) internal returns (uint256 collected) {
        uint256 balanceBefore = reward.balanceOf(holder);
        distributor.collectVestedRewards({
            hook: address(stickyToken), tokenIds: _tokenIds(holder), tokens: _rewardTokens(), beneficiary: holder
        });
        collected = reward.balanceOf(holder) - balanceBefore;
    }

    function _beginVestingGroupFor(address holder, uint256 groupId) internal {
        distributor.beginVesting({
            hook: address(stickyToken), groupId: groupId, tokenIds: _tokenIds(holder), tokens: _rewardTokens()
        });
    }

    function _collectGroupFor(address holder, uint256 groupId) internal returns (uint256 collected) {
        uint256 balanceBefore = reward.balanceOf(holder);
        distributor.collectVestedRewards({
            hook: address(stickyToken),
            groupId: groupId,
            tokenIds: _tokenIds(holder),
            tokens: _rewardTokens(),
            beneficiary: holder
        });
        collected = reward.balanceOf(holder) - balanceBefore;
    }

    function _collectableGroupFor(address holder, uint256 groupId) internal view returns (uint256) {
        return distributor.collectableFor(address(stickyToken), groupId, uint256(uint160(holder)), reward);
    }

    /// @notice Launch a transferable Sticky project for the staked token, so its shares can be handed out as rewards.
    function _launchOpenProject() internal returns (uint256 openProjectId, IJBToken openToken) {
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        openProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Open Sticky",
            symbol: "OSTICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        openToken = jbTokens().tokenOf(openProjectId);
    }

    /// @notice Alice funds `amount` of the open project's shares as a default-group reward for the first project.
    function _fundShares(IJBToken openToken, uint256 amount) internal {
        vm.startPrank(alice);
        IERC20(address(openToken)).approve({spender: address(distributor), value: amount});
        distributor.fund({hook: address(stickyToken), token: IERC20(address(openToken)), amount: amount});
        vm.stopPrank();
        assertEq(openToken.balanceOf(address(distributor)), amount);
    }

    /// @notice Fund `amount` of the reward token into a group's pot for another sticky token's holders.
    function _fundHook(address rewardedHook, uint256 amount, uint256 groupId) internal {
        reward.mint({to: funder, amount: amount});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: amount});
        distributor.fund({hook: rewardedHook, token: IERC20(address(reward)), amount: amount, groupId: groupId});
        vm.stopPrank();
    }

    /// @notice The current round's pot and denominator for another sticky token's group.
    function _currentRewardRoundOfHook(
        address rewardedHook,
        uint256 groupId
    )
        internal
        view
        returns (uint208 amount, uint208 totalStake)
    {
        (amount,,,, totalStake) =
            distributor.rewardRoundOf(rewardedHook, groupId, IERC20(address(reward)), distributor.currentRound());
    }

    /// @notice Brute-force sum of every holder's live tranches created in `[lo, hi]`.
    function _bruteForceWindow(address[] memory holders, uint256 lo, uint256 hi) internal view returns (uint256 sum) {
        for (uint256 h; h < holders.length; h++) {
            JBStickyTranche[] memory tranches = hook.tranchesOf(projectId, holders[h]);
            for (uint256 t; t < tranches.length; t++) {
                uint256 epoch = uint256(tranches[t].timestamp) / 1 weeks;
                if (epoch >= lo && epoch <= hi) sum += tranches[t].amount;
            }
        }
    }

    //*********************************************************************//
    // ---------------------------- default group ------------------------ //
    //*********************************************************************//

    function test_group0FundClaimCollect_parity() public {
        _stake(alice, 75e18);
        _stake(bob, 25e18);
        vm.roll(vm.getBlockNumber() + 1);

        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        _beginVestingFor(bob);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 75e18);
        assertEq(_collectFor(bob), 25e18);
    }

    function test_group0MatchesStockTokenDistributorStepForStep() public {
        JBTokenDistributor stock = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: CLAIM_DURATION
        });
        assertEq(stock.STARTING_TIMESTAMP(), distributor.STARTING_TIMESTAMP());

        _stake(alice, 60e18);
        _stake(bob, 40e18);
        vm.roll(vm.getBlockNumber() + 1);

        // Fund both identically across several rounds, with a stake change in between.
        for (uint256 round; round < 3; round++) {
            uint256 amount = (round + 1) * 10e18 + 7;
            reward.mint({to: funder, amount: 2 * amount});
            vm.startPrank(funder);
            reward.approve({spender: address(distributor), value: amount});
            distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount});
            reward.approve({spender: address(stock), value: amount});
            stock.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: amount});
            vm.stopPrank();
            if (round == 1) _stake(carol, 33e18);
            vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
            vm.roll(vm.getBlockNumber() + 1);
        }

        address[3] memory holders = [alice, bob, carol];
        for (uint256 h; h < holders.length; h++) {
            uint256 tokenId = uint256(uint160(holders[h]));
            distributor.beginVesting({
                hook: address(stickyToken), tokenIds: _tokenIds(holders[h]), tokens: _rewardTokens()
            });
            stock.beginVesting({hook: address(stickyToken), tokenIds: _tokenIds(holders[h]), tokens: _rewardTokens()});
            assertEq(
                distributor.claimedFor(address(stickyToken), tokenId, reward),
                stock.claimedFor(address(stickyToken), tokenId, reward)
            );
        }

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        for (uint256 h; h < holders.length; h++) {
            uint256 tokenId = uint256(uint160(holders[h]));
            assertEq(
                distributor.collectableFor(address(stickyToken), tokenId, reward),
                stock.collectableFor(address(stickyToken), tokenId, reward)
            );
            uint256 before = reward.balanceOf(holders[h]);
            distributor.collectVestedRewards({
                hook: address(stickyToken),
                tokenIds: _tokenIds(holders[h]),
                tokens: _rewardTokens(),
                beneficiary: holders[h]
            });
            uint256 fromSticky = reward.balanceOf(holders[h]) - before;
            stock.collectVestedRewards({
                hook: address(stickyToken),
                tokenIds: _tokenIds(holders[h]),
                tokens: _rewardTokens(),
                beneficiary: holders[h]
            });
            assertEq(reward.balanceOf(holders[h]) - before - fromSticky, fromSticky);
        }

        for (uint256 round; round < 3; round++) {
            (uint208 amount, uint48 snapshotBlock, uint208 claimed, uint48 deadline, uint208 totalStake) =
                distributor.rewardRoundOf(address(stickyToken), 0, reward, round);
            (uint208 sAmount, uint48 sSnapshotBlock, uint208 sClaimed, uint48 sDeadline, uint208 sTotalStake) =
                stock.rewardRoundOf(address(stickyToken), 0, reward, round);
            assertEq(amount, sAmount);
            assertEq(snapshotBlock, sSnapshotBlock);
            assertEq(claimed, sClaimed);
            assertEq(deadline, sDeadline);
            assertEq(totalStake, sTotalStake);
        }
        assertEq(distributor.balanceOf(address(stickyToken), reward), stock.balanceOf(address(stickyToken), reward));
        assertEq(
            distributor.totalVestingAmountOf(address(stickyToken), reward),
            stock.totalVestingAmountOf(address(stickyToken), reward)
        );
    }

    function test_vestingUnlocksLinearlyAcrossRounds() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        assertEq(distributor.claimedFor(address(stickyToken), uint256(uint160(alice)), IERC20(address(reward))), 100e18);
        assertEq(_collectFor(alice), 0);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        assertEq(
            distributor.collectableFor(address(stickyToken), uint256(uint160(alice)), IERC20(address(reward))), 50e18
        );
        assertEq(_collectFor(alice), 50e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        assertEq(_collectFor(alice), 50e18);
        assertEq(distributor.totalVestingAmountOf(address(stickyToken), IERC20(address(reward))), 0);
    }

    function test_expiredRoundsRecycleUnclaimedRewards() public {
        _stake(alice, 50e18);
        _stake(bob, 50e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);
        uint256 fundedRound = distributor.currentRound();

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        vm.warp(vm.getBlockTimestamp() + CLAIM_DURATION);

        uint256[] memory rounds = new uint256[](1);
        rounds[0] = fundedRound;
        uint256 recycled = distributor.recycleExpiredRewards({
            hook: address(stickyToken), token: IERC20(address(reward)), rounds: rounds
        });
        assertEq(recycled, 50e18);

        assertEq(
            distributor.recycleExpiredRewards({
                hook: address(stickyToken), token: IERC20(address(reward)), rounds: rounds
            }),
            0
        );
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(address(reward))), 100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 50e18);
    }

    function test_pokeLocksTheCurrentAndNextRoundSnapshots() public {
        uint256 round = distributor.currentRound();
        vm.roll(vm.getBlockNumber() + 1);

        distributor.poke();

        assertEq(distributor.roundSnapshotBlock(round), vm.getBlockNumber() - 1);
        assertEq(distributor.roundSnapshotBlock(round + 1), vm.getBlockNumber() - 1);
    }

    function test_unstakedHolderKeepsAlreadyClaimedRewards() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);

        _unstake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 100e18);
    }

    /// @notice A Sticky token funded as a reward leaves the distributor holding aged shares. Collecting its own
    /// allocation, which a helper can only send to the distributor, recycles it into the current round instead of
    /// erasing it from the ledger, and other holders' claims are untouched.
    function test_distributorHeldSharesRecycleInsteadOfSelfCollecting() public {
        (uint256 openProjectId, IJBToken openToken) = _launchOpenProject();
        _stakeIn({holder: alice, amount: 100e18, targetProjectId: openProjectId});

        // Alice hands 40% of the open project's shares to the first project's holders as a reward. That funding
        // pins this round's shared snapshot, so the open project's own round is funded in the next one.
        _fundShares({openToken: openToken, amount: 40e18});
        assertEq(hook.stakedBalanceOf(openProjectId, address(distributor)), 40e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        vm.roll(vm.getBlockNumber() + 1);

        // The open project's holders are rewarded: alice weighs 60% and the distributor 40%.
        _fundHook({rewardedHook: address(openToken), amount: 100e18, groupId: 0});
        uint256 distributorId = uint256(uint160(address(distributor)));

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        distributor.beginVesting({
            hook: address(openToken), tokenIds: _tokenIds(address(distributor)), tokens: _rewardTokens()
        });
        assertEq(distributor.claimedFor(address(openToken), 0, distributorId, reward), 40e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        distributor.collectVestedRewards({
            hook: address(openToken),
            tokenIds: _tokenIds(address(distributor)),
            tokens: _rewardTokens(),
            beneficiary: address(distributor)
        });

        // The allocation is now the current round's pot; custody and the accounted balance are unchanged.
        (uint208 recycledPot,,,,) =
            distributor.rewardRoundOf(address(openToken), 0, IERC20(address(reward)), distributor.currentRound());
        assertEq(recycledPot, 40e18);
        assertEq(distributor.balanceOf(address(openToken), IERC20(address(reward))), 100e18);
        assertEq(reward.balanceOf(address(distributor)), 100e18);
        assertEq(distributor.claimedFor(address(openToken), 0, distributorId, reward), 0);
        assertEq(distributor.totalVestingAmountOf(address(openToken), IERC20(address(reward))), 0);

        // Alice's share of the funded round is intact, and she shares the recycled round once it completes.
        distributor.beginVesting({hook: address(openToken), tokenIds: _tokenIds(alice), tokens: _rewardTokens()});
        assertEq(distributor.claimedFor(address(openToken), 0, uint256(uint160(alice)), reward), 60e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        distributor.collectVestedRewards({
            hook: address(openToken), tokenIds: _tokenIds(alice), tokens: _rewardTokens(), beneficiary: alice
        });
        assertEq(reward.balanceOf(alice), 60e18);
        distributor.beginVesting({hook: address(openToken), tokenIds: _tokenIds(alice), tokens: _rewardTokens()});
        assertEq(distributor.claimedFor(address(openToken), 0, uint256(uint160(alice)), reward), 24e18);
    }

    /// @notice The same recycling applies to a tenure group's pot, through the group-carrying collection.
    function test_distributorHeldSharesRecycleInTenureGroups() public {
        (uint256 openProjectId, IJBToken openToken) = _launchOpenProject();
        _warpWeeks(10);
        _stakeIn({holder: alice, amount: 100e18, targetProjectId: openProjectId});
        _fundShares({openToken: openToken, amount: 40e18});

        // Both tranches are two weeks old when the round is funded, so the denominator counts them both.
        _warpWeeks(12);
        _fundHook({rewardedHook: address(openToken), amount: 100e18, groupId: 1000});
        (uint208 pot, uint208 totalStake) = _currentRewardRoundOfHook({rewardedHook: address(openToken), groupId: 1000});
        assertEq(pot, 100e18);
        assertEq(totalStake, 100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        distributor.beginVesting({
            hook: address(openToken), groupId: 1000, tokenIds: _tokenIds(address(distributor)), tokens: _rewardTokens()
        });
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        distributor.collectVestedRewards({
            hook: address(openToken),
            groupId: 1000,
            tokenIds: _tokenIds(address(distributor)),
            tokens: _rewardTokens(),
            beneficiary: address(distributor)
        });

        (pot,) = _currentRewardRoundOfHook({rewardedHook: address(openToken), groupId: 1000});
        assertEq(pot, 40e18);
        assertEq(distributor.balanceOf(address(openToken), IERC20(address(reward))), 100e18);
        assertEq(reward.balanceOf(address(distributor)), 100e18);
    }

    /// @notice Holders cannot route their own rewards to the distributor, which would leave them in custody with no
    /// ledger entry.
    function test_holderCannotCollectToTheDistributor() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_NoAccess.selector, address(stickyToken), uint256(uint160(alice)), alice
            )
        );
        vm.prank(alice);
        distributor.collectVestedRewards({
            hook: address(stickyToken),
            tokenIds: _tokenIds(alice),
            tokens: _rewardTokens(),
            beneficiary: address(distributor)
        });
    }

    //*********************************************************************//
    // ------------------------------- splits ---------------------------- //
    //*********************************************************************//

    function test_splitFundingRejectsUnauthorizedCallers() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_Unauthorized.selector, projectId, address(this)
            )
        );
        distributor.processSplitWith(_splitContext(address(reward), 1e18));
    }

    function test_splitFundingCreditsTheErc20BalanceDelta() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 40e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 40e18});
        uint256 balanceBefore = reward.balanceOf(address(distributor));
        vm.expectEmit(address(distributor));
        emit IJBStickyDistributor.Fund({
            hook: address(stickyToken),
            groupId: 0,
            token: IERC20(address(reward)),
            round: distributor.currentRound(),
            amount: 40e18,
            caller: terminal
        });
        distributor.processSplitWith(_splitContext(address(reward), 40e18));
        vm.stopPrank();

        uint256 delta = reward.balanceOf(address(distributor)) - balanceBefore;
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 0);
        assertEq(delta, 40e18);
        assertEq(amount, delta);
        assertEq(totalStake, 100e18);
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(address(reward))), 40e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingFor(alice);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectFor(alice), 40e18);
    }

    function test_splitFundingCreditsOnlyWhatAFeeOnTransferTokenDelivers() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        reward.setFeeBps(100);
        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 40e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 40e18});
        uint256 balanceBefore = reward.balanceOf(address(distributor));
        distributor.processSplitWith(_splitContext(address(reward), 40e18));
        vm.stopPrank();

        uint256 delta = reward.balanceOf(address(distributor)) - balanceBefore;
        (uint208 amount,) = _currentRewardRoundOf(address(reward), 0);
        assertEq(delta, 39.6e18);
        assertEq(amount, delta);
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(address(reward))), delta);
    }

    function test_splitFundingRevertsWhenErc20CarriesNativeValue() public {
        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_TokenMismatch.selector,
                address(reward),
                JBConstants.NATIVE_TOKEN,
                uint256(1)
            )
        );
        vm.prank(terminal);
        distributor.processSplitWith{value: 1}(_splitContext(address(reward), 1e18));
    }

    function test_splitFundingRevertsWhenNativeValueMissesTheContextAmount() public {
        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_NativeAmountMismatch.selector, uint256(0.5e18), uint256(1e18)
            )
        );
        vm.prank(terminal);
        distributor.processSplitWith{value: 0.5e18}(_splitContext(JBConstants.NATIVE_TOKEN, 1e18));
    }

    function test_nativeSplitFundingCollectsThroughTheNativeTransferPath() public {
        _stake(alice, 75e18);
        _stake(bob, 25e18);
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        vm.deal(terminal, 100e18);
        vm.prank(terminal);
        distributor.processSplitWith{value: 100e18}(_splitContext(JBConstants.NATIVE_TOKEN, 100e18));

        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(JBConstants.NATIVE_TOKEN, 0);
        assertEq(amount, 100e18);
        assertEq(totalStake, 100e18);
        assertEq(address(distributor).balance, 100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        distributor.beginVesting({hook: address(stickyToken), tokenIds: _tokenIds(alice), tokens: _nativeTokens()});
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        uint256 aliceBalanceBefore = alice.balance;
        distributor.collectVestedRewards({
            hook: address(stickyToken), tokenIds: _tokenIds(alice), tokens: _nativeTokens(), beneficiary: alice
        });
        assertEq(alice.balance - aliceBalanceBefore, 75e18);

        assertEq(address(distributor).balance, 25e18);
        assertEq(distributor.balanceOf(address(stickyToken), IERC20(JBConstants.NATIVE_TOKEN)), 25e18);
    }

    function test_splitProjectIdSelectsTenureGroup() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(14);

        _processSplitWithGroup({amount: 10e18, groupId: 3000});
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 3000);
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
        assertEq(distributor.snapshotEpochOf(distributor.currentRound()), _startEpoch + 14);
    }

    function test_splitOutOfRangeGroupFallsToGroupZero() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        _processSplitWithGroup({amount: 10e18, groupId: uint64(vm.getBlockTimestamp() + 365 days)});
        (uint208 amount,) = _currentRewardRoundOf(address(reward), 0);
        assertEq(amount, 10e18);
    }

    function test_splitInvalidGroupFallsToGroupZero() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        // 4 decodes to minWeeks == 0, which is invalid, so it funds the default group instead of reverting.
        _processSplitWithGroup({amount: 10e18, groupId: 4});
        (uint208 amount,) = _currentRewardRoundOf(address(reward), 0);
        assertEq(amount, 10e18);
    }

    function test_splitLockedGroupFundsTenurePot() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(14);

        uint48 futureLock = uint48(vm.getBlockTimestamp() + 365 days);
        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 10e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 10e18});
        distributor.processSplitWith(
            _splitContext({token: address(reward), amount: 10e18, groupId: 3000, lockedUntil: futureLock})
        );
        vm.stopPrank();

        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 3000);
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
    }

    function test_splitGroupValueInLockedUntilIsIgnored() public {
        _stake(alice, 100e18);
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 10e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 10e18});
        distributor.processSplitWith(
            _splitContext({token: address(reward), amount: 10e18, groupId: 0, lockedUntil: 4008})
        );
        vm.stopPrank();

        (uint208 amount,) = _currentRewardRoundOf(address(reward), 0);
        assertEq(amount, 10e18);
    }

    function test_splitTenureGroupForUnregisteredBeneficiaryFallsToGroupZero() public {
        // A Sticky token the hook never registered: it reports the project, but is not its movement reporter.
        JBStickyToken impostor = new JBStickyToken({
            name: "Impostor",
            symbol: "IMP",
            tokens: IJBTokens(address(this)),
            projectId: projectId,
            hook: hook,
            soulbound: true
        });
        assertTrue(hook.tokenOf(projectId) != address(impostor));
        vm.roll(vm.getBlockNumber() + 1);

        address terminal = address(jbMultiTerminal());
        reward.mint({to: terminal, amount: 10e18});
        vm.startPrank(terminal);
        reward.approve({spender: address(distributor), value: 10e18});
        JBSplitHookContext memory context =
            _splitContext({token: address(reward), amount: 10e18, groupId: 3000, lockedUntil: 0});
        context.split.beneficiary = payable(address(impostor));
        distributor.processSplitWith(context);
        vm.stopPrank();

        (uint208 amount,,,,) = distributor.rewardRoundOf(address(impostor), 0, reward, distributor.currentRound());
        assertEq(amount, 10e18);
        (uint208 tenureAmount,,,,) =
            distributor.rewardRoundOf(address(impostor), 3000, reward, distributor.currentRound());
        assertEq(tenureAmount, 0);
    }

    //*********************************************************************//
    // --------------------------- group validation ---------------------- //
    //*********************************************************************//

    function test_isValidGroupIdTable() public view {
        assertTrue(distributor.isValidGroupId(0));
        assertTrue(distributor.isValidGroupId(1000));
        assertTrue(distributor.isValidGroupId(4000));
        assertTrue(distributor.isValidGroupId(1004));
        assertTrue(distributor.isValidGroupId(4008));
        assertTrue(distributor.isValidGroupId(4004));
        assertTrue(distributor.isValidGroupId(520_000));
        assertTrue(distributor.isValidGroupId(520_520));
        assertFalse(distributor.isValidGroupId(1)); // minWeeks == 0
        assertFalse(distributor.isValidGroupId(520)); // minWeeks == 0
        assertFalse(distributor.isValidGroupId(8004)); // maxWeeks < minWeeks
        assertFalse(distributor.isValidGroupId(4999)); // maxWeeks > 520
        assertFalse(distributor.isValidGroupId(521_000)); // minWeeks > 520
        assertFalse(distributor.isValidGroupId(uint256(1) << 240));
        assertFalse(distributor.isValidGroupId(type(uint256).max));
    }

    function test_fundAcceptsValidGroups() public {
        uint256[4] memory validGroups = [uint256(0), 4000, 1004, 4008];
        vm.roll(vm.getBlockNumber() + 1);

        reward.mint(funder, 4e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 4e18);
        for (uint256 i; i < validGroups.length; i++) {
            distributor.fund(address(stickyToken), reward, 1e18, validGroups[i]);
        }
        vm.stopPrank();

        // The widest window is accepted; its bottom simply clamps at epoch 0 and nothing is that old yet.
        _fundGroup(1e18, 520_520);
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 520_520);
        assertEq(amount, 1e18);
        assertEq(totalStake, 0);
    }

    function test_fundRejectsInvalidGroups() public {
        uint256[6] memory invalidGroups = [uint256(4), 520, 8004, 4999, 521_000, uint256(1) << 240];

        reward.mint(funder, 10e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 10e18);
        for (uint256 i; i < invalidGroups.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, invalidGroups[i]
                )
            );
            distributor.fund(address(stickyToken), reward, 1e18, invalidGroups[i]);
        }
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, 4));
        distributor.beginVesting({
            hook: address(stickyToken), groupId: 4, tokenIds: _tokenIds(alice), tokens: _rewardTokens()
        });
        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, 4));
        distributor.collectVestedRewards({
            hook: address(stickyToken),
            groupId: 4,
            tokenIds: _tokenIds(alice),
            tokens: _rewardTokens(),
            beneficiary: alice
        });
        vm.expectRevert(abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_InvalidGroupId.selector, 4));
        distributor.recycleExpiredRewards({
            hook: address(stickyToken), groupId: 4, token: reward, rounds: new uint256[](0)
        });
    }

    function test_fundTenureGroupRejectsUnregisteredToken() public {
        JBStickyToken impostor = new JBStickyToken({
            name: "Impostor",
            symbol: "IMP",
            tokens: IJBTokens(address(this)),
            projectId: projectId,
            hook: hook,
            soulbound: true
        });
        reward.mint(funder, 1e18);
        vm.startPrank(funder);
        reward.approve(address(distributor), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_UnregisteredStickyToken.selector, address(impostor)
            )
        );
        distributor.fund(address(impostor), reward, 1e18, 2000);
        vm.expectRevert(
            abi.encodeWithSelector(JBStickyDistributor.JBStickyDistributor_UnregisteredStickyToken.selector, alice)
        );
        distributor.fund(alice, reward, 1e18, 2000);
        vm.stopPrank();
    }

    function test_constructorRejectsMismatchedEpochDuration() public {
        vm.mockCall(address(hook), abi.encodeCall(IJBStickyHook.EPOCH_DURATION, ()), abi.encode(uint256(1 days)));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyDistributor.JBStickyDistributor_EpochDurationMismatch.selector,
                uint256(1 weeks),
                uint256(1 days)
            )
        );
        new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: hook,
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: CLAIM_DURATION
        });
    }

    /// @notice A zero claim duration never expires, so a tenure pot forfeited by exits could never recycle.
    function test_constructorRejectsZeroClaimDuration() public {
        vm.expectRevert(JBStickyDistributor.JBStickyDistributor_ZeroClaimDuration.selector);
        new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: hook,
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: 0
        });
    }

    function test_bindingsAndInterfaces() public view {
        assertEq(address(distributor.STICKY_HOOK()), address(hook));
        assertEq(address(distributor.DIRECTORY()), address(jbDirectory()));
        assertEq(address(distributor.CONTROLLER()), address(jbController()));
        assertEq(address(distributor.REV_LOANS()), address(0));
        assertEq(address(distributor.REV_OWNER()), address(0));
        assertEq(distributor.EPOCH_DURATION(), hook.EPOCH_DURATION());
        assertEq(distributor.CRITERIA_BASE(), 1000);
        assertEq(distributor.MAX_CRITERIA_WEEKS(), 520);
        assertTrue(distributor.supportsInterface(type(IJBStickyDistributor).interfaceId));
        assertTrue(distributor.supportsInterface(type(IJBTokenDistributor).interfaceId));
        assertTrue(distributor.supportsInterface(type(IJBSplitHook).interfaceId));
        assertTrue(distributor.supportsInterface(type(IERC165).interfaceId));
        assertFalse(distributor.supportsInterface(0xffffffff));
    }

    function test_distributorFitsEip170() public view {
        assertLe(address(distributor).code.length, 24_576);
    }

    //*********************************************************************//
    // ------------------------------ tenure ----------------------------- //
    //*********************************************************************//

    function test_fundWithTenureGroupCreatesPot() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(14);

        reward.mint({to: funder, amount: 10e18});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: 10e18});
        vm.expectEmit(address(distributor));
        emit IJBStickyDistributor.Fund({
            hook: address(stickyToken),
            groupId: 2000,
            token: IERC20(address(reward)),
            round: distributor.currentRound(),
            amount: 10e18,
            caller: funder
        });
        distributor.fund({hook: address(stickyToken), token: IERC20(address(reward)), amount: 10e18, groupId: 2000});
        vm.stopPrank();

        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 2000);
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
        assertEq(distributor.snapshotEpochOf(distributor.currentRound()), _startEpoch + 14);
    }

    function test_fundWithTenureGroupAcceptsNativeToken() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(14);

        vm.deal(funder, 10e18);
        vm.prank(funder);
        distributor.fund{value: 10e18}(address(stickyToken), IERC20(JBConstants.NATIVE_TOKEN), 0, 2000);

        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(JBConstants.NATIVE_TOKEN, 2000);
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
    }

    function test_denominatorSumsOnlyAgedStake() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(13);
        _stake(bob, 300e18); // too fresh for min = 2 at epoch +14
        _warpWeeks(14);

        _fundGroup(10e18, 2000);
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 2000);
        assertEq(totalStake, 100e18);
    }

    function test_denominatorZeroWhenNothingAged() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _fundGroup(10e18, 52_000);
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 52_000);
        assertEq(totalStake, 0);
    }

    function test_snapshotEpochIsPinnedAtRoundStart() public {
        _warpWeeks(10);
        _stake(alice, 100e18);

        // The round starting at +12 weeks runs one day. Funding early or late in it reads the same window.
        _warpWeeks(12);
        uint256 round = distributor.currentRound();
        assertEq(distributor.snapshotEpochOf(round), _startEpoch + 12);
        assertEq(distributor.roundStartTimestamp(round), _start + 12 weeks);
        vm.warp(_start + 12 weeks + 20 hours);
        _stake(bob, 900e18); // same round, same epoch: never enters this round's window
        _fundGroup(10e18, 1000);
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 1000);
        assertEq(totalStake, 100e18);

        // A round that starts mid-week still pins to that week's epoch, so earlier same-week stakes are excluded.
        vm.warp(_start + 13 weeks + 3 days + 1);
        _stake(carol, 50e18); // epoch +13, before the next round starts
        vm.warp(_start + 13 weeks + 4 days + 1);
        assertEq(distributor.snapshotEpochOf(distributor.currentRound()), _startEpoch + 13);
        _fundGroup(10e18, 1000);
        (, totalStake) = _currentRewardRoundOf(address(reward), 1000);
        assertEq(totalStake, 1000e18); // alice + bob, staked in epochs +10 and +12; carol's epoch +13 is excluded
    }

    function test_stakeAfterRoundStartCannotClaimThatRound() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(12);
        _fundGroup(100e18, 1000);
        _stake(carol, 500e18); // staked after the round started

        vm.warp(vm.getBlockTimestamp() + 3 weeks); // carol's tranche is now well past minWeeks in wall-time
        _beginVestingGroupFor(carol, 1000);
        assertEq(_collectableGroupFor(carol, 1000), 0);
        _beginVestingGroupFor(alice, 1000);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 1000), 100e18);
    }

    function test_secondFundingSameRoundKeepsPinnedDenominator() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(12);
        _fundGroup(10e18, 1000);
        _stake(bob, 900e18);
        _fundGroup(5e18, 1000);
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 1000);
        assertEq(amount, 15e18);
        assertEq(totalStake, 100e18);
    }

    function test_claimSplitsProRataAcrossAgedTranches() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _warpWeeks(13);
        _stake(bob, 600e18); // fresh bob tranche won't count for min = 2 at epoch +14
        _warpWeeks(14);
        _fundGroup(100e18, 2000); // denominator = 400e18

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 2000);
        _beginVestingGroupFor(bob, 2000);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 2000), 25e18);
        assertEq(_collectGroupFor(bob, 2000), 75e18);
    }

    function test_postSnapshotDeepExitForfeitsAgedWeight() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _warpWeeks(12);
        _fundGroup(100e18, 1000); // denominator 200e18

        _unstake(bob, 80e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 1000);
        _beginVestingGroupFor(bob, 1000);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 1000), 50e18);
        assertEq(_collectGroupFor(bob, 1000), 10e18); // 20/200 of the pot; 40e18 stays for recycle
    }

    function test_fullExitBeforeClaimForfeitsTheRoundToRecycling() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _warpWeeks(12);
        _fundGroup(100e18, 1000);
        uint256 fundedRound = distributor.currentRound();

        _unstake(bob, 100e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(bob, 1000);
        assertEq(distributor.claimedFor(address(stickyToken), 1000, uint256(uint160(bob)), reward), 0);

        vm.warp(vm.getBlockTimestamp() + CLAIM_DURATION);
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = fundedRound;
        assertEq(
            distributor.recycleExpiredRewards({
                hook: address(stickyToken), groupId: 1000, token: reward, rounds: rounds
            }),
            100e18
        );
    }

    function test_transferDoesNotInheritAgeForTenureClaims() public {
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 openProjectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(staked)),
            name: "Open Sticky",
            symbol: "OSTICKY",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: false
        });
        IJBToken openToken = jbTokens().tokenOf(openProjectId);

        _warpWeeks(10);
        _stakeIn({holder: alice, amount: 100e18, targetProjectId: openProjectId});

        _warpWeeks(12);
        reward.mint({to: funder, amount: 100e18});
        vm.startPrank(funder);
        reward.approve({spender: address(distributor), value: 100e18});
        distributor.fund({hook: address(openToken), token: IERC20(address(reward)), amount: 100e18, groupId: 1000});
        vm.stopPrank();

        // Alice moves half to carol after the snapshot: LIFO splits her only aged tranche, and carol's new tranche
        // is timestamped now, above the window.
        vm.prank(alice);
        IERC20(address(openToken)).transfer({to: carol, value: 50e18});

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        distributor.beginVesting({
            hook: address(openToken), groupId: 1000, tokenIds: _tokenIds(alice), tokens: _rewardTokens()
        });
        distributor.beginVesting({
            hook: address(openToken), groupId: 1000, tokenIds: _tokenIds(carol), tokens: _rewardTokens()
        });
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        uint256 aliceBalanceBefore = reward.balanceOf(alice);
        distributor.collectVestedRewards({
            hook: address(openToken),
            groupId: 1000,
            tokenIds: _tokenIds(alice),
            tokens: _rewardTokens(),
            beneficiary: alice
        });
        assertEq(reward.balanceOf(alice) - aliceBalanceBefore, 50e18);

        uint256 carolBalanceBefore = reward.balanceOf(carol);
        distributor.collectVestedRewards({
            hook: address(openToken),
            groupId: 1000,
            tokenIds: _tokenIds(carol),
            tokens: _rewardTokens(),
            beneficiary: carol
        });
        assertEq(reward.balanceOf(carol) - carolBalanceBefore, 0);
    }

    function test_tenureDenominatorMatchesBruteForce() public {
        address[] memory holders = new address[](3);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = carol;

        // Stakes and exits scattered across 20 weeks, several per week.
        uint256 seed = 7;
        for (uint256 week; week < 20; week++) {
            for (uint256 k; k < 3; k++) {
                seed = uint256(keccak256(abi.encode(seed, week, k)));
                vm.warp(_start + week * 1 weeks + (seed % 6 days) + 1);
                address holder = holders[seed % 3];
                uint256 amount = (seed >> 8) % 50e18 + 1;
                if ((seed >> 4) % 4 == 0 && hook.stakedBalanceOf(projectId, holder) != 0) {
                    _unstake(holder, amount % hook.stakedBalanceOf(projectId, holder) + 1);
                } else {
                    _stake(holder, amount);
                }
            }
        }

        _warpWeeks(21);
        uint256 snapshotEpoch = distributor.snapshotEpochOf(distributor.currentRound());
        assertEq(snapshotEpoch, _startEpoch + 21);

        uint256[4] memory groups = [uint256(1000), 4000, 3009, 1004];
        for (uint256 g; g < groups.length; g++) {
            uint256 minWeeks = groups[g] / 1000;
            uint256 maxWeeks = groups[g] % 1000;
            uint256 hi = snapshotEpoch - minWeeks;
            uint256 lo = maxWeeks == 0 ? 0 : snapshotEpoch - maxWeeks;
            _fundGroup(1e18, groups[g]);
            (, uint208 totalStake) = _currentRewardRoundOf(address(reward), groups[g]);
            assertEq(totalStake, _bruteForceWindow(holders, lo, hi), "denominator");

            // Every holder's numerator matches the same brute force over their own tranches.
            for (uint256 h; h < holders.length; h++) {
                address[] memory one = new address[](1);
                one[0] = holders[h];
                uint256 expected = hook.stakedBalanceThroughEpochOf(projectId, holders[h], hi)
                    - (lo == 0 ? 0 : hook.stakedBalanceThroughEpochOf(projectId, holders[h], lo - 1));
                assertEq(expected, _bruteForceWindow(one, lo, hi), "numerator");
            }
        }
        assertEq(hook.netStakedWithin(projectId, _startEpoch, snapshotEpoch), IJBToken(stickyToken).totalSupply());
    }

    //*********************************************************************//
    // ----------------------------- windows ----------------------------- //
    //*********************************************************************//

    function test_cohortDenominatorOnlyMiddleBucketsCount() public {
        _warpWeeks(10);
        _stake(alice, 100e18); // epoch +10, below the (4, 8) window at snapshot +20
        _warpWeeks(14);
        _stake(bob, 200e18); // epoch +14, inside [+12, +16]
        _warpWeeks(18);
        _stake(carol, 300e18); // epoch +18, above the window
        _warpWeeks(20);

        _fundGroup(10e18, 4008);
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 4008);
        assertEq(totalStake, 200e18);
    }

    function test_cohortNumeratorClaimsOnlyDepositCohortSlice() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(14);
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _warpWeeks(18);
        _stake(alice, 100e18);
        _warpWeeks(20);

        _fundGroup(100e18, 4008); // denominator = alice's epoch +14 100e18 + bob's epoch +14 100e18

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 4008);
        _beginVestingGroupFor(bob, 4008);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 4008), 50e18);
        assertEq(_collectGroupFor(bob, 4008), 50e18);
    }

    function test_recencyPaysNewestWeeksExcludesOldTenure() public {
        _warpWeeks(10);
        _stake(alice, 100e18);
        _warpWeeks(18);
        _stake(bob, 100e18);
        _warpWeeks(20);

        _fundGroup(100e18, 1004);
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 1004);
        assertEq(totalStake, 100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 1004);
        _beginVestingGroupFor(bob, 1004);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 1004), 0);
        assertEq(_collectGroupFor(bob, 1004), 100e18);
    }

    function test_recencyPotInsolvencyGuardAgainstSameEpochLateStake() public {
        _warpWeeks(18);
        _stake(alice, 100e18);

        _warpWeeks(20);
        _fundGroup(100e18, 1004);
        _stake(bob, 500e18); // same epoch as the round start, right after the funding

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 1004);
        _beginVestingGroupFor(bob, 1004);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);

        assertEq(_collectableGroupFor(bob, 1004), 0);
        uint256 aliceClaim = _collectGroupFor(alice, 1004);
        uint256 bobClaim = _collectGroupFor(bob, 1004);
        assertEq(aliceClaim, 100e18);
        assertEq(bobClaim, 0);
    }

    function test_splitProjectIdSelectsCohortGroup() public {
        _warpWeeks(14);
        _stake(alice, 100e18);
        _warpWeeks(20);

        _processSplitWithGroup({amount: 10e18, groupId: 4008});
        (uint208 amount, uint208 totalStake) = _currentRewardRoundOf(address(reward), 4008);
        assertEq(amount, 10e18);
        assertEq(totalStake, 100e18);
    }

    function test_singleBucketWindowMatchesExactlyOneEpoch() public {
        _warpWeeks(15);
        _stake(alice, 100e18);
        _warpWeeks(16);
        _stake(bob, 100e18);
        _warpWeeks(17);
        _stake(carol, 100e18);
        _warpWeeks(20);

        _fundGroup(30e18, 4004);
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 4004);
        assertEq(totalStake, 100e18);

        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 4004);
        _beginVestingGroupFor(bob, 4004);
        _beginVestingGroupFor(carol, 4004);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 4004), 0);
        assertEq(_collectGroupFor(bob, 4004), 30e18);
        assertEq(_collectGroupFor(carol, 4004), 0);
    }

    function test_sameWeekTopUpsMergeAndAgeAsOne() public {
        _warpWeeks(10);
        _stake(alice, 40e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _stake(alice, 60e18); // merges into the epoch +10 tranche
        assertEq(hook.trancheCountOf(projectId, alice), 1);
        _warpWeeks(12);

        _fundGroup(100e18, 2000); // window top is epoch +10: the whole merged tranche qualifies
        (, uint208 totalStake) = _currentRewardRoundOf(address(reward), 2000);
        assertEq(totalStake, 100e18);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION);
        _beginVestingGroupFor(alice, 2000);
        vm.warp(vm.getBlockTimestamp() + ROUND_DURATION * VESTING_ROUNDS);
        assertEq(_collectGroupFor(alice, 2000), 100e18);
    }
}
