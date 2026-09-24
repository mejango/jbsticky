'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { createEngine } = require('../tx-engine.js');

const OWNER = '0x' + '11'.repeat(20);
const TARGET = '0x' + '22'.repeat(20);
const EXECUTOR = '0x' + '33'.repeat(20);
const PROPOSAL = '0x' + 'aa'.repeat(32);
const OTHER_PROPOSAL = '0x' + 'bb'.repeat(32);
const EXECUTION = '0x' + 'cc'.repeat(32);
const BLOCK = '0x' + 'dd'.repeat(32);
const SUCCESS = '0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e';
const word = value => BigInt(value).toString(16).padStart(64, '0');
const tail = data => word(data.length / 2) + data.padEnd(Math.ceil(data.length / 64) * 64, '0');
const PLAN = { chainId: 1, from: OWNER, to: TARGET, data: '0x1234', value: '0x9', rpcUrl: 'https://rpc.example.test' };

function harness({ safe = false, unknown = false, failed = false, proposal = PROPOSAL } = {}) {
  const values = new Map();
  const storage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
  const dynamicData = tail(PLAN.data.slice(2));
  const safeInput = '0x6a761202' + [word(BigInt(TARGET)), word(9), word(320), word(0), word(100000), word(0), word(0),
    word(0), word(0), word(320 + dynamicData.length / 2)].join('') + dynamicData + tail('11'.repeat(65));
  const transaction = {
    hash: EXECUTION, from: safe ? EXECUTOR : OWNER, to: safe ? OWNER : TARGET,
    input: safe ? safeInput : PLAN.data, value: safe ? '0x0' : PLAN.value, nonce: '0x7', chainId: '0x1', blockNumber: '0x11', blockHash: BLOCK,
  };
  const receipt = {
    transactionHash: EXECUTION, blockNumber: '0x11', blockHash: BLOCK, status: failed ? '0x0' : '0x1',
    logs: safe ? [{ address: OWNER, topics: [SUCCESS], data: proposal + word(0) }] : [],
  };
  let reportedTransaction = null;
  let sends = 0;
  const wallet = { request: async ({ method }) => {
    if (method === 'eth_accounts') return [OWNER];
    if (method === 'eth_chainId') return '0x1';
    if (method === 'eth_sendTransaction') {
      sends++;
      if (unknown) throw new Error('Wallet disconnected after submitting');
      return PROPOSAL;
    }
    throw new Error('Unexpected wallet method ' + method);
  } };
  const engine = createEngine({
    storage, wallet: () => wallet, locks: { request: async (_name, _options, fn) => fn({}) },
    ensureChain: async () => {}, randomId: () => 'adversarial-recovery', pollAttempts: 1,
    rpc: async (_tx, method, params) => {
      if (method === 'eth_chainId') return '0x1';
      if (method === 'eth_call') return '0x';
      if (method === 'eth_blockNumber') return '0x10';
      if (method === 'eth_getTransactionCount') return '0x7';
      if (method === 'eth_getCode') return safe ? '0x6001' : '0x';
      if (method === 'eth_getTransactionByHash') return params[0] === EXECUTION ? transaction
        : params[0] === PROPOSAL ? reportedTransaction : null;
      if (method === 'eth_getTransactionReceipt') return params[0] === EXECUTION ? receipt : null;
      if (method === 'eth_getBlockByNumber') return { number: params[0] === 'finalized' ? '0x20' : '0x11', hash: BLOCK };
      throw new Error('Unexpected RPC method ' + method);
    },
  });
  return { engine, transaction, sends: () => sends, setReportedTransaction: value => { reportedTransaction = value; } };
}

test('a distinct successful Safe proposal cannot complete a still-live saved proposal with identical calldata', async () => {
  const { engine, sends } = harness({ safe: true, proposal: OTHER_PROPOSAL });
  await engine.prepare('Fund rewards', [PLAN]);
  await assert.rejects(engine.run({ review: async () => true }), /still unresolved/);
  await assert.rejects(engine.recover(EXECUTION), /does not prove/);
  assert.equal(engine.load().steps[0].state, 'pending');
  assert.equal(sends(), 1);
});

test('an exact successful Safe event can identify the returned wallet reference as its proposal hash', async () => {
  const { engine, sends } = harness({ safe: true });
  await engine.prepare('Fund rewards', [PLAN]);
  await assert.rejects(engine.run({ review: async () => true }), /still unresolved/);
  await engine.recover(EXECUTION);
  assert.equal(engine.load().steps[0].state, 'confirmed');
  assert.equal(sends(), 1);
});

test('a missing wallet hash can recover an exact finalized EOA revert without trapping all later transactions', async () => {
  const { engine, sends } = harness({ unknown: true, failed: true });
  await engine.prepare('Fund rewards', [PLAN]);
  await assert.rejects(engine.run({ review: async () => true }), /outcome is unknown/);
  await engine.recover(EXECUTION);
  assert.equal(engine.load().steps[0].state, 'reverted');
  await engine.clear();
  assert.equal(engine.load(), null);
  assert.equal(sends(), 1);
});

test('a Safe submission with no returned reference remains unresolved because an identical call cannot identify its proposal', async () => {
  const { engine, sends } = harness({ safe: true, unknown: true });
  await engine.prepare('Fund rewards', [PLAN]);
  await assert.rejects(engine.run({ review: async () => true }), /outcome is unknown/);
  await assert.rejects(engine.recover(EXECUTION), /does not prove/);
  assert.equal(engine.load().steps[0].state, 'unknown');
  assert.equal(sends(), 1);
});

test('an exact Safe outer replacement binds its proposal for later checks even when the replaced hash disappears', async () => {
  const h = harness({ safe: true, proposal: OTHER_PROPOSAL });
  h.setReportedTransaction({ ...h.transaction, hash: PROPOSAL, blockHash: null, blockNumber: null });
  await h.engine.prepare('Fund rewards', [PLAN]);
  await assert.rejects(h.engine.run({ review: async () => true }), /still unresolved/);
  await h.engine.recover(EXECUTION);
  assert.equal(h.engine.load().steps[0].submission.safeTxHash, OTHER_PROPOSAL);
  h.setReportedTransaction(null);
  await h.engine.run({ review: async () => true });
  assert.equal(h.engine.load().steps[0].state, 'confirmed');
  assert.equal(h.sends(), 1);
});

test('different outer executor or nonce cannot identify a replacement despite identical Safe calldata', async t => {
  for (const mutation of [{ from: TARGET }, { nonce: '0x8' }, { value: '0x1' }, { input: '0x1234' }, { hash: OTHER_PROPOSAL }]) {
    await t.test(JSON.stringify(mutation), async () => {
      const h = harness({ safe: true, proposal: OTHER_PROPOSAL });
      h.setReportedTransaction({ ...h.transaction, hash: PROPOSAL, blockHash: null, blockNumber: null, ...mutation });
      await h.engine.prepare('Fund rewards', [PLAN]);
      await assert.rejects(h.engine.run({ review: async () => true }), /still unresolved/);
      await assert.rejects(h.engine.recover(EXECUTION), /does not prove/);
      assert.equal(h.engine.load().steps[0].state, 'pending');
      assert.equal(h.sends(), 1);
    });
  }
});
