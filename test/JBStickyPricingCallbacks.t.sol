// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JBStickyDeployer} from "../src/JBStickyDeployer.sol";
import {JBStickyDistributor} from "../src/JBStickyDistributor.sol";
import {JBStickyHook} from "../src/JBStickyHook.sol";
import {JBStickyRewardReceiverFactory} from "../src/JBStickyRewardReceiverFactory.sol";

import {IJBStickyDistributor} from "../src/interfaces/IJBStickyDistributor.sol";
import {IJBStickyHook} from "../src/interfaces/IJBStickyHook.sol";

import {JBStickyCallbackToken} from "./helpers/JBStickyCallbackToken.sol";

/// @notice Records what the hook reports about a payment in progress at the moment it is called.
contract JBStickyPayingProbe {
    /// @notice Whether the hook reported a payment in progress during the last probe.
    bool public wasPaying;

    /// @notice Read the hook's payment flag for a project.
    /// @param hook The Sticky hook to read.
    /// @param projectId The ID of the sticky project.
    function probe(IJBStickyHook hook, uint256 projectId) external {
        wasPaying = hook.isPayingFor(projectId);
    }
}

/// @notice Real terminal callbacks cannot change supply or backing between Sticky pricing and stake accounting, and
/// cannot record a tenure denominator while the minted shares have no tranche.
contract JBStickyPricingCallbacksTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The distributor whose tenure denominators read the hook's buckets.
    JBStickyDistributor internal _distributor;

    /// @notice The account whose outer payment is targeted by the token callback.
    address internal _holder = makeAddr("outer payer");

    /// @notice The deployed Sticky accounting hook.
    IJBStickyHook internal _hook;

    /// @notice The factory whose receivers settle into the distributor.
    JBStickyRewardReceiverFactory internal _receiverFactory;

    /// @notice A plain ERC-20 handed out as a reward; its callback is never armed.
    JBStickyCallbackToken internal _reward;

    /// @notice The Sticky project used by the callback tests.
    uint256 internal _projectId;

    /// @notice The project's Sticky share token.
    IJBToken internal _stickyToken;

    /// @notice The callback-capable underlying token, also an existing Sticky holder.
    JBStickyCallbackToken internal _underlying;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Launch a real project and give the underlying token its own funded, approved initial stake.
    function setUp() public override {
        super.setUp();
        _underlying = new JBStickyCallbackToken();
        JBStickyDeployer deployer = new JBStickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = deployer.HOOK();
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        _projectId = deployer.deployStickyFor{value: fee}({
            stakedToken: IERC20Metadata(address(_underlying)),
            name: "Sticky Callback",
            symbol: "stCALL",
            projectUri: "",
            cashOutTaxRate: 0,
            granters: new address[](0),
            soulbound: true
        });
        _stickyToken = jbTokens().tokenOf(_projectId);
        _distributor = new JBStickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            initialRoundDuration: 1 days,
            initialVestingRounds: 1,
            initialClaimDuration: 30 days
        });
        _receiverFactory = new JBStickyRewardReceiverFactory(_distributor);
        _reward = new JBStickyCallbackToken();
        _underlying.mint({beneficiary: address(_underlying), amount: 100e18});
        _underlying.mint({beneficiary: _holder, amount: 100e18});
        _underlying.approveFromSelf({spender: address(jbMultiTerminal()), amount: type(uint256).max});
        vm.prank(_holder);
        _underlying.approve({spender: address(jbMultiTerminal()), value: 100e18});
        _underlying.execute({
            target: address(jbMultiTerminal()), data: _paymentData({beneficiary: address(_underlying), amount: 10e18})
        });
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice A callback donation changes backing alone and reverts both the donation and outer stake.
    function test_callbackDonationRevertsAtomically() public {
        bytes memory data =
            abi.encodeCall(IJBTerminal.addToBalanceOf, (_projectId, address(_underlying), 3e18, false, "", bytes("")));
        _assertCallbackReverts({
            target: address(jbMultiTerminal()), data: data, actualSupply: 15e18, actualBacking: 18e18
        });
    }

    /// @notice Group 0 weighs a past block, so funding it from the mint gap records nothing unrecorded and succeeds.
    function test_callbackGroupZeroFundingSucceedsWhilePaying() public {
        _prepareCallbackFunding(1e18);
        _underlying.configureCallback({
            terminal: address(jbMultiTerminal()),
            hook: address(_hook),
            target: address(_distributor),
            data: abi.encodeCall(IJBStickyDistributor.fund, (address(_stickyToken), IERC20(address(_reward)), 1e18, 0))
        });

        vm.prank(_holder);
        uint256 minted = jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: 5e18,
            beneficiary: _holder,
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });

        assertEq(minted, 5e18);
        assertEq(_underlying.callbackCount(), 1);
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(address(_reward))), 1e18);
        assertEq(_hook.stakedBalanceOf(_projectId, _holder), 5e18);
        assertFalse(_hook.isPayingFor(_projectId));
    }

    /// @notice A successful nested self-payment changes both supply and backing and rolls back completely.
    function test_callbackNestedPaymentRevertsAtomically() public {
        _assertCallbackReverts({
            target: address(jbMultiTerminal()),
            data: _paymentData({beneficiary: address(_underlying), amount: 2e18}),
            actualSupply: 17e18,
            actualBacking: 17e18
        });
    }

    /// @notice The hook flags the payment only between the terminal's mint and its after-pay callback.
    function test_callbackProbeSeesPaymentInProgress() public {
        JBStickyPayingProbe probe = new JBStickyPayingProbe();
        assertFalse(_hook.isPayingFor(_projectId));
        _underlying.configureCallback({
            terminal: address(jbMultiTerminal()),
            hook: address(_hook),
            target: address(probe),
            data: abi.encodeCall(JBStickyPayingProbe.probe, (_hook, _projectId))
        });

        vm.prank(_holder);
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: 5e18,
            beneficiary: _holder,
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });

        assertTrue(probe.wasPaying(), "the mint gap is flagged");
        assertFalse(_hook.isPayingFor(_projectId), "the after-pay callback clears the flag");
        assertEq(_underlying.callbackCount(), 1);
        assertEq(_hook.stakedBalanceOf(_projectId, _holder), 5e18);
    }

    /// @notice Settling a prefunded tenure receiver from the mint gap reverts instead of recording a denominator.
    function test_callbackReceiverSettlementRevertsWhilePaying() public {
        address receiver = _receiverFactory.predictReceiverOf({stickyToken: address(_stickyToken), groupId: 1000});
        _reward.mint({beneficiary: receiver, amount: 1e18});
        _assertFundingCallbackReverts({
            target: address(_receiverFactory),
            data: abi.encodeCall(
                JBStickyRewardReceiverFactory.settleFor, (address(_stickyToken), 1000, IERC20(address(_reward)))
            )
        });
        assertEq(_reward.balanceOf(receiver), 1e18);
    }

    /// @notice Funding a tenure group from the mint gap reverts instead of recording a denominator that counts the
    /// unrecorded mint.
    function test_callbackTenureFundingRevertsWhilePaying() public {
        _prepareCallbackFunding(1e18);
        _assertFundingCallbackReverts({
            target: address(_distributor),
            data: abi.encodeCall(
                IJBStickyDistributor.fund, (address(_stickyToken), IERC20(address(_reward)), 1e18, 1000)
            )
        });
        assertEq(_reward.balanceOf(address(_underlying)), 1e18);
    }

    /// @notice A holder's callback burn changes supply alone and cannot invalidate the outer payment's pricing.
    function test_callbackVoluntaryBurnRevertsAtomically() public {
        bytes memory data = abi.encodeCall(IJBController.burnTokensOf, (address(_underlying), _projectId, 1e18, ""));
        _assertCallbackReverts({target: address(jbController()), data: data, actualSupply: 14e18, actualBacking: 15e18});
    }

    /// @notice The same token and terminal complete ordinary stakes when no callback is armed.
    function test_disabledCallbackAllowsPayment() public {
        vm.prank(_holder);
        uint256 minted = jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: 5e18,
            beneficiary: _holder,
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });
        assertEq(minted, 5e18);
        assertEq(_stickyToken.totalSupply(), 15e18);
        assertEq(_stickyToken.balanceOf(_holder), 5e18);
        assertEq(_hook.stakedBalanceOf(_projectId, _holder), 5e18);
        assertEq(_hook.trancheCountOf(_projectId, _holder), 1);
        assertEq(_hook.stakedBalanceOf(_projectId, address(_underlying)), 10e18);
        assertEq(_hook.trancheCountOf(_projectId, address(_underlying)), 1);
        assertEq(jbTerminalStore().balanceOf(address(jbMultiTerminal()), _projectId, address(_underlying)), 15e18);
        assertEq(_underlying.balanceOf(_holder), 95e18);
        assertEq(_underlying.allowance(_holder, address(jbMultiTerminal())), 95e18);
        assertEq(_underlying.callbackCount(), 0);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Prove the nested funding reaches the distributor's payment guard and everything rolls back.
    /// @param target The callback target.
    /// @param data The callback calldata.
    function _assertFundingCallbackReverts(address target, bytes memory data) internal {
        _underlying.configureCallback({
            terminal: address(jbMultiTerminal()), hook: address(_hook), target: target, data: data
        });
        bytes32 beforeState = _stateHash();
        vm.expectCall(target, data);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyCallbackToken.JBStickyCallbackToken_CallFailed.selector,
                abi.encodeWithSelector(
                    JBStickyDistributor.JBStickyDistributor_PaymentInProgress.selector,
                    address(_stickyToken),
                    _projectId
                )
            )
        );
        vm.prank(_holder);
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: 5e18,
            beneficiary: _holder,
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });
        assertEq(_stateHash(), beforeState, "callback and outer payment must roll back atomically");
        assertFalse(_hook.isPayingFor(_projectId), "a reverted payment leaves no flag");
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(address(_reward))), 0);
        assertEq(_underlying.callbackCount(), 0);
    }

    /// @notice Give the underlying token contract reward tokens and an approval so its callback can fund rewards.
    /// @param amount The reward amount in token atoms.
    function _prepareCallbackFunding(uint256 amount) internal {
        _reward.mint({beneficiary: address(_underlying), amount: amount});
        _underlying.execute({
            target: address(_reward), data: abi.encodeCall(IERC20.approve, (address(_distributor), amount))
        });
    }

    /// @notice Prove the nested call reaches the pricing guard and all observed state is restored by the revert.
    /// @param target The callback target.
    /// @param data The callback calldata.
    /// @param actualSupply The supply after the nested operation but before the outer hook runs.
    /// @param actualBacking The backing after the nested operation but before the outer hook runs.
    function _assertCallbackReverts(
        address target,
        bytes memory data,
        uint256 actualSupply,
        uint256 actualBacking
    )
        internal
    {
        _underlying.configureCallback({
            terminal: address(jbMultiTerminal()), hook: address(_hook), target: target, data: data
        });
        bytes32 beforeState = _stateHash();
        vm.expectCall(target, data);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBStickyHook.JBStickyHook_PricingStateChanged.selector,
                _projectId,
                15e18,
                actualSupply,
                15e18,
                actualBacking
            )
        );
        vm.prank(_holder);
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            amount: 5e18,
            beneficiary: _holder,
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });
        assertEq(_stateHash(), beforeState, "callback and outer payment must roll back atomically");
        assertTrue(_underlying.callbackEnabled(), "arming state also rolls back");
        assertEq(_underlying.callbackCount(), 0);
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Encode a payment whose caller is the underlying token contract itself.
    /// @param beneficiary The payment beneficiary.
    /// @param amount The amount in underlying token atoms.
    /// @return data The encoded terminal payment.
    function _paymentData(address beneficiary, uint256 amount) internal view returns (bytes memory data) {
        return
            abi.encodeCall(
                IJBTerminal.pay, (_projectId, address(_underlying), amount, beneficiary, amount, "", bytes(""))
            );
    }

    /// @notice Hash balances, allowances, supply, terminal accounting, and both holders' entire active positions.
    /// @return stateHash The hash of the state that either nested or outer operations could change.
    function _stateHash() internal view returns (bytes32 stateHash) {
        bytes32 balances = keccak256(
            abi.encode(
                _underlying.balanceOf(address(jbMultiTerminal())),
                _underlying.balanceOf(_holder),
                _underlying.balanceOf(address(_underlying)),
                _underlying.allowance(_holder, address(jbMultiTerminal())),
                _underlying.allowance(address(_underlying), address(jbMultiTerminal())),
                _underlying.allowance(address(jbMultiTerminal()), address(_hook)),
                _stickyToken.totalSupply(),
                _stickyToken.balanceOf(_holder),
                _stickyToken.balanceOf(address(_underlying)),
                jbTerminalStore().balanceOf(address(jbMultiTerminal()), _projectId, address(_underlying)),
                _hook.orphanedBalanceOf(_projectId)
            )
        );
        return keccak256(
            abi.encode(
                balances,
                _hook.stakedBalanceOf(_projectId, _holder),
                _hook.stakedBalanceOf(_projectId, address(_underlying)),
                _hook.tranchesOf(_projectId, _holder),
                _hook.tranchesOf(_projectId, address(_underlying)),
                _hook.streakStartOf(_projectId, _holder),
                _hook.streakStartOf(_projectId, address(_underlying)),
                _hook.longestStreakOf(_projectId, _holder),
                _hook.longestStreakOf(_projectId, address(_underlying))
            )
        );
    }
}
