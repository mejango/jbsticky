# Sticky webclient

The browser client reads chain RPCs directly. Its Python service serves an explicit
set of public assets with Waitress and WhiteNoise; it does not hold wallet keys or
relay transactions. Dependencies are pinned in `requirements.txt`.

## Run locally

```sh
cd webclient
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
STICKY_DEMO=true python build-config.py
python serve.py
```

Open `http://127.0.0.1:8788`. Demo mode is explicit and read-only. For real chain data,
set deployment variables from `.env.example`, then run `python build-config.py`.
The generator writes next to itself regardless of the working directory. It does
not automatically load `.env`; source an appropriately filled file or set the
variables through the hosting platform. Restart the server after changing files.
Existing local `config.js` files are ignored by Git and are changed only when the
generator is explicitly run.

## Production configuration

Use `/webclient` as the Railway service root and `/webclient/railway.json` as its
configuration file (the path starts at the repository root, independent of the
service root). Railway installs
`requirements.txt`, generates public configuration, and starts `python3 serve.py`.
HTTPS is provided by the platform. `PORT` binds the service to all interfaces; the
local default binds only to loopback. `/healthz` is the readiness endpoint and
includes the Railway Git revision when available. A service without a valid
configuration or any referenced script refuses to start in production.

`STICKY_DEMO` defaults to false. A live build requires a verified deployer for
`STICKY_DEFAULT_CHAIN` (default: Ethereum mainnet). Use the per-chain address
variables unless every supported chain has the same verified deployment. Global
fields in the generated config are resolved from the selected default network.
All eight mainnet/Sepolia RPC entries are emitted; configuring an RPC alone does
not mean Sticky contracts are deployed there. Runtime transaction checks validate
the destination chain and deployed contracts.

Set `STICKY_FROM_BLOCK_<chainId>` to each deployment's actual block and provide
reliable RPCs that support historical logs. Explicit `STICKY_RPC_<chainId>` values
override the shared Dwellir key. Every value in `config.js`, including RPC URL keys,
is public: use keys intended for browser access and restrict them to your domain.
The service never publishes `.env`, Python source, examples, tests, or directory
listings. Configuration is not cached; scripts and HTML must revalidate.

Contract deployments are a separate prerequisite. This repository currently has
no tracked production deployment manifest, and its ignored local configuration
is not evidence of a live deployment. Configure verified Sticky deployer,
distributor, reward-pocket, and auto-stick addresses on each intended network
before selecting it for a production launch. Set optional extension addresses
only where those extensions are deployed. A successful health check verifies the
site's build and configuration, not on-chain contract deployment or RPC uptime.

## Transactions and recovery

Multichain creation requests a Relayr prepaid quote for the frozen deployment
configuration. Funding choices appear only after the quote has been matched to
every destination transaction. Choose a quoted chain, review its exact ETH amount,
and make one payment. A single-chain creation uses the same reviewed transaction
runner as other wallet actions.

Sticking, unsticking, grants, unlocked-token transfers, rewards, trusted senders,
and auto-stick use the connected wallet on the project's chain. Approvals and
dependent actions execute in sequence. The displayed account preview and demo
cannot submit transactions. Native ETH rewards are supported for direct funding;
bridging uses supported project ERC-20 tokens and their verified V6 sucker pair.
Cross-chain funding has separate reviewed prepare, transport, claim and settlement
steps because the bridge must deliver its message before rewards can be claimed.

Keep the browser's saved transaction and launch records until completion. Refresh
or resume to recheck canonical receipts. An unresolved wallet submission is never
sent again automatically; use its execution hash to recover it. Safe proposals
remain pending until their exact execution is verified. A finalized outer Safe
failure alone does not invalidate a proposal.

Sticky's deployed factory has no deployment nonce or idempotency key. A published
launch quote therefore cannot be discarded or replaced merely because it expired,
the API timed out, or one chain reported a failure. Keep the original record and
recover destination execution hashes; republishing could create duplicate projects.
The recovery UI exposes only clearing that is supported by the saved evidence.

The 100% cash out tax permanently makes unsticking return zero underlying tokens.
For tokens above 18 decimals, minimums reject deposits that would mint zero sticky
tokens, and rewards use Claim separately from Stick when the adapter cannot enforce
that minimum in one call.

## Checks

Run from the repository root with the Python environment activated:

```sh
python -m unittest discover -s webclient/test -p 'test_*.py' -v
for script in webclient/*.js; do node --check "$script"; done
node --test webclient/test/*.test.cjs
```

The separate `webclient` GitHub workflow runs these gates and starts the real
production HTTP entry point with an explicit demo config. Contract tests remain
under `forge test`; they do not broadcast transactions.

Server libraries: [Waitress](https://docs.pylonsproject.org/projects/waitress/en/latest/)
and [WhiteNoise](https://whitenoise.readthedocs.io/en/latest/base.html).
