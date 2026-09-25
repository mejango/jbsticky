"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const C = require("../center-intents.js");
const R = require("../relayr.js");
const OWNER = "0x042F619EED558723252593DB0375fC34306f203A";
const DEPLOYER = "0xda38ec48b5b1d186b02ba99f297e95153bee33a9";
const INTENT = "0f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b";
const SIGNATURE = "0x" + "ab".repeat(65);
const listing = (overrides = {}) => C.buildEnvelope({
  calls: [{ chainId: 11155420, to: DEPLOYER, data: "0x00d5ce37ABCD" }, { chainId: 84532, to: DEPLOYER, data: "0x00d5ce37abcd" }],
  owner: OWNER, name: "Sticky Test — ünïcode", symbol: "STICKYT", stakedToken: "0x" + "5".repeat(40), stakedTokenSymbol: "T",
  cashOutTaxRate: 1000n, soulbound: false, launchId: "abc", projectUri: "data:application/json,{}", ...overrides,
});
// What Center's normalizeEnvelope returns: `to` checksummed, everything else as sent.
const centerNormalized = (envelope) => ({ ...envelope, deploymentCalls: envelope.deploymentCalls.map((call) => ({ ...call, to: "0xdA38Ec48B5b1d186B02BA99F297e95153BEE33a9" })) });
const reply = (status, body) => ({ ok: status < 400, status, json: async () => body });
function center(routes) {
  const calls = [];
  const fetch = async (url, init) => {
    const path = url.replace("https://juicebox.center", "");
    calls.push({ path, method: init.method || "GET", body: init.body ? JSON.parse(init.body) : undefined, init });
    const route = routes[`${init.method || "GET"} ${path}`];
    if (!route) throw new TypeError("Failed to fetch");
    return route(init.body ? JSON.parse(init.body) : undefined);
  };
  return { client: C.createClient({ fetch }), calls };
}
const messageRoute = (mutate = (body) => body) => (body) => {
  const envelope = centerNormalized(body);
  const contentHash = R.keccak256(C.utf8Hex(C.canonicalJson(envelope)));
  return reply(200, mutate({ contentHash, message: C.signingMessage(contentHash), envelope }));
};

