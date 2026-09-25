"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const P = require("../launch-plan.js");
const addr = (digit) => "0x" + String(digit).repeat(40);
const ALIASES = { base: 8453, op: 10, basesepolia: 84532 };
const NAMES = { 10: "OP Mainnet", 8453: "Base", 84532: "Base Sepolia", 11155420: "OP Sepolia" };
const nameOf = (chainId) => NAMES[chainId];

test("stickiness bonus presets are 0, 5, 10 and 25 percent in basis points", () => {
  assert.deepEqual(P.BONUS_PRESETS, ["0", "5", "10", "25"]);
  assert.deepEqual(P.BONUS_PRESETS.map((preset) => P.bonusBasisPoints(preset)), [0n, 500n, 1000n, 2500n]);
  assert.throws(() => P.bonusBasisPoints("50"), /Choose/);
});
test("a custom bonus is 0 to 99.99 percent with at most two decimals", () => {
  for (const [text, bp] of [["0", 0n], ["7", 700n], ["12.5", 1250n], ["99.99", 9999n], [" 3.05 ", 305n]]) assert.equal(P.bonusBasisPoints("custom", text), bp);
  for (const text of ["100", "100.00", "99.999", "-1", "", "1e2", "abc", "0x10"]) assert.throws(() => P.bonusBasisPoints("custom", text), /0 to 99.99/);
});
test("default names match the illustration: Sticky <name> and STICKY<SYMBOL>", () => {
  assert.deepEqual(P.defaultNames("Artizen", "art"), { name: "Sticky Artizen", symbol: "STICKYART" });
});
test("trusted senders are validated and deduplicated", () => {
  assert.deepEqual(P.parseSenders(` ${addr(1)}, ${addr(2)},${addr(1).toUpperCase().replace("0X", "0x")} ,`), [addr(1), addr(2)]);
  assert.deepEqual(P.parseSenders(""), []);
  assert.throws(() => P.parseSenders("0x123"), /Not an address: 0x123/);
  assert.throws(() => P.parseSenders(P.ZERO), /Not an address/);
});
test("AutoStick is always the last granter on every chain, once", () => {
  const adapter = addr("c");
  assert.deepEqual(P.launchGranters([], adapter, "Base"), [adapter]);
  assert.deepEqual(P.launchGranters([addr(1)], adapter, "Base"), [addr(1), adapter]);
  assert.deepEqual(P.launchGranters([adapter.toUpperCase().replace("0X", "0x"), addr(1)], adapter, "Base"), [addr(1), adapter]);
});
test("a chain without the AutoStick helper blocks the launch with a reason", () => {
  for (const missing of [undefined, "", P.ZERO, "0x1234"]) assert.throws(() => P.launchGranters([addr(1)], missing, "OP Sepolia"), /OP Sepolia has no auto-stick helper configured/);
});
test("token input reads addresses, project IDs and chain-prefixed project IDs", () => {
  assert.deepEqual(P.parseTokenInput(` ${addr(5)} `, ALIASES), { kind: "address", address: addr(5) });
  assert.deepEqual(P.parseTokenInput("12", ALIASES), { kind: "project", projectId: 12n, chainId: null });
  assert.deepEqual(P.parseTokenInput("base-sepolia:3", ALIASES), { kind: "project", projectId: 3n, chainId: 84532 });
  assert.deepEqual(P.parseTokenInput("mars:3", ALIASES), { kind: "unknown-chain", prefix: "mars" });
  assert.equal(P.parseTokenInput("", ALIASES).kind, "empty");
  for (const text of ["0", "0x12", "1.5", "base:"]) assert.equal(P.parseTokenInput(text, ALIASES).kind, "invalid");
});
test("a project ID resolves on every target chain, not just the loaded one", async () => {
  const seen = [];
  const tokenOfAt = async (chainId, projectId) => { seen.push([chainId, projectId]); return addr(7); };
  const resolved = await P.resolveProjectToken({ projectId: 4n, chainId: null, targetChainIds: [84532, 11155420], tokenOfAt, nameOf });
  assert.deepEqual(resolved, { address: addr(7), chainIds: [84532, 11155420] });
  assert.deepEqual(seen, [[84532, 4n], [11155420, 4n]]);
});
test("a project ID with no token or a different token on one chain is refused, naming that chain", async () => {
  const missing = async (chainId) => chainId === 11155420 ? P.ZERO : addr(7);
  await assert.rejects(P.resolveProjectToken({ projectId: 4n, chainId: null, targetChainIds: [84532, 11155420], tokenOfAt: missing, nameOf }), /Project #4 has no ERC-20 on OP Sepolia/);
  const reverts = async (chainId) => { if (chainId === 11155420) throw new Error("execution reverted"); return addr(7); };
  await assert.rejects(P.resolveProjectToken({ projectId: 4n, chainId: null, targetChainIds: [84532, 11155420], tokenOfAt: reverts, nameOf }), /no ERC-20 on OP Sepolia/);
  const differs = async (chainId) => chainId === 11155420 ? addr(8) : addr(7);
  await assert.rejects(P.resolveProjectToken({ projectId: 4n, chainId: null, targetChainIds: [84532, 11155420], tokenOfAt: differs, nameOf }), /different token on OP Sepolia than on Base Sepolia.*base:5/);
});
test("a chain-prefixed project ID resolves once on its chain", async () => {
  const seen = [];
  const tokenOfAt = async (chainId) => { seen.push(chainId); return addr(7); };
  assert.deepEqual(await P.resolveProjectToken({ projectId: 4n, chainId: 8453, targetChainIds: [10, 8453], tokenOfAt, nameOf }), { address: addr(7), chainIds: [8453] });
  assert.deepEqual(seen, [8453]);
});
test("the token must match by name, symbol and decimals on every chain", () => {
  const read = (name, overrides = {}) => ({ name, tokenName: "Art", tokenSymbol: "ART", tokenDecimals: 18, ...overrides });
  assert.equal(P.checkSameToken([read("Base"), read("OP")]).tokenSymbol, "ART");
  for (const change of [{ tokenName: "Artt" }, { tokenSymbol: "ARTT" }, { tokenDecimals: 6 }]) {
    assert.throws(() => P.checkSameToken([read("Base"), read("OP", change)]), /OP: the token differs from the one on Base/);
  }
});
