# Deploying Sticky

Sticky uses the same Sphinx proposal workflow and canonical CREATE2 factory as the other Juicebox V6 repositories. The production entrypoint is `script/Deploy.s.sol:Deploy`. `DeployLocal.s.sol` is a disposable demonstration with mintable tokens and different reward durations; it requires `STICKY_LOCAL_DEMO=true` and is not a production deployment.

## Reproducible checkout

Use Node 22.23.1, Foundry v1.8.1, and the committed npm lockfile. CI reproduces this workspace layout:

```text
nana-core-v6/                 # feff600654aee6fb1747dded692f18068b2230a6
nana-distributor-v6/          # 79af754e642b648347aba0c7df8a3398215e74a5
extensions/JBSticky/
```

The core and distributor are intentionally linked `file:` dependencies. Install all dependencies, including the pinned Sphinx CLI, before compiling scripts:

```sh
npm ci
forge fmt --check
forge test
forge build --sizes --skip '*/test/**' --skip '*/script/**' --skip SphinxUtils
forge build --skip '*/test/**'
```

Keep `remappings.txt` as the source of import mappings. In this workspace, explicit global package mappings also unify nested dependency copies: removing the OpenZeppelin and protocol mappings can compile duplicate `IERC20`/`IERC165`/Revnet interface types. They are not redundant merely because the top-level packages are real directories.

Changing source, compiler settings, dependency versions, or constructor arguments changes CREATE2 predictions. All chains must use the same reviewed checkout, compiler, lockfile, salts, and core dependency addresses to obtain matching singleton and reward receiver addresses. Distributor `STARTING_TIMESTAMP` is chain-specific; it does not enter its CREATE2 init code.

## Configuration and preflight

Copy `.env.example` to `.env`, provide RPC endpoints for the intended network group, configure `SPHINX_ORG_ID`, `SPHINX_API_KEY`, and `SPHINX_MANAGED_BASE_URL` for the existing Sphinx organization, and `ETHERSCAN_API_KEY` (one Etherscan v2 key serves every chain) for the post-execution artifacts. The npm deployment commands select the `deploy` Foundry profile (`isolate = false`), which is compatible with Sphinx and avoids Foundry 1.8.1's isolated Optimism factory-call failure. Local contract tests keep the default isolated execution model; the real-project `fork` profile uses non-isolated execution for the same production artifact inspection as rehearsals. For direct `sphinx` or deployment `forge script` commands, set `FOUNDRY_PROFILE=deploy`. The deployment commands load `.env` with portable POSIX shell syntax and also accept environment variables supplied by CI. Never commit credentials.

| Sphinx / RPC alias | Environment variable | Core artifact folder |
| --- | --- | --- |
| ethereum | RPC_ETHEREUM_MAINNET | ethereum |
| optimism | RPC_OPTIMISM_MAINNET | optimism |
| base | RPC_BASE_MAINNET | base |
| arbitrum | RPC_ARBITRUM_MAINNET | arbitrum |
| ethereum_sepolia | RPC_ETHEREUM_SEPOLIA | sepolia |
| optimism_sepolia | RPC_OPTIMISM_SEPOLIA | optimism_sepolia |
| base_sepolia | RPC_BASE_SEPOLIA | base_sepolia |
| arbitrum_sepolia | RPC_ARBITRUM_SEPOLIA | arbitrum_sepolia |

Sticky uses the registered `v6-deployment` Sphinx project and the public `sphinx.lock`
from `deploy-all-v6`, so proposal review uses the same 4-of-8 `V6 Deployment` Safe
(`0x4dc161eF837fF1C4485b08DDFcDB182F2157bE18`, the same address on every chain).
The lock contains public organization/project/Safe configuration, not credentials.
The proposal runner checks that its organization matches `SPHINX_ORG_ID` and that
the configured project exists; `Deploy.run()` refuses any other Safe. The installed
Sphinx CLI synchronizes this lock during proposal collection; review any resulting
Safe configuration changes before execution.

The core reader defaults to `node_modules/@bananapus/core-v6/deployments/<network>/`. An optional `NANA_CORE_DEPLOYMENT_PATH` overrides the directory containing the network folders. Only `JBController.json`, `JBDirectory.json`, and `JBMultiTerminal.json` are required. Each artifact must record the connected chain ID. The reader checks live contract code, controller launch authorization, and controller/directory/terminal/token/project/store/split/price/ruleset registry bindings before deploying anything. It does not require a forwarder.

