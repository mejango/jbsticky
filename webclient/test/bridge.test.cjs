const test = require('node:test');
const assert = require('node:assert/strict');
const Bridge = require('../bridge.js');
const { keccak256 } = require('../relayr.js');
const { SEL, ZERO, NATIVE, word, CONTRACTS } = Bridge;
const A = n => '0x' + BigInt(n).toString(16).padStart(40, '0');
const addressWord = a => a.slice(2).padStart(64, '0');
const abi = (...values) => '0x' + values.map(v => typeof v === 'string' && /^0x/.test(v) ? v.slice(2).padStart(64, '0') : word(v)).join('');
const array = values => abi(32, values.length, ...values);

function fixture(changes = {}) {
  const state = { delivered: true, executed: false, membership: 1n, allowance: 0n, balance: 10000n, mapping: NATIVE,
    token: A(32), sourceChain: 1n, transport: 'ccip', successfulBudget: 10n ** 15n, incomplete: false, ...changes };
  const route = {
    source: { chainId: 1, rpcUrl: 'https://source.example', environment: 'production', name: 'Ethereum' },
    destination: { chainId: 10, rpcUrl: 'https://destination.example', environment: 'production', name: 'OP Mainnet' },
    sourceSucker: A(11), destinationSucker: A(12), sourceProjectId: '21', destinationProjectId: '22',
    sourceToken: A(31), rewardToken: A(32), backingToken: NATIVE, remoteBackingToken: NATIVE,
    terminal: CONTRACTS.terminal,
  };
  const owner = A(40), pocket = A(41), metadata = abi(99);
  const leaf = { index: 0n, beneficiary: abi(pocket), projectTokenCount: 1000n, terminalTokenAmount: 500n, metadata };
  const calls = [];
  let api;
  const sourceHash = abi(1001);
  const blockHash = abi(1002);
  const prepareData = SEL.prepare + word(1000) + addressWord(pocket) + word(965) + addressWord(NATIVE) + metadata.slice(2);
  const event = () => {
    const hashed = api.leafHash(leaf);
    const root = api.branchRoot(hashed, api.proofFor([hashed], 0), 0);
    return { address: route.sourceSucker, topics: [Bridge.INSERT, leaf.beneficiary, abi(NATIVE)],
      data: abi(state.badHash ? ZERO : hashed, 0, root, leaf.projectTokenCount, leaf.terminalTokenAmount, leaf.metadata, state.caller || owner),
      transactionHash: sourceHash, blockNumber: '0x64', blockHash, logIndex: '0x0' };
  };
  const rpc = async (url, method, params) => {
    calls.push({ url, method, params });
    const source = url === route.source.rpcUrl;
    if (method === 'eth_chainId') return source ? '0x' + state.sourceChain.toString(16) : '0x' + route.destination.chainId.toString(16);
    if (method === 'eth_getCode') return state.emptyCode ? '0x' : '0x60006000';
    if (method === 'eth_getTransactionByHash') return {
      hash: sourceHash, blockHash, blockNumber: '0x64', from: owner, to: route.sourceSucker,
      chainId: '0x' + route.source.chainId.toString(16), value: '0x0', input: state.wrongInput ? '0x12345678' : prepareData, transactionIndex: '0x0',
    };
    if (method === 'eth_getTransactionReceipt') return {
      transactionHash: sourceHash, blockHash, blockNumber: '0x64', from: owner, to: route.sourceSucker,
      status: '0x1', transactionIndex: '0x0', logs: state.missingReceiptLog ? [] : [event()],
    };
    if (method === 'eth_getBlockByNumber') return { hash: state.reorged ? abi(1234) : blockHash, number: '0x64', transactions: [state.wrongBlockTx ? abi(1235) : sourceHash] };
    if (method === 'eth_getLogs') {
      if (state.incomplete) return [];
      return state.badAddress ? [{ ...event(), address: A(999) }] : [event()];
    }
    if (method !== 'eth_call') throw new Error('unexpected ' + method);
    const tx = params[0], selector = tx.data.slice(0, 10);
    if (selector === SEL.isSuckerOf) return abi(state.membership);
    if (selector === SEL.peer) return abi(source ? route.destinationSucker : state.badPeer ? A(555) : route.sourceSucker);
    if (selector === SEL.peerChainId) return abi(source ? route.destination.chainId : route.source.chainId);
    if (selector === SEL.projectId) return abi(source ? 21 : 22);
    if (selector === SEL.projectIdOf) return abi(state.nonProject ? 0 : 21);
    if (selector === SEL.tokenOf) return abi(source ? route.sourceToken : state.token);
    if (selector === SEL.TOKENS) return abi(CONTRACTS.tokens);
    if (selector === SEL.DIRECTORY) return abi(CONTRACTS.directory);
    if (selector === SEL.remoteTokenFor) return abi(state.disabled ? 0 : 1, 0, 200000, !source && state.changedReverse ? A(999) : state.mapping);
    if (selector === SEL.primaryTerminalOf) return abi(state.migratedTerminal ? A(800) : CONTRACTS.terminal);
    if (selector === SEL.accountingContextForTokenOf) return abi(NATIVE, source ? 18 : state.badDecimals ? 6 : 18, 61166);
    if (selector === SEL.accountingContextsOf) return abi(32, 1, NATIVE, 18, 61166);
    if (selector === SEL.allSuckersOf) return array([route.sourceSucker]);
    if (selector === SEL.state) return abi(0);
    if (selector === SEL.DISTRIBUTOR) return abi(state.distributor || A(51));
    if (selector === SEL.predictPocketOf) return abi(pocket);
    if (selector === SEL.decimals) return abi(18);
    if (selector === SEL.symbol) return abi(32, 3) + Buffer.from('TOK').toString('hex').padEnd(64, '0');
    if (selector === SEL.balanceOf) return abi(state.balance);
    if (selector === SEL.allowance) return abi(state.allowance);
    if (selector === SEL.previewCashOutFrom) return abi(...Array(9).fill(0), 1000, 1000, 384, 0);
    if (selector === SEL.feeFreeSurplusOf) return abi(0);
    if (selector === SEL.FEELESS_ADDRESSES) return abi(A(60));
    if (selector === SEL.isFeelessFor) return abi(0);
    if (selector === SEL.outboxOf) return abi(1, state.delivered ? 1 : 0, 500, state.badBranch ? ZERO : api.leafHash(leaf), ...Array(31).fill(ZERO), 1);
    if (selector === SEL.inboxOf) return abi(state.delivered ? 1 : 0, state.delivered ? api.branchRoot(api.leafHash(leaf), api.proofFor([api.leafHash(leaf)], 0), 0) : ZERO);
    if (selector === SEL.executedLeafHashOf) return state.badExecution ? abi(9000) : state.executed ? api.leafHash(leaf) : ZERO;
    if ([SEL.CCIP_ROUTER, SEL.OPMESSENGER, SEL.ARBINBOX, SEL.LAYER, SEL.GATEWAYROUTER].includes(selector)) {
      if (state.transport === 'ccip' && selector === SEL.CCIP_ROUTER) return abi(A(70));
      if (state.transport === 'native' && selector === SEL.OPMESSENGER) return abi(A(71));
      if (state.transport.startsWith('arbitrum')) {
        if (selector === SEL.LAYER) return abi(state.transport === 'arbitrum-l1' ? 0 : 1);
        if (selector === SEL.GATEWAYROUTER) return abi(A(72));
        if (selector === SEL.ARBINBOX) return state.transport === 'arbitrum-l1' ? abi(A(73)) : ZERO;
      }
      throw new Error('no transport probe');
    }
    if (selector === SEL.toRemoteFee) return abi(100);
    if (selector === SEL.toRemote) {
      if (BigInt(tx.value) < 100n + state.successfulBudget) throw new Error('insufficient transport value');
      return '0x';
    }
    if (selector === SEL.claim) { if (state.rejectClaim) throw new Error('claim reverted'); return '0x'; }
    throw new Error('unexpected selector ' + selector);
  };
  api = Bridge.create({ rpc, keccak256 });
  return { api, route, state, calls, owner, pocket, metadata, leaf, sourceHash, prepareData };
}

