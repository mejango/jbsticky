# Real-project fork tests

These tests run Sticky against the deployed V6 projects on Base `6` (Artizen,
`ART`) and Ethereum `3` (Revnet Network, `REV`). They create Sticky locally through
the production deployment helper, verify its bindings, and launch projects backed
by the existing project tokens. Underlying tokens are acquired by paying the live
project's native-token terminal. No ERC-20 balances, contract code, or project
configuration are replaced.

## Run

Use the pinned workspace dependencies and Foundry version in the root
[README](../../README.md#develop-and-check). Provide Ethereum and Base archive RPCs
through `.env`, exported variables, or the existing deployment environment:

```sh
STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork
STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork -- --match-contract StickyBase6ForkTest
STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork -- --match-contract StickyEthereum3ForkTest
STICKY_ENV_FILE=../../deploy-all-v6/.env npm run test:fork -- --match-contract StickyCrossChainRewardsForkTest
```

The wrapper selects the `fork` profile, using the same non-isolated production
artifact inspection as deployment rehearsals, and fails if either required RPC
variable is missing. A missing archive block, wrong chain, unavailable project, failed
payment, or missing bridge route fails the suite. Tests contain no RPC skip
guards. Default `forge test` runs the local suites without requiring public RPCs.

The regular test workflow runs the fork suite on main-branch pushes, manual runs,
and pull requests originating in the same repository. External pull requests run
the local checks; their fork suite must be run from a reviewed revision with RPC
access. CI needs `RPC_ETHEREUM_MAINNET` and `RPC_BASE_MAINNET` secrets. Sphinx and
wallet credentials are unnecessary for these tests.

## Pinned state

| Chain | Block | Block hash | Existing project token |
| --- | --- | --- | --- |
| Base | `51218441` | `0x8a01ed27f4d292f665be2eb0901e0224f7d1cd0129e103de0f04d792dfc41a97` | Project `6`: `0x44c4516768e47cd97cfF2561B81a74699F23f8Ec` |
| Ethereum | `25962175` | `0x79b726290770722b62d4bad4a0cdff6d412fc2230fc7dbec73ca55d0921982ba` | Project `3`: `0x3dD82a891C80Db068e95708E83583d626E2c1Fac` |

The block constants live in [the shared fixture](helpers/StickyRealProjectFork.sol).
Update the constants and this evidence together after reviewing project and
bridge configuration changes. Passing these historical forks does not establish
the state at a later deployment block.

## Lifecycle coverage

Validation on 2026-09-12 passed all 34 tests with `--deny notes`: 14 on each
underlying project and six cross-chain cases, with zero failures or skips.

[StickyRealProjects.t.sol](StickyRealProjects.t.sol) runs the same scenarios
against both projects:

- Real token acquisition, production Sticky launch, permanent project rules,
  reviewed stake previews, multiple deposits, and tranche ages through exits.
- Granter and holder consent, trust revocation, soulbound transfer rejection,
  transferable shares, voluntary burns, and historical checkpoints.
- Donations, stale minimum protection, orphaned backing, restart, and complete
  withdrawal while another holder retains one share atom in either transfer mode.
- Taxed partial and full cash-outs, comparing gross quotes with actual net wallet
  receipts and terminal backing.
- Weekly rewards with four vesting rounds, unequal holder allocations, transfers
  and burns after funding, and exclusion of deposits after the snapshot.
- Collection and auto-stick consent, approval-failure atomicity, retry, staking
  after exit, and donation-adjusted compounding that spends only collected rewards.

## Cross-chain coverage and boundary

[StickyCrossChainRewards.t.sol](StickyCrossChainRewards.t.sol) resolves
Ethereum `3`'s deployed native-token sucker route to Base `3` (Revnet Network,
`REV`), a separate project from Artizen. Both sides use sucker
`0xA2b081638dC179Dbb7e63f338357cEA2487bb933` and project token
`0x3dD82a891C80Db068e95708E83583d626E2c1Fac`. The L1 messenger is
`0x866E82a600A1414e583f7F13623F1aC5d58b0Afa`; the Base messenger is
`0x4200000000000000000000000000000000000007`.
It buys real source tokens, prepares a leaf addressed to the predicted destination
Sticky receiver, sends the actual outbox root, and captures the live L1 messenger's
message. The proof uses the outbox's existing Merkle frontier, including leaves
that predate the test.

The test delivers that exact message through the deployed Base messenger,
impersonating the canonical aliased L1 messenger and crediting the matching ETH.
This models the portal deposit boundary. Both messengers, both suckers, the
destination mint and backing accounting, receiver settlement, vesting, auto-stick,
and the final Sticky cash-out execute actual contract code. Negative cases check
unauthorized delivery, a false remote sender, altered beneficiary/metadata/proof,
message replay, duplicate claims, retry after an early claim, and source slippage
rejection without burning tokens or changing the outbox.

This suite does not run a portal consensus proof, sequencer, finality delay,
off-chain relayer, or browser wallet. It covers the Ethereum-to-Base native route;
reverse withdrawals and alternate-token routes require separate bridge checks.
The existing [deployment rehearsals](../../DEPLOYMENT.md) cover singleton deployment
and restart across all eight configured networks. Neither suite broadcasts a
transaction or creates a Sphinx proposal.
