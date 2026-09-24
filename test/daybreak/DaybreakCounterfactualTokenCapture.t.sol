// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StickyDeployer} from "../../src/StickyDeployer.sol";
import {StickyDistributor} from "../../src/StickyDistributor.sol";
import {StickyRewardReceiverFactory} from "../../src/StickyRewardReceiverFactory.sol";

/// @notice A freely mintable ERC-20 standing in for a reward or staked asset.
// forge-lint: disable-next-line(multi-contract-file)
contract DaybreakMintableToken is ERC20 {
    /// @notice Initializes the token's name and symbol.
    /// @param name The token name.
    /// @param symbol The token symbol.
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice Mints tokens to an account.
    /// @param beneficiary The account receiving the tokens.
    /// @param amount The amount to mint, in token atoms.
    function mint(address beneficiary, uint256 amount) external {
        _mint({account: beneficiary, value: amount});
    }
}

/// @notice Share tokens are CREATE2-bound to their launcher and configuration, so a receiver prefunded for a
/// launcher's predicted token cannot be captured by whoever launches first, and the launcher's own launch lands on
/// the prediction made for the project ID it receives.
// forge-lint: disable-next-line(multi-contract-file)
contract DaybreakCounterfactualTokenCaptureTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The account that launches first with the victim's configuration.
    // forge-lint: disable-next-line(function-init-state)
    address internal _attacker = makeAddr("counterfactual token attacker");

    /// @notice The Sticky factory under test.
    StickyDeployer internal _deployer;

    /// @notice The distributor that receives settled rewards.
    StickyDistributor internal _distributor;

    /// @notice The project creation fee.
    uint256 internal _fee;

    /// @notice The factory that predicts and deploys counterfactual reward receivers.
    StickyRewardReceiverFactory internal _receiverFactory;

    /// @notice The token sent to the prefunded receiver.
    DaybreakMintableToken internal _rewardToken;

    /// @notice The asset staked by both launchers' configurations.
    DaybreakMintableToken internal _underlying;

    /// @notice The account whose predicted token address is prefunded.
    // forge-lint: disable-next-line(function-init-state)
    address internal _victim = makeAddr("counterfactual token victim");

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    function setUp() public override {
        super.setUp();

        _deployer = new StickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _distributor = new StickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _deployer.HOOK(),
            initialRoundDuration: 1 days,
            initialVestingRounds: 1,
            initialClaimDuration: 30 days
        });
        _receiverFactory = new StickyRewardReceiverFactory(_distributor);
        _rewardToken = new DaybreakMintableToken("Victim reward", "RWD");
        _underlying = new DaybreakMintableToken("Shared asset", "AST");
        _fee = jbProjects().creationFee();
    }

    /// @notice An attacker who front-runs the victim's launch with the victim's exact configuration gets a token
    /// bound to the attacker, never the address the victim predicted, and cannot settle the victim's prefunding.
    function test_earlierLauncherCannotTakeAPredictedTokenAddress() public {
        uint256 nextProjectId = jbProjects().count() + 1;
        address victimExpectedStickyToken = _predictFor({launcher: _victim, projectId: nextProjectId});
        assertEq(victimExpectedStickyToken.code.length, 0);

        // The counterfactual flow lets rewards arrive at the future token's receiver before either exists.
        address prefundedReceiver =
            _receiverFactory.predictReceiverOf({stickyToken: victimExpectedStickyToken, groupId: 0});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 reward = 100e18;
        _rewardToken.mint({beneficiary: prefundedReceiver, amount: reward});

        // The attacker launches first with the victim's exact configuration and takes the project ID.
        uint256 attackerProjectId = _launchAs(_attacker);
        assertEq(attackerProjectId, nextProjectId);
        IJBToken attackerStickyToken = jbTokens().tokenOf(attackerProjectId);
        assertNotEq(address(attackerStickyToken), victimExpectedStickyToken);
        assertEq(address(attackerStickyToken), _predictFor({launcher: _attacker, projectId: attackerProjectId}));
        assertEq(victimExpectedStickyToken.code.length, 0);

        // Nothing arrived at the attacker's receiver, and the victim's receiver cannot settle to a token that does
        // not exist, so the prefunding stays where it was sent.
        assertEq(
            _rewardToken.balanceOf(
                _receiverFactory.predictReceiverOf({stickyToken: address(attackerStickyToken), groupId: 0})
            ),
            0
        );
        vm.expectRevert();
        // forge-lint: disable-next-item(unused-return)
        _receiverFactory.settleFor({
            stickyToken: victimExpectedStickyToken, groupId: 0, token: IERC20(address(_rewardToken))
        });
        assertEq(_rewardToken.balanceOf(prefundedReceiver), reward);
    }

    /// @notice A launch lands exactly on the launcher's prediction for the project ID it receives, so a receiver
    /// prefunded against that prediction pays the launcher's holders.
    function test_launchLandsOnThePredictedTokenAddress() public {
        uint256 nextProjectId = jbProjects().count() + 1;
        address expectedStickyToken = _predictFor({launcher: _victim, projectId: nextProjectId});
        address prefundedReceiver = _receiverFactory.predictReceiverOf({stickyToken: expectedStickyToken, groupId: 0});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        uint256 reward = 100e18;
        _rewardToken.mint({beneficiary: prefundedReceiver, amount: reward});

        uint256 projectId = _launchAs(_victim);
        assertEq(projectId, nextProjectId);
        assertEq(address(jbTokens().tokenOf(projectId)), expectedStickyToken);

        // The victim stakes, becoming the entire supply, and the prefunding settles into their holders' round.
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _underlying.mint({beneficiary: _victim, amount: 1e18});
        vm.startPrank(_victim);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _underlying.approve({spender: address(jbMultiTerminal()), value: 1e18});
        jbMultiTerminal().pay({
            projectId: projectId,
            token: address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 1e18,
            beneficiary: _victim,
            minReturnedTokens: 1,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(
            _receiverFactory.settleFor({
                stickyToken: expectedStickyToken, groupId: 0, token: IERC20(address(_rewardToken))
            }),
            reward
        );

        vm.warp(_distributor.roundStartTimestamp(1) + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = uint256(uint160(_victim));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_rewardToken));
        _distributor.beginVesting({hook: expectedStickyToken, tokenIds: ids, tokens: tokens});
        vm.warp(_distributor.roundStartTimestamp(3));
        vm.roll(vm.getBlockNumber() + 1);
        _distributor.collectVestedRewards({
            hook: expectedStickyToken, tokenIds: ids, tokens: tokens, beneficiary: _victim
        });
        assertEq(_rewardToken.balanceOf(_victim), reward);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Launches the shared configuration as `launcher`, paying the creation fee.
    /// @param launcher The account that launches and owns the fee.
    /// @return projectId The ID of the launched project.
    function _launchAs(address launcher) internal returns (uint256 projectId) {
        vm.deal(launcher, _fee);
        vm.prank(launcher);
        // forge-lint: disable-next-item(arbitrary-send-eth)
        projectId = _deployer.deployStickyFor{value: _fee}({
            stakedToken: IERC20Metadata(address(_underlying)),
            name: "Victim Sticky",
            symbol: "sVIC",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Predicts the shared configuration's token address for a launcher and project ID.
    /// @param launcher The account expected to launch.
    /// @param projectId The project ID expected at launch.
    /// @return token The predicted Sticky token address.
    function _predictFor(address launcher, uint256 projectId) internal view returns (address token) {
        token = _deployer.predictStickyTokenOf({
            launcher: launcher,
            projectId: projectId,
            stakedToken: IERC20Metadata(address(_underlying)),
            name: "Victim Sticky",
            symbol: "sVIC",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
    }
}
