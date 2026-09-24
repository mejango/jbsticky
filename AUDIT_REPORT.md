# Sticky production review — 2026-09-12

## Assessment

The review found and fixed two High-severity defects: a withdrawal restriction that
could trap another holder's backing, and script execution through an unescaped
ERC-20 symbol. It also corrected wallet recovery, stale navigation, deployment
validation, fee attribution, accessibility, and misleading economic descriptions.

The resulting source is prepared for a reviewed Sphinx release. This is a source,
local execution, and fork review, not evidence of a live Sticky deployment. Sphinx
execution, post-execution verification, and real wallet transaction smoke checks
remain release steps. The deployment predictions in [DEPLOYMENT-READINESS.md](DEPLOYMENT-READINESS.md)
replace the earlier predictions because contract bytecode changed.

## Scope and method

The scope covers all seven Sticky-owned runtime contracts, the pricing library,
interfaces and value types, production deployment scripts, the browser client,
public configuration, HTTP serving, and repository documentation. Reviewers traced
relevant V6 controller, terminal, registry, payer-tracker, distributor, Safe, and
bridge call paths. This is not a fresh exhaustive audit of every imported V6 or
third-party contract or hosted service.

Independent passes covered accounting/pricing, token/factory permissions, rewards,
deployment, wallet recovery, web security/accessibility, and V6 style. Findings
were reproduced where practical and fixed at their shared cause. The review used
[Ponytail](https://raw.githubusercontent.com/DietrichGebert/ponytail/main/skills/ponytail/SKILL.md)
to prefer existing V6 helpers and native browser controls, while preserving
validation, recovery guarantees, and accessibility. No new runtime dependency or
configurable rewards architecture was added.

Reviewed inputs: Sticky base commit `584c6322584a0c85f5fe2e32c2f572822cbb4d1d`
plus this checkout's changes; core `feff600654aee6fb1747dded692f18068b2230a6`;
distributor `79af754e642b648347aba0c7df8a3398215e74a5`; Node 22.23.1;
Foundry 1.8.1; solc 0.8.28; Sphinx 0.33.3.

## Findings and resolutions

| ID | Severity | Finding and consequence | Resolution and evidence |
| --- | --- | --- | --- |
| A-01 | High | The global burn supply floor made an honest holder's exit depend on someone else relinquishing dust. With inflated backing per share, substantial backing could remain trapped. | Removed the burn restriction; retained the initial deposit minimum and exact issuance/rounding protection. The independent-withdrawal regression failed against the restriction and passes after removal. [Pricing tests](test/JBStickyPricing_Regression.t.sol). |
| A-02 | High | A token symbol entered the bonus legend's `innerHTML` unescaped. A permissionlessly created project could execute script in the application's origin. | Escape metadata at the HTML boundary. The hostile-symbol browser proof executes against the original rendering and renders as text after the fix, independently of CSP. Added [metadata regression](webclient/test/metadata-rendering.test.cjs); removed inline handlers and enabled `script-src 'self'`. |
| A-03 | Medium | Safe recovery accepted an unrelated successful proposal with identical inner calldata, potentially clearing an action whose original proposal remained executable. | Bind recovery to the saved Safe proposal event or the returned outer transaction/replacement, including executor and nonce. Retain verified proposal identity for later checks. [Wallet regressions](webclient/test/tx-engine-adversarial.test.cjs). |
| A-04 | Medium | A missing-hash EOA submission that canonically reverted could never be recovered, permanently blocking later actions. | Accept verified finalized failure as recovery evidence, then allow explicit retry/dismissal. Safe outer failures still do not prove proposal consumption. [Wallet regressions](webclient/test/tx-engine-adversarial.test.cjs). |
| A-05 | Medium | Delayed handle, project, account, and reward reads could overwrite the current view after navigation, making the displayed route disagree with the target project. | One shared view guard rejects stale account/chain/project results before state or DOM changes. [View-race regressions](webclient/test/view-races.test.cjs). |
| A-06 | Medium | Duplicated or swapped RPC aliases could make a group report success after checking the wrong chain. The installed Sphinx validator also accepts this misconfiguration. | Pass the expected chain to every rehearsal/verification and reject a mismatch before selecting artifacts. [Deployment tests](test/deployment/JBStickyDeployment.t.sol), [runner tests](test/deployment/runner.test.mjs). |
| A-07 | Medium | Proposals were not runnable from the prepared checkout: no public Sphinx lock, an unregistered project name, and an undocumented required service URL. | Reuse `deploy-all-v6`'s registered `v6-deployment` project/Safe and identical public lock; check organization/project configuration before proposing. An installed-Sphinx test loads the Solidity configuration and independently derives the expected Safe. [Configuration tests](test/deployment/config.test.cjs). |
| A-08 | Medium | Singleton verification did not establish that the core controller was allowed to launch projects. It also omitted terminal-store/controller ruleset-registry equality. | Check launch authorization and the missing registry binding before deployment or verification. [Deployment tests](test/deployment/JBStickyDeployment.t.sol). |
| A-09 | Medium | A clean Sticky revision did not identify its symlinked core/distributor sources; changed dependencies could silently produce different release artifacts. | Proposal/verification require clean dependencies at reviewed commits; tests keep runner and CI pins aligned. [Runner tests](test/deployment/runner.test.mjs). |
| A-10 | Medium | Pointer-only controls prevented keyboard users from selecting custom tax, bridge origin, or custom allowance. Inputs/dialogs lacked accessible names. | Native buttons/links/selects, associated labels, selected states, focus handling, and keyboard navigation. Mobile controls wrap; muted text contrast increased from 3.88:1 to 4.72:1. [Accessibility checks](webclient/test/test_accessibility.py). |
| A-11 | Low | Creation-fee rewards were attributed to the permanent factory rather than the launcher, stranding the launcher's fee-project tokens. | Reuse V6's payer-tracking interface/library, scope the transient payer to the core launch, and restore it across nested calls. Three real-core tests cover direct, forwarded, and nested attribution. [Factory regressions](test/JBStickyDeployer_Regression.t.sol). |
| A-12 | Low | Arbitrum manifests labeled EVM `block.number` as the fork's RPC block, although it is an L1 height. | Pin grouped forks to RPC headers and record `rpcBlockNumber`/`rpcBlockHash` separately from EVM context. Never derive client event start blocks from verification time. [Deployment tests](test/deployment/JBStickyDeployment.t.sol). |
| A-13 | Low | Copy overstated token compatibility, absence of upstream controls, full-exit refunds, and cross-chain availability from project metadata. | State standard-token assumptions, core/underlying authority, actual tax/fee behavior, snapshot eligibility, and planned-chain status. Corrected architecture, administration, journeys, README, and product copy. |

The receiver also rejects zero distributor/token addresses while continuing to allow
predicted destination tokens that have not yet been deployed. NatSpec, section
order, named calls, comments, and strict CI gates follow the V6 guide. The local
[STYLE_GUIDE](STYLE_GUIDE.md) records a narrow Foundry multiline lint-directive
exception; no wrapper code was introduced solely to silence a false positive.

## Remaining design and operational limits

- **Snapshot rewards are not tenure rewards.** A brief holding before a pinned
  snapshot can earn rewards after exit. A real-core test shows a one-block holder
  recovering its entire zero-tax deposit and later collecting its proportional
  share of two rounds pinned by `poke()`. Funding pins only the current round;
  `poke()` also pins the next. Nonzero tax raises cash-out cost but does not prevent
  temporary ownership of transferable shares. Programs requiring duration-based
  eligibility need a different reward policy. [Snapshot characterization](test/JBStickyRewardSnapshots.t.sol).
- **Independent exits take priority over deposit availability.** After the burn
  floor is removed, a very small remaining supply and large backing can make some
  later deposits unissuable under the rounding bound. Those deposits revert
  without taking funds. Restoring an exit restriction would reintroduce A-01.
- **Token and core assumptions remain.** Fee-on-transfer and rebasing underlyings
  are unsupported. Token administrators may freeze or alter their token. Sticky
  exposes no project-admin path, but depends on the configured V6 release and its
  authority/forwarder boundaries. A 100% cash-out tax returns zero even on a full exit.
- **Recovery requires evidence.** A Safe submission with no returned reference
  cannot be matched to a unique proposal and stays unresolved. Published Relayr
  launches have no contract-level idempotency key; expiry is not permission to
  create another launch. Auto-stick is best effort after permissionless collection.
- **Cross-chain settlement has limits.** Receiver parity requires matching factory,
  distributor, creation code, and destination token. Bridge routes depend on the
  reward token. The client reconstructs at most 20,000 shared-sucker leaves; larger
  histories can require other recovery tooling. RPC history availability and
  indexer-independent loading performance must be checked for the launch network.

See [RISKS.md](RISKS.md) and [INVARIANTS.md](INVARIANTS.md) for the continuing
integration assumptions and guarantees.

## Validation

Validation results and refreshed network evidence are recorded in
[DEPLOYMENT-READINESS.md](DEPLOYMENT-READINESS.md). Regression coverage includes
independent exits, hostile token metadata, nested creation-fee attribution, Safe
proposal identity, finalized failed submissions, navigation races, wrong-chain
rehearsals, missing launch authorization, dependency drift, and RPC/EVM block
identity.

Real-project integration now adds 34 passing fork cases: the Sticky lifecycle
against Base `6` and Ethereum `3`, plus Ethereum `3` rewards bridged to Base `3`
through the deployed native-route suckers and messengers. Historical allocation,
late deposits, revoked consent, donation-adjusted compounding, source slippage,
message authentication, forged proofs, replay, and retry have executable coverage.
The [fork guide](test/fork/README.md) records blocks and the modeled portal-delivery
boundary; these tests do not establish bridge finality or relayer operation.

Slither's transient payer restoration report was reviewed against the nested-launch
regression and suppressed only at that restoration: each call saves and restores
the outer attribution. Eight Low reports remain documented: two checks of
factory-validated constructor inputs, one transitive `CTPublisher` permission loop,
two factory writes scoped to distinct project IDs, and three completion-event
ordering reports. They do not establish a path to reuse another project's state or
redirect a holder's funds. Strict runtime lint uses individually justified
suppressions for similarly inapplicable rules; security checks remain in place.
