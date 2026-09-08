"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const R = require("../relayr.js");
const BUNDLE = "12345678-1234-1234-1234-123456789012";
const ID1 = "11111111-1111-1111-1111-111111111111";
const ID2 = "22222222-2222-2222-2222-222222222222";
const word = (n) => BigInt(n).toString(16).padStart(64, "0");
const addr = (n) => "0x" + BigInt(n).toString(16).padStart(40, "0");
const h = (n) => "0x" + word(n);
const ACCOUNT = addr(1), TARGET = addr(2), PROJECTS = addr(3), CONTROLLER = addr(4), TOKEN = addr(5), STICKY_TOKEN = addr(6), RELAYER = addr(7);
const HASH = h(11), BLOCK = h(12);
const clone = (value) => JSON.parse(JSON.stringify(value));
const ENTRY = { chain: 1, target: TARGET, data: "0x00d5ce37" + [TOKEN, 224, 224, 224, 100, 224, 1].map(word).join(""), value: "100000000000000" };
const EXPECTED = { projects: PROJECTS, controller: CONTROLLER, stakedToken: TOKEN, cashOutTaxRate: "100", soulbound: true };
// Runtime read from the pinned endpoint on Ethereum. keccak256 must match the immutable pin.
const PAYMENT_CODE = "0x608060405260043610156010575f80fd5b5f3560e01c63103903a7146022575f80fd5b604036600319011260ef576004356fffffffffffffffffffffffffffffffff19811680910360ef5760243564ffffffffff811680910360ef5780421160ce575f341560c6575b5f8080809373755ff2f75a0a586ecfa2b9a3c959cb662458a1053491f11560bb5760407fb96b060a9c075a83da0cf1f9405deeb5df21df681a762de16c3d5eaf99531cd8918151903482526020820152a2005b6040513d5f823e3d90fd5b506108fc6068565b90630f01bd8760e21b5f5260045260245264ffffffffff421660445260645ffd5b5f80fdfea26469706673582212206ea0d2ba1e0cb26cc9293b24f1a7aecc1de7e328ca83d6b3bf5382ac44c7390064736f6c634300081a0033";
function payment(chain = 1, deadline = Math.floor(Date.now() / 1000) + 3600) {
  return { chain, amount: "123456789012345678", target: R.PAYMENT_ADDRESS, token: R.NATIVE_TOKEN,
    calldata: R.PAYMENT_SELECTOR + BUNDLE.replaceAll("-", "") + "0".repeat(32) + word(deadline), payment_deadline: new Date(deadline * 1000).toISOString() };
}
function quoteFixture(entries = [ENTRY]) {
  const ordered = R.orderedEntries(entries);
  const ids = [ID1, ID2].slice(0, entries.length);
  const unbound = { bundle_uuid: BUNDLE, tx_uuids: ids, payment_info: [payment()] };
  const transactions = ordered.map((entry, i) => ({ tx_uuid: ids[i], request: entry, status: { state: "Pending" } }));
  const bound = { bundle_uuid: BUNDLE, payment_info: unbound.payment_info, transactions,
    expectedTransactions: ordered.map((entry, i) => ({ txUuid: ids[i], chain: entry.chain, entry })) };
  return { ordered, unbound, bound, status: { bundle_uuid: BUNDLE, transactions } };
}
function clientFor(fetch = async () => { throw Error("unexpected fetch"); }, rpc = async () => { throw Error("unexpected RPC"); }) {
  return R.createClient({ fetch, rpc });
}
const response = (body) => ({ ok: true, json: async () => body });
function evidence(entry = ENTRY, sender = RELAYER) {
  const tx = { hash: HASH, chainId: "0x1", blockNumber: "0xa", blockHash: BLOCK, transactionIndex: "0x0", from: sender, to: entry.target, input: entry.data, value: "0x" + BigInt(entry.value).toString(16) };
  const logBase = { transactionHash: HASH, blockHash: BLOCK, blockNumber: "0xa", removed: false };
  const receipt = { transactionHash: HASH, blockHash: BLOCK, blockNumber: "0xa", transactionIndex: "0x0", from: sender, to: entry.target, status: "0x1",
    logs: [
      { ...logBase, address: TARGET, topics: [R.DEPLOY_TOPIC, h(123), h(TOKEN)], data: "0x" + [STICKY_TOKEN, 100, 1, sender].map(word).join("") },
      { ...logBase, address: PROJECTS, topics: [R.CREATE_TOPIC, h(123), h(TARGET)], data: "0x" + word(CONTROLLER) },
    ] };
  const block = { hash: BLOCK, number: "0xa", transactions: [HASH] };
  const fixture = { tx, receipt, block, finalized: { hash: BLOCK, number: "0xa", transactions: [HASH] }, chain: "0x1", code: PAYMENT_CODE, callResult: "0x", calls: [] };
  fixture.rpc = async (chain, method, params) => {
    fixture.calls.push({ chain, method, params });
    return method === "eth_chainId" ? fixture.chain : method === "eth_getTransactionByHash" ? fixture.tx
      : method === "eth_getTransactionReceipt" ? fixture.receipt : method === "eth_getBlockByNumber" ? (params[0] === "finalized" ? fixture.finalized : fixture.block)
      : method === "eth_getCode" ? fixture.code : method === "eth_call" ? fixture.callResult : assert.fail(method);
  };
  return fixture;
}

