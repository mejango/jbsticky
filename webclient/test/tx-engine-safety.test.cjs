'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { createEngine, STORAGE_KEY } = require('../tx-engine.js');

const OWNER = '0x1111111111111111111111111111111111111111';
const TARGET = '0x2222222222222222222222222222222222222222';
const EXECUTOR = '0x3333333333333333333333333333333333333333';
const HASH = '0x' + 'ab'.repeat(32);
const REPLACEMENT = '0x' + 'cd'.repeat(32);
const PROPOSAL = '0x' + 'ef'.repeat(32);
const BLOCK = '0x' + '12'.repeat(32);
const OTHER_BLOCK = '0x' + '34'.repeat(32);
const SUCCESS = '0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e';
const FAILURE = '0x23428b18acfb3ea64b08dc0c1d296ea9c09702c09083ca5272e64d115b687d23';
const PLAN = { chainId: 8453, from: OWNER, to: TARGET, data: '0x1234abcd', value: '0x9', rpcUrl: 'https://rpc.example.test', label: 'Mint' };
const word = value => BigInt(value).toString(16).padStart(64, '0');
const addressWord = value => value.slice(2).padStart(64, '0');
const tail = data => word(data.length / 2) + data.padEnd(Math.ceil(data.length / 64) * 64, '0');

function safeInput() {
  const data = tail(PLAN.data.slice(2));
  return '0x6a761202' + [addressWord(TARGET), word(9), word(320), word(0), word(100000), word(0), word(0),
    word(0), word(0), word(320 + data.length / 2)].join('') + data + tail('11'.repeat(65));
}

function evidence(hash = HASH) {
  return {
    transaction: { hash, from: OWNER, to: TARGET, input: PLAN.data, value: PLAN.value, nonce: '0x7', chainId: '0x2105', blockNumber: '0x11', blockHash: BLOCK },
    receipt: { transactionHash: hash, blockNumber: '0x11', blockHash: BLOCK, status: '0x1', logs: [] },
  };
}

function safeEvidence(hash = HASH, outcome = SUCCESS) {
  const result = evidence(hash);
  result.transaction.from = EXECUTOR;
  result.transaction.to = OWNER;
  result.transaction.value = '0x0';
  result.transaction.input = safeInput();
  result.receipt.logs = [{ address: OWNER, topics: [outcome], data: PROPOSAL + word(0), transactionHash: hash }];
  return result;
}

function harness() {
  const stored = new Map();
  const storage = {
    getItem: key => stored.has(key) ? stored.get(key) : null,
    setItem: (key, value) => stored.set(key, value),
    removeItem: key => stored.delete(key),
  };
  const state = {
    chainId: '0x2105', code: '0x', canonicalBlock: { number: '0x11', hash: BLOCK },
    finalized: { number: '0x20', hash: OTHER_BLOCK }, sent: [], sendResults: [HASH],
    ledger: new Map([[HASH, evidence()]]), rpcCalls: [], reviews: 0,
  };
  const wallet = {
    request: async ({ method, params }) => {
      if (method === 'eth_accounts') return [OWNER];
      if (method === 'eth_chainId') return '0x2105';
      if (method === 'eth_sendTransaction') {
        state.sent.push(params[0]);
        const result = state.sendResults.shift();
        if (result instanceof Error) throw result;
        return result;
      }
      throw new Error('Unexpected wallet request: ' + method);
    },
  };
  const options = {
    storage,
    locks: { request: async (_name, _mode, callback) => callback({}) },
    wallet: () => wallet,
    ensureChain: async () => {},
    randomId: () => 'safety-test-session',
    pollAttempts: 1,
    sleep: async () => {},
    rpc: async (_tx, method, params) => {
      state.rpcCalls.push({ method, params });
      if (method === 'eth_chainId') return state.chainId;
      if (method === 'eth_call') return '0x';
      if (method === 'eth_blockNumber') return '0x10';
      if (method === 'eth_getTransactionCount') return '0x7';
      if (method === 'eth_getCode') return state.code;
      if (method === 'eth_getTransactionByHash') return state.ledger.get(params[0])?.transaction || null;
      if (method === 'eth_getTransactionReceipt') return state.ledger.get(params[0])?.receipt || null;
      if (method === 'eth_getBlockByNumber') {
        const result = params[0] === 'finalized' ? state.finalized : state.canonicalBlock;
        if (result instanceof Error) throw result;
        return result;
      }
      throw new Error('Unexpected RPC request: ' + method);
    },
  };
  const reload = () => createEngine(options);
  const review = async () => { state.reviews += 1; return true; };
  return { state, storage, reload, engine: reload(), review };
}

