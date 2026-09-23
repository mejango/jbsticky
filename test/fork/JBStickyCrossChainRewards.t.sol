// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBTokenDistributor} from "@bananapus/distributor-v6/src/JBTokenDistributor.sol";
import {JBSucker} from "@bananapus/suckers-v6/src/JBSucker.sol";
import {JBOptimismSucker} from "@bananapus/suckers-v6/src/JBOptimismSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IOPMessenger} from "@bananapus/suckers-v6/src/interfaces/IOPMessenger.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";
import {JBLeaf} from "@bananapus/suckers-v6/src/structs/JBLeaf.sol";
import {JBMessageRoot} from "@bananapus/suckers-v6/src/structs/JBMessageRoot.sol";
import {JBOutboxTree} from "@bananapus/suckers-v6/src/structs/JBOutboxTree.sol";
import {MerkleLib} from "@bananapus/suckers-v6/src/utils/MerkleLib.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBStickyAutoStick} from "../../src/JBStickyAutoStick.sol";
import {JBStickyHook} from "../../src/JBStickyHook.sol";
import {JBStickyRewardReceiverFactory} from "../../src/JBStickyRewardReceiverFactory.sol";
import {JBStickyToken} from "../../src/JBStickyToken.sol";
import {JBStickyRealProjectContext, JBStickyRealProjectFork} from "./helpers/JBStickyRealProjectFork.sol";

/// @notice The canonical OP messenger entry point used after a portal deposits an L1 message on Base.
interface IStickyOPMessenger {
    /// @notice Relays one cross-domain message after its portal deposit.
    /// @param nonce The source messenger's versioned message nonce.
    /// @param sender The original sender on the source chain.
    /// @param target The receiving contract on this chain.
    /// @param value The native-token amount accompanying the message.
    /// @param minimumGas The minimum gas guaranteed to the receiving call.
    /// @param message The exact calldata emitted by the source messenger.
    function relayMessage(
        uint256 nonce,
        address sender,
        address target,
        uint256 value,
        uint256 minimumGas,
        bytes calldata message
    )
        external
        payable;

    /// @notice Whether the messenger has successfully relayed a message.
    /// @param messageHash The hash of the complete versioned relay calldata.
    /// @return success Whether the target accepted the message.
    function successfulMessages(bytes32 messageHash) external view returns (bool success);
}