test("the envelope is sticky.center/deploy.v1 for deployment version 6, sorted by chain, with no call value", () => {
  const envelope = listing();
  assert.equal(envelope.format, "sticky.center/deploy.v1");
  assert.equal(envelope.deploymentVersion, "6");
  assert.deepEqual(envelope.chainIds, [84532, 11155420]);
  assert.deepEqual(envelope.jb.chainIds, envelope.chainIds);
  assert.deepEqual(envelope.deploymentCalls, [{ chainId: 84532, to: DEPLOYER, data: "0x00d5ce37abcd" }, { chainId: 11155420, to: DEPLOYER, data: "0x00d5ce37abcd" }]);
  assert.deepEqual({ app: envelope.jb.app, kind: envelope.jb.kind, name: envelope.jb.name, owner: envelope.jb.owner, cashOutTaxRate: envelope.jb.cashOutTaxRate },
    { app: "sticky", kind: "sticky", name: "Sticky Test — ünïcode", owner: OWNER, cashOutTaxRate: "1000" });
  assert.match(envelope.format, /^[a-z0-9.-]{1,80}\/[a-zA-Z0-9._-]{1,32}$/);
  assert.throws(() => listing({ calls: [{ chainId: 1, to: DEPLOYER, data: "0x00d5ce37" }, { chainId: 1, to: DEPLOYER, data: "0x00d5ce37" }] }), /one launch per chain/);
});
test("the content hash matches Center's keccak256 of canonical JSON (vector from viem)", () => {
  const hash = R.keccak256(C.utf8Hex(C.canonicalJson(centerNormalized(listing()))));
  assert.equal(hash, "0xf9d00ba55aa7a79c95f4fef8f73ed77316caa67b93649f659dc4b6150f24b821");
  assert.equal(C.signingMessage(hash), `Juice Central project intent\nVersion: 1\nContent hash: ${hash}`);
});
test("publishing signs only Center's message for exactly this envelope, then posts it with the signature", async () => {
  const { client, calls } = center({
    "POST /v1/intents/message": messageRoute(),
    "POST /v1/intents": (body) => reply(201, { id: INTENT, contentHash: R.keccak256(C.utf8Hex(C.canonicalJson(centerNormalized(listing())))), publisher: body.publisher }),
  });
  const prepared = await client.prepare(listing());
  assert.equal(prepared.message, C.signingMessage(prepared.contentHash));
  const intent = await client.publish(prepared, OWNER, SIGNATURE);
  assert.equal(intent.id, INTENT);
  const posted = calls[1].body;
  assert.equal(posted.publisher, OWNER); assert.equal(posted.signature, SIGNATURE);
  assert.equal(posted.format, "sticky.center/deploy.v1");
  assert.equal(calls[0].init.credentials, "omit");
});
for (const [name, mutate] of [
  ["a changed envelope", (body) => ({ ...body, envelope: { ...body.envelope, jb: { ...body.envelope.jb, owner: "0x" + "9".repeat(40) } } })],
  ["a message for another hash", (body) => ({ ...body, message: C.signingMessage("0x" + "1".repeat(64)) })],
  ["a hash that isn't the envelope's", (body) => ({ ...body, contentHash: "0x" + "1".repeat(64), message: C.signingMessage("0x" + "1".repeat(64)) })],
  ["a malformed reply", () => ({ message: 1 })],
]) test(`Center returning ${name} is never signed`, async () => {
  const { client } = center({ "POST /v1/intents/message": messageRoute(mutate) });
  await assert.rejects(client.prepare(listing()), (error) => error instanceof C.CenterError && ["mismatch", "malformed"].includes(error.code));
});
test("an origin Center refuses reads as unreachable; Center's own errors keep status and code", async () => {
  const { client } = center({ "POST /v1/intents": () => reply(429, { error: { code: "publish_limit", message: "Publish limit reached" } }) });
  await assert.rejects(client.prepare(listing()), (error) => error.code === "unreachable" && error.status === 0);
  await assert.rejects(client.publish({ envelope: listing(), contentHash: "0x" }, OWNER, SIGNATURE), (error) => error.status === 429 && error.code === "publish_limit");
  await assert.rejects(client.publish({ envelope: listing() }, OWNER, "0x12"), /invalid signature/);
});
test("recording posts each chain's lowercase hash once 2 confirmations exist; earlier posts wait", async () => {
  let confirmations = 1;
  const { client, calls } = center({ [`POST /v1/intents/${INTENT}/deployments`]: () => confirmations < 2
    ? reply(422, { error: { code: "deployment_unverified", message: "Deployment has 1 confirmations; 2 required" } })
    : reply(201, { chainId: 84532, projectId: "12" }) });
  const hash = "0x" + "AB".repeat(32);
  assert.deepEqual(await client.record(INTENT, { chainId: 84532, projectId: 12n, transactionHash: hash }), { status: "wait" });
  confirmations = 2;
  assert.deepEqual(await client.record(INTENT, { chainId: 84532, projectId: 12n, transactionHash: hash }), { status: "recorded" });
  assert.deepEqual(calls[1].body, { chainId: 84532, projectId: "12", transactionHash: hash.toLowerCase() });
});
test("a record Center rejects for another reason is an error", async () => {
  const { client } = center({ [`POST /v1/intents/${INTENT}/deployments`]: () => reply(409, { error: { code: "conflict", message: "Deployment already recorded" } }) });
  await assert.rejects(client.record(INTENT, { chainId: 1, projectId: 1, transactionHash: "0x" + "1".repeat(64) }), (error) => error.code === "conflict");
  await assert.rejects(client.get("not-a-uuid"), /listing ID is invalid/);
});
test("sponsored only when Center sponsors every chain and StickyDeployer trusts the forwarder on each", async () => {
  const trusted = async () => true;
  assert.equal(await C.sponsoredPlan({ chainIds: [84532, 11155420], isTrusted: trusted }), true);
  assert.equal(await C.sponsoredPlan({ chainIds: [1, 8453], isTrusted: trusted }), false, "Ethereum mainnet is never sponsored");
  assert.equal(await C.sponsoredPlan({ chainIds: [84532, 11155420], isTrusted: async (chainId) => chainId === 84532 }), false);
  assert.equal(await C.sponsoredPlan({ chainIds: [84532], isTrusted: async () => { throw new Error("execution reverted"); } }), false, "today's deployer reverts");
  assert.equal(await C.sponsoredPlan({ chainIds: [84532], isTrusted: () => { throw new Error("sync"); } }), false);
  assert.equal(await C.sponsoredPlan({ chainIds: [], isTrusted: trusted }), false);
  assert.equal(C.FORWARDER, "0x3bA60b60933916a7C87D0860DcEE62a0CE34E3e2");
  assert.equal(C.IS_TRUSTED_FORWARDER, "0x572b6c05");
});
