/* Decodes every write the site sends and checks it against the review rows before the wallet sees it.
   The confirm dialog shows decoded values, never the inputs a builder encoded. An unknown selector,
   a non-canonical encoding, or a row that disagrees with the calldata blocks the send. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyCalldata = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  // Every function the site encodes. Selectors are checked against keccak256 in the tests.
  const ABIS = [
    ["0x095ea7b3", "approve(address spender, uint256 amount)"],
    ["0xa9059cbb", "transfer(address to, uint256 amount)"],
    ["0x00d5ce37", "deployStickyFor(address stakedToken, string name, string symbol, string projectUri, uint256 cashOutTaxRate, address[] granters, bool soulbound)"],
    ["0xfef43257", "pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)"],
    ["0x13da8317", "cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address beneficiary, bytes metadata)"],
    ["0x77531866", "fund(address hook, address token, uint256 amount, uint256 groupId)"],
    ["0x83d96f8f", "beginVesting(address hook, uint256 groupId, uint256[] tokenIds, address[] tokens)"],
    ["0x4d355ce6", "collectVestedRewards(address hook, uint256 groupId, uint256[] tokenIds, address[] tokens, address beneficiary)"],
    ["0x415174c8", "setConfigFor(uint256 projectId, bool enabled, uint128 minimumAmount, uint48 cooldown)"],
    ["0x8244fb99", "compoundFor(uint256 projectId, address holder, uint256[] groupIds)"],
    ["0x40b5a05d", "stickRewardsFor(uint256 projectId, uint256[] groupIds)"],
    ["0xa15557e8", "beginVestingFor(uint256 projectId, address holder, uint256[] groupIds)"],
    ["0x3a799596", "setTrustedSenderFor(uint256 projectId, address sender, bool trusted)"],
    ["0xa4b4e8bf", "settleFor(address stickyToken, uint256 groupId, address token)"],
    ["0x103903a7", "prepayment(bytes16 bundle, uint40 deadline)"],
    ["0xaf629bbb", "prepare(uint256 projectTokenCount, bytes32 beneficiary, uint256 minTokensReclaimed, address token, bytes32 metadata)"],
    ["0xb71c1179", "toRemote(address token)"],
    ["0xcbb2adce", "claim((address token, (uint256 index, bytes32 beneficiary, uint256 projectTokenCount, uint256 terminalTokenAmount, bytes32 metadata) leaf, bytes32[32] proof) claimData)"],
  ];

  class CalldataError extends Error {}
  const fail = (message) => { throw new CalldataError(message); };

  // ------------------------------------------------------------ signatures
  function splitTop(text) {
    const parts = [];
    let depth = 0, start = 0;
    for (let i = 0; i < text.length; i++) {
      if (text[i] === "(") depth++;
      else if (text[i] === ")") depth--;
      else if (text[i] === "," && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
      if (depth < 0) fail("Malformed function signature.");
    }
    if (depth !== 0) fail("Malformed function signature.");
    const last = text.slice(start);
    if (last.trim() || parts.length) parts.push(last);
    return parts.map((part) => part.trim());
  }
  function parseType(text) {
    let rest = text.trim();
    const dims = [];
    for (let match; (match = /\[(\d*)\]$/.exec(rest));) {
      dims.unshift(match[1] === "" ? null : Number(match[1]));
      rest = rest.slice(0, match.index);
    }
    let type;
    if (rest.startsWith("(") && rest.endsWith(")")) type = { kind: "tuple", components: parseParams(rest.slice(1, -1)) };
    else if (rest === "address" || rest === "bool" || rest === "string" || rest === "bytes") type = { kind: rest };
    else if (/^uint(\d+)$/.test(rest)) {
      const bits = Number(rest.slice(4));
      if (bits < 8 || bits > 256 || bits % 8) fail(`Unsupported type ${rest}.`);
      type = { kind: "uint", bits };
    } else if (/^bytes(\d+)$/.test(rest)) {
      const size = Number(rest.slice(5));
      if (size < 1 || size > 32) fail(`Unsupported type ${rest}.`);
      type = { kind: "fixedBytes", size };
    } else fail(`Unsupported type ${rest || "(empty)"}.`);
    for (const length of dims) type = { kind: "array", of: type, length };
    return type;
  }
  function parseParams(text) {
    return splitTop(text).map((part) => {
      const tuple = part.startsWith("(");
      const close = tuple ? part.lastIndexOf(")") : -1;
      const head = tuple ? part.slice(0, close + 1) + (/^\[\d*\](?:\[\d*\])*/.exec(part.slice(close + 1))?.[0] || "") : part.split(/\s+/)[0];
      const name = part.slice(head.length).trim();
      if (name && !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) fail("Malformed parameter name.");
      return { name, type: parseType(head) };
    });
  }
  const canonicalType = (type) => type.kind === "tuple" ? `(${type.components.map((c) => canonicalType(c.type)).join(",")})`
    : type.kind === "array" ? `${canonicalType(type.of)}[${type.length ?? ""}]`
      : type.kind === "uint" ? `uint${type.bits}` : type.kind === "fixedBytes" ? `bytes${type.size}` : type.kind;
  function parseSignature(signature) {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(([\s\S]*)\)\s*$/.exec(String(signature || ""));
    if (!match) fail("Malformed function signature.");
    const inputs = parseParams(match[2]);
    return { name: match[1], inputs, canonical: `${match[1]}(${inputs.map((input) => canonicalType(input.type)).join(",")})` };
  }
  const REGISTRY = new Map(ABIS.map(([selector, signature]) => [selector, { selector, signature, ...parseSignature(signature) }]));

  // --------------------------------------------------------------- decoding
  const MAX_ITEMS = 1024;
  const MAX_BYTES = 65536;
  const isDynamic = (type) => type.kind === "string" || type.kind === "bytes"
    || (type.kind === "array" && (type.length === null || isDynamic(type.of)))
    || (type.kind === "tuple" && type.components.some((c) => isDynamic(c.type)));
  const headSize = (type) => isDynamic(type) ? 32
    : type.kind === "tuple" ? type.components.reduce((sum, c) => sum + headSize(c.type), 0)
      : type.kind === "array" ? type.length * headSize(type.of) : 32;

  function reader(hex) {
    const size = hex.length / 2;
    const wordAt = (offset) => {
      if (!Number.isSafeInteger(offset) || offset < 0 || offset + 32 > size) fail("The calldata is shorter than its function needs.");
      return hex.slice(offset * 2, offset * 2 + 64);
    };
    return { size, wordAt, uintAt: (offset) => BigInt("0x" + wordAt(offset)), slice: (offset, length) => hex.slice(offset * 2, (offset + length) * 2) };
  }
  // Canonical decoding: every offset points exactly where a standard encoder puts it, padding is zero,
  // values fit their type, and nothing trails the last argument. Any other encoding is refused.
  function decodeStatic(type, r, offset) {
    if (type.kind === "tuple") return decodeSequence(type.components.map((c) => c.type), r, offset).values;
    if (type.kind === "array") return decodeSequence(Array(type.length).fill(type.of), r, offset).values;
    const value = r.uintAt(offset);
    if (type.kind === "uint") { if (value >> BigInt(type.bits)) fail("A number in the calldata is larger than its type."); return value; }
    if (type.kind === "address") { if (value >> 160n) fail("An address in the calldata has dirty high bits."); return "0x" + value.toString(16).padStart(40, "0"); }
    if (type.kind === "bool") { if (value > 1n) fail("A true/false value in the calldata is not 0 or 1."); return value === 1n; }
    if (type.kind === "fixedBytes") {
      const word = r.wordAt(offset);
      if (!/^0*$/.test(word.slice(type.size * 2))) fail("A fixed-size value in the calldata has dirty padding.");
      return "0x" + word.slice(0, type.size * 2);
    }
    fail("Unsupported static type.");
  }
  function decodeDynamic(type, r, offset) {
    if (type.kind === "string" || type.kind === "bytes") {
      const length = r.uintAt(offset);
      if (length > BigInt(MAX_BYTES)) fail("A byte string in the calldata is too long to review.");
      const n = Number(length), padded = Math.ceil(n / 32) * 32;
      if (offset + 32 + padded > r.size) fail("The calldata is shorter than its function needs.");
      const body = r.slice(offset + 32, n);
      if (!/^0*$/.test(r.slice(offset + 32 + n, padded - n))) fail("A byte string in the calldata has dirty padding.");
      let value = "0x" + body;
      if (type.kind === "string") {
        const bytes = new Uint8Array(n);
        for (let i = 0; i < n; i++) bytes[i] = parseInt(body.slice(i * 2, i * 2 + 2), 16);
        try { value = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { fail("A text value in the calldata is not valid UTF-8."); }
      }
      return { value, used: 32 + padded };
    }
    if (type.kind === "array" && type.length === null) {
      const length = r.uintAt(offset);
      if (length > BigInt(MAX_ITEMS)) fail("A list in the calldata is too long to review.");
      const inner = decodeSequence(Array(Number(length)).fill(type.of), r, offset + 32);
      return { value: inner.values, used: 32 + inner.used };
    }
    const types = type.kind === "tuple" ? type.components.map((c) => c.type) : Array(type.length).fill(type.of);
    const inner = decodeSequence(types, r, offset);
    return { value: inner.values, used: inner.used };
  }
  function decodeSequence(types, r, start) {
    let tail = start + types.reduce((sum, type) => sum + headSize(type), 0);
    let head = start;
    const values = [];
    for (const type of types) {
      if (isDynamic(type)) {
        const pointer = r.uintAt(head);
        if (pointer !== BigInt(tail - start)) fail("The calldata uses a non-standard offset.");
        const decoded = decodeDynamic(type, r, tail);
        values.push(decoded.value);
        tail += decoded.used;
      } else {
        values.push(decodeStatic(type, r, head));
      }
      head += headSize(type);
    }
    return { values, used: tail - start };
  }

  function decode(data) {
    const hex = String(data || "").toLowerCase();
    if (!/^0x[0-9a-f]*$/.test(hex) || hex.length % 2) fail("The transaction data is not hexadecimal bytes.");
    if (hex.length < 10) fail("The transaction has no function to call.");
    const selector = hex.slice(0, 10);
    const abi = REGISTRY.get(selector);
    if (!abi) fail(`This transaction calls an unknown function (${selector}). It was not sent.`);
    const body = hex.slice(10);
    const r = reader(body);
    const { values, used } = decodeSequence(abi.inputs.map((input) => input.type), r, 0);
    if (used !== r.size) fail("The calldata has extra bytes after its arguments.");
    return {
      selector, name: abi.name, signature: abi.signature, canonical: abi.canonical,
      params: abi.inputs.map((input, i) => ({ name: input.name, type: input.type, value: values[i] })),
    };
  }

  // ----------------------------------------------------------- comparison
  // Values compare in one plain form: numbers as decimal text, hex lowercased, lists and tuples as arrays.
  function canon(value) {
    if (Array.isArray(value)) return value.map(canon);
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "number") {
      if (!Number.isSafeInteger(value)) fail("A review value is not a whole number.");
      return String(value);
    }
    if (typeof value === "boolean") return value ? "true" : "false";
    const text = String(value);
    return /^0x[0-9a-fA-F]*$/.test(text) ? text.toLowerCase() : text;
  }
  const same = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));

  // ------------------------------------------------------------- display
  function formatUnits(value, decimals) {
    const base = 10n ** BigInt(decimals);
    const whole = value / base;
    const fraction = (value % base).toString().padStart(decimals, "0").replace(/0+$/, "");
    return fraction ? `${whole}.${fraction}` : whole.toString();
  }
  function groupLabel(groupId) {
    const id = BigInt(groupId);
    if (id === 0n) return "Everyone";
    const min = id / 1000n, max = id % 1000n;
    return max === 0n ? `Staked ${min}+ weeks` : `Staked ${min}–${max} weeks`;
  }
  function duration(seconds) {
    const s = Number(seconds);
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${s % 60}s`;
  }
  const noted = (text, note) => note ? `${text} (${note})` : text;
  const UNLIMITED = (1n << 256n) - 1n;
  function stickyUri(uri) {
    if (!uri.startsWith("data:application/json")) return null;
    try {
      const comma = uri.indexOf(",");
      const meta = JSON.parse(decodeURIComponent(uri.slice(comma + 1)));
      if (meta?.protocol !== "Sticky" || !Array.isArray(meta.chains)) return null;
      return `Sticky launch ${meta.launchId} on chains ${meta.chains.join(", ")}`;
    } catch { return null; }
  }
  // Formats one decoded value with a data-only hint from the builder.
  function formatValue(value, type, fmt = {}) {
    const kind = fmt.kind || "";
    const names = fmt.names || {};
    const name = (address) => noted(address, names[String(address).toLowerCase()]);
    if (kind === "units") {
      if (fmt.unlimited && value === UNLIMITED) return "unlimited";
      return noted(`${formatUnits(value, Number(fmt.decimals ?? 18))} ${fmt.symbol || ""}`.trim(), fmt.note);
    }
    if (kind === "bps") return value === 0n && fmt.zero ? fmt.zero : noted(`${Number(value) / 100}%`, fmt.note);
    if (kind === "group") return `${groupLabel(value)} (group ${value})`;
    if (kind === "groups") return value.length ? value.map(groupLabel).join(", ") : "none";
    if (kind === "holders") return value.map((id) => name("0x" + id.toString(16).padStart(40, "0"))).join(", ") || "none";
    if (kind === "duration") return duration(value);
    if (kind === "time") return new Date(Number(value) * 1000).toISOString().replace(".000Z", " UTC").replace("T", " ");
    if (kind === "uuid") { const h = value.slice(2); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; }
    if (kind === "bytes32Address") {
      if (!/^0x0{24}/.test(value)) return noted(value, "not an address");
      return name("0x" + value.slice(26));
    }
    if (kind === "uri") return stickyUri(value) || value;
    if (kind === "claim") {
      const [token, [index, beneficiary, count]] = value;
      return `leaf ${index}, ${fmt.decimals === undefined ? count : formatUnits(count, Number(fmt.decimals))} ${fmt.symbol || "units"} of ${name(token)} to ${/^0x0{24}/.test(beneficiary) ? name("0x" + beneficiary.slice(26)) : beneficiary}`;
    }
    if (type.kind === "bool") return value ? (fmt.yes || "yes") : (fmt.no || "no");
    if (type.kind === "address") return name(value);
    if (type.kind === "array") return value.length ? value.map((item) => formatValue(item, type.of, { names })).join(", ") : (fmt.empty || "none");
    if (type.kind === "string") return value === "" ? (fmt.empty || "none") : value;
    if (type.kind === "bytes") return value === "0x" ? (fmt.empty || "none") : value;
    if (type.kind === "uint") return noted(value.toString(), fmt.note);
    return canon(value);
  }

  // A review row that shows a calldata argument: { param, expect, fmt }. Other rows are prose notes.
  const isBound = (value) => value !== null && typeof value === "object" && typeof value.param === "string";

  // Decodes a planned transaction and renders its review rows from the calldata.
  // Returns { rows, decoded } or throws a CalldataError that the dialog shows and that blocks sending.
  function review(tx) {
    const decoded = decode(tx.data);
    // A plan saved with a descriptive function name shows the decoded function instead.
    let planned = null;
    try { planned = tx.fn ? parseSignature(tx.fn) : null; } catch {}
    if (planned && planned.canonical !== decoded.canonical) fail(`The review says ${planned.canonical} but the calldata calls ${decoded.canonical}.`);
    const params = new Map(decoded.params.map((param) => [param.name, param]));
    const shown = new Set();
    const args = Array.isArray(tx.args) ? tx.args : [];
    const bound = args.some(([, value]) => isBound(value));
    const rows = [];
    if (!bound) {
      // A plan saved before reviews were bound: show every argument as decoded.
      for (const param of decoded.params) rows.push([param.name.replace(/([a-z])([A-Z])/g, "$1 $2").toUpperCase(), formatValue(param.value, param.type)]);
      return { rows, decoded };
    }
    for (const [label, value] of args) {
      if (!isBound(value)) { rows.push([label, value]); continue; }
      const param = params.get(value.param);
      if (!param) fail(`The review shows ${label}, which this function does not take.`);
      if (Object.hasOwn(value, "expect") && !same(param.value, value.expect)) {
        fail(`${label} in the calldata does not match the review. Nothing was sent.`);
      }
      shown.add(param.name);
      rows.push([label, formatValue(param.value, param.type, value.fmt || {})]);
    }
    const hidden = decoded.params.filter((param) => !shown.has(param.name)).map((param) => param.name);
    if (hidden.length) fail(`The review does not show ${hidden.join(", ")}. Nothing was sent.`);
    return { rows, decoded };
  }

  // A row bound to a calldata argument, for builders.
  const arg = (param, expect, fmt) => ({ param, expect: canon(expect), ...(fmt ? { fmt } : {}) });

  return Object.freeze({ ABIS, CalldataError, parseSignature, decode, review, formatValue, arg, isBound, canon, groupLabel });
});