/// @notice Bridges Ethereum project 3's real tokens into its Base counterpart's Sticky rewards.
/// @dev Only the portal deposit is simulated: the exact message emitted by the live L1 messenger is passed to the
/// live L2 messenger by its canonical aliased L1 sender, with the corresponding ETH. Both messengers, both suckers,
/// project tokens, project accounting, claims, and the production Sticky suite execute their real code. This does
/// not test the portal's consensus proof, sequencer, finality delay, or an off-chain relayer.
contract JBStickyCrossChainRewardsForkTest is JBStickyRealProjectFork {
    /// @notice A complete native-token message emitted by the deployed L1 messenger.
    /// @custom:member sender The Ethereum sucker that submitted the message.
    /// @custom:member target The Base sucker receiving the message.
    /// @custom:member message The exact remote-call calldata.
    /// @custom:member nonce The messenger's versioned nonce.
    /// @custom:member minimumGas The destination call's gas requirement.
    /// @custom:member value The source outbox's bridged native-token balance.
    struct BridgeMessage {
        address sender;
        address target;
        bytes message;
        uint256 nonce;
        uint256 minimumGas;
        uint256 value;
    }

    /// @notice The production registry shared by Ethereum and Base.
    IJBSuckerRegistry internal constant _SUCKER_REGISTRY =
        IJBSuckerRegistry(0x7903a854aE91eAf635430D120a1a434085cEf297);
    /// @notice Base's cross-domain messenger on Ethereum.
    address internal constant _L1_MESSENGER = 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa;
    /// @notice The canonical OP cross-domain messenger predeploy on Base.
    address internal constant _L2_MESSENGER = 0x4200000000000000000000000000000000000007;
    /// @notice The OP alias applied to an L1 contract that sends a portal deposit.
    uint160 internal constant _ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);
    /// @notice The messenger event that records the original sender, recipient, and calldata.
    bytes32 internal constant _SENT_MESSAGE = keccak256("SentMessage(address,address,bytes,uint256,uint256)");

    JBStickyRealProjectContext internal _ethereum;
    JBStickyRealProjectContext internal _base;
    JBOptimismSucker internal _source;
    JBOptimismSucker internal _destination;
    JBStickyToken internal _sticky;
    uint256 internal _stickyProjectId;
    address internal _receiver;
    address internal _funder = makeAddr("cross-chain reward funder");
    address internal _holder = makeAddr("cross-chain reward holder");
    address internal _keeper = makeAddr("cross-chain reward keeper");

    /// @notice Resolves the production native bridge route and creates a backed Sticky position on its Base peer.
    function setUp() public {
        _ethereum =
            _createProjectFork({rpcAlias: "ethereum", forkBlock: _ETHEREUM_BLOCK, chainId: 1, underlyingProjectId: 3});
        address[] memory suckers = _SUCKER_REGISTRY.suckersOf(3);
        for (uint256 i; i < suckers.length; i++) {
            if (JBSucker(payable(suckers[i])).peerChainId() != 8453) continue;
            try JBOptimismSucker(payable(suckers[i])).OPMESSENGER() returns (IOPMessenger messenger) {
                if (address(messenger) == _L1_MESSENGER) _source = JBOptimismSucker(payable(suckers[i]));
            } catch {}
        }
        assertNotEq(address(_source), address(0), "Ethereum project 3 must have a native Base sucker");
        address peer = address(uint160(uint256(_source.peer())));

        // Resolve the existing destination project from the deployed sucker before launching Sticky around it.
        vm.createSelectFork({urlOrAlias: "base", blockNumber: _BASE_BLOCK});
        _destination = JBOptimismSucker(payable(peer));
        uint256 baseProjectId = _destination.projectId();
        assertEq(_destination.peer(), bytes32(uint256(uint160(address(_source)))));
        assertEq(_destination.peerChainId(), 1);
        assertEq(address(_destination.OPMESSENGER()), _L2_MESSENGER);
        _base = _createProjectFork({
            rpcAlias: "base", forkBlock: _BASE_BLOCK, chainId: 8453, underlyingProjectId: baseProjectId
        });
        assertTrue(_SUCKER_REGISTRY.isSuckerOf({projectId: baseProjectId, addr: address(_destination)}));
        assertTrue(_destination.isMapped(JBConstants.NATIVE_TOKEN));
        (_stickyProjectId, _sticky) = _launchSticky({context: _base, soulbound: true, cashOutTaxRate: 0});
        uint256 acquired = _buyUnderlying({context: _base, holder: _holder, nativeAmount: 0.01 ether});
        _stake({context: _base, projectId: _stickyProjectId, payer: _holder, beneficiary: _holder, amount: acquired});
        vm.roll(block.number + 1);
        _receiver = JBStickyRewardReceiverFactory(_base.suite.rewardReceiverFactory).predictReceiverOf(address(_sticky));
        assertEq(_receiver.code.length, 0, "Rewards can arrive before the receiver is deployed");
    }

    /// @notice A real cross-chain reward reaches a counterfactual receiver, vests, compounds, and remains redeemable.
    function test_ethereumProject3ToBaseReceiver_settleVestCompoundAndExit() public {
        (JBClaim memory claimData, BridgeMessage memory message) = _prepareAndSend();
        _relay(message);
        uint256 supplyBefore = _base.underlying.totalSupply();
        uint256 backingBefore = _base.core.terminal.STORE().balanceOf({
            terminal: address(_base.nativeTerminal),
            projectId: _base.underlyingProjectId,
            token: JBConstants.NATIVE_TOKEN
        });
        vm.prank(_keeper);
        _destination.claim(claimData);
        assertEq(_base.underlying.totalSupply(), supplyBefore + claimData.leaf.projectTokenCount);
        assertEq(_base.underlying.balanceOf(_receiver), claimData.leaf.projectTokenCount);
        assertEq(_base.underlying.balanceOf(_keeper), 0);
        assertEq(
            _base.core.terminal.STORE().balanceOf({
                terminal: address(_base.nativeTerminal),
                projectId: _base.underlyingProjectId,
                token: JBConstants.NATIVE_TOKEN
            }),
            backingBefore + claimData.leaf.terminalTokenAmount
        );
        assertEq(_receiver.code.length, 0);

        uint256 reward = _settle();
        assertEq(reward, claimData.leaf.projectTokenCount);
        _enableAutoStick();
        _vest();
        JBTokenDistributor distributor = JBTokenDistributor(payable(_base.suite.distributor));
        assertEq(
            distributor.collectableFor({
                hook: address(_sticky), tokenId: uint256(uint160(_holder)), token: IERC20(address(_base.underlying))
            }),
            reward
        );
        uint256 sharesBefore = _sticky.balanceOf(_holder);
        vm.prank(_keeper);
        (uint256 compounded, uint256 shares) =
            JBStickyAutoStick(_base.suite.autoStick).compoundFor({projectId: _stickyProjectId, holder: _holder});
        assertEq(compounded, reward);
        assertGt(shares, 0);
        assertEq(_sticky.balanceOf(_holder), sharesBefore + shares);
        assertEq(_base.underlying.balanceOf(_keeper), 0);
        assertEq(_sticky.balanceOf(_keeper), 0);
        assertEq(_base.underlying.balanceOf(_base.suite.autoStick), 0);
        assertEq(_base.underlying.allowance(_base.suite.autoStick, address(_base.core.terminal)), 0);
        assertGt(
            _cashOut({
                context: _base,
                projectId: _stickyProjectId,
                holder: _holder,
                count: _sticky.balanceOf(_holder),
                minimum: 1
            }),
            reward
        );
        assertEq(_sticky.balanceOf(_holder), 0);
    }

    /// @notice Neither a direct caller, an unauthorized deposit caller, nor a different remote sender can set a root.
    function test_ethereumProject3ToBaseReceiver_rejectsUnauthorizedRelayAndRemoteSender() public {
        (, BridgeMessage memory message) = _prepareAndSend();
        vm.selectFork(_base.forkId);
        bytes32 inboxBefore = _destination.inboxOf(JBConstants.NATIVE_TOKEN).root;
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(_keeper)))));
        vm.prank(_keeper);
        _destination.fromRemote(_messageRoot(message));

        vm.expectRevert();
        vm.prank(_keeper);
        IStickyOPMessenger(_L2_MESSENGER).relayMessage({
            nonce: message.nonce,
            sender: message.sender,
            target: message.target,
            value: message.value,
            minimumGas: message.minimumGas,
            message: message.message
        });
        address source = message.sender;
        message.sender = _keeper;
        _deposit(message);
        assertFalse(IStickyOPMessenger(_L2_MESSENGER).successfulMessages(_messageHash(message)));
        assertEq(_destination.inboxOf(JBConstants.NATIVE_TOKEN).root, inboxBefore);
        message.sender = source;
        _relay(message);
    }

    /// @notice A keeper cannot redirect a valid claim or change its metadata or proof.
    function test_ethereumProject3ToBaseReceiver_rejectsTamperedBeneficiaryMetadataAndProof() public {
        (JBClaim memory claimData, BridgeMessage memory message) = _prepareAndSend();
        _relay(message);
        bytes32 beneficiary = claimData.leaf.beneficiary;
        claimData.leaf.beneficiary = bytes32(uint256(uint160(_keeper)));
        _expectInvalidClaim(claimData);
        claimData.leaf.beneficiary = beneficiary;
        bytes32 metadata = claimData.leaf.metadata;
        claimData.leaf.metadata = keccak256("forged metadata");
        _expectInvalidClaim(claimData);
        claimData.leaf.metadata = metadata;
        bytes32 sibling = claimData.proof[0];
        claimData.proof[0] = keccak256("forged proof");
        _expectInvalidClaim(claimData);
        claimData.proof[0] = sibling;
        _destination.claim(claimData);
        assertEq(_base.underlying.balanceOf(_receiver), claimData.leaf.projectTokenCount);
        assertEq(_base.underlying.balanceOf(_keeper), 0);
    }

    /// @notice Messenger replay and duplicate claims cannot mint twice, and repeated empty settlement is harmless.
    function test_ethereumProject3ToBaseReceiver_rejectsMessageReplayAndDoubleClaim() public {
        (JBClaim memory claimData, BridgeMessage memory message) = _prepareAndSend();
        _relay(message);
        vm.expectRevert();
        _deposit(message);
        _destination.claim(claimData);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_LeafAlreadyExecuted.selector, JBConstants.NATIVE_TOKEN, claimData.leaf.index
            )
        );
        _destination.claim(claimData);
        assertEq(_settle(), claimData.leaf.projectTokenCount);
        assertEq(_settle(), 0);
    }

    /// @notice Claiming before message delivery leaves the valid leaf available for a later retry.
    function test_ethereumProject3ToBaseReceiver_claimBeforeMessageArrivalCanRetry() public {
        (JBClaim memory claimData, BridgeMessage memory message) = _prepareAndSend();
        vm.selectFork(_base.forkId);
        _expectInvalidClaim(claimData);
        _relay(message);
        _destination.claim(claimData);
        assertEq(_base.underlying.balanceOf(_receiver), claimData.leaf.projectTokenCount);
    }

    /// @notice A failed source-side minimum returns the wallet, supply, allowance, treasury, and outbox unchanged.
    function test_ethereumProject3ToBaseReceiver_failedPreparePreservesTokensAndOutbox() public {
        vm.selectFork(_ethereum.forkId);
        uint256 reward = _buyUnderlying({context: _ethereum, holder: _funder, nativeAmount: 0.01 ether});
        JBOutboxTree memory beforeOutbox = _source.outboxOf(JBConstants.NATIVE_TOKEN);
        uint256 supplyBefore = _ethereum.underlying.totalSupply();
        uint256 backingBefore = _ethereum.core.terminal.STORE().balanceOf({
            terminal: address(_ethereum.nativeTerminal), projectId: 3, token: JBConstants.NATIVE_TOKEN
        });
        vm.startPrank(_funder);
        _ethereum.underlying.approve({spender: address(_source), value: reward});
        vm.expectPartialRevert(JBMultiTerminal.JBMultiTerminal_UnderMin.selector);
        _source.prepare({
            projectTokenCount: reward,
            beneficiary: bytes32(uint256(uint160(_receiver))),
            minTokensReclaimed: type(uint256).max,
            token: JBConstants.NATIVE_TOKEN,
            metadata: bytes32(0)
        });
        vm.stopPrank();
        assertEq(_ethereum.underlying.balanceOf(_funder), reward);
        assertEq(_ethereum.underlying.totalSupply(), supplyBefore);
        assertEq(_ethereum.underlying.allowance(_funder, address(_source)), reward);
        assertEq(
            _ethereum.core.terminal.STORE().balanceOf({
                terminal: address(_ethereum.nativeTerminal), projectId: 3, token: JBConstants.NATIVE_TOKEN
            }),
            backingBefore
        );
        assertEq(abi.encode(_source.outboxOf(JBConstants.NATIVE_TOKEN)), abi.encode(beforeOutbox));
    }

    /// @notice Pays Ethereum project 3, burns its real tokens, and captures the actual messenger submission.
    /// @return claimData The newly prepared leaf and its proof against the emitted root.
    /// @return message The complete L1 message to replay at the portal deposit boundary.
    function _prepareAndSend() internal returns (JBClaim memory claimData, BridgeMessage memory message) {
        vm.selectFork(_ethereum.forkId);
        uint256 reward = _buyUnderlying({context: _ethereum, holder: _funder, nativeAmount: 0.01 ether});
        JBOutboxTree memory beforeOutbox = _source.outboxOf(JBConstants.NATIVE_TOKEN);
        claimData.token = JBConstants.NATIVE_TOKEN;
        claimData.leaf = JBLeaf({
            index: beforeOutbox.tree.count,
            beneficiary: bytes32(uint256(uint160(_receiver))),
            projectTokenCount: reward,
            terminalTokenAmount: 0,
            metadata: keccak256("Sticky cross-chain rewards")
        });
        // The prior frontier contains every left sibling needed to prove this newly appended leaf. This works even
        // when the production sucker already has transfers; there is no empty-tree assumption or fabricated root.
        bytes32 zero;
        for (uint256 i; i < 32; i++) {
            claimData.proof[i] = (beforeOutbox.tree.count >> i) & 1 == 1 ? beforeOutbox.tree.branch[i] : zero;
            zero = keccak256(abi.encode(zero, zero));
        }
        vm.startPrank(_funder);
        uint256 supplyBefore = _ethereum.underlying.totalSupply();
        _ethereum.underlying.approve({spender: address(_source), value: reward});
        _source.prepare({
            projectTokenCount: reward,
            beneficiary: claimData.leaf.beneficiary,
            minTokensReclaimed: 1,
            token: JBConstants.NATIVE_TOKEN,
            metadata: claimData.leaf.metadata
        });
        vm.stopPrank();
        JBOutboxTree memory afterOutbox = _source.outboxOf(JBConstants.NATIVE_TOKEN);
        claimData.leaf.terminalTokenAmount = afterOutbox.balance - beforeOutbox.balance;
        assertGt(claimData.leaf.terminalTokenAmount, 0);
        assertEq(_ethereum.underlying.balanceOf(_funder), 0);
        assertEq(_ethereum.underlying.totalSupply(), supplyBefore - reward);
        assertEq(afterOutbox.tree.count, beforeOutbox.tree.count + 1);
        uint256 fee = _source.REGISTRY().toRemoteFee();
        vm.deal(_funder, fee);
        vm.recordLogs();
        vm.prank(_funder);
        _source.toRemote{value: fee}(JBConstants.NATIVE_TOKEN);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != _L1_MESSENGER || logs[i].topics[0] != _SENT_MESSAGE) continue;
            (address sender, bytes memory data, uint256 nonce, uint256 gasLimit) =
                abi.decode(logs[i].data, (address, bytes, uint256, uint256));
            if (sender != address(_source)) continue;
            message = BridgeMessage({
                sender: sender,
                target: address(uint160(uint256(logs[i].topics[1]))),
                message: data,
                nonce: nonce,
                minimumGas: gasLimit,
                value: afterOutbox.balance
            });
            found = true;
        }
        assertTrue(found, "The deployed L1 messenger must accept the actual sucker message");
        assertEq(message.target, address(_destination));
        JBMessageRoot memory root = _messageRoot(message);
        assertEq(root.amount, message.value);
        assertEq(
            root.remoteRoot.root,
            MerkleLib.branchRoot({
                item: keccak256(
                    abi.encode(
                        claimData.leaf.projectTokenCount,
                        claimData.leaf.terminalTokenAmount,
                        claimData.leaf.beneficiary,
                        claimData.leaf.metadata
                    )
                ),
                branch: claimData.proof,
                index: claimData.leaf.index
            })
        );
        assertEq(_source.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0);
    }

    /// @notice Delivers the captured source message through Base's actual cross-domain messenger.
    /// @param message The exact message and value emitted on Ethereum.
    function _relay(BridgeMessage memory message) internal {
        vm.selectFork(_base.forkId);
        _deposit(message);
        assertTrue(IStickyOPMessenger(_L2_MESSENGER).successfulMessages(_messageHash(message)));
        assertEq(_destination.inboxOf(JBConstants.NATIVE_TOKEN).root, _messageRoot(message).remoteRoot.root);
    }

    /// @notice Models the portal deposit by impersonating its canonical aliased sender and crediting the sent ETH.
    /// @param message The message being deposited, including the original remote sender.
    function _deposit(BridgeMessage memory message) internal {
        address aliasedSender;
        unchecked {
            aliasedSender = address(uint160(_L1_MESSENGER) + _ALIAS_OFFSET);
        }
        vm.deal(aliasedSender, message.value);
        vm.prank(aliasedSender);
        IStickyOPMessenger(_L2_MESSENGER).relayMessage{value: message.value}({
            nonce: message.nonce,
            sender: message.sender,
            target: message.target,
            value: message.value,
            minimumGas: message.minimumGas,
            message: message.message
        });
    }

    /// @notice Recreates the OP version-1 message hash from the captured relay arguments.
    /// @param message The complete message being relayed.
    /// @return messageHash The hash used by the canonical messenger's replay guard.
    function _messageHash(BridgeMessage memory message) internal pure returns (bytes32 messageHash) {
        return keccak256(
            abi.encodeCall(
                IStickyOPMessenger.relayMessage,
                (message.nonce, message.sender, message.target, message.value, message.minimumGas, message.message)
            )
        );
    }

    /// @notice Decodes the sucker root from the actual messenger calldata after its four-byte selector.
    /// @param message The captured remote call.
    /// @return root The outbox root, bridged value, and source accounting records.
    function _messageRoot(BridgeMessage memory message) internal pure returns (JBMessageRoot memory root) {
        bytes memory arguments = new bytes(message.message.length - 4);
        for (uint256 i; i < arguments.length; i++) {
            arguments[i] = message.message[i + 4];
        }
        return abi.decode(arguments, (JBMessageRoot));
    }

    /// @notice Checks that a rejected proof neither marks the leaf executed nor delivers reward tokens.
    /// @param claimData The unprovable or tampered claim.
    function _expectInvalidClaim(JBClaim memory claimData) internal {
        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        _destination.claim(claimData);
        assertEq(_destination.executedLeafHashOf(JBConstants.NATIVE_TOKEN, claimData.leaf.index), bytes32(0));
        assertEq(_base.underlying.balanceOf(_receiver), 0);
    }

    /// @notice Settles the receiver as an unrelated keeper and checks that its tokens and approval are cleared.
    /// @return amount The reward amount funded into the production distributor.
    function _settle() internal returns (uint256 amount) {
        vm.prank(_keeper);
        amount = JBStickyRewardReceiverFactory(_base.suite.rewardReceiverFactory).settleFor({
            stickyToken: address(_sticky), token: IERC20(address(_base.underlying))
        });
        assertEq(_base.underlying.balanceOf(_receiver), 0);
        assertEq(_base.underlying.allowance(_receiver, _base.suite.distributor), 0);
    }

    /// @notice Gives the adapter only the holder's explicit project trust, token approval, and compounding opt-in.
    function _enableAutoStick() internal {
        vm.startPrank(_holder);
        _base.underlying.approve({spender: _base.suite.autoStick, value: type(uint256).max});
        JBStickyHook(_base.suite.hook).setTrustedSenderFor({
            projectId: _stickyProjectId, sender: _base.suite.autoStick, trusted: true
        });
        JBStickyAutoStick(_base.suite.autoStick).setConfigFor({
            projectId: _stickyProjectId, enabled: true, minimumAmount: 1, cooldown: 1 days
        });
        vm.stopPrank();
    }

    /// @notice Starts the completed reward round's vesting and advances through the production vesting schedule.
    function _vest() internal {
        JBTokenDistributor distributor = JBTokenDistributor(payable(_base.suite.distributor));
        assertEq(distributor.ROUND_DURATION(), 7 days);
        assertEq(distributor.VESTING_ROUNDS(), 4);
        vm.warp(block.timestamp + distributor.ROUND_DURATION() + 1);
        vm.roll(block.number + 1);
        vm.prank(_keeper);
        JBStickyAutoStick(_base.suite.autoStick).beginVestingFor({projectId: _stickyProjectId, holder: _holder});
        vm.warp(block.timestamp + distributor.ROUND_DURATION() * (distributor.VESTING_ROUNDS() + 1));
        vm.roll(block.number + 1);
    }
}
