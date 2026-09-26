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
      if (++requests > limit) throw new Error(`This history spans ${end - start + 1n} blocks, more than this RPC can scan in ${limit} requests.`);
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
      await Promise.all(Array.from({ length: Math.min(options.concurrency || 8, parts.length) }, worker));
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
  // Bendystraw, the Juicebox indexer, answers discovery and history. It is a cache: every caller keeps a chain
  // read for when it errors, times out or lags, and money (backing, supply, quotes) is never read from it.
  // `url` is serve.py's same-origin relay, which forwards only the persisted operations in
  // bendystraw-operations.json. The page sends an operation's id, the SHA-256 of its document, and its
  // variables; a document missing from that file is refused, locally as in production.
  const operationIds = new Map();
  function operationId(query) {
    if (!operationIds.has(query)) {
      operationIds.set(query, globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(query))
        .then((digest) => [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")));
    }
    return operationIds.get(query);
  }
  async function graphql(url, query, variables = {}, options = {}) {
    const fetcher = options.fetch || globalThis.fetch;
    if (!url || typeof url !== "string") throw new Error("No Bendystraw endpoint is configured.");
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeout || 6000);
    try {
      const operation = await operationId(query);
      const response = await fetcher(url, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ operation, variables }),
        signal: controller.signal, cache: "no-store", credentials: "omit", redirect: "error",
      });
      let body;
      try { body = await response.json(); } catch { body = null; }
      if (typeof body?.error === "string") {
        const message = body.error.slice(0, 300);
        throw new Error(message.startsWith("Bendystraw") ? message : `Bendystraw: ${message}`);
      }
      if (!response.ok || !body || typeof body !== "object") throw new Error(`Bendystraw returned HTTP ${response.status}.`);
      if (!body.data || typeof body.data !== "object") throw new Error("Bendystraw returned no data.");
      return body.data;
    } catch (error) {
      if (controller.signal.aborted) throw new Error("Bendystraw timed out.");
      throw error;
    } finally { clearTimeout(timer); }
  }
  // Every item of one list field, following its cursor. A list longer than the page cap is an error, not a
  // silent truncation.
  async function graphqlItems(url, field, query, variables, options = {}) {
    const items = [];
    let after = null;
    for (let page = 0; page < (options.maxPages || 20); page++) {
      const data = await graphql(url, query, { ...variables, after }, options);
      const list = data[field];
      if (!list || !Array.isArray(list.items)) throw new Error(`Bendystraw returned no ${field}.`);
      items.push(...list.items);
      if (!list.pageInfo?.hasNextPage) return { items, data };
      after = list.pageInfo.endCursor;
    }
    throw new Error(`Bendystraw has more ${field} than one page load reads.`);
  }

  const INDEX_QUERY = `query StickyIndex($owners: [String!], $after: String) {
    _meta { status }
    projects(where: { owner_in: $owners }, limit: 1000, after: $after) {
      items { chainId projectId version owner metadataUri createdAt }
      pageInfo { hasNextPage endCursor }
    }
  }`;
  // Sticky projects per chain, keyed by chain ID, with the block Bendystraw has indexed each chain through.
  // `deployers` maps chain ID to that chain's StickyDeployer, which owns every project it launches. A chain
  // missing from Bendystraw's status is left out, so its caller scans that chain instead.
  async function stickyIndex(url, deployers, options = {}) {
    const wanted = new Map(Object.entries(deployers).filter(([, deployer]) => ADDRESS.test(deployer || ""))
      .map(([chainId, deployer]) => [Number(chainId), deployer.toLowerCase()]));
    if (!wanted.size) return new Map();
    const owners = [...new Set(wanted.values())];
    const { items, data } = await graphqlItems(url, "projects", INDEX_QUERY, { owners }, options);
    const status = data._meta?.status;
    if (!status || typeof status !== "object") throw new Error("Bendystraw returned no indexing status.");
    const chains = new Map();
    for (const entry of Object.values(status)) {
      const chainId = Number(entry?.id);
      const block = entry?.block?.number;
      if (!wanted.has(chainId) || !Number.isSafeInteger(block) || block < 0) continue;
      chains.set(chainId, { block: BigInt(block), timestamp: Number(entry.block.timestamp) || 0, projects: [] });
    }
    for (const row of items) {
      const chainId = Number(row?.chainId);
      const chain = chains.get(chainId);
      if (!chain || String(row.owner || "").toLowerCase() !== wanted.get(chainId)) continue;
      if (!Number.isSafeInteger(row.projectId) || row.projectId <= 0) continue;
      chain.projects.push({
        projectId: BigInt(row.projectId), version: Number(row.version),
        metadataUri: typeof row.metadataUri === "string" ? row.metadataUri : null, createdAt: Number(row.createdAt) || 0,
      });
    }
    for (const chain of chains.values()) chain.projects.sort((a, b) => (a.projectId < b.projectId ? -1 : 1));
    return chains;
  }

  const PAY_QUERY = `query StickyPays($where: payEventFilter, $after: String) {
    payEvents(where: $where, orderBy: "timestamp", orderDirection: "asc", limit: 1000, after: $after) {
      items { chainId projectId version txHash logIndex timestamp caller beneficiary amount newlyIssuedTokenCount }
      pageInfo { hasNextPage endCursor }
    }
  }`;
  const CASH_OUT_QUERY = `query StickyCashOuts($where: cashOutTokensEventFilter, $after: String) {
    cashOutTokensEvents(where: $where, orderBy: "timestamp", orderDirection: "asc", limit: 1000, after: $after) {
      items { chainId projectId version txHash logIndex timestamp caller holder beneficiary cashOutCount reclaimAmount }
      pageInfo { hasNextPage endCursor }
    }
  }`;
  const bigint = (value) => { try { return BigInt(value); } catch { return null; } };
  // Sticks (pays) and unsticks (cash outs) of the given projects, oldest first. `projects` is a list of
  // { chainId, projectId, version }. Pays and cash outs are what change a Sticky token's supply.
  async function stickyEvents(url, projects, options = {}) {
    if (!projects.length) return [];
    const groups = new Map();
    for (const project of projects) {
      const key = `${project.chainId}:${project.version}`;
      if (!groups.has(key)) groups.set(key, { chainId: Number(project.chainId), version: Number(project.version), projectId_in: [] });
      groups.get(key).projectId_in.push(Number(project.projectId));
    }
    // One filter per chain and version: Bendystraw ignores an OR filter and would return every project's events.
    const lists = await Promise.all([...groups.values()].flatMap((where) => [
      graphqlItems(url, "payEvents", PAY_QUERY, { where }, options).then(({ items }) => items.map((row) => ({ row, kind: "stick" }))),
      graphqlItems(url, "cashOutTokensEvents", CASH_OUT_QUERY, { where }, options).then(({ items }) => items.map((row) => ({ row, kind: "unstick" }))),
    ]));
    const asked = new Set(projects.map((project) => `${Number(project.chainId)}:${Number(project.version)}:${Number(project.projectId)}`));
    const rows = lists.flat().filter(({ row }) => asked.has(`${Number(row?.chainId)}:${Number(row?.version)}:${Number(row?.projectId)}`));
    const common = (row) => ({
      chainId: Number(row.chainId), projectId: bigint(row.projectId), ts: Number(row.timestamp),
      txHash: String(row.txHash || ""), logIndex: Number(row.logIndex) || 0,
    });
    const events = rows.map(({ row, kind }) => (kind === "stick"
      ? { ...common(row), kind, payer: String(row.caller || "").toLowerCase(), holder: String(row.beneficiary || "").toLowerCase(),
        amount: bigint(row.amount), tokens: bigint(row.newlyIssuedTokenCount) }
      : { ...common(row), kind, holder: String(row.holder || "").toLowerCase(), tokens: bigint(row.cashOutCount), amount: bigint(row.reclaimAmount) }));
    if (events.some((event) => event.projectId === null || event.tokens === null || event.amount === null || !ADDRESS.test(event.holder) || !Number.isFinite(event.ts))) {
      throw new Error("Bendystraw returned an incomplete Sticky event.");
    }
    return events.sort((a, b) => a.ts - b.ts || a.logIndex - b.logIndex);
  }

  const CREATE_QUERY = `query StickyCreate($where: projectCreateEventFilter) {
    projectCreateEvents(where: $where, limit: 5) { items { txHash timestamp } }
  }`;
  // The transaction that created one project, for its creation block. Null when Bendystraw has none.
  async function projectCreateTx(url, chainId, projectId, version, options = {}) {
    const data = await graphql(url, CREATE_QUERY, { where: { chainId: Number(chainId), projectId: Number(projectId), version: Number(version) } }, options);
    const items = data.projectCreateEvents?.items;
    if (!Array.isArray(items)) throw new Error("Bendystraw returned no project creation.");
    return items.length === 1 && /^0x[0-9a-fA-F]{64}$/.test(items[0].txHash || "") ? items[0].txHash : null;
  }

  return { address, assetUrl, deployment, withoutFixtures, jsonRpc, logs, statedRange, graphql, stickyIndex, stickyEvents, projectCreateTx };
});
