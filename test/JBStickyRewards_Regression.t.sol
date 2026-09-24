// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JBStickyAutoStick} from "../src/JBStickyAutoStick.sol";
import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {JBAutoStickStatus} from "../src/enums/JBAutoStickStatus.sol";

/// @notice An ERC-20 with configurable decimals that serves as both the staked and the reward token.
// forge-lint: disable-next-line(multi-contract-file)
contract StickyRewardRegressionToken is ERC20 {
    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The number of decimals the token reports.
    uint8 internal immutable _DECIMALS;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param tokenDecimals The number of decimals the token reports.
    constructor(uint8 tokenDecimals) ERC20("Reward regression", "RWD") {
        _DECIMALS = tokenDecimals;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Mints tokens to a beneficiary.
    /// @param beneficiary The account receiving the tokens.
    /// @param amount The number of tokens to mint.
    function mint(address beneficiary, uint256 amount) external {
        _mint({account: beneficiary, value: amount});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The number of decimals the token reports.
    /// @return tokenDecimals The number of decimals.
    function decimals() public view override returns (uint8 tokenDecimals) {
        return _DECIMALS;
    }
}

/// @notice Regressions for compounding distributor rewards through the auto-stick adapter against real V6
/// contracts.
// forge-lint: disable-next-line(multi-contract-file)
contract JBStickyRewardsRegressionTest is TestBaseWorkflow {
    //*********************************************************************//
    // ------------------------------ structs ---------------------------- //
    //*********************************************************************//

    /// @notice One Sticky project with a funded distributor and an enabled auto-stick adapter.
    /// @custom:member underlying The token staked into the project and paid out as its reward.
    /// @custom:member stickyToken The Sticky share token issued by the project.
    /// @custom:member distributor The distributor holding the project's reward.
    /// @custom:member adapter The auto-stick adapter compounding the holder's rewards.
    /// @custom:member projectId The Sticky project's ID.
    struct RewardFixture {
        StickyRewardRegressionToken underlying;
        IJBToken stickyToken;
        JBStickyDistributor distributor;
        JBStickyAutoStick adapter;
        uint256 projectId;
    }

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The deployer that launches every fixture's Sticky project.
    JBStickyDeployer internal _deployer;

    /// @notice The account that stakes into every fixture and whose rewards are compounded.
    // forge-lint: disable-next-line(function-init-state)
    address internal _holder = makeAddr("reward holder");

    /// @notice The account that compounds on the holder's behalf.
    // forge-lint: disable-next-line(function-init-state)
    address internal _keeper = makeAddr("reward keeper");

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
    }

    function test_compoundKeepsZeroIssuanceRewardsClaimable() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 24, reward: 999_999, donation: 0});
        uint256 balanceBefore = fixture.underlying.balanceOf(address(jbMultiTerminal()));
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        (JBAutoStickStatus status,,,) =
            fixture.adapter.statusOf({projectId: fixture.projectId, holder: _holder, groupIds: _defaultGroup()});
        assertEq(uint256(status), uint256(JBAutoStickStatus.ZeroIssuance));

        vm.expectRevert(
            abi.encodeWithSelector(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector,
                fixture.projectId,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                999_999
            )
        );
        vm.prank(_keeper);
        fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder, groupIds: _defaultGroup()});

        _assertRewardUnmoved({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            fixture: fixture,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            reward: 999_999,
            balanceBefore: balanceBefore,
            sharesBefore: sharesBefore
        });
    }

    function test_compoundUsesBackingPriceWithoutChangingBeneficiary() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 6, reward: 10e6, donation: 1e6});
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 preview = _preview({fixture: fixture, amount: 10e6});
        assertGt(preview, 0);
        assertLt(preview, 10e18);
        vm.prank(_keeper);
        (uint256 amount, uint256 count) =
            fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder, groupIds: _defaultGroup()});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 10e6);
        assertEq(count, preview);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore + count);
        assertEq(fixture.stickyToken.balanceOf(_keeper), 0);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(fixture.underlying.balanceOf(_holder), 37);
        assertEq(fixture.underlying.balanceOf(_keeper), 0);
        assertEq(fixture.underlying.balanceOf(address(fixture.adapter)), 0);
        assertEq(fixture.underlying.allowance(address(fixture.adapter), address(jbMultiTerminal())), 0);
    }

    function test_priorPermissionlessCollectionKeepsRewardsWithHolder() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
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
        fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder, groupIds: _defaultGroup()});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(fixture.underlying.balanceOf(_holder), 10e6 + 37);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore);
        assertEq(fixture.underlying.balanceOf(_keeper), 0);
    }

    function test_selfServiceKeepsZeroIssuanceRewardsClaimable() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 24, reward: 999_999, donation: 0});
        uint256 balanceBefore = fixture.underlying.balanceOf(address(jbMultiTerminal()));
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                JBStickyAutoStick.JBStickyAutoStick_ZeroIssuance.selector,
                fixture.projectId,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                999_999
            )
        );
        vm.prank(_holder);
        fixture.adapter.stickRewardsFor({projectId: fixture.projectId, groupIds: _defaultGroup()});

        _assertRewardUnmoved({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            fixture: fixture,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            reward: 999_999,
            balanceBefore: balanceBefore,
            sharesBefore: sharesBefore
        });
    }

    function test_smallest24DecimalIssuanceUsesTerminalPreview() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        RewardFixture memory fixture = _rewardFixture({tokenDecimals: 24, reward: 1e6, donation: 0});
        uint256 sharesBefore = fixture.stickyToken.balanceOf(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 preview = _preview({fixture: fixture, amount: 1e6});
        assertEq(preview, 1);
        vm.prank(_keeper);
        (uint256 amount, uint256 count) =
            fixture.adapter.compoundFor({projectId: fixture.projectId, holder: _holder, groupIds: _defaultGroup()});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(amount, 1e6);
        assertEq(count, preview);
        assertEq(fixture.stickyToken.balanceOf(_holder), sharesBefore + count);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(fixture.underlying.balanceOf(_holder), 37);
        assertEq(fixture.underlying.balanceOf(address(fixture.adapter)), 0);
        assertEq(fixture.underlying.allowance(address(fixture.adapter), address(jbMultiTerminal())), 0);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Previews how many shares the terminal issues to the holder for a payment made by the adapter.
    /// @param fixture The fixture whose project receives the payment.
    /// @param amount The amount of the underlying token the adapter pays.
    /// @return count The number of shares the terminal reports it would issue.
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

    /// @notice Launches a Sticky project, stakes one whole token for the holder, funds a reward and enables the
    /// auto-stick adapter, leaving the reward vested and collectable.
    /// @param tokenDecimals The number of decimals of the underlying token.
    /// @param reward The amount of the underlying token funded into the distributor.
    /// @param donation The amount of the underlying token added to the project's balance without minting shares.
    /// @return fixture The launched project and its distributor and adapter.
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
        // forge-lint: disable-next-item(arbitrary-send-eth)
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
        // forge-lint: disable-next-line(literal-instead-of-constant)
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
        fixture.distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _deployer.HOOK(),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            initialRoundDuration: 1 days,
            initialVestingRounds: 2,
            initialClaimDuration: 30 days
        });
        fixture.adapter = new JBStickyAutoStick({deployer: _deployer, distributor: fixture.distributor});
        fixture.underlying.mint({beneficiary: address(this), amount: reward});
        fixture.underlying.approve({spender: address(fixture.distributor), value: reward});
        fixture.distributor
            .fund({hook: address(fixture.stickyToken), token: IERC20(address(fixture.underlying)), amount: reward});
        vm.startPrank(_holder);
        fixture.underlying.approve({spender: address(fixture.adapter), value: type(uint256).max});
        _deployer.HOOK().setTrustedSenderFor({
            projectId: fixture.projectId, sender: address(fixture.adapter), trusted: true
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        fixture.adapter.setConfigFor({projectId: fixture.projectId, enabled: true, minimumAmount: 1, cooldown: 1 days});
        vm.stopPrank();
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 1);
        fixture.adapter.beginVestingFor({projectId: fixture.projectId, holder: _holder, groupIds: _defaultGroup()});
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice The group ID list selecting only the default group.
    /// @return groupIds A single-element list holding group 0.
    function _defaultGroup() internal pure returns (uint256[] memory groupIds) {
        groupIds = new uint256[](1);
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Asserts that a failed compound left the reward collectable and every balance untouched.
    /// @param fixture The fixture whose reward must remain collectable.
    /// @param reward The amount of the underlying token that must still be collectable by the holder.
    /// @param balanceBefore The terminal's underlying balance before the failed compound.
    /// @param sharesBefore The holder's share balance before the failed compound.
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
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(fixture.underlying.balanceOf(_holder), 37);
        assertEq(fixture.underlying.balanceOf(address(fixture.adapter)), 0);
        assertEq(fixture.underlying.allowance(address(fixture.adapter), address(jbMultiTerminal())), 0);
        (,, uint48 lastCompoundedAt,) = fixture.adapter.configOf({projectId: fixture.projectId, holder: _holder});
        assertEq(lastCompoundedAt, 0);
    }
}
