"use strict";
// The create flow's listing and chain choices, sliced from app.js.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const StickyCenter = require("../center-intents.js");
const StickyLaunchPlan = require("../launch-plan.js");
const source = fs.readFileSync(require.resolve("../app.js"), "utf8");
const slice = (from, to) => { const begin = source.indexOf(from); const end = source.indexOf(to, begin); assert.ok(begin >= 0 && end > begin, from); return source.slice(begin, end); };
const OWNER = "0x042F619EED558723252593DB0375fC34306f203A";
const DEPLOYER = "0xdA38Ec48B5b1d186B02BA99F297e95153BEE33a9";
const targets = (ids) => ids.map((chainId) => ({ chainId, deployer: DEPLOYER, rpcUrl: `https://rpc/${chainId}` }));
const listing = (ids) => ({ calls: ids.map((chainId) => ({ chainId, to: DEPLOYER, data: "0x00d5ce37" })), owner: OWNER, name: "Sticky T", symbol: "STICKYT",
  stakedToken: "0x" + "5".repeat(40), stakedTokenSymbol: "T", cashOutTaxRate: 0n, soulbound: false, launchId: "l", projectUri: "data:," });

function planner({ config = { centerUrl: "https://juicebox.center" }, code = "0x", trusted = () => { throw new Error("execution reverted"); } } = {}) {
  const views = [];
  const context = vm.createContext({ window: { STICKY_CONFIG: config, StickyCenter }, StickyCenter,
    rpcAt: async (url, method) => { assert.equal(method, "eth_getCode"); return typeof code === "function" ? code() : code; },
    viewAt: async (target, to, selector, args) => { views.push([target.chainId, to, selector, args]); return trusted(target.chainId); },
    decUint: (hex) => BigInt(hex), encAddress: (a) => a.slice(2).toLowerCase().padStart(64, "0") });
  vm.runInContext(slice("async function launchListingPlan(", "\n// Center's answers in plain words"), context);
  return { plan: (ids) => context.launchListingPlan({ owner: OWNER, targets: targets(ids), listing: listing(ids) }), views };
}
const TRUE = "0x" + "0".repeat(63) + "1";

test("today's StickyDeployer reverts isTrustedForwarder, so launches are self-paid and listed", async () => {
  const p = planner();
  assert.deepEqual(JSON.parse(JSON.stringify(await p.plan([84532]))).mode, "direct");
  const multi = await p.plan([84532, 11155420]);
  assert.equal(multi.mode, "relayr");
  assert.equal(multi.center.state, "pending");
  assert.equal(multi.center.envelope.format, "sticky.center/deploy.v1");
  assert.ok(p.views.every(([, to, selector, args]) => to === DEPLOYER && selector === "0x572b6c05"
    && args === "0000000000000000000000003ba60b60933916a7c87d0860dcee62a0ce34e3e2"));
});
test("after the ERC-2771 redeploy, sponsored chains go through Center with no client change", async () => {
  const p = planner({ trusted: () => TRUE });
  assert.equal((await p.plan([84532, 11155420])).mode, "center");
  assert.equal((await p.plan([8453])).mode, "center");
  assert.equal((await p.plan([1, 8453])).mode, "relayr", "Ethereum mainnet is never sponsored");
  const partial = planner({ trusted: (chainId) => chainId === 84532 ? TRUE : "0x" + "0".repeat(64) });
  assert.equal((await partial.plan([84532, 11155420])).mode, "relayr");
});
test("a contract account can't sign a listing; a 7702-delegated wallet can", async () => {
  const safe = await planner({ code: "0x6080604052" }).plan([84532]);
  assert.deepEqual([safe.mode, safe.center.state], ["direct", "unavailable"]);
  assert.match(safe.center.reason, /wallet address/);
  const delegated = await planner({ code: "0xef0100" + "a".repeat(40) }).plan([84532]);
  assert.equal(delegated.center.state, "pending");
});
test("without a Center URL, launches are self-paid and not listed", async () => {
  const plan = await planner({ config: {} }).plan([84532, 11155420]);
  assert.deepEqual([plan.mode, plan.center.state], ["relayr", "unavailable"]);
});

test("a chain without the AutoStick helper is shown as unavailable with its reason", () => {
  const configs = { 84532: { deployer: DEPLOYER, autoStickAdapter: "0x9B091e21d25c424De67751F4b6Ae8494351218C5" }, 11155420: { deployer: DEPLOYER }, 421614: {} };
  const context = vm.createContext({ window: { STICKY_CONFIG: { demoMode: false } }, StickyLaunchPlan, stickyDeploymentFor: (chainId) => configs[chainId] });
  vm.runInContext(slice("function launchChainBlocker(", "\nfunction renderCreateChains"), context);
  assert.equal(context.launchChainBlocker({ chainId: 84532 }), "");
  assert.equal(context.launchChainBlocker({ chainId: 11155420 }), "no auto-stick helper");
  assert.equal(context.launchChainBlocker({ chainId: 421614 }), "not deployed");
  assert.equal(vm.runInContext("launchChainConfigured({ chainId: 11155420 })", context), false);
});