test('Merkle reconstruction uses the exact canonical V6 empty root', () => {
  const { api } = fixture();
  assert.equal(api.branchRoot(ZERO, api.proofFor([ZERO], 0), 0), Bridge.EMPTY_ROOT);
  assert.throws(() => Bridge.create({ rpc: () => {}, keccak256: () => ZERO }), /self-check/);
});

test('dense odd-sized trees yield matching fixed-depth proofs, and mutations change the root', () => {
  const { api } = fixture();
  const hashes = [1n, 2n, 3n].map(n => keccak256(abi(n)));
  const roots = hashes.map((value, index) => api.branchRoot(value, api.proofFor(hashes, index), index));
  assert.equal(new Set(roots).size, 1);
  const proof = api.proofFor(hashes, 2);
  assert.equal(proof.length, 32);
  proof[0] = hashes[0];
  assert.notEqual(api.branchRoot(hashes[2], proof, 2), roots[2]);
  assert.throws(() => api.branchRoot(hashes[0], [], 0), /Invalid bridge proof/);
});

test('net backing minimum includes only applicable protocol fees and the 1% floor', () => {
  assert.deepEqual(Bridge.minimumOutput(1000n, 1000n, 0n, false), { net: 975n, minimum: 965n });
  assert.deepEqual(Bridge.minimumOutput(1000n, 0n, 400n, false), { net: 990n, minimum: 980n });
  assert.deepEqual(Bridge.minimumOutput(1000n, 1000n, 400n, true), { net: 1000n, minimum: 990n });
  assert.throws(() => Bridge.minimumOutput(0n, 0n, 0n, false), /nonzero/);
  assert.throws(() => Bridge.minimumOutput(1n, 0n, 0n, false), /rounds to zero/);
  assert.throws(() => Bridge.minimumOutput(100n, 0n, 0n, false, 501n), /5%/);
});

