"use strict";
// Review copy sliced from app.js: step counts, value wrapping, shortened addresses.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const Tx = require("../tx-engine.js");
const source = fs.readFileSync(require.resolve("../app.js"), "utf8");
const begin = source.indexOf("const transactionsLeft =");
const end = source.indexOf("\nfunction renderConfirmSteps", begin);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const context = vm.createContext({ esc });
vm.runInContext(source.slice(begin, end) + "\nthis.transactionsLeft = transactionsLeft;", context);
const ADAPTER = "0x9B091e21d25c424De67751F4b6Ae8494351218C5";

test("the review counts what is left in plain words", () => {
  assert.equal(context.transactionsLeft(1), "1 transaction left");
  assert.equal(context.transactionsLeft(3), "3 transactions left");
  assert.doesNotMatch(source, /transactions? remains?\b/);
});
test("prose wraps at spaces; only addresses and hex may break anywhere", () => {
  const html = context.reviewValue("5% cash out tax. Part of each unstick stays with the holders who remain.");
  assert.doesNotMatch(html, /hexv/);
  assert.equal(context.reviewValue(`sent by ${ADAPTER}`), `sent by <span class="hexv">${ADAPTER}</span>`);
  assert.doesNotMatch(source, /<td style="word-break:break-all">\$\{esc\(String\(v\)\)\}/);
});
test("a shortened address keeps the full one in its title and survives the saved plan", () => {
  const value = { text: "AutoStick 0xc6f0…82E5, trusted. Each holder still opts in.", title: ADAPTER };
  assert.equal(context.reviewValue(value), `<span title="${ADAPTER}">AutoStick 0xc6f0…82E5, trusted. Each holder still opts in.</span>`);
  assert.equal(context.reviewValue({ text: "<b>", title: '"x' }), '<span title="&quot;x">&lt;b&gt;</span>');
  const saved = Tx.normalizeTx({ chainId: 1, from: "0x" + "1".repeat(40), to: "0x" + "2".repeat(40), rpcUrl: "https://rpc.example", args: [["AUTO-STICK", value], ["NAME", "Sticky"]] });
  assert.deepEqual(saved.args, [["AUTO-STICK", value], ["NAME", "Sticky"]]);
});
test("the launch review rows use no em dashes", () => {
  const start = source.indexOf("async function prepareStickyLaunch(");
  const stop = source.indexOf("\n// A launch is listed on Juicebox Center", start);
  assert.doesNotMatch(source.slice(start, stop), /—/);
  assert.doesNotMatch(source, /Nothing is signed until you confirm[^"]*—/);
});
