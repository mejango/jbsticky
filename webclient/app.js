// Sticky webclient. Raw JSON-RPC, no dependencies, no build step.
// Hash-routed: #/ is the homepage; #/project/<id> is a sticky token's overview, with
// /tokens and /airdrops child routes for its other tabs.
// Writes go straight to an RPC node (anvil auto-impersonation for local dev) or a browser wallet.
"use strict";

// Function selectors, precomputed with `cast sig`.
const SEL = {
  HOOK: "0xa54eb242",
  CONTROLLER: "0xee0fc121",
  TOKENS: "0x1d831d5c",
  TERMINAL: "0x160668af",
  PROJECTS: "0x293c4999",
  creationFee: "0xdce0b4e4",
  stakedTokenOf: "0xdbced5db",
  deployStickyFor: "0x00d5ce37",
  SOULBOUND: "0x32a9ba68",
  setTrustedSenderFor: "0x3a799596",
  isTrustedSenderOf: "0x5d0bc3bb",
  cashOutTaxRateOf: "0x7aac1c6f",
  STORE: "0x507f1465",
  storeBalanceOf: "0x467f4cb9",
  tranchesOf: "0x8cc1b370",
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
  cashOutTokensOf: "0x13da8317",
  mint: "0x40c10f19",
  fund: "0xbe899c89",
  beginVesting: "0x018ff2e1",
  collectVestedRewards: "0xf8724f34",
  collectableFor: "0x77b8073a",
  currentRound: "0x8a19c8bc",
  ROUND_DURATION: "0x6641ea08",
  VESTING_ROUNDS: "0xaf29da14",
  distBalanceOf: "0xf7888aec",
  ROUND_DURATION: "0x6641ea08",
  predictPocketOf: "0x7780193e",
  settleFor: "0x85713bc6",
  ensReverseWithGateways: "0xb7d6ca64",
  handleOf: "0xd9b0da2d",
  ownerOf: "0x6352211e",
  isGranterOf: "0xb9f2a2ba",
  asConfigOf: "0x7f1a9379",
  asStatusOf: "0x57cf5a31",
  asSetConfigFor: "0x415174c8",
  asCompoundFor: "0xb105ac0d",
  asStickRewardsFor: "0xd3a651da",
  asBeginVestingFor: "0x19b1b278",
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
};

// ---------------------------------------------------------------- abi codec
const strip = (h) => h.replace(/^0x/, "");
const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const encAddress = (a) => strip(a).toLowerCase().padStart(64, "0");
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
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}

const decUint = (hex, i = 0) => BigInt("0x" + (strip(hex).slice(i * 64, i * 64 + 64) || "0"));
const decAddress = (hex, i = 0) => "0x" + strip(hex).slice(i * 64 + 24, i * 64 + 64);
function decString(hex) {
  const h = strip(hex);
  const offset = Number(decUint(h, 0)) * 2;
  const len = Number(BigInt("0x" + h.slice(offset, offset + 64)));
  return new TextDecoder().decode(hexToBytes(h.slice(offset + 64, offset + 64 + len * 2)));
}
// JBStickyTranche[]: offset word, length word, then (amount, timestamp) per tranche.
function decTranches(hex) {
  const h = strip(hex);
  const offset = Number(decUint(h, 0)) / 32;
  const len = Number(decUint(h, offset));
  const out = [];
  for (let i = 0; i < len; i++) {
    out.push({ amount: decUint(h, offset + 1 + i * 2), timestamp: Number(decUint(h, offset + 2 + i * 2)) });
  }
  return out;
}

// ------------------------------------------------------------- rpc plumbing
const $ = (id) => document.getElementById(id);
let walletAccount = null; // set when a browser wallet is connected
const account = () => viewAs ?? walletAccount ?? $("account").value;
const txAccount = () => walletAccount ?? $("account").value;

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
  const res = await fetch($("rpc").value, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(json.error.message);
  return json.result;
}

// Match Juicescan's ENS behavior: reverse-resolve every account against Ethereum mainnet's Universal Resolver,
// independently of the chain the sticky project lives on. Results (including misses) are cached per address.
const ENS_RPC_URL = window.STICKY_CONFIG?.ensRpc || "https://ethereum-rpc.publicnode.com";
const ENS_UNIVERSAL_RESOLVER = "0xeeeeeeee14d718c2b47d9923deab1335e144eeee";
const ensNameCache = new Map();

async function ensRpc(method, params) {
  const res = await fetch(ENS_RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(json.error.message);
  return json.result;
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
  if (!/^0x[0-9a-f]{40}$/.test(key)) return Promise.resolve(null);
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
const fromBlock = () => window.STICKY_CONFIG?.fromBlock ?? "earliest";
const getLogs = (address, topics) =>
  rpc("eth_getLogs", [{ address, topics, fromBlock: fromBlock(), toBlock: "latest" }]);

const blockTimestamps = {};
async function blockTimestamp(blockNumber) {
  if (!(blockNumber in blockTimestamps)) {
    const block = await rpc("eth_getBlockByNumber", [blockNumber, false]);
    blockTimestamps[blockNumber] = Number(BigInt(block.timestamp));
  }
  return blockTimestamps[blockNumber];
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

async function sendTx(tx) {
  const chainId = Number(tx.chainId ?? ctx.chainId);
  const wireTx = { to: tx.to, data: tx.data, ...(tx.value ? { value: tx.value } : {}) };
  let hash;
  if (walletAccount) {
    await ensureWalletChain(chainId);
    wireTx.from = walletAccount;
    hash = await activeProvider.request({ method: "eth_sendTransaction", params: [wireTx] });
  } else {
    if (chainId !== ctx.chainId) throw new Error("connect a wallet to deploy on more than the connected chain");
    wireTx.from = txAccount();
    hash = await rpc("eth_sendTransaction", [wireTx]);
  }
  txStatus(`Transaction ${hash.slice(0, 14)}… submitted. Awaiting confirmation…`);
  for (let i = 0; i < 120; i++) {
    const receipt = walletAccount
      ? await activeProvider.request({ method: "eth_getTransactionReceipt", params: [hash] })
      : await rpc("eth_getTransactionReceipt", [hash]);
    if (receipt) {
      if (receipt.status !== "0x1") throw new Error(`tx reverted: ${hash}`);
      return receipt;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("timed out waiting for receipt");
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
  const [whole, frac = ""] = str.trim().split(".");
  if (!/^\d*$/.test(whole) || !/^\d*$/.test(frac)) throw new Error(`bad amount: ${str}`);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0").slice(0, decimals));
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
function tokenLogo(addr, symbol, size = 15) {
  return `<span data-token-logo="${addr}" data-size="${size}" style="display:inline-flex;flex:none">${tokenBadge(addr, symbol, size)}</span>`;
}

function tokenBadge(addr, symbol, size) {
  const hue = Number(BigInt(addr) % 360n);
  const letter = (symbol || "?").slice(0, 1).toUpperCase();
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}"><rect width="24" height="24" rx="6" fill="hsl(${hue} 45% 42%)"/>` +
    `<text x="12" y="16.4" font-size="12" font-weight="700" fill="#f0f7f9" text-anchor="middle" font-family="ui-monospace,Menlo,monospace">${esc(letter)}</text></svg>`;
}
const ipfsUrl = (uri) => uri.replace("ipfs://", "https://ipfs.io/ipfs/");
const logoCache = {}; // token addr -> url | null | pending promise
const projectMetadataCache = {}; // project token addr -> metadata | null | pending promise

async function resolveProjectMetadata(addr) {
  const key = addr.toLowerCase();
  if (key in projectMetadataCache) return projectMetadataCache[key];
  return (projectMetadataCache[key] = (async () => {
    try {
      const projectId = decUint(await view(ctx.tokens, SEL.projectIdOf, encAddress(addr)));
      if (projectId === 0n) return null;
      const uri = decString(await view(ctx.controller, SEL.uriOf, word(projectId)));
      if (!uri) return null;
      return await (await fetch(ipfsUrl(uri))).json();
    } catch {
      return null;
    }
  })());
}

async function resolveTokenLogoUrl(addr) {
  const key = addr.toLowerCase();
  const override = window.STICKY_CONFIG?.logoOverrides?.[key];
  if (override) return (logoCache[key] = override);
  if (key in logoCache) return logoCache[key];
  return (logoCache[key] = (async () => {
    const metadata = await resolveProjectMetadata(addr);
    return metadata?.logoUri ? ipfsUrl(metadata.logoUri) : null;
  })());
}

async function hydrateProjectName(projectId, info) {
  const override = window.STICKY_CONFIG?.projectNameOverrides?.[String(projectId)];
  if (override) {
    $("h-name").textContent = override;
    return;
  }
  const metadata = await resolveProjectMetadata(info.stakedToken);
  if (ctx.currentId === projectId && metadata?.name) $("h-name").textContent = metadata.name;
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
    const chains = metadata?.protocol === "JBSticky" ? metadata.chains : null;
    if (Array.isArray(chains) && chains.length) return chains.map(Number).filter(chainById);
  } catch {}
  return ctx.chainId ? [ctx.chainId] : [];
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
    const url = await resolveTokenLogoUrl(addr);
    if (url) el.innerHTML = `<img src="${url}" width="${size}" height="${size}" style="border-radius:6px;object-fit:cover;display:block" onerror="this.remove()">`;
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

function inlineStatus(anchor, msg, cls = "err") {
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
}
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

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

async function loadDeployer() {
  const deployer = $("deployer").value;
  status("loading…");
  ctx.hook = decAddress(await view(deployer, SEL.HOOK));
  ctx.tokens = decAddress(await view(deployer, SEL.TOKENS));
  ctx.terminal = decAddress(await view(deployer, SEL.TERMINAL));
  ctx.store = decAddress(await view(ctx.terminal, SEL.STORE));
  ctx.controller = decAddress(await view(deployer, SEL.CONTROLLER));
  try {
    ctx.chainId = Number(BigInt(await rpc("eth_chainId", [])));
  } catch {}
  ctx.loaded = true;
  ctx.projects = {};
  handleRouteCache.clear();
  // Re-resolve the fund-origin default now that the connected chain is known.
  originKey = null;
  renderOriginPills();
  status("onchain", "ok");
  route();
}

async function projectInfo(projectId) {
  const key = projectId.toString();
  if (ctx.projects[key]) return ctx.projects[key];
  const idArg = word(projectId);
  const stakedToken = decAddress(await view($("deployer").value, SEL.stakedTokenOf, idArg));
  if (stakedToken === "0x0000000000000000000000000000000000000000") {
    throw new Error(`project ${projectId} is not a sticky token of this deployer`);
  }
  const stToken = decAddress(await view(ctx.tokens, SEL.tokenOf, idArg));
  const [symbol, decimals, name, stSymbol, stName, reward, soulbound] = await Promise.all([
    view(stakedToken, SEL.symbol).then(decString),
    view(stakedToken, SEL.decimals).then((h) => Number(decUint(h))),
    view(stakedToken, SEL.name).then(decString),
    view(stToken, SEL.symbol).then(decString),
    view(stToken, SEL.name).then(decString),
    view($("deployer").value, SEL.cashOutTaxRateOf, idArg).then(decUint),
    view(stToken, SEL.SOULBOUND).then((h) => decUint(h) === 1n).catch(() => true),
  ]);
  ctx.projects[key] = { stakedToken, symbol, decimals, name, stToken, stSymbol, stName, reward, soulbound };
  return ctx.projects[key];
}

const stickyLabel = (info) => `Sticky ${info.symbol}`;

async function projectIds() {
  const logs = await getLogs($("deployer").value, [TOPIC.DeploySticky]);
  return logs.map((log) => decUint(log.topics[1]));
}

// Hook logs for a project (or all projects when undefined), with block timestamps attached.
async function hookLogs(projectId) {
  const projectTopic = projectId === undefined ? null : "0x" + word(projectId);
  const logs = await getLogs(ctx.hook, [
    [TOPIC.Staked, TOPIC.Unstaked, TOPIC.StreakStarted, TOPIC.StreakEnded],
    projectTopic,
  ]);
  for (const log of logs) log.ts = await blockTimestamp(log.blockNumber);
  return logs;
}

// Per-holder rows for a project: staked balance, live current streak, longest.
async function holderRows(projectId, logs) {
  const stakedLogs = logs.filter((log) => log.topics[0] === TOPIC.Staked);
  const holders = [...new Set(stakedLogs.map((log) => decAddress(log.topics[2])))];
  const now = Math.floor(Date.now() / 1000);
  const idArg = word(projectId);
  return Promise.all(
    holders.map(async (holder) => {
      const args = idArg + encAddress(holder);
      const [staked, streakStart, longest] = await Promise.all([
        view(ctx.hook, SEL.stakedBalanceOf, args).then(decUint),
        view(ctx.hook, SEL.streakStartOf, args).then(decUint),
        view(ctx.hook, SEL.longestStreakOf, args).then(decUint),
      ]);
      const current = streakStart === 0n ? 0 : Math.max(0, now - Number(streakStart));
      return { holder, staked, current, longest: Math.max(Number(longest), current) };
    }),
  );
}

// Decode hook logs into activity cards, newest first. Each card carries the stuck token's logo.
async function activityItems(logs, includeProject) {
  const items = [];
  for (const log of logs.slice(-40)) {
    const id = decUint(log.topics[1]);
    let info;
    try {
      info = await projectInfo(id);
    } catch {
      continue; // a project from another deployer sharing the hook
    }
    const holder = shortAddr(decAddress(log.topics[2]));
    let html;
    if (log.topics[0] === TOPIC.Staked) {
      const autoStuck = decAddress(log.data, 0).toLowerCase() === (autoStickAdapter() || "").toLowerCase();
      html = `<span class="addr">${holder}</span> <span class="verb">${autoStuck ? "auto-stuck" : "locked"}</span> ${formatUnits(decUint(log.data, 1), 18)} ${esc(info.symbol)}`;
    } else if (log.topics[0] === TOPIC.Unstaked) {
      html = `<span class="addr">${holder}</span> <span class="verb out">unlocked</span> ${formatUnits(decUint(log.data, 0), 18)} ${esc(info.symbol)}`;
    } else if (log.topics[0] === TOPIC.StreakStarted) {
      html = `<span class="addr">${holder}</span> <span class="verb">got sticky</span>`;
    } else {
      html = `<span class="addr">${holder}</span> <span class="verb out">came unstuck after ${formatDuration(decUint(log.data, 0))}</span>`;
    }
    const nameLine = includeProject
      ? `<div><span class="link" onclick="location.hash='#/project/${id}'">${esc(stickyLabel(info))}</span></div>`
      : "";
    items.push(
      `<div class="card-item"><div class="card-head">${tokenLogo(info.stakedToken, info.symbol, 22)}` +
      `<div style="flex:1;min-width:0"><div class="mut" style="font-size:11px">${ago(log.ts)}</div>` +
      `${nameLine}<div>${html}</div></div></div></div>`,
    );
  }
  return items.reverse();
}

// A stake paid for someone else is an airdrop. Staked logs include both payer and holder, so this is exact.
async function airdropItems(logs) {
  const items = [];
  const staked = logs.filter((log) => log.topics[0] === TOPIC.Staked).slice(-40);
  for (const log of staked) {
    const holder = decAddress(log.topics[2]);
    const payer = decAddress(log.data, 0);
    if (holder.toLowerCase() === payer.toLowerCase()) continue;
    // Auto-stick compounds are the holder's own rewards, not airdrops.
    if (payer.toLowerCase() === (autoStickAdapter() || "").toLowerCase()) continue;
    const id = decUint(log.topics[1]);
    let info;
    try {
      info = await projectInfo(id);
    } catch {
      continue;
    }
    const amount = formatUnits(decUint(log.data, 1), 18);
    const self = holder.toLowerCase() === account().toLowerCase() ? " (you)" : "";
    items.push(
      `<div class="card-item"><div class="card-head">${tokenLogo(info.stakedToken, info.symbol, 22)}`
      + `<div style="flex:1;min-width:0"><div class="mut" style="font-size:11px">${ago(log.ts)}</div>`
      + `<div><span class="link" onclick="location.hash='#/project/${id}'">${esc(stickyLabel(info))}</span></div>`
      + `<div><span class="addr">${addressLabel(holder)}${self}</span> received ${amount} ${esc(info.symbol)}`
      + ` from <span class="addr">${addressLabel(payer)}</span></div></div></div></div>`,
    );
  }
  return items.reverse();
}

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
      + `<div><span class="link" onclick="location.hash='#/project/${row.projectId}'">${esc(stickyLabel(info))}</span></div>`
      + `<div><span class="addr">${addressLabel(row.holder)}${self}</span> received ${esc(String(row.amount))} ${esc(info.symbol)}`
      + ` from <span class="addr">${addressLabel(row.payer)}</span></div></div></div></div>`,
    );
  }
  return items;
}

const renderFeed = (el, items, empty = "no activity yet") => {
  el.innerHTML = items.length ? items.join("") : `<div class="card-item mut">${esc(empty)}</div>`;
  hydrateEns(el).catch(() => {});
};

function setHomeListTab(active) {
  for (const name of ["latest", "stickiest", "airdrops"]) {
    const selected = name === active;
    $("home-tab-" + name).classList.toggle("on", selected);
    $("home-tab-" + name).setAttribute("aria-selected", String(selected));
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
    $("home-panel-" + name).classList.toggle("ranking-on", selected);
  }
}
$("home-rank-stickiest").onclick = () => setHomeRankingTab("stickiest");
$("home-rank-airdrops").onclick = () => setHomeRankingTab("airdrops");

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


function configuredUsdPrice(card) {
  const entries = Object.entries(window.STICKY_CONFIG?.usdPriceOverrides || {});
  const overrides = new Map(entries.map(([key, price]) => [key.toLowerCase(), price]));
  const address = card.info.stakedToken.toLowerCase();
  const keys = [`${ctx.chainId}:${address}`, address, card.info.symbol.toLowerCase()];
  for (const key of keys) {
    const price = usdMicros(overrides.get(key));
    if (price !== null) return price;
  }
  return null;
}

// Prices are keyed by chain and contract address. Symbols are only accepted as explicit config overrides,
// which keeps two unrelated tokens with the same ticker from being accidentally valued as one asset.
async function backingUsdPrices(cards) {
  const prices = new Map();
  const missingByAddress = new Map();
  for (const card of cards) {
    const override = configuredUsdPrice(card);
    if (override !== null) {
      prices.set(card.id.toString(), override);
      continue;
    }
    const address = card.info.stakedToken.toLowerCase();
    if (!missingByAddress.has(address)) missingByAddress.set(address, []);
    missingByAddress.get(address).push(card);
  }

  const chain = DEXSCREENER_CHAIN[ctx.chainId];
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
      if (price !== null) for (const card of addressCards) prices.set(card.id.toString(), price);
    }
  } catch (error) {
    console.warn("Unable to price Sticky backing tokens", error);
  } finally {
    clearTimeout(timeout);
  }
  return prices;
}

