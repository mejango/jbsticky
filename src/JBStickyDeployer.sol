// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {IJBStickyDeployer} from "./interfaces/IJBStickyDeployer.sol";
import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";
import {JBStickyHook} from "./JBStickyHook.sol";
import {JBStickyToken} from "./JBStickyToken.sol";

/// @notice Deploys sticky projects: locked Juicebox projects that accept a token to stake and issue a soulbound
/// staked copy in return, 1:1, unwindable at any time. This contract owns every sticky project it deploys and
/// exposes no way to change their rules — the single eternal ruleset it launches with (1:1 issuance, zero cash out
/// tax, no fund access, no migrations) is permanent, so stakers never need to trust an owner.
contract JBStickyDeployer is IERC721Receiver, IJBStickyDeployer {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a commitment reward is above the maximum cash out tax rate.
    error JBStickyDeployer_InvalidCashOutTaxRate(uint256 rate, uint256 max);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller used to launch and manage sticky projects.
    IJBController public immutable override CONTROLLER;

    /// @notice The data hook that tracks staking positions for sticky projects.
    IJBStickyHook public immutable override HOOK;

    /// @notice The terminal sticky projects accept their staked token through.
    IJBTerminal public immutable override TERMINAL;

    /// @notice The contract managing token minting and burning for projects.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The portion of an unwind a sticky project leaves behind for remaining stakers — its commitment
    /// reward — out of `JBConstants.MAX_CASH_OUT_TAX_RATE`.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => uint256) public override cashOutTaxRateOf;

    /// @notice The token a sticky project accepts for staking.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => IERC20Metadata) public override stakedTokenOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The controller used to launch and manage sticky projects.
    /// @param terminal The terminal sticky projects accept their staked token through.
    constructor(IJBController controller, IJBTerminal terminal) {
        CONTROLLER = controller;
        TERMINAL = terminal;
        TOKENS = controller.TOKENS();
        HOOK = new JBStickyHook({directory: controller.DIRECTORY(), deployer: address(this)});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys a sticky project for a token.
    /// @dev The `msg.value` must equal the project creation fee required by `JBProjects`.
    /// @param stakedToken The token the project accepts for staking.
    /// @param name The name of the soulbound token issued to represent staked positions.
    /// @param symbol The symbol of the soulbound token issued to represent staked positions.
    /// @param projectUri The sticky project's metadata URI.
    /// @param cashOutTaxRate The portion of an unwind left behind for remaining stakers — the project's commitment
    /// reward — out of `JBConstants.MAX_CASH_OUT_TAX_RATE`. 0 makes unwinds 1:1 and protocol-fee-free; any other
    /// value makes leavers reward stayers, and the Juicebox protocol takes its standard fee on what leavers reclaim.
    /// @param granters Addresses allowed to airdrop stakes to any holder (e.g. the community's grant program).
    /// Permanent — holders can additionally trust senders for their own position at any time.
    /// @param soulbound Whether the staked copy's transfers revert. If false, transfers are allowed and restart the
    /// streak clock on the moved tokens.
    /// @return projectId The ID of the sticky project.
    function deployStickyFor(
        IERC20Metadata stakedToken,
        string calldata name,
        string calldata symbol,
        string calldata projectUri,
        uint256 cashOutTaxRate,
        address[] calldata granters,
        bool soulbound
    )
        external
        payable
        override
        returns (uint256 projectId)
    {
        // Make sure the commitment reward fits the protocol's cash out tax range.
        if (cashOutTaxRate > JBConstants.MAX_CASH_OUT_TAX_RATE) {
            revert JBStickyDeployer_InvalidCashOutTaxRate({
                rate: cashOutTaxRate, max: JBConstants.MAX_CASH_OUT_TAX_RATE
            });
        }

        // Keep a reference to the single eternal ruleset the sticky project will run on.
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                // casting to 'uint16' is safe because the rate is checked against `MAX_CASH_OUT_TAX_RATE` above.
                // forge-lint: disable-next-line(unsafe-typecast)
                cashOutTaxRate: uint16(cashOutTaxRate),
                baseCurrency: uint32(uint160(address(stakedToken))),
                pausePay: false,
                pauseCreditTransfers: true,
                allowOwnerMinting: false,
                allowSetCustomToken: true,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: false,
                ownerMustSendPayouts: false,
                holdFees: false,
                scopeCashOutsToLocalBalances: false,
                useDataHookForPay: true,
                useDataHookForCashOut: true,
                dataHook: address(HOOK),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Keep a reference to the terminal configuration accepting the staked token.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: address(stakedToken),
            decimals: stakedToken.decimals(),
            currency: uint32(uint160(address(stakedToken)))
        });
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: TERMINAL, accountingContextsToAccept: accountingContexts});

        // Launch the sticky project, owned by this contract forever.
        projectId = CONTROLLER.launchProjectFor{value: msg.value}({
            owner: address(this),
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: "JBSticky"
        });

        // Deploy the token representing staked positions, bound to this project.
        IJBToken token = new JBStickyToken({
            name_: name, symbol_: symbol, tokens: TOKENS, projectId: projectId, hook: HOOK, soulbound: soulbound
        });

        // Attach the token to the project, and register it with the hook as the project's transfer reporter.
        CONTROLLER.setTokenFor({projectId: projectId, token: token});
        HOOK.setTokenFor({projectId: projectId, token: address(token)});

        // Allow the project's granters to airdrop stakes to any holder.
        HOOK.setGrantersFor({projectId: projectId, granters: granters});

        // Store the token the project accepts for staking, and the commitment reward its unwinds leave behind.
        stakedTokenOf[projectId] = stakedToken;
        cashOutTaxRateOf[projectId] = cashOutTaxRate;

        emit DeploySticky({
            projectId: projectId,
            stakedToken: stakedToken,
            token: token,
            cashOutTaxRate: cashOutTaxRate,
            soulbound: soulbound,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Accept ownership of the project NFTs minted to this contract when sticky projects launch.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
