const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync(require.resolve("../app.js"), "utf8");
const escapeSource = source.slice(source.indexOf("const esc ="), source.indexOf("// --------------------------------------------------------------------- state"));
const bonusSource = source.slice(source.indexOf("function renderBonusSplit("), source.indexOf("const soulboundHint ="));
const renderBonusSplit = vm.runInNewContext(escapeSource + bonusSource + "\nrenderBonusSplit");

test("token metadata in the cash out illustration remains text", () => {
  const el = { innerHTML: "" };
  const symbol = '<img src=x onerror="window.stickyXss=1">';
  renderBonusSplit(0.1, { el, sym: symbol, stSym: symbol });
  assert.ok(!el.innerHTML.includes("<img"), "untrusted ERC-20 metadata must not create elements");
  assert.match(el.innerHTML, /&lt;img src=x onerror=&quot;window\.stickyXss=1&quot;&gt;/);
  assert.match(el.innerHTML, /87\.8/);
});
