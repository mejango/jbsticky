#!/usr/bin/env python3
"""Emit public browser configuration. No credentials here remain server-only."""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import quote, urlsplit

DWELLIR = {
    1: "api-ethereum-mainnet.n.dwellir.com",
    10: "api-optimism-mainnet-archive.n.dwellir.com",
    8453: "api-base-mainnet-archive.n.dwellir.com",
    42161: "api-arbitrum-mainnet-archive.n.dwellir.com",
    11155111: "api-ethereum-sepolia.n.dwellir.com",
    11155420: "api-optimism-sepolia.n.dwellir.com",
    84532: "api-base-sepolia-archive.n.dwellir.com",
    421614: "api-arbitrum-sepolia.n.dwellir.com",
}
PUBLIC_RPC = {
    1: "https://ethereum-rpc.publicnode.com",
    10: "https://mainnet.optimism.io",
    8453: "https://mainnet.base.org",
    42161: "https://arb1.arbitrum.io/rpc",
    11155111: "https://ethereum-sepolia-rpc.publicnode.com",
    11155420: "https://sepolia.optimism.io",
    84532: "https://sepolia.base.org",
    421614: "https://sepolia-rollup.arbitrum.io/rpc",
}
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
ZERO_ADDRESS = "0x" + "0" * 40


def address(value, name):
    if value and (not ADDRESS.fullmatch(value) or value.lower() == ZERO_ADDRESS):
        raise ValueError(f"{name} must be a nonzero Ethereum address")
    return value


def endpoint(value, name):
    try:
        parsed = urlsplit(value)
        local = parsed.hostname in ("localhost", "127.0.0.1", "::1")
        valid = parsed.hostname and (parsed.scheme == "https" or (parsed.scheme == "http" and local))
        valid = valid and not parsed.username and not parsed.password and not parsed.fragment
        valid = valid and not any(character.isspace() for character in value)
        parsed.port  # Validate malformed ports without printing credential-bearing URLs.
    except ValueError:
        valid = False
    if not valid:
        raise ValueError(f"{name} must be an HTTPS URL (HTTP is allowed only on localhost)")
    return value


def block_number(value, name):
    if value != "earliest" and not re.fullmatch(r"(?:0x[0-9a-fA-F]+|[0-9]+)", value):
        raise ValueError(f"{name} must be earliest or a nonnegative block number")
    return value


def build_config(environ):
    def env(*names, default=""):
        return next((environ[name].strip() for name in names if environ.get(name, "").strip()), default)

    def integer(name, default):
        value = env(name, default=default)
        if not value.isdecimal() or not 0 <= int(value) <= 2**53 - 1:
            raise ValueError(f"{name} must be a nonnegative safe integer")
        return int(value)

    default_chain = integer("STICKY_DEFAULT_CHAIN", "1")
    if default_chain not in PUBLIC_RPC:
        raise ValueError("STICKY_DEFAULT_CHAIN is not a supported network")

    demo = env("STICKY_DEMO", default="false").lower()
    if demo not in ("0", "false", "no", "off", "1", "true", "yes", "on"):
        raise ValueError("STICKY_DEMO must be true or false")
    demo_mode = demo in ("1", "true", "yes", "on")
    dwellir_key = env("NEXT_PUBLIC_DWELLIR_API_KEY", "STICKY_DWELLIR_API_KEY")

    def rpc_for(chain_id):
        fallback = (f"https://{DWELLIR[chain_id]}/{quote(dwellir_key, safe='')}"
                    if dwellir_key else PUBLIC_RPC[chain_id])
        return endpoint(env(f"STICKY_RPC_{chain_id}", default=fallback), f"STICKY_RPC_{chain_id}")

    contract_fields = {
        "deployer": "STICKY_DEPLOYER",
        "distributor": "STICKY_DISTRIBUTOR",
        "pockets": "STICKY_POCKETS",
        "autoStickAdapter": "STICKY_AUTOSTICK_ADAPTER",
    }
    chains = {}
    for chain_id in PUBLIC_RPC:
        entry = {"rpcUrl": rpc_for(chain_id)}
        for field, variable in contract_fields.items():
            specific = f"{variable}_{chain_id}"
            value = address(env(specific, variable), specific)
            if value:
                entry[field] = value
        block_var = f"STICKY_FROM_BLOCK_{chain_id}"
        entry["fromBlock"] = block_number(env(block_var, "STICKY_FROM_BLOCK", default="earliest"), block_var)
        chains[str(chain_id)] = entry

    selected = chains[str(default_chain)]
    if not demo_mode and not selected.get("deployer"):
        raise ValueError("Live mode requires STICKY_DEPLOYER or STICKY_DEPLOYER_<defaultChainId>; "
                         "set STICKY_DEMO=true only for an explicit demo")

    return {
        **selected,
        "defaultChainId": default_chain,
        "demoMode": demo_mode,
        "projectId": integer("STICKY_PROJECT_ID", "0") or None,
        "chains": chains,
        "ensRpc": endpoint(env("STICKY_ENS_RPC", default=rpc_for(1)), "STICKY_ENS_RPC"),
        "relayrUrl": endpoint(env("STICKY_RELAYR_URL", default="https://api.relayr.ba5ed.com"), "STICKY_RELAYR_URL"),
        "bendystrawUrl": endpoint(env("NEXT_PUBLIC_BENDYSTRAW_URL", default="https://bendystraw.up.railway.app"), "NEXT_PUBLIC_BENDYSTRAW_URL"),
        "testnetBendystrawUrl": endpoint(env("NEXT_PUBLIC_TESTNET_BENDYSTRAW_URL", default="https://testnet.bendystraw.xyz"), "NEXT_PUBLIC_TESTNET_BENDYSTRAW_URL"),
    }


def write_config(config, output):
    output = Path(output)
    # Keep a running server from ever reading a partially written config.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write("// Generated public configuration. Do not put private credentials here.\n")
        handle.write("window.STICKY_CONFIG = " + json.dumps(config, indent=2) + ";\n")
    try:
        temporary.chmod(0o644)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().with_name("config.js"))
    args = parser.parse_args()
    try:
        config = build_config(os.environ)
        write_config(config, args.output)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Configuration failed: {error}\n")
    print(f"config.js generated: {'demo' if config['demoMode'] else 'live'}, "
          f"default chain {config['defaultChainId']}, "
          f"{sum(bool(entry.get('deployer')) for entry in config['chains'].values())} configured deployment chains")


if __name__ == "__main__":
    main()
