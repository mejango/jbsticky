// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {JBStickyHook} from "./JBStickyHook.sol";
import {JBStickyPriceFeed} from "./JBStickyPriceFeed.sol";
import {JBStickyToken} from "./JBStickyToken.sol";

import {IJBStickyDeployer} from "./interfaces/IJBStickyDeployer.sol";
import {IJBStickyHook} from "./interfaces/IJBStickyHook.sol";

/// @notice Deploys permanently configured staking projects with backing-priced shares, a chosen cash-out tax and
/// optional soulbound transfers. Owns each project's NFT without exposing any operation to change its rules,
/// terminals, metadata, token or ownership, or withdraw project funds.
contract JBStickyDeployer is IERC721Receiver, IJBStickyDeployer {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a commitment reward is above the maximum cash out tax rate.
    error JBStickyDeployer_InvalidCashOutTaxRate(uint256 rate, uint256 max);

    /// @notice The core price registry does not support a zero currency ID.
    error JBStickyDeployer_InvalidCurrency(address token);

    /// @notice Feed registration and payment pricing must use the same core registry.
    error JBStickyDeployer_PriceRegistryMismatch(address controllerPrices, address terminalPrices);

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

    /// @notice The immutable feed providing the denominator for a project's exact share issuance ratio.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => IJBPriceFeed) public override priceFeedOf;

    /// @notice The token a sticky project accepts for staking.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => IERC20Metadata) public override stakedTokenOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Bind every launched project to the same controller, terminal and position-accounting hook.
    /// @param controller The controller used to launch and manage sticky projects.
    /// @param terminal The terminal sticky projects accept their staked token through.
    constructor(IJBController controller, IJBTerminal terminal) {
        address controllerPrices = address(controller.PRICES());
        address terminalPrices = address(IJBMultiTerminal(address(terminal)).STORE().PRICES());
        if (controllerPrices != terminalPrices) {
            revert JBStickyDeployer_PriceRegistryMismatch({
                controllerPrices: controllerPrices, terminalPrices: terminalPrices
            });
        }
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
    /// @param name The name of the share token issued to represent staked positions.
    /// @param symbol The symbol of the share token issued to represent staked positions.
    /// @param projectUri The sticky project's metadata URI.
    /// @param cashOutTaxRate The portion of an unwind left behind for remaining stakers — the project's commitment
    /// reward — out of `JBConstants.MAX_CASH_OUT_TAX_RATE`. Zero uses proportional redemption of share-owned
    /// backing. Positive values apply the protocol's cash-out curve; the maximum returns no backing. Terminal fee
    /// rules apply independently, including any fee-free intra-terminal balance allowances.
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

        // A distinct synthetic currency makes core use the project's exact backing denominator for issuance.
        uint32 currency = uint32(uint160(address(stakedToken)));
        if (currency == 0) revert JBStickyDeployer_InvalidCurrency(address(stakedToken));
        uint32 baseCurrency = currency == type(uint32).max ? type(uint32).max - 1 : type(uint32).max;

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
                baseCurrency: baseCurrency,
                pausePay: false,
                pauseCreditTransfers: true,
                allowOwnerMinting: false,
                allowSetCustomToken: true,
                allowTerminalMigration: false,
                allowSetTerminals: false,
                allowSetController: false,
                allowAddAccountingContext: false,
                allowAddPriceFeed: true,
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
        accountingContexts[0] =
            JBAccountingContext({token: address(stakedToken), decimals: stakedToken.decimals(), currency: currency});
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

        // Deploy the share token representing staked positions, bound to this project.
        IJBToken token = new JBStickyToken({
            name: name, symbol: symbol, tokens: TOKENS, projectId: projectId, hook: HOOK, soulbound: soulbound
        });

        // Attach the token and register it as the project's transfer and burn reporter. The custom-token flag is
        // needed for this attachment; this permanent owner exposes no later token-setting operation.
        CONTROLLER.setTokenFor({projectId: projectId, token: token});
        HOOK.setTokenFor({projectId: projectId, token: address(token)});

        // The price-feed flag allows this initial registration. This owner exposes no later feed-setting method.
        IJBPriceFeed feed = new JBStickyPriceFeed({
            hook: HOOK, terminal: TERMINAL, token: token, projectId: projectId, underlyingToken: address(stakedToken)
        });
        CONTROLLER.addPriceFeedFor({
            projectId: projectId, pricingCurrency: currency, unitCurrency: baseCurrency, feed: feed
        });
        priceFeedOf[projectId] = feed;

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
    /// @param operator The address performing the NFT transfer.
    /// @param from The previous NFT holder.
    /// @param tokenId The NFT ID being received.
    /// @param data Extra transfer data.
    /// @return selector The ERC721 receiver acceptance selector.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    )
        external
        pure
        override
        returns (bytes4 selector)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