test('discovery resolves different per-chain project IDs and destination project token', async () => {
  const { api, route } = fixture();
  const routes = await api.discover({ source: route.source, destination: route.destination, sourceToken: route.sourceToken });
  assert.equal(routes.length, 1);
  assert.equal(routes[0].sourceProjectId, '21');
  assert.equal(routes[0].destinationProjectId, '22');
  assert.equal(routes[0].rewardToken, route.rewardToken);
  assert.equal(routes[0].canPrepare, true);
});

for (const [name, changes, pattern] of [
  ['wrong RPC chain', { sourceChain: 10n }, /wrong chain/],
  ['missing deployment', { emptyCode: true }, /not deployed/],
  ['unregistered sucker', { membership: 0n }, /registry/],
  ['one-way peer', { badPeer: true }, /peer/],
  ['wrong project token', { token: A(999) }, /project token/],
  ['wrong mapping', { mapping: A(998) }, /mapping/],
  ['mismatched backing decimals', { badDecimals: true }, /accounting contexts/],
]) test('route verification rejects ' + name, async () => {
  const { api, route } = fixture(changes);
  await assert.rejects(api.validateRoute(route, { preparing: true }), pattern);
});

test('mainnet and testnet routes are never mixed', async () => {
  const { api, route } = fixture();
  route.destination.environment = 'testnet';
  await assert.rejects(api.validateRoute(route), /same environment/);
});

test('pockets are verified against the intended distributor before creating a beneficiary', async () => {
  const { api, route, pocket } = fixture();
  assert.equal(await api.pocketFor(route.destination, A(80), A(81), A(51)), pocket);
  await assert.rejects(api.pocketFor(route.destination, A(80), A(81), A(52)), /distributor/);
});

test('prepare returns exact, chain-pinned approval and protected queue requests with a recovery tag', async () => {
  const { api, route, owner, pocket, metadata } = fixture();
  const result = await api.prepare({ route, owner, pocket, metadata, amount: 1000n });
  assert.equal(result.txs.length, 2);
  assert.equal(result.txs[0].to, route.sourceToken);
  assert.equal(result.txs[0].data, SEL.approve + addressWord(route.sourceSucker) + word(1000));
  const tx = result.txs[1];
  assert.equal(tx.data, SEL.prepare + word(1000) + addressWord(pocket) + word(965) + addressWord(NATIVE) + metadata.slice(2));
  assert.equal(tx.chainId, 1);
  assert.equal(tx.rpcUrl, route.source.rpcUrl);
  assert.equal(tx.from, owner);
  assert.equal(tx.sessionTag, 'sticky-bridge:' + metadata);
});

