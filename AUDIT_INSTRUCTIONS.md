# Audit Instructions

## Audit objective

Find a concrete sequence that loses backing, corrupts share or tranche accounting, blocks another holder's exit, redirects rewards, or causes the client to authorize a different outcome from the one it presents. Verify findings against the pinned core and distributor implementations. Distinguish a source defect from a documented economic choice, a dependency failure, or an unverified deployment.

## Scope

- Solidity in `src/`, including interfaces, structs, and `JBStickyPricing`.
- Deployment and verification under `script/`, environment handling, and Sphinx network groups.
- The core pay/mint/burn/cash-out flows and the inherited `JBDistributor` snapshot, vesting, and recycling logic actually used by `JBStickyDistributor`.
- `webclient/` configuration, project identity, quote units, transaction preparation, receipt recovery, rewards, and cross-chain flows.

Read [ARCHITECTURE.md](./ARCHITECTURE.md), [INVARIANTS.md](./INVARIANTS.md), [RISKS.md](./RISKS.md), and [USER_JOURNEYS.md](./USER_JOURNEYS.md), then trace source in this order:

1. `JBStickyDeployer`: permanent project metadata, ownership, accepted token, and core bindings.
2. `JBStickyPricing`, `JBStickyPriceFeed`, and `JBStickyHook`: exact issuance, orphaned backing, callback authentication, and position accounting.
3. `JBStickyToken`: every mint, transfer, burn, delegation, and checkpoint transition.
4. `JBStickyDistributor`: group encoding, the window pinned at round start, the denominator read from the hook's buckets at first funding, live-tranche numerators, the pot-remainder cap, split fallback to group 0, and the unregistered-token check.
5. `JBStickyAutoStick`, `JBStickyRewardReceiverFactory`, and `JBStickyRewardReceiver`: collection consent across groups, balance deltas, settlement timing, group validation, and destination identity.
6. Core `JBMultiTerminal`, `JBTerminalStore`, `JBController`, `JBTokens`, and `JBPrices`, paired with distributor `JBDistributor`.
7. Deployment helpers and the client transaction path for the same operation.

## Attack sequences

- Deposit, donate, partially redeem, voluntarily burn, fully exit, donate while empty, and bootstrap again. Track terminal backing, orphaned funds, share supply, and every holder's tranche sum.
- Leave one holder with dust and redeem every share belonging to another. Repeat in soulbound and transferable projects; another account's residual position must not impose a minimum balance on the exiter.
- Reduce supply to a few atoms, increase backing per atom, and try exact and inexact deposits across 0–36 accounting decimals. Rejected payments must not donate value; accepted payments must match exact rounded issuance.
- Reenter during the underlying token's transfer or approval callbacks. Attempt mint-time share transfers, controller burns, nested deposits, and donations before the after-pay reconciliation.
- Build many positive tranches in the same week and across weeks, exit partially and fully, then reuse the position. Check newest-first consumption, timestamp preservation, same-week merging, that every consumed tranche debits its original epoch bucket, that buckets always sum to supply, and bounded reads.
- Stake before and after a round start in the same week, fund a tenure group early and late in the round, exit and transfer between funding and claiming, and claim in every order. The recorded denominator must equal the in-window stake at first funding, no later stake may enter the window, and the sum of claims must never exceed the pot.
- Fund a tenure group through a split whose `projectId` is invalid, whose beneficiary is a token the hook does not track, or whose `lockedUntil` is set; fund directly with the same inputs.
- Compare cash outs at zero, intermediate, and maximum tax for a partial holder exit and the whole supply. Include a feeless beneficiary, fee-free surplus, a failed fee route, and low-decimal rounding. Compare gross preview with net receipt.
- Acquire shares for one block, call `poke()`, exit, and fund both pinned group-0 rounds. Repeat with transferable shares returned to their source, and repeat against a tenure group, which must pay that position nothing.
- Begin vesting, permissionlessly collect to the holder, and attempt a later compound. Fail each approval, transfer, preview, and payment step to check atomicity and that unrelated wallet funds are untouched.
- Fund a predicted receiver before deployment, settle across a round boundary, and compare predictions across different factories, distributors, destination tokens, groups, and compiled creation code.
- Change the connected account or chain during a multi-step client action; reject a signature, lose the RPC response after submission, and resume after reload. Verify destination, minimums, canonical receipts, and whether a retry would duplicate value movement.
- Rehearse clean, partial, repeated, and mismatched deployments on both network groups. Treat foreign code, immutable mismatches, stale manifests, and unverified privileged core bindings as distinct failures.

## Evidence and reporting

For a defect, provide the affected contract or client entrypoint, required starting state, executable sequence, observed result, expected invariant, and value or availability impact. Use a focused regression when changing behavior. Keep historical findings in review reports; source comments describe the current mechanism and its reason.

Validate source and documentation against [STYLE_GUIDE.md](./STYLE_GUIDE.md). Check complete NatSpec, correct units, current function names, and user-facing claims as part of the same review. A fixed test count or static-analysis result is evidence about that run, not certification of a release.

## Verification

Use the workspace and toolchain described in [README.md](./README.md), then run:

```sh
forge fmt --check
forge test --deny notes --fail-fast --summary --detailed --skip '*/script/**'
npm run test:deployment
STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork
forge build --deny notes --sizes --skip '*/test/**' --skip '*/script/**' --skip SphinxUtils
forge build --skip '*/test/**'
slither . --config-file slither-ci.config.json --fail-medium
node --test webclient/test/*.test.cjs
python -m unittest discover -s webclient/test -p 'test_*.py' -v
```

Use [DEPLOYMENT.md](./DEPLOYMENT.md) for fork rehearsals, Sphinx proposals, and post-execution verification. Run target-chain wallet checks after execution; a local test or read-only rehearsal cannot establish those outcomes.