async function prepare(h) {
  await h.engine.prepare('Mint Sticky', [PLAN]);
}

test('mismatched or noncanonical receipt evidence never completes or resends a pending transaction', async t => {
  const cases = [
    ['transaction hash', item => { item.transaction.hash = REPLACEMENT; }],
    ['receipt transaction hash', item => { item.receipt.transactionHash = REPLACEMENT; }],
    ['receipt block hash', item => { item.receipt.blockHash = OTHER_BLOCK; }],
    ['transaction block number', item => { item.transaction.blockNumber = '0x12'; }],
    ['RPC canonical block hash', (_item, state) => { state.canonicalBlock.hash = OTHER_BLOCK; }],
    ['RPC canonical block number', (_item, state) => { state.canonicalBlock.number = '0x12'; }],
    ['transaction chain', item => { item.transaction.chainId = '0x1'; }],
    ['sender', item => { item.transaction.from = EXECUTOR; }],
    ['target', item => { item.transaction.to = OWNER; }],
    ['calldata', item => { item.transaction.input = '0x1234abce'; }],
    ['value', item => { item.transaction.value = '0xa'; }],
    ['old nonce', item => { item.transaction.nonce = '0x6'; }],
    ['pre-submission block', item => { item.transaction.blockNumber = item.receipt.blockNumber = '0x10'; }],
    ['unknown receipt status', item => { item.receipt.status = '0x2'; }],
    ['missing transaction', (_item, state) => { state.ledger.set(HASH, { receipt: evidence().receipt }); }],
    ['missing receipt', (_item, state) => { state.ledger.set(HASH, { transaction: evidence().transaction }); }],
  ];
  for (const [label, mutate] of cases) {
    await t.test(label, async () => {
      const h = harness();
      mutate(h.state.ledger.get(HASH), h.state);
      await prepare(h);
      await assert.rejects(h.engine.run({ review: h.review }));
      assert.equal(h.engine.load().steps[0].state, 'pending');
      assert.equal(h.state.sent.length, 1);
      await assert.rejects(h.reload().run({ review: h.review }));
      assert.equal(h.state.sent.length, 1);
      await assert.rejects(h.engine.clear(), /may still execute/);
      assert.equal(h.engine.load().steps[0].hash, HASH);
    });
  }
});

test('an RPC on another chain cannot send or manufacture recovered completion', async () => {
  const h = harness();
  h.state.chainId = '0x1';
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /different chain/);
  assert.equal(h.state.sent.length, 0);
  assert.equal(h.engine.load().steps[0].state, 'ready');
});

test('a disappeared previously confirmed receipt becomes pending and cannot replay', async () => {
  const h = harness();
  await prepare(h);
  await h.engine.run({ review: h.review });
  assert.equal(h.engine.load().steps[0].state, 'confirmed');
  h.state.ledger.clear();
  await assert.rejects(h.reload().run({ review: h.review }), /still unresolved/);
  const step = h.engine.load().steps[0];
  assert.equal(step.state, 'pending');
  assert.equal(step.receipt, undefined);
  assert.equal(step.hash, HASH);
  assert.equal(h.state.sent.length, 1);
});

