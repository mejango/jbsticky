/* Create-flow rules shared by the create dialog and its tests. No DOM, no network. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyLaunchPlan = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const ZERO = "0x" + "0".repeat(40);
  const BONUS_PRESETS = Object.freeze(["0", "5", "10", "25"]);
  const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  const isAddress = (value) => typeof value === "string" && ADDRESS.test(value) && !same(value, ZERO);

  // The contract takes basis points up to 10000, but at 100% every unstick returns nothing,
  // so the site offers 0 to 99.99%.
  function bonusBasisPoints(choice, custom) {
    const text = choice === "custom" ? String(custom ?? "").trim() : String(choice);
    if (choice !== "custom" && !BONUS_PRESETS.includes(text)) throw new Error("Choose a stickiness bonus.");
    if (!/^\d{1,2}(?:\.\d{1,2})?$/.test(text)) throw new Error("Enter a bonus from 0 to 99.99%.");
    const [whole, fraction = ""] = text.split(".");
    return BigInt(whole) * 100n + BigInt((fraction + "00").slice(0, 2));
  }

  function defaultNames(tokenName, tokenSymbol) {
    return { name: `Sticky ${tokenName}`, symbol: `STICKY${String(tokenSymbol).toUpperCase()}` };
  }

  function parseSenders(text) {
    const senders = [];
    for (const value of String(text || "").split(",").map((item) => item.trim()).filter(Boolean)) {
      if (!isAddress(value)) throw new Error(`Not an address: ${value}`);
      if (!senders.some((sender) => same(sender, value))) senders.push(value);
    }
    return senders;
  }

  // AutoStick is a granter on every launch. A chain without it cannot launch.
  function launchGranters(senders, adapter, chainName) {
    if (!isAddress(adapter)) throw new Error(`${chainName} has no auto-stick helper configured, so Sticky can't launch there.`);
    return [...senders.filter((sender) => !same(sender, adapter)), adapter];
  }

  // "0x…" is a token. "5" is project 5 on every selected chain. "base:5" is project 5 on Base.
  function parseTokenInput(input, aliases) {
    const text = String(input || "").trim();
    if (!text) return { kind: "empty" };
    if (ADDRESS.test(text)) return { kind: "address", address: text };
    const match = text.match(/^(?:([a-zA-Z-]+):)?(\d{1,20})$/);
    if (!match) return { kind: "invalid" };
    const [, prefix, id] = match;
    if (BigInt(id) === 0n) return { kind: "invalid" };
    if (!prefix) return { kind: "project", projectId: BigInt(id), chainId: null };
    const chainId = aliases[prefix.toLowerCase().replace(/[^a-z]/g, "")];
    if (!chainId) return { kind: "unknown-chain", prefix };
    return { kind: "project", projectId: BigInt(id), chainId };
  }

  // Each chain numbers its own projects. An unprefixed ID must name the same token on every
  // selected chain; a prefixed ID names the token once and the address is checked everywhere.
  async function resolveProjectToken({ projectId, chainId, targetChainIds, tokenOfAt, nameOf }) {
    const lookup = async (id) => {
      let address;
      try { address = await tokenOfAt(id, projectId); } catch { address = ZERO; }
      if (!isAddress(address)) throw new Error(`Project #${projectId} has no ERC-20 on ${nameOf(id)}.`);
      return address;
    };
    if (chainId) return { address: await lookup(chainId), chainIds: [chainId] };
    if (!targetChainIds.length) throw new Error("Choose at least one chain.");
    const found = await Promise.all(targetChainIds.map(lookup));
    for (let i = 1; i < found.length; i++) {
      if (!same(found[i], found[0])) {
        throw new Error(`Project #${projectId} has a different token on ${nameOf(targetChainIds[i])} than on ${nameOf(targetChainIds[0])}. `
          + "Enter the token address, or name the chain, like base:5.");
      }
    }
    return { address: found[0], chainIds: [...targetChainIds] };
  }

  // The same token must exist everywhere the launch goes.
  function checkSameToken(reads) {
    const [first] = reads;
    for (const read of reads.slice(1)) {
      if (read.tokenSymbol !== first.tokenSymbol || read.tokenName !== first.tokenName || read.tokenDecimals !== first.tokenDecimals) {
        throw new Error(`${read.name}: the token differs from the one on ${first.name}.`);
      }
    }
    return first;
  }

  return Object.freeze({ BONUS_PRESETS, ZERO, bonusBasisPoints, defaultNames, parseSenders, launchGranters,
    parseTokenInput, resolveProjectToken, checkSameToken, isAddress });
});