test('nonzero insufficient approval is reset first, exact sufficient allowance skips approval', async () => {
  const f = fixture({ allowance: 1n });
  let result = await f.api.prepare({ ...f, amount: 1000n });
  assert.equal(result.txs.length, 3);
  assert.equal(result.txs[0].data, SEL.approve + addressWord(f.route.sourceSucker) + word(0));
  f.state.allowance = 1000n;
  result = await f.api.prepare({ ...f, amount: 1000n });
  assert.equal(result.txs.length, 1);
});

test('zero amounts, insufficient balances, untagged attempts and disabled routes cannot prepare', async () => {
  const f = fixture({ balance: 0n });
  await assert.rejects(f.api.prepare({ ...f, amount: 0n }), /positive/);
  await assert.rejects(f.api.prepare({ ...f, amount: 1n, metadata: ZERO }), /unique/);
  await assert.rejects(f.api.prepare({ ...f, amount: 1n }), /enough project tokens/);
  f.state.disabled = true;
  await assert.rejects(f.api.prepare({ ...f, amount: 1n }), /no longer accepts/);
});

test('movements prove source preimages, dense history, live outbox branch and destination root', async () => {
  const { api, route, pocket, sourceHash } = fixture();
  const rows = await api.movements(route, pocket);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, 'claimable');
  assert.equal(rows[0].proof.length, 32);
  assert.equal(rows[0].sourceHash, sourceHash);
  assert.equal((await api.movements(route, A(888))).length, 0);
});

for (const [name, changes, pattern] of [
  ['missing history', { incomplete: true }, /incomplete bridge history/],
  ['forged preimage', { badHash: true }, /committed leaf/],
  ['unrelated event', { badAddress: true }, /unrelated bridge event/],
  ['wrong live branch root', { badBranch: true }, /source contract/],
  ['wrong executed leaf', { badExecution: true }, /different bridge leaf/],
]) test('movement reconstruction rejects ' + name, async () => {
  const { api, route, pocket } = fixture(changes);
  await assert.rejects(api.movements(route, pocket), pattern);
});

test('already-executed leaves never expose a replayable claim proof', async () => {
  const f = fixture({ executed: true });
  const [row] = await f.api.movements(f.route, f.pocket);
  assert.equal(row.status, 'claimed');
  assert.equal(row.proof, null);
  await assert.rejects(f.api.claim(f.route, row, f.owner, f.pocket), /not ready/);
});

test('claim uses an exact static V6 tuple and rechecks the proof before simulation', async () => {
  const f = fixture();
  const [row] = await f.api.movements(f.route, f.pocket);
  const tx = await f.api.claim(f.route, row, f.owner, f.pocket);
  assert.equal(tx.chainId, 10);
  assert.equal(tx.to, f.route.destinationSucker);
  assert.equal(tx.data.length, 10 + 38 * 64);
  assert.equal(tx.data.slice(10, 10 + 6 * 64), addressWord(NATIVE) + word(0) + addressWord(f.pocket) + word(1000) + word(500) + f.metadata.slice(2));
  assert.ok(f.calls.some(call => call.method === 'eth_call' && call.params[0].data === tx.data && call.url === f.route.destination.rpcUrl));
  f.state.rejectClaim = true;
  await assert.rejects(f.api.claim(f.route, row, f.owner, f.pocket), /claim reverted/);
});

test('CCIP flushing uses a positive native transport budget plus the registry fee', async () => {
  const f = fixture({ delivered: false, successfulBudget: 5n * 10n ** 15n });
  const tx = await f.api.flush(f.route, f.owner, f.pocket);
  assert.equal(tx.chainId, 1);
  assert.equal(BigInt(tx.value), 100n + 5n * 10n ** 15n);
  const probes = f.calls.filter(call => call.method === 'eth_call' && call.params[0].data?.startsWith(SEL.toRemote));
  assert.ok(probes.every(call => BigInt(call.params[0].value) > 100n));
});

