# Deploying Sticky

Sticky uses the same Sphinx proposal workflow and canonical CREATE2 factory as the other Juicebox V6 repositories. The production entrypoint is `script/Deploy.s.sol:Deploy`. `DeployLocal.s.sol` is a disposable demonstration with mintable tokens and different reward durations; it requires `STICKY_LOCAL_DEMO=true` and is not a production deployment.

## Reproducible checkout

Use Node 22.23.1, Foundry v1.8.1, and the committed npm lockfile. CI reproduces this workspace layout:

```text
nana-core-v6/                 # 898f08b96194391d545df31a62f9d89ef6759f9a
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

Changing source, compiler settings, dependency versions, or constructor arguments changes CREATE2 predictions. All chains must use the same reviewed checkout, compiler, lockfile, salts, and core dependency addresses to obtain matching singleton and reward pocket addresses. Distributor `STARTING_TIMESTAMP` is chain-specific; it does not enter its CREATE2 init code.

## Configuration and preflight

Copy `.env.example` to `.env`, provide RPC endpoints for the intended network group, and configure the existing Sphinx organization credentials. The npm deployment commands select the `deploy` Foundry profile (`isolate = false`), which is compatible with Sphinx and avoids Foundry 1.8.1's isolated Optimism factory-call failure. Contract tests keep the default isolated execution model. For direct `sphinx` or deployment `forge script` commands, set `FOUNDRY_PROFILE=deploy`. The deployment commands load `.env` with portable POSIX shell syntax and also accept environment variables supplied by CI. Never commit credentials.

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

The core reader defaults to `node_modules/@bananapus/core-v6/deployments/<network>/`. An optional `NANA_CORE_DEPLOYMENT_PATH` overrides the directory containing the network folders. Only `JBController.json`, `JBDirectory.json`, and `JBMultiTerminal.json` are required. Each artifact must record the connected chain ID. The reader checks live contract code and the controller/directory/terminal/token/project/store/split/price registry bindings before deploying anything. It does not require a forwarder.

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

## Proposal and execution

The script keeps the original `JBStickyDeployerV6` and `JBStickyAutoStickV6` salts and explicitly uses the canonical factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`. It validates that factory's exact runtime. The suite is:

1. `JBStickyDeployer`, which creates its accounting hook in its constructor.
2. `JBTokenDistributor`, with 7-day rounds, 4-round vesting, a 3-year claim window, and loans disabled.
3. `JBStickyRewardPockets`, bound to that distributor.
4. `JBStickyAutoStick`, bound to that deployer and distributor.

```sh
npm run deploy:testnets
# After the testnet release and all intended mainnet rehearsals are reviewed:
npm run deploy:mainnets
```

These commands create Sphinx proposals. Review the exact predicted addresses, missing deployment transactions, bytecode, constructors, network group, and Sphinx Safe before approving execution through the existing Sphinx process. Do not use `forge script --broadcast` with the Sphinx entrypoint.

A repeated proposal collection skips existing deployments only after checking their compiled executable runtime and all immutable bindings. Every occurrence of a compiler-reported immutable must agree; checking only its getter is insufficient. The hook must be the deployer's nonce-1 CREATE child. The distributor must retain its original valid starting timestamp. Unexpected code or settings cause a failure rather than silent reuse. A changed source revision deploys new predictions; it does not upgrade or replace earlier immutable projects.

## Verification and publication

A rehearsal or Sphinx collection writes `deployments/<network>/simulation.json`. This ignored file describes simulated state and is **not deployment evidence**.

After Sphinx executes, verify the unchanged reviewed compilation against each live RPC:

```sh
npm run deploy:verify -- --rpc-url ethereum_sepolia -vv
```

`Verify` sends no transactions. It requires the predicted suite to already exist and rechecks runtime code, every immutable dependency, distributor settings, hook prediction, and core bindings. Only then does it write `deployments/<network>/verified.json`, containing the chain/block context, source revision, addresses, salts, and complete runtime hashes. `revision: unrecorded` means the operator did not set `STICKY_REVISION`; fill that gap by rerunning with the actual reviewed commit before publishing artifacts.

Retain the executed Sphinx proposal/transaction receipts and its standard deployment artifacts alongside the verified manifest. Publish only verified artifacts for chains that have executed, and propagate them through the existing V6 artifact distribution process before configuring the website. Confirm the deployer, hook, token registry, distributor, reward pocket factory, and adapter against the manifest; keep the website in demo mode until those checks and target-chain transaction smoke tests succeed. No live deployment or production artifact is implied by files generated during local tests.
