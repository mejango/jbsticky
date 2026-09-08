// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBStickyAutoStick} from "../src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBAutoStickStatus} from "../src/enums/JBAutoStickStatus.sol";

contract StickyRewardRegressionToken is ERC20 {
    uint8 internal immutable _DECIMALS;

    constructor(uint8 tokenDecimals) ERC20("Reward regression", "RWD") {
        _DECIMALS = tokenDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address beneficiary, uint256 amount) external {
        _mint({account: beneficiary, value: amount});
    }
}

contract JBStickyRewardsRegressionTest is TestBaseWorkflow {
    struct RewardFixture {
        StickyRewardRegressionToken underlying;
        IJBToken stickyToken;
        JBTokenDistributor distributor;
        JBStickyAutoStick adapter;
        uint256 projectId;
    }

    address internal _holder = makeAddr("reward holder");
    address internal _keeper = makeAddr("reward keeper");
    JBStickyDeployer internal _deployer;

    function setUp() public override {
        super.setUp();
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
    }

    function test_compoundKeepsZeroIssuanceRewardsClaimable() public {
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 24, reward: 999_999, donation: 0});
        uint256 balanceBefore = fixture.underlying.balanceOf(address(jbMultiTerminal()));
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        (JBAutoStickStatus status,,,) = fixture.adapter.statusOf({projectId: fixture.projectId, holder: _holder});
        assertEq(uint256(status), uint256(JBAutoStickStatus.ZeroIssuance));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, fixture.projectId, 999_999
            )
        );
        vm.prank(_keeper);
        fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder});

        _assertRewardUnmoved({
            fixture: fixture, reward: 999_999, balanceBefore: balanceBefore, sharesBefore: sharesBefore
        });
    }

    function test_selfServiceKeepsZeroIssuanceRewardsClaimable() public {
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 24, reward: 999_999, donation: 0});
        uint256 balanceBefore = fixture.underlying.balanceOf(address(jbMultiTerminal()));
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector, fixture.projectId, 999_999
            )
        );
        vm.prank(_holder);
        fixture.adapter.stickRewardsFor(fixture.projectId);

        _assertRewardUnmoved({
            fixture: fixture, reward: 999_999, balanceBefore: balanceBefore, sharesBefore: sharesBefore
        });
    }

    function test_smallest24DecimalIssuanceUsesTerminalPreview() public {
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 24, reward: 1e6, donation: 0});
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        uint256 preview = _preview({fixture: fixture, amount: 1e6});
        assertEq(preview, 1);
        vm.prank(_keeper);
        (uint256 amount, uint256 count) = fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder});
        assertEq(amount, 1e6);
        assertEq(count, preview);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore + count);
        assertEq(fixture.underlying.balanceOf(_holder), 37);
        assertEq(fixture.underlying.balanceOf(address(fixture.adapter)), 0);
        assertEq(fixture.underlying.allowance(address(fixture.adapter), address(jbMultiTerminal())), 0);
    }

    function test_compoundUsesBackingPriceWithoutChangingBeneficiary() public {
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 6, reward: 10e6, donation: 1e6});
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        uint256 preview = _preview({fixture: fixture, amount: 10e6});
        assertGt(preview, 0);
        assertLt(preview, 10e18);
        vm.prank(_keeper);
        (uint256 amount, uint256 count) = fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder});
        assertEq(amount, 10e6);
        assertEq(count, preview);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore + count);
        assertEq(fixture.stickyToken.balanceOf(_keeper), 0);
        assertEq(fixture.underlying.balanceOf(_holder), 37);
        assertEq(fixture.underlying.balanceOf(_keeper), 0);
        assertEq(fixture.underlying.balanceOf(address(fixture.adapter)), 0);
        assertEq(fixture.underlying.allowance(address(fixture.adapter), address(jbMultiTerminal())), 0);
    }

    function test_priorPermissionlessCollectionKeepsRewardsWithHolder() public {
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 6, reward: 10e6, donation: 0});
        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = uint256(uint160(_holder));
        IERC20[] memory rewardTokens = new IERC20[](1);
        rewardTokens[0] = IERC20(address(fixture.underlying));
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        vm.prank(_keeper);
        fixture.distributor
            .collectVestedRewards({
                hook: address(fixture.stickyToken), tokenIds: holderIds, tokens: rewardTokens, beneficiary: _holder
            });
        vm.expectRevert(abi.encodeWithSelector(JBStickyAutoStick.JBStickyAutoStick_BelowMinimum.selector, 0, 1));
        fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder});
        assertEq(fixture.underlying.balanceOf(_holder), 10e6 + 37);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore);
        assertEq(fixture.underlying.balanceOf(_keeper), 0);
    }

    function _assertRewardUnmoved(
        RewardFixture memory fixture,
        uint256 reward,
        uint256 balanceBefore,
        uint256 sharesBefore
    )
        internal
        view
    {
        assertEq(
            fixture.distributor
                .collectableFor({
                    hook: address(fixture.stickyToken),
                    tokenId: uint256(uint160(_holder)),
                    token: IERC20(address(fixture.underlying))
                }),
            reward
        );
        assertEq(fixture.underlying.balanceOf(address(jbMultiTerminal())), balanceBefore);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore);
        assertEq(fixture.underlying.balanceOf(_holder), 37);
        assertEq(fixture.underlying.balanceOf(address(fixture.adapter)), 0);
        assertEq(fixture.underlying.allowance(address(fixture.adapter), address(jbMultiTerminal())), 0);
        (,, uint48 lastCompoundedAt,) = fixture.adapter.configOf({projectId: fixture.projectId, holder: _holder});
        assertEq(lastCompoundedAt, 0);
    }

    function _preview(RewardFixture memory fixture, uint256 amount) internal returns (uint256 count) {
        vm.prank(address(fixture.adapter));
        (, count,,) = jbMultiTerminal().previewPayFor({
            projectId: fixture.projectId,
            token: address(fixture.underlying),
            amount: amount,
            beneficiary: _holder,
            metadata: bytes("")
        });
    }

    function _rewardFixture(
        uint8 tokenDecimals,
        uint256 reward,
        uint256 donation
    )
        internal
        returns (RewardFixture memory fixture)
    {
        fixture.underlying = new StickyRewardRegressionToken(tokenDecimals);
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        fixture.projectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(fixture.underlying)),
            name: "Sticky reward regression",
            symbol: "sRWD",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        fixture.stickyToken = jbTokens().tokenOf(fixture.projectId);
        uint256 initialStake = 10 ** tokenDecimals;
        fixture.underlying.mint({beneficiary: _holder, amount: initialStake + 37});
        vm.startPrank(_holder);
        fixture.underlying.approve({spender: address(jbMultiTerminal()), value: initialStake});
        jbMultiTerminal().pay({
            projectId: fixture.projectId,
            token: address(fixture.underlying),
            amount: initialStake,
            beneficiary: _holder,
            minReturnedTokens: 1,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(block.number + 1);

        if (donation != 0) {
            fixture.underlying.mint({beneficiary: address(this), amount: donation});
            fixture.underlying.approve({spender: address(jbMultiTerminal()), value: donation});
            jbMultiTerminal().addToBalanceOf({
                projectId: fixture.projectId,
                token: address(fixture.underlying),
                amount: donation,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });
        }
        fixture.distributor = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        fixture.adapter =
            new JBStickyAutoStick({deployer: _deployer, distributor: IJBDistributor(address(fixture.distributor))});
        fixture.underlying.mint({beneficiary: address(this), amount: reward});
        fixture.underlying.approve({spender: address(fixture.distributor), value: reward});
        fixture.distributor
            .fund({hook: address(fixture.stickyToken), token: IERC20(address(fixture.underlying)), amount: reward});
        vm.startPrank(_holder);
        fixture.underlying.approve({spender: address(fixture.adapter), value: type(uint256).max});
        _deployer.HOOK().setTrustedSenderFor({
            projectId: fixture.projectId, sender: address(fixture.adapter), trusted: true
        });
        fixture.adapter.setConfigFor({projectId: fixture.projectId, enabled: true, minimumAmount: 1, cooldown: 1 days});
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 1);
        fixture.adapter.beginVestingFor({projectId: fixture.projectId, holder: _holder});
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);
    }
}
