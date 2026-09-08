// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";
import {JBStickyTranche} from "../src/structs/JBStickyTranche.sol";
import {MockArt} from "./JBSticky_Integration.t.sol";

/// @notice Real Juicebox controller and terminal burns keep sticky accounting synchronized in both token modes.
contract JBStickyBurnIntegrationTest is TestBaseWorkflow {
    address internal _holder = makeAddr("holder");
    MockArt internal _art;
    JBStickyDeployer internal _deployer;
    IJBStickyHook internal _hook;

    function setUp() public override {
        super.setUp();
        _art = new MockArt();
        _deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = _deployer.HOOK();
        _art.mint({to: _holder, amount: 100e6});
        vm.prank(_holder);
        _art.approve({spender: address(jbMultiTerminal()), value: type(uint256).max});
    }

    function test_controllerBurnAndTerminalCashoutRemainSynchronizedSoulbound() public {
        _exerciseBurns(true);
    }

    function test_controllerBurnAndTerminalCashoutRemainSynchronizedTransferable() public {
        _exerciseBurns(false);
    }

    function _exerciseBurns(bool soulbound) internal {
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        uint256 projectId = _deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_art)),
            name: "Sticky ART",
            symbol: "stART",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: soulbound
        });
        IJBToken token = jbTokens().tokenOf(projectId);
        uint256 start = vm.getBlockTimestamp();
        uint256 firstMint = _stake(projectId, 10e6);
        vm.warp(start + 10 days);
        uint256 secondMint = _stake(projectId, 5e6);
        uint256 partialBurn = secondMint + firstMint / 5;
        uint256 underlyingBefore = _art.balanceOf(_holder);
        vm.prank(_holder);
        jbController().burnTokensOf({holder: _holder, projectId: projectId, tokenCount: partialBurn, memo: ""});
        // Controller burns are voluntary and reclaim no underlying backing.
        assertEq(_art.balanceOf(_holder), underlyingBefore);
        assertEq(token.balanceOf(_holder), firstMint + secondMint - partialBurn);
        assertEq(_hook.stakedBalanceOf(projectId, _holder), token.balanceOf(_holder));
        JBStickyTranche[] memory tranches = _hook.tranchesOf(projectId, _holder);
        assertEq(tranches.length, 1);
        assertEq(tranches[0].timestamp, start);
        assertEq(tranches[0].amount, firstMint - firstMint / 5);
        assertEq(_hook.currentStreakOf(projectId, _holder), 10 days);

        // The terminal's controller burn consumes the final tranche exactly once.
        vm.warp(start + 20 days);
        uint256 finalBalance = token.balanceOf(_holder);
        vm.prank(_holder);
        jbMultiTerminal().cashOutTokensOf({
            holder: _holder,
            projectId: projectId,
            cashOutCount: finalBalance,
            tokenToReclaim: address(_art),
            minTokensReclaimed: 0,
            beneficiary: payable(_holder),
            metadata: bytes("")
        });
        assertEq(token.balanceOf(_holder), 0);
        assertEq(_hook.stakedBalanceOf(projectId, _holder), 0);
        assertEq(_hook.trancheCountOf(projectId, _holder), 0);
        assertEq(_hook.streakStartOf(projectId, _holder), 0);
        assertEq(_hook.longestStreakOf(projectId, _holder), 20 days);

        // A full voluntary burn also ends the streak, and the next stake starts a fresh position.
        vm.warp(start + 30 days);
        uint256 restaked = _stake(projectId, 1e6);
        assertGt(restaked, 0);
        assertEq(_hook.currentStreakOf(projectId, _holder), 0);
        vm.warp(start + 35 days);
        vm.prank(_holder);
        jbController().burnTokensOf({holder: _holder, projectId: projectId, tokenCount: restaked, memo: ""});
        assertEq(_hook.stakedBalanceOf(projectId, _holder), 0);
        assertEq(_hook.trancheCountOf(projectId, _holder), 0);
        assertEq(_hook.streakStartOf(projectId, _holder), 0);
        vm.warp(start + 365 days);
        _stake(projectId, 1e6);
        assertEq(_hook.currentStreakOf(projectId, _holder), 0);
        assertEq(_hook.stakedBalanceOf(projectId, _holder), token.balanceOf(_holder));
    }

    function _stake(uint256 projectId, uint256 amount) internal returns (uint256) {
        vm.prank(_holder);
        return jbMultiTerminal().pay({
            projectId: projectId,
            token: address(_art),
            amount: amount,
            beneficiary: _holder,
            minReturnedTokens: 1,
            memo: "",
            metadata: bytes("")
        });
    }
}