test('a finalized exact reverted transaction permits a reviewed retry and retains its evidence', async () => {
  const h = harness();
  h.state.ledger.get(HASH).receipt.status = '0x0';
  h.state.sendResults.push(REPLACEMENT);
  h.state.ledger.set(REPLACEMENT, evidence(REPLACEMENT));
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /reverted and is finalized/);
  assert.equal(h.engine.load().steps[0].state, 'reverted');
  await h.reload().run({ review: h.review });
  const step = h.engine.load().steps[0];
  assert.equal(h.state.sent.length, 2);
  assert.equal(h.state.reviews, 2);
  assert.equal(step.state, 'confirmed');
  assert.equal(step.hash, REPLACEMENT);
  assert.equal(step.attempts.length, 1);
  assert.equal(step.attempts[0].hash, HASH);
  assert.equal(step.attempts[0].receipt.status, '0x0');
  assert.equal(step.attempts[0].state, 'reverted');
});

test('an unfinalized revert or unavailable finality cannot permit retry or clearing', async t => {
  for (const finalized of [{ number: '0x10', hash: OTHER_BLOCK }, null, new Error('finalized tag unavailable')]) {
    await t.test(String(finalized?.number || finalized), async () => {
      const h = harness();
      h.state.ledger.get(HASH).receipt.status = '0x0';
      h.state.finalized = finalized;
      await prepare(h);
      await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
      await assert.rejects(h.reload().run({ review: h.review }), /still unresolved/);
      await assert.rejects(h.engine.clear(), /may still execute/);
      assert.equal(h.engine.load().steps[0].state, 'pending');
      assert.equal(h.state.sent.length, 1);
    });
  }
});

test('an unknown wallet submission survives reload without replay and recovers only exact execution', async () => {
  const h = harness();
  h.state.sendResults = [new Error('wallet connection disappeared')];
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /outcome is unknown/);
  let step = h.engine.load().steps[0];
  assert.equal(step.state, 'unknown');
  assert.equal(step.hash, undefined);
  assert.equal(step.submission.blockNumber, '0x10');
  await assert.rejects(h.reload().run({ review: h.review }), /did not return a transaction hash/);
  await assert.rejects(h.engine.clear(), /may still execute/);
  h.state.ledger.set(REPLACEMENT, evidence(REPLACEMENT));
  h.state.ledger.get(REPLACEMENT).transaction.value = '0xa';
  await assert.rejects(h.engine.recover(REPLACEMENT), /does not prove/);
  assert.equal(h.engine.load().steps[0].state, 'unknown');
  await h.reload().recover(HASH);
  step = h.engine.load().steps[0];
  assert.equal(step.state, 'confirmed');
  assert.equal(step.hash, HASH);
  await h.reload().run({ review: h.review });
  assert.equal(h.state.sent.length, 1);
});

test('a wallet success response without a hash is still an unknown submission', async t => {
  for (const result of [undefined, null, '0x1234', { hash: HASH }]) {
    await t.test(JSON.stringify(result) || 'undefined', async () => {
      const h = harness();
      h.state.sendResults = [result];
      await prepare(h);
      await assert.rejects(h.engine.run({ review: h.review }), /no valid transaction hash/);
      await assert.rejects(h.reload().run({ review: h.review }), /did not return a transaction hash/);
      assert.equal(h.engine.load().steps[0].state, 'unknown');
      assert.equal(h.state.sent.length, 1);
    });
  }
});

test('a recovered Safe execution does not confuse an earlier wallet execution hash with a proposal hash', async () => {
  const h = harness();
  h.state.code = '0x6001';
  h.state.ledger.clear();
  h.state.ledger.set(REPLACEMENT, safeEvidence(REPLACEMENT));
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
  await h.reload().recover(REPLACEMENT);
  const step = h.engine.load().steps[0];
  assert.equal(step.state, 'confirmed');
  assert.equal(step.reportedHash, HASH);
  assert.equal(step.hash, REPLACEMENT);
  assert.equal(h.state.sent.length, 1);
});

