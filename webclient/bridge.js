/* V6 sucker reward funding. The Merkle reconstruction follows nana-sdk-core/v6/suckers
 * (MIT, Bananapus); source contracts are nana-suckers-v6/src/JBSucker.sol and MerkleLib.sol.
 * Every write is returned as a reviewable request. This module never contacts a wallet. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyBridge = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const ZERO = "0x" + "0".repeat(64);
  const NATIVE = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
  const EMPTY_ROOT = "0x27ae5ba08d7291c96c8cbddcc148bf48a6d68c7974b94356f53754ef6171d757";
  const INSERT = "0xc92fa1150c24ee5470c272112539aab52450a5e05573e7ea7bdfb98829b89321";
  const CONTRACTS = Object.freeze({
    tokens: "0x1f80d8f057ee36b4c2656d107e4e4558b71ba7d9",
    directory: "0x5aff29060e023e6fb87be5596652b33c65af535b",
    suckerRegistry: "0x7903a854ae91eaf635430d120a1a434085cef297",
    terminal: "0x130f5dd2bd8805443cf41755253d778a75a67f53",
  });
  const SEL = Object.freeze({
    projectIdOf: "0x0f85421b", tokenOf: "0xea78803f", allSuckersOf: "0x49ad63cd",
    isSuckerOf: "0x83db9d01", DIRECTORY: "0x88bc2ef3", TOKENS: "0x1d831d5c",
    peer: "0x11cda415", peerChainId: "0xcdfceeba", projectId: "0x3fafa127", state: "0xc19d93fb",
    remoteTokenFor: "0x7de6fba2", accountingContextsOf: "0x515a9293",
    accountingContextForTokenOf: "0x3a01714f", primaryTerminalOf: "0x86202650",
    previewCashOutFrom: "0x4aa71dbc", feeFreeSurplusOf: "0xc66d192b",
    FEELESS_ADDRESSES: "0x659a2047", isFeelessFor: "0x8717d7c2",
    outboxOf: "0x802c8fa0", inboxOf: "0x6d9e384b", executedLeafHashOf: "0x4035d3b1",
    CCIP_ROUTER: "0xfe5f42ca", OPMESSENGER: "0xfc8fa43d", ARBINBOX: "0xb1012368", LAYER: "0xc86719b7", GATEWAYROUTER: "0xdefbb697",
    toRemoteFee: "0x42115915", toRemote: "0xb71c1179", prepare: "0xaf629bbb", claim: "0xcbb2adce",
    DISTRIBUTOR: "0x9c26149f", predictPocketOf: "0x7780193e", decimals: "0x313ce567",
    symbol: "0x95d89b41", balanceOf: "0x70a08231", allowance: "0xdd62ed3e", approve: "0x095ea7b3",
  });
  function address(value) {
    if (typeof value !== "string" || !/^0x[0-9a-f]{40}$/i.test(value) || /^0x0{40}$/.test(value)) throw new Error("A valid nonzero address is required.");
    return value.toLowerCase();
  }
  function hash(value) {
    if (typeof value !== "string" || !/^0x[0-9a-f]{64}$/i.test(value)) throw new Error("The bridge returned an invalid bytes32 value.");
    return value.toLowerCase();
  }
  function word(value) {
    const n = BigInt(value);
    if (n < 0n || n >= 1n << 256n) throw new Error("A bridge amount is out of range.");
    return n.toString(16).padStart(64, "0");
  }
  const aw = value => address(value).slice(2).padStart(64, "0");
  function words(data) {
    if (typeof data !== "string" || !/^0x(?:[0-9a-f]{64})*$/i.test(data)) throw new Error("The bridge RPC returned malformed contract data.");
    return data.slice(2).match(/.{64}/g) || [];
  }
  function uint(data, at = 0) {
    const ws = words(data);
    if (!ws[at]) throw new Error("The bridge RPC returned incomplete contract data.");
    return BigInt("0x" + ws[at]);
  }
  function addr(data, at = 0) {
    const w = words(data)[at];
    if (!w || !/^0{24}/.test(w)) throw new Error("The bridge returned a non-EVM address.");
    return address("0x" + w.slice(24));
  }
  function count(value, max = 20000) {
    const n = Number(value);
    if (!Number.isSafeInteger(n) || n < 0 || n > max) throw new Error("The bridge history exceeds the supported scan size.");
    return n;
  }
  function array(data, width) {
    const ws = words(data);
    if (uint(data) !== 32n) throw new Error("The bridge returned an invalid array offset.");
    const n = count(uint(data, 1), 256);
    if (ws.length !== 2 + n * width) throw new Error("The bridge returned an incomplete array.");
    return Array.from({ length: n }, (_, i) => "0x" + ws.slice(2 + i * width, 2 + (i + 1) * width).join(""));
  }
  function text(data) {
    const ws = words(data);
    if (uint(data) !== 32n) throw new Error("Invalid token name.");
    const size = count(uint(data, 1), 256);
    if (ws.length < 2 + Math.ceil(size / 32)) throw new Error("Incomplete token name.");
    const raw = data.slice(130, 130 + size * 2);
    return new TextDecoder().decode(Uint8Array.from(raw.match(/../g) || [], x => parseInt(x, 16)));
  }
  function minimumOutput(gross, tax, feeFree, feeless, slippageBps = 100n) {
    if (gross <= 0n || tax < 0n || tax > 10000n || feeFree < 0n || slippageBps < 0n || slippageBps > 500n) throw new Error("A nonzero live bridge quote and at most 5% slippage are required.");
    const feeable = tax > 0n ? gross : gross < feeFree ? gross : feeFree;
    const net = gross - (feeless ? 0n : feeable / 40n);
    const minimum = net * (10000n - slippageBps) / 10000n;
    if (minimum <= 0n) throw new Error("The protected bridge output rounds to zero.");
    return { net, minimum };
  }

  function create({ rpc, keccak256, logs: readLogs, inspectSafeExecution }) {
    if (typeof rpc !== "function" || typeof keccak256 !== "function") throw new Error("Bridge verification is unavailable.");
    const pairHash = (a, b) => hash(keccak256(hash(a) + hash(b).slice(2)));
    const zeros = [ZERO];
    for (let i = 0; i < 32; i++) zeros.push(pairHash(zeros[i], zeros[i]));
    if (zeros[32] !== EMPTY_ROOT) throw new Error("The bridge Merkle self-check failed.");
    const leafHash = leaf => hash(keccak256("0x" + word(leaf.projectTokenCount) + word(leaf.terminalTokenAmount) + hash(leaf.beneficiary).slice(2) + hash(leaf.metadata).slice(2)));
    function treeLevels(hashes) {
      const levels = [hashes.map(hash)];
      for (let depth = 0; depth < 32; depth++) {
        const level = levels[depth], next = [];
        for (let i = 0; i < level.length; i += 2) next.push(pairHash(level[i], level[i + 1] || zeros[depth]));
        levels.push(next);
      }
      return levels;
    }
    function proofFor(hashes, index, levels = treeLevels(hashes)) {
      if (index >= hashes.length || index < 0 || !Number.isSafeInteger(index)) throw new Error("The bridge leaf is outside the outbox.");
      let position = index;
      const proof = [];
      for (let depth = 0; depth < 32; depth++) {
        proof.push(levels[depth][position ^ 1] || zeros[depth]);
        position = Math.floor(position / 2);
      }
      return proof;
    }
    function branchRoot(leaf, proof, index) {
      if (proof.length !== 32 || !Number.isSafeInteger(index) || index < 0 || index >= 2 ** 32) throw new Error("Invalid bridge proof.");
      let current = hash(leaf), position = index;
      for (const sibling of proof) {
        current = position % 2 ? pairHash(sibling, current) : pairHash(current, sibling);
        position = Math.floor(position / 2);
      }
      return current;
    }
    const request = (runtime, method, params) => rpc(runtime.rpcUrl, method, params);
    const call = (runtime, to, name, args = "", from) => request(runtime, "eth_call", [{ to: address(to), data: SEL[name] + args, ...(from ? { from: address(from) } : {}) }, "latest"]);
    async function chain(runtime) {
      if (!Number.isSafeInteger(runtime.chainId) || Number(BigInt(await request(runtime, "eth_chainId", []))) !== runtime.chainId) throw new Error("The bridge RPC is connected to the wrong chain.");
    }
    async function code(runtime, target) {
      const value = await request(runtime, "eth_getCode", [address(target), "latest"]);
      if (typeof value !== "string" || !/^0x(?:[0-9a-f]{2})+$/i.test(value) || /^0x0*$/.test(value)) throw new Error("A required bridge contract is not deployed on this chain.");
    }
    const contracts = runtime => ({ ...CONTRACTS, ...(runtime.bridgeContracts || {}) });
    async function tokenMeta(runtime, token) {
      if (address(token) === NATIVE) return { symbol: "ETH", decimals: 18 };
      await code(runtime, token);
      const decimals = Number(uint(await call(runtime, token, "decimals")));
      if (!Number.isInteger(decimals) || decimals < 0 || decimals > 36) throw new Error("The reward token's decimals are unsupported.");
      const symbol = await call(runtime, token, "symbol").then(text).catch(() => token.slice(0, 8));
      return { symbol: symbol || token.slice(0, 8), decimals };
    }
    async function pocketFor(destination, stickyToken, pockets, distributor) {
      await chain(destination);
      await code(destination, pockets);
      if (addr(await call(destination, pockets, "DISTRIBUTOR")) !== address(distributor)) throw new Error("The destination reward pocket does not use this project's distributor.");
      return addr(await call(destination, pockets, "predictPocketOf", aw(stickyToken)));
    }
    async function validateRoute(route, { sending = false, preparing = false } = {}) {
      const { source, destination, sourceSucker, destinationSucker, sourceToken, rewardToken, sourceProjectId, destinationProjectId, backingToken, remoteBackingToken } = route;
      if (source.chainId === destination.chainId || source.environment !== destination.environment) throw new Error("A bridge route must connect different chains in the same environment.");
      const sc = contracts(source), dc = contracts(destination);
      await Promise.all([chain(source), chain(destination), code(source, sourceSucker), code(destination, destinationSucker)]);
      const checked = await Promise.all([
        call(source, sc.suckerRegistry, "isSuckerOf", word(sourceProjectId) + aw(sourceSucker)).then(uint),
        call(destination, dc.suckerRegistry, "isSuckerOf", word(destinationProjectId) + aw(destinationSucker)).then(uint),
        call(source, sourceSucker, "peer").then(addr), call(destination, destinationSucker, "peer").then(addr),
        call(source, sourceSucker, "peerChainId").then(uint), call(destination, destinationSucker, "peerChainId").then(uint),
        call(source, sourceSucker, "projectId").then(uint), call(destination, destinationSucker, "projectId").then(uint),
        call(source, sc.tokens, "tokenOf", word(sourceProjectId)).then(addr),
        call(destination, dc.tokens, "tokenOf", word(destinationProjectId)).then(addr),
        call(source, sourceSucker, "TOKENS").then(addr), call(destination, destinationSucker, "TOKENS").then(addr),
        call(source, sourceSucker, "DIRECTORY").then(addr), call(destination, destinationSucker, "DIRECTORY").then(addr),
      ]);
      const expected = [1n, 1n, address(destinationSucker), address(sourceSucker), BigInt(destination.chainId), BigInt(source.chainId), BigInt(sourceProjectId), BigInt(destinationProjectId), address(sourceToken), address(rewardToken), address(sc.tokens), address(dc.tokens), address(sc.directory), address(dc.directory)];
      if (checked.some((value, i) => value !== expected[i])) throw new Error("The bridge peer, project token, or registry does not match the selected route.");
      const mapping = await call(source, sourceSucker, "remoteTokenFor", aw(backingToken));
      if (uint(mapping, 3) !== 0n && addr(mapping, 3) !== address(remoteBackingToken)) throw new Error("The bridge source backing-token mapping changed.");
      if (preparing) {
        const reverse = await call(destination, destinationSucker, "remoteTokenFor", aw(remoteBackingToken));
        if (uint(mapping, 3) === 0n || addr(reverse, 3) !== address(backingToken)) throw new Error("The bridge backing-token mappings do not match in both directions.");
      }
      if (sending && (uint(mapping) !== 1n || uint(mapping, 1) !== 0n || uint(await call(source, sourceSucker, "state")) > 1n)) throw new Error("This bridge route no longer accepts new transfers.");
      if (preparing) {
        const primary = addr(await call(source, sc.directory, "primaryTerminalOf", word(sourceProjectId) + aw(backingToken)));
        if (primary !== address(route.terminal)) throw new Error("The source project's backing terminal changed. Find routes again.");
        const context = await call(source, primary, "accountingContextForTokenOf", word(sourceProjectId) + aw(backingToken));
        const remotePrimary = addr(await call(destination, dc.directory, "primaryTerminalOf", word(destinationProjectId) + aw(remoteBackingToken)));
        const remoteContext = await call(destination, remotePrimary, "accountingContextForTokenOf", word(destinationProjectId) + aw(remoteBackingToken));
        if (addr(context) !== address(backingToken) || addr(remoteContext) !== address(remoteBackingToken) || uint(context, 1) !== uint(remoteContext, 1)) throw new Error("The bridge's backing accounting contexts are inconsistent.");
      }
      return route;
    }
    async function discover({ source, destination, sourceToken }) {
      sourceToken = address(sourceToken);
      await Promise.all([chain(source), chain(destination)]);
      const sc = contracts(source), dc = contracts(destination);
      await Promise.all([code(source, sc.tokens), code(source, sc.suckerRegistry), code(destination, dc.tokens), code(destination, dc.suckerRegistry)]);
      const sourceProjectId = uint(await call(source, sc.tokens, "projectIdOf", aw(sourceToken)));
      if (!sourceProjectId) throw new Error("This is not a Juicebox V6 project token on the origin chain.");
      const locals = array(await call(source, sc.suckerRegistry, "allSuckersOf", word(sourceProjectId)), 1).map(data => addr(data));
      const contexts = array(await call(source, sc.terminal, "accountingContextsOf", word(sourceProjectId)), 3);
      const routes = [];
      for (const sourceSucker of locals) {
        const peerChain = Number(uint(await call(source, sourceSucker, "peerChainId")));
        if (peerChain !== destination.chainId) continue;
        const destinationSucker = addr(await call(source, sourceSucker, "peer"));
        const destinationProjectId = uint(await call(destination, destinationSucker, "projectId"));
        const rewardToken = addr(await call(destination, dc.tokens, "tokenOf", word(destinationProjectId)));
        for (const context of contexts) {
          const backingToken = addr(context);
          const mapping = await call(source, sourceSucker, "remoteTokenFor", aw(backingToken));
          if (uint(mapping, 3) === 0n) continue;
          const remoteBackingToken = addr(mapping, 3);
          const terminal = addr(await call(source, sc.directory, "primaryTerminalOf", word(sourceProjectId) + aw(backingToken)));
          const route = { source: { ...source }, destination: { ...destination }, sourceSucker, destinationSucker, sourceToken, rewardToken, sourceProjectId: sourceProjectId.toString(), destinationProjectId: destinationProjectId.toString(), backingToken, remoteBackingToken, terminal };
          await validateRoute(route, { preparing: true });
          const [sourceMeta, rewardMeta, backingMeta, state] = await Promise.all([tokenMeta(source, sourceToken), tokenMeta(destination, rewardToken), tokenMeta(source, backingToken), call(source, sourceSucker, "state").then(uint)]);
          if (sourceMeta.decimals !== rewardMeta.decimals) throw new Error("The source and destination project token decimals do not match.");
          routes.push({ ...route, sourceMeta, rewardMeta, backingMeta, canPrepare: uint(mapping) === 1n && uint(mapping, 1) === 0n && state < 2n });
        }
      }
      return routes;
    }
    const txFor = (runtime, to, data, label, args = [], value = 0n) => ({ chainId: runtime.chainId, rpcUrl: runtime.rpcUrl, to: address(to), data, value: "0x" + value.toString(16), label, args });
    async function prepare({ route, amount, owner, pocket, metadata }) {
      amount = BigInt(amount); owner = address(owner); pocket = address(pocket); metadata = hash(metadata);
      if (amount <= 0n || metadata === ZERO) throw new Error("A positive bridge amount and unique transfer reference are required.");
      await validateRoute(route, { sending: true, preparing: true });
      // Check that this RPC can reconstruct existing transfers before burning any new
      // source tokens. A truncated log service must fail before the wallet is asked.
      await movements(route, pocket);
      const { source, sourceSucker, sourceToken, backingToken, terminal, sourceProjectId } = route;
      const [balance, allowance, preview, feeFree, feeless] = await Promise.all([
        call(source, sourceToken, "balanceOf", aw(owner)).then(uint), call(source, sourceToken, "allowance", aw(owner) + aw(sourceSucker)).then(uint),
        call(source, terminal, "previewCashOutFrom", aw(sourceSucker) + word(sourceProjectId) + word(amount) + aw(backingToken) + aw(sourceSucker) + word(192) + word(0), sourceSucker),
        call(source, terminal, "feeFreeSurplusOf", word(sourceProjectId) + aw(backingToken)).then(uint),
        call(source, terminal, "FEELESS_ADDRESSES").then(data => call(source, addr(data), "isFeelessFor", aw(sourceSucker) + word(sourceProjectId) + aw(sourceSucker))).then(uint),
      ]);
      if (balance < amount) throw new Error("The origin wallet does not have enough project tokens.");
      const quote = minimumOutput(uint(preview, 9), uint(preview, 10), feeFree, feeless === 1n);
      const txs = [];
      if (allowance < amount) {
        if (allowance > 0n) txs.push({ ...txFor(source, sourceToken, SEL.approve + aw(sourceSucker) + word(0), "Reset bridge allowance"), fn: "approve(address,uint256)" });
        txs.push({ ...txFor(source, sourceToken, SEL.approve + aw(sourceSucker) + word(amount), "Approve bridge transfer", [["SPENDER", sourceSucker], ["AMOUNT", amount.toString() + " smallest units"]]), fn: "approve(address,uint256)" });
      }
      txs.push({ ...txFor(source, sourceSucker, SEL.prepare + word(amount) + aw(pocket) + word(quote.minimum) + aw(backingToken) + metadata.slice(2), "Queue cross-chain rewards", [["SOURCE TOKEN", sourceToken], ["DESTINATION TOKEN", route.rewardToken], ["DESTINATION POCKET", pocket], ["MINIMUM BACKING", quote.minimum.toString() + " smallest units"], ["SLIPPAGE", "1% below the live net backing quote"]]), fn: "prepare(uint256,bytes32,uint256,address,bytes32)" });
      return { txs: txs.map(tx => ({ ...tx, from: owner, sessionTag: "sticky-bridge:" + metadata })), ...quote };
    }

    async function movements(route, pocket) {
      await validateRoute(route);
      const source = route.source, destination = route.destination;
      const data = await call(source, route.sourceSucker, "outboxOf", aw(route.backingToken));
      if (words(data).length !== 36) throw new Error("The sucker outbox does not match the current V6 ABI.");
      const total = count(uint(data, 35));
      const sent = count(uint(data, 1));
      if (sent > total) throw new Error("The bridge reports more sent leaves than exist.");
      if (!total) return [];
      const filter = { address: route.sourceSucker, topics: [INSERT, null, "0x" + aw(route.backingToken)], fromBlock: source.bridgeFromBlock || "earliest", toBlock: "latest" };
      const logs = readLogs ? await readLogs((method, params) => request(source, method, params), filter) : await request(source, "eth_getLogs", [filter]);
      if (!Array.isArray(logs)) throw new Error("The source RPC did not return bridge history.");
      const leaves = new Map();
      for (const log of logs) {
        if (log.removed) continue;
        if (address(log.address) !== address(route.sourceSucker) || log.topics?.[0]?.toLowerCase() !== INSERT || log.topics?.[2]?.toLowerCase() !== "0x" + aw(route.backingToken)) throw new Error("The RPC returned an unrelated bridge event.");
        const ws = words(log.data);
        if (ws.length !== 7) throw new Error("The bridge event does not match the current V6 ABI.");
        const index = count(uint(log.data, 1));
        if (index >= total) continue; // A newer prepare can arrive after the outbox count read.
        const leaf = { index: BigInt(index), beneficiary: hash(log.topics[1]), projectTokenCount: uint(log.data, 3), terminalTokenAmount: uint(log.data, 4), metadata: "0x" + ws[5] };
        const computed = leafHash(leaf), emitted = "0x" + ws[0];
        if (computed !== emitted.toLowerCase()) throw new Error("A bridge event does not match its committed leaf.");
        const item = { leaf, leafHash: computed, root: "0x" + ws[2], sourceHash: hash(log.transactionHash), blockNumber: BigInt(log.blockNumber), caller: addr(log.data, 6),
          event: { data: log.data, topics: log.topics, logIndex: log.logIndex, blockHash: log.blockHash } };
        if (leaves.has(index) && JSON.stringify(leaves.get(index), (_, v) => typeof v === "bigint" ? v.toString() : v) !== JSON.stringify(item, (_, v) => typeof v === "bigint" ? v.toString() : v)) throw new Error("The RPC returned conflicting bridge leaves.");
        leaves.set(index, item);
      }
      if (leaves.size !== total) throw new Error("The RPC returned incomplete bridge history. Use an archive RPC to recover this transfer.");
      const dense = Array.from({ length: total }, (_, i) => leaves.get(i));
      if (dense.some(x => !x)) throw new Error("The bridge history has a missing leaf.");
      const hashes = dense.map(x => x.leafHash);
      if (branchRoot(hashes[total - 1], proofFor(hashes, total - 1), total - 1) !== dense[total - 1].root.toLowerCase()) throw new Error("The reconstructed bridge tree does not match its emitted root.");
      // Check the same root against the live branch array, not only an RPC event.
      let currentRoot = ZERO, size = total;
      const outboxWords = words(data);
      for (let i = 0; i < 32; i++) { currentRoot = size % 2 ? pairHash("0x" + outboxWords[3 + i], currentRoot) : pairHash(currentRoot, zeros[i]); size = Math.floor(size / 2); }
      if (currentRoot !== dense[total - 1].root.toLowerCase()) throw new Error("The reconstructed bridge tree does not match the source contract.");
      const inbox = await call(destination, route.destinationSucker, "inboxOf", aw(route.remoteBackingToken));
      const inboxRoot = "0x" + words(inbox)[1];
      const delivered = inboxRoot === ZERO ? 0 : dense.findIndex(item => item.root.toLowerCase() === inboxRoot.toLowerCase()) + 1;
      if (inboxRoot !== ZERO && !delivered) throw new Error("The destination root is absent from the verified source history.");
      const selected = dense.filter(item => item.leaf.beneficiary === "0x" + aw(pocket));
      const deliveredHashes = hashes.slice(0, delivered);
      const deliveredLevels = treeLevels(deliveredHashes);
      return Promise.all(selected.map(async item => {
        const index = Number(item.leaf.index);
        const executed = hash(await call(destination, route.destinationSucker, "executedLeafHashOf", aw(route.remoteBackingToken) + word(index)));
        if (executed !== ZERO && executed !== item.leafHash) throw new Error("The destination executed a different bridge leaf.");
        const status = executed !== ZERO ? "claimed" : index < delivered ? "claimable" : index < sent ? "in-flight" : "queued";
        const proof = status === "claimable" ? proofFor(deliveredHashes, index, deliveredLevels) : null;
        if (proof && branchRoot(item.leafHash, proof, index) !== inboxRoot.toLowerCase()) throw new Error("The bridge claim proof does not match the destination root.");
        return { ...item, status, proof, remoteToken: route.remoteBackingToken };
      }));
    }
    async function flush(route, owner, pocket) {
      await validateRoute(route, { sending: true });
      if (!(await movements(route, pocket)).some(row => row.status === "queued")) throw new Error("No rewards are waiting to leave the origin chain. Refresh their status.");
      let transport = "unknown";
      for (const probe of ["CCIP_ROUTER", "OPMESSENGER"]) {
        try { addr(await call(route.source, route.sourceSucker, probe)); transport = probe === "CCIP_ROUTER" ? "ccip" : "native"; break; } catch { /* A failed probe is never a positive match. */ }
      }
      if (transport === "unknown") {
        try {
          const layer = uint(await call(route.source, route.sourceSucker, "LAYER"));
          addr(await call(route.source, route.sourceSucker, "GATEWAYROUTER"));
          if (layer === 0n && [1, 11155111].includes(route.source.chainId) && [42161, 421614].includes(route.destination.chainId)) {
            addr(await call(route.source, route.sourceSucker, "ARBINBOX"));
            transport = "arbitrum-l1";
          } else if (layer === 1n && [42161, 421614].includes(route.source.chainId) && [1, 11155111].includes(route.destination.chainId)) transport = "native";
        } catch { /* Arbitrum L2 has no L1 inbox; verify its layer and gateway instead. */ }
      }
      if (transport === "unknown") throw new Error("This bridge transport cannot be verified. The queued transfer is saved for recovery.");
      const fee = uint(await call(route.source, contracts(route.source).suckerRegistry, "toRemoteFee"));
      const budgets = ["ccip", "arbitrum-l1"].includes(transport) ? [10n ** 15n, 5n * 10n ** 15n, 2n * 10n ** 16n, 5n * 10n ** 16n, 2n * 10n ** 17n, 5n * 10n ** 17n] : [0n];
      for (const budget of budgets) {
        const tx = { ...txFor(route.source, route.sourceSucker, SEL.toRemote + aw(route.backingToken), "Send queued rewards across chains", [["DESTINATION", route.destination.name || String(route.destination.chainId)], ["FEE AND TRANSPORT BUDGET", (fee + budget).toString() + " wei"], ["EFFECT", "send the origin bridge's queued batch; destination arrival is asynchronous"]], fee + budget), from: address(owner), fn: "toRemote(address)" };
        try { await request(route.source, "eth_call", [{ from: tx.from, to: tx.to, data: tx.data, value: tx.value }, "latest"]); return tx; } catch { /* Only a successfully simulated exact native budget is offered. */ }
      }
      throw new Error("The bridge transport could not be quoted. The queued rewards remain recoverable; refresh and try again.");
    }
    async function claim(route, row, owner, pocket) {
      const live = (await movements(route, pocket)).find(item => item.leaf.index === row.leaf.index && item.leafHash === row.leafHash);
      if (!live || live.status !== "claimable" || live.proof?.length !== 32) throw new Error("This transfer is not ready to claim. Refresh its bridge status.");
      const leaf = live.leaf;
      const data = SEL.claim + aw(route.remoteBackingToken) + word(leaf.index) + hash(leaf.beneficiary).slice(2) + word(leaf.projectTokenCount) + word(leaf.terminalTokenAmount) + hash(leaf.metadata).slice(2) + live.proof.map(x => hash(x).slice(2)).join("");
      const tx = { ...txFor(route.destination, route.destinationSucker, data, "Claim arriving rewards", [["REWARD TOKEN", route.rewardToken], ["POCKET", address(pocket)], ["EFFECT", "deliver project tokens into this Sticky project's reward pocket"]]), from: address(owner), fn: "claim((address,(uint256,bytes32,uint256,uint256,bytes32),bytes32[32]))" };
      await request(route.destination, "eth_call", [{ from: tx.from, to: tx.to, data: tx.data }, "latest"]);
      return tx;
    }
    async function verifySource(route, row, owner, expectedData) {
      owner = address(owner);
      await chain(route.source);
      if (row.caller !== owner || typeof expectedData !== "string" || !expectedData.startsWith(SEL.prepare)) throw new Error("The source bridge event is not the saved wallet transfer.");
      const [transaction, receipt] = await Promise.all([
        request(route.source, "eth_getTransactionByHash", [hash(row.sourceHash)]),
        request(route.source, "eth_getTransactionReceipt", [hash(row.sourceHash)]),
      ]);
      if (!transaction || !receipt || BigInt(receipt.status || 0) !== 1n || hash(receipt.transactionHash) !== row.sourceHash
        || hash(transaction.hash) !== row.sourceHash || BigInt(receipt.blockNumber) !== row.blockNumber
        || BigInt(transaction.blockNumber) !== row.blockNumber || hash(transaction.blockHash) !== hash(receipt.blockHash)
        || hash(row.event.blockHash) !== hash(receipt.blockHash) || (transaction.chainId != null && BigInt(transaction.chainId) !== BigInt(route.source.chainId))
        || transaction.from?.toLowerCase() !== receipt.from?.toLowerCase() || transaction.to?.toLowerCase() !== receipt.to?.toLowerCase()
        || BigInt(transaction.transactionIndex) !== BigInt(receipt.transactionIndex)) throw new Error("The source transaction is not proven successful in its recorded block.");
      const block = await request(route.source, "eth_getBlockByNumber", [receipt.blockNumber, false]);
      const txIndex = count(BigInt(transaction.transactionIndex), 100000);
      if (!block || hash(block.hash) !== hash(receipt.blockHash) || BigInt(block.number) !== row.blockNumber
        || block.transactions?.[txIndex]?.toLowerCase() !== row.sourceHash) throw new Error("The source bridge transaction is no longer canonical.");
      const included = receipt.logs?.some(log => !log.removed && address(log.address) === address(route.sourceSucker)
        && log.data?.toLowerCase() === row.event.data.toLowerCase() && BigInt(log.logIndex) === BigInt(row.event.logIndex)
        && log.transactionHash?.toLowerCase() === row.sourceHash && log.blockHash?.toLowerCase() === receipt.blockHash.toLowerCase()
        && BigInt(log.blockNumber) === row.blockNumber
        && JSON.stringify(log.topics?.map(value => value.toLowerCase())) === JSON.stringify(row.event.topics.map(value => value.toLowerCase())));
      if (!included) throw new Error("The source receipt does not include this bridge event.");
      const direct = transaction.from?.toLowerCase() === owner && transaction.to?.toLowerCase() === address(route.sourceSucker)
        && (transaction.input || transaction.data)?.toLowerCase() === expectedData.toLowerCase() && BigInt(transaction.value || 0) === 0n;
      const safe = inspectSafeExecution?.(transaction, receipt, { from: owner, to: route.sourceSucker, data: expectedData, value: 0n });
      if (!direct && !safe) throw new Error("The source transaction does not match the exact saved bridge call.");
      return receipt;
    }
    return { discover, validateRoute, pocketFor, prepare, movements, flush, claim, verifySource, tokenMeta, leafHash, proofFor, branchRoot };
  }
  return { create, CONTRACTS, SEL, INSERT, NATIVE, ZERO, EMPTY_ROOT, minimumOutput, address, word, words, uint, addr, array };
});