function projectStakedHistory(logs, card, now) {
  const configured = configuredChartPoints(now, card.id);
  if (configured) {
    const points = configured.map((point) => ({ ts: point.ts, value: point.staked }));
    points[points.length - 1] = { ts: now, value: card.totalStaked };
    return points;
  }

  const events = logs.flatMap((log) => {
    if (decUint(log.topics[1]) !== card.id) return [];
    if (log.topics[0] === TOPIC.Staked) return [{ ts: log.ts, delta: decUint(log.data, 1) }];
    if (log.topics[0] === TOPIC.Unstaked) return [{ ts: log.ts, delta: -decUint(log.data, 0) }];
    return [];
  }).sort((a, b) => a.ts - b.ts);

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

function homeSecuredSeries(logs, cards, prices) {
  const now = Math.floor(Date.now() / 1000);
  const valuedCards = cards.filter((card) => prices.has(card.id.toString()));
  const histories = valuedCards.map((card) => ({
    card,
    price: prices.get(card.id.toString()),
    points: projectStakedHistory(logs, card, now),
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
      value += amount * history.price / 10n ** 18n;
    }
    return { ts, value };
  });
  const total = valuedCards.reduce(
    (sum, card) => sum + card.totalStaked * prices.get(card.id.toString()) / 10n ** 18n,
    0n,
  );
  points[points.length - 1] = { ts: now, value: total };
  const missing = cards.filter((card) => card.totalStaked > 0n && !prices.has(card.id.toString()));
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
  value.title = series.missing.length
    ? `Could not price ${series.missing.map((card) => card.info.symbol).join(", ")}`
    : "USD value of the tokens backing Sticky tokens";
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
    const label = `${date(sample.ts)}: ${formatUsd(sample.value)}`;
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
    hoverValue.textContent = formatUsd(sample.value);
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
  const svg = `<svg viewBox="0 0 ${W} ${H}" style="width:100%;max-width:${W}px;cursor:crosshair" tabindex="0" role="img" aria-label="Active sticks and total stuck over time">
    ${guides}
    <line x1="${PAD}" y1="${(20 + H - 24) / 2}" x2="${W - 10}" y2="${(20 + H - 24) / 2}" stroke="#d8e7eb" stroke-dasharray="2 4"/>
    <line x1="${PAD}" y1="${H - 24}" x2="${W - 10}" y2="${H - 24}" stroke="#e2d7bd"/>
    <line x1="${PAD}" y1="20" x2="${PAD}" y2="${H - 24}" stroke="#e2d7bd"/>
    <path d="${path(yStaked, "staked")}" fill="none" stroke="#1c2d33" stroke-width="1.3" opacity="0.75"/>
    <path d="${path(yStreaks, "streaks")}" fill="none" stroke="#2fb3c7" stroke-width="2"/>
    <text x="${PAD - 6}" y="${yStreaks(maxStreaks) + 4}" fill="#64808a" font-size="10" text-anchor="end">${maxStreaks}</text>
    <text x="${PAD - 6}" y="${H - 21}" fill="#64808a" font-size="10" text-anchor="end">0</text>
    <text x="${W - 10}" y="16" fill="#1c2d33" font-size="10" text-anchor="end">max ${formatUnits(maxStaked, 18, 0)} ${esc(info.symbol)}</text>
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
        lockedLabel.textContent = `${formatUnits(point.staked, 18, 2)} ${info.symbol} stuck`;
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
    </g></svg><div class="owner-pie-total"><b>${formatUnits(total, 18)}</b> Sticky ${esc(symbol)}
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
async function renderHome() {
  clearHomeSecuredChart();
  $("view-home").classList.remove("hide");
  $("view-project").classList.add("hide");
  if (!ctx.loaded) return;

  const ids = await projectIds();
  const logs = await hookLogs(undefined);

  // Stickiest: project cards sorted by amount stuck, jbm-style key:value pairs, one logo — the stuck token's.
  const cards = (
    await Promise.all(
      ids.map(async (id) => {
        try {
          const info = await projectInfo(id);
          const projectLogs = logs.filter((log) => decUint(log.topics[1]) === id);
          const rows = await holderRows(id, projectLogs);
          const totalStaked = await view(info.stToken, SEL.totalSupply).then(decUint);
          return { id, info, totalStaked, sticks: rows.filter((r) => r.staked > 0n).length };
        } catch {
          return null;
        }
      }),
    )
  ).filter(Boolean);
  cards.sort((a, b) => (b.totalStaked > a.totalStaked ? 1 : b.totalStaked < a.totalStaked ? -1 : 0));
  const prices = await backingUsdPrices(cards);
  mountHomeSecuredChart(homeSecuredSeries(logs, cards, prices));
  const homeCards = [...cards, ...configuredStickiestCards()];
  $("projects").innerHTML = homeCards.length
    ? homeCards.map((card, i) =>
        `<div class="card-item${card.demo ? "" : " pickc"}"${card.demo ? "" : ` onclick="location.hash='#/project/${card.id}'"`}><div class="card-head">` +
        `<span class="rank">${i + 1}</span>${tokenLogo(card.info.stakedToken, card.info.symbol, 26)}` +
        `<div style="flex:1;min-width:0"><div style="font-weight:700">${esc(stickyLabel(card.info))} <span class="mut">#${card.id}</span></div>` +
        `<div class="kv"><span class="mut">Stuck:</span> ${formatUnits(card.totalStaked, 18)} ${esc(card.info.symbol)}</div>` +
        `<div class="kv"><span class="mut">Sticks:</span> ${card.sticks}</div>` +
        `<div class="kv"><span class="mut">Bonus:</span> ${pct(card.info.reward)}</div>` +
        `</div></div></div>`,
      ).join("")
    : `<div class="card-item mut">no sticky tokens yet — create one</div>`;

  renderFeed($("activity"), await activityItems(logs, true));
  const [liveAirdrops, demoAirdrops] = await Promise.all([airdropItems(logs), configuredAirdropItems()]);
  renderFeed($("airdrops"), [...liveAirdrops, ...demoAirdrops], "no airdrops yet");
  hydrateLogos().catch(() => {});
}

