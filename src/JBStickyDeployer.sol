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
import {JBPayerTrackerLib} from "@bananapus/core-v6/src/libraries/JBPayerTrackerLib.sol";
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

    /// @notice Thrown when the underlying token maps to currency zero, which the core price registry rejects.
    error JBStickyDeployer_InvalidCurrency(address token);

    /// @notice Thrown when feed registration and payment pricing would use different core price registries.
    error JBStickyDeployer_PriceRegistryMismatch(address controllerPrices, address terminalPrices);

    /// @notice Thrown when the staked token is a share token of a project launched by this deployer.
    error JBStickyDeployer_StakedTokenIsSticky(address token, uint256 projectId);

    /// @notice Thrown when an NFT arrives other than a project NFT minted during this deployer's own launch.
    error JBStickyDeployer_UnexpectedNft(address collection, address from, uint256 tokenId);

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

    /// @notice The project's cash out curve parameter, out of `JBConstants.MAX_CASH_OUT_TAX_RATE`.
    /// @dev The retained proportion also depends on the fraction of supply redeemed; this is not a flat fee.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => uint256) public override cashOutTaxRateOf;

    /// @notice The immutable feed providing the denominator for a project's exact share issuance ratio.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => IJBPriceFeed) public override priceFeedOf;

    /// @notice The token a sticky project accepts for staking.
    /// @custom:param projectId The ID of the sticky project.
    mapping(uint256 projectId => IERC20Metadata) public override stakedTokenOf;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice The account that paid the creation fee for the project currently being launched.
    /// @dev Exposed while the controller launches the project so fee receivers credit the launcher or its upstream
    /// payer. Restored to the previous value after the call so a nested launch preserves the outer payer.
    address public transient override originalPayer;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Bind every launched project to the same controller, terminal and position-accounting hook.
    /// @param controller The controller used to launch and manage sticky projects.
    /// @param terminal The terminal sticky projects accept their staked token through.
    constructor(IJBController controller, IJBTerminal terminal) {
        // Locate the registry where the controller will register each project's issuance feed.
        address controllerPrices = address(controller.PRICES());

        // Read the terminal's actual pricing registry so registration and payment pricing can be compared.
        address terminalPrices = address(IJBMultiTerminal(address(terminal)).STORE().PRICES());

        // Reject a pairing that would leave the terminal unable to read the registered issuance denominator.
        if (controllerPrices != terminalPrices) {
            revert JBStickyDeployer_PriceRegistryMismatch({
                controllerPrices: controllerPrices, terminalPrices: terminalPrices
            });
        }

        // Keep all project launches and initial configuration on the validated controller.
        CONTROLLER = controller;

        // Fix the staking terminal so projects retain the validated pricing path.
        TERMINAL = terminal;

        // Use the controller's token manager as the only authority allowed to mint and burn Sticky shares.
        TOKENS = controller.TOKENS();

        // Share one accounting hook across projects, with this deployer authorized to bind tokens and granters.
        HOOK = new JBStickyHook({directory: controller.DIRECTORY(), deployer: address(this)});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys a sticky project for a token.
    /// @dev The `msg.value` must equal the project creation fee required by `JBProjects`.
    /// @param stakedToken The token the project accepts for staking. Cannot be the share token of another project
    /// launched by this deployer.
    /// @param name The name of the share token issued to represent staked positions.
    /// @param symbol The symbol of the share token issued to represent staked positions.
    /// @param projectUri The sticky project's metadata URI.
    /// @param cashOutTaxRate The cash out curve parameter, out of `JBConstants.MAX_CASH_OUT_TAX_RATE`. Zero uses
    /// proportional redemption of share-owned backing. Positive values apply the protocol's cash-out curve; the maximum
    /// returns no backing. Terminal fee
    /// rules apply independently, including any fee-free intra-terminal balance allowances.
    /// @param granters Addresses allowed to airdrop stakes to any holder (e.g. the community's grant program).
    /// Permanent — holders can additionally trust senders for their own position at any time.
    /// @param soulbound Whether transfers between holders revert. Otherwise, incoming transfers create fresh
    /// tranches; a recipient's existing streak continues until their entire balance leaves.
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
        // Keep the requested cash out curve within the protocol's supported range before launching a project.
        if (cashOutTaxRate > JBConstants.MAX_CASH_OUT_TAX_RATE) {
            revert JBStickyDeployer_InvalidCashOutTaxRate({
                rate: cashOutTaxRate, max: JBConstants.MAX_CASH_OUT_TAX_RATE
            });
        }

        // Match the core convention for identifying an ERC-20 accounting currency from its address.
        uint32 currency = uint32(uint160(address(stakedToken)));

        // The core price registry rejects currency zero, so fail before creating a project that cannot be priced.
        if (currency == 0) revert JBStickyDeployer_InvalidCurrency(address(stakedToken));

        // Find the project, if any, whose share token is the requested staking asset.
        uint256 stakedTokenProjectId = TOKENS.projectIdOf(IJBToken(address(stakedToken)));

        // Reject another Sticky project's shares: every holder self-delegates, so the terminal would hold reward
        // weight in that project's distributor rounds with no way to claim the rewards.
        if (HOOK.tokenOf(stakedTokenProjectId) == address(stakedToken)) {
            revert JBStickyDeployer_StakedTokenIsSticky({token: address(stakedToken), projectId: stakedTokenProjectId});
        }

        // Force a currency conversion so core consults the exact backing denominator instead of using a 1:1 rate.
        uint32 baseCurrency = currency == type(uint32).max ? type(uint32).max - 1 : type(uint32).max;

        // Supply one ruleset so the launcher does not schedule any later change in staking policy.
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);

        // Fix issuance, redemption and administrative restrictions for the lifetime of the project.
        rulesetConfigurations[0] = JBRulesetConfig({
            // Make staking available as soon as the project launches.
            mustStartAtOrAfter: 0,
            // Keep the initial ruleset active without a recurring expiry.
            duration: 0,
            // Provide a nonzero nominal weight; the pay data hook supplies the actual issuance numerator.
            weight: 1e18,
            // Prevent time-based decay of the configured issuance weight.
            weightCutPercent: 0,
            // No approval mechanism is needed because this owner exposes no ruleset-queueing operation.
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                // Give every issued share to the depositor's beneficiary instead of reserving a separate portion.
                reservedPercent: 0,
                // Preserve the chosen cash out curve; the maximum-rate check above makes this cast safe.
                // forge-lint: disable-next-line(unsafe-typecast)
                cashOutTaxRate: uint16(cashOutTaxRate),
                // Route payment pricing through the synthetic-currency feed registered below.
                baseCurrency: baseCurrency,
                // Allow holders to create stakes by paying the terminal.
                pausePay: false,
                // Prevent credit transfers from bypassing the share token's tranche accounting and transfer policy.
                pauseCreditTransfers: true,
                // Prevent owner minting from diluting stakes without a backing deposit.
                allowOwnerMinting: false,
                // Permit the initial Sticky token attachment; this owner exposes no later token-setting method.
                allowSetCustomToken: true,
                // Keep backing in the terminal whose accounting the hook and feed use.
                allowTerminalMigration: false,
                // Prevent changing the set of terminals that can receive stakes and redeem shares.
                allowSetTerminals: false,
                // Preserve the controller that enforces this project's issuance and configuration rules.
                allowSetController: false,
                // Keep the underlying token as the project's only accepted staking asset.
                allowAddAccountingContext: false,
                // Permit initial feed registration; this owner exposes no later feed-setting method.
                allowAddPriceFeed: true,
                // No payout permission gate is needed because the project has no fund-access limits.
                ownerMustSendPayouts: false,
                // Let terminal fees process normally instead of accumulating deferred fee obligations.
                holdFees: false,
                // Use the core's aggregate surplus path; this project has one fixed staking terminal.
                scopeCashOutsToLocalBalances: false,
                // Price each deposit against share-owned backing and request its tranche-accounting callback.
                useDataHookForPay: true,
                // Exclude orphaned funds from the backing available to redeeming holders.
                useDataHookForCashOut: true,
                // Use the same accounting authority that the project's share token will notify.
                dataHook: address(HOOK),
                // Leave application-specific metadata bits unset because Sticky requires no additional flags.
                metadata: 0
            }),
            // No payout or reserved-share allocation is needed for a project funded only for its share holders.
            splitGroups: new JBSplitGroup[](0),
            // Expose no payout limits or surplus allowances that could withdraw holder backing.
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Allocate exactly one accepted asset so the project's backing stays denominated in its underlying token.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);

        // Cache the token's precision at launch so terminal accounting does not follow later metadata changes.
        accountingContexts[0] =
            JBAccountingContext({token: address(stakedToken), decimals: stakedToken.decimals(), currency: currency});

        // Configure a single terminal so payments and cash outs share one backing ledger.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);

        // Bind that terminal to the accepted asset and its cached accounting units.
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: TERMINAL, accountingContextsToAccept: accountingContexts});

        // Preserve any outer launch's fee payer in case a creation-fee callback starts a nested launch.
        address previousPayer = originalPayer;

        // Expose the resolved launcher so the controller attributes creation-fee tokens to the account funding them.
        originalPayer = JBPayerTrackerLib.resolve(msg.sender);

        // Forward the creation fee and retain the project NFT here, with no operation to alter its policy or owner.
        projectId = CONTROLLER.launchProjectFor{value: msg.value}({
            owner: address(this),
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: "JBSticky"
        });
        // Each nested launch attributes its own fee, then restores the outer launch's payer before returning.
        // slither-disable-next-line reentrancy-eth
        originalPayer = previousPayer;

        // Deploy the share token representing staked positions, bound to this project.
        IJBToken token = new JBStickyToken({
            name: name, symbol: symbol, tokens: TOKENS, projectId: projectId, hook: HOOK, soulbound: soulbound
        });

        // Make terminal issuance use these shares; the custom-token flag permits this initial attachment.
        CONTROLLER.setTokenFor({projectId: projectId, token: token});

        // Authorize only this share token to report transfers and burns to the project's position accounting.
        HOOK.setTokenFor({projectId: projectId, token: address(token)});

        // Bind an immutable issuance denominator to the launched project's terminal, supply and orphaned backing.
        IJBPriceFeed feed = new JBStickyPriceFeed({
            hook: HOOK, terminal: TERMINAL, token: token, projectId: projectId, underlyingToken: address(stakedToken)
        });

        // Register the feed for the exact currency pair that core consults when pricing a staking payment.
        CONTROLLER.addPriceFeedFor({
            projectId: projectId, pricingCurrency: currency, unitCurrency: baseCurrency, feed: feed
        });

        // Expose the project's feed so clients can inspect the denominator used for issuance.
        priceFeedOf[projectId] = feed;

        // Allow the project's granters to airdrop stakes to any holder.
        HOOK.setGrantersFor({projectId: projectId, granters: granters});

        // Expose the accepted staking asset so clients can identify the backing for this project's shares.
        stakedTokenOf[projectId] = stakedToken;

        // Expose the fixed curve parameter so clients can account for backing retained during cash outs.
        cashOutTaxRateOf[projectId] = cashOutTaxRate;

        // Announce the completed configuration so indexers can discover the project and its share token.
        // Launches receive distinct project IDs, and every configuration write is scoped to its own project.
        // forge-lint: disable-next-item(reentrancy-events)
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
    /// @dev Only a mint from the controller's `PROJECTS` while a launch is in progress is accepted. `originalPayer` is
    /// non-zero exactly for the duration of `deployStickyFor`, and `JBProjects` mints before forwarding its creation
    /// fee, so the accepted NFT is the one the launch requested. Transfers of existing NFTs and mints outside a launch
    /// revert.
    /// @inheritdoc IERC721Receiver
    /// @return selector The ERC721 receiver acceptance selector.
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    )
        external
        view
        override
        returns (bytes4 selector)
    {
        // Retain only freshly minted project NFTs requested by a launch in progress.
        if (msg.sender != address(CONTROLLER.PROJECTS()) || from != address(0) || originalPayer == address(0)) {
            revert JBStickyDeployer_UnexpectedNft({collection: msg.sender, from: from, tokenId: tokenId});
        }

        // Accept the project NFT so the deployer can retain ownership and enforce permanent configuration.
        return IERC721Receiver.onERC721Received.selector;
    }
}
