# Sticky deployment readiness — 2026-09-12

The audited suite passed deployment-and-restart rehearsals on all eight configured
networks before the reward receiver rename. Each rehearsal checked the expected
chain, core launch authorization and registry bindings, deployed missing contracts
only in fork state, verified executable code and immutable bindings, and repeated
to validate reuse. No Sphinx proposal was
submitted and no on-chain transaction was broadcast.

The receiver/factory rename and the tenure-rewards change (`StickyDistributor`
replaces `JBTokenDistributor`, the distributor is bound to the hook, the claim
window is two years, receivers are keyed by group, and the hook's runtime changed)
change deployment inputs, so regenerate predictions and rerun deployment
rehearsals before collecting a Sphinx proposal. Live production readiness still requires executed receipts,
post-execution verification, published
artifacts, and wallet/bridge smoke checks. Read [AUDIT_REPORT.md](AUDIT_REPORT.md)
for findings, fixes, and remaining economic/recovery limits.

## Release inputs

- Sticky base commit: `584c6322584a0c85f5fe2e32c2f572822cbb4d1d`, plus this checkout's reviewed changes. Rehearsal manifests correctly record `-dirty` until the changes are committed.
- Core: `feff600654aee6fb1747dded692f18068b2230a6` (`1.2.1`).
- Distributor: `79af754e642b648347aba0c7df8a3398215e74a5`.
- Node 22.23.1; Foundry 1.8.1; solc 0.8.28; Sphinx plugins 0.33.3.
- Public `sphinx.lock` and the registered `sticky` project with its 1-of-3 `V6 Jango` Safe.
- Existing RPC/service configuration loaded through `STICKY_ENV_FILE=../../deploy-all-v6/.env`. No credentials are copied into this report.

Proposal/verification commands require clean dependencies at the reviewed commits.
The installed Sphinx configuration test loads the committed project and verifies
its derived Safe. Commit the reviewed Sticky release before collecting a proposal
and use the same checkout for post-execution verification.

## Fork evidence

These are simulation observations, not proof of live Sticky deployment. The
ignored `deployments/<network>/simulation.json` files contain addresses, complete
runtime hashes, RPC block hashes, and EVM context. RPC and EVM heights differ on
Arbitrum; only the RPC height identifies the L2 fork used by Forge.

| Network | Chain ID | Pinned RPC block | EVM block |
| --- | --- | --- | --- |
| arbitrum | 42161 | 504431146 | 25962106 |
| arbitrum_sepolia | 421614 | 308146463 | 11689662 |
| base | 8453 | 51218025 | 51218025 |
| base_sepolia | 84532 | 46728552 | 46728552 |
| ethereum | 1 | 25962102 | 25962102 |
| optimism | 10 | 156813298 | 156813298 |
| optimism_sepolia | 11155420 | 48711415 | 48711415 |
| sepolia | 11155111 | 11689657 | 11689657 |

All eight rehearsals predicted the same suite addresses below. These are historical
predictions from before the receiver/factory rename and the tenure-rewards change
and must not be used as current release addresses. Generate current predictions
with the reviewed source.

| Component (current name) | Historical predicted address |
| --- | --- |
| deployer | `0xedcFD0E082EfA0ca0A9Aa3A8569D1feD20c2898d` |
| hook | `0x3Ad2b04006d14C46aE9B8ab3c214f46658dE7232` |
| distributor | `0xEDa8563977EB0857616C163b8084B3152332e6BE` |
| rewardReceiverFactory | `0x3E10A8E2dbbF3C9d9B753F69231a77255FAc1358` |
| autoStick | `0xbF88e94b58Fd1d5f3E37eCb28de91a4454CF5757` |

Per-project share tokens/price feeds and individual reward receivers are created on
demand. Cross-chain receiver parity additionally depends on the destination Sticky
token address; equal factory addresses alone are insufficient.

## Validation

The results below were recorded before the receiver/factory rename and the
tenure-rewards change; rerun every gate on the reviewed source.

- **143 Solidity tests passed**, zero failed, across twelve suites; includes 21 deployment regressions, direct/forwarded/nested creation-fee attribution, independent withdrawals, and the snapshot-reward characterization.
- **34 real-project fork tests passed**, zero failed and zero skipped, through `npm run test:fork` with strict lint: 14 each on Base `6` (Artizen) and Ethereum `3` (Revnet Network), plus six Ethereum `3` to Base `3` reward-bridge tests. These acquire real project tokens through deployed payment contracts and deploy Sticky locally through the production helper. [Pinned state, scenarios, and rerun commands](test/fork/README.md).
- **292 browser-state tests passed**, including Safe identity, failed-submission recovery, navigation races, and hostile token metadata.
- **27 Python checks passed** for public configuration, HTTP serving, and accessibility structure.
- **13 deployment-tooling tests passed** using the installed Sphinx validator/configuration reader and runner regressions.
- Strict runtime build/lint and contract size checks pass with `--deny notes`; deployment entrypoints compile.
- Pinned `forge fmt --check`, shell/JavaScript syntax, and `git diff --check` pass.
- Slither 0.11.3 passes `--fail-medium`: no untriaged High/Medium findings; eight Low reports are explained in the audit report. The transient payer restore is narrowly suppressed after nested-call regression verification.
- Isolated Chrome desktop/mobile keyboard and CSP smoke checks pass with no browser errors. The token-symbol XSS regression also passes with CSP removed, establishing the escaping fix independently.
- Four testnet and four mainnet fork deployment/restart rehearsals pass; nothing was broadcast.

The new real-project suites use Base block `51218441` and Ethereum block
`25962175`. Their lifecycle coverage includes historical rewards after transfers,
burns, and late deposits; donation-adjusted compounding; revoked consent; and
independent dust exits. Cross-chain coverage executes the deployed native-route
suckers and messengers, proof validation, receiver settlement, vesting, compounding,
and full redemption. Portal delivery is modeled at the Base messenger boundary;
consensus proofs, finality, relayer operation, reverse withdrawals, and alternate
bridge lanes remain outside that suite. Wallet smoke checks remain a separate
post-deployment requirement.

## Operator handoff

Follow [DEPLOYMENT.md](DEPLOYMENT.md#network-group-commands). Propose testnets first,
execute through the existing Sphinx process, then run `deploy:post:testnets` and
wallet transaction smoke checks. Use the corresponding mainnet commands for the
reviewed release. Retain Sphinx receipts and publish only verified manifests.
Configure per-chain client addresses from the executed release, and derive event
start blocks from execution receipts rather than verification blocks.