test('a known Safe proposal hash remains bound to its exact successful event', async () => {
  const h = harness();
  h.state.code = '0x6001';
  h.state.sendResults = [PROPOSAL];
  h.state.ledger.clear();
  h.state.ledger.set(REPLACEMENT, safeEvidence(REPLACEMENT));
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
  const saved = h.engine.load();
  saved.steps[0].reportedHashKind = 'proposal';
  h.storage.setItem(STORAGE_KEY, JSON.stringify(saved));
  h.state.ledger.get(REPLACEMENT).receipt.logs[0].data = HASH + word(0);
  await assert.rejects(h.engine.recover(REPLACEMENT), /does not prove/);
  assert.equal(h.engine.load().steps[0].reportedHash, PROPOSAL);
  h.state.ledger.get(REPLACEMENT).receipt.logs[0].data = PROPOSAL + word(0);
  await h.reload().recover(REPLACEMENT);
  assert.equal(h.engine.load().steps[0].state, 'confirmed');
});

test('a canonical finalized Safe inner failure is retryable and retains the failed execution', async () => {
  const h = harness();
  h.state.code = '0x6001';
  h.state.ledger.set(HASH, safeEvidence(HASH, FAILURE));
  h.state.ledger.set(REPLACEMENT, safeEvidence(REPLACEMENT));
  h.state.sendResults.push(REPLACEMENT);
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /reverted and is finalized/);
  assert.equal(h.engine.load().steps[0].state, 'reverted');
  await h.reload().run({ review: h.review });
  const step = h.engine.load().steps[0];
  assert.equal(step.state, 'confirmed');
  assert.equal(step.hash, REPLACEMENT);
  assert.equal(step.attempts[0].hash, HASH);
  assert.equal(step.attempts[0].receipt.logs[0].topics[0], FAILURE);
  assert.equal(h.state.sent.length, 2);
});

test('a Safe failure with insufficient finality cannot be retried', async () => {
  const h = harness();
  h.state.code = '0x6001';
  h.state.finalized.number = '0x10';
  h.state.ledger.set(HASH, safeEvidence(HASH, FAILURE));
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
  await assert.rejects(h.reload().run({ review: h.review }), /still unresolved/);
  assert.equal(h.engine.load().steps[0].state, 'pending');
  assert.equal(h.state.sent.length, 1);
});

test('a finalized outer Safe revert cannot permit retry while its signed proposal remains live', async () => {
  const h = harness();
  h.state.code = '0x6001';
  const reverted = safeEvidence();
  reverted.receipt.status = '0x0';
  reverted.receipt.logs = [];
  h.state.ledger.set(HASH, reverted);
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
  await assert.rejects(h.reload().run({ review: h.review }), /still unresolved/);
  await assert.rejects(h.engine.clear(), /may still execute/);
  assert.equal(h.engine.load().steps[0].state, 'pending');
  assert.equal(h.state.sent.length, 1);
});

test('an unrelated Safe inner failure cannot consume the saved proposal even with the same calldata', async () => {
  const h = harness();
  h.state.code = '0x6001';
  h.state.sendResults = [PROPOSAL];
  h.state.ledger.clear();
  const failure = safeEvidence(REPLACEMENT, FAILURE);
  // Same Safe and exact inner call, but a different proposal was consumed.
  failure.receipt.logs[0].data = HASH + word(0);
  h.state.ledger.set(REPLACEMENT, failure);
  await prepare(h);
  await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
  await assert.rejects(h.engine.recover(REPLACEMENT), /does not prove/);
  await assert.rejects(h.reload().run({ review: h.review }), /still unresolved/);
  assert.equal(h.engine.load().steps[0].reportedHash, PROPOSAL);
  assert.equal(h.engine.load().steps[0].hash, PROPOSAL);
  assert.equal(h.state.sent.length, 1);
});

test('a source intent with exact canonical finalized EOA failure can be discarded', async () => {
  const h = harness();
  h.state.ledger.get(HASH).receipt.status = '0x0';
  const session = await h.engine.prepare('Prepare bridge', [{ ...PLAN, sessionTag: 'bridge:finalized' }]);
  await assert.rejects(h.engine.run({ review: h.review }), /reverted and is finalized/);
  await h.engine.discardUnsubmitted(session.id);
  assert.equal(h.engine.wasDiscarded(session.id, 'bridge:finalized'), true);
  assert.equal(h.engine.load(), null);
  assert.equal(h.state.sent.length, 1);
});

