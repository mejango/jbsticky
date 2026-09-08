// Relayr prepaid v1. No wallet access: callers own review, durable storage and sending.
// Sticky deployment is permissionless and owns projects itself, so Relayr calls it directly.
(function (root, factory) {
  "use strict";
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyRelayr = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";
  const API = "https://api.relayr.ba5ed.com";
  const PAYMENT_ADDRESS = "0x1c05f7841379d4393574c0ffa17908ec40ffd97d";
  const PAYMENT_SELECTOR = "0x103903a7";
  const PAYMENT_CODE_HASH = "0x6006b5acadb4cd60aa5c00cb844c34563e182dff83d4f4ff4fde226f7df16fa6";
  const NATIVE_TOKEN = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
  const PAYMENT_GAS = "0x249f0"; // 150,000; bounded simulation, no guessed destination gas.
  const DEPLOY_TOPIC = "0xc00d5094bed981d0f08872f495cb40cf20020621153d33b7b379d10c953e59a1";
  const FAMILIES = [[1, 10, 8453, 42161], [11155111, 11155420, 84532, 421614]];
  const NAMES = { 1: "Ethereum", 10: "Optimism", 8453: "Base", 42161: "Arbitrum", 11155111: "Sepolia", 11155420: "Optimism Sepolia", 84532: "Base Sepolia", 421614: "Arbitrum Sepolia" };
  const HEX = /^0x(?:[0-9a-f]{2})*$/i;
  const HASH = /^0x[0-9a-f]{64}$/i;
  const ADDRESS = /^0x[0-9a-f]{40}$/i;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
  const fail = (message) => { throw new Error(message); };
  const object = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : fail("Relayr returned a malformed response.");
  const uuid = (value) => typeof value === "string" && UUID.test(value) ? value.toLowerCase() : fail("Relayr returned an invalid bundle or transaction ID.");
  const address = (value) => typeof value === "string" && ADDRESS.test(value) ? value.toLowerCase() : fail("Invalid contract or account address.");
  function unsigned(value) {
    if (typeof value !== "string" || value.length > 78 || !/^(?:[0-9]+|0x[0-9a-f]+)$/i.test(value)) fail("Invalid unsigned transaction amount.");
    const n = BigInt(value);
    if (n >= 2n ** 256n) fail("Invalid unsigned transaction amount.");
    return n;
  }
  function freeze(value) {
    if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); }
    return value;
  }
  function paymentChains(chainIds) {
    if (!Array.isArray(chainIds) || !chainIds.length || chainIds.some((id) => !Number.isSafeInteger(id))) return [];
    return [...(FAMILIES.find((family) => chainIds.every((id) => family.includes(id))) || [])];
  }
  function entrySnapshot(value) {
    const row = object(value);
    if (!paymentChains([row.chain]).length || typeof row.data !== "string" || !HEX.test(row.data)
      || (row.virtual_nonce !== undefined && (!Number.isSafeInteger(row.virtual_nonce) || row.virtual_nonce < 0))) fail("Invalid Relayr destination request.");
    return { chain: row.chain, target: address(row.target), data: row.data.toLowerCase(), value: unsigned(row.value).toString(),
      ...(row.virtual_nonce !== undefined ? { virtual_nonce: row.virtual_nonce } : {}) };
  }
  function orderedEntries(entries) {
    if (!Array.isArray(entries) || !paymentChains(entries.map((entry) => entry.chain)).length) fail("Choose supported Relayr destinations from one network family.");
    const nonces = new Map();
    return freeze(entries.map((entry) => {
      const nonce = nonces.get(entry.chain) || 0;
      nonces.set(entry.chain, nonce + 1);
      return entrySnapshot({ ...entry, virtual_nonce: nonce });
    }));
  }
  const entryKey = (entry) => JSON.stringify([entry.chain, entry.target, entry.data, entry.value, entry.virtual_nonce]);
  function paymentSnapshots(value) {
    if (!Array.isArray(value)) fail("Relayr returned no payment options.");
    return value.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const row = item;
      if (typeof row.chain !== "number" || typeof row.amount !== "string" || typeof row.calldata !== "string" || typeof row.target !== "string") return [];
      return [{ chain: row.chain, amount: row.amount, calldata: row.calldata, target: row.target,
        ...(typeof row.token === "string" ? { token: row.token } : {}),
        ...(typeof row.payment_deadline === "string" || typeof row.payment_deadline === "number" ? { payment_deadline: row.payment_deadline } : {}) }];
    });
  }
  function unboundSnapshot(value, count) {
    const body = object(value);
    const current = body.tx_uuids;
    const legacy = body.txn_uuids;
    if ((current !== undefined && !Array.isArray(current)) || (legacy !== undefined && !Array.isArray(legacy))) fail("Relayr returned invalid transaction IDs.");
    const ids = current ?? legacy;
    if (!Array.isArray(ids) || ids.length !== count) fail("Relayr did not return every transaction ID.");
    const txUuids = ids.map(uuid);
    if (new Set(txUuids).size !== count) fail("Relayr returned duplicate transaction IDs.");
    if (current && legacy && JSON.stringify(current.map(uuid)) !== JSON.stringify(legacy.map(uuid))) fail("Relayr returned conflicting transaction IDs.");
    return freeze({ bundle_uuid: uuid(body.bundle_uuid), payment_info: paymentSnapshots(body.payment_info), tx_uuids: txUuids });
  }
  function recordsSnapshot(value, bundleUuid) {
    const body = object(value);
    if (uuid(body.bundle_uuid) !== bundleUuid || !Array.isArray(body.transactions)) fail("Relayr status does not match this bundle.");
    const seen = new Set();
    return body.transactions.map((item) => {
      const row = object(item);
      const id = uuid(row.tx_uuid);
      const entry = entrySnapshot(row.request);
      if (seen.has(id) || (row.chain !== undefined && row.chain !== entry.chain)) fail("Relayr returned conflicting transaction records.");
      seen.add(id);
      const record = { tx_uuid: id, request: entry };
      if (row.status !== undefined) {
        const state = object(row.status);
        record.status = {};
        if (typeof state.state === "string") record.status.state = state.state;
        if (state.data && typeof state.data === "object") {
          const data = object(state.data);
          record.status.data = {};
          if (data.hash !== undefined) record.status.data.hash = data.hash;
          if (data.transaction && typeof data.transaction === "object" && data.transaction.hash !== undefined) record.status.data.transaction = { hash: data.transaction.hash };
        }
      }
      return record;
    });
  }
  function deadlineSeconds(value) {
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
    if (typeof value === "string" && /^\d+$/.test(value) && value.length < 17) return BigInt(value);
    const ms = typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(value) ? Date.parse(value) : NaN;
    if (!Number.isFinite(ms) || ms < 0) fail("Relayr returned an invalid payment deadline.");
    return BigInt(Math.floor(ms / 1000));
  }
  function paymentDetails(payment, expectedBundleUuid, options = {}) {
    if (!payment || !paymentChains([payment.chain]).length) fail("Relayr returned an unsupported payment chain.");
    if (!same(payment.target, PAYMENT_ADDRESS)) fail("Relayr returned an unrecognized payment contract.");
    if (!same(payment.token, NATIVE_TOKEN)) fail("Relayr returned an unsupported payment token.");
    const amount = unsigned(payment.amount);
    const bundleUuid = uuid(expectedBundleUuid);
    const calldata = typeof payment.calldata === "string" ? payment.calldata.toLowerCase() : "";
    if (!/^0x[0-9a-f]{136}$/.test(calldata) || calldata.slice(0, 10) !== PAYMENT_SELECTOR) fail("Relayr returned invalid payment calldata.");
    if (calldata.slice(10, 74) !== bundleUuid.replaceAll("-", "") + "0".repeat(32)) fail("Relayr payment calldata does not match this bundle.");
    const deadline = BigInt("0x" + calldata.slice(74));
    if (deadline > 0xffffffffffn || deadlineSeconds(payment.payment_deadline) !== deadline) fail("Relayr payment calldata does not match its deadline.");
    if (!options.allowExpired && deadline <= BigInt(Math.floor(Date.now() / 1000) + 15)) fail("This Relayr quote expired. Keep the saved deployment for recovery.");
    return freeze({ chainId: payment.chain, target: PAYMENT_ADDRESS, amount, calldata, bundleUuid, deadline });
  }
  function paymentOptions(quote, chainIds) {
    // A UUID-only POST response is not sufficient to show a funding picker.
    const bindings = validateBindings(quote);
    const destinations = bindings.map((binding) => binding.chain);
    if (JSON.stringify([...new Set(chainIds)].sort()) !== JSON.stringify([...new Set(destinations)].sort())) fail("Funding destinations differ from the bound quote.");
    const allowed = paymentChains(destinations);
    const offers = new Map(), identities = new Map(), conflicts = new Set();
    for (const payment of paymentSnapshots(quote.payment_info)) {
      let details;
      try { details = paymentDetails(payment, quote.bundle_uuid); } catch { continue; }
      if (!allowed.includes(details.chainId)) continue;
      const identity = `${details.amount}:${details.calldata}`;
      if (identities.has(details.chainId) && identities.get(details.chainId) !== identity) conflicts.add(details.chainId);
      identities.set(details.chainId, identity);
      offers.set(details.chainId, freeze(payment));
    }
    return [...offers].filter(([chain]) => !conflicts.has(chain)).map(([, payment]) => payment);
  }
  function paymentLabel(payment) {
    const n = unsigned(payment.amount);
    const whole = n / 10n ** 18n;
    const fraction = (n % 10n ** 18n).toString().padStart(18, "0").replace(/0+$/, "");
    return `${NAMES[payment.chain] || `Chain ${payment.chain}`} — ${whole}${fraction ? "." + fraction : ""} ETH`;
  }
  function destinationHash(record) {
    const direct = record.status?.data?.hash;
    const nested = record.status?.data?.transaction?.hash;
    if (direct !== undefined && (typeof direct !== "string" || !HASH.test(direct))) return null;
    if (nested !== undefined && (typeof nested !== "string" || !HASH.test(nested))) return null;
    if (direct && nested && !same(direct, nested)) return null;
    return (direct ?? nested)?.toLowerCase() || null;
  }
  function validateBindings(quote) {
    uuid(quote.bundle_uuid);
    if (!Array.isArray(quote.expectedTransactions) || !quote.expectedTransactions.length) fail("This Relayr bundle lacks authenticated destination requests.");
    const ids = new Set(), keys = new Set();
    const result = quote.expectedTransactions.map((binding) => {
      const entry = entrySnapshot(binding.entry);
      const id = uuid(binding.txUuid);
      const key = entryKey(entry);
      if (binding.chain !== entry.chain || ids.has(id) || keys.has(key)) fail("This Relayr bundle has conflicting destination requests.");
      ids.add(id); keys.add(key);
      return { txUuid: id, chain: entry.chain, entry };
    });
    const ordered = orderedEntries(result.map((binding) => binding.entry));
    if (ordered.some((entry, i) => entryKey(entry) !== entryKey(result[i].entry))) fail("This Relayr bundle has invalid virtual nonces.");
    return result;
  }

  // Keccak-256, Ethereum's original padding (not SHA3-256). Small fixed-input runtime checks.
  const MASK = (1n << 64n) - 1n;
  const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
  const RC = [1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n, 0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800an, 0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n];
  const rotate = (x, n) => n ? ((x << BigInt(n)) | (x >> BigInt(64 - n))) & MASK : x;
  function keccak256(hex) {
    if (typeof hex !== "string" || !HEX.test(hex)) fail("Invalid bytes for runtime verification.");
    const input = Uint8Array.from(hex.slice(2).match(/../g) || [], (byte) => parseInt(byte, 16));
    const padded = new Uint8Array(Math.ceil((input.length + 1) / 136) * 136);
    padded.set(input); padded[input.length] = 1; padded[padded.length - 1] |= 128;
    const a = Array(25).fill(0n);
    for (let offset = 0; offset < padded.length; offset += 136) {
      for (let i = 0; i < 136; i++) a[Math.floor(i / 8)] ^= BigInt(padded[offset + i]) << BigInt((i % 8) * 8);
      for (const rc of RC) {
        const c = Array(5).fill(0n), d = [], b = Array(25).fill(0n);
        for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) c[x] ^= a[x + 5 * y];
        for (let x = 0; x < 5; x++) d[x] = c[(x + 4) % 5] ^ rotate(c[(x + 1) % 5], 1);
        for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) a[x + 5 * y] ^= d[x];
        for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(a[x + 5 * y], ROT[x + 5 * y]);
        for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) a[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]);
        a[0] ^= rc;
      }
    }
    let result = "0x";
    for (let i = 0; i < 32; i++) result += Number((a[Math.floor(i / 8)] >> BigInt((i % 8) * 8)) & 255n).toString(16).padStart(2, "0");
    return result;
  }
  const CREATE_EVENT = keccak256("0x" + Array.from(new TextEncoder().encode("Create(uint256,address,address)"), (byte) => byte.toString(16).padStart(2, "0")).join(""));
  function abiAddress(word) {
    if (typeof word !== "string" || !/^0{24}[0-9a-f]{40}$/i.test(word)) fail("Receipt contains an invalid ABI address.");
    return "0x" + word.slice(24).toLowerCase();
  }
  function createClient(options = {}) {
    const fetcher = options.fetch || globalThis.fetch;
    const rpc = options.rpc;
    const safe = options.safe || globalThis.StickyTxSafe || (typeof module === "object" && module.exports ? require("./tx-safe.js") : null);
    if (typeof fetcher !== "function" || typeof rpc !== "function") fail("Relayr requires fetch and a chain-specific RPC reader.");
    async function request(path, init = {}) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), init.method === "POST" ? 45000 : 15000);
      try {
        const response = await fetcher(API + path, { ...init, signal: controller.signal, cache: "no-store", credentials: "omit", redirect: "error" });
        if (!response.ok) fail(`Relayr HTTP ${response.status}. Keep the saved deployment for recovery.`);
        return await response.json();
      } catch (error) {
        if (controller.signal.aborted) fail("Relayr did not respond in time. Published requests must not be submitted again.");
        throw error;
      } finally { clearTimeout(timer); }
    }
    async function bindQuote(unbound, entries) {
      const ordered = orderedEntries(entries);
      if (unbound?.expectedTransactions !== undefined) {
        const bindings = validateBindings(unbound);
        if (bindings.length !== ordered.length || bindings.some((binding, i) => entryKey(binding.entry) !== entryKey(ordered[i]))) fail("The saved Relayr quote differs from the frozen deployment.");
        return freeze({ bundle_uuid: uuid(unbound.bundle_uuid), payment_info: paymentSnapshots(unbound.payment_info), expectedTransactions: bindings });
      }
      const snapshot = unboundSnapshot(unbound, ordered.length);
      const records = recordsSnapshot(await request(`/v1/bundle/${snapshot.bundle_uuid}`), snapshot.bundle_uuid);
      if (records.length !== ordered.length) fail("Relayr has not returned every quoted request. Resume this saved bundle to check again.");
      const ids = new Set(snapshot.tx_uuids), byRequest = new Map();
      for (const record of records) {
        const key = entryKey(record.request);
        if (!ids.has(record.tx_uuid) || byRequest.has(key)) fail("Relayr did not uniquely bind every quoted request.");
        byRequest.set(key, record);
      }
      const expectedTransactions = ordered.map((entry) => {
        const match = byRequest.get(entryKey(entry));
        if (!match) fail("Relayr's quoted request differs from the saved deployment.");
        return { txUuid: match.tx_uuid, chain: entry.chain, entry };
      });
      return freeze({ bundle_uuid: snapshot.bundle_uuid, payment_info: snapshot.payment_info, transactions: records, expectedTransactions });
    }
    async function postBundle(entries, callbacks) {
      if (typeof callbacks?.beforePublish !== "function" || typeof callbacks?.onPublished !== "function") fail("Save deployment publication before contacting Relayr.");
      const ordered = orderedEntries(entries);
      await callbacks.beforePublish(ordered);
      const body = await request("/v1/bundle/prepaid", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ transactions: ordered, virtual_nonce_mode: "ChainIndependent" }) });
      // Preserve a known bundle ID even if the rest of the POST response is malformed.
      // A failed parse must never turn an already published deployment into a fresh POST.
      const published = object(body);
      const known = freeze({ bundle_uuid: uuid(published.bundle_uuid), payment_info: published.payment_info ?? [],
        tx_uuids: published.tx_uuids ?? published.txn_uuids ?? [],
        ...(published.txn_uuids !== undefined ? { txn_uuids: published.txn_uuids } : {}) });
      await callbacks.onPublished(known);
      const quote = unboundSnapshot(known, ordered.length);
      return bindQuote(quote, ordered);
    }
    async function fetchStatus(quote) {
      const expected = new Map(validateBindings(quote).map((binding) => [binding.txUuid, entryKey(binding.entry)]));
      const records = recordsSnapshot(await request(`/v1/bundle/${uuid(quote.bundle_uuid)}`), uuid(quote.bundle_uuid));
      for (const record of records) if (expected.get(record.tx_uuid) !== entryKey(record.request)) fail("Relayr status differs from the authenticated deployment requests.");
      return freeze(records);
    }
    async function checkChain(chain) {
      if (unsigned(await rpc(chain, "eth_chainId", [])) !== BigInt(chain)) fail("RPC returned the wrong chain.");
    }
    async function validatePayment(payment, bundleUuid, from) {
      const details = paymentDetails(payment, bundleUuid);
      const sender = address(from);
      await checkChain(details.chainId);
      const code = await rpc(details.chainId, "eth_getCode", [PAYMENT_ADDRESS, "latest"]);
      if (typeof code !== "string" || !HEX.test(code) || code === "0x" || code.length > 4098 || keccak256(code) !== PAYMENT_CODE_HASH) fail("The Relayr payment contract does not match its verified runtime.");
      const transaction = { from: sender, to: details.target, value: "0x" + details.amount.toString(16), data: details.calldata, gas: PAYMENT_GAS };
      if (await rpc(details.chainId, "eth_call", [transaction, "latest"]) !== "0x") fail("Relayr payment simulation returned unexpected data.");
      paymentDetails(payment, bundleUuid); // A quote can expire during RPC checks.
      return details;
    }
    async function canonicalTransaction(chain, hash) {
      if (typeof hash !== "string" || !HASH.test(hash)) fail("Invalid transaction hash.");
      await checkChain(chain);
      const [tx, receipt] = await Promise.all([rpc(chain, "eth_getTransactionByHash", [hash]), rpc(chain, "eth_getTransactionReceipt", [hash])]);
      if (!tx || !receipt || tx.blockHash === null || receipt.blockHash === null) return null;
      if (!same(tx.hash, hash) || !same(receipt.transactionHash, hash) || unsigned(tx.chainId) !== BigInt(chain)
        || !HASH.test(receipt.blockHash) || !same(tx.blockHash, receipt.blockHash) || unsigned(tx.blockNumber) !== unsigned(receipt.blockNumber)
        || !same(tx.from, receipt.from) || !same(tx.to, receipt.to) || unsigned(tx.transactionIndex) !== unsigned(receipt.transactionIndex)) fail("The transaction is not in its canonical chain.");
      const block = await rpc(chain, "eth_getBlockByNumber", [receipt.blockNumber, false]);
      if (!block || !same(block.hash, receipt.blockHash) || unsigned(block.number) !== unsigned(receipt.blockNumber)
        || !Array.isArray(block.transactions) || !same(block.transactions[Number(unsigned(receipt.transactionIndex))], hash)) fail("The transaction is not in its canonical block.");
      if (receipt.status !== "0x1" && receipt.status !== "0x0") fail("The transaction receipt has an invalid status.");
      return { tx, receipt };
    }
    async function isFinalized(chain, receipt) {
      try {
        const finalized = await rpc(chain, "eth_getBlockByNumber", ["finalized", false]);
        if (!finalized || !HASH.test(finalized.hash) || unsigned(finalized.number) < unsigned(receipt.blockNumber)) return false;
        const block = await rpc(chain, "eth_getBlockByNumber", [finalized.number, false]);
        const included = await rpc(chain, "eth_getBlockByNumber", [receipt.blockNumber, false]);
        return !!block && !!included && same(block.hash, finalized.hash) && same(included.hash, receipt.blockHash);
      } catch { return false; }
    }
    function safeOutcome(evidence, expected) {
      if (!safe?.inspectSafeOutcome) return null;
      const outcome = safe.inspectSafeOutcome(evidence.tx, evidence.receipt, expected);
      if (!outcome) return null;
      for (const log of evidence.receipt.logs) {
        if (!same(log.address, expected.from)) continue;
        if (log.removed || !same(log.transactionHash, evidence.tx.hash) || !same(log.blockHash, evidence.receipt.blockHash)
          || unsigned(log.blockNumber) !== unsigned(evidence.receipt.blockNumber)) fail("The Safe execution log is not canonical.");
      }
      return outcome;
    }
    async function verifyPayment(hash, payment, bundleUuid, from, options = {}) {
      const details = paymentDetails(payment, bundleUuid, { allowExpired: true });
      const sender = address(from);
      const evidence = await canonicalTransaction(details.chainId, hash);
      if (!evidence) return { status: "pending" };
      const { tx, receipt } = evidence;
      const direct = same(tx.from, sender) && same(tx.to, details.target) && same(tx.input, details.calldata) && unsigned(tx.value) === details.amount;
      const wrapped = direct ? null : safeOutcome(evidence, { from: sender, to: details.target, data: details.calldata, value: details.amount,
        ...(options.safeTxHash !== undefined ? { safeTxHash: options.safeTxHash } : {}) });
      if (!direct && !wrapped) fail("The transaction does not match the saved Relayr payment.");
      // A reverted Safe wrapper leaves its signed proposal executable. An unbound
      // inner failure could belong to another proposal with the same payment call.
      if (wrapped === "failure" && (receipt.status === "0x0" || options.safeTxHash === undefined)) return { status: "unresolved", hash: hash.toLowerCase() };
      if (receipt.status === "0x0" || wrapped === "failure") return { status: "reverted", hash: hash.toLowerCase(), finalized: await isFinalized(details.chainId, receipt) };
      return { status: "confirmed", hash: hash.toLowerCase() };
    }
    async function verifyDeployment(hash, requestEntry, expected) {
      const entry = entrySnapshot(requestEntry);
      const projects = address(expected.projects), controller = address(expected.controller);
      const token = address(expected.stakedToken), tax = unsigned(String(expected.cashOutTaxRate));
      if (typeof expected.soulbound !== "boolean" || tax > 10000n || entry.data.slice(0, 10) !== "0x00d5ce37" || entry.data.length < 458) fail("Invalid saved Sticky deployment configuration.");
      const args = entry.data.slice(10);
      if (!same(abiAddress(args.slice(0, 64)), token) || BigInt("0x" + args.slice(256, 320)) !== tax
        || BigInt("0x" + args.slice(384, 448)) !== (expected.soulbound ? 1n : 0n)) fail("Sticky deployment calldata differs from the saved configuration.");
      const evidence = await canonicalTransaction(entry.chain, hash);
      if (!evidence) return { status: "pending" };
      const { tx, receipt } = evidence;
      const direct = same(tx.to, entry.target) && same(tx.input, entry.data) && unsigned(tx.value) === unsigned(entry.value)
        && (expected.from === undefined || same(tx.from, address(expected.from)));
      const wrapped = !direct && expected.from !== undefined ? safeOutcome(evidence, { from: address(expected.from), to: entry.target, data: entry.data, value: entry.value,
        ...(expected.safeTxHash !== undefined ? { safeTxHash: expected.safeTxHash } : {}) }) : null;
      if (!direct && !wrapped) fail("The transaction does not match the saved Sticky deployment.");
      if (wrapped === "failure" && (receipt.status === "0x0" || expected.safeTxHash === undefined)) return { status: "unresolved", hash: hash.toLowerCase() };
      if (receipt.status === "0x0" || wrapped === "failure") return { status: "reverted", hash: hash.toLowerCase(), finalized: await isFinalized(entry.chain, receipt) };
      const deployCaller = wrapped ? address(expected.from) : tx.from;
      if (!Array.isArray(receipt.logs)) fail("The Sticky deployment receipt has no logs.");
      const logs = receipt.logs.filter((log) => same(log.address, entry.target) && same(log.topics?.[0], DEPLOY_TOPIC));
      if (logs.length !== 1) fail("The receipt does not identify exactly one Sticky deployment.");
      const deployed = logs[0];
      function validateLog(log) {
        if (log.removed || !same(log.transactionHash, hash) || !same(log.blockHash, receipt.blockHash) || unsigned(log.blockNumber) !== unsigned(receipt.blockNumber)) fail("The deployment log is not canonical.");
      }
      validateLog(deployed);
      if (deployed.topics.length !== 3 || !HASH.test(deployed.topics[1]) || !HASH.test(deployed.topics[2]) || !/^0x[0-9a-f]{256}$/i.test(deployed.data)) fail("The Sticky deployment event is malformed.");
      const projectId = BigInt(deployed.topics[1]);
      const data = deployed.data.slice(2);
      const deployedToken = abiAddress(data.slice(0, 64));
      if (!projectId || deployedToken === "0x" + "0".repeat(40) || !same(abiAddress(deployed.topics[2].slice(2)), token)
        || BigInt("0x" + data.slice(64, 128)) !== tax || BigInt("0x" + data.slice(128, 192)) !== (expected.soulbound ? 1n : 0n)
        || !same(abiAddress(data.slice(192, 256)), deployCaller)) fail("The Sticky deployment event differs from its exact configuration.");
      const creations = receipt.logs.filter((log) => same(log.address, projects) && same(log.topics?.[0], CREATE_EVENT));
      if (creations.length !== 1) fail("The receipt does not prove canonical project creation.");
      const created = creations[0];
      validateLog(created);
      if (created.topics.length !== 3 || !HASH.test(created.topics[1]) || BigInt(created.topics[1]) !== projectId
        || !same(abiAddress(created.topics[2].slice(2)), entry.target) || !/^0x[0-9a-f]{64}$/i.test(created.data)
        || !same(abiAddress(created.data.slice(2)), controller)) fail("The project creation event differs from the Sticky deployment.");
      return { status: "confirmed", hash: hash.toLowerCase(), projectId: projectId.toString(), token: deployedToken };
    }
    return Object.freeze({ postBundle, bindQuote, fetchStatus, validatePayment, verifyPayment, verifyDeployment,
      orderedEntries, paymentChains, paymentOptions, paymentDetails, paymentLabel, destinationHash });
  }
  return Object.freeze({ createClient, orderedEntries, paymentChains, paymentOptions, paymentDetails, paymentLabel, destinationHash, keccak256,
    PAYMENT_ADDRESS, PAYMENT_SELECTOR, PAYMENT_CODE_HASH, PAYMENT_GAS, NATIVE_TOKEN, DEPLOY_TOPIC, CREATE_TOPIC: CREATE_EVENT });
});
