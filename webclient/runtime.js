/* Shared read-only RPC and asset validation. No wallet methods are sent here. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyRuntime = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const ZERO = /^0x0{40}$/i;
  function address(value) {
    if (typeof value !== "string" || !ADDRESS.test(value) || ZERO.test(value)) throw new Error("A valid deployed contract address is required.");
    return value.toLowerCase();
  }
  function assetUrl(value) {
    if (typeof value !== "string" || value.length > 8192) return null;
    const expanded = value.startsWith("ipfs://") ? "https://ipfs.io/ipfs/" + value.slice(7).replace(/^ipfs\//, "") : value;
    try {
      const url = new URL(expanded);
      if (url.protocol !== "https:" || url.username || url.password) return null;
      return url.href;
    } catch { return null; }
  }
  function deployment(config, chainId) {
    const entry = config.chains?.[String(chainId)] || {};
    const result = {};
    for (const key of ['deployer', 'distributor', 'pockets', 'autoStickAdapter', 'fromBlock']) {
      // Generated globals describe only the default chain. They are not evidence
      // that the same contract exists on an unconfigured destination.
      const fallback = config.defaultChainId === undefined || Number(config.defaultChainId) === Number(chainId) ? config[key] : undefined;
      result[key] = Object.hasOwn(entry, key) ? entry[key] : fallback;
    }
    return { ...entry, ...result };
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
      if (!response.ok) throw new Error(`The chain RPC returned HTTP ${response.status}. Please try again.`);
      const body = await response.json();
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("The chain RPC returned an invalid response.");
      if (body.error) {
        const error = new Error(String(body.error.message || "The chain RPC rejected the request.").slice(0, 500));
        error.code = body.error.code;
        error.data = body.error.data;
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
  async function logs(rpc, filter, options = {}) {
    const end = BigInt(filter.toBlock && filter.toBlock !== "latest" ? filter.toBlock : await rpc("eth_blockNumber", []));
    const start = filter.fromBlock === "earliest" || !filter.fromBlock ? 0n : BigInt(filter.fromBlock);
    if (start > end) return [];
    let requests = 0;
    async function range(from, to) {
      if (++requests > (options.maxRequests || 256)) throw new Error("Project history exceeds the RPC scan limit. Configure the deployment's starting block or an archive RPC.");
      let result;
      try {
        result = await rpc("eth_getLogs", [{ ...filter, fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}` }]);
        if (!Array.isArray(result)) throw new Error("The RPC returned invalid project history.");
      } catch (error) {
        if (from === to || !/range|limit|too (?:many|large)|exceed|response size|query returned|block distance/i.test(error.message)) throw error;
        const middle = (from + to) / 2n;
        return [...await range(from, middle), ...await range(middle + 1n, to)];
      }
      return result;
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
  return { address, assetUrl, deployment, jsonRpc, logs };
});
