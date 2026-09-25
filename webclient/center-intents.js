/* Juicebox Center launch listings (project intents). No wallet access: callers sign. */
(function (root, factory) {
  const api = factory(root);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyCenter = api;
})(typeof globalThis === "object" ? globalThis : this, function (root) {
  "use strict";
  const DEFAULT_URL = "https://juicebox.center";
  const FORMAT = "sticky.center/deploy.v1";
  // The V6 ERC-2771 forwarder, the same on all 8 chains. Center sponsors only calls it forwards.
  const FORWARDER = "0x3bA60b60933916a7C87D0860DcEE62a0CE34E3e2";
  const IS_TRUSTED_FORWARDER = "0x572b6c05";
  // Center's sponsor policy: every testnet, and every mainnet except Ethereum.
  const SPONSORED_CHAINS = Object.freeze([10, 8453, 42161, 11155111, 11155420, 84532, 421614]);
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const HASH = /^0x[0-9a-f]{64}$/;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const SIGNATURE = /^0x(?:[0-9a-fA-F]{128}|[0-9a-fA-F]{130})$/;

  class CenterError extends Error {
    constructor(status, code, message) { super(message); this.name = "CenterError"; this.status = status; this.code = code; }
  }

  function canonicalJson(value) {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  // Center checksums addresses and lowercases calldata; compare hex without case.
  function lowerHex(value) {
    if (typeof value === "string") return /^0x[0-9a-fA-F]*$/.test(value) ? value.toLowerCase() : value;
    if (Array.isArray(value)) return value.map(lowerHex);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, lowerHex(item)]));
    return value;
  }
  const utf8Hex = (text) => "0x" + Array.from(new TextEncoder().encode(text), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const signingMessage = (hash) => `Juice Central project intent\nVersion: 1\nContent hash: ${hash}`;

  // One launch call per chain, sent as is. Center drops `value`; the creation fee is not signed.
  function buildEnvelope({ calls, owner, name, symbol, stakedToken, stakedTokenSymbol, cashOutTaxRate, soulbound, launchId, projectUri }) {
    if (!Array.isArray(calls) || !calls.length) throw new Error("A listing needs at least one launch call.");
    if (!ADDRESS.test(owner || "")) throw new Error("A listing needs the launching wallet.");
    const sorted = [...calls].sort((a, b) => a.chainId - b.chainId);
    const chainIds = sorted.map((call) => call.chainId);
    if (new Set(chainIds).size !== chainIds.length) throw new Error("A listing has one launch per chain.");
    // A JSON copy: what is compared and hashed later is exactly what is sent.
    return JSON.parse(JSON.stringify({
      format: FORMAT,
      deploymentVersion: "6",
      chainIds,
      deploymentCalls: sorted.map(({ chainId, to, data }) => ({ chainId, to, data: data.toLowerCase() })),
      jb: { app: "sticky", kind: "sticky", name, owner, chainIds, symbol, stakedToken, stakedTokenSymbol,
        cashOutTaxRate: String(cashOutTaxRate), soulbound, launchId, projectUri },
    }));
  }

  // Sponsored only when Center sponsors every chain and StickyDeployer trusts the forwarder on each.
  async function sponsoredPlan({ chainIds, isTrusted }) {
    if (!chainIds.length || chainIds.some((chainId) => !SPONSORED_CHAINS.includes(chainId))) return false;
    const trusted = await Promise.all(chainIds.map((chainId) => Promise.resolve().then(() => isTrusted(chainId)).catch(() => false)));
    return trusted.every((value) => value === true);
  }

  function createClient(options = {}) {
    const fetcher = options.fetch || root.fetch?.bind(root);
    const keccak256 = options.keccak256 || root.StickyRelayr?.keccak256
      || (typeof module === "object" && module.exports ? require("./relayr.js").keccak256 : null);
    const api = (options.apiUrl || DEFAULT_URL).replace(/\/+$/, "");
    if (typeof fetcher !== "function" || typeof keccak256 !== "function") throw new Error("Juicebox Center needs fetch and keccak256.");
    async function request(path, init = {}) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 20000);
      let response;
      try {
        response = await fetcher(api + path, { ...init, signal: controller.signal, cache: "no-store", credentials: "omit", redirect: "error",
          headers: init.body ? { "content-type": "application/json" } : {} });
      } catch {
        // An origin Center doesn't allow gets a 403 without CORS headers, which reads as a network error.
        throw new CenterError(0, "unreachable", "Juicebox Center could not be reached.");
      } finally { clearTimeout(timer); }
      let body = null;
      try { body = await response.json(); } catch {}
      if (!response.ok) {
        const code = typeof body?.error?.code === "string" ? body.error.code : "http_error";
        const message = typeof body?.error?.message === "string" ? body.error.message : `HTTP ${response.status}`;
        throw new CenterError(response.status, code, message);
      }
      return body;
    }
    const post = (path, body) => request(path, { method: "POST", body: JSON.stringify(body) });
    const intentPath = (id) => {
      if (!UUID.test(id || "")) throw new CenterError(0, "bad_intent", "The saved listing ID is invalid.");
      return `/v1/intents/${id.toLowerCase()}`;
    };

    // Center returns the message to sign. Sign only if it names exactly this envelope.
    async function prepare(envelope) {
      const body = await post("/v1/intents/message", envelope);
      if (!body || typeof body.message !== "string" || !body.envelope || typeof body.envelope !== "object") {
        throw new CenterError(0, "malformed", "Juicebox Center returned a malformed listing.");
      }
      if (canonicalJson(lowerHex(body.envelope)) !== canonicalJson(lowerHex(envelope))) {
        throw new CenterError(0, "mismatch", "Juicebox Center changed the listing. Nothing was signed.");
      }
      const contentHash = keccak256(utf8Hex(canonicalJson(body.envelope)));
      if (body.contentHash?.toLowerCase?.() !== contentHash || body.message !== signingMessage(contentHash)) {
        throw new CenterError(0, "mismatch", "Juicebox Center's message does not match the listing. Nothing was signed.");
      }
      return { envelope: body.envelope, message: body.message, contentHash };
    }
    async function publish(prepared, publisher, signature) {
      if (!ADDRESS.test(publisher || "") || !SIGNATURE.test(signature || "")) throw new CenterError(0, "bad_signature", "The wallet returned an invalid signature.");
      const intent = await post("/v1/intents", { ...prepared.envelope, publisher, signature });
      if (!UUID.test(intent?.id || "") || intent.contentHash?.toLowerCase?.() !== prepared.contentHash) {
        throw new CenterError(0, "malformed", "Juicebox Center returned a different listing.");
      }
      return intent;
    }
    const get = async (id) => request(intentPath(id));
    // Center waits for 2 confirmations; earlier posts come back 422 and are retried later.
    async function record(id, { chainId, projectId, transactionHash }) {
      if (!HASH.test(String(transactionHash).toLowerCase())) throw new CenterError(0, "bad_hash", "Invalid deployment transaction hash.");
      try {
        await post(`${intentPath(id)}/deployments`, { chainId, projectId: String(projectId), transactionHash: transactionHash.toLowerCase() });
        return { status: "recorded" };
      } catch (error) {
        if (error.status === 422 && /confirmation/i.test(error.message)) return { status: "wait" };
        throw error;
      }
    }
    const requestDeploy = async (id, chainIds) => post(`${intentPath(id)}/deploy`, { chainIds });
    return Object.freeze({ prepare, publish, get, record, requestDeploy, apiUrl: api });
  }

  return Object.freeze({ DEFAULT_URL, FORMAT, FORWARDER, IS_TRUSTED_FORWARDER, SPONSORED_CHAINS, CenterError,
    canonicalJson, lowerHex, utf8Hex, signingMessage, buildEnvelope, sponsoredPlan, createClient });
});