The pinned core artifacts are the trusted address source. Their `deployedBytecode` fields are templates with unresolved immutable words, so comparing those fields directly to live runtime hashes would be incorrect. Sticky checks core code existence and immutable cross-bindings, and records the observed full core runtime hashes in its manifest. Verify the upstream core release independently when changing those trusted artifacts.

Foundry's local script memory and gas budgets match `deploy-all-v6` so repeated artifact inspection can complete. Sphinx still estimates and checks the actual deployment transactions separately. Foundry file access permits reads from the checkout and the sibling core deployment tree, and writes only to `cache/` (required by Sphinx) and `deployments/`. A custom artifact path outside these locations needs an explicit additional read permission.

Run the deployment twice on a fork of each intended chain before making a proposal. This exercises fresh deployment, partial deployment recovery, or verified reuse, depending on the fork state, without sending transactions:

```sh
set -a
. ./.env
set +a
export STICKY_REVISION="$(git rev-parse HEAD)"
npm run deploy:rehearse -- --rpc-url ethereum_sepolia -vv
```

Repeat with every intended RPC alias. CI's manually dispatched `test` workflow runs the same read-only rehearsal for its selected network. Regular CI compiles all deployment scripts and runs the local clean, partial, repeat, malformed-runtime, immutable-mismatch, and artifact-loading regression tests.

Before proposing a release, also run
`STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork`. The
[real-project suites](test/fork/README.md) exercise Sticky's lifecycle against Base
`6` and Ethereum `3`, including Ethereum `3`'s deployed Base reward route. These
complement the eight singleton deployment rehearsals. Trusted CI runs require
Ethereum and Base archive RPC secrets; the tests fail when required state or
configuration is unavailable.

## Network-group commands

The operator commands follow `deploy-all-v6` naming. Run from this package with Node
22.23.1 and Foundry v1.8.1 on `PATH`. To reuse the workspace RPC and Sphinx setup
without copying credentials, set:

```sh
export STICKY_ENV_FILE=../../deploy-all-v6/.env
```

An explicit `STICKY_ENV_FILE` must exist; otherwise commands load the package's
`.env` when present, or use the current environment. Core artifacts still come
from the configured core package, independently of the credentials file.

```sh
npm run deploy:preflight:testnets
npm run deploy:preflight:mainnets
npm run deploy:rehearse:testnets
npm run deploy:rehearse:mainnets
npm run deploy:propose:testnets
npm run deploy:propose:mainnets
# Only after the corresponding Sphinx proposal has executed:
npm run deploy:post:testnets
npm run deploy:post:mainnets
```

Preflight checks all four RPC variables and the three core address/chain-ID
artifacts per destination. It does not contact RPCs. Rehearsal binds each RPC to its expected chain ID, checks live core bindings, and
simulates fresh deployment and restart on every destination. It reads a canonical
RPC block header and pins Forge to that height; the header number and hash are
recorded separately from the EVM block height. After the group's rehearsals the
runner requires every chain to have predicted the same deployer, hook, distributor,
reward receiver factory and adapter; the core binds the same addresses on all eight
chains, so mainnets and testnets predict one suite.
Proposal commands require Sphinx credentials, the public project lock, and clean
core/distributor checkouts at the reviewed commits recorded in `script/deploy.mjs`,
and rerun the entire group's
rehearsals before invoking the pinned local Sphinx CLI. A failed or divergent chain
stops the command before proposal submission. `deploy:testnets` and
`deploy:mainnets` are aliases for these proposal commands. Sphinx execution remains
a separate step.

`deploy:post:*` runs `deploy:verify:*`, which verifies the group on live RPCs,
requires the same agreement, and writes `deployments/<network>/verified.json`; it
then runs `deploy:artifacts:*` (`script/artifacts.mjs`), which verifies the five
sources on Etherscan and writes `deployments/<network>/JBStickyDeployer.json`,
`JBStickyHook.json`, `JBStickyDistributor.json`, `JBStickyRewardReceiverFactory.json`
and `JBStickyAutoStick.json` in the `sphinx-sol-ct-artifact-1` layout the other V6
repositories keep: address, ABI, constructor arguments, creation receipt, bytecode,
metadata and source revision. The constructor arguments come from the bindings the
verified manifest recorded, and for every factory-deployed contract the explorer's
creation bytecode must equal the compiled creation code followed by those
arguments; the hook is created by the deployer's constructor, so its receipt is the
deployer's creation transaction. Commit both kinds of file. `deploy:post:*` does
not publish packages or configure the website; follow the publication steps below.
If a later chain fails, earlier manifests remain valid for their recorded block,
but the group is incomplete. No group command broadcasts directly through Forge.