test("Keccak matches Ethereum vectors including rate-boundary padding", () => {
  assert.equal(R.keccak256("0x"), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  assert.equal(R.keccak256("0x616263"), "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
  for (const [n, hash] of [[135, "f1d6ccc06d572a1e3f4fb6320f8fd3a2e3f1044c45e4f5d863f5a1b6a0ec3b7c"], [136, "2d417340362cd4144efbf52adc1bfb7a4b40254f55f3b0f09efa6a1ef299b51a"], [137, "b00891248c94192303027a8e95a1fc8dc700c0c599733f5c2af5865da2047c3e"], [272, "b9e89d2eccfc4597f4d706170d9bb9b0e2eb00c01caab48d25decb57f5408886"]]) assert.equal(R.keccak256("0x" + "ff".repeat(n)), "0x" + hash);
  assert.equal(R.keccak256(PAYMENT_CODE), R.PAYMENT_CODE_HASH);
  assert.throws(() => R.keccak256("0xf"));
});
test("destinations stay in one network family and virtual nonces advance independently", () => {
  assert.deepEqual(R.paymentChains([1, 10]), [1, 10, 8453, 42161]);
  assert.deepEqual(R.paymentChains([11155111]), [11155111, 11155420, 84532, 421614]);
  for (const ids of [[], [1, 11155111], [31337], ["1"]]) assert.deepEqual(R.paymentChains(ids), []);
  assert.throws(() => R.orderedEntries([]));
  assert.throws(() => R.orderedEntries([ENTRY, { ...ENTRY, chain: 11155111 }]));
  assert.deepEqual(R.orderedEntries([ENTRY, { ...ENTRY, chain: 10 }, ENTRY]).map((x) => x.virtual_nonce), [0, 0, 1]);
});
test("quote publication is durable before POST and UUIDs persist before binding GET", async () => {
  const fixture = quoteFixture();
  const sequence = [];
  const client = clientFor(async (url, options) => {
    sequence.push(options.method || "GET");
    if (options.method === "POST") {
      assert.deepEqual(JSON.parse(options.body), { transactions: fixture.ordered, virtual_nonce_mode: "ChainIndependent" });
      return response(fixture.unbound);
    }
    assert.equal(url, "https://api.relayr.ba5ed.com/v1/bundle/" + BUNDLE);
    return response(fixture.status);
  });
  const bound = await client.postBundle([ENTRY], { beforePublish: async () => sequence.push("persist-before"), onPublished: async (known) => { assert.equal(known.bundle_uuid, BUNDLE); sequence.push("persist-uuid"); } });
  assert.deepEqual(sequence, ["persist-before", "POST", "persist-uuid", "GET"]);
  assert.deepEqual(bound.expectedTransactions, fixture.bound.expectedTransactions);
  assert(Object.isFrozen(bound.expectedTransactions[0].entry));
});
test("missing or failed durable persistence prevents network publication", async () => {
  let requests = 0;
  const client = clientFor(async () => { requests++; });
  await assert.rejects(client.postBundle([ENTRY]));
  await assert.rejects(client.postBundle([ENTRY], { beforePublish: () => { throw Error("disk full"); }, onPublished() {} }), /disk full/);
  assert.equal(requests, 0);
});
test("known UUID survives malformed POST payload before binding validation fails", async () => {
  let published;
  const client = clientFor(async () => response({ bundle_uuid: BUNDLE, payment_info: null, tx_uuids: [] }));
  await assert.rejects(client.postBundle([ENTRY], { beforePublish() {}, onPublished(value) { published = value; } }), /every transaction/);
  assert.equal(published.bundle_uuid, BUNDLE);
});
test("lost POST response is not retried and known UUID storage failure prevents GET", async () => {
  let requests = 0, before = 0;
  const client = clientFor(async () => { requests++; throw Error("network lost"); });
  await assert.rejects(client.postBundle([ENTRY], { beforePublish() { before++; }, onPublished() {} }), /network lost/);
  assert.equal(requests, 1); assert.equal(before, 1);
  const fixture = quoteFixture();
  const client2 = clientFor(async () => { requests++; return response(fixture.unbound); });
  await assert.rejects(client2.postBundle([ENTRY], { beforePublish() {}, onPublished() { throw Error("storage lost"); } }), /storage lost/);
  assert.equal(requests, 2);
});
test("binding matches exact requests independent of provider UUID and transaction order", async () => {
  const fixture = quoteFixture([ENTRY, { ...ENTRY, chain: 10 }]);
  fixture.unbound.tx_uuids.reverse(); fixture.status.transactions.reverse();
  const bound = await clientFor(async () => response(fixture.status)).bindQuote(fixture.unbound, [ENTRY, { ...ENTRY, chain: 10 }]);
  assert.deepEqual(bound.expectedTransactions.map((x) => x.txUuid), [ID1, ID2]);
});
test("saved bound quote resumes offline and still binds frozen destination calldata", async () => {
  const { bound } = quoteFixture();
  const client = clientFor();
  assert.deepEqual((await client.bindQuote(clone(bound), [ENTRY])).expectedTransactions, bound.expectedTransactions);
  await assert.rejects(client.bindQuote(clone(bound), [{ ...ENTRY, data: "0x1234" }]), /frozen/);
  const corrupted = clone(bound); corrupted.expectedTransactions[0].entry.virtual_nonce = 2;
  await assert.rejects(client.bindQuote(corrupted, [ENTRY]), /nonces/);
});
for (const [name, mutate] of [
  ["changed calldata", (f) => { f.status.transactions[0].request.data = "0xdeadbeef"; }],
  ["changed target", (f) => { f.status.transactions[0].request.target = ACCOUNT; }],
  ["changed value", (f) => { f.status.transactions[0].request.value = "0"; }],
  ["changed nonce", (f) => { f.status.transactions[0].request.virtual_nonce = 1; }],
  ["changed chain", (f) => { f.status.transactions[0].request.chain = 10; }],
  ["foreign UUID", (f) => { f.status.transactions[0].tx_uuid = ID2; }],
  ["missing transaction", (f) => { f.status.transactions = []; }],
  ["wrong bundle", (f) => { f.status.bundle_uuid = ID2; }],
]) test(`quote binding rejects ${name}`, async () => {
  const fixture = clone(quoteFixture()); mutate(fixture);
  await assert.rejects(clientFor(async () => response(fixture.status)).bindQuote(fixture.unbound, [ENTRY]));
});
test("funding options cannot appear from an unbound POST response", () => {
  assert.throws(() => R.paymentOptions(quoteFixture().unbound, [1]), /authenticated/);
});
test("funding choices preserve exact ETH amount and reject wrong family or conflicting offers", () => {
  const { bound } = quoteFixture();
  bound.payment_info.push(payment(10), payment(11155111), { ...payment(10), amount: "9" });
  assert.deepEqual(R.paymentOptions(bound, [1]).map((x) => x.chain), [1]);
  assert.equal(R.paymentLabel(payment()), "Ethereum — 0.123456789012345678 ETH");
  assert.throws(() => R.paymentOptions(bound, [10]), /destinations/);
});
for (const [name, mutate] of [
  ["target", (p) => { p.target = ACCOUNT; }],
  ["token", (p) => { p.token = ACCOUNT; }],
  ["missing native token", (p) => { delete p.token; }],
  ["unsupported chain", (p) => { p.chain = 31337; }],
  ["negative amount", (p) => { p.amount = "-1"; }],
  ["overflow amount", (p) => { p.amount = (2n ** 256n).toString(); }],
  ["selector", (p) => { p.calldata = "0xffffffff" + p.calldata.slice(10); }],
  ["UUID", (p) => { p.calldata = p.calldata.slice(0, 10) + "f" + p.calldata.slice(11); }],
  ["UUID padding", (p) => { p.calldata = p.calldata.slice(0, 42) + "f" + p.calldata.slice(43); }],
  ["deadline", (p) => { p.payment_deadline = "2099-01-01T00:00:00Z"; }],
  ["trailing calldata", (p) => { p.calldata += "00"; }],
]) test(`payment parsing rejects modified ${name}`, () => {
  const p = payment(); mutate(p);
  assert.throws(() => R.paymentDetails(p, BUNDLE));
  const { bound } = quoteFixture(); bound.payment_info = [p];
  assert.deepEqual(R.paymentOptions(bound, [1]), []);
});
test("expired payments remain inspectable but cannot be newly paid", () => {
  const p = payment(1, 1);
  assert.throws(() => R.paymentDetails(p, BUNDLE), /expired/);
  assert.equal(R.paymentDetails(p, BUNDLE, { allowExpired: true }).deadline, 1n);
});
test("partial status stays pending and foreign status requests never become evidence", async () => {
  const f = quoteFixture(); f.status.transactions = [];
  assert.deepEqual(await clientFor(async () => response(f.status)).fetchStatus(f.bound), []);
  f.status.transactions = [{ tx_uuid: ID2, request: f.ordered[0] }];
  await assert.rejects(clientFor(async () => response(f.status)).fetchStatus(f.bound), /differs/);
});
test("status label cannot prove execution and contradictory or malformed hashes are rejected", () => {
  assert.equal(R.destinationHash({ status: { state: "Success" } }), null);
  assert.equal(R.destinationHash({ status: { data: { hash: HASH } } }), HASH);
  assert.equal(R.destinationHash({ status: { data: { transaction: { hash: HASH } } } }), HASH);
  assert.equal(R.destinationHash({ status: { data: { hash: HASH, transaction: { hash: h(99) } } } }), null);
  assert.equal(R.destinationHash({ status: { data: { hash: 5, transaction: { hash: HASH } } } }), null);
});
test("payment validates pinned runtime and simulates exactly reviewed sender/value/calldata", async () => {
  const f = evidence(); const p = payment();
  const details = await clientFor(undefined, f.rpc).validatePayment(p, BUNDLE, ACCOUNT);
  assert.equal(details.amount.toString(), p.amount);
  const simulation = f.calls.find((call) => call.method === "eth_call");
  assert.deepEqual(simulation.params, [{ from: ACCOUNT, to: R.PAYMENT_ADDRESS, value: "0x" + BigInt(p.amount).toString(16), data: p.calldata, gas: R.PAYMENT_GAS }, "latest"]);
});
for (const [name, mutate] of [["wrong RPC chain", (f) => { f.chain = "0xa"; }], ["changed runtime", (f) => { f.code = "0x6000"; }], ["empty runtime", (f) => { f.code = "0x"; }], ["oversized runtime", (f) => { f.code = "0x" + "00".repeat(2049); }], ["unexpected simulation output", (f) => { f.callResult = "0x01"; }]]) test(`payment preflight rejects ${name}`, async () => {
  const f = evidence(); mutate(f);
  await assert.rejects(clientFor(undefined, f.rpc).validatePayment(payment(), BUNDLE, ACCOUNT));
});
test("canonical direct Relayr deployment verifies project creation and relayer event caller", async () => {
  const f = evidence();
  assert.deepEqual(await clientFor(undefined, f.rpc).verifyDeployment(HASH, ENTRY, EXPECTED), { status: "confirmed", hash: HASH, projectId: "123", token: STICKY_TOKEN });
  await assert.rejects(clientFor(undefined, f.rpc).verifyDeployment(HASH, ENTRY, { ...EXPECTED, from: ACCOUNT }), /does not match/);
});
for (const [name, mutate] of [
  ["transaction calldata", (f) => { f.tx.input += "00"; }],
  ["transaction value", (f) => { f.tx.value = "0x0"; }],
  ["transaction target", (f) => { f.tx.to = ACCOUNT; f.receipt.to = ACCOUNT; }],
  ["transaction chain", (f) => { f.tx.chainId = "0xa"; }],
  ["transaction hash", (f) => { f.tx.hash = h(99); }],
  ["receipt hash", (f) => { f.receipt.transactionHash = h(99); }],
  ["receipt sender", (f) => { f.receipt.from = ACCOUNT; }],
  ["reorged block", (f) => { f.block.hash = h(99); }],
  ["block inclusion", (f) => { f.block.transactions = []; }],
  ["removed log", (f) => { f.receipt.logs[0].removed = true; }],
  ["log block hash", (f) => { f.receipt.logs[0].blockHash = h(99); }],
  ["event tax", (f) => { f.receipt.logs[0].data = "0x" + [STICKY_TOKEN, 101, 1, RELAYER].map(word).join(""); }],
  ["event caller", (f) => { f.receipt.logs[0].data = "0x" + [STICKY_TOKEN, 100, 1, ACCOUNT].map(word).join(""); }],
  ["event token", (f) => { f.receipt.logs[0].topics[2] = h(ACCOUNT); }],
  ["event soulbound", (f) => { f.receipt.logs[0].data = "0x" + [STICKY_TOKEN, 100, 0, RELAYER].map(word).join(""); }],
  ["zero deployed token", (f) => { f.receipt.logs[0].data = "0x" + [0, 100, 1, RELAYER].map(word).join(""); }],
  ["project owner", (f) => { f.receipt.logs[1].topics[2] = h(ACCOUNT); }],
  ["project caller", (f) => { f.receipt.logs[1].data = "0x" + word(TARGET); }],
  ["project ID", (f) => { f.receipt.logs[1].topics[1] = h(124); }],
  ["missing creation", (f) => { f.receipt.logs.pop(); }],
  ["duplicate deployment", (f) => { f.receipt.logs.push(clone(f.receipt.logs[0])); }],
]) test(`deployment receipt rejects ${name}`, async () => {
  const f = evidence(); mutate(f);
  await assert.rejects(clientFor(undefined, f.rpc).verifyDeployment(HASH, ENTRY, EXPECTED));
});
test("missing transaction evidence is pending; reverted evidence needs finalized canonical block", async () => {
  const f = evidence(); f.tx = null;
  assert.deepEqual(await clientFor(undefined, f.rpc).verifyDeployment(HASH, ENTRY, EXPECTED), { status: "pending" });
  const g = evidence(); g.receipt.status = "0x0";
  assert.deepEqual(await clientFor(undefined, g.rpc).verifyDeployment(HASH, ENTRY, EXPECTED), { status: "reverted", hash: HASH, finalized: true });
  g.finalized.number = "0x9";
  assert.deepEqual(await clientFor(undefined, g.rpc).verifyDeployment(HASH, ENTRY, EXPECTED), { status: "reverted", hash: HASH, finalized: false });
});
test("payment receipt binds wallet sender and exact old quote even after expiration", async () => {
  const p = payment(1, 1);
  const f = evidence({ target: p.target, data: p.calldata, value: p.amount }, ACCOUNT);
  assert.deepEqual(await clientFor(undefined, f.rpc).verifyPayment(HASH, p, BUNDLE, ACCOUNT), { status: "confirmed", hash: HASH });
  await assert.rejects(clientFor(undefined, f.rpc).verifyPayment(HASH, p, BUNDLE, RELAYER), /does not match/);
  f.tx.value = "0x0";
  await assert.rejects(clientFor(undefined, f.rpc).verifyPayment(HASH, p, BUNDLE, ACCOUNT), /does not match/);
});
function safeExecution(entry, success = true) {
  const f = evidence(entry, RELAYER);
  const data = entry.data.slice(2);
  const callTail = word(data.length / 2) + data.padEnd(Math.ceil(data.length / 64) * 64, "0");
  f.tx.to = ACCOUNT;
  f.receipt.to = ACCOUNT;
  f.tx.value = "0x0";
  f.tx.input = "0x6a761202" + [entry.target, entry.value, 320, 0, 0, 0, 0, 0, 0, 320 + callTail.length / 2].map(word).join("") + callTail + word(0);
  f.receipt.logs = success && entry.target === TARGET ? f.receipt.logs : [];
  if (f.receipt.logs.length) f.receipt.logs[0].data = "0x" + [STICKY_TOKEN, 100, 1, ACCOUNT].map(word).join("");
  f.receipt.logs.push({ address: ACCOUNT, topics: [success ? "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e" : "0x23428b18acfb3ea64b08dc0c1d296ea9c09702c09083ca5272e64d115b687d23"],
    data: h(90) + word(0), transactionHash: HASH, blockHash: BLOCK, blockNumber: "0xa", removed: false });
  return f;
}
test("Safe deployment correlates exact inner call and Safe caller in Sticky event", async () => {
  const f = safeExecution(ENTRY);
  const client = clientFor(undefined, f.rpc);
  assert.equal((await client.verifyDeployment(HASH, ENTRY, { ...EXPECTED, from: ACCOUNT, safeTxHash: h(90) })).status, "confirmed");
  await assert.rejects(client.verifyDeployment(HASH, ENTRY, EXPECTED), /does not match/);
  await assert.rejects(client.verifyDeployment(HASH, ENTRY, { ...EXPECTED, from: ACCOUNT, safeTxHash: h(91) }), /does not match/);
  f.receipt.logs[0].data = "0x" + [STICKY_TOKEN, 100, 1, RELAYER].map(word).join("");
  await assert.rejects(client.verifyDeployment(HASH, ENTRY, { ...EXPECTED, from: ACCOUNT }), /configuration/);
});
test("Safe payment verifies exact inner quote, execution event and optional known proposal", async () => {
  const p = payment();
  const f = safeExecution({ target: p.target, data: p.calldata, value: p.amount });
  const client = clientFor(undefined, f.rpc);
  assert.equal((await client.verifyPayment(HASH, p, BUNDLE, ACCOUNT, { safeTxHash: h(90) })).status, "confirmed");
  await assert.rejects(client.verifyPayment(HASH, p, BUNDLE, ACCOUNT, { safeTxHash: h(91) }), /does not match/);
  f.receipt.logs[0].blockHash = h(99);
  await assert.rejects(client.verifyPayment(HASH, p, BUNDLE, ACCOUNT), /canonical/);
});
test("only proposal-bound Safe inner failure can prove a finalized unsuccessful proposal", async () => {
  const p = payment();
  const f = safeExecution({ target: p.target, data: p.calldata, value: p.amount }, false);
  const client = clientFor(undefined, f.rpc);
  assert.deepEqual(await client.verifyPayment(HASH, p, BUNDLE, ACCOUNT), { status: "unresolved", hash: HASH });
  assert.deepEqual(await client.verifyPayment(HASH, p, BUNDLE, ACCOUNT, { safeTxHash: h(90) }), { status: "reverted", hash: HASH, finalized: true });
  f.finalized.number = "0x9";
  assert.deepEqual(await client.verifyPayment(HASH, p, BUNDLE, ACCOUNT, { safeTxHash: h(90) }), { status: "reverted", hash: HASH, finalized: false });
  f.receipt.status = "0x0";
  f.receipt.logs = [];
  assert.deepEqual(await client.verifyPayment(HASH, p, BUNDLE, ACCOUNT, { safeTxHash: h(90) }), { status: "unresolved", hash: HASH });
});
