// Sticky webclient. Raw JSON-RPC, no dependencies, no build step.
// Hash-routed: #/ is the homepage; #/project/<id> is a sticky token's overview, with
// /tokens and /airdrops child routes for its other tabs.
// Wallet writes are reviewed and journaled; multichain launches use Relayr prepaid bundles.
"use strict";

// Function selectors, precomputed with `cast sig`.
const SEL = {
  HOOK: "0xa54eb242",
  CONTROLLER: "0xee0fc121",
  TOKENS: "0x1d831d5c",
  TERMINAL: "0x160668af",
  PROJECTS: "0x293c4999",
  count: "0x06661abd",
  creationFee: "0xdce0b4e4",
  stakedTokenOf: "0xdbced5db",
  deployStickyFor: "0x00d5ce37",
  SOULBOUND: "0x32a9ba68",
  setTrustedSenderFor: "0x3a799596",
  isTrustedSenderOf: "0x5d0bc3bb",
  cashOutTaxRateOf: "0x7aac1c6f",
  STORE: "0x507f1465",
  storeBalanceOf: "0x467f4cb9",
  orphanedBalanceOf: "0x325fcad5",
  tranchesOf: "0x8cc1b370",
  trancheCountOf: "0x56dbba3b",
  tranchesRangeOf: "0xc964d0f3",
  stakedBalanceOf: "0x7bd208b2",
  streakStartOf: "0xac609038",
  longestStreakOf: "0x62a82139",
  decimals: "0x313ce567",
  symbol: "0x95d89b41",
  name: "0x06fdde03",
  balanceOf: "0x70a08231",
  allowance: "0xdd62ed3e",
  approve: "0x095ea7b3",
  totalSupply: "0x18160ddd",
  tokenOf: "0xea78803f",
  projectIdOf: "0x0f85421b",
  uriOf: "0xa312889b",
  pay: "0xfef43257",
  previewPayFor: "0x0aff0c31",
  cashOutTokensOf: "0x13da8317",
  mint: "0x40c10f19",
  fund: "0x77531866",
  beginVesting: "0x83d96f8f",
  collectVestedRewards: "0x4d355ce6",
  collectableFor: "0x5710be41",
  nextClaimRoundOf: "0x5fef1a8a",
  rewardRoundOf: "0xc45c9bf6",
  isValidGroupId: "0x0468459c",
  snapshotEpochOf: "0x09ff1c3f",
  currentRound: "0x8a19c8bc",
  ROUND_DURATION: "0x6641ea08",
  VESTING_ROUNDS: "0xaf29da14",
  STARTING_TIMESTAMP: "0x20e9fcd4",
  claimedFor: "0x51e0706c",
  latestVestedIndexOf: "0x4d5bf2a8",
  vestingDataOf: "0xa50ae7da",
  getPastVotes: "0x3a46b1a8",
  previewCashOutFrom: "0x4aa71dbc",
  feeFreeSurplusOf: "0xc66d192b",
  FEELESS_ADDRESSES: "0x659a2047",
  isFeelessFor: "0x8717d7c2",
  stakedBalanceThroughEpochOf: "0x0fdcc877",
  DISTRIBUTOR: "0x9c26149f",
  predictReceiverOf: "0x330b5eea",
  settleFor: "0xa4b4e8bf",
  ensReverseWithGateways: "0xb7d6ca64",
  handleOf: "0xd9b0da2d",
  ownerOf: "0x6352211e",
  isGranterOf: "0xb9f2a2ba",
  asConfigOf: "0x7f1a9379",
  asStatusOf: "0x7d33ed0f",
  asSetConfigFor: "0x415174c8",
  asCompoundFor: "0x8244fb99",
  asStickRewardsFor: "0x40b5a05d",
  asBeginVestingFor: "0xa15557e8",
};
// Event topics, precomputed with `cast keccak`.
const TOPIC = {
  DeploySticky: "0xc00d5094bed981d0f08872f495cb40cf20020621153d33b7b379d10c953e59a1",
  Staked: "0xd6d3230e3db876114bd3eea9c8a9b54a70c8263b762d4086170e2089e4506aa9",
  Unstaked: "0x169f9c267fbc671daf3188c40c7ac44f00fbd8d51133fe23364b771c207297cc",
  StreakStarted: "0xbf35648fc2c3b2611046bd0e40788ec1f1ccec09ab1d1188dd0ce73b8683009d",
  StreakEnded: "0x633ff8e26572566ae370cee18c8b3c0a5370f533bb490764ab6586c0a404e4ea",
  SetGranter: "0xb1493c7092cfd1c7e27c08ccd5e2f65f3408075032bdcc2983702abb376f9521",
  SetTrustedSender: "0x19cb6ea1a683846f033314fc7883a280ffee4abf9e75f0c699a947575f182e69",
  Transfer: "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
  Fund: "0x171d1972970e548ead487a3a60cfbdfffd130a21513e44dfcd8778965935ddf2",
};

// ---------------------------------------------------------------- abi codec
const strip = (h) => h.replace(/^0x/, "");
const word = (v) => {
  const value = BigInt(v);
  if (value < 0n || value >= 2n ** 256n) throw new Error("Value is outside the uint256 range.");
  return value.toString(16).padStart(64, "0");
};
const encAddress = (a) => {
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error("Invalid address.");
  return strip(a).toLowerCase().padStart(64, "0");
};
const encBytesTail = (bytes) => {
  const len = word(bytes.length);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return len + hex.padEnd(Math.ceil(bytes.length / 32) * 64, "0");
};

// Encode arguments for the given types. Supports uint256, address, string, bytes.
function encode(types, values) {
  const head = [];
  const tail = [];
  let tailOffset = types.length * 32;
  for (let i = 0; i < types.length; i++) {
    const t = types[i];
    const v = values[i];
    if (t === "uint256" || t === "bool") head.push(word(t === "bool" ? (v ? 1 : 0) : v));
    else if (t === "address") head.push(encAddress(v));
    else if (t === "address[]" || t === "uint256[]") {
      const chunk = word(v.length) + v.map(t === "address[]" ? encAddress : word).join("");
      head.push(word(tailOffset));
      tail.push(chunk);
      tailOffset += chunk.length / 2;
    } else {
      const bytes = t === "string" ? new TextEncoder().encode(v) : hexToBytes(v);
      const chunk = encBytesTail(bytes);
      head.push(word(tailOffset));
      tail.push(chunk);
      tailOffset += chunk.length / 2;
    }
  }
  return head.join("") + tail.join("");
}

function hexToBytes(hex) {
  const h = strip(hex);
  if (!/^(?:[0-9a-fA-F]{2})*$/.test(h)) throw new Error("Invalid hexadecimal bytes.");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}

const decUint = (hex, i = 0) => {
  const value = strip(hex).slice(i * 64, i * 64 + 64);
  if (!Number.isSafeInteger(i) || i < 0 || !/^[0-9a-fA-F]{64}$/.test(value)) throw new Error("Contract returned an invalid ABI word.");
  return BigInt("0x" + value);
};
const decAddress = (hex, i = 0) => {
  const value = decUint(hex, i);
  if (value >= 2n ** 160n) throw new Error("Contract returned an invalid address.");
  return "0x" + value.toString(16).padStart(40, "0");
};
function decString(hex) {
  const h = strip(hex);
  if (h.length === 64) return new TextDecoder().decode(hexToBytes(h)).replace(/\0+$/, "");
  const offset = Number(decUint(h, 0)) * 2;
  if (!Number.isSafeInteger(offset) || offset < 64 || offset % 64 || offset + 64 > h.length) throw new Error("Contract returned an invalid string offset.");
  const len = Number(decUint(h, offset / 64));
  if (!Number.isSafeInteger(len) || len < 0 || len > 1048576 || offset + 64 + len * 2 > h.length) throw new Error("Contract returned an invalid string length.");
  return new TextDecoder().decode(hexToBytes(h.slice(offset + 64, offset + 64 + len * 2)));
}
// StickyTranche[]: offset word, length word, then (amount, timestamp) per tranche.
function decTranches(hex) {
  const h = strip(hex);
  const offset = Number(decUint(h, 0)) / 32;
  const len = Number(decUint(h, offset));
  if (!Number.isSafeInteger(offset) || offset < 1 || !Number.isSafeInteger(len) || len < 0 || (offset + 1 + len * 2) * 64 > h.length) throw new Error("Contract returned an invalid tranche list.");
  const out = [];
  for (let i = 0; i < len; i++) {
    out.push({ amount: decUint(h, offset + 1 + i * 2), timestamp: Number(decUint(h, offset + 2 + i * 2)) });
  }
  return out;
}

// ------------------------------------------------------------- rpc plumbing
const $ = (id) => document.getElementById(id);
let walletAccount = null; // set when a browser wallet or a Signa account is connected
let walletKind = null; // "injected" (a browser wallet signs) or "signa" (an address for reads only)
const account = () => viewAs ?? walletAccount ?? $("account").value;
function localTransactionMode(tx) {
  const loopback = (hostname) => ["localhost", "127.0.0.1", "[::1]"].includes(hostname);
  if (window.STICKY_CONFIG?.localMode !== true || !loopback(location.hostname) || window.__DEMO_RPC) return false;
  try { return loopback(new URL(tx?.rpcUrl || $("rpc").value).hostname); } catch { return false; }
}
function txAccount() {
  if (viewAs) throw new Error("Exit account preview before sending a transaction.");
  // Signa's review covers only Base USDC pays today; no Sticky action is one of them.
  if (walletKind === "signa") throw needsExternalWallet();
  if (window.__DEMO_RPC) throw new Error("The demo is read only. Connect to a live Sticky deployment to transact.");
  const address = walletAccount || (localTransactionMode() ? $("account").value : null);
  if (!/^0x[0-9a-fA-F]{40}$/.test(address || "")) throw new Error("Connect a wallet before sending a transaction.");
  return address;
}

// Give the reflected half real document space so it moves exactly with the page. Set the normal fold
// once after loading; unlike the earlier attempt, nothing snaps or rewrites scrolling afterward.
const TOP_FOLD_HEIGHT = 50;
const foldWalletControl = document.querySelector("header .right");
// Own the initial scroll so mobile browsers don't restore 0 after load and leave the whole logo
// below the fold — we want its lower half flush with the top, like desktop.
if ("scrollRestoration" in history) history.scrollRestoration = "manual";
function syncTopFoldControls() {
  foldWalletControl.classList.toggle("top-fold-fixed", window.scrollY < TOP_FOLD_HEIGHT);
}
function setInitialTopFold() {
  if (window.scrollY < TOP_FOLD_HEIGHT) window.scrollTo(0, TOP_FOLD_HEIGHT);
  syncTopFoldControls();
}
window.addEventListener("scroll", syncTopFoldControls, { passive: true });
syncTopFoldControls();
requestAnimationFrame(setInitialTopFold);
window.addEventListener("load", () => requestAnimationFrame(setInitialTopFold), { once: true });
// Mobile: catch the post-load scroll reset and the address-bar height settling.
window.addEventListener("pageshow", () => requestAnimationFrame(setInitialTopFold));
setTimeout(setInitialTopFold, 150);

async function rpc(method, params) {
  if (window.__DEMO_RPC) return window.__DEMO_RPC(method, params);
  return StickyRuntime.jsonRpc($("rpc").value, method, params);
}

// Match Juicescan's ENS behavior: reverse-resolve every account against Ethereum mainnet's Universal Resolver,
// independently of the production chain the sticky project lives on. Results (including misses) are cached per address.
// Testnet pages skip ENS and handles: mainnet names don't describe testnet accounts or projects.
const ensAvailable = () => chainById(ctx.chainId)?.environment !== "testnet";
const ENS_RPC_URL = window.STICKY_CONFIG?.ensRpc || "https://ethereum-rpc.publicnode.com";
const ENS_UNIVERSAL_RESOLVER = "0xeeeeeeee14d718c2b47d9923deab1335e144eeee";
const ensNameCache = new Map();

async function ensRpc(method, params) {
  return StickyRuntime.jsonRpc(ENS_RPC_URL, method, params);
}

function ensReverseData(address) {
  // reverseWithGateways(bytes,uint256,string[]): address bytes, ETH coin type (60), no custom gateways.
  return SEL.ensReverseWithGateways
    + word(96) + word(60) + word(160)
    + word(20) + strip(address).padEnd(64, "0")
    + word(0);
}

function reverseEns(address) {
  const key = String(address || "").toLowerCase();
  if (!ensAvailable() || !/^0x[0-9a-f]{40}$/.test(key)) return Promise.resolve(null);
  if (!ensNameCache.has(key)) {
    ensNameCache.set(key, (async () => {
      try {
        const result = await ensRpc("eth_call", [{
          to: ENS_UNIVERSAL_RESOLVER,
          data: ensReverseData(key),
        }, "latest"]);
        return result && result !== "0x" ? (decString(result) || null) : null;
      } catch {
        return null;
      }
    })());
  }
  return ensNameCache.get(key);
}

// JBProjectHandles lives on Ethereum and re-checks the ENS `juicebox` text record inside
// handleOf, so a non-empty answer is already proof the name names this exact project.
const JB_PROJECT_HANDLES = "0x726f4a3dfd2fb8297f8ab98d215b42a92d8eefe8";
const projectHandleCache = new Map();
const handleRouteCache = new Map();

function verifiedHandleOf(projectId) {
  if (!ensAvailable()) return Promise.resolve(null);
  const key = `${ctx.chainId}:${projectId}`;
  if (!projectHandleCache.has(key)) {
    projectHandleCache.set(key, (async () => {
      try {
        const projects = decAddress(await view(ctx.controller, SEL.PROJECTS));
        // ponytail: the owner is the setter for every sticky project today. Read the
        // revnet operator here too if a sticky token is ever launched on one.
        const owner = decAddress(await view(projects, SEL.ownerOf, word(projectId)));
        const result = await ensRpc("eth_call", [{
          to: JB_PROJECT_HANDLES,
          data: SEL.handleOf + word(ctx.chainId) + word(projectId) + word(owner),
        }, "latest"]);
        return result && result !== "0x" ? (decString(result) || null) : null;
      } catch {
        return null;
      }
    })());
  }
  return projectHandleCache.get(key);
}

// @handle -> the sticky token of the project that published it. Only this deployer's projects
// are considered, which is the whole question being asked: a project without a sticky token has
// nothing to route to.
async function projectIdForHandle(handle) {
  const wanted = String(handle || "").replace(/^@/, "").replace(/\.eth$/i, "").toLowerCase();
  if (!wanted) return null;
  // Only a match is remembered, so a handle published after this page loaded still resolves.
  if (handleRouteCache.has(wanted)) return handleRouteCache.get(wanted);
  const ids = await projectIds();
  // ponytail: one cached mainnet read per sticky token. Swap in a forward ENS text lookup
  // (which needs a local namehash, so keccak) once the list outgrows one screen.
  const handles = await Promise.all(ids.map(verifiedHandleOf));
  const index = handles.findIndex((name) => (name || "").toLowerCase() === wanted);
  if (index === -1) return null;
  handleRouteCache.set(wanted, ids[index]);
  return ids[index];
}

const call = async (to, data) => rpc("eth_call", [{ to, data }, "latest"]);
const view = (to, sel, args = "") => call(to, sel + args);
const fromBlock = () => StickyRuntime.deployment(window.STICKY_CONFIG || {}, ctx.chainId).fromBlock ?? "earliest";
// `from` is the block a scan starts at: a project's creation block for that project's history.
const getLogs = (address, topics, from = fromBlock()) => window.__DEMO_RPC
  ? rpc("eth_getLogs", [{ address, topics, fromBlock: fromBlock(), toBlock: "latest" }])
  : StickyRuntime.logs(rpc, { address, topics, fromBlock: from, toBlock: "latest" });

const blockTimestamps = {};
async function blockTimestamp(blockNumber, reader = null) {
  const cache = reader?.timestamps || blockTimestamps;
  if (!(blockNumber in cache)) {
    cache[blockNumber] = (reader?.rpc || rpc)("eth_getBlockByNumber", [blockNumber, false]).then((block) => Number(BigInt(block.timestamp)));
    cache[blockNumber].catch(() => delete cache[blockNumber]);
  }
  return cache[blockNumber];
}
// Timestamps for many logs, one read per distinct block, a few at a time.
async function attachTimestamps(logs, concurrency = 6, reader = null) {
  const blocks = [...new Set(logs.map((log) => log.blockNumber))];
  let next = 0;
  const worker = async () => { while (next < blocks.length) await blockTimestamp(blocks[next++], reader); };
  await Promise.all(Array.from({ length: Math.min(concurrency, blocks.length) }, worker));
  for (const log of logs) log.ts = await blockTimestamp(log.blockNumber, reader);
  return logs;
}

async function ensureWalletChain(chainId) {
  if (!activeProvider) throw new Error("connect a wallet to switch networks");
  const hexChainId = `0x${Number(chainId).toString(16)}`;
  const current = Number(BigInt(await activeProvider.request({ method: "eth_chainId" })));
  if (current === Number(chainId)) return;
  try {
    await activeProvider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexChainId }] });
  } catch (error) {
    if (error?.code !== 4902) throw error;
    const chain = chainById(chainId);
    if (!chain) throw new Error(`wallet does not know chain ${chainId}`);
    await activeProvider.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId: hexChainId,
        chainName: chain.name,
        nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
        rpcUrls: [stickyDeploymentFor(chainId).rpcUrl || chain.rpcUrl],
        blockExplorerUrls: [chain.explorer],
      }],
    });
  }
  const switched = Number(BigInt(await activeProvider.request({ method: "eth_chainId" })));
  if (switched !== Number(chainId)) throw new Error(`switch your wallet to ${chainById(chainId)?.name || chainId}`);
}

let txEngine = null;
function getTxEngine() {
  if (!txEngine) {
    if (!window.StickyTx) throw new Error("Transaction recovery could not be loaded. Reload before sending.");
    txEngine = window.StickyTx.createEngine({
      storage: window.localStorage,
      locks: navigator.locks,
      wallet: () => walletAccount && walletKind === "injected" ? activeProvider : null,
      ensureChain: ensureWalletChain,
      localMode: localTransactionMode,
      authorize: (tx) => {
        if (txAccount().toLowerCase() !== tx.from.toLowerCase()) throw new Error("Connect the account shown in the transaction review.");
      },
      rpc: (tx, method, params) => rpcAt(tx.rpcUrl, method, params),
      onUpdate: (session) => {
        confirmSession = session;
        renderTxRecovery(session);
        if ($("confirm-dialog").open && session) renderConfirmSteps();
      },
    });
  }
  return txEngine;
}

// Standalone callers use the same durable review path as every transaction sequence.
async function sendTx(tx) {
  const plan = [{ label: "Transaction", args: [], ...tx }];
  if (!(await confirmAndRun(tx.label || "Confirm transaction", plan))) return null;
  return plan[0].receipt;
}

// ---------------------------------------------------------------- formatting
function formatUnits(v, decimals, dp = 4) {
  const base = 10n ** BigInt(decimals);
  const whole = v / base;
  const frac = ((v % base) * 10n ** BigInt(dp)) / base;
  const fracStr = frac.toString().padStart(dp, "0").replace(/0+$/, "");
  return fracStr ? `${whole}.${fracStr}` : whole.toString();
}
function parseUnits(str, decimals) {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 255) throw new Error("invalid token decimals");
  const input = String(str).trim();
  if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(input)) throw new Error(`bad amount: ${str}`);
  const [whole, frac = ""] = input.split(".");
  if (frac.length > decimals) throw new Error(`this token supports at most ${decimals} decimal places`);
  const amount = BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0") || "0");
  if (amount >= 1n << 256n) throw new Error("amount is too large");
  return amount;
}
function formatDuration(seconds) {
  const s = Number(seconds);
  if (s === 0) return "0";
  const d = Math.floor(s / 86_400);
  const h = Math.floor((s % 86_400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m ${s % 60}s`;
}
function tokenLogo(addr, symbol, size = 15, chainId = null) {
  const chain = chainId ? ` data-chain="${Number(chainId)}"` : "";
  return `<span data-token-logo="${addr}" data-size="${size}"${chain} style="display:inline-flex;flex:none">${tokenBadge(addr, symbol, size)}</span>`;
}

function tokenBadge(addr, symbol, size) {
  const hue = Number(BigInt(addr) % 360n);
  const letter = (symbol || "?").slice(0, 1).toUpperCase();
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}"><rect width="24" height="24" rx="6" fill="hsl(${hue} 45% 42%)"/>` +
    `<text x="12" y="16.4" font-size="12" font-weight="700" fill="#f0f7f9" text-anchor="middle" font-family="ui-monospace,Menlo,monospace">${esc(letter)}</text></svg>`;
}
const ipfsUrl = (uri) => StickyRuntime.assetUrl(uri);
const logoCache = {}; // token addr -> url | null | pending promise
const projectMetadataCache = {}; // project token addr -> metadata | null | pending promise

async function resolveProjectMetadata(addr, reader = pageReader()) {
  const key = `${reader.chainId}:${addr.toLowerCase()}`;
  if (key in projectMetadataCache) return projectMetadataCache[key];
  const view = (to, sel, args = "") => reader.rpc("eth_call", [{ to, data: sel + args }, "latest"]);
  return (projectMetadataCache[key] = (async () => {
    try {
      const projectId = decUint(await view(reader.tokens, SEL.projectIdOf, encAddress(addr)));
      if (projectId === 0n) return null;
      const uri = decString(await view(reader.controller, SEL.uriOf, word(projectId)));
      if (!uri) return null;
      const inline = parseStickyProjectUri(uri);
      if (inline) return inline;
      const url = ipfsUrl(uri);
      if (!url) return null;
      const response = await fetch(url, { signal: AbortSignal.timeout(10000), credentials: "omit", referrerPolicy: "no-referrer" });
      if (!response.ok) return null;
      const metadata = await response.json();
      return metadata && typeof metadata === "object" && !Array.isArray(metadata) ? metadata : null;
    } catch {
      return null;
    }
  })());
}

async function resolveTokenLogoUrl(addr, reader = pageReader()) {
  const override = window.STICKY_CONFIG?.logoOverrides?.[addr.toLowerCase()];
  if (override) return StickyRuntime.assetUrl(override, true);
  const key = `${reader.chainId}:${addr.toLowerCase()}`;
  if (key in logoCache) return logoCache[key];
  return (logoCache[key] = (async () => {
    const metadata = await resolveProjectMetadata(addr, reader);
    return metadata?.logoUri ? ipfsUrl(metadata.logoUri) : null;
  })());
}

function parseStickyProjectUri(uri) {
  if (!uri?.startsWith("data:application/json")) return null;
  try {
    const comma = uri.indexOf(",");
    if (comma < 0) return null;
    const payload = uri.slice(comma + 1);
    const json = uri.slice(0, comma).includes(";base64") ? atob(payload) : decodeURIComponent(payload);
    return JSON.parse(json);
  } catch {
    return null;
  }
}

async function projectChainIds(projectId) {
  const override = window.STICKY_CONFIG?.projectChainOverrides?.[String(projectId)];
  if (Array.isArray(override) && override.length) return override.map(Number).filter(chainById);
  try {
    const uri = decString(await view(ctx.controller, SEL.uriOf, word(projectId)));
    const metadata = parseStickyProjectUri(uri);
    const chains = metadata?.protocol === "Sticky" ? metadata.chains : null;
    if (Array.isArray(chains) && chains.length) return chains.map(Number).filter(chainById);
  } catch {}
  return ctx.chainId ? [ctx.chainId] : [];
}

// ------------------------------------------------------------ sibling chains
// A multichain launch gets a different project ID on each chain, but every chain's projectUri carries the
// same launchId. Siblings are found from each same-environment chain's own DeploySticky events, scanned from
// that chain's deployment block, and kept only when the uri's launchId, the cash out tax and the transfer
// mode all match. Results are cached for the session; the other environment's chains are never scanned.
const chainRuntimeCache = new Map();
function chainRuntime(chainId) {
  const key = Number(chainId);
  if (!chainRuntimeCache.has(key)) {
    const pending = (async () => {
      const deployment = stickyDeploymentFor(key);
      if (!deployment.rpcUrl || !/^0x[0-9a-fA-F]{40}$/.test(deployment.deployer || "")) throw new Error("Sticky is not configured on this chain");
      const [hook, terminal, controller, tokens] = await Promise.all([SEL.HOOK, SEL.TERMINAL, SEL.CONTROLLER, SEL.TOKENS]
        .map((selector) => viewAt(deployment, deployment.deployer, selector).then(decAddress)));
      const store = decAddress(await viewAt(deployment, terminal, SEL.STORE));
      return { ...deployment, chainId: key, hook, terminal, controller, tokens, store };
    })();
    pending.catch(() => chainRuntimeCache.delete(key));
    chainRuntimeCache.set(key, pending);
  }
  return chainRuntimeCache.get(key);
}

// Reads bound to one chain. The home page reads every chain of its environment through these. In demo
// mode every read goes through the page's rpc(), which serves the one demo chain.
function pageReader() {
  return {
    chainId: ctx.chainId, rpc, deployer: $("deployer").value, hook: ctx.hook, tokens: ctx.tokens, terminal: ctx.terminal,
    store: ctx.store, controller: ctx.controller, fromBlock: fromBlock(), projects: ctx.projects, timestamps: blockTimestamps,
  };
}
const chainReaderCache = new Map();
function chainReader(chainId) {
  if (window.__DEMO_RPC) return Promise.resolve(pageReader());
  const key = Number(chainId);
  if (!chainReaderCache.has(key)) {
    const pending = chainRuntime(key).then((runtime) => ({
      ...runtime, rpc: (method, params) => rpcAt(runtime.rpcUrl, method, params), projects: {}, timestamps: {},
    }));
    pending.catch(() => chainReaderCache.delete(key));
    chainReaderCache.set(key, pending);
  }
  return chainReaderCache.get(key);
}
const getLogsOn = (reader, address, topics, from = reader.fromBlock) => window.__DEMO_RPC
  ? reader.rpc("eth_getLogs", [{ address, topics, fromBlock: reader.fromBlock, toBlock: "latest" }])
  : StickyRuntime.logs(reader.rpc, { address, topics, fromBlock: from, toBlock: "latest" });

// ----------------------------------------------------------------- bendystraw
// Bendystraw, the Juicebox indexer, lists each environment's Sticky projects and their sticks and unsticks,
// so a page does not scan a chain's whole history. It is a cache: a chain it has not indexed, or any
// Bendystraw error, falls back to chain reads, and backing, supply and quotes always come from the chain.
// The page reaches it through serve.py's same-origin relay, which forwards only the persisted operations in
// bendystraw-operations.json: Bendystraw's CORS list does not include this site.
const bendystrawUrl = (chainId) => {
  const network = chainById(chainId)?.environment === "testnet" ? "testnet" : "mainnet";
  const upstream = window.STICKY_CONFIG?.[network === "testnet" ? "testnetBendystrawUrl" : "bendystrawUrl"];
  return upstream ? new URL(`/api/bendystraw/${network}/query`, location.href).href : null;
};
const INDEX_TTL = 60_000;
const indexCache = new Map();
function stickyIndexFor(chainId) {
  const environment = chainById(chainId)?.environment;
  const cached = indexCache.get(environment);
  if (cached && Date.now() - cached.at < INDEX_TTL) return cached.pending;
  const deployers = Object.fromEntries(chainsForEnvironment(environment)
    .map((chain) => [chain.chainId, stickyDeploymentFor(chain.chainId).deployer]).filter(([, deployer]) => deployer));
  const pending = StickyRuntime.stickyIndex(bendystrawUrl(chainId), deployers);
  pending.catch((error) => {
    console.warn("Bendystraw is unavailable; reading chains directly.", error);
    if (indexCache.get(environment)?.pending === pending) indexCache.delete(environment);
  });
  indexCache.set(environment, { at: Date.now(), pending });
  return pending;
}
// This chain's entry in the index, or null when Bendystraw fails or does not index the chain.
async function indexedChain(chainId) {
  if (window.__DEMO_RPC) return null;
  try {
    return (await stickyIndexFor(chainId)).get(Number(chainId)) || null;
  } catch {
    return null;
  }
}

// Every Sticky launch on a chain, oldest first. Bendystraw lists them and a scan from the block it has indexed
// through adds launches it has not reached yet. Without Bendystraw the chain is scanned from the deployment
// block. Scanned launches carry their cash out tax, transfer mode and creation block from DeploySticky.
const deployedCache = new Map();
function deployedProjectsOn(chainId) {
  const key = Number(chainId);
  const cached = deployedCache.get(key);
  if (cached && Date.now() - cached.at < INDEX_TTL) return cached.pending;
  const pending = (async () => {
    const runtime = await chainRuntime(key);
    const indexed = await indexedChain(key);
    const first = runtime.fromBlock === "earliest" || runtime.fromBlock === undefined ? 0n : BigInt(runtime.fromBlock);
    const from = indexed && indexed.block + 1n > first ? `0x${(indexed.block + 1n).toString(16)}` : runtime.fromBlock;
    const logs = await StickyRuntime.logs((method, params) => rpcAt(runtime.rpcUrl, method, params),
      { address: runtime.deployer, topics: [TOPIC.DeploySticky], fromBlock: from, toBlock: "latest" });
    const scanned = logs.map((log) => ({
      projectId: decUint(log.topics[1]), tax: decUint(log.data, 1), soulbound: decUint(log.data, 2) === 1n, startBlock: log.blockNumber,
    }));
    for (const project of scanned) rememberStartBlock(key, project.projectId, project.startBlock);
    if (!indexed) return scanned;
    // Bendystraw's uri narrows sibling candidates; without one the launch id is unknown and read onchain.
    const listed = indexed.projects.map((project) => {
      const launchId = parseStickyProjectUri(project.metadataUri)?.launchId;
      return { projectId: project.projectId, version: project.version, launchId: typeof launchId === "string" ? launchId : undefined };
    });
    return [...listed, ...scanned.filter((project) => !listed.some((row) => row.projectId === project.projectId))];
  })();
  pending.catch(() => { if (deployedCache.get(key)?.pending === pending) deployedCache.delete(key); });
  deployedCache.set(key, { at: Date.now(), pending });
  return pending;
}

// The block a project was created in. A scan of one project's history starts there, not at the deployment's
// first block. Bendystraw names the creating transaction, and its receipt, which must carry this deployer's
// DeploySticky for the project, gives the block. Otherwise a binary search on JBProjects.count() at past
// blocks finds it, and failing that the deployment's first block is used. Kept for the session.
const startBlockCache = new Map();
function rememberStartBlock(chainId, projectId, block) {
  startBlockCache.set(`${Number(chainId)}:${BigInt(projectId)}`, Promise.resolve(block));
}
function projectStartBlock(chainId, projectId) {
  const key = `${Number(chainId)}:${BigInt(projectId)}`;
  const deployment = stickyDeploymentFor(chainId);
  const fallback = deployment.fromBlock ?? "earliest";
  if (window.__DEMO_RPC) return Promise.resolve(fallback);
  if (!startBlockCache.has(key)) {
    const pending = (async () => {
      try {
        return await createdBlockFromIndex(deployment, BigInt(projectId));
      } catch (error) {
        console.warn(`Could not find project ${projectId}'s creation from Bendystraw.`, error);
      }
      try {
        return await createdBlockFromCount(deployment, BigInt(projectId));
      } catch (error) {
        console.warn(`Could not find project ${projectId}'s creation block onchain.`, error);
      }
      return null;
    })();
    startBlockCache.set(key, pending);
    // A failed lookup is not remembered, so the next view tries again.
    pending.then((block) => { if (block === null && startBlockCache.get(key) === pending) startBlockCache.delete(key); });
  }
  return startBlockCache.get(key).then((block) => block ?? fallback);
}
async function createdBlockFromIndex(deployment, projectId) {
  const indexed = await indexedChain(deployment.chainId);
  const version = indexed?.projects.find((project) => project.projectId === projectId)?.version ?? 6;
  const tx = await StickyRuntime.projectCreateTx(bendystrawUrl(deployment.chainId), deployment.chainId, projectId, version);
  if (!tx) throw new Error("Bendystraw has no creation for this project.");
  const receipt = await rpcAt(deployment.rpcUrl, "eth_getTransactionReceipt", [tx]);
  const deployed = Array.isArray(receipt?.logs) && receipt.logs.some((log) => !log.removed
    && String(log.address).toLowerCase() === String(deployment.deployer).toLowerCase()
    && log.topics?.[0] === TOPIC.DeploySticky && decUint(log.topics[1]) === projectId);
  if (!deployed || !/^0x[0-9a-fA-F]+$/.test(receipt.blockNumber || "")) throw new Error("The creation transaction did not launch this project.");
  return receipt.blockNumber;
}
async function createdBlockFromCount(deployment, projectId) {
  const read = (method, params) => rpcAt(deployment.rpcUrl, method, params);
  const controller = decAddress(await viewAt(deployment, deployment.deployer, SEL.CONTROLLER));
  const projects = decAddress(await viewAt(deployment, controller, SEL.PROJECTS));
  const countAt = async (block) => decUint(await read("eth_call", [{ to: projects, data: SEL.count }, `0x${block.toString(16)}`]));
  const configured = deployment.fromBlock;
  let low = configured === undefined || configured === "earliest" ? 0n : BigInt(configured);
  let high = BigInt(await read("eth_blockNumber", []));
  if (await countAt(high) < projectId) throw new Error("This project does not exist yet.");
  if (await countAt(low) >= projectId) return `0x${low.toString(16)}`;
  while (high - low > 1n) {
    const middle = (low + high) / 2n;
    if (await countAt(middle) >= projectId) high = middle;
    else low = middle;
  }
  return `0x${high.toString(16)}`;
}

const launchIdCache = new Map();
function launchIdOf(runtime, projectId) {
  const key = `${runtime.chainId}:${projectId}`;
  if (!launchIdCache.has(key)) {
    const pending = viewAt(runtime, runtime.controller, SEL.uriOf, word(projectId)).then((uri) => {
      const metadata = parseStickyProjectUri(decString(uri));
      return metadata?.protocol === "Sticky" && typeof metadata.launchId === "string" ? metadata.launchId : null;
    });
    pending.catch(() => launchIdCache.delete(key));
    launchIdCache.set(key, pending);
  }
  return launchIdCache.get(key);
}

// The first launch on a chain that shares this launch's id and settings. First, so a later copy of the uri
// cannot displace the real sibling. Bendystraw's uri only narrows the candidates; the chain decides.
async function siblingOn(chainId, launchId, info) {
  const runtime = await chainRuntime(chainId);
  for (const deployed of await deployedProjectsOn(chainId)) {
    if (deployed.tax !== undefined && (deployed.tax !== BigInt(info.reward) || deployed.soulbound !== Boolean(info.soulbound))) continue;
    if (deployed.launchId !== undefined && deployed.launchId !== launchId) continue;
    if (await launchIdOf(runtime, deployed.projectId) !== launchId) continue;
    if (deployed.tax === undefined) {
      const other = await projectInfo(deployed.projectId, await chainReader(chainId));
      if (other.reward !== BigInt(info.reward) || other.soulbound !== Boolean(info.soulbound)) continue;
    }
    return deployed.projectId;
  }
  return null;
}

// Backing and supply of one project on one chain, read at one block.
async function chainBacking(runtime, projectId) {
  const block = await rpcAt(runtime.rpcUrl, "eth_blockNumber", []);
  const read = (to, data) => rpcAt(runtime.rpcUrl, "eth_call", [{ to, data }, block]);
  const stakedToken = decAddress(await read(runtime.deployer, SEL.stakedTokenOf + word(projectId)));
  const stToken = decAddress(await read(runtime.tokens, SEL.tokenOf + word(projectId)));
  const [raw, supply, saved, decimals, symbol] = await Promise.all([
    read(runtime.store, SEL.storeBalanceOf + encAddress(runtime.terminal) + word(projectId) + encAddress(stakedToken)).then(decUint),
    read(stToken, SEL.totalSupply).then(decUint),
    read(runtime.hook, SEL.orphanedBalanceOf + word(projectId)).then(decUint),
    read(stakedToken, SEL.decimals).then((hex) => Number(decUint(hex))),
    read(stakedToken, SEL.symbol).then(decString),
  ]);
  const orphaned = supply === 0n ? raw : saved;
  return { stakedToken, stToken, supply, backing: raw > orphaned ? raw - orphaned : 0n, decimals, symbol };
}

const siblingCache = new Map();
function launchSiblings(projectId, info) {
  const key = `${ctx.chainId}:${projectId}`;
  if (!siblingCache.has(key)) {
    const pending = (async () => {
      const here = await chainRuntime(ctx.chainId);
      const launchId = await launchIdOf(here, projectId);
      const self = { chainId: ctx.chainId, projectId: BigInt(projectId), self: true };
      if (!launchId) return [self];
      const environment = chainById(ctx.chainId)?.environment;
      const others = chainsForEnvironment(environment)
        .filter((chain) => chain.chainId !== ctx.chainId && stickyDeploymentFor(chain.chainId).deployer);
      const found = await Promise.all(others.map(async (chain) => {
        try {
          const sibling = await siblingOn(chain.chainId, launchId, info);
          return sibling === null ? null : { chainId: chain.chainId, projectId: sibling };
        } catch (error) {
          return { chainId: chain.chainId, error: error.message };
        }
      }));
      return [self, ...found.filter(Boolean)];
    })();
    pending.catch(() => siblingCache.delete(key));
    siblingCache.set(key, pending);
  }
  return siblingCache.get(key);
}

// Per-chain rows plus totals. Backing totals only add up when every chain backs with the same token symbol
// and decimals; otherwise each chain stands alone.
function siblingTotals(rows) {
  const ok = rows.filter((row) => row.backing);
  const supply = ok.reduce((sum, row) => sum + row.backing.supply, 0n);
  const first = ok[0]?.backing;
  const same = first && ok.every((row) => row.backing.symbol === first.symbol && row.backing.decimals === first.decimals);
  return { supply, backing: same ? ok.reduce((sum, row) => sum + row.backing.backing, 0n) : null, decimals: first?.decimals, symbol: first?.symbol, complete: ok.length === rows.length };
}

async function renderSiblings(projectId, info, current) {
  const section = $("p-chains-card");
  let siblings;
  try { siblings = await launchSiblings(projectId, info); } catch { siblings = [{ chainId: ctx.chainId, projectId: BigInt(projectId), self: true }]; }
  if (!current()) return;
  const planned = (await projectChainIds(projectId)).filter((chainId) => chainById(chainId)?.environment === chainById(ctx.chainId)?.environment);
  if (!current()) return;
  const missing = planned.filter((chainId) => !siblings.some((row) => row.chainId === chainId));
  if (siblings.length < 2 && !missing.length) { section.classList.add("hide"); return; }
  const rows = await Promise.all(siblings.map(async (row) => {
    if (row.error) return row;
    try { return { ...row, backing: await chainBacking(await chainRuntime(row.chainId), row.projectId) }; }
    catch (error) { return { ...row, error: error.message }; }
  }));
  if (!current()) return;
  const totals = siblingTotals(rows);
  const cell = (row) => row.backing
    ? `<td>${formatUnits(row.backing.backing, row.backing.decimals)} ${esc(row.backing.symbol)}</td><td>${formatUnits(row.backing.supply, 18)} ${esc(info.stSymbol)}</td>`
    : `<td colspan="2" class="mut">${esc(row.error ? "Could not read this chain." : "Not found yet.")}</td>`;
  const link = (row) => row.self
    ? `${esc(chainById(row.chainId)?.name || row.chainId)} <span class="mut">#${row.projectId} (this page)</span>`
    : `<a class="link" href="?chain=${row.chainId}#/project/${row.projectId}">${esc(chainById(row.chainId)?.name || row.chainId)} #${row.projectId}</a>`;
  $("p-chains").innerHTML = rows.map((row) => `<tr><td>${row.projectId === undefined ? esc(chainById(row.chainId)?.name || row.chainId) : link(row)}</td>${cell(row)}</tr>`).join("")
    + missing.map((chainId) => `<tr><td>${esc(chainById(chainId)?.name || chainId)}</td><td colspan="2" class="mut">Planned at launch. Not deployed yet.</td></tr>`).join("")
    + `<tr class="total"><td>Total</td><td>${totals.backing === null ? "Backed by different tokens" : `${formatUnits(totals.backing, totals.decimals)} ${esc(totals.symbol)}`}</td>`
    + `<td>${formatUnits(totals.supply, 18)} ${esc(info.stSymbol)}</td></tr>`;
  $("p-chains-note").textContent = totals.complete ? "" : "Some chains could not be read. Totals cover the chains shown.";
  section.classList.remove("hide");
}

function renderProjectChains(chainIds) {
  const chains = [...new Set(chainIds)].map(chainById).filter(Boolean);
  $("h-chains-wrap").classList.toggle("hide", chains.length === 0);
  $("h-chains").setAttribute("aria-label", chains.map((chain) => chain.name).join(", "));
  $("h-chains").innerHTML = chains.map((chain) =>
    `<span class="project-chain" role="img" aria-label="${esc(chain.name)}" title="${esc(chain.name)}">`
      + `${CHAIN_ICON_SVG[chain.icon]}</span>`,
  ).join("");
}

// Swap monogram badges for real logos wherever they resolved.
async function hydrateLogos() {
  for (const el of document.querySelectorAll("[data-token-logo]")) {
    const addr = el.dataset.tokenLogo;
    const size = el.dataset.size;
    let reader;
    try { reader = el.dataset.chain ? await chainReader(el.dataset.chain) : pageReader(); } catch { continue; }
    const url = await resolveTokenLogoUrl(addr, reader);
    if (url) {
      const img = document.createElement("img");
      img.src = url;
      img.alt = "";
      img.width = img.height = Number(size) || 15;
      img.style.cssText = "border-radius:6px;object-fit:cover;display:block";
      img.referrerPolicy = "no-referrer";
      img.onload = () => el.replaceChildren(img);
    }
  }
}

const tok = (addr, symbol) => `<span class="tok">${tokenLogo(addr, symbol)}${esc(symbol)}</span>`;
const pct = (bp) => `${Number(bp) / 100}%`;
const shortAddr = (a) => a.slice(0, 6) + "…" + a.slice(-4);
const addressLabel = (address) =>
  `<span class="address-label" tabindex="0" data-ens-address="${esc(address)}" `
    + `data-full-address="${esc(address)}" aria-label="${esc(address)}">${esc(shortAddr(address))}</span>`;

async function hydrateEns(root = document) {
  const labels = [...root.querySelectorAll("[data-ens-address]")];
  await Promise.all(labels.map(async (label) => {
    const address = label.dataset.ensAddress;
    const name = await reverseEns(address);
    if (!name || !label.isConnected || label.dataset.ensAddress !== address) return;
    label.textContent = name;
    label.setAttribute("aria-label", `${name}, ${address}`);
  }));
}

const addressTooltip = $("address-tooltip");
function showAddressTooltip(label) {
  addressTooltip.textContent = label.dataset.fullAddress;
  addressTooltip.classList.remove("hide");
  const anchor = label.getBoundingClientRect();
  const tip = addressTooltip.getBoundingClientRect();
  const left = Math.min(Math.max(8, anchor.left), window.innerWidth - tip.width - 8);
  const above = anchor.top - tip.height - 7;
  const top = above >= 8 ? above : anchor.bottom + 7;
  addressTooltip.style.left = `${left}px`;
  addressTooltip.style.top = `${top}px`;
}
function hideAddressTooltip() { addressTooltip.classList.add("hide"); }
document.addEventListener("pointerover", (event) => {
  const label = event.target.closest?.("[data-full-address]");
  if (label) showAddressTooltip(label);
});
document.addEventListener("pointerout", (event) => {
  const label = event.target.closest?.("[data-full-address]");
  if (label && !label.contains(event.relatedTarget)) hideAddressTooltip();
});
document.addEventListener("focusin", (event) => {
  const label = event.target.closest?.("[data-full-address]");
  if (label) showAddressTooltip(label);
});
document.addEventListener("focusout", (event) => {
  if (event.target.closest?.("[data-full-address]")) hideAddressTooltip();
});
function ago(ts) {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86_400)}d ago`;
}
function status(msg, cls = "") {
  const el = $("status");
  el.textContent = msg;
  el.className = !msg || msg === "idle" || msg === "onchain" ? "hide" : cls;
}

let txStatusTimer = null;
function txStatus(msg, cls = "") {
  clearTimeout(txStatusTimer);
  $("tx-status-message").textContent = msg;
  $("tx-status").className = msg ? cls : "hide";
  if (msg && (cls === "ok" || cls === "err")) {
    txStatusTimer = setTimeout(() => txStatus(""), 8_000);
  }
}

function inlineStatus(anchor, msg, cls = "err", action = null) {
  const dialog = anchor?.closest?.("dialog");
  const target = dialog
    ? anchor.closest?.(".create-section") || dialog
    : anchor?.closest?.("section, .card-item, .list-card") || anchor?.parentElement;
  if (!target) return status(msg, cls);
  let notice = target.querySelector(":scope > .inline-status");
  if (!notice) {
    notice = document.createElement("div");
    notice.className = "inline-status";
    notice.setAttribute("role", "alert");
    const actions = target.querySelector(":scope > .dlg-actions");
    if (actions) target.insertBefore(notice, actions);
    else target.appendChild(notice);
  }
  notice.textContent = msg;
  notice.className = `inline-status ${cls}`;
  if (action) notice.append(" ", action);
}
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// --------------------------------------------------------------------- state
const ctx = {
  loaded: false,
  hook: null,
  tokens: null,
  terminal: null,
  store: null,
  controller: null,
  projects: {}, // projectId -> {stakedToken, symbol, decimals, name, stToken, stSymbol, stName, reward}
  currentId: null,
  alias: null, // the verified @handle the current project was reached through, if any
  homeChartCleanup: null,
};

let viewSequence = 0;
function currentView() {
  const sequence = viewSequence, chainId = ctx.chainId, projectId = ctx.currentId, holder = account();
  return () => sequence === viewSequence && ctx.loaded && ctx.chainId === chainId
    && ctx.currentId === projectId && account() === holder;
}

async function loadDeployer() {
  ctx.loaded = false;
  const deployer = $("deployer").value;
  if (!isHomeRoute()) status("loading…");
  StickyRuntime.address(deployer);
  const chainId = Number(BigInt(await rpc("eth_chainId", [])));
  if (!window.__DEMO_RPC) {
    const selected = Number(new URL(location.href).searchParams.get("chain") || window.STICKY_CONFIG?.defaultChainId || chainId);
    if (chainId !== selected) throw new Error(`The configured RPC serves chain ${chainId}; this page selected chain ${selected}.`);
    const code = await rpc("eth_getCode", [deployer, "latest"]);
    if (!code || code === "0x") throw new Error("Sticky is not deployed at the configured address on this chain.");
  }
  const [hook, tokens, terminal, controller] = await Promise.all(
    [SEL.HOOK, SEL.TOKENS, SEL.TERMINAL, SEL.CONTROLLER].map(selector => view(deployer, selector).then(decAddress).then(StickyRuntime.address)),
  );
  const store = StickyRuntime.address(decAddress(await view(terminal, SEL.STORE)));
  if (!window.__DEMO_RPC) {
    await Promise.all([hook, tokens, terminal, controller, store].map(async address => {
      const code = await rpc("eth_getCode", [address, "latest"]);
      if (!code || code === "0x") throw new Error("The configured Sticky deployment has an unavailable dependency.");
    }));
  }
  Object.assign(ctx, { chainId, hook, tokens, terminal, controller, store });
  ctx.loaded = true;
  ctx.projects = {};
  ctx.pool = null;
  ctx.walletMax = ctx.stakedMax = null;
  for (const cache of [blockTimestamps, logoCache, projectMetadataCache]) for (const key of Object.keys(cache)) delete cache[key];
  handleRouteCache.clear();
  projectHandleCache.clear();
  // Re-resolve the fund-origin default now that the connected chain is known.
  originKey = null;
  renderOriginPills();
  status("onchain", "ok");
  // The home page reads every chain itself and does not wait for this one.
  if (!isHomeRoute() || window.__DEMO_RPC) route();
}

async function projectInfo(projectId, reader = pageReader()) {
  const key = projectId.toString();
  if (reader.projects[key]) return reader.projects[key];
  const idArg = word(projectId);
  const view = (to, sel, args = "") => reader.rpc("eth_call", [{ to, data: sel + args }, "latest"]);
  const stakedToken = decAddress(await view(reader.deployer, SEL.stakedTokenOf, idArg));
  if (stakedToken === "0x0000000000000000000000000000000000000000") {
    throw new Error(`project ${projectId} is not a sticky token of this deployer`);
  }
  const stToken = decAddress(await view(reader.tokens, SEL.tokenOf, idArg));
  const [symbol, decimals, name, stSymbol, stName, reward, soulbound] = await Promise.all([
    view(stakedToken, SEL.symbol).then(decString),
    view(stakedToken, SEL.decimals).then((h) => Number(decUint(h))),
    view(stakedToken, SEL.name).then(decString),
    view(stToken, SEL.symbol).then(decString),
    view(stToken, SEL.name).then(decString),
    view(reader.deployer, SEL.cashOutTaxRateOf, idArg).then(decUint),
    view(stToken, SEL.SOULBOUND).then((h) => decUint(h) === 1n).catch(() => true),
  ]);
  reader.projects[key] = { stakedToken, symbol, decimals, name, stToken, stSymbol, stName, reward, soulbound };
  return reader.projects[key];
}

// A Sticky token is named by its own onchain symbol, which a launch may customize.
const stickyLabel = (info) => info.stSymbol || `Sticky ${info.symbol}`;

async function projectIds() {
  if (!window.__DEMO_RPC) return (await deployedProjectsOn(ctx.chainId)).map((project) => project.projectId);
  const logs = await getLogs($("deployer").value, [TOPIC.DeploySticky]);
  return logs.map((log) => decUint(log.topics[1]));
}

const POSITION_TOPICS = [TOPIC.Staked, TOPIC.Unstaked, TOPIC.StreakStarted, TOPIC.StreakEnded];
// One holder's position events across the given projects, from the oldest project's creation block (project
// IDs rise with creation), with block timestamps attached.
async function holderLogs(ids, holder) {
  if (!ids.length) return [];
  const oldest = ids.reduce((low, id) => (id < low ? id : low));
  const logs = await getLogs(ctx.hook, [POSITION_TOPICS, null, "0x" + encAddress(holder)], await projectStartBlock(ctx.chainId, oldest));
  return attachTimestamps(logs);
}

// One scan per project view: position events plus the launch granters and every holder's trusted senders,
// all indexed by project. Timestamps are attached to position events only. Kept for the view's lifetime
// so the 15-second position refresh never rescans history.
async function projectLogs(projectId) {
  const all = await getLogs(ctx.hook, [[...POSITION_TOPICS, TOPIC.SetGranter, TOPIC.SetTrustedSender], "0x" + word(projectId)],
    await projectStartBlock(ctx.chainId, projectId));
  const position = all.filter((log) => POSITION_TOPICS.includes(log.topics[0]));
  await attachTimestamps(position);
  ctx.projectLogs = { chainId: ctx.chainId, projectId: BigInt(projectId), all, position };
  return ctx.projectLogs;
}
const cachedProjectLogs = (projectId) => ctx.projectLogs?.chainId === ctx.chainId && ctx.projectLogs.projectId === BigInt(projectId) ? ctx.projectLogs : null;

// Per-holder rows for a project, from the hook's own events: every Staked and Unstaked carries the holder's
// resulting balance, StreakStarted marks the streak's start and StreakEnded its length. No per-holder reads,
// so the list costs one bounded log scan however many holders there are. The visible page is re-read from
// the hook (verifyHolderPage) so a gap in the scan cannot misstate a balance shown.
// A stick's age is block time minus the holder's streak start (StreakStarted, the hook's streakStartOf).
// A project page reads every age against one pinned block, so the header and your position agree.
async function pinnedBlock() {
  const block = await rpc("eth_getBlockByNumber", ["latest", false]);
  return { tag: /^0x[0-9a-fA-F]+$/.test(block?.number || "") ? block.number : "latest", timestamp: Number(BigInt(block.timestamp)) };
}
function renderHeaderAges(rows, now) {
  const ages = rows.filter((row) => row.staked > 0n).map((row) => (row.start ? Math.max(0, now - row.start) : 0));
  $("h-average").textContent = formatDuration(ages.length ? Math.floor(ages.reduce((total, age) => total + age, 0) / ages.length) : 0);
  $("h-top").textContent = formatDuration(Math.max(0, ...ages));
}

function holderRows(projectId, logs, now = Math.floor(Date.now() / 1000)) {
  const rows = new Map();
  for (const log of logs) {
    if (decUint(log.topics[1]) !== BigInt(projectId)) continue;
    const holder = decAddress(log.topics[2]);
    const row = rows.get(holder) || { holder, staked: 0n, start: 0, longest: 0 };
    const topic = log.topics[0];
    if (topic === TOPIC.Staked) row.staked = decUint(log.data, 2);
    else if (topic === TOPIC.Unstaked) row.staked = decUint(log.data, 1);
    else if (topic === TOPIC.StreakStarted) row.start = log.ts;
    else if (topic === TOPIC.StreakEnded) { row.start = 0; row.longest = Math.max(row.longest, Number(decUint(log.data, 0))); }
    rows.set(holder, row);
  }
  return [...rows.values()].map(({ holder, staked, start, longest }) => {
    const current = start ? Math.max(0, now - start) : 0;
    return { holder, staked, start, current, longest: Math.max(longest, current) };
  });
}

// Re-read the shown holders' balances from the hook at one block.
async function verifyHolderPage(projectId, rows) {
  const block = await rpc("eth_blockNumber", []);
  return Promise.all(rows.map(async (row) => {
    const staked = decUint(await rpc("eth_call", [{ to: ctx.hook, data: SEL.stakedBalanceOf + word(projectId) + encAddress(row.holder) }, block]));
    return staked === row.staked ? row : { ...row, staked };
  }));
}

// Decode hook logs into activity cards, newest first. Each card carries the stuck token's logo.
async function activityItems(logs, includeProject, reader = pageReader()) {
  const items = [];
  const adapter = (autoStickAdapterOn(reader.chainId) || "").toLowerCase();
  for (const log of logs.slice(-40)) {
    const id = decUint(log.topics[1]);
    let info;
    try {
      info = await projectInfo(id, reader);
    } catch {
      continue; // a project from another deployer sharing the hook
    }
    const holder = shortAddr(decAddress(log.topics[2]));
    let html;
    if (log.topics[0] === TOPIC.Staked) {
      const autoStuck = decAddress(log.data, 0).toLowerCase() === adapter;
      html = `<span class="addr">${holder}</span> <span class="verb">${autoStuck ? "auto-stuck" : "received"}</span> ${formatUnits(decUint(log.data, 1), 18)} ${esc(info.stSymbol)}`;
    } else if (log.topics[0] === TOPIC.Unstaked) {
      // Burns and outgoing transfers reduce the position too; this event does not prove an underlying payout.
      html = `<span class="addr">${holder}</span> <span class="verb out">removed</span> ${formatUnits(decUint(log.data, 0), 18)} ${esc(info.stSymbol)} from their position`;
    } else if (log.topics[0] === TOPIC.StreakStarted) {
      html = `<span class="addr">${holder}</span> <span class="verb">got sticky</span>`;
    } else {
      html = `<span class="addr">${holder}</span> <span class="verb out">came unstuck after ${formatDuration(decUint(log.data, 0))}</span>`;
    }
    const nameLine = includeProject
      ? `<div><a class="link" href="${projectHref(reader.chainId, id)}">${esc(stickyLabel(info))}</a> ${chainIcons([reader.chainId])}</div>`
      : "";
    items.push({
      ts: log.ts,
      html: `<div class="card-item"><div class="card-head">${tokenLogo(info.stakedToken, info.symbol, 22, reader.chainId)}` +
        `<div style="flex:1;min-width:0"><div class="mut" style="font-size:11px">${ago(log.ts)}</div>` +
        `${nameLine}<div>${html}</div></div></div></div>`,
    });
  }
  return items.reverse();
}

// A stake paid for someone else is an airdrop. Staked logs include both payer and holder, so this is exact.
async function airdropItems(logs, reader = pageReader()) {
  const items = [];
  const adapter = (autoStickAdapterOn(reader.chainId) || "").toLowerCase();
  const staked = logs.filter((log) => log.topics[0] === TOPIC.Staked).slice(-40);
  for (const log of staked) {
    const holder = decAddress(log.topics[2]);
    const payer = decAddress(log.data, 0);
    if (holder.toLowerCase() === payer.toLowerCase()) continue;
    // Auto-stick compounds are the holder's own rewards, not airdrops.
    if (payer.toLowerCase() === adapter) continue;
    const id = decUint(log.topics[1]);
    let info;
    try {
      info = await projectInfo(id, reader);
    } catch {
      continue;
    }
    const amount = formatUnits(decUint(log.data, 1), 18);
    const self = holder.toLowerCase() === account().toLowerCase() ? " (you)" : "";
    items.push({
      ts: log.ts,
      html: `<div class="card-item"><div class="card-head">${tokenLogo(info.stakedToken, info.symbol, 22, reader.chainId)}`
        + `<div style="flex:1;min-width:0"><div class="mut" style="font-size:11px">${ago(log.ts)}</div>`
        + `<div><a class="link" href="${projectHref(reader.chainId, id)}">${esc(stickyLabel(info))}</a> ${chainIcons([reader.chainId])}</div>`
        + `<div><span class="addr">${addressLabel(holder)}${self}</span> received ${amount} ${esc(info.stSymbol)}`
        + ` from <span class="addr">${addressLabel(payer)}</span></div></div></div></div>`,
    });
  }
  return items.reverse();
}

// Home feeds from Bendystraw's events. A stick is a pay and an unstick a cash out; amounts are the Sticky
// tokens minted or burned. Stuck tokens paid for someone else are an airdrop.
async function indexedActivityItems(events, reader) {
  const adapter = (autoStickAdapterOn(reader.chainId) || "").toLowerCase();
  const items = [];
  for (const event of events.slice(-40)) {
    let info;
    try {
      info = await projectInfo(event.projectId, reader);
    } catch {
      continue;
    }
    const verb = event.kind === "unstick" ? `<span class="verb out">unstuck</span>`
      : `<span class="verb">${event.payer === adapter ? "auto-stuck" : "stuck"}</span>`;
    items.push({
      ts: event.ts,
      html: feedCard(info, reader, event.projectId, event.ts,
        `<span class="addr">${shortAddr(event.holder)}</span> ${verb} ${formatUnits(event.tokens, 18)} ${esc(info.stSymbol)}`),
    });
  }
  return items.reverse();
}
async function indexedAirdropItems(events, reader) {
  const adapter = (autoStickAdapterOn(reader.chainId) || "").toLowerCase();
  const items = [];
  const airdrops = events.filter((event) => event.kind === "stick" && event.payer !== event.holder && event.payer !== adapter);
  for (const event of airdrops.slice(-40)) {
    let info;
    try {
      info = await projectInfo(event.projectId, reader);
    } catch {
      continue;
    }
    const self = event.holder === (account() || "").toLowerCase() ? " (you)" : "";
    items.push({
      ts: event.ts,
      html: feedCard(info, reader, event.projectId, event.ts,
        `<span class="addr">${addressLabel(event.holder)}${self}</span> received ${formatUnits(event.tokens, 18)} ${esc(info.stSymbol)}`
        + ` from <span class="addr">${addressLabel(event.payer)}</span>`),
    });
  }
  return items.reverse();
}
const feedCard = (info, reader, projectId, ts, line) => `<div class="card-item"><div class="card-head">${tokenLogo(info.stakedToken, info.symbol, 22, reader.chainId)}`
  + `<div style="flex:1;min-width:0"><div class="mut" style="font-size:11px">${ago(ts)}</div>`
  + `<div><a class="link" href="${projectHref(reader.chainId, projectId)}">${esc(stickyLabel(info))}</a> ${chainIcons([reader.chainId])}</div>`
  + `<div>${line}</div></div></div></div>`;

function configuredStickiestCards() {
  return (window.STICKY_CONFIG?.demoHomeStickiest || []).flatMap((row) => {
    try {
      return [{
        id: BigInt(row.id),
        info: {
          symbol: String(row.symbol),
          stakedToken: row.token,
          reward: BigInt(Math.round(Number(row.bonus) * 100)),
        },
        totalStaked: parseUnits(String(row.stuck), 18),
        sticks: Number(row.sticks),
        demo: true,
      }];
    } catch {
      return [];
    }
  });
}

async function configuredAirdropItems() {
  const items = [];
  const now = Math.floor(Date.now() / 1000);
  for (const row of window.STICKY_CONFIG?.demoHomeAirdrops || []) {
    let info;
    try {
      info = await projectInfo(BigInt(row.projectId));
    } catch {
      continue;
    }
    const self = row.holder.toLowerCase() === account().toLowerCase() ? " (you)" : "";
    items.push(
      `<div class="card-item"><div class="card-head">${tokenLogo(info.stakedToken, info.symbol, 22)}`
      + `<div style="flex:1;min-width:0"><div class="mut" style="font-size:11px">${ago(now - Number(row.hoursAgo) * 3600)}</div>`
      + `<div><a class="link" href="#/project/${esc(row.projectId)}">${esc(stickyLabel(info))}</a></div>`
      + `<div><span class="addr">${addressLabel(row.holder)}${self}</span> received ${esc(String(row.amount))} ${esc(info.symbol)}`
      + ` from <span class="addr">${addressLabel(row.payer)}</span></div></div></div></div>`,
    );
  }
  return items;
}

const renderFeed = (el, items, empty = "no activity yet") => {
  el.innerHTML = items.length ? items.map((item) => item.html ?? item).join("") : `<div class="card-item mut">${esc(empty)}</div>`;
  hydrateEns(el).catch(() => {});
};

function setHomeListTab(active) {
  for (const name of ["latest", "stickiest", "airdrops"]) {
    const selected = name === active;
    $("home-tab-" + name).classList.toggle("on", selected);
    $("home-tab-" + name).setAttribute("aria-selected", String(selected));
    $("home-tab-" + name).tabIndex = selected ? 0 : -1;
    $("home-panel-" + name).classList.toggle("on", selected);
  }
}
$("home-tab-latest").onclick = () => setHomeListTab("latest");
$("home-tab-stickiest").onclick = () => setHomeListTab("stickiest");
$("home-tab-airdrops").onclick = () => setHomeListTab("airdrops");

function setHomeRankingTab(active) {
  for (const name of ["stickiest", "airdrops"]) {
    const selected = name === active;
    $("home-rank-" + name).classList.toggle("on", selected);
    $("home-rank-" + name).setAttribute("aria-selected", String(selected));
    $("home-rank-" + name).tabIndex = selected ? 0 : -1;
    $("home-panel-" + name).classList.toggle("ranking-on", selected);
  }
}
$("home-rank-stickiest").onclick = () => setHomeRankingTab("stickiest");
$("home-rank-airdrops").onclick = () => setHomeRankingTab("airdrops");

for (const [prefix, names, select] of [
  ["home-tab-", ["latest", "stickiest", "airdrops"], setHomeListTab],
  ["home-rank-", ["stickiest", "airdrops"], setHomeRankingTab],
]) {
  names.forEach((name, index) => {
    const button = $(prefix + name);
    button.tabIndex = index === 0 ? 0 : -1;
    button.onkeydown = (event) => {
      const next = event.key === "Home" ? 0 : event.key === "End" ? names.length - 1
        : event.key === "ArrowRight" ? (index + 1) % names.length
        : event.key === "ArrowLeft" ? (index + names.length - 1) % names.length : null;
      if (next === null) return;
      event.preventDefault();
      select(names[next]);
      $(prefix + names[next]).focus();
    };
  });
}

// ------------------------------------------------------ home secured chart
const groupAmount = (value, decimals = 18, dp = 2) => {
  const [whole, fraction] = formatUnits(value, decimals, dp).split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return fraction ? `${grouped}.${fraction}` : grouped;
};

const compactAmount = (value, decimals = 18) => {
  const numeric = Number(formatUnits(value, decimals, 2));
  if (!Number.isFinite(numeric)) return groupAmount(value, decimals, 0);
  return new Intl.NumberFormat(undefined, {
    notation: numeric >= 1_000 ? "compact" : "standard",
    maximumFractionDigits: numeric >= 10 ? 1 : 2,
  }).format(numeric);
};

const USD_DECIMALS = 6;
const USD_SCALE = 10n ** BigInt(USD_DECIMALS);
const DEXSCREENER_CHAIN = {
  1: "ethereum",
  10: "optimism",
  8453: "base",
  42_161: "arbitrum",
};

const usdMicros = (value) => {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric > 0 ? BigInt(Math.round(numeric * Number(USD_SCALE))) : null;
};

const formatUsd = (value) => {
  const cents = (value + 5_000n) / 10_000n;
  const dollars = cents / 100n;
  const fraction = (cents % 100n).toString().padStart(2, "0");
  return `$${dollars.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${fraction}`;
};


const cardKey = (card) => card.key ?? card.id.toString();
function configuredUsdPrice(card, chainId = ctx.chainId) {
  const entries = Object.entries(window.STICKY_CONFIG?.usdPriceOverrides || {});
  const overrides = new Map(entries.map(([key, price]) => [key.toLowerCase(), price]));
  const address = card.info.stakedToken.toLowerCase();
  const keys = [`${chainId}:${address}`, address, card.info.symbol.toLowerCase()];
  for (const key of keys) {
    const price = usdMicros(overrides.get(key));
    if (price !== null) return price;
  }
  return null;
}

// Prices are keyed by chain and contract address. Symbols are only accepted as explicit config overrides,
// which keeps two unrelated tokens with the same ticker from being accidentally valued as one asset.
async function backingUsdPrices(cards, chainId = ctx.chainId) {
  const prices = new Map();
  const missingByAddress = new Map();
  for (const card of cards) {
    const override = configuredUsdPrice(card, chainId);
    if (override !== null) {
      prices.set(cardKey(card), override);
      continue;
    }
    const address = card.info.stakedToken.toLowerCase();
    if (!missingByAddress.has(address)) missingByAddress.set(address, []);
    missingByAddress.get(address).push(card);
  }

  const chain = DEXSCREENER_CHAIN[chainId];
  const addresses = [...missingByAddress.keys()];
  if (!chain || !addresses.length) return prices;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5_000);
  try {
    const endpoint = window.STICKY_CONFIG?.usdPriceEndpoint
      || `https://api.dexscreener.com/tokens/v1/${chain}/${addresses.join(",")}`;
    const response = await fetch(endpoint, { signal: controller.signal });
    if (!response.ok) throw new Error(`price request failed (${response.status})`);
    const pairs = await response.json();
    if (!Array.isArray(pairs)) throw new Error("price response was not a list");

    for (const [address, addressCards] of missingByAddress) {
      let best = null;
      for (const pair of pairs) {
        const base = pair.baseToken?.address?.toLowerCase();
        const quote = pair.quoteToken?.address?.toLowerCase();
        let price = null;
        if (base === address) price = Number(pair.priceUsd);
        else if (quote === address) {
          const baseUsd = Number(pair.priceUsd);
          const baseInQuote = Number(pair.priceNative);
          if (baseInQuote > 0) price = baseUsd / baseInQuote;
        }
        const liquidity = Number(pair.liquidity?.usd || 0);
        if (price > 0 && (!best || liquidity > best.liquidity)) best = { price, liquidity };
      }
      const price = best ? usdMicros(best.price) : null;
      if (price !== null) for (const card of addressCards) prices.set(cardKey(card), price);
    }
  } catch (error) {
    console.warn("Unable to price Sticky backing tokens", error);
  } finally {
    clearTimeout(timeout);
  }
  return prices;
}

// Supply moves for the chart: { chainId, projectId, ts, delta } in Sticky token units.
function logMoves(logs) {
  return logs.flatMap((log) => {
    if (log.topics[0] === TOPIC.Staked) return [{ chainId: log.chainId, projectId: decUint(log.topics[1]), ts: log.ts, delta: decUint(log.data, 1) }];
    if (log.topics[0] === TOPIC.Unstaked) return [{ chainId: log.chainId, projectId: decUint(log.topics[1]), ts: log.ts, delta: -decUint(log.data, 0) }];
    return [];
  });
}
const eventMoves = (events) => events.map((event) => ({
  chainId: event.chainId, projectId: event.projectId, ts: event.ts, delta: event.kind === "stick" ? event.tokens : -event.tokens,
}));

function projectStakedHistory(moves, card, now) {
  const configured = configuredChartPoints(now, card.id);
  if (configured) {
    const points = configured.map((point) => ({ ts: point.ts, value: point.staked }));
    points[points.length - 1] = { ts: now, value: card.totalStaked };
    return points;
  }

  const events = moves.filter((move) => move.projectId === card.id && (card.chainId === undefined || move.chainId === card.chainId))
    .sort((a, b) => a.ts - b.ts);

  if (!events.length) {
    return [{ ts: now - 30 * 86_400, value: card.totalStaked }, { ts: now, value: card.totalStaked }];
  }

  let running = 0n;
  const points = [{ ts: events[0].ts, value: 0n }];
  for (const event of events) {
    running = running + event.delta < 0n ? 0n : running + event.delta;
    points.push({ ts: event.ts, value: running });
  }
  const correction = card.totalStaked - running;
  for (const point of points) point.value = point.value + correction < 0n ? 0n : point.value + correction;
  points.push({ ts: now, value: card.totalStaked });
  return points;
}

function homeSecuredSeries(moves, cards, prices) {
  const now = Math.floor(Date.now() / 1000);
  const valuedCards = cards.filter((card) => prices.has(cardKey(card)));
  const histories = valuedCards.map((card) => ({
    card,
    price: prices.get(cardKey(card)),
    points: projectStakedHistory(moves, card, now),
  }));
  const timestamps = [...new Set(histories.flatMap((history) => history.points.map((point) => point.ts)))]
    .sort((a, b) => a - b);
  if (!timestamps.length) timestamps.push(now - 30 * 86_400, now);

  const points = timestamps.map((ts) => {
    let value = 0n;
    for (const history of histories) {
      let amount = 0n;
      for (const point of history.points) {
        if (point.ts > ts) break;
        amount = point.value;
      }
      // Historical share quantities valued at today's backing per share and token price; this is an estimate,
      // not a reconstruction of past donations, cash out fees, or market prices.
      if (history.card.totalStaked > 0n) value += amount * history.card.pool.sigma * history.price
        / history.card.totalStaked / 10n ** BigInt(history.card.info.decimals);
    }
    return { ts, value };
  });
  const total = valuedCards.reduce(
    (sum, card) => sum + card.pool.sigma * prices.get(cardKey(card)) / 10n ** BigInt(card.info.decimals),
    0n,
  );
  points[points.length - 1] = { ts: now, value: total };
  const missing = cards.filter((card) => card.totalStaked > 0n && !prices.has(cardKey(card)));
  return { points, total, missing, hasValue: valuedCards.length > 0 };
}

function clearHomeSecuredChart() {
  ctx.homeChartCleanup?.();
  ctx.homeChartCleanup = null;
}

function mountHomeSecuredChart(series) {
  clearHomeSecuredChart();
  const container = $("home-secured-chart");
  const value = $("home-secured-value");
  const hover = $("home-secured-hover");
  const dateValue = $("home-secured-date");
  const hoverValue = $("home-secured-hover-value");
  value.textContent = series.hasValue ? formatUsd(series.total) : "$—";
  $("home-secured-note").classList.toggle("hide", !series.hasValue);
  value.title = series.missing.length
    ? `Could not price ${series.missing.map((card) => card.info.symbol).join(", ")}`
    : "Current claimable backing at today's token price. History estimates past shares at today's backing per share and price.";
  const date = (ts) => new Date(ts * 1000).toLocaleDateString(undefined, {
    month: "short", day: "numeric", year: "numeric",
  });
  const count = 28;
  const start = series.points[0].ts;
  const end = series.points[series.points.length - 1].ts;
  const span = Math.max(end - start, 1);
  const samples = [];
  let pointIndex = 0;
  for (let i = 0; i < count; i++) {
    const ts = start + (span * i) / Math.max(count - 1, 1);
    while (pointIndex + 1 < series.points.length && series.points[pointIndex + 1].ts <= ts) pointIndex++;
    samples.push({ ts, value: series.points[pointIndex].value });
  }
  samples[samples.length - 1] = { ts: end, value: series.total };
  const max = samples.reduce((highest, sample) => sample.value > highest ? sample.value : highest, 1n);
  const bars = samples.map((sample, i) => {
    const height = sample.value <= 0n ? 0 : Math.max(1, Number((sample.value * 10_000n) / max) / 100);
    const label = `${date(sample.ts)}: ${formatUsd(sample.value)} (current backing and price estimate)`;
    return `<span class="home-secured-bar" data-index="${i}" style="height:${height.toFixed(2)}%" title="${esc(label)}"></span>`;
  }).join("");

  const defaultLabel = `${series.hasValue ? formatUsd(series.total) : "USD value unavailable"} secured by Sticky`;
  container.innerHTML = `<div class="home-secured-plot" tabindex="0" role="img" aria-label="${esc(defaultLabel)}">`
    + `<div class="home-secured-bars" aria-hidden="true">${bars}</div>`
    + `<span class="home-secured-axis home-secured-x-start">${esc(date(start))}</span>`
    + `<span class="home-secured-axis home-secured-x-end">${esc(date(end))}</span>`
    + `</div>`;

  const plot = container.querySelector(".home-secured-plot");
  const barArea = container.querySelector(".home-secured-bars");
  const barElements = [...container.querySelectorAll(".home-secured-bar")];
  let active = -1;
  const show = (index) => {
    active = Math.min(samples.length - 1, Math.max(0, index));
    const sample = samples[active];
    barElements.forEach((bar, i) => bar.classList.toggle("active", i === active));
    container.classList.add("is-inspecting");
    dateValue.textContent = date(sample.ts);
    hoverValue.textContent = `≈ ${formatUsd(sample.value)}`;
    hover.classList.remove("hide");
    plot.setAttribute("aria-label", `${date(sample.ts)}: ${formatUsd(sample.value)} secured by Sticky`);
  };
  const clear = () => {
    active = -1;
    barElements.forEach((bar) => bar.classList.remove("active"));
    container.classList.remove("is-inspecting");
    hover.classList.add("hide");
    plot.setAttribute("aria-label", defaultLabel);
  };
  const showPointer = (event) => {
    const box = barArea.getBoundingClientRect();
    show(Math.floor(((event.clientX - box.left) / box.width) * samples.length));
  };
  plot.onpointermove = showPointer;
  plot.onpointerdown = showPointer;
  plot.onpointerleave = (event) => { if (event.pointerType !== "touch") clear(); };
  plot.onfocus = () => show(samples.length - 1);
  plot.onblur = clear;
  plot.onkeydown = (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    show(active < 0 ? samples.length - 1 : active + (event.key === "ArrowRight" ? 1 : -1));
  };
  ctx.homeChartCleanup = () => {
    plot.onpointermove = null;
    plot.onpointerdown = null;
    plot.onpointerleave = null;
    plot.onfocus = null;
    plot.onblur = null;
    plot.onkeydown = null;
  };
}

// ----------------------------------------------------------------- svg chart
// Two stepped series over time: active streak count and total staked, each normalized to its own
// max so both trends read on one panel.
function configuredChartPoints(now, projectId) {
  const history = window.STICKY_CONFIG?.demoChartHistory;
  if (!Array.isArray(history) || history.length < 2) return null;
  const configuredProjectId = window.STICKY_CONFIG?.projectId;
  if (configuredProjectId !== undefined && String(configuredProjectId) !== String(projectId)) return null;
  try {
    const points = history
      .map((point) => ({
        ts: now - Number(point.daysAgo) * 86_400,
        streaks: Number(point.streaks),
        staked: parseUnits(String(point.locked), 18),
      }))
      .filter((point) => Number.isFinite(point.ts) && Number.isFinite(point.streaks) && point.streaks >= 0)
      .sort((a, b) => a.ts - b.ts);
    return points.length >= 2 ? points : null;
  } catch {
    return null;
  }
}

function chartSvg(logs, info, projectId) {
  const now = Math.floor(Date.now() / 1000);
  let points = configuredChartPoints(now, projectId);
  const events = logs
    .map((log) => {
      if (log.topics[0] === TOPIC.StreakStarted) return { ts: log.ts, streaks: 1, staked: 0n };
      if (log.topics[0] === TOPIC.StreakEnded) return { ts: log.ts, streaks: -1, staked: 0n };
      if (log.topics[0] === TOPIC.Staked) return { ts: log.ts, streaks: 0, staked: decUint(log.data, 1) };
      return { ts: log.ts, streaks: 0, staked: -decUint(log.data, 0) };
    })
    .sort((a, b) => a.ts - b.ts);
  if (!points && !events.length) return { svg: `<p class="mut">no sticks yet</p>` };

  const t0 = points ? points[0].ts : events[0].ts;
  const span = Math.max(now - t0, 1);
  const W = 640;
  const H = 210;
  const PAD = 34;
  const x = (ts) => PAD + ((ts - t0) / span) * (W - PAD - 10);

  // Build cumulative step points for both series.
  if (!points) {
    let streaks = 0;
    let staked = 0n;
    points = [{ ts: t0, streaks: 0, staked: 0n }];
    for (const event of events) {
      streaks += event.streaks;
      staked += event.staked;
      points.push({ ts: event.ts, streaks, staked });
    }
    points.push({ ts: now, streaks, staked });
  }
  const maxStreaks = Math.max(...points.map((p) => p.streaks), 1);
  const maxStaked = points.reduce((m, p) => (p.staked > m ? p.staked : m), 1n);
  const yStreaks = (v) => H - 24 - (v / maxStreaks) * (H - 44);
  const yStaked = (v) => H - 24 - Number((v * 1000n) / maxStaked) / 1000 * (H - 44);

  const path = (yOf, key) => {
    let d = "";
    let prevY = null;
    for (const p of points) {
      const px = x(p.ts).toFixed(1);
      const py = yOf(p[key]).toFixed(1);
      d += d === "" ? `M ${px} ${py}` : ` H ${px}` + (py !== prevY ? ` V ${py}` : "");
      prevY = py;
    }
    return d;
  };
  const date = (ts) => new Date(ts * 1000).toLocaleString(undefined, span < 2 * 86_400
    ? { hour: "numeric", minute: "2-digit" }
    : { month: "short", day: "numeric" });
  const guides = [0.25, 0.5, 0.75].map((fraction) => {
    const gx = x(t0 + span * fraction).toFixed(1);
    return `<line x1="${gx}" y1="20" x2="${gx}" y2="${H - 24}" stroke="#d8e7eb" stroke-dasharray="2 4"/>`
      + `<text x="${gx}" y="${H - 8}" fill="#64808a" font-size="9" text-anchor="middle">${date(t0 + span * fraction)}</text>`;
  }).join("");
  // Each series is scaled to its own peak, so the top line means both peaks, and each caption names its peak
  // in its own unit and color. There is no shared numeric axis to label.
  const svg = `<svg viewBox="0 0 ${W} ${H}" style="width:100%;max-width:${W}px;cursor:crosshair" tabindex="0" role="img" aria-label="Active sticks and total stuck over time">
    ${guides}
    <line x1="${PAD}" y1="${(20 + H - 24) / 2}" x2="${W - 10}" y2="${(20 + H - 24) / 2}" stroke="#d8e7eb" stroke-dasharray="2 4"/>
    <line x1="${PAD}" y1="${H - 24}" x2="${W - 10}" y2="${H - 24}" stroke="#e2d7bd"/>
    <line x1="${PAD}" y1="20" x2="${PAD}" y2="${H - 24}" stroke="#e2d7bd"/>
    <path d="${path(yStaked, "staked")}" fill="none" stroke="#1c2d33" stroke-width="1.3" opacity="0.75"/>
    <path d="${path(yStreaks, "streaks")}" fill="none" stroke="#2fb3c7" stroke-width="2"/>
    <text x="${PAD}" y="14" fill="#1a8fa1" font-size="10" font-weight="600">Peak: ${maxStreaks} active stick${maxStreaks === 1 ? "" : "s"}</text>
    <text x="${W - 10}" y="14" fill="#1c2d33" font-size="10" font-weight="600" text-anchor="end">Peak: ${formatUnits(maxStaked, 18, 2)} ${esc(info.stSymbol)} stuck</text>
    <text x="${PAD - 6}" y="${H - 21}" fill="#64808a" font-size="10" text-anchor="end">0</text>
    <text x="${PAD}" y="${H - 8}" fill="#64808a" font-size="10">${date(t0)}</text>
    <text x="${W - 10}" y="${H - 8}" fill="#64808a" font-size="10" text-anchor="end">now</text>
    <g id="chart-hover" style="display:none;pointer-events:none">
      <line id="chart-hover-line" y1="20" y2="${H - 24}" stroke="#64808a" stroke-width="1" stroke-dasharray="3 3"/>
      <circle id="chart-hover-streaks" r="4" fill="#fdffff" stroke="#2fb3c7" stroke-width="2"/>
      <circle id="chart-hover-locked" r="4" fill="#fdffff" stroke="#1c2d33" stroke-width="2"/>
      <g id="chart-hover-card">
        <rect width="154" height="57" rx="4" fill="#fdffff" stroke="#d8e7eb"/>
        <text id="chart-hover-date" x="9" y="15" fill="#64808a" font-size="9" font-weight="700"></text>
        <rect x="9" y="24" width="7" height="7" rx="1" fill="#2fb3c7"/>
        <text id="chart-hover-streaks-value" x="22" y="31" fill="#1c2d33" font-size="10"></text>
        <rect x="9" y="41" width="7" height="7" rx="1" fill="#1c2d33"/>
        <text id="chart-hover-locked-value" x="22" y="48" fill="#1c2d33" font-size="10"></text>
      </g>
    </g>
  </svg>`;

  return {
    svg,
    bind(container) {
      const chart = container.querySelector("svg");
      const hover = chart.querySelector("#chart-hover");
      const line = chart.querySelector("#chart-hover-line");
      const streakDot = chart.querySelector("#chart-hover-streaks");
      const lockedDot = chart.querySelector("#chart-hover-locked");
      const card = chart.querySelector("#chart-hover-card");
      const dateLabel = chart.querySelector("#chart-hover-date");
      const streaksLabel = chart.querySelector("#chart-hover-streaks-value");
      const lockedLabel = chart.querySelector("#chart-hover-locked-value");
      const plotRight = W - 10;

      const showAt = (chartX) => {
        const cx = Math.min(plotRight, Math.max(PAD, chartX));
        const ts = t0 + ((cx - PAD) / (plotRight - PAD)) * span;
        let point = points[0];
        for (const candidate of points) {
          if (candidate.ts > ts) break;
          point = candidate;
        }

        const streakY = yStreaks(point.streaks);
        const lockedY = yStaked(point.staked);
        line.setAttribute("x1", cx); line.setAttribute("x2", cx);
        streakDot.setAttribute("cx", cx); streakDot.setAttribute("cy", streakY);
        lockedDot.setAttribute("cx", cx); lockedDot.setAttribute("cy", lockedY);

        const cardX = cx > W - 172 ? cx - 162 : cx + 8;
        card.setAttribute("transform", `translate(${cardX} 25)`);
        dateLabel.textContent = date(ts);
        streaksLabel.textContent = `${point.streaks} active stick${point.streaks === 1 ? "" : "s"}`;
        lockedLabel.textContent = `${formatUnits(point.staked, 18, 2)} ${info.stSymbol}`;
        chart.setAttribute("aria-label", `${date(ts)}: ${streaksLabel.textContent}; ${lockedLabel.textContent}`);
        hover.style.display = "";
      };

      chart.onpointermove = (event) => {
        const box = chart.getBoundingClientRect();
        showAt(((event.clientX - box.left) / box.width) * W);
      };
      chart.onpointerleave = () => { hover.style.display = "none"; };
      chart.onfocus = () => { showAt(plotRight); };
      chart.onblur = () => { hover.style.display = "none"; };
    },
  };
}

// ------------------------------------------------------------------ svg pie
function pieSvg(active, symbol, tokenSupply) {
  const total = active.reduce((sum, row) => sum + row.staked, 0n);
  if (total === 0n) return { svg: `<p class="mut">nobody is stuck yet</p>` };
  const totalPercent = tokenSupply > 0n ? Number((total * 1_000_000n) / tokenSupply) / 10_000 : 0;
  const R = 56;
  const C = 2 * Math.PI * R;
  const gap = active.length > 1 ? 1.5 : 0;
  let offset = 0;
  const segments = active.map((row, i) => {
    const share = Number((row.staked * 10_000n) / total) / 10_000;
    const percent = Number((row.staked * 1_000_000n) / total) / 10_000;
    const self = row.holder.toLowerCase() === (account() || "").toLowerCase() ? ", you" : "";
    const label = `${shortAddr(row.holder)}${self}: ${formatUnits(row.staked, 18)} ${symbol}, ${percent.toFixed(2)}%`;
    const length = Math.max(share * C - gap, 0.5);
    const seg = `<circle class="owner-pie-slice" data-pie-index="${i}" r="${R}" cx="70" cy="70" fill="none"
      stroke="var(--amber)" stroke-width="22" stroke-dasharray="${length.toFixed(2)} ${C.toFixed(2)}"
      stroke-dashoffset="${(-offset * C).toFixed(2)}" transform="rotate(-90 70 70)"
      tabindex="0" role="img" aria-label="${esc(label)}"/>`;
    offset += share;
    return seg;
  });
  const svg = `<div class="owner-pie-chart"><svg width="190" height="190" viewBox="0 0 140 140"
    aria-label="Owner distribution"><circle class="owner-pie-track" r="56" cx="70" cy="70" fill="none" stroke-width="22"/>
    ${segments.join("")}<g class="owner-pie-label" aria-hidden="true">
      <text class="owner-pie-wallet" x="70" y="60"></text>
      <text class="owner-pie-balance" x="70" y="77"></text>
      <text class="owner-pie-percent" x="70" y="94"></text>
    </g></svg><div class="owner-pie-total"><b>${formatUnits(total, 18)}</b> ${esc(symbol)}
      <span class="owner-pie-separator" aria-hidden="true">|</span> <b>${totalPercent.toFixed(2)}%</b> of all ${esc(symbol)}</div>
    <span class="sr-only owner-pie-live" aria-live="polite"></span></div>`;

  return {
    svg,
    bind(root) {
      const slices = [...root.querySelectorAll(".owner-pie-slice")];
      const walletLabel = root.querySelector(".owner-pie-wallet");
      const balanceLabel = root.querySelector(".owner-pie-balance");
      const percentLabel = root.querySelector(".owner-pie-percent");
      const live = root.querySelector(".owner-pie-live");

      const show = (i) => {
        const row = active[i];
        if (!row) return;
        const percent = Number((row.staked * 1_000_000n) / total) / 10_000;
        const self = row.holder.toLowerCase() === (account() || "").toLowerCase() ? " (you)" : "";
        const amount = `${formatUnits(row.staked, 18)} ${symbol}`;
        walletLabel.textContent = `${shortAddr(row.holder)}${self}`;
        balanceLabel.textContent = amount;
        percentLabel.textContent = `${percent.toFixed(2)}%`;
        live.textContent = `${shortAddr(row.holder)}${self}, ${amount}, ${percent.toFixed(2)} percent`;
        slices.forEach((slice, index) => slice.classList.toggle("active", index === i));
        for (const tableRow of document.querySelectorAll("#leaderboard tr[data-owner]")) {
          tableRow.classList.toggle("pie-active", tableRow.dataset.owner === row.holder.toLowerCase());
        }
      };
      const clear = () => {
        walletLabel.textContent = "";
        balanceLabel.textContent = "";
        percentLabel.textContent = "";
        slices.forEach((slice) => slice.classList.remove("active"));
        for (const tableRow of document.querySelectorAll("#leaderboard tr.pie-active")) tableRow.classList.remove("pie-active");
      };

      slices.forEach((slice, i) => {
        slice.onpointerenter = () => show(i);
        slice.onfocus = () => show(i);
        slice.onblur = clear;
        slice.onclick = () => show(i);
      });
      root.querySelector("svg").onpointerleave = clear;
      show(0);
    },
  };
}

// ---------------------------------------------------------------------- home
// The home page lists every configured chain of one environment. A ?chain deep link picks the environment;
// without one it is the default chain's, which is production.
const isHomeRoute = () => !/^#\/(project\/|@|account\/)/.test(location.hash);
function homeEnvironment() {
  const chainId = window.__DEMO_RPC ? ctx.chainId
    : new URL(location.href).searchParams.get("chain") || window.STICKY_CONFIG?.defaultChainId || 1;
  return chainById(chainId)?.environment || "production";
}
function homeChains() {
  if (window.__DEMO_RPC) return ctx.chainId ? [ctx.chainId] : [];
  return chainsForEnvironment(homeEnvironment())
    .filter((chain) => StickyRuntime.deployment(window.STICKY_CONFIG || {}, chain.chainId).deployer)
    .map((chain) => chain.chainId);
}
const projectHref = (chainId, projectId) => Number(chainId) === ctx.chainId
  ? `#/project/${projectId}` : `?chain=${Number(chainId)}#/project/${projectId}`;
function chainIcons(chainIds) {
  const chains = chainIds.map(chainById).filter(Boolean);
  return `<span class="chain-icons" role="img" aria-label="${esc(chains.map((chain) => chain.name).join(", "))}">`
    + chains.map((chain) => `<span title="${esc(chain.name)}">${CHAIN_ICON_SVG[chain.icon]}</span>`).join("") + `</span>`;
}
// loading: placeholder lines. empty: no Sticky tokens in this environment, hero only. error: reads failed,
// hero and one line. ready: the dashboard, with a note naming any chain that could not be read.
function setHomeState(state, note = "", retry = false) {
  const home = $("view-home");
  home.dataset.state = state;
  home.setAttribute("aria-busy", String(state === "loading"));
  $("home-note-text").textContent = note;
  $("home-note").classList.toggle("hide", !note);
  $("home-retry").classList.toggle("hide", !retry);
}
function homeFailed(error) {
  console.error(error);
  setHomeState("error", "Could not read Sticky tokens.", true);
  if (!isHomeRoute()) status(error?.message || String(error), "err");
}
async function retryHome() {
  for (const id of ["home-secured-chart", "activity", "projects", "airdrops"]) $(id).innerHTML = "";
  $("home-secured-value").textContent = "–";
  setHomeState("loading");
  try {
    await renderHome();
  } catch (error) {
    homeFailed(error);
  }
}

// One chain's home data: its Sticky projects as cards, supply moves for the chart, prices, and feed items.
// Bendystraw supplies the projects and their sticks and unsticks; a chain it cannot answer for is scanned.
async function homeChainData(chainId) {
  const indexed = await indexedChain(chainId);
  if (!indexed) return scannedHomeChainData(chainId);
  let projects, events;
  try {
    projects = await deployedProjectsOn(chainId);
    events = projects.length ? await StickyRuntime.stickyEvents(bendystrawUrl(chainId),
      projects.map((project) => ({ chainId: Number(chainId), projectId: project.projectId, version: project.version ?? 6 }))) : [];
  } catch (error) {
    console.warn(`Bendystraw could not list Sticky activity on ${chainById(chainId)?.name || chainId}; scanning the chain.`, error);
    return scannedHomeChainData(chainId);
  }
  if (!projects.length) return { chainId, cards: [], moves: [], prices: new Map(), activity: [], airdrops: [] };
  const reader = await chainReader(chainId);
  const cards = await homeCards(reader, projects.map((project) => project.projectId), (id) => indexedHolderCount(id, events));
  const [prices, activity, airdrops] = await Promise.all([
    backingUsdPrices(cards, reader.chainId), indexedActivityItems(events, reader), indexedAirdropItems(events, reader),
  ]);
  return { chainId, cards, moves: eventMoves(events), prices, activity, airdrops };
}

// The chain-only path: every DeploySticky from the deployment block, then every position event from the
// first launch's block.
async function scannedHomeChainData(chainId) {
  const reader = await chainReader(chainId);
  const deploys = await getLogsOn(reader, reader.deployer, [TOPIC.DeploySticky]);
  const ids = deploys.map((log) => decUint(log.topics[1]));
  if (!ids.length) return { chainId, cards: [], moves: [], prices: new Map(), activity: [], airdrops: [] };
  const logs = await attachTimestamps(await getLogsOn(reader, reader.hook, [POSITION_TOPICS, null], deploys[0].blockNumber), 6, reader);
  for (const log of logs) log.chainId = reader.chainId;
  const cards = await homeCards(reader, ids, (id) => holderRows(id, logs).filter((row) => row.staked > 0n).length);
  const [prices, activity, airdrops] = await Promise.all([
    backingUsdPrices(cards, reader.chainId), activityItems(logs, true, reader), airdropItems(logs, reader),
  ]);
  return { chainId, cards, moves: logMoves(logs), prices, activity, airdrops };
}

// Cards read backing and supply from the chain. A project that fails to read is left out; a chain whose
// projects all fail is an error.
async function homeCards(reader, ids, sticksOf) {
  const cards = (await Promise.all(ids.map(async (id) => {
    try {
      const info = await projectInfo(id, reader);
      const [pool, launchId] = await Promise.all([
        poolBacking(id, info, reader),
        window.__DEMO_RPC ? null : launchIdOf(reader, id).catch(() => null),
      ]);
      return { id, chainId: reader.chainId, key: `${reader.chainId}:${id}`, info, pool, launchId, totalStaked: pool.supply, sticks: sticksOf(id) };
    } catch {
      return null;
    }
  }))).filter(Boolean);
  if (!cards.length) throw new Error(`Could not read any Sticky token on ${chainById(reader.chainId)?.name || reader.chainId}.`);
  return cards;
}

// Holders with tokens left after their sticks and unsticks. Exact for soulbound tokens; transfers of a
// transferable token are not in Bendystraw's events, so this is a count for display only.
function indexedHolderCount(projectId, events) {
  const balances = new Map();
  for (const event of events) {
    if (event.projectId !== BigInt(projectId)) continue;
    balances.set(event.holder, (balances.get(event.holder) || 0n) + (event.kind === "stick" ? event.tokens : -event.tokens));
  }
  return [...balances.values()].filter((balance) => balance > 0n).length;
}

// Sibling projects of one multichain launch share a launchId, cash out tax and transfer mode. Each chain
// contributes its first matching project, as on the project page, so a copied uri cannot join a launch.
function groupHomeCards(cards) {
  const groups = [];
  const byLaunch = new Map();
  for (const card of cards) {
    const key = card.launchId ? `${card.launchId}:${card.info.reward}:${Boolean(card.info.soulbound)}` : null;
    const group = key ? byLaunch.get(key) : null;
    if (group && !group.cards.some((other) => other.chainId === card.chainId)) {
      group.cards.push(card);
      group.totalStaked += card.totalStaked;
      continue;
    }
    const fresh = { cards: [card], totalStaked: card.totalStaked };
    if (key && !group) byLaunch.set(key, fresh);
    groups.push(fresh);
  }
  return groups.sort((a, b) => (b.totalStaked > a.totalStaked ? 1 : b.totalStaked < a.totalStaked ? -1 : 0));
}

function stickiestCardHtml(group, rank) {
  const [first] = group.cards;
  const decimals = (card) => card.info.decimals ?? 18;
  const amount = (card) => card.pool?.sigma ?? card.totalStaked;
  const same = group.cards.every((card) => card.info.symbol === first.info.symbol && decimals(card) === decimals(first));
  const backing = same
    ? `${formatUnits(group.cards.reduce((sum, card) => sum + amount(card), 0n), decimals(first))} ${esc(first.info.symbol)}`
    : group.cards.map((card) => `${formatUnits(amount(card), decimals(card))} ${esc(card.info.symbol)}`).join(", ");
  const sticks = group.cards.reduce((sum, card) => sum + card.sticks, 0);
  const tag = first.demo ? "div" : "a";
  const chains = first.demo ? "" : ` ${chainIcons(group.cards.map((card) => card.chainId))}`;
  const id = group.cards.length === 1 ? ` <span class="mut">#${first.id}</span>` : "";
  return `<${tag} class="card-item${first.demo ? "" : " pickc"}"${first.demo ? "" : ` href="${projectHref(first.chainId, first.id)}"`}><div class="card-head">`
    + `<span class="rank">${rank}</span>${tokenLogo(first.info.stakedToken, first.info.symbol, 26, first.chainId)}`
    + `<div style="flex:1;min-width:0"><div style="font-weight:700">${esc(stickyLabel(first.info))}${id}${chains}</div>`
    + `<div class="kv"><span class="mut">Backing:</span> ${backing}</div>`
    + `<div class="kv"><span class="mut">Sticks:</span> ${sticks}</div>`
    + `<div class="kv"><span class="mut">Bonus:</span> ${pct(first.info.reward)}</div>`
    + `</div></div></${tag}>`;
}

// Chains load in parallel and the dashboard redraws as each arrives. A chain that fails is named in the
// note; it never blanks the chains that loaded.
async function renderHome() {
  const sequence = ++viewSequence;
  const current = () => sequence === viewSequence;
  clearHomeSecuredChart();
  $("view-home").classList.remove("hide");
  $("view-project").classList.add("hide");
  if (window.__DEMO_RPC && !ctx.loaded) return;
  if ($("view-home").dataset.state !== "ready") setHomeState("loading");

  const chains = homeChains();
  const testnet = homeEnvironment() === "testnet";
  if (!chains.length) {
    setHomeState("error", testnet ? "Sticky is not on testnets yet." : "Sticky is not deployed yet.");
    return;
  }
  const results = new Map();
  const demoCards = configuredStickiestCards();
  const demoAirdrops = await configuredAirdropItems();
  if (!current()) return;
  const paint = () => {
    const loaded = chains.map((chainId) => results.get(chainId)).filter((result) => result && !result.error);
    const failed = chains.filter((chainId) => results.get(chainId)?.error);
    const pending = chains.length - results.size;
    const failedNote = failed.length
      ? `Could not read Sticky tokens on ${failed.map((chainId) => chainById(chainId)?.name || chainId).join(", ")}.` : "";
    const cards = loaded.flatMap((result) => result.cards);
    if (!cards.length && !demoCards.length) {
      if (pending) return;
      if (failed.length) setHomeState("error", failed.length === chains.length ? "Could not read Sticky tokens." : failedNote, true);
      else setHomeState("empty", testnet ? "No sticky tokens on testnets yet." : "No sticky tokens yet.");
      return;
    }
    const moves = loaded.flatMap((result) => result.moves);
    const prices = new Map(loaded.flatMap((result) => [...result.prices]));
    mountHomeSecuredChart(homeSecuredSeries(moves, cards, prices));
    const groups = [...groupHomeCards(cards), ...demoCards.map((card) => ({ cards: [card], totalStaked: card.totalStaked }))];
    $("projects").innerHTML = groups.map((group, i) => stickiestCardHtml(group, i + 1)).join("");
    const newest = (items) => items.sort((a, b) => b.ts - a.ts).slice(0, 40);
    renderFeed($("activity"), newest(loaded.flatMap((result) => result.activity)));
    renderFeed($("airdrops"), [...newest(loaded.flatMap((result) => result.airdrops)), ...demoAirdrops], "no airdrops yet");
    setHomeState("ready", failedNote, failed.length > 0);
    hydrateLogos().catch(() => {});
  };
  await Promise.all(chains.map(async (chainId) => {
    let result;
    try {
      result = await homeChainData(chainId);
    } catch (error) {
      console.error(error);
      result = { chainId, error };
    }
    if (!current()) return;
    results.set(chainId, result);
    paint();
  }));
}

// ------------------------------------------------------------------- project
async function renderProject(projectId) {
  if (!ctx.loaded) return;
  ++viewSequence;
  clearHomeSecuredChart();
  const changed = ctx.currentId !== projectId;
  ctx.currentId = projectId;
  ctx.pool = null;
  const current = currentView();
  // A different project never shows the last one's details, board, or feed while its own load.
  if (changed) {
    $("p-details-card").classList.add("hide");
    $("p-chains-card").classList.add("hide");
    for (const id of ["token-info", "p-activity", "leaderboard", "pie"]) $(id).innerHTML = "";
  }
  $("view-home").classList.add("hide");
  $("view-project").classList.remove("hide");
  // A verified handle stays in the address bar while tabs change and across post-transaction refreshes.
  const projectRoute = ctx.alias ? `#/${ctx.alias}` : `#/project/${projectId}`;
  $("tab-btn-overview").href = projectRoute;
  $("tab-btn-owners").href = `${projectRoute}/tokens`;
  $("tab-btn-rewards").href = `${projectRoute}/airdrops`;

  const info = await projectInfo(projectId);
  if (!current()) return;
  syncTransferSticky(info);
  $("p-logo").innerHTML = tokenLogo(info.stakedToken, info.symbol, 104);
  $("h-symbol").textContent = stickyLabel(info);
  $("h-name").textContent = window.STICKY_CONFIG?.projectNameOverrides?.[String(projectId)] || info.stName;
  $("tranches-amount-head").textContent = `AMOUNT (${info.stSymbol})`;
  $("stake-title").textContent = `Stick ${info.symbol}`;
  $("stake-symbol").textContent = info.symbol;
  $("unstake-symbol").textContent = info.stSymbol;
  $("unstake-hint").textContent = info.reward > 0n
    ? `Newest tokens unstick first, and up to ${pct(info.reward)} stays behind for remaining holders.`
    : "Newest tokens unstick first.";

  ctx.projectLogs = null;
  const scanned = await projectLogs(projectId);
  if (!current()) return;
  const logs = scanned.position;
  const pin = await pinnedBlock();
  if (!current()) return;
  const rows = holderRows(projectId, logs, pin.timestamp);
  ctx.streakRows = { chainId: ctx.chainId, projectId, rows };
  const pool = await poolBacking(projectId, info);
  if (!current()) return;
  const totalStaked = pool.supply;
  ctx.pool = pool;
  renderUnstickQuote();
  renderStickQuote();
  $("p-bonus-card").classList.toggle("hide", info.reward === 0n);
  if (info.reward > 0n) {
    const rho0 = pool.supply > 0n ? Number((pool.sigma * 10n ** 18n) / pool.supply) / 10 ** info.decimals : 1;
    $("p-bonus-blurb").textContent =
      `Unsticks leave up to ${pct(info.reward)} behind for holders who stay.`
      + (rho0 > 1.0005 ? ` 1 ${info.stSymbol} is currently backed by ${parseFloat(rho0.toFixed(4))} ${info.symbol}.` : "");
    renderBonusSplit(Number(info.reward) / 10000, {
      el: $("p-ratchet"),
      rho0,
      sym: info.symbol,
      stSym: info.stSymbol,
    });
  }
  const active = rows.filter((row) => row.staked > 0n).sort((a, b) => (b.staked > a.staked ? 1 : -1));
  $("h-staked").textContent = `${formatUnits(totalStaked, 18)} ${info.stSymbol}`;
  $("h-streakers").textContent = active.length;
  renderHeaderAges(rows, pin.timestamp);
  const projectChains = await projectChainIds(projectId);
  if (!current()) return;
  renderProjectChains(projectChains);
  renderSiblings(projectId, info, current).catch(() => {});

  // OVERVIEW: chart + my position.
  const chart = chartSvg(logs, info, projectId);
  $("chart").innerHTML = chart.svg;
  chart.bind?.($("chart"));
  // The holder's position loads on its own; Details, the board and Latest never wait on it.
  refreshPosition().catch((error) => { if (current()) status(error.message, "err"); });

  // OWNERS: token info, pie, leaderboard.
  const granters = [...new Set(scanned.all.filter((log) => log.topics[0] === TOPIC.SetGranter).map((log) => decAddress(log.topics[2])))];
  const transferMode = info.soulbound ? "No" : "Yes";
  const transferRule = info.soulbound
    ? "Transfers are disabled. Sticky tokens are minted by sticking. Unsticking burns them; a voluntary burn returns no backing."
    : "Transfers move the sender's newest tranches first. The recipient receives a fresh tranche; existing streaks keep running unless the sender transfers everything.";
  const bonusRule = info.reward > 0n
    ? `Cash out tax is ${pct(info.reward)}. The reclaim depends on pool backing and the portion of total supply unstuck.`
    : "Unsticking returns your proportional share of the backing with no cash out tax. Any applicable terminal fees are included in the final quote.";
  // The auto-stick adapter is presented as its own pre-approval, not as a generic airdrop sender.
  const adapterGranter = granters.some((g) => g.toLowerCase() === (autoStickAdapter() || "").toLowerCase());
  const humanGranters = granters.filter((g) => g.toLowerCase() !== (autoStickAdapter() || "").toLowerCase());
  const senderRule = "Anyone can stick for themselves. "
    + (humanGranters.length
      ? `${humanGranters.length} permanent airdrop sender${humanGranters.length === 1 ? " is" : "s are"} approved for every holder. `
      : "")
    + (adapterGranter ? "Auto-stick is available. Holders turn it on with an allowance and settings. " : "")
    + "Holders can also approve trusted senders to stick for them.";
  const meta = (label, value, title = "") =>
    `<span class="token-meta"${title ? ` title="${esc(title)}"` : ""}><b>${label}:</b><span>${value}</span></span>`;
  const copySymbol = (symbol, address) =>
    `<button type="button" class="token-copy" data-address="${address}" data-copy-address="${address}" `
      + `aria-label="Copy ${esc(symbol)} token address">${esc(symbol)}</button>`;
  $("p-details-card").classList.remove("hide");
  $("token-info").innerHTML =
    `<div class="token-meta-row">`
      + meta("Token", `${esc(info.stName)} (${copySymbol(info.stSymbol, info.stToken)})`)
      + `</div>`
    + `<div class="token-meta-row">`
      + meta("Sticks", `${esc(info.name)} (${copySymbol(info.symbol, info.stakedToken)})`)
      + meta("Sticky supply", `${formatUnits(totalStaked, 18)} ${copySymbol(info.stSymbol, info.stToken)}`)
      + meta("Pool backing", `${formatUnits(pool.sigma, info.decimals)} ${copySymbol(info.symbol, info.stakedToken)}`)
      + (pool.orphaned > 0n ? meta("Unowned backing", `${formatUnits(pool.orphaned, info.decimals)} ${esc(info.symbol)}`,
        "Funds left when no Sticky shares existed are excluded from issuance and redemption; a new depositor cannot claim them.") : "")
      + meta("Stickiness bonus", pct(info.reward), bonusRule)
      + (pool.supply > 0n
        ? meta(
            "Backing",
            `1 ${esc(info.stSymbol)} ≈ ${formatUnits((pool.sigma * 10n ** 18n) / pool.supply, info.decimals)} ${esc(info.symbol)}`,
            "New sticks are priced against current backing. Donations, burns, and cash out taxes can change the number of Sticky tokens issued per underlying token.",
          )
        : "")
      + meta("Transferable", transferMode, transferRule)
      + `</div>`
    + `<details class="token-contracts"><summary>Rules &amp; contracts</summary>`
      + `<div class="token-contract-grid">`
        + `<div><b>STICKY TOKEN CONTRACT</b><span>${info.stToken}</span></div>`
        + `<div><b>${esc(info.symbol)} TOKEN CONTRACT</b><span>${info.stakedToken}</span></div>`
        + `<div><b>STICK ACCOUNTING CONTRACT</b><span>${ctx.hook}</span></div>`
        + `<div><b>UNSTICKING</b><span>${bonusRule}</span></div>`
        + `<div><b>TRANSFERS</b><span>${transferRule}</span></div>`
        + `<div><b>WHO CAN ADD STAKE</b><span>${senderRule}</span></div>`
      + `</div></details>`;
  for (const copy of $("token-info").querySelectorAll("[data-copy-address]")) {
    copy.onclick = guard(async () => {
      await navigator.clipboard.writeText(copy.dataset.copyAddress);
      inlineStatus(copy, `${copy.textContent} address copied.`, "ok");
    });
  }

  const pie = pieSvg(active, info.stSymbol, totalStaked);
  $("pie").innerHTML = pie.svg;
  ctx.board = { rows: active, symbol: info.stSymbol, total: totalStaked, projectId, page: 0 };
  renderBoard();
  pie.bind?.($("pie"));

  $("r-token").value ||= info.stakedToken;
  renderRewards().catch(() => {});
  const activity = await activityItems(logs, false);
  if (!current()) return;
  renderFeed($("p-activity"), activity);
  hydrateLogos().catch(() => {});
}

let positionSequence = 0;
async function refreshPosition() {
  const request = ++positionSequence;
  if (ctx.currentId === null || !account()) return;
  const projectId = ctx.currentId, holder = account(), chainId = ctx.chainId;
  const info = await projectInfo(projectId);
  if (request !== positionSequence || ctx.currentId !== projectId || ctx.chainId !== chainId || account() !== holder) return;
  const pageKey = `${chainId}:${projectId}:${holder.toLowerCase()}`;
  if (ctx.tranchePageKey !== pageKey) { ctx.tranchePageKey = pageKey; ctx.tranchePage = 0n; }
  const args = word(projectId) + encAddress(holder);
  const pin = await pinnedBlock();
  const at = (to, data) => rpc("eth_call", [{ to, data }, pin.tag]);
  const [staked, streakStart, longest, wallet, tranchePage] = await Promise.all([
    at(info.stToken, SEL.balanceOf + encAddress(holder)).then(decUint),
    at(ctx.hook, SEL.streakStartOf + args).then(decUint),
    at(ctx.hook, SEL.longestStreakOf + args).then(decUint),
    at(info.stakedToken, SEL.balanceOf + encAddress(holder)).then(decUint),
    readTranchePage(projectId, holder, ctx.tranchePage, pin.tag),
  ]);
  if (request !== positionSequence || ctx.currentId !== projectId || ctx.chainId !== chainId || account() !== holder) return;
  const { tranches, total, page, start } = tranchePage;
  ctx.tranchePage = page;
  const now = pin.timestamp;
  const current = streakStart === 0n ? 0n : BigInt(Math.max(0, now - Number(streakStart)));
  const header = ctx.streakRows;
  if (header?.chainId === chainId && header.projectId === projectId) renderHeaderAges(header.rows, now);
  $("p-balance").textContent = `${formatUnits(staked, 18)} ${info.stSymbol}`;
  $("p-current").textContent = formatDuration(current);
  $("p-longest").textContent = formatDuration(longest > current ? longest : current);
  $("p-wallet").textContent = `${formatUnits(wallet, info.decimals)} ${info.symbol}`;
  $("open-unstick").textContent = `Unstick ${info.symbol}`;
  ctx.walletMax = formatUnits(wallet, info.decimals, info.decimals);
  // Full precision so "max" truly unsticks everything (and the full-exit auto-stick check sees a full exit).
  ctx.stakedMax = formatUnits(staked, 18, 18);
  $("stake-balance").textContent = ctx.walletMax;
  $("stake-balance-label").textContent = ` ${info.symbol} in wallet`;
  renderTrustedSenders().catch(() => {});
  const tbody = $("tranches");
  tbody.innerHTML = "";
  tranches.forEach((tranche) => {
    const row = document.createElement("tr");
    const stuckSince = new Date(tranche.timestamp * 1000).toLocaleString(undefined, {
      month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit",
    });
    row.innerHTML = `<td>${formatUnits(tranche.amount, 18)}</td>` +
      `<td>${stuckSince}</td>` +
      `<td>${formatDuration(Math.max(0, now - tranche.timestamp))}</td>`;
    tbody.appendChild(row);
  });
  $("tranches-page").textContent = total === 0n ? "No active tranches" : `Tranches ${start + 1n}–${start + BigInt(tranches.length)} of ${total}`;
  $("tranches-newer").disabled = page === 0n;
  $("tranches-older").disabled = start === 0n;
  $("tranches-pagination").classList.toggle("hide", total <= 50n);
}

// Never fetch an unbounded holder array: incoming dust must not prevent the account page or exit controls loading.
// Pin count and slice to one block so a concurrent burn cannot shift the range between these reads.
async function readTranchePage(projectId, holder, requestedPage = 0n, pinned = null) {
  const hook = ctx.hook;
  const block = pinned || await rpc("eth_blockNumber", []);
  if (!/^0x[0-9a-fA-F]+$/.test(block || "") && block !== "latest") throw new Error("The RPC returned an invalid tranche block.");
  const args = word(projectId) + encAddress(holder);
  const read = (selector, tail = "") => rpc("eth_call", [{ to: hook, data: selector + args + tail }, block]);
  const total = decUint(await read(SEL.trancheCountOf));
  if (total === 0n) return { tranches: [], total, page: 0n, start: 0n };
  const lastPage = (total - 1n) / 50n;
  const page = requestedPage < 0n ? 0n : requestedPage > lastPage ? lastPage : requestedPage;
  const end = total - page * 50n;
  const start = end > 50n ? end - 50n : 0n;
  const tranches = decTranches(await read(SEL.tranchesRangeOf, word(start) + word(end - start)));
  if (BigInt(tranches.length) !== end - start) throw new Error("The RPC returned an incomplete tranche page.");
  return { tranches, total, page, start };
}

// ---------------------------------------------------------- confirm dialog
function contractNameOf(addr) {
  const lower = addr.toLowerCase();
  if (lower === ctx.terminal?.toLowerCase()) return "JBMultiTerminal";
  if (lower === $("deployer").value.toLowerCase()) return "StickyDeployer";
  if (lower === ctx.hook?.toLowerCase()) return "StickyHook";
  if (lower === distributor()?.toLowerCase()) return "StickyDistributor";
  if (lower === autoStickAdapter()?.toLowerCase()) return "StickyAutoStick";
  if (lower === window.STICKY_CONFIG?.rewardReceiverFactory?.toLowerCase()) return "StickyRewardReceiverFactory";
  for (const info of Object.values(ctx.projects)) {
    if (lower === info.stakedToken.toLowerCase()) return `the ${info.symbol} token`;
    if (lower === info.stToken.toLowerCase()) return `the ${info.stSymbol} token`;
  }
  return "an unrecognized contract";
}

let confirmResolve = null;
// Why the reviewed plan cannot be sent, or "" when every step decoded and matched its review.
let confirmBlocked = "";
// Dialogs the review replaced; they come back when the review closes without completing.
let confirmReturnTo = [];
let confirmCompleted = false;
let confirmPlan = [];
let confirmSummary = [];
let confirmSession = null;
let confirmProgress = -1;
let txRunCancelled = false;
// Non-transaction steps shown before the transactions, like signing the launch listing.
let confirmPreSteps = [];
// A sponsored review: Juicebox Center sends the reviewed calls, the wallet only signs the listing.
let confirmSponsored = false;

const transactionsLeft = (count) => `${count} transaction${count === 1 ? "" : "s"} left`;
// Review values wrap at spaces; only addresses and hex may break anywhere.
// A value is a string, or { text, title } to shorten an address and keep it in the tooltip.
function reviewValue(value) {
  const text = typeof value === "object" && value !== null ? value.text : String(value);
  const html = esc(text).replace(/0x[0-9a-fA-F]{16,}/g, (hex) => `<span class="hexv">${hex}</span>`);
  return value?.title ? `<span title="${esc(value.title)}">${html}</span>` : html;
}

function renderConfirmSteps() {
  const card = $("cd-steps");
  card.classList.remove("hide");
  const steps = confirmSession?.steps || confirmPlan.map((tx) => ({ tx, state: "ready" }));
  const labels = {
    ready: confirmSponsored ? "Juicebox Center sends this" : "Ready for review", rejected: "Cancelled in wallet", submitting: "Waiting for wallet",
    pending: "Checking execution", unknown: "Execution hash needed", reverted: "Reverted and finalized", confirmed: "Confirmed",
  };
  const done = steps.filter((step) => step.state === "confirmed").length;
  const uncertain = steps.some((step) => ["submitting", "pending", "unknown"].includes(step.state));
  const intro = confirmSponsored ? "Juicebox Center sends these after you sign the listing."
    : done === steps.length ? "All transactions confirmed."
    : uncertain ? "The submitted step will be checked before any remaining transaction is sent."
      : `${transactionsLeft(steps.length - done)}. Confirmed steps will not be repeated.`;
  const offset = confirmPreSteps.length;
  card.innerHTML = `<p>${esc(intro)}</p>` + confirmPreSteps.map((step, i) =>
    `<div class="cd-step ${step.state}"><i>${step.state === "done" ? "✓" : i + 1}</i><span>${esc(step.label)}<br><small>${esc(step.note)}</small></span></div>`,
  ).join("") + steps.map((step, i) => {
    const state = step.state === "confirmed" ? "done" : ["pending", "submitting", "unknown"].includes(step.state) ? "current" : "pending";
    const chain = chainById(step.tx.chainId);
    const reference = step.hash ? ` <span class="mut">${esc(step.hash.slice(0, 12))}…</span>` : "";
    const link = step.hash && chain?.explorer ? ` <a href="${esc(chain.explorer)}/tx/${esc(step.hash)}" target="_blank" rel="noopener noreferrer">View</a>` : "";
    return `<div class="cd-step ${state}"><i>${state === "done" ? "✓" : offset + i + 1}</i><span>${esc(step.tx.label)}<br><small>${esc(labels[step.state])}${reference}${link}</small></span></div>`;
  }).join("");
  const recovery = $("cd-recovery");
  if (recovery) recovery.classList.toggle("hide", !uncertain);
}

// Every row a transaction shows comes from its decoded calldata and value, never from the builder's inputs.
// A step whose calldata cannot be decoded, or disagrees with its review, blocks the whole plan.
function reviewedRows(tx) {
  const { rows, decoded } = StickyCalldata.review(tx);
  const from = tx.from || txAccount();
  const value = BigInt(tx.value || 0);
  const out = [["FROM", from], ...rows];
  if (value > 0n) out.push(["VALUE", `${formatUnits(value, 18, 18)} ETH${tx.valueNote ? ` (${tx.valueNote})` : ""}`]);
  return { rows: out, decoded };
}

function renderConfirm() {
  $("cd-summary").innerHTML = confirmSummary
    .map(([k, v]) => `<div class="cd-summary-row"><span class="k">${esc(k)}</span><span class="v">${esc(String(v))}</span></div>`)
    .join("");
  renderConfirmSteps();
  confirmBlocked = "";
  const multiple = confirmPlan.length > 1;
  $("cd-body").innerHTML = confirmPlan
    .map((tx, i) => {
      const chain = tx.chainLabel || chainById(tx.chainId ?? ctx.chainId)?.label || "";
      const step = multiple ? `${i + 1}. ` : "";
      let reviewed = null, problem = "";
      try { reviewed = reviewedRows(tx); } catch (error) {
        problem = error instanceof StickyCalldata.CalldataError ? error.message : `This transaction could not be checked: ${error.message}`;
        confirmBlocked ||= multiple ? `Step ${i + 1}: ${problem}` : problem;
      }
      const fn = reviewed ? reviewed.decoded.canonical : tx.fn;
      return `<div class="txstep">`
        + (chain ? `<div class="cd-chain">${esc(chain)}</div>` : "")
        + `<div class="cd-contract"><b>${esc(tx.contractName || contractNameOf(tx.to))}</b> | ${esc(tx.to)}</div>`
        + `<h3>${step}${esc(tx.label)}</h3>`
        + (problem ? `<p class="cd-block" role="alert">${esc(problem)}</p>` : "")
        + (reviewed ? `<table><tbody>`
          + reviewed.rows.map(([k, v]) => `<tr><th style="width:104px">${esc(k)}</th><td>${reviewValue(v)}</td></tr>`).join("")
          + `</tbody></table>` : "")
        + `<details class="cd-raw"><summary>Show raw data</summary>`
        + `<div class="rawbox">function: ${esc(fn)}\nfrom: ${esc(tx.from || txAccount())}\nto: ${tx.to}\nvalue: ${tx.value ? BigInt(tx.value) : 0} wei\ndata: ${tx.data}</div></details>`
        + `</div>`;
    })
    .join("");
  $("cd-warn").textContent = confirmBlocked
    ? "Sending is blocked. The transaction data does not match this review."
    : confirmSponsored ? "Every row is read back from the exact data Juicebox Center will send. You only sign the listing."
    : multiple
      ? "Every row is read back from the exact data your wallet will sign. Nothing is signed until you confirm each one."
      : "Every row is read back from the exact data your wallet will sign. Nothing is signed until you confirm.";
  $("cd-warn").classList.toggle("err", Boolean(confirmBlocked));
  $("cd-confirm").disabled = Boolean(confirmBlocked);
}

// Show the consent dialog for a transaction plan. Resolves true only if the user confirms.
// `summary` is optional plain-language rows shown above the sequence, e.g. [["Stick", "10 ART"]].
function confirmTxs(title, txs, summary = [], { sponsored = false } = {}) {
  if (confirmResolve) throw new Error("Finish the current transaction review first.");
  confirmSponsored = sponsored;
  confirmPlan = txs;
  confirmSummary = summary;
  confirmProgress = -1;
  confirmCompleted = false;
  $("cd-title").textContent = title;
  $("cd-confirm").disabled = false;
  $("cd-confirm").textContent = sponsored ? "Sign listing"
    : confirmSession?.steps.some((step) => ["submitting", "pending", "unknown"].includes(step.state))
    ? "Check transaction" : "Confirm & send";
  $("cd-cancel").classList.remove("hide");
  $("cd-cancel").textContent = "Cancel";
  $("confirm-dialog").querySelectorAll(".inline-status").forEach((notice) => notice.remove());
  renderConfirm();
  const answer = new Promise((resolve) => { confirmResolve = resolve; });
  if (!$("confirm-dialog").open) {
    replaceOpenDialogs();
    $("confirm-dialog").showModal();
  }
  return answer;
}

// Dialogs replace each other: the review closes the dialog it came from and brings it back if cancelled.
function replaceOpenDialogs() {
  const open = [...document.querySelectorAll("dialog[open]")].filter((dialog) => dialog.id !== "confirm-dialog");
  for (const dialog of open) { try { dialog.close(); } catch {} }
  confirmReturnTo = [...new Set([...confirmReturnTo, ...open])];
}
function restoreReplacedDialogs() {
  const back = confirmReturnTo;
  confirmReturnTo = [];
  if (confirmCompleted) return;
  for (const dialog of back) if (dialog.isConnected && !dialog.open) dialog.showModal();
}

function settleConfirm(ok) {
  if (ok && confirmBlocked) {
    inlineStatus($("cd-confirm"), confirmBlocked, "err");
    return;
  }
  if (!ok) {
    txRunCancelled = true;
    try { $("confirm-dialog").close(); } catch {}
  }
  const resolve = confirmResolve;
  confirmResolve = null;
  if (resolve) {
    if (ok) {
      $("cd-confirm").disabled = true;
      $("cd-cancel").textContent = "Close";
    }
    resolve(ok);
  }
}

async function runSavedTransactions(session, originalTxs, hooks = {}) {
  txRunCancelled = false;
  confirmSession = session;
  try {
    const result = await getTxEngine().run({
      sessionId: session.id,
      review: async (saved) => {
        confirmSession = saved;
        const ok = await confirmTxs(saved.title, saved.steps.map((step) => step.tx), saved.summary);
        // Runs after consent and before the first transaction is sent. False sends nothing.
        if (ok && hooks.afterReview) return (await hooks.afterReview()) !== false;
        return ok;
      },
      shouldContinue: () => !txRunCancelled,
    });
    confirmSession = result.session;
    if (originalTxs) result.session.steps.forEach((step, index) => { originalTxs[index].receipt = step.receipt; });
    if (result.cancelled) {
      // Closed before anything was sent: no saved plan, no banner.
      await getTxEngine().discardIfUnsent(result.session.id).catch(() => {});
      return false;
    }
    confirmProgress = result.session.steps.length;
    renderConfirmSteps();
    confirmCompleted = true;
    try { $("confirm-dialog").close(); } catch {}
    renderTxRecovery(result.session);
    return true;
  } catch (error) {
    $("cd-confirm").disabled = false;
    $("cd-confirm").textContent = "Resume saved plan";
    $("cd-cancel").classList.remove("hide");
    $("cd-cancel").textContent = "Close";
    inlineStatus($("cd-confirm"), error.message, "err");
    try { renderTxRecovery(getTxEngine().load()); } catch {}
    throw error;
  }
}

async function confirmAndRun(title, txs, summary = [], hooks = {}) {
  const from = txAccount();
  const frozen = txs.map((tx) => {
    if (tx.from && tx.from.toLowerCase() !== from.toLowerCase()) throw new Error("The account changed while building the transaction. Review the action again.");
    return {
      ...tx, from: tx.from || from, chainId: Number(tx.chainId ?? ctx.chainId),
      rpcUrl: tx.rpcUrl || stickyDeploymentFor(tx.chainId ?? ctx.chainId).rpcUrl,
    };
  });
  const session = await getTxEngine().prepare(title, frozen, summary);
  await hooks.onPrepared?.(session);
  confirmPreSteps = hooks.preSteps || [];
  try { return await runSavedTransactions(session, txs, hooks); }
  finally { confirmPreSteps = []; }
}

async function resumeSavedTransactions() {
  const session = getTxEngine().load();
  if (!session) return;
  const result = await runSavedTransactions(session);
  if (result) {
    txStatus("Saved transactions confirmed.", "ok");
    await refreshPosition();
  }
}

function renderTxRecovery(session) {
  const banner = $("tx-recovery-banner");
  if (!banner) return;
  const pending = session?.steps.some((step) => step.state !== "confirmed");
  const tagged = session?.steps.some((step) => step.tx.sessionTag) && !session.acknowledged;
  banner.classList.toggle("hide", !pending && !tagged);
  if (!session) return;
  $("tx-recovery-label").textContent = `${session.title}: ${pending ? "saved transaction needs attention" : "payment confirmed; resume your launch"}.`;
  $("tx-recovery-resume").disabled = !!txEngine?.isBusy();
  $("tx-recovery-clear").classList.toggle("hide", tagged || session.steps.some((step) => ["submitting", "pending", "unknown"].includes(step.state)));
}

function installTxRecoveryUI() {
  const banner = document.createElement("div");
  banner.id = "tx-recovery-banner";
  banner.className = "hide";
  banner.setAttribute("role", "status");
  banner.style.cssText = "position:relative;z-index:2;margin:12px auto;padding:14px;max-width:940px;border:1px solid var(--line);border-radius:6px;background:var(--panel,#fdffff);overflow-wrap:anywhere";
  banner.innerHTML = '<span id="tx-recovery-label"></span><div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px"><button id="tx-recovery-resume">Review saved transaction</button><button id="tx-recovery-clear" class="ghost">Dismiss saved plan</button></div>';
  (document.querySelector("main") || document.body).prepend(banner);
  const recovery = document.createElement("div");
  recovery.id = "cd-recovery";
  recovery.className = "cd-steps hide";
  recovery.innerHTML = '<p>If your wallet created a proposal, wait for it to execute. Paste the final execution transaction hash to recover a transaction your wallet did not report.</p><label for="cd-execution-hash">Execution transaction hash</label><input id="cd-execution-hash" autocomplete="off" spellcheck="false" placeholder="0x…" style="width:100%;margin:8px 0"><button id="cd-recover-hash" class="ghost">Verify execution</button>';
  $("cd-body").after(recovery);
  $("tx-recovery-resume").onclick = guard(resumeSavedTransactions);
  $("tx-recovery-clear").onclick = guard(async () => { await getTxEngine().clear(); });
  $("cd-recover-hash").onclick = guard(async () => {
    if (confirmResolve) {
      settleConfirm(false);
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    const saved = await getTxEngine().recover($("cd-execution-hash").value.trim());
    confirmSession = saved;
    renderConfirmSteps();
    $("cd-confirm").textContent = "Resume saved plan";
    $("cd-confirm").disabled = false;
    if (!$("confirm-dialog").open) $("confirm-dialog").showModal();
    const reverted = saved.steps.some((step) => step.state === "reverted");
    inlineStatus($("cd-recover-hash"), reverted
      ? "The transaction reverted and is finalized. Review the saved plan before retrying or dismissing it."
      : "Execution verified. Resume the saved plan to continue.", reverted ? "err" : "ok");
  });
  try { renderTxRecovery(getTxEngine().load()); } catch (error) {
    banner.classList.remove("hide");
    $("tx-recovery-label").textContent = error.message;
    $("tx-recovery-clear").classList.add("hide");
  }
  window.addEventListener("storage", (event) => {
    if (event.key === window.StickyTx?.STORAGE_KEY) {
      try { renderTxRecovery(getTxEngine().load()); } catch (error) { $("tx-recovery-label").textContent = error.message; banner.classList.remove("hide"); }
    }
  });
}

async function auditPrompt() {
  const chainIds = [...new Set(confirmPlan.map((tx) => Number(tx.chainId ?? ctx.chainId)))];
  const lines = [
    "Audit these Ethereum transactions before I sign them. Do not assume good intent. Verify everything.",
    `Chain ids: ${chainIds.join(", ")}. Reviewed account: ${confirmPlan[0]?.from || txAccount()}. App: Sticky webclient (${location.origin}).`,
    `Stated intent: ${$("cd-title").textContent}.`,
    "",
  ];
  confirmPlan.forEach((tx, i) => {
    let rows;
    try { rows = reviewedRows(tx).rows.slice(1); } catch (error) { rows = [["review error", error.message]]; }
    lines.push(
      `Transaction ${i + 1} of ${confirmPlan.length}: ${tx.label}`,
      `- chain id: ${tx.chainId ?? ctx.chainId}`,
      `- to: ${tx.to} (expected to be ${tx.contractName || contractNameOf(tx.to)})`,
      `- function: ${tx.fn}`,
      ...rows.map(([k, v]) => `- ${k.toLowerCase()}: ${v?.title ? `${v.text} (${v.title})` : v}`),
      `- value: ${tx.value ? BigInt(tx.value) : 0} wei`,
      `- raw calldata: ${tx.data}`,
      "",
    );
  });
  lines.push(
    "Tasks: decode each raw calldata and confirm it exactly matches the stated function and arguments.",
    "Confirm each target address matches the contract it claims to be. Flag any approval, transfer, or",
    "value that could move funds anywhere other than described. Conclude SAFE or UNSAFE with reasons.",
  );
  return lines.join("\n");
}

async function renderTrustedSenders() {
  if (ctx.currentId === null || !account()) return;
  const isCurrent = currentView();
  const idArg = word(ctx.currentId);
  // Candidates come from the holder's trust events; current state is re-read from the contract.
  // Candidates come from the view's one project scan, or one holder scan kept until the holder changes trust.
  const holderTopic = "0x" + encAddress(account());
  const key = `${ctx.chainId}:${ctx.currentId}:${holderTopic}`;
  let scanned = cachedProjectLogs(ctx.currentId)?.all ?? (ctx.trustLogs?.key === key ? ctx.trustLogs.logs : null);
  if (!scanned) {
    scanned = await getLogs(ctx.hook, [TOPIC.SetTrustedSender, "0x" + idArg, holderTopic], await projectStartBlock(ctx.chainId, ctx.currentId));
    ctx.trustLogs = { key, logs: scanned };
  }
  if (!isCurrent()) return;
  const logs = scanned.filter((log) => log.topics[0] === TOPIC.SetTrustedSender && log.topics[2]?.toLowerCase() === holderTopic);
  // The auto-stick adapter's trust is presented through the auto-stick card, not as a generic airdropper.
  const candidates = [...new Set(logs.map((log) => decAddress(log.topics[3])))]
    .filter((sender) => sender.toLowerCase() !== (autoStickAdapter() || "").toLowerCase());
  const current = [];
  for (const sender of candidates) {
    const trusted = decUint(await view(ctx.hook, SEL.isTrustedSenderOf, idArg + encAddress(account()) + encAddress(sender)));
    if (!isCurrent()) return;
    if (trusted === 1n) current.push(sender);
  }
  $("trusted-list").innerHTML = current.length
    ? current.map((sender) =>
        `<tr><td style="word-break:break-all">${sender}</td>` +
        `<td style="width:90px"><button type="button" class="danger" style="margin:0;padding:4px 10px" data-untrust="${sender}">Untrust</button></td></tr>`,
      ).join("")
    : `<tr><td class="trusted-empty"><strong>None yet</strong><span>Only you and the project's trusted senders can stick for you.</span></td></tr>`;
  for (const button of $("trusted-list").querySelectorAll("[data-untrust]")) {
    button.onclick = guard(() => setTrust(button.dataset.untrust, false));
  }
}

async function setTrust(sender, trusted) {
  const action = beginAction();
  const { holder } = action;
  sender = actionAddress(sender, "sender");
  const info = await projectInfo(ctx.currentId);
  const current = decUint(await view(ctx.hook, SEL.isTrustedSenderOf,
    word(ctx.currentId) + encAddress(holder) + encAddress(sender))) === 1n;
  if (current === trusted) throw new Error(trusted ? "this sender is already trusted" : "this sender is not trusted");
  const txs = [{
    label: trusted ? "Trust sender" : "Untrust sender",
    to: ctx.hook,
    fn: "setTrustedSenderFor(uint256 projectId, address sender, bool trusted)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["SENDER", bind("sender", sender)],
      ["TRUSTED", bind("trusted", trusted, { yes: "yes, they can add stakes to your position", no: "no, they can no longer add stakes to your position" })],
    ],
    data: SEL.setTrustedSenderFor + word(ctx.currentId) + encAddress(sender) + word(trusted ? 1 : 0),
  }];
  if (!(await reviewAction(action, `${trusted ? "Trust" : "Untrust"} ${shortAddr(sender)}`, txs))) return;
  txStatus(trusted ? "Sender trusted" : "Sender untrusted", "ok");
  ctx.projectLogs = ctx.trustLogs = null;
  await renderTrustedSenders();
}


const CHAIN_ICON_SVG = {
  eth: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#627EEA"/><path d="M12 4v5.9l5 2.25z" fill="#fff" fill-opacity=".6"/><path d="M12 4L7 12.15l5-2.25z" fill="#fff"/><path d="M12 16v3.99l5-6.92z" fill="#fff" fill-opacity=".6"/><path d="M12 19.99V16l-5-3.07z" fill="#fff"/><path d="M12 15.07l5-2.92-5-2.24z" fill="#fff" fill-opacity=".2"/><path d="M7 12.15l5 2.92v-5.16z" fill="#fff" fill-opacity=".6"/></svg>`,
  op: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#FF0420"/><text x="12" y="15.6" font-size="8.5" font-weight="700" fill="#fff" text-anchor="middle" font-family="Helvetica,Arial,sans-serif">OP</text></svg>`,
  base: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#0052FF"/><path d="M12 6.2A5.8 5.8 0 0 0 12 17.8V6.2z" fill="#fff"/></svg>`,
  arb: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#2D374B"/><path d="M12 6l4.8 11h-2.4L12 11.2 9.6 17H7.2z" fill="#28A0F0"/><path d="M12 6l-1.05 2.45L12 11.2l1.05-2.75z" fill="#fff"/></svg>`,
};
const ORIGINS = [
  { key: "ethereum", chainId: 1, label: "ETHEREUM", name: "Ethereum", icon: "eth", environment: "production", rpcUrl: "https://ethereum-rpc.publicnode.com", explorer: "https://etherscan.io" },
  { key: "optimism", chainId: 10, label: "OPTIMISM", name: "OP Mainnet", icon: "op", environment: "production", rpcUrl: "https://mainnet.optimism.io", explorer: "https://optimistic.etherscan.io" },
  { key: "base", chainId: 8453, label: "BASE", name: "Base", icon: "base", environment: "production", rpcUrl: "https://mainnet.base.org", explorer: "https://basescan.org" },
  { key: "arbitrum", chainId: 42_161, label: "ARBITRUM", name: "Arbitrum One", icon: "arb", environment: "production", rpcUrl: "https://arb1.arbitrum.io/rpc", explorer: "https://arbiscan.io" },
  { key: "ethereum-sepolia", chainId: 11_155_111, label: "ETH SEPOLIA", name: "Ethereum Sepolia", icon: "eth", environment: "testnet", rpcUrl: "https://ethereum-sepolia-rpc.publicnode.com", explorer: "https://sepolia.etherscan.io" },
  { key: "optimism-sepolia", chainId: 11_155_420, label: "OP SEPOLIA", name: "OP Sepolia", icon: "op", environment: "testnet", rpcUrl: "https://sepolia.optimism.io", explorer: "https://sepolia-optimism.etherscan.io" },
  { key: "base-sepolia", chainId: 84_532, label: "BASE SEPOLIA", name: "Base Sepolia", icon: "base", environment: "testnet", rpcUrl: "https://sepolia.base.org", explorer: "https://sepolia.basescan.org" },
  { key: "arbitrum-sepolia", chainId: 421_614, label: "ARB SEPOLIA", name: "Arbitrum Sepolia", icon: "arb", environment: "testnet", rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc", explorer: "https://sepolia.arbiscan.io" },
];
const chainById = (chainId) => ORIGINS.find((origin) => origin.chainId === Number(chainId));
const chainsForEnvironment = (environment) => ORIGINS.filter((origin) => origin.environment === environment);

function stickyDeploymentFor(chainId) {
  const origin = chainById(chainId);
  const configured = StickyRuntime.deployment(window.STICKY_CONFIG || {}, chainId);
  const current = Number(chainId) === ctx.chainId;
  return {
    ...origin,
    ...configured,
    chainId: Number(chainId),
    rpcUrl: configured.rpcUrl || (current ? $("rpc").value : origin?.rpcUrl),
    deployer: current ? $("deployer").value : configured.deployer,
    autoStickAdapter: configured.autoStickAdapter,
    distributor: configured.distributor,
    rewardReceiverFactory: configured.rewardReceiverFactory,
    fromBlock: configured.fromBlock ?? "earliest",
  };
}

async function rpcAt(url, method, params) {
  return StickyRuntime.jsonRpc(url, method, params);
}

const viewAt = (deployment, to, selector, args = "") =>
  rpcAt(deployment.rpcUrl, "eth_call", [{ to, data: selector + args }, "latest"]);

async function loadStickyRuntime(chainId) {
  const deployment = stickyDeploymentFor(chainId);
  const chain = chainById(chainId);
  if (!chain || !deployment.rpcUrl) throw new Error(`no RPC is configured for chain ${chainId}`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(deployment.deployer || "")) {
    throw new Error(`no Sticky deployer is configured for ${chain.name}`);
  }
  const actualChainId = Number(BigInt(await rpcAt(deployment.rpcUrl, "eth_chainId", [])));
  if (actualChainId !== Number(chainId)) {
    throw new Error(`${chain.name}'s configured RPC returned chain ${actualChainId}`);
  }
  const deployerCode = await rpcAt(deployment.rpcUrl, "eth_getCode", [deployment.deployer, "latest"]);
  if (!deployerCode || deployerCode === "0x") {
    throw new Error(`Sticky is not deployed at ${deployment.deployer} on ${chain.name}`);
  }
  const controller = decAddress(await viewAt(deployment, deployment.deployer, SEL.CONTROLLER));
  const [projects, tokens] = await Promise.all([
    viewAt(deployment, controller, SEL.PROJECTS).then(decAddress),
    viewAt(deployment, controller, SEL.TOKENS).then(decAddress),
  ]);
  await Promise.all([controller, projects, tokens].map(async address => {
    StickyRuntime.address(address);
    const code = await rpcAt(deployment.rpcUrl, "eth_getCode", [address, "latest"]);
    if (!code || code === "0x") throw new Error(`A required Sticky contract is missing on ${chain.name}`);
  }));
  const fee = decUint(await viewAt(deployment, projects, SEL.creationFee));
  // Every launch trusts AutoStick, so a chain without it cannot launch.
  const adapter = deployment.autoStickAdapter;
  StickyLaunchPlan.launchGranters([], adapter, chain.name);
  const adapterCode = await rpcAt(deployment.rpcUrl, "eth_getCode", [adapter, "latest"]);
  if (!adapterCode || adapterCode === "0x") {
    throw new Error(`the auto-stick adapter is not deployed at ${adapter} on ${chain.name}`);
  }
  const [adapterDeployer, adapterDistributor, hook, adapterHook] = await Promise.all([
    viewAt(deployment, adapter, "0xc1b8411a").then(decAddress),
    viewAt(deployment, adapter, SEL.DISTRIBUTOR).then(decAddress),
    viewAt(deployment, deployment.deployer, SEL.HOOK).then(decAddress),
    viewAt(deployment, adapter, SEL.HOOK).then(decAddress),
  ]);
  if (adapterDeployer.toLowerCase() !== deployment.deployer.toLowerCase() || hook.toLowerCase() !== adapterHook.toLowerCase()
    || !deployment.distributor || adapterDistributor.toLowerCase() !== deployment.distributor.toLowerCase()) {
    throw new Error(`The auto-stick adapter on ${chain.name} does not match this Sticky deployment and distributor.`);
  }
  return { ...chain, ...deployment, controller, projects, tokens, fee, autoStickAdapter: adapter };
}

// One runtime check per chain while the create dialog is open.
let launchRuntimes = new Map();
function launchRuntime(chainId) {
  if (!launchRuntimes.has(chainId)) {
    const pending = loadStickyRuntime(chainId);
    pending.catch(() => launchRuntimes.delete(chainId));
    launchRuntimes.set(chainId, pending);
  }
  return launchRuntimes.get(chainId);
}

let createEnvironment = "production";
let createChainIds = new Set(chainsForEnvironment(createEnvironment).map((chain) => chain.chainId));
// Why a chain can't launch, or "" when it can. AutoStick is a granter on every launch.
function launchChainBlocker(chain) {
  if (window.STICKY_CONFIG?.demoMode === true) return "";
  const deployment = stickyDeploymentFor(chain.chainId);
  if (!/^0x[0-9a-fA-F]{40}$/.test(deployment.deployer || "")) return "not deployed";
  if (!StickyLaunchPlan.isAddress(deployment.autoStickAdapter)) return "no auto-stick helper";
  return "";
}
const launchChainConfigured = (chain) => !launchChainBlocker(chain);

function renderCreateChains() {
  const chains = chainsForEnvironment(createEnvironment);
  for (const chain of chains) if (!launchChainConfigured(chain)) createChainIds.delete(chain.chainId);
  $("d-environment").value = createEnvironment;
  $("d-chains").innerHTML = chains.map((chain) =>
    `<label class="chain-option"><input type="checkbox" data-create-chain="${chain.chainId}"`
      + `${createChainIds.has(chain.chainId) ? " checked" : ""}${launchChainConfigured(chain) ? "" : " disabled"}>`
      + `<span class="chain-option-icon" aria-hidden="true">${CHAIN_ICON_SVG[chain.icon]}</span>`
      + `<span>${esc(chain.name)}${launchChainConfigured(chain) ? "" : ` <span class="mut">(${esc(launchChainBlocker(chain))})</span>`}</span></label>`,
  ).join("");
  syncCreateChainValidity();
}

function syncCreateChainValidity() {
  const empty = createChainIds.size === 0;
  $("d-chains-error").classList.toggle("hide", !empty);
  $("deploy").disabled = empty;
}

function selectCreateEnvironment(environment) {
  createEnvironment = environment;
  createChainIds = new Set(chainsForEnvironment(environment).filter(launchChainConfigured).map((chain) => chain.chainId));
  renderCreateChains();
  resolveLockToken().catch(() => {});
}
let originKey = null;

function renderOriginPills() {
  const family = chainById(ctx.chainId)?.environment || "production";
  const origins = chainsForEnvironment(family);
  const selected = origins.find((origin) => origin.key === originKey)
    ?? origins.find((origin) => origin.chainId === ctx.chainId) ?? origins[0];
  originKey = selected.key;
  $("r-origin").replaceChildren(...origins.map((origin) => {
    const option = document.createElement("option");
    option.value = origin.key;
    option.textContent = origin.chainId === ctx.chainId ? `${origin.label} (this chain)` : origin.label;
    return option;
  }));
  $("r-origin").value = originKey;
  const here = selected.chainId === ctx.chainId;
  $("fund-direct").classList.toggle("hide", !here);
  $("fund-bridge").classList.toggle("hide", here);
  $("r-token-wrap").classList.toggle("hide", !here);
  $("r-amount-wrap").classList.toggle("hide", !here);
};

$("r-origin").onchange = (event) => {
  originKey = event.target.value;
  renderOriginPills();
};

// Cross-chain rewards use the reward token's own V6 sucker pair. The Sticky
// project receives the destination tokens through its deterministic receiver.
let bridgeApi = null;
let bridgeContextKey = "";
let bridgeRoutes = [];
let bridgeDisplayedRows = [];
let bridgeRefreshGeneration = 0;
let bridgeBusy = false;
const getBridgeApi = () => bridgeApi ||= StickyBridge.create({ rpc: rpcAt, keccak256: StickyRelayr.keccak256, logs: StickyRuntime.logs, inspectSafeExecution: StickyTxSafe.inspectSafeExecution });

function bridgeRuntime(chainId) {
  const chain = chainById(chainId);
  if (!chain) throw new Error("This bridge chain is unsupported.");
  return { ...stickyDeploymentFor(chainId), ...chain, rpcUrl: stickyDeploymentFor(chainId).rpcUrl,
    bridgeContracts: window.STICKY_CONFIG?.chains?.[String(chainId)]?.bridgeContracts,
    bridgeFromBlock: window.STICKY_CONFIG?.chains?.[String(chainId)]?.bridgeFromBlock };
}

function rehydrateBridgeRoute(route) {
  return { ...route, source: bridgeRuntime(Number(route.source.chainId)), destination: bridgeRuntime(Number(route.destination.chainId)) };
}

async function bridgeContext() {
  const projectId = ctx.currentId;
  const chainId = ctx.chainId;
  const source = ORIGINS.find(origin => origin.key === originKey);
  if (projectId === null || !source || source.chainId === chainId) return null;
  const destination = bridgeRuntime(chainId);
  if (source.environment !== destination.environment) throw new Error("Choose an origin in the same network environment.");
  const info = await projectInfo(projectId);
  if (ctx.currentId !== projectId || ctx.chainId !== chainId) throw new Error("The project changed. Review the bridge again.");
  const rewardReceiverFactory = stickyDeploymentFor(chainId).rewardReceiverFactory;
  if (!rewardReceiverFactory || !distributor()) throw new Error("Cross-chain rewards are unavailable until this chain's reward receiver factory and distributor are deployed.");
  // Each reward group has its own receiver, so the chosen stake-age window is part of the route.
  const groupId = fundGroupId();
  const receiver = await getBridgeApi().receiverFor(destination, info.stToken, rewardReceiverFactory, distributor(), groupId);
  const owner = /^0x[0-9a-f]{40}$/i.test(txAccount() || "") ? txAccount().toLowerCase() : null;
  return { source: bridgeRuntime(source.chainId), destination, info, receiver, groupId, owner,
    key: `sticky:bridge:v2:${chainId}:${info.stToken.toLowerCase()}:${groupId}:${owner || "disconnected"}` };
}

function bridgeRecords(key) {
  const raw = localStorage.getItem(key);
  if (raw === null) return [];
  let records;
  try { records = JSON.parse(raw); } catch { throw new Error("Saved bridge recovery data is unreadable. Keep this browser's data and recover the original transfer before sending again."); }
  if (!Array.isArray(records) || records.length > 100 || records.some(record => !record || !/^0x[0-9a-f]{64}$/i.test(record.metadata || "")
    || !/^0x[0-9a-f]{40}$/i.test(record.owner || "") || !/^\d+$/.test(record.amount || "") || !record.route?.source || !record.route?.destination)) {
    throw new Error("Saved bridge recovery data is invalid. Recover the original transfer before sending again.");
  }
  return records;
}

function saveBridgeRecords(key, records) {
  if (records.length > 100) throw new Error("This browser's saved bridge history is full. Existing transfers can still be recovered; no new transfer was submitted.");
  const encoded = JSON.stringify(records);
  localStorage.setItem(key, encoded);
  if (localStorage.getItem(key) !== encoded) throw new Error("Bridge recovery could not be saved. No new transfer will be submitted.");
}

async function mutateBridgeRecords(key, update) {
  if (!navigator.locks?.request) throw new Error("This browser cannot safely save bridge recovery across tabs.");
  return navigator.locks.request("sticky-reward-bridge-storage", { mode: "exclusive" }, () => {
    const updated = update(bridgeRecords(key));
    saveBridgeRecords(key, updated);
    return updated;
  });
}

function canDiscardBridgeJournal(journal, metadata) {
  return !!journal?.steps.length && journal.steps.every(step => step.tx.sessionTag === "sticky-bridge:" + metadata
    && ((step.state === "ready" && !step.submission) || ["rejected", "reverted"].includes(step.state)
      || (step.state === "confirmed" && /^0x095ea7b3[0-9a-f]{128}$/i.test(step.tx.data))))
    && journal.steps.some(step => step.state !== "confirmed");
}

async function discardBridgeDraft(context, record) {
  const tag = "sticky-bridge:" + record.metadata;
  const journal = getTxEngine().load();
  if (record.journalId && getTxEngine().wasDiscarded(record.journalId, tag)) {
    await mutateBridgeRecords(context.key, records => records.filter(item => item.metadata !== record.metadata));
    return true;
  }
  if (!canDiscardBridgeJournal(journal, record.metadata)) return false;
  await getTxEngine().discardUnsubmitted(journal.id);
  await mutateBridgeRecords(context.key, records => records.filter(item => item.metadata !== record.metadata));
  return true;
}

function bridgeRouteId(route) {
  return `${route.source.chainId}:${route.destination.chainId}:${route.sourceSucker.toLowerCase()}:${route.backingToken.toLowerCase()}`;
}

async function reconcileBridgeRecord(context, record, rows) {
  const candidates = rows.filter(row => row.leaf.metadata === record.metadata && row.caller === record.owner.toLowerCase());
  let found;
  for (const candidate of candidates) {
    try { await getBridgeApi().verifySource(rehydrateBridgeRoute(record.route), candidate, record.owner, record.prepareData); found = candidate; break; } catch { /* A copied reference or noncanonical log must not release the saved wallet transfer. */ }
  }
  if (found && (found.leaf.projectTokenCount !== BigInt(record.amount) || found.leaf.beneficiary !== "0x" + encAddress(context.receiver))) throw new Error("The recovered bridge leaf does not match the saved transfer.");
  await mutateBridgeRecords(context.key, records => {
    const index = records.findIndex(item => item.metadata === record.metadata);
    if (index < 0) return records; // A coordinated cancellation may finish while a read is in flight.
    records[index] = found ? { ...records[index], phase: "submitted", sourceHash: found.sourceHash, sourceVerified: true, leafIndex: found.leaf.index.toString(), status: found.status }
      : { ...records[index], sourceVerified: false, status: "recover" };
    return records;
  });
  if (!found) return false;
  const journal = getTxEngine().load();
  if (journal?.steps.every(step => step.tx.sessionTag === "sticky-bridge:" + record.metadata && step.state === "confirmed")) await getTxEngine().acknowledge(journal.id);
  return true;
}

async function renderBridgeFunding() {
  if (!$("bridge-status")) return;
  const generation = ++bridgeRefreshGeneration;
  try {
    const context = await bridgeContext();
    if (!context || generation !== bridgeRefreshGeneration) return;
    const key = `${context.key}:${context.source.chainId}`;
    if (bridgeContextKey !== key) {
      bridgeContextKey = key;
      bridgeRoutes = [];
      bridgeDisplayedRows = [];
      $("bridge-source-token").value = "";
      $("bridge-route").innerHTML = "";
      $("bridge-route").classList.add("hide");
      $("bridge-route").disabled = true;
      $("bridge-prepare").disabled = true;
      $("bridge-movements").replaceChildren();
    }
    $("receiver-addr").textContent = context.receiver;
    const records = context.owner ? bridgeRecords(context.key).filter(record => record.route.source.chainId === context.source.chainId) : [];
    const routes = new Map(bridgeRoutes.map(route => [bridgeRouteId(route), route]));
    for (const record of records) {
      const route = rehydrateBridgeRoute(record.route);
      if (route.destination.chainId !== context.destination.chainId || record.owner.toLowerCase() !== context.owner) throw new Error("Saved bridge data belongs to another destination or account.");
      routes.set(bridgeRouteId(route), route);
    }
    const displayed = [];
    for (const route of routes.values()) {
      const rows = await getBridgeApi().movements(route, context.receiver);
      for (const record of records.filter(item => bridgeRouteId(item.route) === bridgeRouteId(route))) {
        const verified = await reconcileBridgeRecord(context, record, rows);
        if (!verified) displayed.push({ route, record, status: "recover" });
      }
      for (const row of rows) displayed.push({ route, row, status: row.status });
    }
    if (generation !== bridgeRefreshGeneration) return;
    bridgeDisplayedRows = displayed;
    const rowsEl = $("bridge-movements");
    rowsEl.replaceChildren();
    for (const [index, item] of displayed.entries()) {
      const container = document.createElement("div");
      container.style.cssText = "border-top:1px solid var(--line);padding:12px 0;overflow-wrap:anywhere";
      const amount = item.row?.leaf.projectTokenCount || BigInt(item.record.amount);
      const meta = item.route.sourceMeta || { symbol: shortAddr(item.route.sourceToken), decimals: 18 };
      const labels = { queued: "Queued on the origin chain. Ready to send.", "in-flight": "Crossing chains. Refresh after the bridge delivers.", claimable: "Arrived. Ready to claim into rewards.", claimed: "Claimed into the receiver. Settle any remaining balance below.", recover: "Saved transfer. Review its wallet status before continuing." };
      const summary = document.createElement("p");
      summary.textContent = `${formatUnits(amount, meta.decimals, meta.decimals)} ${meta.symbol}: ${labels[item.status]}`;
      container.append(summary);
      if (item.row?.sourceHash) {
        const link = document.createElement("a");
        link.href = `${chainById(item.route.source.chainId).explorer}/tx/${item.row.sourceHash}`;
        link.target = "_blank"; link.rel = "noopener noreferrer"; link.textContent = "Origin transaction";
        container.append(link);
      }
      if (["queued", "claimable", "recover"].includes(item.status)) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = item.status === "queued" ? "Send across chains" : item.status === "claimable" ? "Claim arrival" : "Review saved transfer";
        button.onclick = guard(() => withBridgeLock(() => actOnBridgeMovement(index)));
        container.append(button);
      }
      if (item.status === "recover" && canDiscardBridgeJournal(getTxEngine().load(), item.record.metadata)) {
        const cancel = document.createElement("button");
        cancel.type = "button"; cancel.className = "ghost"; cancel.textContent = "Cancel this transfer";
        cancel.onclick = guard(() => withBridgeLock(async () => {
          const live = await bridgeContext();
          if (!live || live.key !== context.key) throw new Error("The selected wallet or project changed. Refresh this transfer.");
          if (!(await discardBridgeDraft(live, item.record))) throw new Error("The transfer may still execute. Recover its wallet outcome before cancelling.");
        }));
        container.append(cancel);
      }
      if (item.status === "claimed") {
        const button = document.createElement("button");
        button.type = "button"; button.className = "ghost"; button.textContent = "Check unsettled rewards";
        button.onclick = guard(async () => { $("bridge-reward-token").value = item.route.rewardToken; await renderRewards(); });
        container.append(button);
      }
      rowsEl.append(container);
    }
    const unresolved = displayed.some(item => item.status === "recover");
    const selected = bridgeRoutes[Number($("bridge-route").value)];
    $("bridge-prepare").disabled = bridgeBusy || unresolved || !selected?.canPrepare;
    $("bridge-status").textContent = unresolved ? "Keep this browser's saved transfer until its wallet outcome is verified."
      : displayed.some(item => item.status === "in-flight") ? "Bridge delivery takes time. Refresh to check for a claimable arrival."
      : bridgeRoutes.length ? "The bridge route is verified. Review the origin transfer, then send its queued batch and claim it here after delivery."
      : "Enter a Juicebox V6 project token address on the origin chain to find its bridge. Existing arrivals can be settled below.";
  } catch (error) {
    if (generation === bridgeRefreshGeneration) {
      $("bridge-status").textContent = error.message;
      $("bridge-prepare").disabled = true;
    }
  }
}

async function withBridgeLock(action) {
  if (!navigator.locks?.request) throw new Error("This browser cannot safely coordinate cross-chain transfers. Use a current browser with Web Locks support.");
  if (bridgeBusy) return;
  bridgeBusy = true;
  $("bridge-prepare").disabled = true;
  try { return await navigator.locks.request("sticky-reward-bridge", { mode: "exclusive", ifAvailable: true }, async lock => {
    if (!lock) throw new Error("A bridge action is already open in another tab.");
    return action();
  }); } finally { bridgeBusy = false; await renderBridgeFunding(); }
}

async function findBridgeRoutes() {
  const context = await bridgeContext();
  if (!context) return;
  const sourceToken = StickyBridge.address($("bridge-source-token").value.trim());
  $("bridge-status").textContent = "Checking the token's bridge contracts on both chains…";
  bridgeRoutes = [];
  const routes = await getBridgeApi().discover({ source: context.source, destination: context.destination, sourceToken });
  if (ctx.chainId !== context.destination.chainId || ORIGINS.find(origin => origin.key === originKey)?.chainId !== context.source.chainId
    || $("bridge-source-token").value.trim().toLowerCase() !== sourceToken) throw new Error("The selected bridge changed. Find routes again.");
  if (!routes.length) throw new Error("This token has no verified direct bridge to this chain. Its project must have a V6 sucker pair and matching backing-token mappings on both chains.");
  bridgeRoutes = routes;
  const selector = $("bridge-route");
  selector.replaceChildren();
  routes.forEach((route, index) => {
    const option = document.createElement("option"); option.value = String(index);
    option.textContent = `${route.sourceMeta.symbol} → ${route.rewardMeta.symbol} via ${route.backingMeta.symbol}${route.canPrepare ? "" : " (recovery only)"}`;
    selector.append(option);
  });
  selector.classList.remove("hide"); selector.disabled = false;
  $("bridge-reward-token").value = routes[0].rewardToken;
  await renderRewards();
}

async function prepareBridgeFunding() {
  const projectId = ctx.currentId;
  const chainId = ctx.chainId;
  const context = await bridgeContext();
  if (!context?.owner) throw new Error("Connect the wallet that holds the origin project tokens.");
  const route = bridgeRoutes[Number($("bridge-route").value)];
  if (!route || route.source.chainId !== context.source.chainId || route.destination.chainId !== context.destination.chainId
    || route.sourceToken !== $("bridge-source-token").value.trim().toLowerCase()) throw new Error("Find and review this token's bridge first.");
  const saved = bridgeRecords(context.key);
  if (saved.length >= 100) throw new Error("This browser's saved bridge history is full. Existing transfers can still be recovered; no new transfer was submitted.");
  const previousMovements = new Map();
  for (const record of saved) {
    const previousRoute = rehydrateBridgeRoute(record.route);
    const key = bridgeRouteId(previousRoute);
    if (!previousMovements.has(key)) previousMovements.set(key, await getBridgeApi().movements(previousRoute, context.receiver));
    if (!(await reconcileBridgeRecord(context, record, previousMovements.get(key)))) throw new Error("Recover the saved origin transfer before starting another bridge transfer.");
  }
  const journal = getTxEngine().load();
  if (journal && (journal.steps.some(step => step.state !== "confirmed") || (!journal.acknowledged && journal.steps.some(step => step.tx.sessionTag)))) throw new Error("Finish the saved wallet transaction before starting a bridge transfer.");
  const amount = parseUnits($("bridge-amount").value, route.sourceMeta.decimals);
  const metadata = "0x" + [...crypto.getRandomValues(new Uint8Array(32))].map(value => value.toString(16).padStart(2, "0")).join("");
  const plan = await getBridgeApi().prepare({ route, amount, owner: context.owner, receiver: context.receiver, metadata });
  if (ctx.currentId !== projectId || ctx.chainId !== chainId) throw new Error("The project changed. Review the bridge again.");
  const record = { metadata, owner: context.owner, amount: amount.toString(), route, prepareData: plan.txs.at(-1).data, createdAt: Date.now(), status: "review", phase: "created" };
  await mutateBridgeRecords(context.key, records => [...records, record]);
  let mayRun = false;
  let complete;
  try { complete = await confirmAndRun("Bridge rewards to " + stickyLabel(context.info), plan.txs, [
    ["Send", `${formatUnits(amount, route.sourceMeta.decimals, route.sourceMeta.decimals)} ${route.sourceMeta.symbol} on ${route.source.name}`],
    ["Receive", `${formatUnits(amount, route.rewardMeta.decimals, route.rewardMeta.decimals)} ${route.rewardMeta.symbol} in this project's receiver on ${route.destination.name}`],
    ["Rewards", `${groupLabel(context.groupId)} (group ${context.groupId})`],
    ["Afterward", "Send the queued bridge batch, wait for delivery, claim the arrival, then settle it into rewards."],
  ], { onPrepared: async session => {
    mayRun = true;
    await mutateBridgeRecords(context.key, records => {
      const index = records.findIndex(item => item.metadata === metadata);
      if (index < 0) throw new Error("The saved bridge transfer disappeared before wallet review.");
      records[index] = { ...records[index], phase: "prepared", journalId: session.id };
      return records;
    });
  } }); } catch (error) {
    if (!mayRun) {
      const current = getTxEngine().load();
      if (current?.steps.every(step => step.tx.sessionTag === "sticky-bridge:" + metadata)) await getTxEngine().discardUnsubmitted(current.id);
      await mutateBridgeRecords(context.key, records => records.filter(item => item.metadata !== metadata));
    }
    throw error;
  }
  if (!complete) {
    await discardBridgeDraft(context, bridgeRecords(context.key).find(item => item.metadata === metadata) || record);
    return;
  }
  await reconcileBridgeRecord(context, record, await getBridgeApi().movements(route, context.receiver));
  txStatus("Rewards queued on the origin chain. Send the queued batch to begin crossing chains.", "ok");
}

async function actOnBridgeMovement(index) {
  const item = bridgeDisplayedRows[index];
  const context = await bridgeContext();
  if (!item || !context?.owner || item.route.source.chainId !== context.source.chainId || item.route.destination.chainId !== context.destination.chainId) throw new Error("Reconnect the wallet and refresh this bridge transfer.");
  $("bridge-reward-token").value = item.route.rewardToken;
  if (item.status === "recover") {
    const saved = getTxEngine().load();
    const discarded = item.record.journalId && getTxEngine().wasDiscarded(item.record.journalId, "sticky-bridge:" + item.record.metadata);
    if (discarded || (item.record.phase === "created" && !item.record.sourceHash && !item.record.journalId
      && !saved?.steps.some(step => step.tx.sessionTag === "sticky-bridge:" + item.record.metadata))) {
      // The shared runner starts only after the durable prepared phase. A crash
      // before journal publication leaves a draft that never reached the wallet.
      await mutateBridgeRecords(context.key, records => {
        const current = records.find(record => record.metadata === item.record.metadata);
        if (current && !(discarded && current.journalId === item.record.journalId)
          && (current.phase !== "created" || current.sourceHash || current.journalId)) throw new Error("This transfer has wallet history. Recover its original transaction before starting another.");
        return records.filter(record => record.metadata !== item.record.metadata);
      });
      txStatus("The unsubmitted bridge draft was cleared. Find the bridge again to review a new transfer.", "ok");
      return;
    }
    if (!saved?.steps.every(step => step.tx.sessionTag === "sticky-bridge:" + item.record.metadata)) throw new Error("The transfer's wallet record is unavailable. Recover its original transaction before sending more tokens; its saved bridge reference has been preserved.");
    await getBridgeApi().validateRoute(item.route);
    if (!(await confirmAndRun(saved.title, saved.steps.map(step => step.tx), saved.summary, { onPrepared: async journal => {
      await mutateBridgeRecords(context.key, records => {
        const index = records.findIndex(record => record.metadata === item.record.metadata);
        if (index < 0) throw new Error("The saved bridge transfer disappeared before wallet review.");
        records[index] = { ...records[index], phase: "prepared", journalId: journal.id };
        return records;
      });
    } }))) {
      await discardBridgeDraft(context, item.record);
      return;
    }
    await reconcileBridgeRecord(context, item.record, await getBridgeApi().movements(item.route, context.receiver));
    return;
  }
  const tx = item.status === "queued" ? await getBridgeApi().flush(item.route, context.owner, context.receiver)
    : await getBridgeApi().claim(item.route, item.row, context.owner, context.receiver);
  if (!(await confirmAndRun(tx.label, [tx], [["Reward token on destination", item.route.rewardToken], ["Destination receiver", context.receiver], ["Rewards", `${groupLabel(context.groupId)} (group ${context.groupId})`]]))) return;
  await renderRewards();
}

function initBridgeFunding() {
  if (!$("bridge-find")) return;
  $("bridge-find").onclick = guard(() => withBridgeLock(findBridgeRoutes));
  $("bridge-prepare").onclick = guard(() => withBridgeLock(prepareBridgeFunding));
  $("bridge-refresh").onclick = guard(renderBridgeFunding);
  $("bridge-source-token").oninput = () => { bridgeRoutes = []; $("bridge-prepare").disabled = true; $("bridge-route").classList.add("hide"); };
  $("bridge-route").onchange = async () => {
    const route = bridgeRoutes[Number($("bridge-route").value)];
    if (route) $("bridge-reward-token").value = route.rewardToken;
    await renderRewards();
  };
  $("bridge-reward-token").onchange = guard(renderRewards);
}
queueMicrotask(initBridgeFunding);

const distributor = () => StickyRuntime.deployment(window.STICKY_CONFIG || {}, ctx.chainId).distributor;
const autoStickAdapterOn = (chainId) => StickyRuntime.deployment(window.STICKY_CONFIG || {}, chainId).autoStickAdapter;
const autoStickAdapter = () => autoStickAdapterOn(ctx.chainId);
const rewardTokens = {}; // projectId -> Set of reward token addresses

const NATIVE_REWARD_TOKEN = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

// A review row bound to a calldata argument. The confirm dialog shows the decoded value and blocks a mismatch.
const bind = (param, expect, fmt) => StickyCalldata.arg(param, expect, fmt);
// Names shown next to addresses in a review, keyed by lowercase address.
const named = (...pairs) => Object.fromEntries(pairs.filter(([address]) => address).map(([address, name]) => [address.toLowerCase(), name]));

function actionAddress(value, label = "address") {
  const address = String(value || "").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(address) || /^0x0{40}$/i.test(address)) {
    throw new Error(`enter a valid ${label}`);
  }
  return address;
}

function rewardTokenAddress(value, fallback) {
  const input = String(value || fallback || "").trim();
  return /^eth$/i.test(input) ? NATIVE_REWARD_TOKEN : actionAddress(input, "reward token address or ETH");
}

function positiveAmount(value, decimals) {
  const amount = parseUnits(value, decimals);
  if (amount === 0n) throw new Error("enter an amount greater than zero");
  return amount;
}

function beginAction() {
  return { holder: txAccount(), chainId: ctx.chainId, projectId: ctx.currentId };
}

function reviewAction(action, title, txs, summary = []) {
  if (txAccount().toLowerCase() !== action.holder.toLowerCase()
    || ctx.chainId !== action.chainId || ctx.currentId !== action.projectId) {
    throw new Error("the account, chain, or project changed; review this action again");
  }
  return confirmAndRun(title, txs.map((tx) => ({ ...tx, from: action.holder, chainId: action.chainId })), summary);
}

async function actionCall(to, data, holder = txAccount(), value = 0n) {
  return rpc("eth_call", [{ from: holder, to, data, ...(value ? { value: `0x${value.toString(16)}` } : {}) }, "latest"]);
}

// ---------------------------------------------------------------- reward groups
// A reward group names who a pot rewards. Group 0 is everyone holding at the round's snapshot. Any other group is
// a stake-age window encoded as minWeeks * 1000 + maxWeeks, where maxWeeks 0 means no upper bound. The distributor
// checks the same rules in isValidGroupId; these mirror them for labels and form validation.
const CRITERIA_BASE = 1000n;
const MAX_CRITERIA_WEEKS = 520n;

function decodeGroupId(groupId) {
  const id = BigInt(groupId);
  return { minWeeks: id / CRITERIA_BASE, maxWeeks: id % CRITERIA_BASE };
}

function isValidGroupId(groupId) {
  const id = BigInt(groupId);
  if (id === 0n) return true;
  const { minWeeks, maxWeeks } = decodeGroupId(id);
  return minWeeks >= 1n && minWeeks <= MAX_CRITERIA_WEEKS
    && (maxWeeks === 0n || (maxWeeks >= minWeeks && maxWeeks <= MAX_CRITERIA_WEEKS));
}

// The two stake-age fields as a group ID. A blank or zero minimum is everyone; a blank maximum is no upper bound.
function groupIdFromWeeks(minValue, maxValue) {
  const parse = (value, label) => {
    const text = String(value ?? "").trim();
    if (text === "") return null;
    if (!/^\d{1,4}$/.test(text)) throw new Error(`${label} must be a whole number of weeks`);
    return BigInt(text);
  };
  const minWeeks = parse(minValue, "the minimum stake age") ?? 0n;
  const maxWeeks = parse(maxValue, "the maximum stake age") ?? 0n;
  if (minWeeks > MAX_CRITERIA_WEEKS || maxWeeks > MAX_CRITERIA_WEEKS) throw new Error(`stake age is limited to ${MAX_CRITERIA_WEEKS} weeks`);
  if (minWeeks === 0n && maxWeeks !== 0n) throw new Error("a maximum stake age needs a minimum of at least 1 week");
  if (maxWeeks !== 0n && maxWeeks < minWeeks) throw new Error("the maximum stake age must be at least the minimum");
  return minWeeks * CRITERIA_BASE + maxWeeks;
}

function groupLabel(groupId) {
  const { minWeeks, maxWeeks } = decodeGroupId(groupId);
  if (BigInt(groupId) === 0n) return "Everyone";
  return maxWeeks === 0n ? `Staked ${minWeeks}+ weeks` : `Staked ${minWeeks}–${maxWeeks} weeks`;
}

// One line on who the funder chose, shared by the funding form, the split recipe, and the confirm dialog.
function groupSentence(groupId) {
  const { minWeeks, maxWeeks } = decodeGroupId(groupId);
  if (BigInt(groupId) === 0n) return "Everyone holding at the round's snapshot shares it.";
  const weeks = (n) => `${n} week${n === 1n ? "" : "s"}`;
  const window = maxWeeks === 0n ? `at least ${weeks(minWeeks)} old` : `between ${weeks(minWeeks)} and ${weeks(maxWeeks)} old`;
  return `Only stake ${window} when the round starts shares it, and holders who unstick before claiming forfeit their share.`;
}

function fundGroupId() {
  return groupIdFromWeeks($("r-min-weeks").value, $("r-max-weeks").value);
}

function groupNote(minValue, maxValue) {
  try {
    const groupId = groupIdFromWeeks(minValue, maxValue);
    return { groupId, text: groupSentence(groupId) };
  } catch (error) {
    return { groupId: null, text: error.message };
  }
}

// A holder's weight in a round: group 0 reads votes at the snapshot block; a stake-age group reads the stake still
// held in the round's window, exactly as the distributor will when the claim lands.
async function rewardStakeOf(info, holder, groupId, round, snapshotBlock) {
  if (groupId === 0n) return decUint(await view(info.stToken, SEL.getPastVotes, encAddress(holder) + word(snapshotBlock)));
  const { minWeeks, maxWeeks } = decodeGroupId(groupId);
  const epoch = decUint(await view(distributor(), SEL.snapshotEpochOf, word(round)));
  if (epoch < minWeeks) return 0n;
  const hi = epoch - minWeeks;
  const lo = maxWeeks === 0n || epoch < maxWeeks ? 0n : epoch - maxWeeks;
  const through = (at) => view(ctx.hook, SEL.stakedBalanceThroughEpochOf, word(ctx.currentId) + encAddress(holder) + word(at)).then(decUint);
  return (await through(hi)) - (lo === 0n ? 0n : await through(lo - 1n));
}

// What a holder earned in finished rounds that has not started vesting yet, summed the way the distributor
// materializes it: each round's pot pro-rata to the holder's weight, capped at what the pot still holds.
// Collecting (or beginVesting) moves it into a vesting entry.
async function earnedRewardsOf(info, holder, token, groupId = 0n, { any = false } = {}) {
  const [roundHex, cursorHex, block] = await Promise.all([
    view(distributor(), SEL.currentRound),
    view(distributor(), SEL.nextClaimRoundOf, encAddress(info.stToken) + word(groupId) + encAddress(holder) + encAddress(token)),
    rpc("eth_getBlockByNumber", ["latest", false]),
  ]);
  const round = decUint(roundHex);
  const cursor = decUint(cursorHex);
  const now = BigInt(block.timestamp);
  // Keep unusual distributor histories bounded. Existing unlocked rewards can always be collected directly.
  if (round > cursor + 4096n) throw new Error("reward history is too large to check; use a distributor client to start unlocking");
  let earned = 0n;
  for (let start = cursor; start < round; start += 16n) {
    const rounds = [];
    for (let value = start; value < round && value < start + 16n; value++) rounds.push(value);
    const states = await Promise.all(rounds.map((value) => view(distributor(), SEL.rewardRoundOf,
      encAddress(info.stToken) + word(groupId) + encAddress(token) + word(value))));
    for (const [index, state] of states.entries()) {
      const amount = decUint(state, 0);
      const snapshot = decUint(state, 1);
      const claimedAmount = decUint(state, 2);
      const deadline = decUint(state, 3);
      const totalStake = decUint(state, 4);
      if (amount === 0n || totalStake === 0n || (deadline !== 0n && now >= deadline)) continue;
      const stake = await rewardStakeOf(info, holder, groupId, rounds[index], snapshot);
      const share = amount * stake / totalStake;
      const left = amount > claimedAmount ? amount - claimedAmount : 0n;
      earned += share < left ? share : left;
      if (any && earned > 0n) return earned;
    }
  }
  return earned;
}

// A successful beginVesting simulation can still be a no-op. Read the holder's unresolved completed rounds
// and their share before asking them to pay for a vesting-only transaction.
async function hasRewardsToVest(info, holder, token, groupId = 0n) {
  return (await earnedRewardsOf(info, holder, token, groupId, { any: true })) > 0n;
}

// The distributor's round clock. Its immutables are read once per chain; the current round is read fresh.
// Round r starts at STARTING_TIMESTAMP + ROUND_DURATION * r, the same formula as roundStartTimestamp(r).
const rewardClockCache = new Map();
async function rewardSchedule() {
  const d = distributor();
  const key = `${ctx.chainId}:${d}`.toLowerCase();
  if (!rewardClockCache.has(key)) {
    const pending = Promise.all([SEL.ROUND_DURATION, SEL.VESTING_ROUNDS, SEL.STARTING_TIMESTAMP].map((selector) => view(d, selector).then(decUint)))
      .then(([roundDuration, vestingRounds, start]) => {
        if (roundDuration === 0n || vestingRounds === 0n) throw new Error("the distributor returned an invalid round schedule");
        return { roundDuration, vestingRounds, start };
      });
    pending.catch(() => rewardClockCache.delete(key));
    rewardClockCache.set(key, pending);
  }
  const clock = await rewardClockCache.get(key);
  const round = decUint(await view(d, SEL.currentRound));
  const startOf = (r) => clock.start + clock.roundDuration * BigInt(r);
  return { ...clock, round, startOf, endsAt: startOf(round + 1n) };
}

// A holder's standing in one reward pot: claimable now, vesting (and when it unlocks), and earned in
// finished rounds but not vesting yet. Every amount comes from the distributor's views.
async function rewardPosition(info, holder, groupId, token, schedule) {
  const d = distributor();
  const key = encAddress(info.stToken) + word(groupId) + encAddress(holder) + encAddress(token);
  const [collectable, claimed, latest, earned] = await Promise.all([
    view(d, SEL.collectableFor, key).then(decUint),
    view(d, SEL.claimedFor, key).then(decUint),
    view(d, SEL.latestVestedIndexOf, key).then(decUint),
    earnedRewardsOf(info, holder, token, groupId),
  ]);
  const vesting = claimed > collectable ? claimed - collectable : 0n;
  let lastRelease = 0n;
  if (vesting > 0n) {
    // Entries past the end revert; a holder has one entry per collection, so a few reads cover it.
    for (let index = latest; index < latest + 32n; index++) {
      let entry;
      try { entry = await view(d, SEL.vestingDataOf, key + word(index)); } catch { break; }
      const release = decUint(entry, 0);
      if (release > lastRelease) lastRelease = release;
    }
  }
  return {
    collectable, vesting, earned,
    nextUnlockAt: vesting > 0n ? schedule.startOf(schedule.round + 1n) : null,
    unlockedAt: vesting > 0n && lastRelease > schedule.round ? schedule.startOf(lastRelease) : null,
  };
}

function dateLabel(seconds) {
  return new Date(Number(seconds) * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric" });
}
function dateTimeLabel(seconds) {
  return new Date(Number(seconds) * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

// The round line above the reward pots.
function roundSentence(schedule) {
  const weeks = schedule.roundDuration === 604_800n ? "week" : formatDuration(schedule.roundDuration);
  return `Round ${schedule.round} ends ${dateTimeLabel(schedule.endsAt)}. `
    + `Your share then vests over ${schedule.vestingRounds} rounds, a ${schedule.vestingRounds === 4n ? "quarter" : `1/${schedule.vestingRounds}`} each ${weeks}, starting when you collect.`;
}

// One pot's lines, stating amounts and dates. Pure so the copy is tested.
function rewardLines(position, meta, funded, fundedThisRound, schedule) {
  const amt = (value) => `${formatUnits(value, meta.decimals)} ${meta.symbol}`;
  const lines = [["Claimable now", amt(position.collectable)]];
  if (position.vesting > 0n) {
    lines.push(["Vesting", `${amt(position.vesting)}. Next unlock ${dateLabel(position.nextUnlockAt)}.`
      + (position.unlockedAt && position.unlockedAt !== position.nextUnlockAt ? ` All unlocked ${dateLabel(position.unlockedAt)}.` : "")]);
  } else {
    lines.push(["Vesting", "None"]);
  }
  if (position.earned > 0n) {
    const last = schedule.startOf(schedule.round + schedule.vestingRounds);
    lines.push(["Earned, not vesting", `About ${amt(position.earned)} from finished rounds. Collect to start vesting: `
      + `a ${schedule.vestingRounds === 4n ? "quarter" : "share"} unlocks ${dateLabel(schedule.endsAt)}, all by ${dateLabel(last)}.`]);
  }
  lines.push(["Funded", (fundedThisRound > 0n ? `${amt(fundedThisRound)} this round, splits ${dateLabel(schedule.endsAt)}.` : "None this round.")
    + ` ${amt(funded)} in total.`]);
  return lines;
}

async function requireTokenBalance(token, holder, amount, meta) {
  const balance = token.toLowerCase() === NATIVE_REWARD_TOKEN
    ? BigInt(await rpc("eth_getBalance", [holder, "latest"]))
    : decUint(await view(token, SEL.balanceOf, encAddress(holder)));
  if (balance < amount) throw new Error(`insufficient ${meta.symbol} balance`);
}

// Explicitly reset a nonzero allowance before replacing it, including tokens that require a zero reset.
// Each step remains separately reviewed and recovery preserves successful prerequisite transactions.
async function tokenApprovalTxs(token, spender, amount, meta, template = null, exact = false) {
  const holder = txAccount();
  actionAddress(token, "token address");
  actionAddress(spender, "spender address");
  const allowance = decUint(await view(token, SEL.allowance, encAddress(holder) + encAddress(spender)));
  if (exact ? allowance === amount : allowance >= amount) return [];
  const make = (value) => {
    const pretty = value === UNLIMITED ? "unlimited" : `${formatUnits(value, meta.decimals, meta.decimals)} ${meta.symbol}`;
    return {
      ...(template || {}),
      label: value === 0n ? `Reset ${meta.symbol} allowance` : (template?.label || `Approve ${pretty}`),
      to: token,
      fn: "approve(address spender, uint256 amount)",
      args: [
        ["SPENDER", bind("spender", spender, { names: named([spender, contractNameOf(spender)]) })],
        ["ALLOWANCE", bind("amount", value, { kind: "units", unlimited: true, decimals: meta.decimals, symbol: meta.symbol })],
      ],
      data: SEL.approve + encode(["address", "uint256"], [spender, value]),
    };
  };
  return [...(allowance > 0n && amount > 0n ? [make(0n)] : []), make(amount)];
}

async function rewardTokenMeta(addr) {
  actionAddress(addr, "reward token address");
  if (addr.toLowerCase() === NATIVE_REWARD_TOKEN) return { symbol: "ETH", decimals: 18 };
  const [symbol, decimals] = await Promise.all([
    view(addr, SEL.symbol).then(decString).catch(() => shortAddr(addr)),
    view(addr, SEL.decimals).then((h) => {
      if (!/^0x[0-9a-fA-F]{64}$/.test(h)) throw new Error("the reward token did not return valid decimals");
      return Number(decUint(h));
    }),
  ]);
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 255) throw new Error("invalid reward token decimals");
  return { symbol, decimals };
}

// Every (group, token) pair the distributor has been funded for, from its Fund logs, with the lifetime amount.
async function discoverFunding(info, projectId) {
  const funded = new Map();
  const logs = await getLogs(distributor(), [TOPIC.Fund, "0x" + encAddress(info.stToken)], await projectStartBlock(ctx.chainId, projectId));
  for (const log of logs) {
    if (!log.topics?.[2] || !log.topics?.[3]) continue;
    const groupId = decUint(log.topics[2]);
    const token = decAddress(log.topics[3]).toLowerCase();
    const id = `${groupId}:${token}`;
    const row = funded.get(id) || { groupId, token, funded: 0n };
    row.funded += decUint(log.data, 1);
    funded.set(id, row);
  }
  return funded;
}

// The rows to show: every funded pair, plus the underlying token and any token checked by hand under every
// discovered group, so a holder can always look for rewards where funding logs were unavailable.
function rewardRows(info, funded) {
  const known = (rewardTokens[ctx.currentId.toString()] ??= new Set([info.stakedToken.toLowerCase()]));
  const groups = [...new Set([0n, ...[...funded.values()].map((row) => row.groupId)])].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const rows = new Map(funded);
  for (const groupId of groups) {
    for (const token of known) {
      const id = `${groupId}:${token}`;
      if (!rows.has(id)) rows.set(id, { groupId, token, funded: 0n });
    }
  }
  return { groups, rows: [...rows.values()] };
}

async function renderRewards() {
  if (ctx.currentId === null || !distributor()) return;
  const current = currentView();
  const info = await projectInfo(ctx.currentId);
  if (!current()) return;
  const holder = account();
  // Funding is discovered from the distributor's own Fund logs; the chunked reader keeps hosted RPC range limits
  // from silently hiding funded groups. A failed scan still shows the hand-checked tokens under group 0.
  let funded = new Map();
  try {
    funded = await discoverFunding(info, ctx.currentId);
  } catch (error) {
    console.error("reward discovery failed", error);
  }
  if (!current()) return;
  const { groups, rows } = rewardRows(info, funded);
  ctx.rewardGroups = groups;
  // Cross-chain receiver: one per (sticky token, group). Show the selected destination token's arrivals there.
  const receiverFactoryAddr = stickyDeploymentFor(ctx.chainId).rewardReceiverFactory;
  if (receiverFactoryAddr) {
    try {
      const groupId = fundGroupId();
      const receiver = decAddress(await view(receiverFactoryAddr, SEL.predictReceiverOf, encAddress(info.stToken) + word(groupId)));
      if (!current()) return;
      ctx.receiver = receiver;
      $("receiver-addr").textContent = receiver;
      $("receiver-group").textContent = `${groupLabel(groupId)} (group ${groupId})`;
      const rewardToken = rewardTokenAddress($("bridge-reward-token")?.value || $("r-token").value, info.stakedToken);
      if (rewardToken.toLowerCase() === NATIVE_REWARD_TOKEN) throw new Error("receivers accept ERC-20 rewards");
      const meta = await rewardTokenMeta(rewardToken);
      const pending = decUint(await view(rewardToken, SEL.balanceOf, encAddress(receiver)));
      if (!current()) return;
      $("receiver-pending").textContent = `${formatUnits(pending, meta.decimals, meta.decimals)} ${meta.symbol}`;
    } catch {
      if (!current()) return;
      $("receiver-pending").textContent = "Select a destination reward token to check arrivals";
    }
  }
  // The direct split route: the distributor is itself a split hook, the split's beneficiary field names the
  // sticky token whose stickers the funds reward, and its projectId field names the reward group.
  $("rr-hook").textContent = distributor();
  $("rr-beneficiary").textContent = info.stToken;
  renderRecipeGroup();
  let schedule = null;
  try { schedule = await rewardSchedule(); } catch (error) { console.error("reward schedule failed", error); }
  if (!current()) return;
  $("rewards-round").textContent = schedule ? roundSentence(schedule) : "The reward round could not be read. Refresh to try again.";
  const entries = [];
  for (const row of rows) {
    const meta = await rewardTokenMeta(row.token).catch(() => null);
    if (!current()) return;
    // Bad token metadata must not hide valid rewards.
    if (!meta || !schedule) continue;
    const [position, roundState] = await Promise.all([
      holder
        ? rewardPosition(info, holder, row.groupId, row.token, schedule).catch(() => null)
        : null,
      view(distributor(), SEL.rewardRoundOf, encAddress(info.stToken) + word(row.groupId) + encAddress(row.token) + word(schedule.round)).catch(() => null),
    ]);
    if (!current()) return;
    const empty = { collectable: 0n, vesting: 0n, earned: 0n, nextUnlockAt: null, unlockedAt: null };
    const mine = position || empty;
    const fundedThisRound = roundState ? decUint(roundState, 0) : 0n;
    if (row.funded === 0n && fundedThisRound === 0n && mine.collectable === 0n && mine.vesting === 0n && mine.earned === 0n
      && !(row.groupId === 0n && row.token === info.stakedToken.toLowerCase())) continue;
    entries.push({ ...row, meta, position: mine, fundedThisRound, collectable: mine.collectable });
  }
  await renderAutoStick();
  if (!current()) return;
  const list = $("rewards-list");
  list.innerHTML = "";
  for (const entry of entries) {
    // The underlying-token row defaults to one-click claim-and-stick wherever the hook accepts the adapter as
    // payer (creator pre-approval or personal trust); every other reward token keeps normal claiming.
    const { position } = entry;
    const collectLabel = position.collectable > 0n ? "Collect" : position.earned > 0n ? "Start vesting" : "";
    let action = collectLabel ? `<button type="button" class="ghost" data-claim>${collectLabel}</button>` : "";
    const as = ctx.autoStick;
    const canStick = as && (as.projectGranter || as.personallyTrusted);
    if (entry.token === info.stakedToken.toLowerCase() && canStick && position.collectable > 0n) {
      action = `<button type="button" data-claim-stick>Claim &amp; stick</button><button type="button" class="ghost" data-claim>Collect only</button>`;
    }
    const card = document.createElement("div");
    card.className = "reward-card";
    card.innerHTML = `<div class="reward-head"><b>${esc(groupLabel(entry.groupId))}</b> <span class="mut">group ${esc(entry.groupId)}</span>`
      + `<span class="reward-token">${tok(entry.token, entry.meta.symbol)}</span></div>`
      + `<dl class="reward-kv">${rewardLines(position, entry.meta, entry.funded, entry.fundedThisRound, schedule)
        .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>`
      + (action ? `<div class="reward-actions">${action}</div>` : "");
    card.querySelector("[data-claim]")?.addEventListener("click", guard(() => claimReward(entry.token, entry.groupId)));
    card.querySelector("[data-claim-stick]")?.addEventListener("click", guard(claimAndStick));
    list.appendChild(card);
  }
  if (!list.children.length) list.innerHTML = `<div class="reward-card mut">No rewards yet. Send some with the button above.</div>`;
  $("rewards-tenure-note").classList.toggle("hide", !entries.some((entry) => entry.groupId !== 0n));
  if (typeof renderBridgeFunding === "function") await renderBridgeFunding();
}

function renderRecipeGroup() {
  const { groupId, text } = groupNote($("rr-min-weeks").value, $("rr-max-weeks").value);
  $("rr-group").textContent = groupId === null ? "–" : `${groupId} (${groupLabel(groupId)})`;
  $("rr-group-note").textContent = text;
}

function renderFundGroupNote() {
  $("r-group-note").textContent = groupNote($("r-min-weeks").value, $("r-max-weeks").value).text;
}

async function fundRewards() {
  const action = beginAction();
  const { holder } = action;
  const info = await projectInfo(ctx.currentId);
  const tokenAddr = rewardTokenAddress($("r-token").value, info.stakedToken);
  const meta = await rewardTokenMeta(tokenAddr);
  const amount = positiveAmount($("r-amount").value, meta.decimals);
  const groupId = fundGroupId();
  const pretty = `${formatUnits(amount, meta.decimals, meta.decimals)} ${meta.symbol}`;
  actionAddress(distributor(), "rewards distributor");
  // The distributor is the source of truth for group encoding; a stake-age group also needs the token registered.
  if (decUint(await view(distributor(), SEL.isValidGroupId, word(groupId))) !== 1n) throw new Error("the distributor does not accept this stake-age window");
  await requireTokenBalance(tokenAddr, holder, amount, meta);
  const native = tokenAddr.toLowerCase() === NATIVE_REWARD_TOKEN;
  const txs = native ? [] : await tokenApprovalTxs(tokenAddr, distributor(), amount, meta);
  const who = `${groupLabel(groupId)} (group ${groupId})`;
  txs.push({
    label: "Fund stuck holders",
    to: distributor(),
    fn: "fund(address hook, address token, uint256 amount, uint256 groupId)",
    args: [
      ["STUCK IN", bind("hook", info.stToken, { names: named([info.stToken, stickyLabel(info)]) })],
      ["REWARD TOKEN", bind("token", tokenAddr, { names: named([tokenAddr, meta.symbol]) })],
      ["AMOUNT", bind("amount", amount, { kind: "units", decimals: meta.decimals, symbol: meta.symbol })],
      ["WHO", bind("groupId", groupId, { kind: "group" })],
      ["SPLIT", groupSentence(groupId)],
    ],
    data: SEL.fund + encode(["address", "address", "uint256", "uint256"], [info.stToken, tokenAddr, amount, groupId]),
    ...(native ? { value: `0x${amount.toString(16)}`, valueNote: "the reward itself" } : {}),
  });
  if (!(await reviewAction(action, `Fund stuck holders: ${pretty}`, txs, [["Send", pretty], ["To", who], ["How", groupSentence(groupId)]]))) return;
  try { $("fund-dialog").close(); } catch {}
  (rewardTokens[ctx.currentId.toString()] ??= new Set()).add(tokenAddr.toLowerCase());
  txStatus("Sticks funded", "ok");
  await renderRewards();
}

async function claimReward(tokenAddr, groupId = 0n) {
  const action = beginAction();
  const { holder } = action;
  const info = await projectInfo(ctx.currentId);
  tokenAddr = rewardTokenAddress(tokenAddr, info.stakedToken);
  groupId = BigInt(groupId);
  const meta = await rewardTokenMeta(tokenAddr);
  const collectable = decUint(await view(distributor(), SEL.collectableFor,
    encAddress(info.stToken) + word(groupId) + encAddress(holder) + encAddress(tokenAddr)));
  if (collectable === 0n && !(await hasRewardsToVest(info, holder, tokenAddr, groupId))) {
    throw new Error("there are no rewards to unlock or collect yet");
  }
  // collectVestedRewards starts vesting historical rewards itself; a separate beginVesting would waste a transaction.
  const tx = {
    label: collectable > 0n ? "Collect unlocked rewards" : "Start unlocking eligible rewards",
    to: distributor(),
    fn: "collectVestedRewards(address hook, uint256 groupId, uint256[] tokenIds, address[] tokens, address beneficiary)",
    args: [
      ["STUCK IN", bind("hook", info.stToken, { names: named([info.stToken, stickyLabel(info)]) })],
      ["HOLDER", bind("tokenIds", [BigInt(holder)], { kind: "holders" })],
      ["GROUP", bind("groupId", groupId, { kind: "group" })],
      ["REWARD TOKEN", bind("tokens", [tokenAddr], { names: named([tokenAddr, meta.symbol]) })],
      ["BENEFICIARY", bind("beneficiary", holder)],
      ["READY", `${formatUnits(collectable, meta.decimals, meta.decimals)} ${meta.symbol}`],
      ["EFFECT", "Collects unlocked rewards and starts vesting finished rounds. This round's rewards stay locked until it ends."],
      ...(groupId === 0n ? [] : [["FORFEIT", "Stake-age rewards pay only stake you still hold. Unstick before claiming and they stay in the pot."]]),
    ],
    data: SEL.collectVestedRewards
      + encode(["address", "uint256", "uint256[]", "address[]", "address"], [info.stToken, groupId, [BigInt(holder)], [tokenAddr], holder]),
  };
  await actionCall(tx.to, tx.data, holder);
  if (!(await reviewAction(action, `Claim ${meta.symbol} rewards`, [tx]))) return;
  txStatus(collectable > 0n ? "Rewards collected; eligible past rewards are unlocking" : "Eligible past rewards are unlocking", "ok");
  await renderRewards();
}

// ---------------------------------------------------------------- auto-stick
// Opt-in compounding: unlocked underlying-token rewards are collected and restuck for the same holder by the
// immutable StickyAutoStick adapter. Permission truth always comes from chain reads, never from events.
const AS_STATUS = {
  READY: 0, DISABLED: 1, INVALID_PROJECT: 2, COOLDOWN: 3, BELOW_MINIMUM: 4, NOT_TRUSTED: 5,
  INSUFFICIENT_ALLOWANCE: 6, ZERO_ISSUANCE: 7,
};
const UNLIMITED = (1n << 256n) - 1n;

// Reward unlock schedule is a distributor immutable (round length × number of rounds), so read it once and cache.
let asUnlockSchedule;
async function unlockScheduleOf() {
  if (asUnlockSchedule !== undefined) return asUnlockSchedule;
  const d = distributor();
  if (!d) return (asUnlockSchedule = null);
  try {
    const [roundHex, roundsHex] = await Promise.all([
      view(d, SEL.ROUND_DURATION),
      view(d, SEL.VESTING_ROUNDS),
    ]);
    const roundDuration = Number(decUint(roundHex));
    const rounds = Number(decUint(roundsHex));
    asUnlockSchedule = roundDuration > 0 && rounds > 0 ? { roundDuration, rounds, total: roundDuration * rounds } : null;
  } catch {
    asUnlockSchedule = null;
  }
  return asUnlockSchedule;
}

// One plain-language sentence describing how gradually rewards unlock, or "" when instant / unknown.
function unlockScheduleSentence(sched) {
  if (!sched || sched.rounds <= 1) return "";
  return `Rewards unlock over ${sched.rounds} rounds, about ${Math.round(100 / sched.rounds)}% every ${formatDuration(sched.roundDuration)}, `
    + `all of it ${formatDuration(sched.total)} after unlocking starts.`;
}
let asCooldownChoice = 604_800;
let asAllowanceChoice = "unlimited";
let asDialogMode = "enable";

// The reward groups a holder's underlying-token rewards sit in: every discovered group with a collectable balance.
// The adapter takes this list and applies the holder's minimum to the combined amount; an empty list reverts, so
// group 0 stands in when nothing is ready yet.
async function stakedRewardGroups(info, holder) {
  const groups = ctx.rewardGroups?.length ? ctx.rewardGroups : [0n];
  const amounts = await Promise.all(groups.map((groupId) => view(distributor(), SEL.collectableFor,
    encAddress(info.stToken) + word(groupId) + encAddress(holder) + encAddress(info.stakedToken)).then(decUint).catch(() => 0n)));
  const ready = groups.filter((_, index) => amounts[index] > 0n);
  return { groupIds: ready.length ? ready : [0n], collectable: amounts.reduce((sum, amount) => sum + amount, 0n) };
}

// The discovered groups with completed, unclaimed rounds the holder has a share of.
async function vestableRewardGroups(info, holder) {
  const groups = ctx.rewardGroups?.length ? ctx.rewardGroups : [0n];
  const flags = await Promise.all(groups.map((groupId) => hasRewardsToVest(info, holder, info.stakedToken, groupId)));
  return groups.filter((_, index) => flags[index]);
}


async function autoStickState() {
  if (ctx.currentId === null || !autoStickAdapter() || !account()) return null;
  const info = await projectInfo(ctx.currentId);
  const { groupIds } = await stakedRewardGroups(info, account());
  const args = word(ctx.currentId) + encAddress(account());
  const [statusHex, configHex, granterHex, trustedHex] = await Promise.all([
    view(autoStickAdapter(), SEL.asStatusOf, encode(["uint256", "address", "uint256[]"], [ctx.currentId, account(), groupIds])),
    view(autoStickAdapter(), SEL.asConfigOf, args),
    view(ctx.hook, SEL.isGranterOf, word(ctx.currentId) + encAddress(autoStickAdapter())),
    view(ctx.hook, SEL.isTrustedSenderOf, word(ctx.currentId) + encAddress(account()) + encAddress(autoStickAdapter())),
  ]);
  return {
    info,
    groupIds,
    status: Number(decUint(statusHex, 0)),
    collectable: decUint(statusHex, 1),
    allowance: decUint(statusHex, 2),
    nextCompoundAt: Number(decUint(statusHex, 3)),
    minimum: decUint(configHex, 0),
    cooldown: Number(decUint(configHex, 1)),
    lastCompoundedAt: Number(decUint(configHex, 2)),
    enabled: decUint(configHex, 3) === 1n,
    // Creator-level pre-approval: the project launched with the adapter as a granter, so no per-holder trust tx.
    projectGranter: decUint(granterHex) === 1n,
    personallyTrusted: decUint(trustedHex) === 1n,
  };
}

function asStatusLine(state) {
  const { info } = state;
  const now = Math.floor(Date.now() / 1000);
  switch (state.status) {
    case AS_STATUS.READY:
      return "Ready to auto-stick";
    case AS_STATUS.COOLDOWN:
      return `Next auto-stick in ${formatDuration(Math.max(0, state.nextCompoundAt - now))}`;
    case AS_STATUS.BELOW_MINIMUM:
      return `${formatUnits(state.collectable, info.decimals)} ${info.symbol} ready | minimum `
        + `${formatUnits(state.minimum, info.decimals)}`;
    case AS_STATUS.NOT_TRUSTED:
      return "Permission removed | repair setup";
    case AS_STATUS.INSUFFICIENT_ALLOWANCE:
      return "Allowance exhausted | renew";
    case AS_STATUS.ZERO_ISSUANCE:
      return "Wait for more rewards: the current amount is too small to mint a Sticky token unit";
    default:
      return "";
  }
}

async function renderAutoStick() {
  const current = currentView();
  const card = $("autostick-card");
  let state = null;
  try {
    state = await autoStickState();
  } catch {}
  if (!current()) return;
  ctx.autoStick = state;
  // Fail closed: no adapter configured (or a misconfigured project) means no auto-stick UI at all.
  if (!state || state.status === AS_STATUS.INVALID_PROJECT) {
    card.classList.add("hide");
    if (state) status("auto-stick is misconfigured for this project", "err");
    return;
  }
  // Every read finishes before the card changes, so a superseded render never leaves it half drawn.
  await unlockScheduleOf();
  // Offer keeper-style vesting kickoff only when it would actually succeed.
  let canBeginVesting = false;
  if (state.enabled) {
    try {
      canBeginVesting = (await vestableRewardGroups(state.info, account())).length > 0;
    } catch {}
  }
  if (!current()) return;
  const { info } = state;
  $("as-heading").textContent = `Auto-stick ${info.symbol} rewards`;
  $("as-blurb").textContent = `Stick your ${info.symbol} rewards into ${stickyLabel(info)} as they unlock.`;
  $("as-toggle").textContent = state.enabled ? "Turn off auto-stick" : "Turn on auto-stick";

  // Same value-over-explanation formatting as the trusted-senders "None yet" block.
  let stateHtml;
  if (!state.enabled) {
    stateHtml = `<strong>Off</strong><span>Unlocked ${esc(info.symbol)} rewards stay claimable until you collect `
      + `them.</span>`;
  } else {
    stateHtml = `<strong>On</strong><span>Unlocked ${esc(info.symbol)} rewards auto-stick when at least `
      + `${formatUnits(state.minimum, info.decimals)} ${esc(info.symbol)} is ready, at most once every `
      + `${formatDuration(state.cooldown)}.</span>`;
    if (state.lastCompoundedAt) {
      stateHtml += `<span>Last auto-stick: ${ago(state.lastCompoundedAt)}</span>`;
    }
    const line = asStatusLine(state);
    if (line) stateHtml += `<div style="font-size:13px">${esc(line)}</div>`;
  }
  $("as-state").innerHTML = `<div class="trusted-empty">${stateHtml}</div>`;

  $("as-stick-now").classList.toggle("hide", !(state.enabled && state.status === AS_STATUS.READY));
  $("as-settings").classList.toggle("hide", !state.enabled);
  const repair = $("as-repair");
  repair.classList.toggle(
    "hide",
    !(state.enabled && (state.status === AS_STATUS.NOT_TRUSTED || state.status === AS_STATUS.INSUFFICIENT_ALLOWANCE)),
  );
  repair.textContent = state.status === AS_STATUS.NOT_TRUSTED ? "Repair permission" : "Renew allowance";
  $("as-begin-vesting").classList.toggle("hide", !canBeginVesting);
  card.classList.remove("hide");
}

// The auto-stick transaction plan pieces, shared by enable, disable, settings, and repair flows.
function asApproveTx(info, amount) {
  const pretty = amount === UNLIMITED ? "unlimited" : `${formatUnits(amount, info.decimals, info.decimals)} ${info.symbol}`;
  return {
    label: `Allow the auto-stick contract to move eligible ${info.symbol} rewards`,
    to: info.stakedToken,
    fn: "approve(address spender, uint256 amount)",
    args: [
      ["SPENDER", bind("spender", autoStickAdapter(), { names: named([autoStickAdapter(), "StickyAutoStick"]) })],
      ["ALLOWANCE", bind("amount", amount, { kind: "units", unlimited: true, decimals: info.decimals, symbol: info.symbol })],
      ["SCOPE", "Only rewards it just delivered to you, only to stick them for you."],
    ],
    data: SEL.approve + encode(["address", "uint256"], [autoStickAdapter(), amount]),
  };
}

function asTrustTx(info, trusted) {
  return {
    label: trusted
      ? `Allow the auto-stick contract to stick ${info.symbol} for you`
      : `Stop the auto-stick contract from sticking ${info.symbol} for you`,
    to: ctx.hook,
    fn: "setTrustedSenderFor(uint256 projectId, address sender, bool trusted)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["SENDER", bind("sender", autoStickAdapter(), { names: named([autoStickAdapter(), "StickyAutoStick"]) })],
      ["TRUSTED", bind("trusted", trusted, { yes: "yes, it can add stakes to your position", no: "no" })],
    ],
    data: SEL.setTrustedSenderFor + word(ctx.currentId) + encAddress(autoStickAdapter()) + word(trusted ? 1 : 0),
  };
}

function asConfigTx(info, enabled, minimum, cooldown) {
  if (minimum <= 0n || minimum >= 1n << 128n) {
    throw new Error("the auto-stick minimum must fit in uint128 and be greater than zero");
  }
  if (cooldown < 86400n || cooldown > 2592000n) throw new Error("auto-stick cooldown must be between 1 and 30 days");
  return {
    label: enabled
      ? `Auto-stick unlocked ${info.symbol} rewards when at least ${formatUnits(minimum, info.decimals, info.decimals)} `
        + `${info.symbol} is ready, no more than once every ${formatDuration(cooldown)}`
      : "Turn off auto-stick",
    to: autoStickAdapter(),
    fn: "setConfigFor(uint256 projectId, bool enabled, uint128 minimumAmount, uint48 cooldown)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["ENABLED", bind("enabled", enabled)],
      ["MINIMUM", bind("minimumAmount", minimum, { kind: "units", decimals: info.decimals, symbol: info.symbol })],
      ["COOLDOWN", bind("cooldown", cooldown, { kind: "duration" })],
      ["EFFECT", enabled
        ? "Rewards can only be added to your Sticky position. They are never sent elsewhere or taken by the keeper."
        : "Future rewards stay claimable as usual."],
    ],
    data: SEL.asSetConfigFor + word(ctx.currentId) + word(enabled ? 1 : 0) + word(minimum) + word(cooldown),
  };
}

function asDisableTxs(info, state) {
  return [
    asConfigTx(info, false, state.minimum, BigInt(state.cooldown)),
    // On creator-pre-approved projects there may be no per-holder trust to revoke.
    ...(state.personallyTrusted ? [asTrustTx(info, false)] : []),
    ...(state.allowance > 0n ? [{
      ...asApproveTx(info, 0n),
      label: `Remove the auto-stick contract's ${info.symbol} allowance`,
    }] : []),
  ];
}

function openAutoStickDialog(mode) {
  const state = ctx.autoStick;
  if (!state) return;
  const { info } = state;
  asDialogMode = mode;
  $("as-dialog-title").textContent = mode === "settings" ? "Auto-stick settings" : "Turn on auto-stick";
  const dialogSchedule = unlockScheduleSentence(asUnlockSchedule || null);
  $("as-dialog-blurb").textContent = dialogSchedule;
  $("as-min-label").textContent = `MINIMUM ${info.symbol.toUpperCase()} PER AUTO-STICK`;
  $("as-min").value = state.minimum > 0n ? formatUnits(state.minimum, info.decimals, info.decimals) : "1";
  asCooldownChoice = state.cooldown || 604_800;
  for (const preset of document.querySelectorAll("[data-as-cooldown]")) {
    selectPreset(preset, Number(preset.dataset.asCooldown) === asCooldownChoice);
  }
  // Settings changes only touch the on-chain config; the allowance is set during enable/renew.
  $("as-allowance-wrap").classList.toggle("hide", mode === "settings");
  $("as-allowance-label").textContent = `ALLOWANCE CAP (${info.symbol.toUpperCase()})`;
  $("as-save").textContent = mode === "settings" ? "Save settings" : "Turn on auto-stick";
  $("autostick-dialog").showModal();
}

async function saveAutoStick() {
  const action = beginAction();
  const state = await autoStickState();
  if (!state || state.status === AS_STATUS.INVALID_PROJECT) throw new Error("auto-stick is unavailable for this project");
  ctx.autoStick = state;
  const { info } = state;
  const minimum = positiveAmount($("as-min").value, info.decimals);
  const cooldown = BigInt(asCooldownChoice);
  const txs = [];
  if (asDialogMode === "settings") {
    if (!state.enabled) throw new Error("auto-stick was turned off; open its setup again to enable it");
    txs.push(asConfigTx(info, true, minimum, cooldown));
  } else {
    // Renewals can start enabled. Disable first so a keeper cannot use a new allowance with the old settings.
    if (state.enabled) txs.push(asConfigTx(info, false, state.minimum, BigInt(state.cooldown)));
    const allowance = asAllowanceChoice === "unlimited"
      ? UNLIMITED
      : parseUnits($("as-allowance").value || "0", info.decimals);
    if (allowance === 0n) throw new Error("set an allowance cap, or choose unlimited");
    txs.push(...await tokenApprovalTxs(info.stakedToken, autoStickAdapter(), allowance, info, asApproveTx(info, allowance), true));
    // Skip the trust step when the project pre-approved the adapter at launch, or it's already granted
    // (repair re-runs land here too).
    if (!state.projectGranter && !state.personallyTrusted) txs.push(asTrustTx(info, true));
    // The config is enabled last so a partially completed setup cannot compound.
    txs.push(asConfigTx(info, true, minimum, cooldown));
  }
  const title = asDialogMode === "settings"
    ? `Auto-stick settings for ${stickyLabel(info)}`
    : `Turn on auto-stick for ${stickyLabel(info)}`;
  const summary = [
    ["Auto-stick when", `at least ${formatUnits(minimum, info.decimals, info.decimals)} ${info.symbol} is ready`],
    ["At most", `once every ${formatDuration(Number(cooldown))}`],
  ];
  if (!(await reviewAction(action, title, txs, summary))) return;
  try { $("autostick-dialog").close(); } catch {}
  txStatus(asDialogMode === "settings" ? "Auto-stick settings saved" : "Auto-stick is on", "ok");
  await renderRewards();
}

async function toggleAutoStick() {
  const action = beginAction();
  const state = await autoStickState();
  ctx.autoStick = state;
  if (!state) return;
  if (!state.enabled) return openAutoStickDialog("enable");
  const { info } = state;
  const txs = asDisableTxs(info, state);
  if (!(await reviewAction(action, `Turn off auto-stick for ${stickyLabel(info)}`, txs))) return;
  txStatus("Auto-stick is off", "ok");
  await renderRewards();
}

async function repairAutoStick() {
  const action = beginAction();
  const state = await autoStickState();
  ctx.autoStick = state;
  if (!state) return;
  if (state.status === AS_STATUS.INSUFFICIENT_ALLOWANCE) return openAutoStickDialog("enable");
  if (state.projectGranter || state.personallyTrusted) throw new Error("auto-stick permission is already enabled");
  const { info } = state;
  const txs = [asTrustTx(info, true)];
  if (!(await reviewAction(action, `Repair auto-stick for ${stickyLabel(info)}`, txs))) return;
  txStatus("Auto-stick permission restored", "ok");
  await renderRewards();
}

async function autoStickNow() {
  const action = beginAction();
  const { holder } = action;
  const state = await autoStickState();
  ctx.autoStick = state;
  if (!state) return;
  if (state.status !== AS_STATUS.READY) throw new Error("auto-stick is not ready; refresh its settings and reward balance");
  const { info } = state;
  const expectedMint = await previewStickMint(ctx.currentId, info, state.collectable, holder, autoStickAdapter());
  const groupIds = state.groupIds ?? [0n];
  const txs = [{
    label: "Stick ready rewards now",
    to: autoStickAdapter(),
    fn: "compoundFor(uint256 projectId, address holder, uint256[] groupIds)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["HOLDER", bind("holder", holder)],
      ["GROUPS", bind("groupIds", groupIds, { kind: "groups" })],
      ["READY", `${formatUnits(state.collectable, info.decimals)} ${info.symbol}`],
      ["ESTIMATED STICKY TOKENS", `${formatUnits(expectedMint, 18, 18)} ${info.stSymbol}`],
      ["ISSUANCE", "Priced at the backing when it runs. A mint of zero tokens reverts."],
      ["EFFECT", `Collects your unlocked ${info.symbol} rewards and sticks them for you in a new tranche.`],
    ],
    data: SEL.asCompoundFor + encode(["uint256", "address", "uint256[]"], [ctx.currentId, holder, groupIds]),
  }];
  if (!(await reviewAction(action, `Stick ready ${info.symbol} rewards`, txs, [["Stick", `${formatUnits(state.collectable, info.decimals)} ${info.symbol} of unlocked rewards`]]))) return;
  txStatus("Rewards auto-stuck", "ok");
  await renderProject(ctx.currentId);
}

async function beginAutoStickVesting() {
  const action = beginAction();
  const { holder } = action;
  const state = await autoStickState();
  ctx.autoStick = state;
  if (!state) return;
  const { info } = state;
  if (!state.enabled) throw new Error("turn on auto-stick before starting automatic reward unlocking");
  const groupIds = await vestableRewardGroups(info, holder);
  if (!groupIds.length) throw new Error("there are no new reward rounds to unlock");
  const txs = [{
    label: "Start unlocking",
    to: autoStickAdapter(),
    fn: "beginVestingFor(uint256 projectId, address holder, uint256[] groupIds)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["HOLDER", bind("holder", holder)],
      ["GROUPS", bind("groupIds", groupIds, { kind: "groups" })],
      ["EFFECT", `Starts the unlock schedule for your ${info.symbol} rewards. No tokens move.`],
    ],
    data: SEL.asBeginVestingFor + encode(["uint256", "address", "uint256[]"], [ctx.currentId, holder, groupIds]),
  }];
  if (!(await reviewAction(action, `Start unlocking ${info.symbol} rewards`, txs))) return;
  txStatus("Unlocking started", "ok");
  await renderRewards();
}
window.stickNowFor = () => guard(autoStickNow)({ currentTarget: document.activeElement });

// One-click claim: the holder's own call claims their vested rewards and sticks them atomically. No settings,
// no cooldown — an exact-amount approve is bundled only when the current allowance doesn't cover the claim.
async function claimAndStick() {
  const action = beginAction();
  const { holder } = action;
  const state = await autoStickState();
  ctx.autoStick = state;
  if (!state) return;
  const { info } = state;
  const { groupIds, collectable } = await stakedRewardGroups(info, holder);
  if (collectable === 0n) throw new Error("nothing is claimable yet. Rewards unlock a round after you collect them");
  // A pending trust step cannot be assumed by a read-only preview. The adapter itself quotes after setup and
  // rejects zero issuance atomically; show a numeric estimate only when the actual payer can preview now.
  const expectedMint = state.projectGranter || state.personallyTrusted
    ? await previewStickMint(ctx.currentId, info, collectable, holder, autoStickAdapter())
    : null;
  const pretty = `${formatUnits(collectable, info.decimals, info.decimals)} ${info.symbol}`;
  const txs = await tokenApprovalTxs(info.stakedToken, autoStickAdapter(), collectable, info, {
    ...asApproveTx(info, collectable), label: `Allow the auto-stick contract to move this claim of ${pretty}`,
  });
  if (!state.projectGranter && !state.personallyTrusted) txs.push(asTrustTx(info, true));
  txs.push({
    label: "Claim & stick",
    to: autoStickAdapter(),
    fn: "stickRewardsFor(uint256 projectId, uint256[] groupIds)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["GROUPS", bind("groupIds", groupIds, { kind: "groups" })],
      ["CLAIM", pretty],
      ["ISSUANCE", "Priced at the backing when it runs. A mint of zero tokens reverts."],
      ["EFFECT", `Your unlocked ${info.symbol} rewards stick for you in a new tranche, in the same transaction.`],
    ],
    data: SEL.asStickRewardsFor + encode(["uint256", "uint256[]"], [ctx.currentId, groupIds]),
  });
  if (!(await reviewAction(action, `Claim & stick ${pretty}`, txs, [
    ["Claim", pretty],
    ["Estimated Sticky tokens", expectedMint === null ? "quoted on chain after your trust step" : `${formatUnits(expectedMint, 18, 18)} ${info.stSymbol}`],
    ["Rate", "current backing price at execution; the amount can change before confirmation"],
  ]))) return;
  txStatus("Rewards claimed and stuck", "ok");
  await renderProject(ctx.currentId);
}

async function settleArrivals() {
  const action = beginAction();
  const { holder } = action;
  const info = await projectInfo(ctx.currentId);
  const receiverFactoryAddr = actionAddress(stickyDeploymentFor(ctx.chainId).rewardReceiverFactory, "reward receiver factory address");
  const tokenAddr = rewardTokenAddress($("bridge-reward-token")?.value || $("r-token").value, info.stakedToken);
  if (tokenAddr.toLowerCase() === NATIVE_REWARD_TOKEN) throw new Error("reward receivers settle ERC-20 tokens; fund ETH rewards directly");
  const meta = await rewardTokenMeta(tokenAddr);
  const groupId = fundGroupId();
  if (!isValidGroupId(groupId)) throw new Error("this stake-age window is not a valid reward group");
  const configuredDistributor = decAddress(await view(receiverFactoryAddr, SEL.DISTRIBUTOR));
  if (configuredDistributor.toLowerCase() !== distributor()?.toLowerCase()) {
    throw new Error("the reward receiver factory uses a different distributor");
  }
  const receiver = actionAddress(decAddress(await view(receiverFactoryAddr, SEL.predictReceiverOf, encAddress(info.stToken) + word(groupId))), "reward receiver");
  const pending = decUint(await view(tokenAddr, SEL.balanceOf, encAddress(receiver)));
  if (pending === 0n) throw new Error(`there are no ${meta.symbol} arrivals to settle`);
  const txs = [{
    label: "Settle arrivals",
    to: receiverFactoryAddr,
    fn: "settleFor(address stickyToken, uint256 groupId, address token)",
    args: [
      ["STUCK IN", bind("stickyToken", info.stToken, { names: named([info.stToken, stickyLabel(info)]) })],
      ["WHO", bind("groupId", groupId, { kind: "group" })],
      ["REWARD TOKEN", bind("token", tokenAddr, { names: named([tokenAddr, meta.symbol]) })],
      ["AMOUNT", `${formatUnits(pending, meta.decimals, meta.decimals)} ${meta.symbol}`],
      ["RECEIVER", receiver],
      ["EFFECT", "The receiver's whole balance becomes this round's rewards for that group."],
    ],
    data: SEL.settleFor + encode(["address", "uint256", "address"], [info.stToken, groupId, tokenAddr]),
  }];
  await actionCall(receiverFactoryAddr, txs[0].data, holder);
  if (!(await reviewAction(action, "Settle cross-chain arrivals", txs))) return;
  try { $("fund-dialog").close(); } catch {}
  txStatus("Arrivals settled into rewards", "ok");
  (rewardTokens[ctx.currentId.toString()] ??= new Set()).add(tokenAddr.toLowerCase());
  await renderRewards();
}

// ------------------------------------------------------------------- actions
function syncTransferSticky(info) {
  $("transfer-sticky")?.classList.toggle("hide", info.soulbound !== false);
}

async function transferSticky() {
  const projectId = ctx.currentId;
  const chainId = ctx.chainId;
  const info = await projectInfo(projectId);
  if (info.soulbound !== false) throw new Error("this sticky token is locked and cannot be transferred");
  const action = beginAction();
  if (action.chainId !== chainId || action.projectId !== projectId) {
    throw new Error("the chain or project changed; review this transfer again");
  }
  const { holder } = action;
  const recipient = actionAddress($("transfer-recipient").value, "recipient address");
  if (recipient.toLowerCase() === holder.toLowerCase()) throw new Error("choose a different recipient");
  const amount = positiveAmount($("transfer-amount").value, 18);
  await requireTokenBalance(info.stToken, holder, amount, { symbol: info.stSymbol });
  const pretty = `${formatUnits(amount, 18, 18)} ${info.stSymbol}`;
  const tx = {
    label: `Transfer ${pretty}`,
    to: info.stToken,
    fn: "transfer(address to, uint256 amount)",
    args: [
      ["RECIPIENT", bind("to", recipient)],
      ["AMOUNT", bind("amount", amount, { kind: "units", decimals: 18, symbol: info.stSymbol })],
      ["STREAK", "The moved tokens start a new tranche now for the recipient. Your remaining tranches keep their dates."],
      ["FULL TRANSFER", "Sending your whole balance ends your current streak."],
    ],
    data: "0xa9059cbb" + encode(["address", "uint256"], [recipient, amount]),
  };
  if (!(await reviewAction(action, `Transfer ${pretty}`, [tx], [
    ["Transfer", pretty], ["To", recipient], ["Transferred tranche", "the recipient's clock starts again now"],
  ]))) return;
  txStatus("Sticky tokens transferred", "ok");
  await renderProject(ctx.currentId);
}

async function stake() {
  const action = beginAction();
  const { holder } = action;
  const info = await projectInfo(ctx.currentId);
  const amount = positiveAmount($("stake-amount").value, info.decimals);
  const beneficiary = actionAddress($("stake-beneficiary")?.value || holder, "beneficiary address");
  const pretty = `${formatUnits(amount, info.decimals, info.decimals)} ${info.symbol}`;
  await requireTokenBalance(info.stakedToken, holder, amount, info);
  if (beneficiary.toLowerCase() !== holder.toLowerCase()) {
    const [granter, trusted] = await Promise.all([
      view(ctx.hook, SEL.isGranterOf, word(ctx.currentId) + encAddress(holder)),
      view(ctx.hook, SEL.isTrustedSenderOf, word(ctx.currentId) + encAddress(beneficiary) + encAddress(holder)),
    ]);
    if (decUint(granter) !== 1n && decUint(trusted) !== 1n) {
      throw new Error("this holder must trust your address before you can stick for them");
    }
  }
  const expectedMint = await previewStickMint(ctx.currentId, info, amount, beneficiary, holder);
  const txs = await tokenApprovalTxs(info.stakedToken, ctx.terminal, amount, info);
  txs.push({
    label: "Stick",
    to: ctx.terminal,
    fn: "pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)",
    args: [
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["TOKEN", bind("token", info.stakedToken, { names: named([info.stakedToken, info.symbol]) })],
      ["AMOUNT", bind("amount", amount, { kind: "units", decimals: info.decimals, symbol: info.symbol })],
      ["BENEFICIARY", bind("beneficiary", beneficiary)],
      ["MINIMUM STICKY TOKENS", bind("minReturnedTokens", expectedMint, { kind: "units", decimals: 18, symbol: info.stSymbol })],
      ["MEMO", bind("memo", "")],
      ["METADATA", bind("metadata", "0x")],
    ],
    data: SEL.pay
      + encode(
        ["uint256", "address", "uint256", "address", "uint256", "string", "bytes"],
        [ctx.currentId, info.stakedToken, amount, beneficiary, expectedMint, "", "0x"],
      ),
  });
  const receipt = `${formatUnits(expectedMint, 18, 18)} ${info.stSymbol}`;
  if (!(await reviewAction(action, `Stick ${pretty}`, txs, [
    ["Stick", pretty], ["Beneficiary", beneficiary], ["Minimum Sticky tokens", receipt],
  ]))) return;
  txStatus("Stick confirmed", "ok");
  await renderProject(ctx.currentId);
}

const MAX_TAX = 10000n;
// What unsticking `count` pays `holder`, read from the terminal's own views at one block:
// previewCashOutFrom gives the gross reclaim and the tax it applies; the fee then follows the terminal's
// rule. A feeless beneficiary pays none. Positive tax pays the fee on the whole reclaim; zero tax pays it
// only on the part covered by feeFreeSurplusOf. The fee is JBFees.standardFeeAmountFrom (amount / 40,
// JBConstants.STANDARD_FEE of 25 per 1,000), a compile-time constant with no view to read.
// The unstick dialog and the final review both call this, so the quote shown is the minimum sent.
async function unstickQuote(projectId, info, holder, count) {
  const block = await rpc("eth_blockNumber", []);
  if (!/^0x[0-9a-fA-F]+$/.test(block || "")) throw new Error("The RPC returned an invalid block for the unstick quote.");
  const read = (to, data) => rpc("eth_call", [{ from: holder, to, data }, block]);
  const [preview, feeFree, feelessRegistry] = await Promise.all([
    read(ctx.terminal, SEL.previewCashOutFrom + encode(
      ["address", "uint256", "uint256", "address", "address", "bytes"],
      [holder, projectId, count, info.stakedToken, holder, "0x"],
    )),
    read(ctx.terminal, SEL.feeFreeSurplusOf + word(projectId) + encAddress(info.stakedToken)).then(decUint),
    read(ctx.terminal, SEL.FEELESS_ADDRESSES).then(decAddress),
  ]);
  // JBRuleset is nine static words; then reclaimAmount, cashOutTaxRate, and an empty hook list.
  if (!/^0x(?:[0-9a-fA-F]{64}){13}$/.test(preview || "") || decUint(preview, 11) !== 384n || decUint(preview, 12) !== 0n) {
    throw new Error("the terminal did not return a valid unstick quote");
  }
  const gross = decUint(preview, 9);
  const tax = decUint(preview, 10);
  if (tax > MAX_TAX) throw new Error("the terminal did not return a valid unstick quote");
  const feeless = decUint(await read(feelessRegistry, SEL.isFeelessFor + encAddress(holder) + word(projectId) + encAddress(holder))) === 1n;
  const feeable = feeless ? 0n : tax > 0n ? gross : gross < feeFree ? gross : feeFree;
  const fee = feeable / 40n;
  return { gross, tax, fee, net: gross - fee, feeless, block };
}
async function poolBacking(projectId, info, reader = pageReader()) {
  const block = await reader.rpc("eth_blockNumber", []);
  if (!/^0x[0-9a-fA-F]+$/.test(block || "")) throw new Error("The RPC returned an invalid backing block.");
  const read = (to, selector, args = "") => reader.rpc("eth_call", [{ to, data: selector + args }, block]).then(decUint);
  const args = encAddress(reader.terminal) + word(projectId) + encAddress(info.stakedToken);
  const [rawBacking, supply, savedOrphaned] = await Promise.all([
    read(reader.store, SEL.storeBalanceOf, args),
    read(info.stToken, SEL.totalSupply),
    read(reader.hook, SEL.orphanedBalanceOf, word(projectId)),
  ]);
  if (savedOrphaned > rawBacking) throw new Error("The Sticky pool returned inconsistent backing accounting.");
  const orphaned = supply === 0n ? rawBacking : savedOrphaned;
  const sigma = rawBacking - orphaned;
  return {
    sigma, supply, rawBacking, orphaned, reward: info.reward, decimals: info.decimals, symbol: info.symbol, stSymbol: info.stSymbol,
  };
}

// Read the same core preview used by the adapter, including hook pricing, decimal rounding, and payer trust.
// JBRuleset has nine static ABI words; the beneficiary count follows it. Sticky reserves no tokens.
async function previewStickMint(projectId, info, amount, beneficiary, payer = beneficiary) {
  const result = await actionCall(ctx.terminal, SEL.previewPayFor + encode(
    ["uint256", "address", "uint256", "address", "bytes"],
    [projectId, info.stakedToken, amount, beneficiary, "0x"],
  ), payer);
  if (!/^0x(?:[0-9a-fA-F]{64}){13,}$/.test(result) || decUint(result, 11) !== 384n
    || decUint(result, 10) !== 0n) throw new Error("the terminal did not return a valid Sticky mint quote");
  const count = decUint(result, 9);
  if (count === 0n) throw new Error("this amount is too small or cannot be priced precisely enough at the current backing price");
  return count;
}

let stickQuoteSequence = 0;
async function renderStickQuote() {
  const sequence = ++stickQuoteSequence;
  const el = $("stake-quote");
  const pool = ctx.pool;
  if (!el) return;
  el.textContent = "";
  if (!pool) return;
  const field = $("stake-amount");
  let amount = 0n;
  try { amount = parseUnits(field.value || field.placeholder || "0", pool.decimals); } catch {}
  if (amount <= 0n) return;
  const projectId = ctx.currentId, chainId = ctx.chainId;
  const displayedAccount = account();
  const input = field.value;
  const payer = /^0x[0-9a-fA-F]{40}$/.test(displayedAccount || "") ? displayedAccount : "0x0000000000000000000000000000000000000000";
  const beneficiary = $("stake-beneficiary")?.value || payer;
  el.textContent = "Checking the current backing price…";
  const current = () => sequence === stickQuoteSequence && ctx.currentId === projectId && ctx.chainId === chainId
    && account() === displayedAccount && field.value === input && ($("stake-beneficiary")?.value || payer) === beneficiary;
  try {
    const info = await projectInfo(projectId);
    if (!current()) return;
    const mint = await previewStickMint(projectId, info, amount, beneficiary, payer);
    if (!current()) return;
    el.textContent = `Estimated mint: ${formatUnits(mint, 18)} ${pool.stSymbol}. The final review sets your minimum.`
      + (pool.reward === MAX_TAX ? " 100% stickiness bonus: unsticking returns no underlying tokens." : "");
  } catch (error) {
    if (current()) el.textContent = `Quote unavailable: ${error.message}`;
  }
}

let unstickQuoteSequence = 0;
async function renderUnstickQuote() {
  const sequence = ++unstickQuoteSequence;
  const el = $("unstake-quote");
  const pool = ctx.pool;
  if (!el) return;
  el.textContent = "";
  if (!pool || pool.supply === 0n) return;
  let count;
  try { count = parseUnits($("unstake-amount").value || "0", 18); } catch { return; }
  if (count <= 0n) return;
  if (pool.reward === MAX_TAX) {
    el.textContent = "100% stickiness bonus: unsticking burns your Sticky tokens and returns nothing.";
    return;
  }
  const holder = account();
  if (!/^0x[0-9a-fA-F]{40}$/.test(holder || "")) {
    el.textContent = "Connect a wallet to quote your unstick.";
    return;
  }
  const projectId = ctx.currentId, chainId = ctx.chainId, input = $("unstake-amount").value;
  const current = () => sequence === unstickQuoteSequence && ctx.currentId === projectId && ctx.chainId === chainId
    && account() === holder && $("unstake-amount").value === input;
  el.textContent = "Quoting from the terminal…";
  try {
    const info = await projectInfo(projectId);
    const quote = await unstickQuote(projectId, info, holder, count > pool.supply ? pool.supply : count);
    if (!current()) return;
    const amt = (v) => `${formatUnits(v, pool.decimals)} ${pool.symbol}`;
    const share = count >= pool.supply ? pool.sigma : (pool.sigma * count) / pool.supply;
    const stays = share > quote.gross ? share - quote.gross : 0n;
    el.textContent = `You get ${amt(quote.net)}.`
      + (stays > 0n ? ` ${amt(stays)} stays with the holders who remain.` : "")
      + (quote.fee > 0n ? ` ${amt(quote.fee)} goes to the protocol fee.` : quote.feeless ? " No protocol fee for this wallet." : " No protocol fee on this unstick.")
      + " The review uses this as your minimum.";
  } catch (error) {
    if (current()) el.textContent = `Quote unavailable: ${error.message}`;
  }
}

async function unstake() {
  const action = beginAction();
  const { holder } = action;
  const info = await projectInfo(ctx.currentId);
  // Use the token balance as the authoritative cap, including voluntary burns and incoming transfers.
  const count = positiveAmount($("unstake-amount").value, 18);
  const balance = decUint(await view(info.stToken, SEL.balanceOf, encAddress(holder)));
  if (count > balance) throw new Error("the unstick amount exceeds your sticky token balance");
  const pretty = `${formatUnits(count, 18, 18)} ${info.stSymbol}`;
  const encodeUnstake = (minimum) => SEL.cashOutTokensOf + encode(
    ["address", "uint256", "uint256", "address", "uint256", "address", "bytes"],
    [holder, ctx.currentId, count, info.stakedToken, minimum, holder, "0x"],
  );
  // The terminal's views price the exit, the same quote the dialog showed. The reviewed net becomes the
  // on-chain minimum; a worse outcome reverts and must be reviewed again.
  const { net: reclaim } = await unstickQuote(ctx.currentId, info, holder, count);
  // A preflight catches a revert the views cannot model. It never sets the amount.
  await actionCall(ctx.terminal, encodeUnstake(reclaim), holder);
  const txs = [];
  const state = await autoStickState();
  ctx.autoStick = state;
  if (state?.enabled && count === balance) txs.push(...asDisableTxs(info, state));
  const receive = `${formatUnits(reclaim, info.decimals, info.decimals)} ${info.symbol}`;
  txs.push({
    label: reclaim === 0n ? "Unstick without reclaiming tokens" : "Unstick",
    to: ctx.terminal,
    fn: "cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address beneficiary, bytes metadata)",
    args: [
      ["HOLDER", bind("holder", holder)],
      ["PROJECT", bind("projectId", ctx.currentId, { note: stickyLabel(info) })],
      ["UNSTICK", bind("cashOutCount", count, { kind: "units", decimals: 18, symbol: info.stSymbol })],
      ["RECLAIM AS", bind("tokenToReclaim", info.stakedToken, { names: named([info.stakedToken, info.symbol]) })],
      ["MINIMUM RECEIVED", bind("minTokensReclaimed", reclaim, { kind: "units", decimals: info.decimals, symbol: info.symbol })],
      ["BENEFICIARY", bind("beneficiary", holder)],
      ["METADATA", bind("metadata", "0x")],
      ...(reclaim === 0n ? [["EFFECT", "Your Sticky tokens are burned and no underlying tokens come back."]] : []),
    ],
    data: encodeUnstake(reclaim),
  });
  if (!(await reviewAction(action, `Unstick ${pretty}`, txs, [["Unstick", pretty], ["Minimum you receive", receive]]))) return;
  try { $("unstick-dialog").close(); } catch {}
  txStatus("Unstick confirmed", "ok");
  await renderProject(ctx.currentId);
}

async function deployStreaks() {
  return withStickyLaunchLock(async () => {
    const saved = stickyLaunchStore().load();
    if (saved) {
      showStickyLaunchDialog();
      await stickyLaunchController().run();
      return;
    }
    await prepareStickyLaunch();
  });
}

// One chain's deployStickyFor, reviewed from its decoded calldata.
function launchDeployTx(target, { token, tokenSymbol, name, symbol, projectUri, reward, soulbound }) {
  const { granters } = target;
  return {
    label: `Deploy ${symbol} on ${target.name}`,
    chainId: target.chainId,
    chainLabel: target.label,
    contractName: "StickyDeployer",
    to: target.deployer,
    fn: "deployStickyFor(address stakedToken, string name, string symbol, string projectUri, uint256 cashOutTaxRate, address[] granters, bool soulbound)",
    args: [
      ["LOCKS", bind("stakedToken", token, { names: named([token, tokenSymbol]) })],
      ["NAME", bind("name", name)],
      ["SYMBOL", bind("symbol", symbol)],
      ["STICKINESS BONUS", bind("cashOutTaxRate", reward, { kind: "bps", zero: "None", note: "cash out tax. Part of each unstick stays with the holders who remain" })],
      ["TRUSTED SENDERS", bind("granters", granters, { names: named([target.autoStickAdapter, "AutoStick, each holder opts in"]) })],
      ["TRANSFERS", bind("soulbound", soulbound, { yes: "Locked. The token can never change hands.", no: "Unlocked. Transfers restart the stickiness clock." })],
      ["LISTING", bind("projectUri", projectUri, { kind: "uri" })],
    ],
    value: `0x${target.fee.toString(16)}`,
    valueNote: "project creation fee",
    data: SEL.deployStickyFor
      + encode(
        ["address", "string", "string", "string", "uint256", "address[]", "bool"],
        [token, name, symbol, projectUri, reward, granters, soulbound],
      ),
  };
}

// The one Relayr prepayment that funds a multichain launch.
function relayrPaymentTx(session, details) {
  return {
    chainId: details.chainId, rpcUrl: session.fundingRpcs[details.chainId], from: session.owner,
    to: details.target, data: details.calldata, value: `0x${details.amount.toString(16)}`, sessionTag: session.id,
    label: `Pay Relayr to create ${session.symbol}`, contractName: "Relayr payment contract", fn: "prepayment(bytes16 bundle, uint40 deadline)",
    valueNote: "covers the quoted gas and creation fees on every chain",
    args: [["LAUNCH", session.symbol], ["CHAINS", session.targets.map((target) => target.name).join(", ")],
      ["QUOTE", bind("bundle", "0x" + details.bundleUuid.replaceAll("-", ""), { kind: "uuid" })],
      ["PAY BY", bind("deadline", details.deadline, { kind: "time" })]],
  };
}

async function prepareStickyLaunch() {
  const reward = $("d-add-reward").checked ? StickyLaunchPlan.bonusBasisPoints(rewardChoice, $("d-reward").value) : 0n;
  const soulbound = $("d-soulbound").value === "1";
  // Launch-time trusted senders (Extras). AutoStick is appended on every chain.
  const humanGranters = $("d-add-granters").checked ? StickyLaunchPlan.parseSenders($("d-granters").value) : [];

  const selectedChains = chainsForEnvironment(createEnvironment)
    .filter((chain) => createChainIds.has(chain.chainId));
  if (!selectedChains.length) {
    renderCreateChains();
    throw new Error("choose at least one chain");
  }
  for (const chain of selectedChains) {
    const blocker = launchChainBlocker(chain);
    if (blocker) throw new Error(`${chain.name} can't launch Sticky: ${blocker}.`);
  }
  if (!walletAccount && selectedChains.some((chain) => chain.chainId !== ctx.chainId)) {
    throw new Error("connect a wallet to deploy on more than the connected chain");
  }

  status(`checking ${selectedChains.length} ${selectedChains.length === 1 ? "chain" : "chains"}…`);
  const runtimes = await Promise.all(selectedChains.map((chain) => launchRuntime(chain.chainId).catch((error) => {
    throw new Error(`${chain.name}: ${error.message}`);
  })));
  const { address: token } = await resolveLaunchToken($("d-token").value, runtimes.map((runtime) => runtime.chainId));
  const targets = await Promise.all(runtimes.map(async (runtime) => {
    try {
      const [tokenSymbol, tokenName, tokenDecimals] = await Promise.all([
        viewAt(runtime, token, SEL.symbol).then(decString),
        viewAt(runtime, token, SEL.name).then(decString),
        viewAt(runtime, token, SEL.decimals).then((value) => Number(decUint(value))),
      ]);
      return { ...runtime, tokenSymbol, tokenName, tokenDecimals,
        granters: StickyLaunchPlan.launchGranters(humanGranters, runtime.autoStickAdapter, runtime.name) };
    } catch (error) {
      throw new Error(`${runtime.name}: ${error.message}`);
    }
  }));
  const { tokenSymbol, tokenName } = StickyLaunchPlan.checkSameToken(targets);
  status("");

  const useCustom = $("d-custom-name").checked;
  const defaults = StickyLaunchPlan.defaultNames(tokenName, tokenSymbol);
  const name = (useCustom && $("d-name").value.trim()) || defaults.name;
  const symbol = (useCustom && $("d-symbol").value.trim()) || defaults.symbol;
  const chainIds = targets.map((target) => target.chainId);
  const launchId = crypto.randomUUID();
  const projectUri = `data:application/json;charset=utf-8,${encodeURIComponent(JSON.stringify({
    protocol: "Sticky",
    version: 1,
    launchId,
    environment: createEnvironment,
    chains: chainIds,
  }))}`;
  const txs = targets.map((target) => launchDeployTx(target, { token, tokenSymbol, name, symbol, projectUri, reward, soulbound }));
  const owner = txAccount();
  if (!/^0x[0-9a-fA-F]{40}$/.test(owner || "")) throw new Error("Connect a wallet to create a Sticky token.");
  const fundingRpcs = Object.fromEntries(chainsForEnvironment(createEnvironment)
    .map((chain) => [chain.chainId, stickyDeploymentFor(chain.chainId).rpcUrl])
    .filter(([, url]) => typeof url === "string" && url));
  const { mode, center } = await launchListingPlan({ owner, targets, listing: {
    calls: txs.map(({ chainId, to, data }) => ({ chainId, to, data })), owner, name, symbol,
    stakedToken: token, stakedTokenSymbol: tokenSymbol, cashOutTaxRate: reward, soulbound, launchId, projectUri,
  } });
  stickyLaunchController().prepare({
    id: launchId, owner, mode, center, name, symbol,
    tokenSymbol, environment: createEnvironment, fundingRpcs,
    summary: [["Create", `${name} (${symbol})`], ["Backed by", tokenSymbol],
      ["On", targets.map((target) => target.name).join(", ")]],
    txs: txs.map((tx, i) => ({ ...tx, rpcUrl: targets[i].rpcUrl, from: owner, sessionTag: launchId })),
    targets: targets.map((target) => ({ chainId: target.chainId, name: target.name,
      deployer: target.deployer, controller: target.controller, projects: target.projects, rpcUrl: target.rpcUrl,
      expected: { stakedToken: token, cashOutTaxRate: reward.toString(), soulbound },
    })),
  });
  $("create-dialog").close();
  showStickyLaunchDialog();
  await stickyLaunchController().run();
}


// A launch is listed on Juicebox Center. Center sponsors it only when every chain is one it
// sponsors and StickyDeployer trusts the V6 forwarder there; otherwise the wallet pays.
async function launchListingPlan({ owner, targets, listing }) {
  const selfPaid = targets.length > 1 ? "relayr" : "direct";
  if (!window.STICKY_CONFIG?.centerUrl || !window.StickyCenter) {
    return { mode: selfPaid, center: { state: "unavailable", reason: "Juicebox Center is not configured on this site." } };
  }
  const envelope = StickyCenter.buildEnvelope(listing);
  const code = await rpcAt(targets[0].rpcUrl, "eth_getCode", [owner, "latest"]).catch(() => null);
  if (code !== "0x" && !/^0xef0100[0-9a-fA-F]{40}$/.test(code || "")) {
    return { mode: selfPaid, center: { state: "unavailable", envelope,
      reason: "Juicebox Center lists launches signed by a wallet address, and this account is a contract." } };
  }
  const sponsored = await StickyCenter.sponsoredPlan({ chainIds: targets.map((target) => target.chainId), isTrusted: async (chainId) => {
    const target = targets.find((item) => item.chainId === chainId);
    return decUint(await viewAt(target, target.deployer, StickyCenter.IS_TRUSTED_FORWARDER, encAddress(StickyCenter.FORWARDER))) === 1n;
  } });
  return { mode: sponsored ? "center" : selfPaid, center: { state: "pending", envelope } };
}

// Center's answers in plain words; its own text is kept for the record.
function centerRefusal(error) {
  if (!(error instanceof StickyCenter.CenterError)) return error.message;
  if (error.code === "unreachable") return "Juicebox Center could not be reached, or does not accept listings from this site yet.";
  if (error.code === "forbidden_origin") return "Juicebox Center does not accept listings from this site yet.";
  if (error.status === 429) return "Juicebox Center's listing limit is reached. Try again later.";
  if (error.code === "mismatch" || error.code === "malformed") return error.message;
  return `Juicebox Center refused the listing (${error.code}).`;
}
let listingStepNote = "";
function setListingStep(note) {
  listingStepNote = note;
  if (confirmPreSteps.length) {
    confirmPreSteps = confirmPreSteps.map((step) => ({ ...step, state: note === "Waiting for wallet" ? "current" : note === "Signed" ? "done" : "pending", note: note || step.note }));
    if ($("confirm-dialog").open) renderConfirmSteps();
  }
  if ($("sticky-launch-dialog")?.open) renderStickyLaunchRecovery();
}
async function signListing(owner, message) {
  if (!activeProvider || walletKind !== "injected") throw new Error("Connect a wallet to sign the launch listing.");
  if (txAccount().toLowerCase() !== owner.toLowerCase()) throw new Error(`Connect ${owner} to sign the launch listing.`);
  setListingStep("Waiting for wallet");
  try {
    const signature = await activeProvider.request({ method: "personal_sign", params: [StickyCenter.utf8Hex(message), owner] });
    setListingStep("Signed");
    return signature;
  } catch (error) {
    setListingStep("Not signed");
    throw error?.code === 4001 ? new Error("You declined the listing signature.") : error;
  }
}
function stickyLaunchListing() {
  const apiUrl = window.STICKY_CONFIG?.centerUrl;
  if (!apiUrl || !window.StickyCenter) return null;
  const client = StickyCenter.createClient({ apiUrl });
  const plain = async (fn) => { try { return await fn(); } catch (error) { throw new Error(centerRefusal(error)); } };
  return {
    forwarder: StickyCenter.FORWARDER,
    async publish(session) {
      const prepared = await plain(() => client.prepare(session.center.envelope));
      const signature = await signListing(session.owner, prepared.message);
      const intent = await plain(() => client.publish(prepared, session.owner, signature));
      return { intentId: intent.id };
    },
    record: (session, chainId, result) => plain(() => client.record(session.center.intentId,
      { chainId, projectId: result.projectId, transactionHash: result.hash })),
    deploy: (session) => client.requestDeploy(session.center.intentId, session.targets.map((target) => target.chainId)),
    status: (session) => plain(() => client.get(session.center.intentId)),
  };
}

// A sponsored launch is reviewed like any other: the decoded calls Center will send, then the listing signature.
async function reviewSponsoredLaunch(session, sign) {
  const launchDialog = $("sticky-launch-dialog");
  const reopen = Boolean(launchDialog?.open);
  if (reopen) launchDialog.close();
  confirmSession = null;
  confirmPreSteps = [{ label: "Sign the launch listing", note: "Lists it on Juicebox Center. Free, no transaction.", state: "pending" }];
  const txs = session.txs.map((tx) => ({ ...tx, from: "Juicebox Center", valueNote: "creation fee, paid by Juicebox Center" }));
  try {
    if (!(await confirmTxs(`Create ${session.symbol}`, txs, [...session.summary, ["Fees", "Juicebox Center pays gas and the creation fee."]], { sponsored: true }))) return false;
    await sign();
    return true;
  } finally {
    confirmPreSteps = [];
    confirmSponsored = false;
    confirmCompleted = true;
    try { $("confirm-dialog").close(); } catch {}
    if (reopen) showStickyLaunchDialog();
  }
}

// Launch state is independent of the editable create form and survives reloads.
let stickyLaunchControllerInstance = null;
let stickyLaunchStoreInstance = null;
let stickyLaunchChoiceResolve = null;
let stickyLaunchBusy = false;
function stickyLaunchStore() {
  if (!window.StickyLaunch) throw new Error("Launch recovery could not load. Reload this page before deploying.");
  return stickyLaunchStoreInstance ||= StickyLaunch.createStore(localStorage);
}
function stickyLaunchRelayr() {
  return StickyRelayr.createClient({ apiUrl: window.STICKY_CONFIG?.relayrUrl, rpc: (chainId, method, params) => {
    const saved = stickyLaunchStore().load();
    const target = saved?.targets.find((item) => item.chainId === Number(chainId));
    const rpcUrl = target?.rpcUrl || saved?.fundingRpcs[chainId];
    if (!rpcUrl) throw new Error(`No saved RPC for chain ${chainId}.`);
    return rpcAt(rpcUrl, method, params);
  } });
}
function stickyLaunchController() {
  return stickyLaunchControllerInstance ||= StickyLaunch.createController({
    store: stickyLaunchStore(), relayr: stickyLaunchRelayr(), listing: stickyLaunchListing(),
    choosePayment: chooseStickyLaunchPayment,
    runPayment: runStickyLaunchPayment,
    runDirect: (session, options) => runStickyLaunchWallet(session, session.txs, options),
    reviewSponsored: reviewSponsoredLaunch,
    acknowledge: async (session) => {
      const pending = getTxEngine().load();
      if (pending?.steps.every((step) => step.tx.sessionTag === session.id)) {
        await getTxEngine().acknowledge(pending.id);
        if (!session.paymentIntent && !session.directIntent
          && pending.steps.every((step) => ["ready", "rejected"].includes(step.state))) await getTxEngine().clear();
      }
    },
    onChange: renderStickyLaunchRecovery,
  });
}
async function withStickyLaunchLock(fn) {
  if (stickyLaunchBusy) throw new Error("This launch is already being processed.");
  if (!navigator.locks) throw new Error("This browser does not support safe launch recovery. Use a current browser over HTTPS.");
  return navigator.locks.request("sticky-launch-write", { ifAvailable: true }, async (lock) => {
    if (!lock) throw new Error("This Sticky launch is being processed in another tab.");
    stickyLaunchBusy = true;
    try { return await fn(); }
    catch (error) {
      ensureStickyLaunchUI();
      $("sl-error").textContent = error.message;
      throw error;
    } finally { stickyLaunchBusy = false; renderStickyLaunchRecovery(); }
  });
}
function ensureStickyLaunchUI() {
  if ($("sticky-launch-dialog")) return;
  const dialog = document.createElement("dialog");
  dialog.id = "sticky-launch-dialog";
  dialog.setAttribute("aria-labelledby", "sl-title");
  dialog.innerHTML = `<button type="button" class="dlg-x" id="sl-close" aria-label="Close launch">✕</button>
    <div class="cd-eyebrow">Create a Sticky token</div><h2 class="cd-title" id="sl-title">Launch</h2>
    <div id="sl-summary" class="cd-summary"></div><p id="sl-status" role="status" aria-live="polite"></p>
    <div id="sl-progress" class="cd-steps"></div><div id="sl-funding" class="hide"></div>
    <p id="sl-error" role="alert" style="color:var(--err);overflow-wrap:anywhere"></p>
    <details id="sl-recovery"><summary>Recover a destination transaction</summary>
      <p class="mut">If a chain explorer shows a completed deployment, paste its execution transaction hash. Sticky verifies the exact saved deployment before marking it complete.</p>
      <label for="sl-chain">Destination chain</label><select id="sl-chain"></select>
      <label for="sl-hash">Execution transaction hash</label><input id="sl-hash" autocomplete="off" spellcheck="false" placeholder="0x…">
      <button type="button" class="ghost" id="sl-check-hash">Verify transaction</button>
    </details><details style="margin-top:16px"><summary>Review saved deployment transactions</summary><div id="sl-transactions"></div></details>
    <div class="dlg-actions"><button type="button" class="ghost" id="sl-clear">Discard draft</button>
      <button type="button" class="ghost" id="sl-refresh">Check progress</button><button type="button" class="ghost hide" id="sl-list">List on Juicebox Center</button><button type="button" class="hide" id="sl-self">Launch it yourself</button><button type="button" id="sl-resume">Continue launch</button></div>`;
  document.body.appendChild(dialog);
  const banner = document.createElement("div");
  banner.id = "sticky-launch-banner";
  banner.className = "hide";
  banner.style.cssText = "max-width:1068px;margin:16px auto;padding:14px;border:1px solid var(--line);border-radius:4px;overflow-wrap:anywhere";
  banner.innerHTML = `<span id="sl-banner-text"></span> <button type="button" class="ghost" id="sl-open">View launch</button>`;
  const main = document.querySelector("main");
  if (main) main.prepend(banner); else document.body.insertBefore(banner, document.querySelector(".site-footer"));
  const close = () => {
    if (stickyLaunchChoiceResolve) { const resolve = stickyLaunchChoiceResolve; stickyLaunchChoiceResolve = null; resolve(null); }
    dialog.close();
  };
  $("sl-close").onclick = close;
  dialog.oncancel = (event) => { event.preventDefault(); close(); };
  $("sl-open").onclick = showStickyLaunchDialog;
  $("sl-resume").onclick = guard(() => withStickyLaunchLock(async () => {
    $("sl-error").textContent = "";
    await stickyLaunchController().run();
  }));
  $("sl-refresh").onclick = guard(() => withStickyLaunchLock(() => stickyLaunchController().refresh()));
  $("sl-list").onclick = guard(() => withStickyLaunchLock(() => stickyLaunchController().list()));
  $("sl-self").onclick = guard(() => withStickyLaunchLock(async () => {
    $("sl-error").textContent = "";
    await stickyLaunchController().selfPay();
  }));
  $("sl-check-hash").onclick = guard(() => withStickyLaunchLock(() => stickyLaunchController().addHash(Number($("sl-chain").value), $("sl-hash").value.trim())));
  $("sl-clear").onclick = guard(() => withStickyLaunchLock(async () => {
    const saved = stickyLaunchStore().load();
    await stickyLaunchController().clear(); dialog.close();
    if (saved && StickyLaunch.complete(saved)) {
      txStatus(`${saved.symbol} deployed on ${saved.targets.length} ${saved.targets.length === 1 ? "chain" : "chains"}.`, "ok");
      await renderHome();
    }
  }));
  $("create-toggle").addEventListener("click", (event) => {
    try {
      if (!stickyLaunchStore().load()) return;
      event.stopImmediatePropagation(); event.preventDefault(); showStickyLaunchDialog();
    } catch (error) {
      event.stopImmediatePropagation(); event.preventDefault();
      showStickyLaunchDialog(); $("sl-error").textContent = error.message;
    }
  }, true);
}
function showStickyLaunchDialog() {
  ensureStickyLaunchUI(); renderStickyLaunchRecovery();
  if (!$("sticky-launch-dialog").open) $("sticky-launch-dialog").showModal();
}
function renderStickyLaunchRecovery() {
  ensureStickyLaunchUI();
  let session;
  try { session = stickyLaunchStore().load(); }
  catch (error) {
    $("sticky-launch-banner").classList.remove("hide");
    $("sl-banner-text").textContent = "A saved launch needs recovery.";
    $("sl-error").textContent = error.message;
    for (const id of ["sl-clear", "sl-resume", "sl-refresh", "sl-check-hash", "sl-list"]) $(id).disabled = true;
    return;
  }
  $("sticky-launch-banner").classList.toggle("hide", !session);
  if (!session) return;
  const done = StickyLaunch.complete(session);
  const confirmed = Object.values(session.results).filter((result) => result.status === "confirmed").length;
  $("sl-title").textContent = `${done ? "Created" : "Create"} ${session.symbol}`;
  $("sl-banner-text").textContent = `${session.symbol}: ${confirmed} of ${session.targets.length} chains confirmed.`;
  $("sl-summary").innerHTML = session.summary.map(([key, value]) => `<div class="cd-summary-row"><span class="k">${esc(key)}</span><span class="v">${esc(value)}</span></div>`).join("");
  $("sl-status").textContent = done ? "Your Sticky token is deployed on every selected chain."
    : session.paymentConfirmed ? "Your payment is confirmed. Relayr is deploying on the selected chains. Keep this saved launch until every chain confirms."
    : session.paymentIntent ? "Your saved payment is being recovered. Check your wallet and use Continue launch to verify its result."
    : session.published && !session.quote ? (stickyLaunchBusy ? "Getting a launch quote from Relayr…" : "Relayr may have received this launch, but its quote ID was not returned. Submitting again could deploy duplicates. Keep this recovery record.")
    : session.mode === "center" ? (!session.center?.deployRequested ? "Sign the launch listing. Juicebox Center then deploys it and pays the fees."
      : session.center.sponsor?.note || "Juicebox Center is deploying on the selected chains. No transaction from you.")
    : session.mode === "relayr" ? (session.quote ? "Choose where to pay this launch quote. One payment covers the quoted destination gas and creation fees." : "Getting funding options for your saved launch…")
    : "Review the saved deployment, then confirm it in your wallet.";
  const listing = listingRow(session);
  $("sl-progress").innerHTML = (listing
    ? `<div class="cd-step ${listing.state}"><i>${listing.state === "done" ? "✓" : 1}</i><span>${esc(listing.label)}<br><small>${esc(listing.note)}</small></span></div>` : "")
    + session.targets.map((target, i) => {
      const result = session.results[target.chainId];
      const step = listing ? i + 2 : i + 1;
      const recorded = session.center?.recorded?.[target.chainId];
      return `<div class="cd-step ${result?.status === "confirmed" ? "done" : "pending"}"><i>${result?.status === "confirmed" ? "✓" : step}</i><span>${esc(target.name)}: `
        + (result?.status === "confirmed"
          ? `<a class="link" href="?chain=${target.chainId}#/project/${esc(result.projectId)}">project #${esc(result.projectId)}</a>${recorded ? " <small>listed</small>" : ""}`
          : "awaiting confirmation") + `</span></div>`;
    }).join("");
  $("sl-list").classList.toggle("hide", session.center?.state !== "unlisted");
  $("sl-list").disabled = stickyLaunchBusy;
  const selfPay = session.mode === "center" && Boolean(session.center?.sponsor?.selfPay);
  $("sl-self").classList.toggle("hide", !selfPay);
  $("sl-self").disabled = stickyLaunchBusy;
  const currentChain = $("sl-chain").value;
  $("sl-chain").innerHTML = session.targets.map((target) => `<option value="${target.chainId}">${esc(target.name)}</option>`).join("");
  if (session.targets.some((target) => String(target.chainId) === currentChain)) $("sl-chain").value = currentChain;
  $("sl-transactions").innerHTML = session.txs.map((tx) => `<div class="txstep"><h3>${esc(tx.label)}</h3><div class="rawbox" style="white-space:pre-wrap;overflow-wrap:anywhere">to: ${esc(tx.to)}\nvalue: ${esc(BigInt(tx.value).toString())} wei\ndata: ${esc(tx.data)}</div></div>`).join("");
  $("sl-clear").textContent = done ? "Done" : "Discard draft";
  $("sl-clear").classList.toggle("hide", !StickyLaunch.canClear(session));
  $("sl-clear").disabled = stickyLaunchBusy;
  $("sl-resume").classList.toggle("hide", done || Boolean(session.paymentConfirmed) || selfPay);
  $("sl-resume").disabled = stickyLaunchBusy;
  $("sl-refresh").disabled = stickyLaunchBusy;
  $("sl-check-hash").disabled = stickyLaunchBusy || done;
  $("sl-recovery").classList.toggle("hide", done);
  if (session.lastStatusError) $("sl-error").textContent = session.lastStatusError;
}
// The listing's line in the launch steps, or null when there is none to show.
function listingRow(session) {
  const center = session.center;
  if (!center) return null;
  const label = "Sign the launch listing";
  if (center.state === "pending") return { label, state: listingStepNote === "Waiting for wallet" ? "current" : "pending",
    note: listingStepNote === "Waiting for wallet" ? "Waiting for wallet" : "Lists it on Juicebox Center. Free, no transaction." };
  if (center.state === "published") {
    const waiting = Object.values(session.results).some((result) => result.status === "confirmed")
      && session.targets.some((target) => session.results[target.chainId]?.status === "confirmed" && !center.recorded[target.chainId]);
    return { label: "Listed on Juicebox Center", state: "done", note: waiting ? "Recording each deployment after 2 confirmations." : `Listing ${center.intentId}` };
  }
  if (center.state === "unlisted") return { label: "Not listed on Juicebox Center", state: "pending", note: center.error || "Your launch works without it. List it any time." };
  return { label: "Not listed on Juicebox Center", state: "pending", note: center.reason || "" };
}
function chooseStickyLaunchPayment(options, session) {
  // A quote can finish after the launch review was closed. Preserve it without trapping a lock.
  if (!$("sticky-launch-dialog").open) return null;
  if (!options.length) throw new Error("Relayr returned no valid funding options. Keep this launch saved and check again later.");
  const client = stickyLaunchRelayr();
  $("sl-funding").classList.remove("hide");
  $("sl-funding").innerHTML = `<label for="sl-payment-chain">Pay the launch quote on</label><select id="sl-payment-chain"><option value="">Choose a quoted chain</option>${options.map((payment, i) => {
    const details = client.paymentDetails(payment, session.quote.bundle_uuid);
    return `<option value="${i}">${esc(chainById(details.chainId)?.name || details.chainId)}: ${formatUnits(details.amount, 18, 18)} ETH</option>`;
  }).join("")}</select><p class="mut">One payment covers the quoted destination gas and creation fees. You will review the exact amount before paying.</p><button type="button" id="sl-review-payment" disabled>Review payment</button>`;
  return new Promise((resolve) => {
    stickyLaunchChoiceResolve = (payment) => { $("sl-funding").classList.add("hide"); resolve(payment); };
    $("sl-payment-chain").onchange = () => { $("sl-review-payment").disabled = $("sl-payment-chain").value === ""; };
    $("sl-review-payment").onclick = () => {
      if ($("sl-payment-chain").value === "") return;
      const settle = stickyLaunchChoiceResolve; stickyLaunchChoiceResolve = null;
      settle(options[Number($("sl-payment-chain").value)]);
    };
  });
}
async function runStickyLaunchPayment(session, options) {
  const details = stickyLaunchRelayr().paymentDetails(session.paymentIntent, session.quote.bundle_uuid, { allowExpired: options.recovering });
  const tx = relayrPaymentTx(session, details);
  return runStickyLaunchWallet(session, [tx], options);
}
async function runStickyLaunchWallet(session, txs, { recovering, beforeSend }) {
  if (txAccount()?.toLowerCase() !== session.owner.toLowerCase()) throw new Error(`Connect ${session.owner} to resume this launch.`);
  const engine = getTxEngine();
  const pending = engine.load();
  const matching = pending?.steps.every((step) => step.tx.sessionTag === session.id)
    && pending.steps.length === txs.length;
  if (recovering && !matching) throw new Error("The saved wallet transaction record is missing or belongs to another action. Keep this launch saved and recover its execution transaction; a new payment will not be sent.");
  // The listing is signed after this review is confirmed and before the wallet sends anything.
  const preSteps = session.center?.state === "pending"
    ? [{ label: "Sign the launch listing", note: "Lists it on Juicebox Center. Free, no transaction.", state: "pending" }] : [];
  let completed;
  // Dialogs replace each other: the review takes the launch dialog's place until it closes.
  const launchDialog = $("sticky-launch-dialog");
  const reopen = Boolean(launchDialog?.open);
  if (reopen) launchDialog.close();
  try { completed = await confirmAndRun(`Create ${session.symbol}`, txs, session.summary, { preSteps, afterReview: beforeSend }); }
  catch (error) {
    // A failure before this tagged plan exists cannot have submitted this launch.
    const after = engine.load();
    if (!recovering && !after?.steps.some((step) => step.tx.sessionTag === session.id)) {
      $("sl-error").textContent = error.message;
      return { status: "cancelled" };
    }
    throw error;
  }
  finally {
    // A review left open on an error keeps its place; the launch comes back when it closes.
    if (reopen && $("confirm-dialog").open) confirmReturnTo = [...new Set([...confirmReturnTo, launchDialog])];
    else if (reopen) showStickyLaunchDialog();
  }
  const latest = engine.load();
  const receipt = txs[0].receipt || latest?.steps[0]?.receipt;
  if (!completed && latest?.steps.every((step) => ["ready", "rejected"].includes(step.state))) return { status: "cancelled" };
  // Closing a recovery review cannot erase an unknown or previously submitted payment.
  return { status: receipt ? "confirmed" : "pending", hash: receipt?.transactionHash || latest?.steps[0]?.hash, receipt };
}
async function pollStickyLaunchProgress() {
  try {
    const saved = stickyLaunchStore().load();
    if (!stickyLaunchBusy && StickyLaunch.needsPolling(saved) && navigator.locks) {
      await navigator.locks.request("sticky-launch-write", { ifAvailable: true }, async (lock) => {
        if (!lock || stickyLaunchBusy) return;
        stickyLaunchBusy = true;
        try { await stickyLaunchController().refresh(); }
        finally { stickyLaunchBusy = false; renderStickyLaunchRecovery(); }
      });
    }
  } catch (error) { if ($("sl-error")) $("sl-error").textContent = error.message; }
  setTimeout(pollStickyLaunchProgress, 12000);
}
queueMicrotask(() => {
  renderStickyLaunchRecovery();
  window.addEventListener("storage", (event) => { if (event.key === StickyLaunch.KEY) renderStickyLaunchRecovery(); });
  setTimeout(pollStickyLaunchProgress, 12000);
});


// ------------------------------------------------------------ wallet (ported from juicescan)
const WALLET_FLAG = "jb-wallet-connected";
const WALLET_RDNS = "jb-wallet-rdns";
const _providers = [];
let activeProvider = window.ethereum || null;
let viewAs = null;
window.addEventListener("eip6963:announceProvider", (event) => {
  const detail = event?.detail;
  if (!detail?.info || !detail.provider) return;
  if (!_providers.some((p) => p.info.uuid === detail.info.uuid)) _providers.push(detail);
});
try { window.dispatchEvent(new Event("eip6963:requestProvider")); } catch {}
window.addEventListener("ethereum#initialized", () => {
  if (!activeProvider && window.ethereum) activeProvider = window.ethereum;
  try { window.dispatchEvent(new Event("eip6963:requestProvider")); } catch {}
});

function walletNameForProvider(provider) {
  if (!provider) return "Browser wallet";
  if (provider.isMetaMask) return "MetaMask";
  if (provider.isCoinbaseWallet) return "Coinbase Wallet";
  if (provider.isRabby) return "Rabby";
  if (provider.isTrust) return "Trust Wallet";
  if (provider.isBraveWallet) return "Brave Wallet";
  return "Browser wallet";
}

function getWalletProviders() {
  if (_providers.length) return _providers.slice();
  if (!window.ethereum) return [];
  const list = Array.isArray(window.ethereum.providers) && window.ethereum.providers.length
    ? window.ethereum.providers : [window.ethereum];
  return list.map((provider, i) => ({
    info: { uuid: `injected-${i}`, name: walletNameForProvider(provider), rdns: "injected", icon: "" },
    provider,
  }));
}

const boundWalletProviders = new WeakSet();
function bindWalletEvents(provider) {
  if (!provider?.on || boundWalletProviders.has(provider)) return;
  boundWalletProviders.add(provider);
  try {
    provider.on("accountsChanged", (accounts) => {
      if (provider !== activeProvider || walletKind === "signa") return;
      walletAccount = accounts?.[0] ?? null;
      walletKind = walletAccount ? "injected" : null;
      try { walletAccount ? localStorage.setItem(WALLET_FLAG, "1") : localStorage.removeItem(WALLET_FLAG); } catch {}
      updateConnectButton();
      route();
    });
    provider.on("chainChanged", () => { if (provider === activeProvider) updateConnectButton(); });
    provider.on("disconnect", () => {
      if (provider !== activeProvider || walletKind === "signa") return;
      walletAccount = null;
      walletKind = null;
      updateConnectButton();
      route();
    });
  } catch {}
}
if (activeProvider) bindWalletEvents(activeProvider);

async function walletConnect(chosen) {
  if (chosen?.provider) {
    activeProvider = chosen.provider;
    bindWalletEvents(activeProvider);
    try { localStorage.setItem(WALLET_RDNS, chosen.info?.rdns || ""); } catch {}
  }
  if (!activeProvider) throw new Error("No wallet detected. Install MetaMask or another browser wallet.");
  // Re-prompt account selection where supported; user rejection (4001) aborts.
  try {
    await activeProvider.request({ method: "wallet_requestPermissions", params: [{ eth_accounts: {} }] });
  } catch (error) {
    if (error?.code === 4001) throw error;
  }
  const accounts = await activeProvider.request({ method: "eth_requestAccounts" });
  if (!accounts?.[0]) throw new Error("The wallet did not share an account.");
  // One connection at a time: a browser wallet replaces a Signa sign-in.
  if (walletKind === "signa") { try { centerClient?.disconnect(); } catch {} }
  walletAccount = accounts[0];
  walletKind = "injected";
  try { localStorage.setItem(WALLET_FLAG, "1"); } catch {}
}

async function walletDisconnect() {
  if (walletKind === "signa") {
    (await centerWallet()).disconnect();
    walletAccount = null;
    walletKind = null;
    return;
  }
  // Revoke so the next connect re-prompts the account picker; older wallets lack this — ignore.
  try {
    await activeProvider?.request({ method: "wallet_revokePermissions", params: [{ eth_accounts: {} }] });
  } catch {}
  walletAccount = null;
  walletKind = null;
  try { localStorage.removeItem(WALLET_FLAG); localStorage.removeItem(WALLET_RDNS); } catch {}
}

// Silently restore a prior connection — eth_accounts returns authorized accounts without prompting.
async function walletEagerConnect() {
  if (await restoreCenterConnection()) { route(); return; }
  let wasConnected = false;
  try { wasConnected = localStorage.getItem(WALLET_FLAG) === "1"; } catch {}
  if (!wasConnected) return;
  let rdns = "";
  try { rdns = localStorage.getItem(WALLET_RDNS) || ""; } catch {}
  if (rdns && rdns !== "injected") {
    const match = _providers.find((p) => p.info.rdns === rdns);
    if (match) activeProvider = match.provider;
  }
  if (!activeProvider) return;
  bindWalletEvents(activeProvider);
  try {
    const accounts = await activeProvider.request({ method: "eth_accounts" });
    if (accounts?.length) {
      walletAccount = accounts[0];
      walletKind = "injected";
      route();
    } else {
      try { localStorage.removeItem(WALLET_FLAG); } catch {}
    }
  } catch {}
}

// ------------------------------------------------- connect button + wallet menu (juicescan port)
let walletMenu = null;
function closeWalletMenu() {
  if (!walletMenu) return;
  walletMenu.remove();
  walletMenu = null;
  $("connect-btn").setAttribute("aria-expanded", "false");
  document.removeEventListener("click", onWalletMenuDocClick, true);
}
function onWalletMenuDocClick(event) {
  const btn = $("connect-btn");
  if (walletMenu && event.target !== btn && !walletMenu.contains(event.target)) closeWalletMenu();
}
function newWalletMenu() {
  closeWalletMenu();
  walletMenu = document.createElement("div");
  walletMenu.id = "wallet-menu";
  walletMenu.className = "wallet-menu";
  walletMenu.onkeydown = (event) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    closeWalletMenu();
    $("connect-btn").focus();
  };
  const rect = $("connect-btn").getBoundingClientRect();
  walletMenu.style.top = `${rect.bottom + 6}px`;
  walletMenu.style.right = `${Math.max(8, window.innerWidth - rect.right)}px`;
  return walletMenu;
}
function mountWalletMenu() {
  document.body.appendChild(walletMenu);
  $("connect-btn").setAttribute("aria-controls", "wallet-menu");
  $("connect-btn").setAttribute("aria-expanded", "true");
  walletMenu.querySelector("button")?.focus();
  setTimeout(() => document.addEventListener("click", onWalletMenuDocClick, true), 0);
}
function menuItem(text, onClick, cls = "") {
  const item = document.createElement("button");
  item.className = `wallet-menu-item ${cls}`.trim();
  item.textContent = text;
  item.addEventListener("click", onClick);
  return item;
}
function appendViewAsItem(menu) {
  const separator = document.createElement("div");
  separator.className = "wallet-menu-separator";
  menu.appendChild(separator);
  menu.appendChild(menuItem(viewAs ? "View as another account…" : "View as…", (event) => {
    event.stopPropagation();
    if (menu.querySelector(".viewas-prompt")) return;
    const wrap = document.createElement("div");
    wrap.className = "viewas-prompt";
    const input = document.createElement("input");
    input.placeholder = "0x address";
    input.setAttribute("aria-label", "Account address to preview");
    const go = menuItem("View", () => {
      if (!/^0x[0-9a-fA-F]{40}$/.test(input.value)) return;
      viewAs = input.value;
      closeWalletMenu();
      updateConnectButton();
      route();
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") go.click();
    });
    wrap.appendChild(input);
    wrap.appendChild(go);
    menu.appendChild(wrap);
    input.focus();
  }));
}
async function appendWalletBalances(menu, address) {
  const panel = document.createElement("div");
  panel.className = "wallet-menu-balances";
  panel.textContent = "Loading balances…";
  menu.appendChild(panel);
  try {
    const rows = [];
    const native = decUint(await rpc("eth_getBalance", [address, "latest"]));
    rows.push(["ETH", formatUnits(native, 18)]);
    if (ctx.currentId !== null) {
      const info = await projectInfo(ctx.currentId);
      rows.push([info.symbol, formatUnits(decUint(await view(info.stakedToken, SEL.balanceOf, encAddress(address))), info.decimals)]);
      rows.push([info.stSymbol, formatUnits(decUint(await view(info.stToken, SEL.balanceOf, encAddress(address))), 18)]);
    }
    if (!panel.isConnected) return;
    panel.innerHTML = rows.map(([label, value]) =>
      `<div class="wallet-menu-balance-row"><span class="mut">${esc(label)}</span><strong>${esc(value)}</strong></div>`).join("");
  } catch {
    if (panel.isConnected) panel.textContent = "Balances unavailable";
  }
}
// ------------------------------------------------ Signa sign-in and the chooser (Homerun's dynamic)
// A Signa account is a passkey account on Base. Here it is an address for reads: positions, rewards and
// the account page. Every write needs a browser wallet until Signa's review covers the action.
const CENTER_WALLET = window.STICKY_CONFIG?.centerWallet || null;
const CENTER_CALLBACK_PATH = "/center/callback";
const CENTER_RETURN_KEY = "sticky:center:return:v1";
let centerSdk = null;
let centerClient = null;
let walletChooser = null;
function loadCenterSdk() {
  centerSdk ||= import("./center-connect.js").catch((error) => { centerSdk = null; throw error; });
  return centerSdk;
}
async function centerWallet() {
  if (!CENTER_WALLET) throw new Error("Signa sign-in is not configured for this site.");
  const sdk = await loadCenterSdk();
  centerClient ||= sdk.createCenterWalletClient({ ...CENTER_WALLET, callbackUri: location.origin + CENTER_CALLBACK_PATH });
  return centerClient;
}
// The SDK keeps this tab's sign-in in sessionStorage under this key, so a reload restores it.
// Check for it before loading the SDK.
function centerConnectionSaved() {
  if (!CENTER_WALLET) return false;
  try { return !!sessionStorage.getItem(`center.wallet.connection.v1:${CENTER_WALLET.issuer}:${location.origin}${CENTER_CALLBACK_PATH}`); }
  catch { return false; }
}
function centerAddress(connection) {
  const address = connection?.address;
  if (connection?.chainId !== 8453 || !/^0x[0-9a-fA-F]{40}$/.test(address || "")
    || connection.accountId !== `eip155:8453:${address.toLowerCase()}`
    || !(connection.expiresAt > Math.floor(Date.now() / 1000))) return null;
  return address;
}
function adoptCenterConnection(connection) {
  const address = centerAddress(connection);
  if (!address) throw new Error("The Signa sign-in did not return a usable account.");
  try { localStorage.removeItem(WALLET_FLAG); localStorage.removeItem(WALLET_RDNS); } catch {}
  walletAccount = address;
  walletKind = "signa";
}
async function restoreCenterConnection() {
  if (!centerConnectionSaved()) return false;
  try {
    const address = centerAddress((await centerWallet()).restoreConnection());
    if (!address) return false;
    walletAccount = address;
    walletKind = "signa";
    return true;
  } catch { return false; }
}
// Signa's "Open as a page" leaves this page; /center/callback brings the tab back to this route.
function saveCenterReturn() {
  const saved = /^#\/[A-Za-z0-9/_@.:%-]{0,1000}$/.test(location.hash) ? location.hash : "";
  sessionStorage.setItem(CENTER_RETURN_KEY, saved);
  if (sessionStorage.getItem(CENTER_RETURN_KEY) !== saved) throw new Error("This tab could not keep your place for the sign-in.");
}
function needsExternalWallet() {
  return Object.assign(new Error("This action needs an external wallet."), { code: "NEEDS_EXTERNAL_WALLET" });
}
function connectWalletAction() {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "text-button";
  button.textContent = "Connect a wallet";
  button.addEventListener("click", () => void openWalletChooser({ walletsOnly: true }));
  return button;
}
function viewAsControl() {
  const wrap = document.createElement("div");
  wrap.className = "wallet-viewas";
  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "text-button";
  toggle.textContent = viewAs ? "View as another account" : "View as an address";
  toggle.addEventListener("click", () => {
    toggle.remove();
    const input = document.createElement("input");
    input.placeholder = "0x address";
    input.setAttribute("aria-label", "Account address to preview");
    const go = document.createElement("button");
    go.type = "button";
    go.className = "ghost";
    go.textContent = "View";
    go.addEventListener("click", () => {
      if (!/^0x[0-9a-fA-F]{40}$/.test(input.value.trim())) { input.setAttribute("aria-invalid", "true"); return; }
      viewAs = input.value.trim();
      walletChooser?.close();
      updateConnectButton();
      route();
    });
    input.addEventListener("keydown", (event) => { if (event.key === "Enter") go.click(); });
    wrap.append(input, go);
    input.focus();
  });
  wrap.append(toggle);
  return wrap;
}
function walletConnected() {
  walletChooser?.close();
  updateConnectButton();
  route();
}
// One native dialog. It replaces whatever dialog is open; dialogs never stack.
async function openWalletChooser({ walletsOnly = false } = {}) {
  closeWalletMenu();
  walletChooser?.close();
  for (const open of document.querySelectorAll("dialog[open]")) open.close();
  let sdk;
  try { sdk = await loadCenterSdk(); }
  catch { status("The sign-in options could not load. Reload to try again.", "err"); return; }
  const options = [];
  if (CENTER_WALLET && !walletsOnly) {
    options.push({ ...sdk.passkeyOption({
      wallet: centerWallet,
      beforeLaunch: saveCenterReturn,
      // Signa frames its sign-in here for sites it admits; inside, "Open as a page" is the full-page path.
      frame: true,
      connected: async (connection) => { adoptCenterConnection(connection); walletConnected(); },
    }), name: "Signa" });
  }
  for (const provider of getWalletProviders()) {
    options.push({
      id: `wallet:${provider.info?.uuid}`, name: provider.info?.name || "Wallet", icon: provider.info?.icon || undefined,
      async connect() { await walletConnect(provider); walletConnected(); },
    });
  }
  const chooser = walletChooser = StickyWalletChooser.createChooser({
    dialog: $("wallet-dialog"), heading: $("wallet-title"), body: $("wallet-body"),
    controller: sdk.createConnectController(options), issuer: CENTER_WALLET?.issuer || null,
    label: StickyWalletChooser.deviceLabel(navigator.userAgent), win: window, extra: viewAsControl(),
    onClose: () => {
      if (walletChooser !== chooser) return;
      walletChooser = null;
      $("connect-btn").focus();
    },
  });
  chooser.open();
}
function openWalletMenu() {
  const menu = newWalletMenu();
  const shown = viewAs || walletAccount;
  if (walletKind === "signa" && !viewAs) {
    const note = document.createElement("div");
    note.className = "wallet-menu-note";
    note.textContent = "Signa account. Connect a wallet to stick, unstick or claim.";
    menu.appendChild(note);
  }
  if (shown) appendWalletBalances(menu, shown);
  menu.appendChild(menuItem("Account", () => {
    closeWalletMenu();
    location.hash = `#/account/${viewAs || walletAccount}`;
  }));
  if (viewAs) {
    menu.appendChild(menuItem(walletAccount ? "View as connected wallet" : "Exit View as", () => {
      closeWalletMenu();
      viewAs = null;
      updateConnectButton();
      route();
    }));
  } else {
    menu.appendChild(menuItem("Copy address", () => {
      try { navigator.clipboard.writeText(walletAccount); } catch {}
      closeWalletMenu();
    }));
    menu.appendChild(menuItem("Disconnect", () => {
      closeWalletMenu();
      guard(async () => {
        await walletDisconnect();
        updateConnectButton();
        route();
      })();
    }, "wallet-menu-danger"));
  }
  appendViewAsItem(menu);
  mountWalletMenu();
}
function updateConnectButton() {
  const btn = $("connect-btn");
  btn.textContent = viewAs
    ? `Viewing as ${shortAddr(viewAs)}`
    : walletAccount ? shortAddr(walletAccount) : "Sign in";
  btn.classList.toggle("connected", !!walletAccount && !viewAs);
  btn.classList.toggle("viewing-as", !!viewAs);
  btn.title = viewAs || (walletKind === "signa" ? `Signa account ${walletAccount}` : walletAccount) || "Sign in, connect a wallet or view as another account";
}

// ------------------------------------------------------------------- account view
async function renderAccount(address) {
  ++viewSequence;
  const current = currentView();
  clearHomeSecuredChart();
  $("view-home").classList.add("hide");
  $("view-project").classList.add("hide");
  $("view-account").classList.remove("hide");
  $("a-logo").innerHTML = tokenBadge(address, address.slice(2, 3), 72);
  $("a-title").textContent = walletAccount && address.toLowerCase() === walletAccount.toLowerCase() ? "Your account" : "Account";
  $("a-address").textContent = address;
  if (!ctx.loaded) return;
  const ids = await projectIds();
  if (!current()) return;
  const logs = await holderLogs(ids, address);
  if (!current()) return;
  const rows = [];
  for (const id of ids) {
    try {
      const info = await projectInfo(id);
      if (!current()) return;
      const args = word(id) + encAddress(address);
      const [staked, streakStart, longest] = await Promise.all([
        view(ctx.hook, SEL.stakedBalanceOf, args).then(decUint),
        view(ctx.hook, SEL.streakStartOf, args).then(decUint),
        view(ctx.hook, SEL.longestStreakOf, args).then(decUint),
      ]);
      if (!current()) return;
      if (staked === 0n && longest === 0n) continue;
      const current = streakStart === 0n ? 0 : Math.max(0, Math.floor(Date.now() / 1000) - Number(streakStart));
      rows.push(
        `<a class="card-item pickc" href="#/project/${id}"><div class="card-head">` +
        `${tokenLogo(info.stakedToken, info.symbol, 26)}<div style="flex:1;min-width:0">` +
        `<div style="font-weight:700">${esc(stickyLabel(info))} <span class="mut">#${id}</span></div>` +
        `<div class="kv"><span class="mut">Stuck:</span> ${formatUnits(staked, 18)} ${esc(info.stSymbol)}</div>` +
        `<div class="kv"><span class="mut">Time:</span> ${formatDuration(current)}</div>` +
        `<div class="kv"><span class="mut">Longest:</span> ${formatDuration(Math.max(Number(longest), current))}</div>` +
        `</div></div></a>`,
      );
    } catch {}
  }
  $("a-positions").innerHTML = rows.length ? rows.join("") : `<div class="card-item mut">no positions yet</div>`;
  const activity = await activityItems(logs, true);
  if (!current()) return;
  renderFeed($("a-activity"), activity);
  hydrateLogos().catch(() => {});
}

// -------------------------------------------------------------------- router
function route() {
  const sequence = ++viewSequence;
  closeWalletMenu();
  try { $("create-dialog").close(); } catch {}
  try { $("connection-dialog").close(); } catch {}
  try { $("unstick-dialog").close(); } catch {}
  try { $("trust-dialog").close(); } catch {}
  try { $("fund-dialog").close(); } catch {}
  try { $("autostick-dialog").close(); } catch {}
  confirmReturnTo = [];
  if (confirmResolve) settleConfirm(false);
  // The home page reads its chains itself; every other route needs the page's chain loaded first.
  if (!ctx.loaded && !isHomeRoute()) return;
  const accountMatch = location.hash.match(/^#\/account\/(0x[0-9a-fA-F]{40})$/);
  if (accountMatch) {
    ctx.currentId = null;
    renderAccount(accountMatch[1]).catch((e) => status(e.message, "err"));
    return;
  }
  $("view-account").classList.add("hide");
  const handleMatch = location.hash.match(/^#\/@([^/]+)(?:\/(overview|tokens|airdrops))?\/?$/);
  if (handleMatch) {
    const handle = decodeURIComponent(handleMatch[1]);
    const tab = { overview: "overview", tokens: "owners", airdrops: "rewards" }[handleMatch[2] || "overview"];
    setTab(tab);
    projectIdForHandle(handle).then((projectId) => {
      if (sequence !== viewSequence) return;
      if (projectId === null) throw new Error(`no sticky token is published at @${handle}`);
      ctx.alias = `@${handle}`;
      return renderProject(projectId);
    }).catch((e) => status(e.message, "err"));
    return;
  }
  const match = location.hash.match(/^#\/project\/(\d+)(?:\/(overview|tokens|airdrops))?\/?$/);
  if (match) {
    const projectId = BigInt(match[1]);
    const tab = { overview: "overview", tokens: "owners", airdrops: "rewards" }[match[2] || "overview"];
    setTab(tab);
    ctx.alias = null;
    renderProject(projectId).catch((e) => status(e.message, "err"));
  }
  else {
    ctx.currentId = null;
    renderHome().catch(homeFailed);
  }
}
window.onhashchange = route;
$("home-retry").onclick = retryHome;

// ---------------------------------------------------------------------- wire
function guard(fn) {
  let active = false;
  return async (event) => {
    if (active) return;
    active = true;
    const anchor = event?.currentTarget || document.activeElement;
    const wasDisabled = anchor && "disabled" in anchor ? anchor.disabled : null;
    if (wasDisabled !== null) anchor.disabled = true;
    const oldNotice = anchor?.closest?.("dialog, section, .card-item, .list-card")?.querySelector?.(".inline-status");
    oldNotice?.remove();
    try { return await fn(event); } catch (error) {
      if (confirmProgress >= 0 || $("confirm-dialog").open) txStatus(error.message, "err");
      else inlineStatus(anchor, error.message, "err", error.code === "NEEDS_EXTERNAL_WALLET" ? connectWalletAction() : null);
    } finally {
      active = false;
      if (wasDisabled !== null) anchor.disabled = wasDisabled;
      try { if (txEngine) renderTxRecovery(txEngine.load()); } catch {}
    }
  };
}
$("load").onclick = guard(async () => {
  await loadDeployer();
  $("connection-dialog").close();
});
$("stake").onclick = guard(stake);
$("transfer-send")?.addEventListener("click", guard(transferSticky));
$("unstake").onclick = guard(unstake);
$("trust").onclick = guard(async () => {
  await setTrust($("trust-addr").value, true);
  try { $("trust-dialog").close(); } catch {}
});
$("fund").onclick = guard(fundRewards);
$("settle").onclick = guard(settleArrivals);
$("rr-copy-hook").onclick = guard(async () => {
  await navigator.clipboard.writeText($("rr-hook").textContent);
  inlineStatus($("rr-copy-hook"), "Split hook address copied.", "ok");
});
$("rr-copy-beneficiary").onclick = guard(async () => {
  await navigator.clipboard.writeText($("rr-beneficiary").textContent);
  inlineStatus($("rr-copy-beneficiary"), "Beneficiary address copied.", "ok");
});
renderOriginPills();
$("r-min-weeks").oninput = $("r-max-weeks").oninput = renderFundGroupNote;
$("r-min-weeks").onchange = $("r-max-weeks").onchange = guard(renderRewards);
$("rr-min-weeks").oninput = $("rr-max-weeks").oninput = renderRecipeGroup;
renderFundGroupNote();
$("r-add").onclick = guard(async () => {
  const addr = $("r-check").value;
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) throw new Error("bad token address");
  (rewardTokens[ctx.currentId.toString()] ??= new Set()).add(addr.toLowerCase());
  await renderRewards();
});
const fillStakeMax = () => { if (ctx.walletMax) { $("stake-amount").value = ctx.walletMax; renderStickQuote(); } };
$("stake-balance").onclick = fillStakeMax;
$("unstake-max").onclick = () => { if (ctx.stakedMax) { $("unstake-amount").value = ctx.stakedMax; renderUnstickQuote(); } };
$("unstake-amount").oninput = renderUnstickQuote;
$("stake-amount").oninput = renderStickQuote;
$("stake-beneficiary").oninput = renderStickQuote;
$("tranches-newer").onclick = guard(async () => {
  ctx.tranchePage = ctx.tranchePage > 0n ? ctx.tranchePage - 1n : 0n;
  await refreshPosition();
});
$("tranches-older").onclick = guard(async () => {
  ctx.tranchePage = (ctx.tranchePage || 0n) + 1n;
  await refreshPosition();
});
$("deploy").onclick = guard(deployStreaks);
// Cash out curve: y = x((1-r) + rx) — proportional at r=0, bonding-curved as the reward grows.
let rewardChoice = "10";
let lockedSymbol = "";
// The token field also takes a Juicebox project ID (5, or chain-prefixed like base:5). What it
// resolves to is echoed below the field.
let dTokenLookup = 0;
const CHAIN_ALIASES = {
  eth: 1, ethereum: 1, mainnet: 1, op: 10, optimism: 10, base: 8453, arb: 42_161, arbitrum: 42_161,
  sepolia: 11_155_111, ethsepolia: 11_155_111, opsepolia: 11_155_420, basesepolia: 84_532, arbsepolia: 421_614,
};
const chainLabelOf = (chainId) => ORIGINS.find((origin) => origin.chainId === chainId)?.label ?? `chain ${chainId}`;

function setTokenMeta(html, isError) {
  const meta = $("d-token-meta");
  meta.classList.toggle("hide", !html);
  meta.style.color = isError ? "var(--err)" : "var(--muted)";
  meta.innerHTML = html || "";
}

// Reads a project's ERC-20 on one chain through that chain's JBTokens.
async function launchTokenOf(chainId, projectId) {
  const runtime = await launchRuntime(chainId);
  return decAddress(await viewAt(runtime, runtime.tokens, SEL.tokenOf, word(projectId)));
}
const launchChainName = (chainId) => chainById(chainId)?.name || `chain ${chainId}`;
const selectedLaunchChainIds = () => chainsForEnvironment(createEnvironment)
  .filter((chain) => createChainIds.has(chain.chainId)).map((chain) => chain.chainId);

// Resolves the TOKEN TO MAKE STICKY field. A project ID resolves on every selected chain.
async function resolveLaunchToken(input, chainIds) {
  const parsed = StickyLaunchPlan.parseTokenInput(input, CHAIN_ALIASES);
  if (parsed.kind === "address") return { address: parsed.address, chainIds, projectId: null };
  if (parsed.kind === "unknown-chain") throw new Error(`Unknown chain "${parsed.prefix}". Try eth, op, base or arb.`);
  if (parsed.kind !== "project") throw new Error("Enter a token address or a Juicebox project ID.");
  const resolved = await StickyLaunchPlan.resolveProjectToken({ projectId: parsed.projectId, chainId: parsed.chainId,
    targetChainIds: chainIds, tokenOfAt: launchTokenOf, nameOf: launchChainName });
  return { ...resolved, projectId: parsed.projectId };
}

async function resolveLockToken() {
  const input = $("d-token").value.trim();
  const lookup = ++dTokenLookup;
  lockedSymbol = "";
  setTokenMeta("");
  renderCurve();
  const parsed = StickyLaunchPlan.parseTokenInput(input, CHAIN_ALIASES);
  if (parsed.kind === "empty" || parsed.kind === "invalid" || !ctx.loaded) return;
  const chainIds = selectedLaunchChainIds();
  if (!chainIds.length) return;
  let resolved, symbol = "", name = "";
  try {
    resolved = await resolveLaunchToken(input, chainIds);
    const runtime = await launchRuntime(resolved.chainIds[0]);
    [symbol, name] = await Promise.all([
      viewAt(runtime, resolved.address, SEL.symbol).then(decString),
      viewAt(runtime, resolved.address, SEL.name).then(decString).catch(() => ""),
    ]);
  } catch (error) {
    if (lookup !== dTokenLookup) return;
    if (parsed.kind === "address" && !resolved) return; // not an ERC-20 (yet)
    return setTokenMeta(esc(resolved ? `This token is not readable on ${launchChainName(resolved.chainIds[0])}.` : error.message), true);
  }
  if (lookup !== dTokenLookup) return;
  lockedSymbol = symbol;
  const defaults = StickyLaunchPlan.defaultNames(name || symbol, symbol);
  $("d-name").placeholder = defaults.name;
  $("d-symbol").placeholder = defaults.symbol;
  const where = resolved.projectId === null ? ""
    : ` | project #${resolved.projectId}'s token on ${resolved.chainIds.map(launchChainName).join(", ")}`;
  setTokenMeta(`${tokenLogo(resolved.address, symbol)} <span>${esc(name || symbol)} (${esc(symbol)})${esc(where)}`
    + `${resolved.projectId === null ? "" : ` | ${esc(shortAddr(resolved.address))}`}</span>`);
  renderCurve();
  hydrateLogos().catch(() => {});
}
$("d-token").addEventListener("input", () => { resolveLockToken().catch(() => {}); });
$("d-environment").onchange = (event) => selectCreateEnvironment(event.target.value);
$("d-chains").onchange = (event) => {
  const input = event.target.closest?.("[data-create-chain]");
  if (!input) return;
  const chainId = Number(input.dataset.createChain);
  if (input.checked) createChainIds.add(chainId);
  else createChainIds.delete(chainId);
  syncCreateChainValidity();
  resolveLockToken().catch(() => {});
};
// The chosen bonus in basis points, or null while a custom value is invalid.
function rewardBasisPoints() {
  try { return StickyLaunchPlan.bonusBasisPoints(rewardChoice, $("d-reward").value); }
  catch { return null; }
}
function renderCurve() {
  const basisPoints = rewardBasisPoints();
  $("d-reward-error")?.classList.toggle("hide", basisPoints !== null);
  const r = Number(basisPoints ?? 0n) / 10000;
  renderBonusSplit(r);
}

// One marginal unstick, split into where the value goes: (1−bonus) to the leaver less the 2.5%
// protocol fee; the bonus stays in the pool and lifts every remaining sticky token's backing.
// Options: el (target, default create-flow), rho0 (today's backing per sticky, default 1),
// sym / stSym (symbols; default from the create form's locked token).
function renderBonusSplit(r, o = {}) {
  const el = o.el || $("d-ratchet");
  if (!el) return;
  if (!(r > 0)) { el.innerHTML = ""; return; }
  const rho0 = o.rho0 || 1;
  const sym = o.sym ?? (lockedSymbol || "");
  const stSym = o.stSym
    ?? (($("d-custom-name")?.checked && $("d-symbol").value.trim()) || (sym ? StickyLaunchPlan.defaultNames("", sym).symbol : ""));
  const value = 100 * rho0;
  const stays = value * r;
  const fee = (value - stays) * 0.025;
  const toLeaver = value - stays - fee;
  const unit = sym ? ` ${sym}` : "";
  const qty = (v) => (v >= 1000 ? Math.round(v).toLocaleString() : parseFloat(v.toFixed(1)).toString());
  const W = 460;
  const BH = 26;
  const wLeaver = (toLeaver / value) * W;
  const wStays = (stays / value) * W;
  el.innerHTML = `
    <div class="mut" style="font-size:13px;margin:10px 0 6px">Unsticking 100 ${esc(stSym) || "sticky tokens"}, a small share of supply</div>
    <svg viewBox="0 0 ${W} ${BH}" style="width:100%;max-width:${W}px;border-radius:4px" preserveAspectRatio="none">
      <rect x="0" y="0" width="${wLeaver.toFixed(1)}" height="${BH}" fill="#2fb3c7"/>
      <rect x="${wLeaver.toFixed(1)}" y="0" width="${wStays.toFixed(1)}" height="${BH}" fill="#0e7c91"/>
      <rect x="${(wLeaver + wStays).toFixed(1)}" y="0" width="${(W - wLeaver - wStays).toFixed(1)}" height="${BH}" fill="#e2d7bd"/>
    </svg>
    <div style="display:flex;flex-wrap:wrap;gap:6px 16px;overflow-wrap:anywhere;margin-top:6px" class="kv mut">
      <span><i style="display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;background:#2fb3c7"></i>${qty(toLeaver)}${esc(unit)} to the unstickers</span>
      <span><i style="display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;background:#0e7c91"></i>${qty(stays)} stays with stickers</span>
      <span><i style="display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;background:#e2d7bd"></i>${qty(fee)} protocol fee</span>
    </div>`;
}

const soulboundHint = () => {
  $("d-soulbound-hint").textContent = $("d-soulbound").value === "1"
    ? "Sticky tokens can't be transferred."
    : "Holders can transfer sticky tokens, which restarts the moved tokens' stickiness clock.";
};
$("d-soulbound").onchange = soulboundHint;
$("d-custom-name").onchange = () => {
  $("d-name-row").classList.toggle("hide", !$("d-custom-name").checked);
  renderCurve();
};
$("d-symbol").oninput = renderCurve;
$("d-add-reward").onchange = () => {
  $("d-reward-wrap").classList.toggle("hide", !$("d-add-reward").checked);
  $("d-reward-hint").classList.toggle("hide", !$("d-add-reward").checked);
  renderCurve();
};
$("d-reward").oninput = renderCurve;
function selectPreset(button, selected) {
  button.classList.toggle("on", selected);
  button.setAttribute("aria-pressed", String(selected));
}
for (const preset of document.querySelectorAll("[data-v]")) {
  preset.onclick = () => {
    rewardChoice = preset.dataset.v;
    for (const other of document.querySelectorAll("[data-v]")) selectPreset(other, other === preset);
    $("d-reward-custom-row").classList.toggle("hide", rewardChoice !== "custom");
    renderCurve();
  };
}
$("d-add-granters").onchange = () => {
  $("d-granters-row").classList.toggle("hide", !$("d-add-granters").checked);
  $("d-granters-hint").classList.toggle("hide", !$("d-add-granters").checked);
};
$("create-toggle").onclick = () => {
  for (const id of ["d-custom-name", "d-add-reward", "d-add-granters"]) $(id).checked = false;
  for (const id of ["d-name-row", "d-reward-wrap", "d-reward-hint", "d-granters-row", "d-granters-hint"]) {
    $(id).classList.add("hide");
  }
  $("d-extras").open = false;
  rewardChoice = "10";
  for (const preset of document.querySelectorAll("[data-v]")) selectPreset(preset, preset.dataset.v === "10");
  $("d-reward-custom-row").classList.add("hide");
  $("d-soulbound").value = "0";
  soulboundHint();
  launchRuntimes = new Map();
  setTokenMeta("");
  selectCreateEnvironment(homeEnvironment());
  $("create-dialog").showModal();
};
$("create-close").onclick = () => $("create-dialog").close();
$("cd-cancel").onclick = () => settleConfirm(false);
const guardedResumeTransactions = guard(resumeSavedTransactions);
$("cd-confirm").onclick = (event) => {
  if (confirmResolve) settleConfirm(true);
  else return guardedResumeTransactions(event);
};
$("cd-close").onclick = () => settleConfirm(false);
$("cd-audit").onclick = guard(async () => {
  await navigator.clipboard.writeText(await auditPrompt());
  inlineStatus($("cd-audit"), "Audit prompt copied. Paste it into your AI.", "ok");
});
$("tx-status-close").onclick = () => txStatus("");
$("confirm-dialog").oncancel = (event) => { event.preventDefault(); settleConfirm(false); };
// The close event arrives a task later; a review reopened in the meantime is not closed by it.
$("confirm-dialog").addEventListener("close", () => {
  if ($("confirm-dialog").open) return;
  if (confirmResolve) settleConfirm(false);
  restoreReplacedDialogs();
  // A plan left after a wallet refusal is dropped on close if nothing was signed or sent.
  if (txEngine && !txEngine.isBusy()) txEngine.discardIfUnsent().catch(() => {});
});
// Clicking the backdrop (the dialog element itself, not its children) closes the dialog.
$("create-dialog").onclick = (event) => {
  if (event.target === $("create-dialog")) $("create-dialog").close();
};
$("confirm-dialog").onclick = (event) => {
  if (event.target === $("confirm-dialog")) settleConfirm(false);
};
let boardSort = "longest";
const BOARD_PAGE = 20;
let boardSequence = 0;
function renderBoard() {
  if (!ctx.board) return;
  const sequence = ++boardSequence;
  const { rows, symbol, total, projectId } = ctx.board;
  const ranked = [...rows].sort((a, b) => boardSort === "largest"
    ? (b.staked > a.staked ? 1 : b.staked < a.staked ? -1 : b.current - a.current)
    : (b.current - a.current || (b.staked > a.staked ? 1 : -1)));
  const pages = Math.max(1, Math.ceil(ranked.length / BOARD_PAGE));
  const page = Math.min(ctx.board.page || 0, pages - 1);
  ctx.board.page = page;
  const shown = ranked.slice(page * BOARD_PAGE, (page + 1) * BOARD_PAGE);
  const draw = (list) => {
    $("leaderboard").innerHTML = list.length
      ? list.map((row, i) => {
          const self = row.holder.toLowerCase() === (account() || "").toLowerCase() ? " (you)" : "";
          const share = total > 0n ? Number(row.staked * 10_000n / total) / 100 : 0;
          return `<tr data-owner="${esc(row.holder.toLowerCase())}"><td>${page * BOARD_PAGE + i + 1}</td><td class="addr">${addressLabel(row.holder)}${self}</td>` +
            `<td>${share.toFixed(1)}%</td><td>${formatUnits(row.staked, 18)} ${esc(symbol)}</td>` +
            `<td>${formatDuration(row.current)}</td></tr>`;
        }).join("")
      : `<tr><td colspan="5" class="mut">Nobody is stuck yet.</td></tr>`;
    hydrateEns($("leaderboard")).catch(() => {});
  };
  draw(shown);
  $("board-pages").classList.toggle("hide", pages <= 1);
  $("board-page").textContent = `${page * BOARD_PAGE + 1}–${page * BOARD_PAGE + shown.length} of ${ranked.length} holders`;
  $("board-prev").disabled = page === 0;
  $("board-next").disabled = page >= pages - 1;
  // The page on screen is checked against the hook; a corrected balance replaces the logged one.
  if (projectId !== undefined && shown.length) {
    verifyHolderPage(projectId, shown).then((checked) => {
      if (sequence === boardSequence && checked.some((row, i) => row.staked !== shown[i].staked)) draw(checked);
    }).catch(() => {});
  }
}
$("board-prev").onclick = () => { if (ctx.board) { ctx.board.page = Math.max(0, ctx.board.page - 1); renderBoard(); } };
$("board-next").onclick = () => { if (ctx.board) { ctx.board.page += 1; renderBoard(); } };
$("sort-longest").onclick = () => {
  boardSort = "longest";
  if (ctx.board) ctx.board.page = 0;
  $("sort-longest").classList.add("on");
  $("sort-largest").classList.remove("on");
  $("sort-longest").setAttribute("aria-pressed", "true");
  $("sort-largest").setAttribute("aria-pressed", "false");
  renderBoard();
};
$("sort-largest").onclick = () => {
  boardSort = "largest";
  if (ctx.board) ctx.board.page = 0;
  $("sort-largest").classList.add("on");
  $("sort-longest").classList.remove("on");
  $("sort-longest").setAttribute("aria-pressed", "false");
  $("sort-largest").setAttribute("aria-pressed", "true");
  renderBoard();
};
$("open-fund").onclick = () => $("fund-dialog").showModal();
$("fund-close").onclick = () => $("fund-dialog").close();
$("fund-dialog").onclick = (event) => {
  if (event.target === $("fund-dialog")) $("fund-dialog").close();
};
$("open-unstick").onclick = () => { renderUnstickQuote(); $("unstick-dialog").showModal(); };
$("unstick-close").onclick = () => $("unstick-dialog").close();
$("unstick-dialog").onclick = (event) => {
  if (event.target === $("unstick-dialog")) $("unstick-dialog").close();
};
$("as-toggle").onclick = guard(toggleAutoStick);
$("as-stick-now").onclick = guard(autoStickNow);
$("as-begin-vesting").onclick = guard(beginAutoStickVesting);
$("as-repair").onclick = guard(repairAutoStick);
$("as-settings").onclick = () => openAutoStickDialog("settings");
$("as-save").onclick = guard(saveAutoStick);
$("as-close").onclick = () => $("autostick-dialog").close();
$("autostick-dialog").onclick = (event) => {
  if (event.target === $("autostick-dialog")) $("autostick-dialog").close();
};
for (const preset of document.querySelectorAll("[data-as-cooldown]")) {
  preset.onclick = () => {
    asCooldownChoice = Number(preset.dataset.asCooldown);
    for (const other of document.querySelectorAll("[data-as-cooldown]")) selectPreset(other, other === preset);
  };
}
for (const preset of document.querySelectorAll("[data-as-allowance]")) {
  preset.onclick = () => {
    asAllowanceChoice = preset.dataset.asAllowance;
    for (const other of document.querySelectorAll("[data-as-allowance]")) selectPreset(other, other === preset);
    $("as-allowance-custom-row").classList.toggle("hide", asAllowanceChoice !== "custom");
  };
}
$("open-trust").onclick = () => $("trust-dialog").showModal();
$("trust-close").onclick = () => $("trust-dialog").close();
$("trust-dialog").onclick = (event) => {
  if (event.target === $("trust-dialog")) $("trust-dialog").close();
};
$("connection-close").onclick = () => $("connection-dialog").close();
$("connection-dialog").onclick = (event) => {
  if (event.target === $("connection-dialog")) $("connection-dialog").close();
};
function setTab(tab) {
  for (const name of ["overview", "owners", "rewards"]) {
    $("tab-" + name).classList.toggle("hide", tab !== name);
    $("tab-btn-" + name).classList.toggle("on", tab === name);
    if (tab === name) $("tab-btn-" + name).setAttribute("aria-current", "page");
    else $("tab-btn-" + name).removeAttribute("aria-current");
  }
}
$("connect-btn").addEventListener("click", () => {
  if (walletMenu) { closeWalletMenu(); return; }
  if (viewAs || walletAccount) { openWalletMenu(); return; }
  void openWalletChooser();
});
$("wallet-close").onclick = () => walletChooser?.close();
$("wallet-dialog").addEventListener("mousedown", (event) => {
  if (event.target !== event.currentTarget) return;
  const box = event.currentTarget.getBoundingClientRect();
  if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) walletChooser?.close();
});
if (CENTER_WALLET) setTimeout(() => { loadCenterSdk().catch(() => {}); }, 0);
updateConnectButton();
walletEagerConnect().then(updateConnectButton);

// ------------------------------------------------------------------- demo
// A fixture RPC: when demoMode is on, every rpc() call is answered from baked data instead of a
// chain, so the whole app (home, project pages, quotes, your position) runs with no contracts —
// for showing how Sticky works before the contracts ship. Swap demoMode off + set real
// addresses to point at live testnet/production.
function buildDemoData() {
  const A = (suffix) => "0x" + suffix.toLowerCase().padStart(40, "0");
  const now = Math.floor(Date.now() / 1000);
  const you = "0x0e3d8D06Ec3c6b9a5815a3E66B129257079615c1";
  const day = 86_400;
  const u = (n) => parseUnits(String(n), 18);
  const projects = {
    2: {
      id: 2, reward: 1000n, decimals: 18,
      staked: A("ba2"), sticky: A("ba57"),
      symbol: "BAN", name: "Banana", stSymbol: "STICKYBAN", stName: "Streaking BAN", soulbound: 1,
      supply: u(950), sigma: u(1000),
      holders: [
        { addr: A("1111"), staked: u(500), start: now - 74 * day, longest: 74 * day },
        { addr: A("2222"), staked: u(250), start: now - 40 * day, longest: 40 * day },
        { addr: you, staked: u(200), start: now - 12 * day, longest: 30 * day },
      ],
      tranches: { [you.toLowerCase()]: [{ amount: u(150), ts: now - 12 * day }, { amount: u(50), ts: now - 3 * day }] },
      stakes: [
        { holder: A("1111"), payer: A("1111"), amount: u(500), ts: now - 74 * day },
        { holder: A("2222"), payer: A("2222"), amount: u(250), ts: now - 40 * day },
        { holder: you, payer: A("cccc"), amount: u(120), ts: now - 12 * day },
        { holder: you, payer: you, amount: u(80), ts: now - 3 * day },
      ],
    },
    1: {
      id: 1, reward: 0n, decimals: 18,
      staked: A("a27"), sticky: A("a57"),
      symbol: "ART", name: "Art", stSymbol: "STICKYART", stName: "Streaking ART", soulbound: 1,
      supply: u(3816), sigma: u(3816),
      holders: [
        { addr: A("1111"), staked: u(2500), start: now - 90 * day, longest: 90 * day },
        { addr: A("2222"), staked: u(750), start: now - 55 * day, longest: 55 * day },
        { addr: you, staked: u(566), start: now - 2 * day, longest: 41 * day },
      ],
      tranches: { [you.toLowerCase()]: [{ amount: u(500), ts: now - 2 * day }, { amount: u(66), ts: now - day }] },
      stakes: [
        { holder: A("1111"), payer: A("1111"), amount: u(2500), ts: now - 90 * day },
        { holder: A("2222"), payer: A("2222"), amount: u(750), ts: now - 55 * day },
        { holder: you, payer: A("dddd"), amount: u(500), ts: now - 2 * day },
        { holder: you, payer: you, amount: u(66), ts: now - day },
      ],
    },
  };
  const byToken = {};
  for (const p of Object.values(projects)) {
    byToken[p.staked.toLowerCase()] = { p, kind: "staked" };
    byToken[p.sticky.toLowerCase()] = { p, kind: "sticky" };
  }
  // Flatten stakes into hook logs shaped like the hook's own: Staked(payer, count, stakedBalance, caller), a
  // StreakStarted at each holder's first stake, and a StreakEnded for an earlier record streak. Newest last;
  // synthetic block numbers map to timestamps.
  const logs = [];
  const blockTs = {};
  let bn = 0x1000;
  for (const p of Object.values(projects)) {
    const balances = new Map();
    const topics = (topic, holder) => [topic, "0x" + word(p.id), "0x" + encAddress(holder)];
    for (const h of p.holders) {
      if (h.longest > now - h.start) {
        const block = "0x" + (bn++).toString(16);
        blockTs[block] = h.start - day;
        logs.push({ topics: topics(TOPIC.StreakEnded, h.addr), data: "0x" + word(h.longest) + encAddress(h.addr), blockNumber: block });
      }
    }
    for (const s of p.stakes.sort((a, b) => a.ts - b.ts)) {
      const block = "0x" + (bn++).toString(16);
      blockTs[block] = s.ts;
      const key = s.holder.toLowerCase();
      if (!balances.has(key)) logs.push({ topics: topics(TOPIC.StreakStarted, s.holder), data: "0x" + encAddress(s.holder), blockNumber: block });
      balances.set(key, (balances.get(key) || 0n) + s.amount);
      logs.push({
        topics: topics(TOPIC.Staked, s.holder),
        data: "0x" + encAddress(s.payer) + word(s.amount) + word(balances.get(key)) + encAddress(s.payer),
        blockNumber: block,
      });
    }
  }
  return {
    chainId: 1, now, you,
    deployer: A("de91"), hook: A("40c"), tokens: A("70c"), terminal: A("ec1"),
    store: A("57e"), controller: A("c04"),
    projects, byToken, logs, blockTs,
    wallet: { [you.toLowerCase()]: { [projects[1].staked.toLowerCase()]: u(995155), [projects[2].staked.toLowerCase()]: u(4200) } },
    prices: { [projects[1].staked.toLowerCase()]: "35", [projects[2].staked.toLowerCase()]: "5" },
    demoCards: [
      { id: 41, symbol: "JBX", token: A("41"), stuck: "4.9", sticks: 10, bonus: 4 },
      { id: 42, symbol: "REV", token: A("42"), stuck: "3.7", sticks: 9, bonus: 5 },
      { id: 43, symbol: "NANA", token: A("43"), stuck: "1.9", sticks: 5, bonus: 2 },
    ],
    logos: {
      [projects[1].staked.toLowerCase()]: "artizen.jpg",
      [projects[2].staked.toLowerCase()]: "banny.png",
      [A("41").toLowerCase()]: "juicebox.png",
      [A("42").toLowerCase()]: "donut.png",
      [A("43").toLowerCase()]: "jar.png",
    },
  };
}

let _demo = null;
const demoData = () => (_demo ??= buildDemoData());

function demoRpc(method, params) {
  const D = demoData();
  const enc = {
    uint: (n) => "0x" + word(n),
    addr: (a) => "0x" + encAddress(a),
    bool: (b) => "0x" + word(b ? 1 : 0),
    str: (s) => {
      const bytes = new TextEncoder().encode(String(s));
      let hex = ""; for (const b of bytes) hex += b.toString(16).padStart(2, "0");
      return "0x" + word(32) + word(bytes.length) + hex.padEnd(Math.ceil(bytes.length / 32) * 64, "0");
    },
    tranches: (list) => "0x" + word(32) + word(list.length)
      + list.map((t) => word(t.amount) + word(t.ts)).join(""),
  };
  if (method === "eth_chainId") return Promise.resolve("0x" + D.chainId.toString(16));
  if (method === "eth_blockNumber") return Promise.resolve("0x1");
  if (method === "eth_getCode") return Promise.resolve("0x60006000");
  if (method === "eth_getBlockByNumber") return Promise.resolve({ timestamp: "0x" + (D.blockTs[params[0]] || D.now).toString(16) });
  if (method === "eth_getLogs") {
    const f = params[0];
    const addr = String(f.address || "").toLowerCase();
    if (addr === D.deployer.toLowerCase()) {
      return Promise.resolve(Object.values(D.projects).map((p) => ({
        topics: [TOPIC.DeploySticky, "0x" + word(p.id)], data: "0x", blockNumber: "0x1",
      })));
    }
    if (addr === D.hook.toLowerCase()) {
      const set = new Set([].concat(f.topics?.[0] || []));
      const pid = f.topics?.[1] ? decUint(f.topics[1]) : null;
      return Promise.resolve(D.logs.filter((l) =>
        (!set.size || set.has(l.topics[0])) && (pid === null || decUint(l.topics[1]) === pid)));
    }
    return Promise.resolve([]);
  }
  if (method === "eth_call") {
    const to = String(params[0].to || "").toLowerCase();
    const data = params[0].data || "0x";
    const sel = data.slice(0, 10);
    const arg = (i) => "0x" + data.slice(10 + i * 64, 10 + i * 64 + 64);
    const idAt = (i) => Number(decUint(arg(i)));
    if (to === D.deployer.toLowerCase()) {
      if (sel === SEL.HOOK) return Promise.resolve(enc.addr(D.hook));
      if (sel === SEL.TOKENS) return Promise.resolve(enc.addr(D.tokens));
      if (sel === SEL.TERMINAL) return Promise.resolve(enc.addr(D.terminal));
      if (sel === SEL.CONTROLLER) return Promise.resolve(enc.addr(D.controller));
      if (sel === SEL.stakedTokenOf) return Promise.resolve(enc.addr(D.projects[idAt(0)]?.staked || "0x" + "0".repeat(40)));
      if (sel === SEL.cashOutTaxRateOf) return Promise.resolve(enc.uint(D.projects[idAt(0)]?.reward ?? 0n));
      if (sel === SEL.creationFee) return Promise.resolve(enc.uint(0));
      if (sel === SEL.uriOf) return Promise.resolve(enc.str(""));
    }
    if (to === D.terminal.toLowerCase() && sel === SEL.STORE) return Promise.resolve(enc.addr(D.store));
    if (to === D.terminal.toLowerCase() && sel === SEL.previewPayFor) {
      const p = D.projects[idAt(0)];
      const amount = decUint(arg(2));
      const mint = p?.supply > 0n ? amount * p.supply / p.sigma : amount;
      return Promise.resolve("0x" + Array(9).fill(word(0)).join("") + word(mint) + word(0) + word(384) + word(0));
    }
    if (to === D.store.toLowerCase() && sel === SEL.storeBalanceOf) {
      // storeBalanceOf(terminal, projectId, token) — projectId is the 2nd arg.
      return Promise.resolve(enc.uint(D.projects[idAt(1)]?.sigma ?? 0n));
    }
    if (to === D.tokens.toLowerCase()) {
      if (sel === SEL.tokenOf) return Promise.resolve(enc.addr(D.projects[idAt(0)]?.sticky || "0x" + "0".repeat(40)));
      if (sel === SEL.projectIdOf) return Promise.resolve(enc.uint(0));
    }
    if (to === D.hook.toLowerCase()) {
      const p = D.projects[idAt(0)];
      if (sel === SEL.orphanedBalanceOf) return Promise.resolve(enc.uint(0));
      const who = decAddress(arg(1)).toLowerCase();
      const holder = p?.holders.find((h) => h.addr.toLowerCase() === who);
      if (sel === SEL.stakedBalanceOf) return Promise.resolve(enc.uint(holder?.staked ?? 0n));
      if (sel === SEL.streakStartOf) return Promise.resolve(enc.uint(holder?.start ?? 0));
      if (sel === SEL.longestStreakOf) return Promise.resolve(enc.uint(holder?.longest ?? 0));
      if (sel === SEL.tranchesOf) return Promise.resolve(enc.tranches(p?.tranches[who] || []));
      if (sel === SEL.trancheCountOf) return Promise.resolve(enc.uint(p?.tranches[who]?.length || 0));
      if (sel === SEL.tranchesRangeOf) return Promise.resolve(enc.tranches((p?.tranches[who] || []).slice(idAt(2), idAt(2) + idAt(3))));
      if (sel === SEL.isGranterOf) return Promise.resolve(enc.bool(false));
      if (sel === SEL.isTrustedSenderOf) return Promise.resolve(enc.bool(false));
    }
    const t = D.byToken[to];
    if (t) {
      const p = t.p;
      if (sel === SEL.symbol) return Promise.resolve(enc.str(t.kind === "sticky" ? p.stSymbol : p.symbol));
      if (sel === SEL.name) return Promise.resolve(enc.str(t.kind === "sticky" ? p.stName : p.name));
      if (sel === SEL.decimals) return Promise.resolve(enc.uint(p.decimals));
      if (sel === SEL.SOULBOUND) return Promise.resolve(enc.uint(p.soulbound));
      if (sel === SEL.totalSupply) return Promise.resolve(enc.uint(t.kind === "sticky" ? p.supply : p.sigma));
      if (sel === SEL.balanceOf) {
        const who = decAddress(arg(0)).toLowerCase();
        if (t.kind === "staked") return Promise.resolve(enc.uint(D.wallet[who]?.[to] ?? 0n));
        return Promise.resolve(enc.uint(p.holders.find((h) => h.addr.toLowerCase() === who)?.staked ?? 0n));
      }
      if (sel === SEL.allowance) return Promise.resolve(enc.uint(2n ** 255n));
    }
    return Promise.resolve("0x" + word(0));
  }
  return Promise.resolve(null);
}

// Baked-in config from config.js; the connection card stays hidden unless toggled.
const config = window.STICKY_CONFIG ?? {};
if (config.demoMode) {
  const D = demoData();
  window.__DEMO_RPC = demoRpc;
  config.usdPriceOverrides = { ...(config.usdPriceOverrides || {}), ...D.prices };
  config.logoOverrides = { ...(config.logoOverrides || {}), ...D.logos };
  config.demoHomeStickiest = D.demoCards;
  window.STICKY_CONFIG = config;
  $("rpc").value = "demo";
  $("deployer").value = D.deployer;
  $("account").value = D.you;
  $("demo-notice").classList.remove("hide");
  guard(loadDeployer)();
} else {
  window.STICKY_CONFIG = StickyRuntime.withoutFixtures(config, location.hostname);
  const selectedId = Number(new URL(location.href).searchParams.get("chain") || config.defaultChainId || 1);
  const selected = chainById(selectedId);
  const chainConfig = StickyRuntime.deployment(config, selectedId);
  const isDefault = selectedId === Number(config.defaultChainId || 1);
  $("rpc").value = chainConfig.rpcUrl || (isDefault && config.rpcUrl) || selected?.rpcUrl || "";
  $("deployer").value = chainConfig.deployer || "";
  if (config.account && config.localMode === true && ["localhost", "127.0.0.1", "[::1]"].includes(location.hostname)) $("account").value = config.account;
  // The home page lists the whole environment; the page's own chain serves project, account and handle routes.
  if (isHomeRoute()) route();
  if (selected && $("deployer").value) loadDeployer().catch((error) => isHomeRoute() ? console.error(error) : homeFailed(error));
  else if (!isHomeRoute()) status(selected ? "Sticky is not configured on this chain yet." : "This chain is not supported.", "err");
}
setInterval(() => refreshPosition().catch(() => {}), 15_000);

installTxRecoveryUI();
