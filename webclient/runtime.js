/* Shared read-only RPC and asset validation. No wallet methods are sent here. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyRuntime = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const ZERO = /^0x0{40}$/i;
  // Juicebox Center's gateway, the one the other Juicebox sites use. ipfs.io and dweb.link are sunset.
  const IPFS_GATEWAY = "https://juicebox.center/ipfs/";
  function address(value) {
    if (typeof value !== "string" || !ADDRESS.test(value) || ZERO.test(value)) throw new Error("A valid deployed contract address is required.");
    return value.toLowerCase();
  }
  function assetUrl(value, allowLocal = false) {
    if (typeof value !== "string" || value.length > 8192) return null;
    if (allowLocal && /^(?:\.\/)?[a-zA-Z0-9][a-zA-Z0-9._-]*\.(?:png|jpe?g|webp|gif|avif)$/i.test(value)) return value;
    const expanded = value.startsWith("ipfs://") ? IPFS_GATEWAY + value.slice(7).replace(/^ipfs\//, "") : value;
    try {
      const url = new URL(expanded);
      if (url.protocol !== "https:" || url.username || url.password) return null;
      return url.href;
    } catch { return null; }
  }
  function deployment(config, chainId) {
    const entry = config.chains?.[String(chainId)] || {};
    const result = {};
    for (const key of ['deployer', 'distributor', 'rewardReceiverFactory', 'autoStickAdapter', 'fromBlock']) {
      // Generated globals describe only the default chain. They are not evidence
      // that the same contract exists on an unconfigured destination.
      const fallback = config.defaultChainId === undefined || Number(config.defaultChainId) === Number(chainId) ? config[key] : undefined;
      result[key] = Object.hasOwn(entry, key) ? entry[key] : fallback;
    }
    return { ...entry, ...result };
  }
  // Fixtures belong to the explicit demo and a local-mode loopback config. A live page never shows them.
  const FIXTURES = ["demoHomeStickiest", "demoHomeAirdrops", "demoChartHistory", "usdPriceOverrides", "logoOverrides", "projectNameOverrides", "projectChainOverrides"];
  function withoutFixtures(config, hostname) {
    const local = config.localMode === true && ["localhost", "127.0.0.1", "[::1]"].includes(hostname);
    if (config.demoMode === true || local) return config;
    const result = { ...config };
    for (const key of FIXTURES) delete result[key];
    return result;
  }
  async function jsonRpc(url, method, params, options = {}) {
    const fetcher = options.fetch || globalThis.fetch;
    if (!url || typeof url !== "string") throw new Error("No RPC is configured for this chain.");
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeout || 20000);
    try {
      const response = await fetcher(url, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: controller.signal, cache: "no-store", credentials: "omit", redirect: "error",
      });
      // Some providers answer a JSON-RPC error with a non-2xx status (base.org: HTTP 413 for a log range
      // over its limit). Read the body first so callers see the node's own error, like a range limit.
      let body;
      try { body = await response.json(); } catch { body = null; }
      if (!response.ok && !body?.error) {
        const error = new Error(`The chain RPC returned HTTP ${response.status}. Please try again.`);
        error.status = response.status;
        throw error;
      }
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("The chain RPC returned an invalid response.");
      if (body.error) {
        const error = new Error(String(body.error.message || "The chain RPC rejected the request.").slice(0, 500));
        error.code = body.error.code;
        error.data = body.error.data;
        if (!response.ok) error.status = response.status;
        throw error;
      }
      if (!Object.hasOwn(body, "result")) throw new Error("The chain RPC returned no result.");
      return body.result;
    } catch (error) {
      if (controller.signal.aborted) throw new Error("The chain RPC timed out. Please try again.");
      throw error;
    } finally { clearTimeout(timer); }
  }
  // Nodes impose different log range/result limits. Split only rejected ranges and never
  // report a partial response as complete. Deployment fromBlock keeps the scan bounded.
  const RANGE_ERROR = /range|limit|too (?:many|large)|exceed|response size|query returned|block distance/i;
  // The largest block span a node names in its error, like "eth_getLogs is limited to a 1,000 range".
  function statedRange(message) {
    const match = /(?:limit(?:ed)?|max(?:imum)?|exceeds?|up to)[^0-9]{0,40}([0-9][0-9,_]*)\s*(?:-?block)?/i.exec(String(message || ""));
    const span = match ? BigInt(match[1].replace(/[,_]/g, "")) : 0n;
    return span >= 10n && span <= 10_000_000n ? span : 0n;
  }
  async function logs(rpc, filter, options = {}) {
    const end = BigInt(filter.toBlock && filter.toBlock !== "latest" ? filter.toBlock : await rpc("eth_blockNumber", []));
    const start = filter.fromBlock === "earliest" || !filter.fromBlock ? 0n : BigInt(filter.fromBlock);
    if (start > end) return [];
    let requests = 0;
    const limit = options.maxRequests || 1024;
    async function fetchRange(from, to) {
      if (++requests > limit) throw new Error("Project history exceeds the RPC scan limit. Configure the deployment's starting block or an RPC with a larger log range.");
      const result = await rpc("eth_getLogs", [{ ...filter, fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}` }]);
      if (!Array.isArray(result)) throw new Error("The RPC returned invalid project history.");
      return result;
    }
    // Fixed-size windows run a few at a time; results keep block order.
    async function windows(from, to, span) {
      const parts = [];
      for (let low = from; low <= to; low += span) parts.push([low, low + span - 1n < to ? low + span - 1n : to]);
      const out = new Array(parts.length);
      let next = 0;
      const worker = async () => { while (next < parts.length) { const i = next++; out[i] = await range(parts[i][0], parts[i][1]); } };
      await Promise.all(Array.from({ length: Math.min(options.concurrency || 4, parts.length) }, worker));
      return out.flat();
    }
    async function range(from, to) {
      try {
        return await fetchRange(from, to);
      } catch (error) {
        const tooLarge = error.status === 413 || RANGE_ERROR.test(error.message);
        if (from === to || !tooLarge) throw error;
        // Chunk straight to the span the node names; otherwise halve.
        const span = statedRange(error.message);
        if (span && span < to - from + 1n) return windows(from, to, span);
        const middle = (from + to) / 2n;
        return [...await range(from, middle), ...await range(middle + 1n, to)];
      }
    }
    const result = await range(start, end);
    const seen = new Set();
    return result.filter(log => {
      if (log.removed) return false;
      if (typeof log.blockNumber !== "string" || typeof log.logIndex !== "string" || typeof log.transactionHash !== "string") throw new Error("The RPC returned an incomplete project event.");
      const key = `${log.blockHash}:${log.transactionHash}:${log.logIndex}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }).sort((a, b) => {
      const block = BigInt(a.blockNumber) - BigInt(b.blockNumber);
      return block < 0n ? -1 : block > 0n ? 1 : Number(BigInt(a.logIndex) - BigInt(b.logIndex));
    });
  }
  return { address, assetUrl, deployment, withoutFixtures, jsonRpc, logs, statedRange };
});
