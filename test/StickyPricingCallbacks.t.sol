// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TestBaseWorkflow} from "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StickyDeployer} from "../src/StickyDeployer.sol";
import {StickyDistributor} from "../src/StickyDistributor.sol";
import {StickyHook} from "../src/StickyHook.sol";
import {StickyRewardReceiverFactory} from "../src/StickyRewardReceiverFactory.sol";

import {IStickyDistributor} from "../src/interfaces/IStickyDistributor.sol";
import {IStickyHook} from "../src/interfaces/IStickyHook.sol";

import {StickyCallbackToken} from "./helpers/StickyCallbackToken.sol";

/// @notice Records what the hook reports about a payment in progress at the moment it is called.
// forge-lint: disable-next-line(multi-contract-file)
contract StickyPayingProbe {
    /// @notice Whether the hook reported a payment in progress during the last probe.
    bool public wasPaying;

    /// @notice Read the hook's payment flag for a project.
    /// @param hook The Sticky hook to read.
    /// @param projectId The ID of the sticky project.
    function probe(IStickyHook hook, uint256 projectId) external {
        wasPaying = hook.isPayingFor(projectId);
    }
}

/// @notice Real terminal callbacks cannot change supply or backing between Sticky pricing and stake accounting, and
/// cannot record a tenure denominator while the minted shares have no tranche.
// forge-lint: disable-next-line(multi-contract-file)
contract StickyPricingCallbacksTest is TestBaseWorkflow {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The distributor whose tenure denominators read the hook's buckets.
    StickyDistributor internal _distributor;

    /// @notice The account whose outer payment is targeted by the token callback.
    // forge-lint: disable-next-line(function-init-state)
    address internal _holder = makeAddr("outer payer");

    /// @notice The deployed Sticky accounting hook.
    IStickyHook internal _hook;

    /// @notice The Sticky project used by the callback tests.
    uint256 internal _projectId;

    /// @notice The factory whose receivers settle into the distributor.
    StickyRewardReceiverFactory internal _receiverFactory;

    /// @notice A plain ERC-20 handed out as a reward; its callback is never armed.
    StickyCallbackToken internal _reward;

    /// @notice The project's Sticky share token.
    IJBToken internal _stickyToken;

    /// @notice The callback-capable underlying token, also an existing Sticky holder.
    StickyCallbackToken internal _underlying;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Launch a real project and give the underlying token its own funded, approved initial stake.
    function setUp() public override {
        super.setUp();
        _underlying = new StickyCallbackToken();
        StickyDeployer deployer = new StickyDeployer({controller: jbController(), terminal: jbMultiTerminal()});
        _hook = deployer.HOOK();
        uint256 fee = jbProjects().creationFee();
        vm.deal(address(this), fee);
        // forge-lint: disable-next-item(arbitrary-send-eth)
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
        _distributor = new StickyDistributor({
            controller: jbController(),
            directory: jbDirectory(),
            stickyHook: _hook,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            initialRoundDuration: 1 days,
            initialVestingRounds: 1,
            initialClaimDuration: 30 days
        });
        _receiverFactory = new StickyRewardReceiverFactory(_distributor);
        _reward = new StickyCallbackToken();
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _underlying.mint({beneficiary: address(_underlying), amount: 100e18});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _underlying.mint({beneficiary: _holder, amount: 100e18});
        _underlying.approveFromSelf({spender: address(jbMultiTerminal()), amount: type(uint256).max});
        vm.prank(_holder);
        // forge-lint: disable-next-line(literal-instead-of-constant,unused-return)
        _underlying.approve({spender: address(jbMultiTerminal()), value: 100e18});
        _underlying.execute({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            target: address(jbMultiTerminal()),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            data: _paymentData({beneficiary: address(_underlying), amount: 10e18})
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice A callback donation changes backing alone and reverts both the donation and outer stake.
    function test_callbackDonationRevertsAtomically() public {
        bytes memory data =
        // forge-lint: disable-next-line(boolean-cst)
        abi.encodeCall(IJBTerminal.addToBalanceOf, (_projectId, address(_underlying), 3e18, false, "", bytes("")));
        _assertCallbackReverts({
            // forge-lint: disable-next-line(literal-instead-of-constant)
            target: address(jbMultiTerminal()),
            data: data,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            actualSupply: 15e18,
            actualBacking: 18e18
        });
    }

    /// @notice Group 0 weighs a past block, so funding it from the mint gap records nothing unrecorded and succeeds.
    function test_callbackGroupZeroFundingSucceedsWhilePaying() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _prepareCallbackFunding(1e18);
        _underlying.configureCallback({
            terminal: address(jbMultiTerminal()),
            hook: address(_hook),
            target: address(_distributor),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            data: abi.encodeCall(IStickyDistributor.fund, (address(_stickyToken), IERC20(address(_reward)), 1e18, 0))
        });

        vm.prank(_holder);
        uint256 minted = jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 5e18,
            beneficiary: _holder,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });

        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(minted, 5e18);
        assertEq(_underlying.callbackCount(), 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_distributor.balanceOf(address(_stickyToken), IERC20(address(_reward))), 1e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_hook.stakedBalanceOf(_projectId, _holder), 5e18);
        assertFalse(_hook.isPayingFor(_projectId));
    }

    /// @notice A successful nested self-payment changes both supply and backing and rolls back completely.
    function test_callbackNestedPaymentRevertsAtomically() public {
        _assertCallbackReverts({
            target: address(jbMultiTerminal()),
            data: _paymentData({beneficiary: address(_underlying), amount: 2e18}),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            actualSupply: 17e18,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            actualBacking: 17e18
        });
    }

    /// @notice The hook flags the payment only between the terminal's mint and its after-pay callback.
    function test_callbackProbeSeesPaymentInProgress() public {
        StickyPayingProbe probe = new StickyPayingProbe();
        assertFalse(_hook.isPayingFor(_projectId));
        _underlying.configureCallback({
            terminal: address(jbMultiTerminal()),
            hook: address(_hook),
            target: address(probe),
            data: abi.encodeCall(StickyPayingProbe.probe, (_hook, _projectId))
        });

        vm.prank(_holder);
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 5e18,
            beneficiary: _holder,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });

        assertTrue(probe.wasPaying(), "the mint gap is flagged");
        assertFalse(_hook.isPayingFor(_projectId), "the after-pay callback clears the flag");
        assertEq(_underlying.callbackCount(), 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_hook.stakedBalanceOf(_projectId, _holder), 5e18);
    }

    /// @notice Settling a prefunded tenure receiver from the mint gap reverts instead of recording a denominator.
    function test_callbackReceiverSettlementRevertsWhilePaying() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        address receiver = _receiverFactory.predictReceiverOf({stickyToken: address(_stickyToken), groupId: 1000});
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _reward.mint({beneficiary: receiver, amount: 1e18});
        _assertFundingCallbackReverts({
            target: address(_receiverFactory),
            data: abi.encodeCall(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                StickyRewardReceiverFactory.settleFor,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                (address(_stickyToken), 1000, IERC20(address(_reward)))
            )
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_reward.balanceOf(receiver), 1e18);
    }

    /// @notice Funding a tenure group from the mint gap reverts instead of recording a denominator that counts the
    /// unrecorded mint.
    function test_callbackTenureFundingRevertsWhilePaying() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _prepareCallbackFunding(1e18);
        _assertFundingCallbackReverts({
            target: address(_distributor),
            data: abi.encodeCall(
                // forge-lint: disable-next-line(literal-instead-of-constant)
                IStickyDistributor.fund,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                (address(_stickyToken), IERC20(address(_reward)), 1e18, 1000)
            )
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_reward.balanceOf(address(_underlying)), 1e18);
    }

    /// @notice A holder's callback burn changes supply alone and cannot invalidate the outer payment's pricing.
    function test_callbackVoluntaryBurnRevertsAtomically() public {
        // forge-lint: disable-next-line(literal-instead-of-constant)
        bytes memory data = abi.encodeCall(IJBController.burnTokensOf, (address(_underlying), _projectId, 1e18, ""));
        // forge-lint: disable-next-line(literal-instead-of-constant)
        _assertCallbackReverts({target: address(jbController()), data: data, actualSupply: 14e18, actualBacking: 15e18});
    }

    /// @notice The same token and terminal complete ordinary stakes when no callback is armed.
    function test_disabledCallbackAllowsPayment() public {
        vm.prank(_holder);
        uint256 minted = jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 5e18,
            beneficiary: _holder,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(minted, 5e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_stickyToken.totalSupply(), 15e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_stickyToken.balanceOf(_holder), 5e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_hook.stakedBalanceOf(_projectId, _holder), 5e18);
        assertEq(_hook.trancheCountOf(_projectId, _holder), 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_hook.stakedBalanceOf(_projectId, address(_underlying)), 10e18);
        assertEq(_hook.trancheCountOf(_projectId, address(_underlying)), 1);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(jbTerminalStore().balanceOf(address(jbMultiTerminal()), _projectId, address(_underlying)), 15e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.balanceOf(_holder), 95e18);
        // forge-lint: disable-next-line(literal-instead-of-constant)
        assertEq(_underlying.allowance(_holder, address(jbMultiTerminal())), 95e18);
        assertEq(_underlying.callbackCount(), 0);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

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
                StickyHook.StickyHook_PricingStateChanged.selector,
                _projectId,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                15e18,
                actualSupply,
                // forge-lint: disable-next-line(literal-instead-of-constant)
                15e18,
                actualBacking
            )
        );
        vm.prank(_holder);
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 5e18,
            beneficiary: _holder,
            // forge-lint: disable-next-line(literal-instead-of-constant)
            minReturnedTokens: 5e18,
            memo: "",
            metadata: bytes("")
        });
        assertEq(_stateHash(), beforeState, "callback and outer payment must roll back atomically");
        assertTrue(_underlying.callbackEnabled(), "arming state also rolls back");
        assertEq(_underlying.callbackCount(), 0);
    }

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
                StickyCallbackToken.StickyCallbackToken_CallFailed.selector,
                abi.encodeWithSelector(
                    StickyDistributor.StickyDistributor_PaymentInProgress.selector, address(_stickyToken), _projectId
                )
            )
        );
        vm.prank(_holder);
        jbMultiTerminal().pay({
            projectId: _projectId,
            token: address(_underlying),
            // forge-lint: disable-next-line(literal-instead-of-constant)
            amount: 5e18,
            beneficiary: _holder,
            // forge-lint: disable-next-line(literal-instead-of-constant)
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

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
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