test('discard freshly rechecks finality and canonicality of a saved failure', async t => {
  for (const reason of ['prefinality', 'reorg', 'missing', 'no-finality']) {
    await t.test(reason, async () => {
      const h = harness();
      h.state.ledger.get(HASH).receipt.status = '0x0';
      const session = await h.engine.prepare('Prepare bridge', [{ ...PLAN, sessionTag: 'bridge:finalized' }]);
      await assert.rejects(h.engine.run({ review: h.review }), /reverted and is finalized/);
      if (reason === 'prefinality') h.state.finalized = { number: '0x10', hash: OTHER_BLOCK };
      if (reason === 'reorg') h.state.canonicalBlock.hash = OTHER_BLOCK;
      if (reason === 'missing') h.state.ledger.delete(HASH);
      if (reason === 'no-finality') h.state.finalized = new Error('unsupported');
      await assert.rejects(h.engine.discardUnsubmitted(session.id), /may have been submitted/);
      assert.equal(h.engine.wasDiscarded(session.id), false);
      assert.equal(h.engine.load().id, session.id);
      assert.equal(h.state.sent.length, 1);
    });
  }
});

test('a rejected retry requires each earlier failed attempt to remain canonically finalized before discard', async t => {
  for (const invalidateHistory of [false, true]) {
    await t.test(invalidateHistory ? 'reorganized historical failure blocks cancellation' : 'finalized historical failure allows cancellation', async () => {
      const h = harness();
      h.state.ledger.get(HASH).receipt.status = '0x0';
      h.state.sendResults.push(Object.assign(new Error('cancelled'), { code: 4001 }));
      const session = await h.engine.prepare('Prepare bridge', [{ ...PLAN, sessionTag: 'bridge:history' }]);
      await assert.rejects(h.engine.run({ review: h.review }), /reverted and is finalized/);
      await assert.rejects(h.engine.run({ review: h.review }), /cancelled in your wallet/);
      assert.equal(h.engine.load().steps[0].state, 'rejected');
      assert.equal(h.engine.load().steps[0].attempts[0].state, 'reverted');
      if (invalidateHistory) {
        h.state.ledger.delete(HASH);
        await assert.rejects(h.engine.discardUnsubmitted(session.id), /previous transaction attempt is unresolved/);
        assert.equal(h.engine.wasDiscarded(session.id), false);
      } else {
        await h.engine.discardUnsubmitted(session.id);
        assert.equal(h.engine.wasDiscarded(session.id, 'bridge:history'), true);
      }
      assert.equal(h.state.sent.length, 2);
    });
  }
});

test('a finalized outer Safe revert never authorizes discarding its live proposal', async () => {
  const h = harness();
  h.state.code = '0x6001';
  const outerRevert = safeEvidence(HASH);
  outerRevert.receipt.status = '0x0';
  outerRevert.receipt.logs = [];
  h.state.ledger.set(HASH, outerRevert);
  const session = await h.engine.prepare('Prepare bridge', [{ ...PLAN, sessionTag: 'bridge:safe' }]);
  await assert.rejects(h.engine.run({ review: h.review }), /still unresolved/);
  await assert.rejects(h.engine.discardUnsubmitted(session.id), /may have been submitted/);
  assert.equal(h.engine.wasDiscarded(session.id), false);
  assert.equal(h.state.sent.length, 1);
});

test('a finalized inner Safe failure tied to the returned execution hash can be discarded', async () => {
  const h = harness();
  h.state.code = '0x6001';
  h.state.ledger.set(HASH, safeEvidence(HASH, FAILURE));
  const session = await h.engine.prepare('Prepare bridge', [{ ...PLAN, sessionTag: 'bridge:safe' }]);
  await assert.rejects(h.engine.run({ review: h.review }), /reverted and is finalized/);
  await h.engine.discardUnsubmitted(session.id);
  assert.equal(h.engine.wasDiscarded(session.id, 'bridge:safe'), true);
  assert.equal(h.state.sent.length, 1);
});