// ------------------------------------------------------------------- project
async function renderProject(projectId) {
  if (!ctx.loaded) return;
  clearHomeSecuredChart();
  ctx.currentId = projectId;
  $("view-home").classList.add("hide");
  $("view-project").classList.remove("hide");
  // A verified handle stays in the address bar while tabs change and across post-transaction refreshes.
  const projectRoute = ctx.alias ? `#/${ctx.alias}` : `#/project/${projectId}`;
  $("tab-btn-overview").href = projectRoute;
  $("tab-btn-owners").href = `${projectRoute}/tokens`;
  $("tab-btn-rewards").href = `${projectRoute}/airdrops`;

  const info = await projectInfo(projectId);
  $("p-logo").innerHTML = tokenLogo(info.stakedToken, info.symbol, 104);
  $("h-symbol").textContent = stickyLabel(info);
  $("h-name").textContent = window.STICKY_CONFIG?.projectNameOverrides?.[String(projectId)] || info.name;
  hydrateProjectName(projectId, info).catch(() => {});
  $("tranches-amount-head").textContent = `AMOUNT (${info.symbol})`;
  $("stake-title").textContent = `Stick ${info.symbol}`;
  $("stake-symbol").textContent = info.symbol;
  $("unstake-symbol").textContent = info.symbol;
  $("unstake-hint").textContent = info.reward > 0n
    ? `unsticking leaves ${pct(info.reward)} behind for those still stuck | newest tranche first | stickiness clock resets only at zero`
    : `unwind fee-free 1:1 | newest tranche first | streak resets only at zero`;

  const logs = await hookLogs(projectId);
  const [totalStaked, tokenSupply, rows, pool] = await Promise.all([
    view(info.stToken, SEL.totalSupply).then(decUint),
    view(info.stakedToken, SEL.totalSupply).then(decUint),
    holderRows(projectId, logs),
    poolBacking(projectId, info),
  ]);
  ctx.pool = pool;
  renderUnstickQuote();
  renderStickQuote();
  $("p-bonus-card").classList.toggle("hide", info.reward === 0n);
  if (info.reward > 0n) {
    const rho0 = pool.supply > 0n ? Number((pool.sigma * 10n ** 18n) / pool.supply) / 10 ** info.decimals : 1;
    $("p-bonus-blurb").textContent =
      `${pct(info.reward)} of each unstick stays in the pool, backing every ${info.stSymbol} that remains.`
      + (rho0 > 1.0005 ? ` 1 ${info.stSymbol} is currently backed by ${parseFloat(rho0.toFixed(4))} ${info.symbol}.` : "");
    renderBonusSplit(Number(info.reward) / 10000, {
      el: $("p-ratchet"),
      rho0,
      sym: info.symbol,
      stSym: info.stSymbol,
    });
  }
  const active = rows.filter((row) => row.staked > 0n).sort((a, b) => (b.staked > a.staked ? 1 : -1));
  $("h-staked").textContent = `${formatUnits(totalStaked, 18)} ${info.symbol}`;
  $("h-streakers").textContent = active.length;
  const averageActive = active.length
    ? Math.floor(active.reduce((total, row) => total + row.current, 0) / active.length)
    : 0;
  $("h-average").textContent = formatDuration(averageActive);
  $("h-top").textContent = formatDuration(active.reduce((m, row) => Math.max(m, row.current), 0));
  renderProjectChains(await projectChainIds(projectId));

  // OVERVIEW: chart + my position.
  const chart = chartSvg(logs, info, projectId);
  $("chart").innerHTML = chart.svg;
  chart.bind?.($("chart"));
  await refreshPosition();

  // OWNERS: token info, pie, leaderboard.
  let granters = [];
  try {
    const granterLogs = await getLogs(ctx.hook, [TOPIC.SetGranter, "0x" + word(projectId)]);
    granters = [...new Set(granterLogs.map((log) => decAddress(log.topics[2])))];
  } catch {}
  const transferMode = info.soulbound ? "No" : "Yes";
  const transferRule = info.soulbound
    ? "Transfers are disabled. Sticky tokens are minted by sticking and burned by unsticking."
    : "Transfers move the sender's newest tranches first. The recipient receives a fresh tranche; existing streaks keep running unless the sender transfers everything.";
  const bonusRule = info.reward > 0n
    ? `${pct(info.reward)} of each unstick stays with everyone still stuck.`
    : "Unsticking returns the underlying tokens one for one; no bonus stays behind.";
  // The auto-stick adapter is presented as its own pre-approval, not as a generic airdrop sender.
  const adapterGranter = granters.some((g) => g.toLowerCase() === (autoStickAdapter() || "").toLowerCase());
  const humanGranters = granters.filter((g) => g.toLowerCase() !== (autoStickAdapter() || "").toLowerCase());
  const senderRule = "Anyone can stick for themselves. "
    + (humanGranters.length
      ? `${humanGranters.length} permanent airdrop sender${humanGranters.length === 1 ? " is" : "s are"} approved for every holder. `
      : "")
    + (adapterGranter ? "Auto-stick is available — holders turn it on with an allowance and settings. " : "")
    + "Holders can also approve trusted senders to stick for them.";
  const meta = (label, value, title = "") =>
    `<span class="token-meta"${title ? ` title="${esc(title)}"` : ""}><b>${label}:</b><span>${value}</span></span>`;
  const copySymbol = (symbol, address) =>
    `<button type="button" class="token-copy" data-address="${address}" data-copy-address="${address}" `
      + `aria-label="Copy ${esc(symbol)} token address">${esc(symbol)}</button>`;
  $("token-info").innerHTML =
    `<div class="token-meta-row">`
      + meta("Token", `${esc(info.stName)} (${copySymbol(info.stSymbol, info.stToken)})`)
      + `</div>`
    + `<div class="token-meta-row">`
      + meta("Sticks", `${esc(info.name)} (${copySymbol(info.symbol, info.stakedToken)})`)
      + meta("Total stuck", `${formatUnits(totalStaked, 18)} ${copySymbol(info.symbol, info.stakedToken)}`)
      + meta("Stickiness bonus", pct(info.reward), bonusRule)
      + (pool.supply > 0n
        ? meta(
            "Backing",
            `1 ${esc(info.stSymbol)} ≈ ${formatUnits((pool.sigma * 10n ** 18n) / pool.supply, info.decimals)} ${esc(info.symbol)}`,
            info.reward > 0n
              ? "Unsticks leave their bonus in the pool, so backing per sticky token only goes up."
              : "Pure wrapper — backing stays one for one.",
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

  const pie = pieSvg(active, info.symbol, tokenSupply);
  $("pie").innerHTML = pie.svg;
  ctx.board = { rows: active, symbol: info.symbol, total: totalStaked };
  renderBoard();
  pie.bind?.($("pie"));

  $("r-token").value ||= info.stakedToken;
  renderRewards().catch(() => {});
  renderFeed($("p-activity"), await activityItems(logs, false));
  hydrateLogos().catch(() => {});
}

async function refreshPosition() {
  if (ctx.currentId === null || !account()) return;
  const info = await projectInfo(ctx.currentId);
  const args = word(ctx.currentId) + encAddress(account());
  const [staked, streakStart, longest, wallet, tranches] = await Promise.all([
    view(ctx.hook, SEL.stakedBalanceOf, args).then(decUint),
    view(ctx.hook, SEL.streakStartOf, args).then(decUint),
    view(ctx.hook, SEL.longestStreakOf, args).then(decUint),
    view(info.stakedToken, SEL.balanceOf, encAddress(account())).then(decUint),
    view(ctx.hook, SEL.tranchesOf, args).then(decTranches),
  ]);
  // Compute the active streak against the wall clock so it ticks between blocks (the on-chain view
  // only moves with block.timestamp).
  const current = streakStart === 0n ? 0n : BigInt(Math.max(0, Math.floor(Date.now() / 1000) - Number(streakStart)));
  $("p-balance").textContent = `${formatUnits(staked, 18)} ${info.symbol}`;
  $("p-current").textContent = formatDuration(current);
  $("p-longest").textContent = formatDuration(longest > current ? longest : current);
  $("p-wallet").textContent = `${formatUnits(wallet, info.decimals)} ${info.symbol}`;
  $("open-unstick").textContent = `Unstick ${info.symbol}`;
  ctx.walletMax = formatUnits(wallet, info.decimals);
  // Full precision so "max" truly unsticks everything (and the full-exit auto-stick check sees a full exit).
  ctx.stakedMax = formatUnits(staked, 18, 18);
  $("stake-balance").textContent = ctx.walletMax;
  $("stake-balance-label").textContent = ` ${info.symbol} in wallet`;
  renderTrustedSenders().catch(() => {});
  const tbody = $("tranches");
  tbody.innerHTML = "";
  const now = Math.floor(Date.now() / 1000);
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
}

// ---------------------------------------------------------- confirm dialog
function contractNameOf(addr) {
  const lower = addr.toLowerCase();
  if (lower === ctx.terminal?.toLowerCase()) return "JBMultiTerminal";
  if (lower === $("deployer").value.toLowerCase()) return "JBStickyDeployer";
  if (lower === ctx.hook?.toLowerCase()) return "JBStickyHook";
  if (lower === distributor()?.toLowerCase()) return "JBTokenDistributor";
  if (lower === autoStickAdapter()?.toLowerCase()) return "JBStickyAutoStick";
  if (lower === window.STICKY_CONFIG?.pockets?.toLowerCase()) return "JBStickyRewardPockets";
  for (const info of Object.values(ctx.projects)) {
    if (lower === info.stakedToken.toLowerCase()) return `the ${info.symbol} token`;
    if (lower === info.stToken.toLowerCase()) return `the ${info.stSymbol} token`;
  }
  return "an unrecognized contract";
}

let confirmResolve = null;
let confirmPlan = [];
let confirmSummary = [];
let confirmProgress = -1; // -1 = reviewing; 0..n-1 = sending that step; n = all sent

// The numbered sequence card: shown for multi-step plans, and advanced live while transactions send.
function renderConfirmSteps() {
  const card = $("cd-steps");
  if (confirmPlan.length < 2) return card.classList.add("hide");
  card.classList.remove("hide");
  const intro = confirmProgress < 0
    ? `Your wallet will ask for ${confirmPlan.length} transactions. This dialog stays open and advances through each one.`
    : confirmProgress >= confirmPlan.length
      ? "All transactions confirmed."
      : `Waiting on your wallet — transaction ${confirmProgress + 1} of ${confirmPlan.length}.`;
  card.innerHTML = `<p>${esc(intro)}</p>` + confirmPlan.map((tx, i) => {
    const state = confirmProgress >= confirmPlan.length || i < confirmProgress
      ? "done"
      : i === confirmProgress ? "current" : "pending";
    return `<div class="cd-step ${state}"><i>${state === "done" ? "✓" : i + 1}</i><span>${esc(tx.label)}</span></div>`;
  }).join("");
}

function renderConfirm() {
  $("cd-summary").innerHTML = confirmSummary
    .map(([k, v]) => `<div class="cd-summary-row"><span class="k">${esc(k)}</span><span class="v">${esc(String(v))}</span></div>`)
    .join("");
  renderConfirmSteps();
  $("cd-warn").textContent = confirmPlan.length > 1
    ? "These are the exact transactions that will be sent to your wallet. Nothing is signed until you confirm each one — review before signing."
    : "This is the exact transaction that will be sent to your wallet. Nothing is signed until you confirm — review before signing.";
  $("cd-body").innerHTML = confirmPlan
    .map((tx, i) => {
      const chain = tx.chainLabel || chainById(tx.chainId ?? ctx.chainId)?.label || "";
      const step = confirmPlan.length > 1 ? `${i + 1}. ` : "";
      const rows = [...tx.args];
      if (tx.value) rows.push(["VALUE", tx.valueLabel ?? `${BigInt(tx.value)} wei`]);
      return `<div class="txstep">`
        + (chain ? `<div class="cd-chain">${esc(chain)}</div>` : "")
        + `<div class="cd-contract"><b>${esc(tx.contractName || contractNameOf(tx.to))}</b> | ${esc(tx.to)}</div>`
        + `<h3>${step}${esc(tx.label)}</h3>`
        + `<table><tbody>`
        + rows.map(([k, v]) => `<tr><th style="width:104px">${esc(k)}</th><td style="word-break:break-all">${esc(String(v))}</td></tr>`).join("")
        + `</tbody></table>`
        + `<details class="cd-raw"><summary>Show raw data</summary>`
        + `<div class="rawbox">function: ${esc(tx.fn)}\nto: ${tx.to}\nvalue: ${tx.value ? BigInt(tx.value) : 0} wei\ndata: ${tx.data}</div></details>`
        + `</div>`;
    })
    .join("");
}

// Show the consent dialog for a transaction plan. Resolves true only if the user confirms.
// `summary` is optional plain-language rows shown above the sequence, e.g. [["Stick", "10 ART"]].
function confirmTxs(title, txs, summary = []) {
  confirmPlan = txs;
  confirmSummary = summary;
  confirmProgress = -1;
  $("cd-title").textContent = title;
  $("cd-confirm").disabled = false;
  $("cd-cancel").classList.remove("hide");
  renderConfirm();
  $("confirm-dialog").showModal();
  return new Promise((resolve) => {
    confirmResolve = resolve;
  });
}

function settleConfirm(ok) {
  // A confirmed plan keeps the dialog open so the sequence card can advance through the sends.
  if (!ok) {
    try { $("confirm-dialog").close(); } catch {}
  }
  const resolve = confirmResolve;
  confirmResolve = null;
  if (resolve) resolve(ok);
}

// The one true tx path: review, confirm, then send each step while the dialog reports progress.
// Resolves true when every transaction landed; false when the user cancelled.
async function confirmAndRun(title, txs, summary = []) {
  if (!(await confirmTxs(title, txs, summary))) {
    return false;
  }
  $("cd-confirm").disabled = true;
  $("cd-cancel").classList.add("hide");
  try {
    for (let i = 0; i < txs.length; i++) {
      confirmProgress = i;
      renderConfirmSteps();
      txStatus(`${txs[i].label}…`);
      txs[i].receipt = await sendTx({
        to: txs[i].to,
        data: txs[i].data,
        chainId: txs[i].chainId,
        ...(txs[i].value ? { value: txs[i].value } : {}),
      });
    }
    confirmProgress = txs.length;
    renderConfirmSteps();
  } finally {
    try { $("confirm-dialog").close(); } catch {}
  }
  return true;
}

async function auditPrompt() {
  const chainIds = [...new Set(confirmPlan.map((tx) => Number(tx.chainId ?? ctx.chainId)))];
  const lines = [
    "Audit these Ethereum transactions before I sign them. Do not assume good intent — verify everything.",
    `Chain ids: ${chainIds.join(", ")}. My account: ${account()}. App: Sticky webclient (${location.origin}).`,
    `Stated intent: ${$("cd-title").textContent}.`,
    "",
  ];
  confirmPlan.forEach((tx, i) => {
    lines.push(
      `Transaction ${i + 1} of ${confirmPlan.length}: ${tx.label}`,
      `- chain id: ${tx.chainId ?? ctx.chainId}`,
      `- to: ${tx.to} (expected to be ${tx.contractName || contractNameOf(tx.to)})`,
      `- function: ${tx.fn}`,
      ...tx.args.map(([k, v]) => `- ${k.toLowerCase()}: ${v}`),
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
  const idArg = word(ctx.currentId);
  // Candidates come from the holder's trust events; current state is re-read from the contract.
  const logs = await getLogs(ctx.hook, [TOPIC.SetTrustedSender, "0x" + idArg, "0x" + encAddress(account())]);
  // The auto-stick adapter's trust is presented through the auto-stick card, not as a generic airdropper.
  const candidates = [...new Set(logs.map((log) => decAddress(log.topics[3])))]
    .filter((sender) => sender.toLowerCase() !== (autoStickAdapter() || "").toLowerCase());
  const current = [];
  for (const sender of candidates) {
    const trusted = decUint(await view(ctx.hook, SEL.isTrustedSenderOf, idArg + encAddress(account()) + encAddress(sender)));
    if (trusted === 1n) current.push(sender);
  }
  $("trusted-list").innerHTML = current.length
    ? current.map((sender) =>
        `<tr><td style="word-break:break-all">${sender}</td>` +
        `<td style="width:90px"><button class="danger" style="margin:0;padding:4px 10px" onclick="untrustSender('${sender}')">Untrust</button></td></tr>`,
      ).join("")
    : `<tr><td class="trusted-empty"><strong>None yet</strong><span>Only you and the project's airdrop senders can add to your streak.</span></td></tr>`;
}

async function setTrust(sender, trusted) {
  const info = await projectInfo(ctx.currentId);
  const txs = [{
    label: trusted ? "Trust sender" : "Untrust sender",
    to: ctx.hook,
    fn: "setTrustedSenderFor(uint256 projectId, address sender, bool trusted)",
    args: [
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["SENDER", sender],
      ["TRUSTED", trusted ? "yes — they can add stakes to your position" : "no — they can no longer add stakes to your position"],
    ],
    data: SEL.setTrustedSenderFor + word(ctx.currentId) + encAddress(sender) + word(trusted ? 1 : 0),
  }];
  if (!(await confirmAndRun(`${trusted ? "Trust" : "Untrust"} ${shortAddr(sender)}`, txs))) return;
  txStatus(trusted ? "Sender trusted" : "Sender untrusted", "ok");
  await renderTrustedSenders();
}

window.untrustSender = (sender) => guard(() => setTrust(sender, false))({ currentTarget: document.activeElement });

const CHAIN_ICON_SVG = {
  eth: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#627EEA"/><path d="M12 4v5.9l5 2.25z" fill="#fff" fill-opacity=".6"/><path d="M12 4L7 12.15l5-2.25z" fill="#fff"/><path d="M12 16v3.99l5-6.92z" fill="#fff" fill-opacity=".6"/><path d="M12 19.99V16l-5-3.07z" fill="#fff"/><path d="M12 15.07l5-2.92-5-2.24z" fill="#fff" fill-opacity=".2"/><path d="M7 12.15l5 2.92v-5.16z" fill="#fff" fill-opacity=".6"/></svg>`,
  op: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#FF0420"/><text x="12" y="15.6" font-size="8.5" font-weight="700" fill="#fff" text-anchor="middle" font-family="Helvetica,Arial,sans-serif">OP</text></svg>`,
  base: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#0052FF"/><path d="M12 6.2A5.8 5.8 0 0 0 12 17.8V6.2z" fill="#fff"/></svg>`,
  arb: `<svg viewBox="0 0 24 24" width="15" height="15"><circle cx="12" cy="12" r="12" fill="#2D374B"/><path d="M12 6l4.8 11h-2.4L12 11.2 9.6 17H7.2z" fill="#28A0F0"/><path d="M12 6l-1.05 2.45L12 11.2l1.05-2.75z" fill="#fff"/></svg>`,
};
const ORIGINS = [
  { key: "ethereum", chainId: 1, label: "ETHEREUM", name: "Ethereum", icon: "eth", environment: "production", rpcUrl: "https://eth.merkle.io", explorer: "https://etherscan.io" },
  { key: "optimism", chainId: 10, label: "OPTIMISM", name: "OP Mainnet", icon: "op", environment: "production", rpcUrl: "https://mainnet.optimism.io", explorer: "https://optimistic.etherscan.io" },
  { key: "base", chainId: 8453, label: "BASE", name: "Base", icon: "base", environment: "production", rpcUrl: "https://mainnet.base.org", explorer: "https://basescan.org" },
  { key: "arbitrum", chainId: 42_161, label: "ARBITRUM", name: "Arbitrum One", icon: "arb", environment: "production", rpcUrl: "https://arb1.arbitrum.io/rpc", explorer: "https://arbiscan.io" },
  { key: "ethereum-sepolia", chainId: 11_155_111, label: "ETH SEPOLIA", name: "Ethereum Sepolia", icon: "eth", environment: "testnet", rpcUrl: "https://sepolia.drpc.org", explorer: "https://sepolia.etherscan.io" },
  { key: "optimism-sepolia", chainId: 11_155_420, label: "OP SEPOLIA", name: "OP Sepolia", icon: "op", environment: "testnet", rpcUrl: "https://sepolia.optimism.io", explorer: "https://sepolia-optimism.etherscan.io" },
  { key: "base-sepolia", chainId: 84_532, label: "BASE SEPOLIA", name: "Base Sepolia", icon: "base", environment: "testnet", rpcUrl: "https://sepolia.base.org", explorer: "https://sepolia.basescan.org" },
  { key: "arbitrum-sepolia", chainId: 421_614, label: "ARB SEPOLIA", name: "Arbitrum Sepolia", icon: "arb", environment: "testnet", rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc", explorer: "https://sepolia.arbiscan.io" },
];
const chainById = (chainId) => ORIGINS.find((origin) => origin.chainId === Number(chainId));
const chainsForEnvironment = (environment) => ORIGINS.filter((origin) => origin.environment === environment);

function stickyDeploymentFor(chainId) {
  const origin = chainById(chainId);
  const configured = window.STICKY_CONFIG?.chains?.[String(chainId)] || {};
  const current = Number(chainId) === ctx.chainId;
  return {
    ...origin,
    ...configured,
    chainId: Number(chainId),
    rpcUrl: configured.rpcUrl || (current ? $("rpc").value : origin?.rpcUrl),
    deployer: configured.deployer || (current ? $("deployer").value : window.STICKY_CONFIG?.deployer),
    autoStickAdapter: configured.autoStickAdapter
      || (current ? autoStickAdapter() : window.STICKY_CONFIG?.autoStickAdapter),
  };
}

async function rpcAt(url, method, params) {
  if (!url) throw new Error("no RPC is configured for this chain");
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await response.json();
  if (json.error) throw new Error(json.error.message);
  return json.result;
}

const viewAt = (deployment, to, selector, args = "") =>
  rpcAt(deployment.rpcUrl, "eth_call", [{ to, data: selector + args }, "latest"]);

async function loadStickyRuntime(chainId) {
  const deployment = stickyDeploymentFor(chainId);
  const chain = chainById(chainId);
  if (!chain || !deployment.rpcUrl) throw new Error(`no RPC is configured for chain ${chainId}`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(deployment.deployer || "")) {
    throw new Error(`no JBSticky deployer is configured for ${chain.name}`);
  }
  const actualChainId = Number(BigInt(await rpcAt(deployment.rpcUrl, "eth_chainId", [])));
  if (actualChainId !== Number(chainId)) {
    throw new Error(`${chain.name}'s configured RPC returned chain ${actualChainId}`);
  }
  const deployerCode = await rpcAt(deployment.rpcUrl, "eth_getCode", [deployment.deployer, "latest"]);
  if (!deployerCode || deployerCode === "0x") {
    throw new Error(`JBSticky is not deployed at ${deployment.deployer} on ${chain.name}`);
  }
  const controller = decAddress(await viewAt(deployment, deployment.deployer, SEL.CONTROLLER));
  const projects = decAddress(await viewAt(deployment, controller, SEL.PROJECTS));
  const fee = decUint(await viewAt(deployment, projects, SEL.creationFee));
  const adapter = deployment.autoStickAdapter;
  if (adapter) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(adapter)) {
      throw new Error(`the auto-stick adapter configured for ${chain.name} is invalid`);
    }
    const adapterCode = await rpcAt(deployment.rpcUrl, "eth_getCode", [adapter, "latest"]);
    if (!adapterCode || adapterCode === "0x") {
      throw new Error(`the auto-stick adapter is not deployed at ${adapter} on ${chain.name}`);
    }
  }
  return { ...chain, ...deployment, controller, projects, fee, autoStickAdapter: adapter || "" };
}

let createEnvironment = "production";
let createChainIds = new Set(chainsForEnvironment(createEnvironment).map((chain) => chain.chainId));

function renderCreateChains() {
  const chains = chainsForEnvironment(createEnvironment);
  $("d-environment").value = createEnvironment;
  $("d-chains").innerHTML = chains.map((chain) =>
    `<label class="chain-option"><input type="checkbox" data-create-chain="${chain.chainId}"`
      + `${createChainIds.has(chain.chainId) ? " checked" : ""}>`
      + `<span class="chain-option-icon" aria-hidden="true">${CHAIN_ICON_SVG[chain.icon]}</span>`
      + `<span>${esc(chain.name)}</span></label>`,
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
  createChainIds = new Set(chainsForEnvironment(environment).map((chain) => chain.chainId));
  renderCreateChains();
  resolveLockToken().catch(() => {});
}
let originKey = null;

const originLabel = (origin) =>
  origin.chainId === ctx.chainId ? `${origin.label} <span class="mut">— THIS CHAIN</span>` : origin.label;

function renderOriginPills() {
  const selected = ORIGINS.find((origin) => origin.key === originKey)
    ?? ORIGINS.find((origin) => origin.chainId === ctx.chainId) ?? ORIGINS[0];
  originKey = selected.key;
  $("r-origin-btn").innerHTML = `${CHAIN_ICON_SVG[selected.icon]}${selected.label}`;
  $("r-origin-menu").innerHTML = ORIGINS.map((origin) =>
    `<div class="dd-item${origin.key === originKey ? " on" : ""}" onclick="setOrigin('${origin.key}')">` +
    `${CHAIN_ICON_SVG[origin.icon]}${originLabel(origin)}</div>`,
  ).join("");
  const here = selected.chainId === ctx.chainId;
  $("fund-direct").classList.toggle("hide", !here);
  $("fund-bridge").classList.toggle("hide", here);
  $("r-token-wrap").classList.toggle("hide", !here);
  $("r-amount-wrap").classList.toggle("hide", !here);
};

window.setOrigin = (key) => {
  originKey = key;
  renderOriginPills();
  $("r-origin-menu").classList.add("hide");
};

const distributor = () => window.STICKY_CONFIG?.distributor;
const autoStickAdapter = () => window.STICKY_CONFIG?.autoStickAdapter;
const rewardTokens = {}; // projectId -> Set of reward token addresses

async function rewardTokenMeta(addr) {
  const [symbol, decimals] = await Promise.all([
    view(addr, SEL.symbol).then(decString).catch(() => shortAddr(addr)),
    view(addr, SEL.decimals).then((h) => Number(decUint(h))).catch(() => 18),
  ]);
  return { symbol, decimals };
}

async function renderRewards() {
  if (ctx.currentId === null || !distributor()) return;
  const info = await projectInfo(ctx.currentId);
  const key = ctx.currentId.toString();
  const known = (rewardTokens[key] ??= new Set([info.stakedToken.toLowerCase()]));
  // Discover reward tokens from ERC-20 transfers into the distributor.
  try {
    const logs = await rpc("eth_getLogs", [
      { topics: [TOPIC.Transfer, null, "0x" + encAddress(distributor())], fromBlock: fromBlock(), toBlock: "latest" },
    ]);
    for (const log of logs) known.add(log.address.toLowerCase());
  } catch {}
  // Cross-chain pocket: predicted address + unsettled staked-token balance.
  const pocketsAddr = window.STICKY_CONFIG?.pockets;
  if (pocketsAddr) {
    try {
      const pocket = decAddress(await view(pocketsAddr, SEL.predictPocketOf, encAddress(info.stToken)));
      ctx.pocket = pocket;
      $("pocket-addr").textContent = pocket;
      const pending = decUint(await view(info.stakedToken, SEL.balanceOf, encAddress(pocket)));
      $("pocket-pending").textContent = `${formatUnits(pending, info.decimals)} ${info.symbol}`;
    } catch {}
  }
  // The direct split route: the distributor is itself a split hook, and the split's beneficiary field names the
  // sticky token whose stickers the funds reward.
  $("rr-hook").textContent = distributor();
  $("rr-beneficiary").textContent = info.stToken;
  await renderAutoStick();
  const tbody = $("rewards-list");
  tbody.innerHTML = "";
  for (const tokenAddr of known) {
    const meta = await rewardTokenMeta(tokenAddr);
    const [pool, collectable] = await Promise.all([
      view(distributor(), SEL.distBalanceOf, encAddress(info.stToken) + encAddress(tokenAddr)).then(decUint),
      view(distributor(), SEL.collectableFor, encAddress(info.stToken) + encAddress(account()) + encAddress(tokenAddr)).then(decUint).catch(() => 0n),
    ]);
    if (pool === 0n && collectable === 0n && tokenAddr !== info.stakedToken.toLowerCase()) continue;
    // The underlying-token row defaults to one-click claim-and-stick wherever the hook accepts the adapter as
    // payer (creator pre-approval or personal trust); every other reward token keeps normal claiming.
    let action = `<button class="ghost" style="margin:0;padding:4px 10px" onclick="claimRewardFor('${tokenAddr}')">Claim</button>`;
    const as = ctx.autoStick;
    const canStick = as && (as.projectGranter || as.personallyTrusted);
    if (tokenAddr === info.stakedToken.toLowerCase() && canStick && collectable > 0n) {
      action = `<button style="margin:0;padding:4px 10px" onclick="claimAndStickNow()">Claim &amp; stick</button>`
        + `<div style="margin-top:2px"><span class="link" style="font-size:12px" onclick="claimRewardFor('${tokenAddr}')">Claim only</span></div>`;
    }
    const row = document.createElement("tr");
    row.innerHTML = `<td>${esc(meta.symbol)}</td><td>${formatUnits(pool, meta.decimals)}</td>` +
      `<td>${formatUnits(collectable, meta.decimals)}</td>` +
      `<td style="min-width:80px">${action}</td>`;
    tbody.appendChild(row);
  }
  if (!tbody.children.length) tbody.innerHTML = `<tr><td colspan="4" class="mut">no rewards yet — fund some</td></tr>`;
}

async function fundRewards() {
  const info = await projectInfo(ctx.currentId);
  const tokenAddr = $("r-token").value || info.stakedToken;
  const meta = await rewardTokenMeta(tokenAddr);
  const amount = parseUnits($("r-amount").value, meta.decimals);
  const pretty = `${formatUnits(amount, meta.decimals)} ${meta.symbol}`;
  const txs = [];
  const allowance = decUint(await view(tokenAddr, SEL.allowance, encAddress(account()) + encAddress(distributor())));
  if (allowance < amount) {
    txs.push({
      label: "Approve",
      to: tokenAddr,
      fn: "approve(address spender, uint256 amount)",
      args: [["SPENDER", `${distributor()} — JBTokenDistributor`], ["AMOUNT", pretty]],
      data: SEL.approve + encode(["address", "uint256"], [distributor(), amount]),
    });
  }
  txs.push({
    label: "Fund stuck holders",
    to: distributor(),
    fn: "fund(address hook, address token, uint256 amount)",
    args: [
      ["STUCK IN", `${info.stToken} — ${stickyLabel(info)}`],
      ["REWARD", pretty],
      ["SPLIT", "pro-rata to locked balances at this round's snapshot"],
    ],
    data: SEL.fund + encode(["address", "address", "uint256"], [info.stToken, tokenAddr, amount]),
  });
  if (!(await confirmAndRun(`Fund stuck holders — ${pretty}`, txs, [["Send", pretty], ["To", "everyone currently stuck, pro-rata"]]))) return;
  try { $("fund-dialog").close(); } catch {}
  txStatus("Sticks funded", "ok");
  await renderRewards();
}

async function claimReward(tokenAddr) {
  const info = await projectInfo(ctx.currentId);
  const meta = await rewardTokenMeta(tokenAddr);
  const me = word(BigInt(account()));
  const candidates = [
    {
      label: "Start unlocking",
      to: distributor(),
      fn: "beginVesting(address hook, uint256[] tokenIds, address[] tokens)",
      args: [["HOLDER", account()], ["REWARD TOKEN", `${tokenAddr} — ${meta.symbol}`]],
      data: SEL.beginVesting + encode(["address", "uint256[]", "address[]"], [info.stToken, [BigInt(account())], [tokenAddr]]),
    },
    {
      label: "Collect unlocked rewards",
      to: distributor(),
      fn: "collectVestedRewards(address hook, uint256[] tokenIds, address[] tokens, address beneficiary)",
      args: [["HOLDER", account()], ["REWARD TOKEN", `${tokenAddr} — ${meta.symbol}`], ["BENEFICIARY", account()]],
      data: SEL.collectVestedRewards
        + encode(["address", "uint256[]", "address[]", "address"], [info.stToken, [BigInt(account())], [tokenAddr], account()]),
    },
  ];
  // Only propose steps that would actually succeed (e.g. skip re-beginning already-vesting rounds).
  const txs = [];
  for (const tx of candidates) {
    try {
      await call(tx.to, tx.data);
      txs.push(tx);
    } catch {}
  }
  if (!txs.length) throw new Error("nothing to claim yet — rewards unlock after the round ends");
  if (!(await confirmAndRun(`Claim ${meta.symbol} rewards`, txs))) return;
  txStatus("Rewards claimed", "ok");
  await renderRewards();
}
window.claimRewardFor = (tokenAddr) => guard(() => claimReward(tokenAddr))({ currentTarget: document.activeElement });

// ---------------------------------------------------------------- auto-stick
// Opt-in compounding: unlocked underlying-token rewards are collected and restuck for the same holder by the
// immutable JBStickyAutoStick adapter. Permission truth always comes from chain reads, never from events.
const AS_STATUS = {
  READY: 0, DISABLED: 1, INVALID_PROJECT: 2, COOLDOWN: 3, BELOW_MINIMUM: 4, NOT_TRUSTED: 5,
  INSUFFICIENT_ALLOWANCE: 6,
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
  return `Rewards unlock gradually — about ${Math.round(100 / sched.rounds)}% every ${formatDuration(sched.roundDuration)}, `
    + `fully unlocked ${formatDuration(sched.total)} after unlocking starts.`;
}
let asCooldownChoice = 604_800;
let asAllowanceChoice = "unlimited";
let asDialogMode = "enable";

async function autoStickState() {
  if (ctx.currentId === null || !autoStickAdapter() || !account()) return null;
  const info = await projectInfo(ctx.currentId);
  const args = word(ctx.currentId) + encAddress(account());
  const [statusHex, configHex, granterHex, trustedHex] = await Promise.all([
    view(autoStickAdapter(), SEL.asStatusOf, args),
    view(autoStickAdapter(), SEL.asConfigOf, args),
    view(ctx.hook, SEL.isGranterOf, word(ctx.currentId) + encAddress(autoStickAdapter())),
    view(ctx.hook, SEL.isTrustedSenderOf, word(ctx.currentId) + encAddress(account()) + encAddress(autoStickAdapter())),
  ]);
  return {
    info,
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
    default:
      return "";
  }
}

async function renderAutoStick() {
  const card = $("autostick-card");
  let state = null;
  try {
    state = await autoStickState();
  } catch {}
  ctx.autoStick = state;
  // Fail closed: no adapter configured (or a misconfigured project) means no auto-stick UI at all.
  if (!state || state.status === AS_STATUS.INVALID_PROJECT) {
    card.classList.add("hide");
    if (state) status("auto-stick is misconfigured for this project", "err");
    return;
  }
  const { info } = state;
  card.classList.remove("hide");
  $("as-heading").textContent = `Auto-stick ${info.symbol} rewards`;
  const schedule = unlockScheduleSentence(await unlockScheduleOf());
  $("as-blurb").textContent =
    `Automatically collect your unlocked ${info.symbol} rewards and add them to your ${stickyLabel(info)} position. `
    + `Each auto-stick creates a new stick starting at that time.`
    + (schedule ? ` ${schedule}` : "");
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

  // Offer keeper-style vesting kickoff only when it would actually succeed.
  let canBeginVesting = false;
  if (state.enabled) {
    try {
      await call(autoStickAdapter(), SEL.asBeginVestingFor + word(ctx.currentId) + encAddress(account()));
      canBeginVesting = true;
    } catch {}
  }
  $("as-begin-vesting").classList.toggle("hide", !canBeginVesting);
}

// The auto-stick transaction plan pieces, shared by enable, disable, settings, and repair flows.
function asApproveTx(info, amount) {
  const pretty = amount === UNLIMITED ? "unlimited" : `${formatUnits(amount, info.decimals)} ${info.symbol}`;
  return {
    label: `Allow the auto-stick contract to move eligible ${info.symbol} rewards`,
    to: info.stakedToken,
    fn: "approve(address spender, uint256 amount)",
    args: [
      ["SPENDER", `${autoStickAdapter()} — JBStickyAutoStick`],
      ["ALLOWANCE", pretty],
      ["SCOPE", "only rewards it just delivered to you, only to stick them for you"],
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
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["SENDER", `${autoStickAdapter()} — JBStickyAutoStick`],
      ["TRUSTED", trusted ? "yes — it can add stakes to your position" : "no"],
    ],
    data: SEL.setTrustedSenderFor + word(ctx.currentId) + encAddress(autoStickAdapter()) + word(trusted ? 1 : 0),
  };
}

function asConfigTx(info, enabled, minimum, cooldown) {
  return {
    label: enabled
      ? `Auto-stick unlocked ${info.symbol} rewards when at least ${formatUnits(minimum, info.decimals)} `
        + `${info.symbol} is ready, no more than once every ${formatDuration(cooldown)}`
      : "Turn off auto-stick",
    to: autoStickAdapter(),
    fn: "setConfigFor(uint256 projectId, bool enabled, uint128 minimumAmount, uint48 cooldown)",
    args: [
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["ENABLED", enabled ? "yes" : "no"],
      ["MINIMUM", `${formatUnits(minimum, info.decimals)} ${info.symbol}`],
      ["COOLDOWN", formatDuration(cooldown)],
      ["EFFECT", enabled
        ? "rewards can only be added to your sticky position — never sent elsewhere or taken by the keeper"
        : "future rewards stay claimable normally"],
    ],
    data: SEL.asSetConfigFor + word(ctx.currentId) + word(enabled ? 1 : 0) + word(minimum) + word(cooldown),
  };
}

function asDisableTxs(info, state) {
  return [
    asConfigTx(info, false, state.minimum, BigInt(state.cooldown)),
    // On creator-pre-approved projects there may be no per-holder trust to revoke.
    ...(state.personallyTrusted ? [asTrustTx(info, false)] : []),
    {
      ...asApproveTx(info, 0n),
      label: `Remove the auto-stick contract's ${info.symbol} allowance`,
    },
  ];
}

function openAutoStickDialog(mode) {
  const state = ctx.autoStick;
  if (!state) return;
  const { info } = state;
  asDialogMode = mode;
  $("as-dialog-title").textContent = mode === "settings" ? "Auto-stick settings" : "Turn on auto-stick";
  const dialogSchedule = unlockScheduleSentence(asUnlockSchedule || null);
  $("as-dialog-blurb").textContent =
    `Unlocked ${info.symbol} rewards are collected and stuck for you automatically once they clear your minimum. `
    + `Each auto-stick creates a new stick starting at that time.`
    + (dialogSchedule ? ` ${dialogSchedule}` : "");
  $("as-min-label").textContent = `MINIMUM ${info.symbol.toUpperCase()} PER AUTO-STICK`;
  $("as-min").value = state.minimum > 0n ? formatUnits(state.minimum, info.decimals) : "1";
  asCooldownChoice = state.cooldown || 604_800;
  for (const preset of document.querySelectorAll("[data-as-cooldown]")) {
    preset.classList.toggle("on", Number(preset.dataset.asCooldown) === asCooldownChoice);
  }
  // Settings changes only touch the on-chain config; the allowance is set during enable/renew.
  $("as-allowance-wrap").classList.toggle("hide", mode === "settings");
  $("as-allowance-label").textContent = `ALLOWANCE CAP (${info.symbol.toUpperCase()})`;
  $("as-save").textContent = mode === "settings" ? "Save settings" : "Turn on auto-stick";
  $("autostick-dialog").showModal();
}

async function saveAutoStick() {
  const state = ctx.autoStick;
  const { info } = state;
  const minimum = parseUnits($("as-min").value, info.decimals);
  if (minimum === 0n) throw new Error("the minimum must be more than zero");
  const cooldown = BigInt(asCooldownChoice);
  const txs = [];
  if (asDialogMode === "settings") {
    txs.push(asConfigTx(info, true, minimum, cooldown));
  } else {
    const allowance = asAllowanceChoice === "unlimited"
      ? UNLIMITED
      : parseUnits($("as-allowance").value || "0", info.decimals);
    if (allowance === 0n) throw new Error("set an allowance cap, or choose unlimited");
    txs.push(asApproveTx(info, allowance));
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
    ["Auto-stick when", `at least ${formatUnits(minimum, info.decimals)} ${info.symbol} is ready`],
    ["At most", `once every ${formatDuration(Number(cooldown))}`],
  ];
  if (!(await confirmAndRun(title, txs, summary))) return;
  try { $("autostick-dialog").close(); } catch {}
  txStatus(asDialogMode === "settings" ? "Auto-stick settings saved" : "Auto-stick is on", "ok");
  await renderRewards();
}

async function toggleAutoStick() {
  const state = ctx.autoStick;
  if (!state) return;
  if (!state.enabled) return openAutoStickDialog("enable");
  const { info } = state;
  const txs = asDisableTxs(info, state);
  if (!(await confirmAndRun(`Turn off auto-stick for ${stickyLabel(info)}`, txs))) return;
  txStatus("Auto-stick is off", "ok");
  await renderRewards();
}

async function repairAutoStick() {
  const state = ctx.autoStick;
  if (!state) return;
  if (state.status === AS_STATUS.INSUFFICIENT_ALLOWANCE) return openAutoStickDialog("enable");
  const { info } = state;
  const txs = [asTrustTx(info, true)];
  if (!(await confirmAndRun(`Repair auto-stick for ${stickyLabel(info)}`, txs))) return;
  txStatus("Auto-stick permission restored", "ok");
  await renderRewards();
}

async function autoStickNow() {
  const state = ctx.autoStick;
  if (!state) return;
  const { info } = state;
  const txs = [{
    label: "Stick ready rewards now",
    to: autoStickAdapter(),
    fn: "compoundFor(uint256 projectId, address holder)",
    args: [
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["HOLDER", account()],
      ["READY", `${formatUnits(state.collectable, info.decimals)} ${info.symbol}`],
      ["EFFECT", `collects your unlocked ${info.symbol} rewards and sticks them for you in a new tranche`],
    ],
    data: SEL.asCompoundFor + word(ctx.currentId) + encAddress(account()),
  }];
  if (!(await confirmAndRun(`Stick ready ${info.symbol} rewards`, txs, [["Stick", `${formatUnits(state.collectable, info.decimals)} ${info.symbol} of unlocked rewards`]]))) return;
  txStatus("Rewards auto-stuck", "ok");
  await renderProject(ctx.currentId);
}

async function beginAutoStickVesting() {
  const state = ctx.autoStick;
  if (!state) return;
  const { info } = state;
  const txs = [{
    label: "Start unlocking",
    to: autoStickAdapter(),
    fn: "beginVestingFor(uint256 projectId, address holder)",
    args: [
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["HOLDER", account()],
      ["EFFECT", `starts the unlock schedule for your ${info.symbol} rewards — no tokens move`],
    ],
    data: SEL.asBeginVestingFor + word(ctx.currentId) + encAddress(account()),
  }];
  if (!(await confirmAndRun(`Start unlocking ${info.symbol} rewards`, txs))) return;
  txStatus("Unlocking started", "ok");
  await renderRewards();
}
window.stickNowFor = () => guard(autoStickNow)({ currentTarget: document.activeElement });

// One-click claim: the holder's own call claims their vested rewards and sticks them atomically. No settings,
// no cooldown — an exact-amount approve is bundled only when the current allowance doesn't cover the claim.
async function claimAndStick() {
  const state = ctx.autoStick;
  if (!state) return;
  const { info } = state;
  const collectable = decUint(await view(
    distributor(),
    SEL.collectableFor,
    encAddress(info.stToken) + encAddress(account()) + encAddress(info.stakedToken),
  ));
  if (collectable === 0n) throw new Error("nothing claimable yet — rewards unlock after the round ends");
  const pretty = `${formatUnits(collectable, info.decimals)} ${info.symbol}`;
  const txs = [];
  const allowance = decUint(await view(
    info.stakedToken, SEL.allowance, encAddress(account()) + encAddress(autoStickAdapter()),
  ));
  if (allowance < collectable) {
    txs.push({
      ...asApproveTx(info, collectable),
      label: `Allow the auto-stick contract to move this claim of ${pretty}`,
    });
  }
  txs.push({
    label: "Claim & stick",
    to: autoStickAdapter(),
    fn: "stickRewardsFor(uint256 projectId)",
    args: [
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["CLAIM", pretty],
      ["EFFECT", `your unlocked ${info.symbol} rewards stick for you in a new tranche, in the same transaction`],
    ],
    data: SEL.asStickRewardsFor + word(ctx.currentId),
  });
  if (!(await confirmAndRun(`Claim & stick ${pretty}`, txs, [["Claim", pretty], ["It becomes", `${formatUnits(collectable, info.decimals)} ${info.stSymbol}, sticking now`]]))) return;
  txStatus("Rewards claimed and stuck", "ok");
  await renderProject(ctx.currentId);
}
window.claimAndStickNow = () => guard(claimAndStick)({ currentTarget: document.activeElement });

async function settleArrivals() {
  const info = await projectInfo(ctx.currentId);
  const pocketsAddr = window.STICKY_CONFIG?.pockets;
  const txs = [{
    label: "Settle arrivals",
    to: pocketsAddr,
    fn: "settleFor(address stickyToken, address token)",
    args: [
      ["STUCK IN", `${info.stToken} — ${stickyLabel(info)}`],
      ["REWARD TOKEN", `${info.stakedToken} — ${info.symbol}`],
      ["POCKET", ctx.pocket ?? "predicted"],
      ["EFFECT", "the pocket's whole balance becomes this round's rewards"],
    ],
    data: SEL.settleFor + encode(["address", "address"], [info.stToken, info.stakedToken]),
  }];
  if (!(await confirmAndRun("Settle cross-chain arrivals", txs))) return;
  try { $("fund-dialog").close(); } catch {}
  txStatus("Arrivals settled into rewards", "ok");
  await renderRewards();
}

// ------------------------------------------------------------------- actions
async function stake() {
  const info = await projectInfo(ctx.currentId);
  const amount = parseUnits($("stake-amount").value, info.decimals);
  const pretty = `${formatUnits(amount, info.decimals)} ${info.symbol}`;
  const txs = [];
  const allowance =
    decUint(await view(info.stakedToken, SEL.allowance, encAddress(account()) + encAddress(ctx.terminal)));
  if (allowance < amount) {
    txs.push({
      label: "Approve",
      to: info.stakedToken,
      fn: "approve(address spender, uint256 amount)",
      args: [["SPENDER", `${ctx.terminal} — JBMultiTerminal`], ["AMOUNT", pretty]],
      data: SEL.approve + encode(["address", "uint256"], [ctx.terminal, amount]),
    });
  }
  txs.push({
    label: "Stick",
    to: ctx.terminal,
    fn: "pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)",
    args: [
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["TOKEN", `${info.stakedToken} — ${info.symbol}`],
      ["AMOUNT", pretty],
      ["BENEFICIARY", account()],
    ],
    data: SEL.pay
      + encode(
        ["uint256", "address", "uint256", "address", "uint256", "string", "bytes"],
        [ctx.currentId, info.stakedToken, amount, account(), 0n, "", "0x"],
      ),
  });
  const mintPool = await poolBacking(ctx.currentId, info).catch(() => null);
  const receipt = mintPool && mintPool.reward > 0n
    ? `≈ ${parseFloat(Number(formatUnits(stickMintOf(mintPool, amount), 18)).toFixed(4))} ${info.stSymbol} — ${pretty} worth of the pool, at today's backing`
    : `${formatUnits(amount, info.decimals)} ${info.stSymbol}`;
  if (!(await confirmAndRun(`Stick — ${pretty}`, txs, [["Stick", pretty], ["You get", receipt]]))) return;
  txStatus("Stick confirmed", "ok");
  await renderProject(ctx.currentId);
}

const MAX_TAX = 10000n;
const PROTOCOL_FEE = 25n; // out of 1000; charged on reclaims whenever the bonus is nonzero
// The cash-out curve: what unsticking `count` reclaims right now, before the protocol fee.
// A lone unstick pays the full bonus; bigger group exits pay proportionally less; a
// full-supply exit takes the whole pool.
function curveReclaim(pool, count) {
  if (count === 0n || pool.supply === 0n) return 0n;
  if (count >= pool.supply) return pool.sigma;
  const base = (pool.sigma * count) / pool.supply;
  return (base * ((MAX_TAX - pool.reward) + (pool.reward * count) / pool.supply)) / MAX_TAX;
}
const afterFee = (gross, reward) => (reward > 0n ? gross - (gross * PROTOCOL_FEE) / 1000n : gross);
async function poolBacking(projectId, info) {
  const args = encAddress(ctx.terminal) + word(projectId) + encAddress(info.stakedToken);
  const [sigma, supply] = await Promise.all([
    view(ctx.store, SEL.storeBalanceOf, args).then(decUint),
    view(info.stToken, SEL.totalSupply).then(decUint),
  ]);
  return {
    sigma, supply, reward: info.reward, decimals: info.decimals, symbol: info.symbol, stSymbol: info.stSymbol,
  };
}

// Sticks mint at the current backing, so 1 token in = exactly 1 token's worth of the pool —
// fewer sticky tokens per token as the bonus grows.
function stickMintOf(pool, amount) {
  return pool.supply > 0n && pool.sigma > 0n
    ? (amount * pool.supply) / pool.sigma
    : amount * 10n ** BigInt(18 - pool.decimals);
}

function renderStickQuote() {
  const el = $("stake-quote");
  const pool = ctx.pool;
  if (!el) return;
  el.textContent = "";
  if (!pool) return;
  const field = $("stake-amount");
  let amount = 0n;
  try { amount = parseUnits(field.value || field.placeholder || "0", pool.decimals); } catch {}
  if (amount <= 0n) return;
  if (pool.reward === 0n) {
    el.textContent = `Get ${formatUnits(amount, pool.decimals)} ${pool.symbol} back anytime.`;
    return;
  }
  const r = Number(pool.reward) / 10000;
  const back = parseFloat((Number(formatUnits(amount, pool.decimals)) * (1 - r) * 0.975).toFixed(4));
  el.textContent = `If you change your mind you can get ${back} ${pool.symbol} back right away, and more as you stick around.`;
}

function renderUnstickQuote() {
  const el = $("unstake-quote");
  const pool = ctx.pool;
  if (!el) return;
  el.textContent = "";
  if (!pool || pool.supply === 0n) return;
  let count;
  try { count = parseUnits($("unstake-amount").value || "0", 18); } catch { return; }
  if (count <= 0n) return;
  if (count > pool.supply) count = pool.supply;
  const gross = curveReclaim(pool, count);
  const net = afterFee(gross, pool.reward);
  const amt = (v) => `${formatUnits(v, pool.decimals)} ${pool.symbol}`;
  if (count >= pool.supply) {
    el.textContent = pool.reward > 0n
      ? `full exit — the last one out takes the whole pool: ≈ ${amt(net)} after the 2.5% protocol fee`
      : `full exit — the last one out takes the whole pool: ${amt(gross)}`;
    return;
  }
  if (pool.reward === 0n) {
    const par = pool.sigma * 10n ** 18n === pool.supply * 10n ** BigInt(pool.decimals);
    el.textContent = `you get ${amt(gross)}${par ? " — one for one" : " — your share of the backing"}`;
    return;
  }
  const bonus = (pool.sigma * count) / pool.supply - gross;
  el.textContent = `you get ≈ ${amt(net)} · ${amt(bonus)} stays with stickers · ${amt(gross - net)} protocol fee`;
}

async function unstake() {
  const info = await projectInfo(ctx.currentId);
  // Cash out counts are in the staked copy's 18 decimals regardless of the staked token's decimals.
  const count = parseUnits($("unstake-amount").value, 18);
  const pretty = `${formatUnits(count, 18)} ${info.symbol}`;
  // Quote against fresh pool state so the reviewed numbers match what the chain will do.
  const quote = await poolBacking(ctx.currentId, info).then((pool) => {
    if (pool.supply === 0n) return null;
    const gross = curveReclaim(pool, count);
    const net = afterFee(gross, pool.reward);
    return { gross, net, bonus: (pool.sigma * (count > pool.supply ? pool.supply : count)) / pool.supply - gross, full: count >= pool.supply };
  }).catch(() => null);
  const txs = [];
  // A full exit with auto-stick still on could be reopened by a later reward compound. Disable it first, in the
  // same reviewed plan, before the unstick lands.
  if (ctx.autoStick?.enabled) {
    const staked = decUint(await view(ctx.hook, SEL.stakedBalanceOf, word(ctx.currentId) + encAddress(account())));
    if (count >= staked) txs.push(...asDisableTxs(info, ctx.autoStick));
  }
  txs.push({
    label: "Unstick",
    to: ctx.terminal,
    fn: "cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address beneficiary, bytes metadata)",
    args: [
      ["HOLDER", account()],
      ["PROJECT", `${ctx.currentId} — ${stickyLabel(info)}`],
      ["UNWIND", pretty],
      ["RECLAIM AS", `${info.stakedToken} — ${info.symbol}`],
      ["BENEFICIARY", account()],
      ...(info.reward > 0n && quote
        ? [["STICKINESS REWARD", `≈ ${formatUnits(quote.bonus, info.decimals)} ${info.symbol} stays with remaining holders (${pct(info.reward)} bonus, discounted for group exits)`]]
        : []),
    ],
    data: SEL.cashOutTokensOf
      + encode(
        ["address", "uint256", "uint256", "address", "uint256", "address", "bytes"],
        [account(), ctx.currentId, count, info.stakedToken, 0n, account(), "0x"],
      ),
  });
  const receipt = quote
    ? quote.full
      ? `≈ ${formatUnits(quote.net, info.decimals)} ${info.symbol} — full exit takes the whole pool${info.reward > 0n ? " (2.5% protocol fee applies)" : ""}`
      : info.reward > 0n
        ? `≈ ${formatUnits(quote.net, info.decimals)} ${info.symbol} after the stickiness bonus + 2.5% protocol fee`
        : `${formatUnits(quote.gross, info.decimals)} ${info.symbol} — your share of the backing`
    : info.reward > 0n
      ? `${info.symbol} on the bonus curve — up to ${pct(info.reward)} stays behind`
      : `${formatUnits(count, 18)} ${info.symbol}, one for one`;
  if (!(await confirmAndRun(`Unstick — ${pretty}`, txs, [["Unstick", pretty], ["You get back", receipt]]))) return;
  try { $("unstick-dialog").close(); } catch {}
  txStatus("Unstick confirmed", "ok");
  await renderProject(ctx.currentId);
}

async function deployStreaks() {
  const token = dTokenResolved ?? $("d-token").value.trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(token)) throw new Error("enter a token address or a Juicebox project id");
  const rewardPercent = $("d-add-reward").checked ? effectiveRewardPct() : 0;
  if (!Number.isFinite(rewardPercent) || rewardPercent < 0 || rewardPercent > 100) {
    throw new Error("stickiness bonus must be between 0% and 100%");
  }
  const reward = BigInt(Math.round(rewardPercent * 100));
  const soulbound = $("d-soulbound").value === "1";
  // Launch-time trusted senders (Extras). The auto-stick adapter is appended below regardless.
  const humanGranters = $("d-add-granters").checked
    ? ($("d-granters").value || "").split(",").map((value) => value.trim()).filter(Boolean)
    : [];
  for (const granter of humanGranters) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(granter)) throw new Error(`bad airdrop sender: ${granter}`);
  }

  const selectedChains = chainsForEnvironment(createEnvironment)
    .filter((chain) => createChainIds.has(chain.chainId));
  if (!selectedChains.length) {
    renderCreateChains();
    throw new Error("choose at least one chain");
  }
  if (!walletAccount && selectedChains.some((chain) => chain.chainId !== ctx.chainId)) {
    throw new Error("connect a wallet to deploy on more than the connected chain");
  }

  status(`checking ${selectedChains.length} ${selectedChains.length === 1 ? "chain" : "chains"}…`);
  const targets = await Promise.all(selectedChains.map(async (chain) => {
    try {
      const runtime = await loadStickyRuntime(chain.chainId);
      const [tokenSymbol, tokenName, tokenDecimals] = await Promise.all([
        viewAt(runtime, token, SEL.symbol).then(decString),
        viewAt(runtime, token, SEL.name).then(decString),
        viewAt(runtime, token, SEL.decimals).then((value) => Number(decUint(value))),
      ]);
      return { ...runtime, tokenSymbol, tokenName, tokenDecimals };
    } catch (error) {
      throw new Error(`${chain.name}: ${error.message}`);
    }
  }));
  const [{ tokenSymbol, tokenName, tokenDecimals }] = targets;
  for (const target of targets.slice(1)) {
    if (target.tokenSymbol !== tokenSymbol || target.tokenName !== tokenName || target.tokenDecimals !== tokenDecimals) {
      throw new Error(`${target.name}: ${token} does not match the token deployed on ${targets[0].name}`);
    }
  }

  const useCustom = $("d-custom-name").checked;
  const name = (useCustom && $("d-name").value.trim()) || `Sticky ${tokenName}`;
  const symbol = (useCustom && $("d-symbol").value.trim()) || `STICKY${tokenSymbol.toUpperCase()}`;
  const chainIds = targets.map((target) => target.chainId);
  const projectUri = `data:application/json;charset=utf-8,${encodeURIComponent(JSON.stringify({
    protocol: "JBSticky",
    version: 1,
    environment: createEnvironment,
    chains: chainIds,
  }))}`;
  const txs = targets.map((target) => {
    const granters = [...humanGranters];
    if (target.autoStickAdapter
      && !granters.some((granter) => granter.toLowerCase() === target.autoStickAdapter.toLowerCase())) {
      granters.push(target.autoStickAdapter);
    }
    return {
      label: `Deploy ${symbol} on ${target.name}`,
      chainId: target.chainId,
      chainLabel: target.label,
      contractName: "JBStickyDeployer",
      to: target.deployer,
      fn: "deployStickyFor(address stakedToken, string name, string symbol, string projectUri, uint256 cashOutTaxRate, address[] granters, bool soulbound)",
      args: [
        ["LOCKS", `${token} — ${tokenSymbol}`],
        ["NAME", name],
        ["SYMBOL", symbol],
        ["STICKINESS BONUS", reward > 0n ? `${pct(reward)} of every unstick stays with those still sticking` : "none"],
        ["TRUSTED SENDERS", humanGranters.length ? humanGranters.join(", ") : "none"],
        ["AUTO-STICK", target.autoStickAdapter
          ? `pre-approved through ${target.autoStickAdapter}; each holder still opts in`
          : "unavailable — no auto-stick adapter is configured"],
        ["TRANSFERS", soulbound ? "locked" : "unlocked — transfers restart the stickiness clock"],
      ],
      value: `0x${target.fee.toString(16)}`,
      valueLabel: `${formatUnits(target.fee, 18)} ETH project creation fee`,
      data: SEL.deployStickyFor
        + encode(
          ["address", "string", "string", "string", "uint256", "address[]", "bool"],
          [token, name, symbol, projectUri, reward, granters, soulbound],
        ),
    };
  });
  if (!(await confirmAndRun(`Create ${symbol}`, txs, [
    ["Create", `${name} (${symbol})`],
    ["Backed by", tokenSymbol],
    ["On", targets.map((target) => target.name).join(", ")],
  ]))) return;
  $("create-dialog").close();
  txStatus(`Sticky token deployed on ${targets.length} ${targets.length === 1 ? "chain" : "chains"}`, "ok");
  await renderHome();
}


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

function bindWalletEvents(provider) {
  if (!provider?.on) return;
  try {
    provider.on("accountsChanged", (accounts) => {
      walletAccount = accounts?.[0] ?? null;
      try { walletAccount ? localStorage.setItem(WALLET_FLAG, "1") : localStorage.removeItem(WALLET_FLAG); } catch {}
      updateConnectButton();
      route();
    });
    provider.on("chainChanged", () => updateConnectButton());
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
  walletAccount = accounts?.[0] ?? null;
  try { localStorage.setItem(WALLET_FLAG, "1"); } catch {}
}

async function walletDisconnect() {
  // Revoke so the next connect re-prompts the account picker; older wallets lack this — ignore.
  try {
    await activeProvider?.request({ method: "wallet_revokePermissions", params: [{ eth_accounts: {} }] });
  } catch {}
  walletAccount = null;
  try { localStorage.removeItem(WALLET_FLAG); localStorage.removeItem(WALLET_RDNS); } catch {}
}

// Silently restore a prior connection — eth_accounts returns authorized accounts without prompting.
async function walletEagerConnect() {
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
  document.removeEventListener("click", onWalletMenuDocClick, true);
}
function onWalletMenuDocClick(event) {
  const btn = $("connect-btn");
  if (walletMenu && event.target !== btn && !walletMenu.contains(event.target)) closeWalletMenu();
}
function newWalletMenu() {
  closeWalletMenu();
  walletMenu = document.createElement("div");
  walletMenu.className = "wallet-menu";
  const rect = $("connect-btn").getBoundingClientRect();
  walletMenu.style.top = `${rect.bottom + 6}px`;
  walletMenu.style.right = `${Math.max(8, window.innerWidth - rect.right)}px`;
  return walletMenu;
}
function mountWalletMenu() {
  document.body.appendChild(walletMenu);
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
function openWalletPicker() {
  const providers = getWalletProviders();
  const menu = newWalletMenu();
  if (!providers.length) {
    const note = document.createElement("div");
    note.className = "wallet-menu-note wallet-menu-error";
    note.textContent = "No wallet detected in this browser. Install a browser wallet.";
    menu.appendChild(note);
  }
  for (const p of providers) {
    const item = document.createElement("button");
    item.className = "wallet-menu-item wallet-pick";
    if (p.info?.icon) {
      const img = document.createElement("img");
      img.className = "wallet-pick-icon";
      img.src = p.info.icon;
      item.appendChild(img);
    }
    const name = document.createElement("span");
    name.textContent = p.info?.name || "Wallet";
    item.appendChild(name);
    item.addEventListener("click", () => {
      closeWalletMenu();
      guard(async () => {
        await walletConnect(p);
        updateConnectButton();
        route();
      })();
    });
    menu.appendChild(item);
  }
  appendViewAsItem(menu);
  mountWalletMenu();
}
function openWalletMenu() {
  const menu = newWalletMenu();
  const shown = viewAs || walletAccount;
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
    : walletAccount ? shortAddr(walletAccount) : "Connect wallet";
  btn.classList.toggle("connected", !!walletAccount && !viewAs);
  btn.classList.toggle("viewing-as", !!viewAs);
  btn.title = viewAs || walletAccount || "Connect a wallet or view as another account";
}

// ------------------------------------------------------------------- account view
async function renderAccount(address) {
  clearHomeSecuredChart();
  $("view-home").classList.add("hide");
  $("view-project").classList.add("hide");
  $("view-account").classList.remove("hide");
  $("a-logo").innerHTML = tokenBadge(address, address.slice(2, 3), 72);
  $("a-title").textContent = walletAccount && address.toLowerCase() === walletAccount.toLowerCase() ? "Your account" : "Account";
  $("a-address").textContent = address;
  if (!ctx.loaded) return;
  const ids = await projectIds();
  const logs = await hookLogs(undefined);
  const rows = [];
  for (const id of ids) {
    try {
      const info = await projectInfo(id);
      const args = word(id) + encAddress(address);
      const [staked, streakStart, longest] = await Promise.all([
        view(ctx.hook, SEL.stakedBalanceOf, args).then(decUint),
        view(ctx.hook, SEL.streakStartOf, args).then(decUint),
        view(ctx.hook, SEL.longestStreakOf, args).then(decUint),
      ]);
      if (staked === 0n && longest === 0n) continue;
      const current = streakStart === 0n ? 0 : Math.max(0, Math.floor(Date.now() / 1000) - Number(streakStart));
      rows.push(
        `<div class="card-item pickc" onclick="location.hash='#/project/${id}'"><div class="card-head">` +
        `${tokenLogo(info.stakedToken, info.symbol, 26)}<div style="flex:1;min-width:0">` +
        `<div style="font-weight:700">${esc(stickyLabel(info))} <span class="mut">#${id}</span></div>` +
        `<div class="kv"><span class="mut">Stuck:</span> ${formatUnits(staked, 18)} ${esc(info.symbol)}</div>` +
        `<div class="kv"><span class="mut">Time:</span> ${formatDuration(current)}</div>` +
        `<div class="kv"><span class="mut">Longest:</span> ${formatDuration(Math.max(Number(longest), current))}</div>` +
        `</div></div></div>`,
      );
    } catch {}
  }
  $("a-positions").innerHTML = rows.length ? rows.join("") : `<div class="card-item mut">no positions yet</div>`;
  const mine = logs.filter((log) => decAddress(log.topics[2]).toLowerCase() === address.toLowerCase());
  renderFeed($("a-activity"), await activityItems(mine, true));
  hydrateLogos().catch(() => {});
}

// -------------------------------------------------------------------- router
function route() {
  closeWalletMenu();
  try { $("create-dialog").close(); } catch {}
  try { $("connection-dialog").close(); } catch {}
  try { $("unstick-dialog").close(); } catch {}
  try { $("trust-dialog").close(); } catch {}
  try { $("fund-dialog").close(); } catch {}
  try { $("autostick-dialog").close(); } catch {}
  if (confirmResolve) settleConfirm(false);
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
    renderHome().catch((e) => status(e.message, "err"));
  }
}
window.onhashchange = route;

// ---------------------------------------------------------------------- wire
function guard(fn) {
  return (event) => {
    const anchor = event?.currentTarget || document.activeElement;
    const oldNotice = anchor?.closest?.("dialog, section, .card-item, .list-card")?.querySelector?.(".inline-status");
    oldNotice?.remove();
    return fn(event).catch((error) => {
      if (confirmProgress >= 0 || $("confirm-dialog").open) txStatus(error.message, "err");
      else inlineStatus(anchor, error.message, "err");
    });
  };
}
$("load").onclick = guard(async () => {
  await loadDeployer();
  $("connection-dialog").close();
});
$("stake").onclick = guard(stake);
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
$("r-origin-btn").onclick = (event) => {
  event.stopPropagation();
  $("r-origin-menu").classList.toggle("hide");
};
document.addEventListener("click", () => $("r-origin-menu").classList.add("hide"));
$("r-add").onclick = guard(async () => {
  const addr = $("r-check").value;
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) throw new Error("bad token address");
  (rewardTokens[ctx.currentId.toString()] ??= new Set()).add(addr.toLowerCase());
  await renderRewards();
});
const fillStakeMax = () => { if (ctx.walletMax) { $("stake-amount").value = ctx.walletMax; renderStickQuote(); } };
$("stake-balance").onclick = fillStakeMax;
$("stake-balance").onkeydown = (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    fillStakeMax();
  }
};
$("unstake-max").onclick = () => { if (ctx.stakedMax) { $("unstake-amount").value = ctx.stakedMax; renderUnstickQuote(); } };
$("unstake-amount").oninput = renderUnstickQuote;
$("stake-amount").oninput = renderStickQuote;
$("deploy").onclick = guard(deployStreaks);
// Cash out curve: y = x((1-r) + rx) — proportional at r=0, bonding-curved as the reward grows.
let rewardChoice = "10";
let lockedSymbol = "";
// The TOKEN TO LOCK field also accepts a Juicebox project id (optionally chain-prefixed, e.g. eth:5) and
// resolves it to the project's token. Whatever resolves is echoed subtly below the field.
let dTokenResolved = null;
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

async function resolveLockToken() {
  const input = $("d-token").value.trim();
  const lookup = ++dTokenLookup;
  lockedSymbol = "";
  dTokenResolved = null;
  setTokenMeta("");
  if (!input || !ctx.loaded) return;

  // A project id, optionally chain-prefixed: resolve it to the project's token on the connected chain.
  const idMatch = input.match(/^(?:([a-zA-Z-]+):)?(\d+)$/);
  let addr = input;
  let projectNote = "";
  if (idMatch) {
    const [, prefix, id] = idMatch;
    if (prefix) {
      const wanted = CHAIN_ALIASES[prefix.toLowerCase().replace(/[^a-z]/g, "")];
      if (!wanted) return setTokenMeta(`Unknown chain "${esc(prefix)}" — try eth, op, base, or arb.`, true);
      if (wanted !== ctx.chainId) {
        return setTokenMeta(`That project lives on ${esc(chainLabelOf(wanted))} — this app is connected to `
          + `${esc(chainLabelOf(ctx.chainId))}. Switch networks to lock its token.`, true);
      }
    }
    try {
      addr = decAddress(await view(ctx.tokens, SEL.tokenOf, word(BigInt(id))));
    } catch {
      addr = "0x0000000000000000000000000000000000000000";
    }
    if (lookup !== dTokenLookup) return;
    if (addr === "0x0000000000000000000000000000000000000000") {
      return setTokenMeta(`No token found for Juicebox project #${esc(id)} on ${esc(chainLabelOf(ctx.chainId))}.`, true);
    }
    projectNote = ` | using its token ${esc(shortAddr(addr))}`;
  } else if (!/^0x[0-9a-fA-F]{40}$/.test(input)) {
    return;
  }

  // Read the token, and check whether it's a Juicebox project's token for the subtle metadata line.
  let symbol = "";
  let name = "";
  try {
    [symbol, name] = await Promise.all([
      view(addr, SEL.symbol).then(decString),
      view(addr, SEL.name).then(decString).catch(() => ""),
    ]);
  } catch {
    if (lookup === dTokenLookup && idMatch) setTokenMeta(`Project #${esc(idMatch[2])}'s token is not readable.`, true);
    return; // not an ERC-20 (yet)
  }
  if (lookup !== dTokenLookup) return;
  lockedSymbol = symbol;
  dTokenResolved = addr;

  let projectId = 0n;
  try {
    projectId = decUint(await view(ctx.tokens, SEL.projectIdOf, encAddress(addr)));
  } catch {}
  if (lookup !== dTokenLookup) return;
  if (projectId > 0n) {
    const metadata = await resolveProjectMetadata(addr).catch(() => null);
    if (lookup !== dTokenLookup) return;
    const projectName = metadata?.name ? `${metadata.name} | ` : "";
    setTokenMeta(`${tokenLogo(addr, symbol)} <span>${esc(projectName)}${esc(name || symbol)} (${esc(symbol)}) | `
      + `Juicebox project #${projectId}${projectNote}</span>`);
    hydrateLogos().catch(() => {});
  } else {
    setTokenMeta(`${tokenLogo(addr, symbol)} <span>${esc(name || symbol)} (${esc(symbol)})</span>`);
    hydrateLogos().catch(() => {});
  }
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
function effectiveRewardPct() {
  return rewardChoice === "custom" ? Number($("d-reward").value || "0") : Number(rewardChoice);
}
function renderCurve() {
  const r = Math.min(1, Math.max(0, effectiveRewardPct() / 100));
  const note = $("d-curve-note");
  if (note) {
    const sym = lockedSymbol ? ` ${lockedSymbol}` : "";
    note.textContent = r > 0
      ? `Stick 100${sym}: get ${parseFloat((100 * (1 - r) * 0.975).toFixed(1))}${sym} back right away, and more as you stick around.`
      : "No bonus: unsticks return exactly what was stuck.";
  }
  $("d-fee-details")?.classList.toggle("hide", r === 0);
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
    ?? (($("d-custom-name")?.checked && $("d-symbol").value.trim()) || (sym ? `st${sym}` : ""));
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
    <div class="mut" style="font-size:13px;margin:10px 0 6px">When 100 ${esc(stSym) || "sticky tokens"} unstick…</div>
    <svg viewBox="0 0 ${W} ${BH}" style="width:100%;max-width:${W}px;border-radius:4px" preserveAspectRatio="none">
      <rect x="0" y="0" width="${wLeaver.toFixed(1)}" height="${BH}" fill="#2fb3c7"/>
      <rect x="${wLeaver.toFixed(1)}" y="0" width="${wStays.toFixed(1)}" height="${BH}" fill="#0e7c91"/>
      <rect x="${(wLeaver + wStays).toFixed(1)}" y="0" width="${(W - wLeaver - wStays).toFixed(1)}" height="${BH}" fill="#e2d7bd"/>
    </svg>
    <div style="display:flex;gap:16px;white-space:nowrap;overflow-x:auto;margin-top:6px" class="kv mut">
      <span><i style="display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;background:#2fb3c7"></i>${qty(toLeaver)}${unit} to the unstickers</span>
      <span><i style="display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;background:#0e7c91"></i>${qty(stays)} stays with stickers</span>
      <span><i style="display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;background:#e2d7bd"></i>${qty(fee)} protocol fee</span>
    </div>`;
}

const soulboundHint = () => {
  $("d-soulbound-hint").textContent = $("d-soulbound").value === "1"
    ? "The sticky token can never change hands."
    : "The sticky token can move between wallets — transferring resets the stickiness clock on the moved tokens.";
};
$("d-soulbound").onchange = soulboundHint;
$("d-custom-name").onchange = () => {
  $("d-name-row").classList.toggle("hide", !$("d-custom-name").checked);
  $("d-name-hint").classList.toggle("hide", !$("d-custom-name").checked);
};
$("d-add-reward").onchange = () => {
  $("d-reward-wrap").classList.toggle("hide", !$("d-add-reward").checked);
  $("d-reward-hint").classList.toggle("hide", !$("d-add-reward").checked);
  renderCurve();
};
$("d-reward").oninput = renderCurve;
for (const preset of document.querySelectorAll(".preset")) {
  preset.onclick = () => {
    rewardChoice = preset.dataset.v;
    for (const other of document.querySelectorAll(".preset")) other.classList.toggle("on", other === preset);
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
  for (const id of ["d-name-row", "d-name-hint", "d-reward-wrap", "d-reward-hint", "d-granters-row", "d-granters-hint"]) {
    $(id).classList.add("hide");
  }
  $("d-extras").open = false;
  rewardChoice = "10";
  for (const preset of document.querySelectorAll(".preset")) preset.classList.toggle("on", preset.dataset.v === "10");
  $("d-reward-custom-row").classList.add("hide");
  $("d-soulbound").value = "1";
  soulboundHint();
  dTokenResolved = null;
  setTokenMeta("");
  selectCreateEnvironment("production");
  $("create-dialog").showModal();
};
$("create-close").onclick = () => $("create-dialog").close();
$("cd-cancel").onclick = () => settleConfirm(false);
$("cd-confirm").onclick = () => settleConfirm(true);
$("cd-close").onclick = () => settleConfirm(false);
$("cd-audit").onclick = guard(async () => {
  await navigator.clipboard.writeText(await auditPrompt());
  inlineStatus($("cd-audit"), "Audit prompt copied — paste it into your AI.", "ok");
});
$("tx-status-close").onclick = () => txStatus("");
$("confirm-dialog").oncancel = () => settleConfirm(false);
// Clicking the backdrop (the dialog element itself, not its children) closes the dialog.
$("create-dialog").onclick = (event) => {
  if (event.target === $("create-dialog")) $("create-dialog").close();
};
$("confirm-dialog").onclick = (event) => {
  if (event.target === $("confirm-dialog")) settleConfirm(false);
};
let boardSort = "longest";
function renderBoard() {
  if (!ctx.board) return;
  const { rows, symbol, total } = ctx.board;
  const ranked = [...rows].sort((a, b) => boardSort === "largest"
    ? (b.staked > a.staked ? 1 : b.staked < a.staked ? -1 : b.current - a.current)
    : (b.current - a.current || (b.staked > a.staked ? 1 : -1)));
  $("leaderboard").innerHTML = ranked.length
    ? ranked.slice(0, 20).map((row, i) => {
        const self = row.holder.toLowerCase() === (account() || "").toLowerCase() ? " (you)" : "";
        const share = total > 0n ? Number(row.staked * 10_000n / total) / 100 : 0;
        return `<tr data-owner="${esc(row.holder.toLowerCase())}"><td>${i + 1}</td><td class="addr">${addressLabel(row.holder)}${self}</td>` +
          `<td>${share.toFixed(1)}%</td><td>${formatUnits(row.staked, 18)} ${esc(symbol)}</td>` +
          `<td>${formatDuration(row.current)}</td></tr>`;
      }).join("")
    : `<tr><td colspan="5" class="mut">nobody is stuck yet</td></tr>`;
  hydrateEns($("leaderboard")).catch(() => {});
}
$("sort-longest").onclick = () => {
  boardSort = "longest";
  $("sort-longest").classList.add("on");
  $("sort-largest").classList.remove("on");
  renderBoard();
};
$("sort-largest").onclick = () => {
  boardSort = "largest";
  $("sort-largest").classList.add("on");
  $("sort-longest").classList.remove("on");
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
    for (const other of document.querySelectorAll("[data-as-cooldown]")) other.classList.toggle("on", other === preset);
  };
}
for (const preset of document.querySelectorAll("[data-as-allowance]")) {
  preset.onclick = () => {
    asAllowanceChoice = preset.dataset.asAllowance;
    for (const other of document.querySelectorAll("[data-as-allowance]")) other.classList.toggle("on", other === preset);
    $("as-allowance-custom-row").classList.toggle("hide", asAllowanceChoice !== "custom");
  };
}
$("open-trust").onclick = () => $("trust-dialog").showModal();
$("trust-close").onclick = () => $("trust-dialog").close();
$("trust-dialog").onclick = (event) => {
  if (event.target === $("trust-dialog")) $("trust-dialog").close();
};
$("conn-toggle").onclick = () => $("connection-dialog").showModal();
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
  openWalletPicker();
});
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
  // Flatten stakes into hook logs (Staked), newest last; synthetic block numbers map to timestamps.
  const logs = [];
  const blockTs = {};
  let bn = 0x1000;
  for (const p of Object.values(projects)) {
    for (const s of p.stakes.sort((a, b) => a.ts - b.ts)) {
      const block = "0x" + (bn++).toString(16);
      blockTs[block] = s.ts;
      logs.push({
        topics: [TOPIC.Staked, "0x" + word(p.id), "0x" + encAddress(s.holder)],
        data: "0x" + encAddress(s.payer) + word(s.amount),
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
      const who = decAddress(arg(1)).toLowerCase();
      const holder = p?.holders.find((h) => h.addr.toLowerCase() === who);
      if (sel === SEL.stakedBalanceOf) return Promise.resolve(enc.uint(holder?.staked ?? 0n));
      if (sel === SEL.streakStartOf) return Promise.resolve(enc.uint(holder?.start ?? 0));
      if (sel === SEL.longestStreakOf) return Promise.resolve(enc.uint(holder?.longest ?? 0));
      if (sel === SEL.tranchesOf) return Promise.resolve(enc.tranches(p?.tranches[who] || []));
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
  guard(loadDeployer)();
} else {
  $("rpc").value = config.rpcUrl ?? "http://localhost:8545";
  if (config.deployer) $("deployer").value = config.deployer;
  if (config.account) $("account").value = config.account;
  if (config.deployer) guard(loadDeployer)();
}
setInterval(() => refreshPosition().catch(() => {}), 15_000);