test('a failed transport probe never silently becomes a native bridge', async () => {
  const f = fixture({ delivered: false, transport: 'unknown' });
  await assert.rejects(f.api.flush(f.route, f.owner, f.pocket), /cannot be verified/);
});

test('native flush requires successful exact fee simulation; delivered batches cannot be sent again', async () => {
  const f = fixture({ delivered: false, transport: 'native', successfulBudget: 0n });
  assert.equal(BigInt((await f.api.flush(f.route, f.owner, f.pocket)).value), 100n);
  f.state.delivered = true;
  await assert.rejects(f.api.flush(f.route, f.owner, f.pocket), /No rewards are waiting/);
});

test('ABI parsing refuses truncation, over-wide addresses and impossible arrays', () => {
  assert.throws(() => Bridge.uint('0x'), /incomplete/);
  assert.throws(() => Bridge.addr(abi(1n << 200n)), /non-EVM/);
  assert.throws(() => Bridge.array(abi(32, 3, A(1)), 1), /incomplete array/);
  assert.throws(() => Bridge.array(abi(64, 0), 1), /offset/);
});

test('source recovery verifies the exact caller, transaction, canonical block inclusion and receipt event', async () => {
  const f = fixture();
  const [row] = await f.api.movements(f.route, f.pocket);
  const receipt = await f.api.verifySource(f.route, row, f.owner, f.prepareData);
  assert.equal(receipt.transactionHash, f.sourceHash);
});

for (const [name, change, pattern] of [
  ['copied metadata from another donor', { caller: A(777) }, /saved wallet transfer/],
  ['different source calldata', { wrongInput: true }, /exact saved bridge call/],
  ['missing receipt event', { missingReceiptLog: true }, /does not include/],
  ['reorged source block', { reorged: true }, /no longer canonical/],
  ['wrong block transaction index', { wrongBlockTx: true }, /no longer canonical/],
]) test('source recovery refuses ' + name, async () => {
  const f = fixture(change);
  const [row] = await f.api.movements(f.route, f.pocket);
  await assert.rejects(f.api.verifySource(f.route, row, f.owner, f.prepareData), pattern);
});

test('Arbitrum L1 to L2 explicitly quotes a positive retryable-ticket budget', async () => {
  const f = fixture({ delivered: false, transport: 'arbitrum-l1', successfulBudget: 5n * 10n ** 15n });
  f.route.destination.chainId = 42161;
  const tx = await f.api.flush(f.route, f.owner, f.pocket);
  assert.equal(BigInt(tx.value), 100n + 5n * 10n ** 15n);
});

test('Arbitrum L2 to L1 supports the zero transport route without an L1 inbox', async () => {
  const f = fixture({ delivered: false, transport: 'arbitrum-l2', successfulBudget: 0n, sourceChain: 42161n });
  f.route.source.chainId = 42161; f.route.destination.chainId = 1;
  const tx = await f.api.flush(f.route, f.owner, f.pocket);
  assert.equal(BigInt(tx.value), 100n);
});

test('terminal migrations preserve queued transfers and claims but require a new preparation quote', async () => {
  const f = fixture({ migratedTerminal: true });
  const [row] = await f.api.movements(f.route, f.pocket);
  assert.equal(row.status, 'claimable');
  await f.api.claim(f.route, row, f.owner, f.pocket);
  await assert.rejects(f.api.prepare({ ...f, amount: 1n }), /terminal changed/);
  f.state.delivered = false;
  await f.api.flush(f.route, f.owner, f.pocket);
});

test('destination outbound remapping does not invalidate existing inbound claims', async () => {
  const f = fixture({ changedReverse: true });
  const [row] = await f.api.movements(f.route, f.pocket);
  await f.api.claim(f.route, row, f.owner, f.pocket);
  await assert.rejects(f.api.prepare({ ...f, amount: 1n }), /mappings/);
});

test('incomplete historical RPC data blocks new token burning during preparation', async () => {
  const f = fixture({ incomplete: true });
  await assert.rejects(f.api.prepare({ ...f, amount: 1n }), /incomplete bridge history/);
});