Proposal, verification and artifact commands reject changed or mismatched local
core and distributor dependencies (their commits, and any change under their
`src/`; tests and scratch files do not compile into the contracts), and an
uncommitted Sticky checkout, where the runner's own outputs under `deployments/`
do not count. A clean Sticky tree alone cannot identify symlinked sources.
Rehearsals allow development changes. CI and runner tests keep the reviewed
dependency commits aligned, and `npm run test:deployment` checks that every source
root of the compiled suite is pinned: the linked checkouts by revision, the npm
packages by the lockfile's integrity hashes.

The grouped commands record the current Git commit automatically, appending
`-dirty` when a rehearsal's checkout has changes. Commit the reviewed release and
rerun its rehearsals before proposal collection; use the identical checkout for
verification.
The single-chain `deploy:rehearse` and `deploy:verify` commands remain available
for diagnosis and accept normal Forge options; source your environment and set
`STICKY_REVISION` explicitly when using those commands.

## Proposal and execution

The script keeps the original `JBStickyDeployerV6` and `JBStickyAutoStickV6` salts and explicitly uses the canonical factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`. It validates that factory's exact runtime. The suite is:

1. `JBStickyDeployer`, which creates its accounting hook in its constructor.
2. `JBStickyDistributor`, bound to that deployer's hook, with 7-day rounds, 4-round vesting, a 2-year claim window, and loans disabled.
3. `JBStickyRewardReceiverFactory`, bound to that distributor.
4. `JBStickyAutoStick`, bound to that deployer and distributor.

```sh
npm run deploy:testnets
# After the testnet release and all intended mainnet rehearsals are reviewed:
npm run deploy:mainnets
```

These commands create Sphinx proposals. Review the exact predicted addresses, missing deployment transactions, bytecode, constructors, network group, and Sphinx Safe before approving execution through the existing Sphinx process. Do not use `forge script --broadcast` with the Sphinx entrypoint.

A repeated proposal collection skips existing deployments only after checking their compiled executable runtime and all immutable bindings. Every occurrence of a compiler-reported immutable must agree; checking only its getter is insufficient. The hook must be the deployer's nonce-1 CREATE child. The distributor must be bound to that hook with a matching epoch duration and retain its original valid starting timestamp. Unexpected code or settings cause a failure rather than silent reuse. A changed source revision deploys new predictions; it does not upgrade or replace earlier immutable projects.

## Verification and publication

A rehearsal or Sphinx collection writes `deployments/<network>/simulation.json`. This ignored file describes simulated state and is **not deployment evidence**.

After Sphinx executes, verify the unchanged reviewed compilation against each live RPC:

```sh
npm run deploy:verify -- --rpc-url ethereum_sepolia -vv
```

`Verify` sends no transactions. It requires the predicted suite to already exist and rechecks runtime code, every immutable dependency, distributor settings, hook prediction, and core bindings. Only then does it write `deployments/<network>/verified.json`, containing the chain context, source revision, addresses, salts, and complete runtime hashes.
`evmBlockNumber` and `evmParentBlockHash` describe the EVM context. On Arbitrum,
these are not the L2 RPC block identity. Grouped commands additionally record
`rpcBlockNumber` and `rpcBlockHash` from the header used to pin their fork. Direct
single-chain Forge calls do not provide those RPC fields automatically; retain
their fork context separately. Deployment start blocks for client event discovery
must come from execution receipts, not verification manifests. `revision: unrecorded` means the operator did not set `STICKY_REVISION`; fill that gap by rerunning with the actual reviewed commit before publishing artifacts.

Retain the executed Sphinx proposal/transaction receipts alongside the verified manifest and the per-contract artifacts `deploy:post:*` writes. Publish only verified artifacts for chains that have executed, and propagate them through the existing V6 artifact distribution process before configuring the website. Confirm the deployer, hook, token registry, distributor, reward receiver factory, and adapter against the manifest; keep the website in demo mode until those checks and target-chain transaction smoke tests succeed. No live deployment or production artifact is implied by files generated during local tests.
