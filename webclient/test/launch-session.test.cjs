const { test } = require('node:test');
const assert = require('node:assert/strict');
const Launch = require('../launch-session.js');
const address = (digit) => `0x${digit.repeat(40)}`;
const hash = (digit) => `0x${digit.repeat(64)}`;
function storage() {
  const values = new Map();
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: (key) => values.delete(key) };
}
function input(mode = 'relayr') {
  const chains = mode === 'direct' ? [1] : [1, 10];
  return { id: 'launch-id', mode, owner: address('1'), name: 'Sticky', symbol: 'STICKY', summary: [],
    fundingRpcs: { 1: 'https://rpc.ethereum.example', 10: 'https://rpc.optimism.example' },
    targets: chains.map((chainId) => ({ chainId, name: String(chainId), deployer: address('2'), controller: address('3'), projects: address('4'), rpcUrl: 'https://rpc.example', expected: { stakedToken: address('5'), cashOutTaxRate: '1000', soulbound: true } })),
    txs: chains.map((chainId) => ({ chainId, to: address('2'), data: '0x00d5ce37abcd', value: '0x1' })),
  };
}
function fixture(changes = {}, existingStorage) {
  const disk = existingStorage || storage(), store = Launch.createStore(disk);
  const calls = [];
  const payment = { chain: 1, amount: '10', calldata: '0xabc' };
  const quote = { bundle_uuid: 'quote-uuid', payment_info: [payment] };
  let rows = [];
  const relayr = {
    postBundle: async (entries, hooks) => { calls.push('post'); await hooks.beforePublish(); await hooks.onPublished(quote); return quote; },
    bindQuote: async (saved) => { calls.push('bind'); return saved; },
    fetchStatus: async () => { calls.push('status'); return rows; },
    paymentOptions: () => { calls.push('options'); return [payment]; },
    validatePayment: async () => calls.push('validate-payment'),
    verifyPayment: async () => ({ status: 'confirmed', hash: hash('a') }),
    verifyDeployment: async (txHash) => ({ status: 'confirmed', hash: txHash, projectId: '42' }),
    destinationHash: (row) => row.hash,
    ...changes.relayr,
  };
  const controller = Launch.createController({ store, relayr,
    choosePayment: async () => { calls.push('choose'); return payment; },
    runPayment: async () => { calls.push('pay'); return { status: 'confirmed', hash: hash('a') }; },
    runDirect: async () => ({ status: 'confirmed', hash: hash('b') }),
    acknowledge: async () => calls.push('ack'),
    ...changes,
    relayr,
  });
  return { controller, disk, store, calls, quote, payment, rows: (value) => { rows = value; } };
}

test('journal publication before POST, bind before funding choice, and fund exactly once', async () => {
  const f = fixture(); f.controller.prepare(input());
  const state = await f.controller.run();
  assert.equal(state.published, true);
  assert.equal(state.paymentConfirmed.status, 'confirmed');
  assert.ok(f.calls.indexOf('bind') < f.calls.indexOf('choose'));
  assert.ok(f.calls.indexOf('validate-payment') < f.calls.indexOf('pay'));
  await f.controller.run();
  assert.equal(f.calls.filter((call) => call === 'post').length, 1);
  assert.equal(f.calls.filter((call) => call === 'pay').length, 1);
});

test('unknown POST never re-posts and cannot be cleared after reload', async () => {
  const f = fixture({ relayr: { postBundle: async (_, hooks) => { await hooks.beforePublish(); throw new Error('connection lost'); } } });
  f.controller.prepare(input());
  await assert.rejects(f.controller.run(), /connection lost/);
  assert.equal(f.store.load().published, true);
  const restored = fixture({}, f.disk);
  await assert.rejects(restored.controller.run(), /quote ID was not returned/);
  assert.equal(restored.calls.includes('post'), false);
  await assert.rejects(restored.controller.clear(), /published or submitted/);
});

test('returned quote UUID is saved even if subsequent binding fails', async () => {
  const f = fixture({ relayr: { postBundle: async (_, hooks) => { await hooks.beforePublish(); await hooks.onPublished({ bundle_uuid: 'known-id' }); throw new Error('bad binding'); } } });
  f.controller.prepare(input());
  await assert.rejects(f.controller.run(), /bad binding/);
  assert.equal(f.store.load().quote.bundle_uuid, 'known-id');
  assert.equal(Launch.canClear(f.store.load()), false);
});

test('failed binding never opens funding selector', async () => {
  const f = fixture({ relayr: { bindQuote: async () => { throw new Error('wrong deployment'); } } });
  f.controller.prepare(input());
  await assert.rejects(f.controller.run(), /wrong deployment/);
  assert.equal(f.calls.includes('choose'), false);
  assert.equal(f.calls.includes('pay'), false);
});

test('quote picker cancellation preserves the one published quote and never sends', async () => {
  const f = fixture({ choosePayment: async () => null });
  f.controller.prepare(input());
  await f.controller.run(); await f.controller.run();
  assert.equal(f.calls.filter((call) => call === 'post').length, 1);
  assert.equal(f.calls.includes('pay'), false);
  assert.equal(Launch.canClear(f.store.load()), false);
});

test('wallet review cancellation can clear a payment intent but preserves published launch', async () => {
  const f = fixture({ runPayment: async () => ({ status: 'cancelled' }) });
  f.controller.prepare(input());
  await f.controller.run();
  assert.equal(f.store.load().paymentIntent, null);
  assert.equal(f.calls.includes('ack'), true);
  assert.equal(Launch.canClear(f.store.load()), false);
});

test('unknown payment retains exact choice and only invokes wallet recovery after reload', async () => {
  const f = fixture({ runPayment: async () => { throw new Error('lost wallet result'); } });
  f.controller.prepare(input());
  await assert.rejects(f.controller.run(), /lost wallet/);
  assert.deepEqual(f.store.load().paymentIntent, f.payment);
  let recovered = false;
  const next = fixture({ choosePayment: async () => { throw new Error('should not choose again'); },
    runPayment: async (_, options) => { recovered = options.recovering; return { status: 'pending' }; } }, f.disk);
  await next.controller.run();
  assert.equal(recovered, true);
  assert.equal(next.calls.includes('post'), false);
  assert.deepEqual(next.store.load().paymentIntent, f.payment);
});

test('candidate hashes survive API omissions and outages; completed chains never redeploy', async () => {
  const f = fixture(); f.controller.prepare(input()); await f.controller.run();
  f.rows([{ request: { chain: 1 }, hash: hash('b') }]);
  await f.controller.refresh();
  f.rows([]); await f.controller.refresh();
  assert.deepEqual(f.store.load().candidates[1], [hash('b')]);
  assert.equal(f.store.load().results[1].projectId, '42');
  const next = fixture({ relayr: { fetchStatus: async () => { throw new Error('offline'); } } }, f.disk);
  await next.controller.refresh();
  assert.deepEqual(next.store.load().candidates[1], [hash('b')]);
  await assert.rejects(next.controller.run(), /offline/);
  assert.equal(next.calls.includes('post'), false);
  assert.equal(next.calls.includes('pay'), false);
});

test('invalid candidate does not erase a previously verified deployment or block other candidates', async () => {
  const f = fixture({ relayr: { verifyDeployment: async (value) => { if (value === hash('c')) throw new Error('unrelated transaction'); return { status: 'confirmed', hash: value, projectId: '7' }; } } });
  f.controller.prepare(input()); await f.controller.run();
  f.rows([{ request: { chain: 1 }, hash: hash('c') }]); await f.controller.refresh();
  await f.controller.addHash(1, hash('b'));
  assert.deepEqual(f.store.load().candidates[1], [hash('c'), hash('b')]);
  assert.equal(f.store.load().results[1].projectId, '7');
});

test('canonical completion across all chains permits clear', async () => {
  const f = fixture(); f.controller.prepare(input()); await f.controller.run();
  f.rows([{ request: { chain: 1 }, hash: hash('b') }, { request: { chain: 10 }, hash: hash('c') }]);
  await f.controller.refresh();
  assert.equal(Launch.complete(f.store.load()), true);
  await f.controller.clear();
  assert.equal(f.store.load(), null);
});

test('unpublished draft may be safely discarded', async () => {
  const f = fixture(); f.controller.prepare(input()); await f.controller.clear();
  assert.equal(f.store.load(), null);
});

test('direct deployment gets durable recovery and never calls Relayr POST', async () => {
  const f = fixture(); f.controller.prepare(input('direct'));
  const state = await f.controller.run();
  assert.equal(Launch.complete(state), true);
  assert.deepEqual(state.candidates[1], [hash('b')]);
  assert.equal(f.calls.includes('post'), false);
});

test('direct unknown outcome keeps intent; direct pre-submit cancellation permits clear', async () => {
  const f = fixture({ runDirect: async () => { throw new Error('wallet unavailable'); } });
  f.controller.prepare(input('direct')); await assert.rejects(f.controller.run(), /wallet unavailable/);
  assert.equal(f.store.load().directIntent, true);
  await assert.rejects(f.controller.clear(), /published or submitted/);
  const next = fixture({ runDirect: async (_, options) => { assert.equal(options.recovering, true); return { status: 'cancelled' }; } }, f.disk);
  await next.controller.run(); await next.controller.clear();
  assert.equal(next.store.load(), null);
});

test('corrupt or unavailable browser storage prevents publication', async () => {
  const disk = storage(); disk.setItem(Launch.KEY, '{');
  const f = fixture({}, disk);
  assert.throws(() => f.controller.prepare(input()), /Cannot resume/);
  await assert.rejects(f.controller.run(), /Cannot resume/);
  assert.equal(f.calls.includes('post'), false);
  disk.removeItem(Launch.KEY);
  disk.setItem = () => { throw new Error('quota'); };
  assert.throws(() => f.controller.prepare(input()), /quota/);
  assert.equal(f.calls.includes('post'), false);
});

test('duplicate run while funding picker is open is rejected', async () => {
  let choose;
  const f = fixture({ choosePayment: () => new Promise((resolve) => { choose = resolve; }) });
  f.controller.prepare(input());
  const pending = f.controller.run();
  while (!choose) await new Promise((resolve) => setImmediate(resolve));
  await assert.rejects(f.controller.run(), /already being processed/);
  choose(null); await pending;
  assert.equal(f.calls.filter((call) => call === 'post').length, 1);
});

test('only one of the actual quoted funding choices can be paid', async () => {
  const f = fixture({ choosePayment: async () => ({ chain: 10, amount: '999' }) });
  f.controller.prepare(input());
  await assert.rejects(f.controller.run(), /quoted funding options/);
  assert.equal(f.calls.includes('pay'), false);
});

test('reorged destination evidence is downgraded while all candidate hashes survive', async () => {
  const f = fixture(); f.controller.prepare(input()); await f.controller.run();
  f.rows([{ request: { chain: 1 }, hash: hash('b') }, { request: { chain: 10 }, hash: hash('c') }]);
  await f.controller.refresh(); assert.equal(Launch.complete(f.store.load()), true);
  const restored = fixture({ relayr: { verifyDeployment: async () => ({ status: 'pending' }) } }, f.disk);
  await assert.rejects(restored.controller.clear(), /published or submitted/);
  assert.equal(Launch.complete(restored.store.load()), false);
  assert.deepEqual(restored.store.load().candidates[1], [hash('b')]);
  assert.deepEqual(restored.store.load().candidates[10], [hash('c')]);
});

test('RPC outage cannot make stale completed deployment clearable', async () => {
  const f = fixture(); f.controller.prepare(input('direct')); await f.controller.run();
  const restored = fixture({ relayr: { verifyDeployment: async () => { throw new Error('RPC unavailable'); } } }, f.disk);
  await assert.rejects(restored.controller.clear(), /published or submitted/);
  assert.equal(Launch.complete(restored.store.load()), false);
  assert.deepEqual(restored.store.load().candidates[1], [hash('b')]);
});

test('reorged payment keeps its hash and intent instead of enabling another payment choice', async () => {
  const f = fixture(); f.controller.prepare(input()); await f.controller.run();
  const restored = fixture({ relayr: { verifyPayment: async () => ({ status: 'pending' }) },
    runPayment: async (_, options) => { assert.equal(options.recovering, true); return { status: 'pending' }; },
    choosePayment: async () => { throw new Error('new payment forbidden'); } }, f.disk);
  await restored.controller.run();
  assert.equal(restored.store.load().paymentConfirmed, null);
  assert.equal(restored.store.load().paymentHash, hash('a'));
  assert.deepEqual(restored.store.load().paymentIntent, f.payment);
});

test('session and real Relayr protocol bind reordered records before offering the quoted payment', async () => {
  const R = require('../relayr.js');
  const disk = storage(), store = Launch.createStore(disk);
  const draft = input(), entries = R.orderedEntries(Launch.entriesOf(draft));
  const bundle = '12345678-1234-1234-1234-123456789012';
  const ids = ['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'];
  const deadline = Math.floor(Date.now() / 1000) + 3600;
  const payment = { chain: 1, target: R.PAYMENT_ADDRESS, token: R.NATIVE_TOKEN, amount: '100000000000000001',
    calldata: R.PAYMENT_SELECTOR + bundle.replaceAll('-', '') + '0'.repeat(32) + BigInt(deadline).toString(16).padStart(64, '0'),
    payment_deadline: new Date(deadline * 1000).toISOString() };
  let posts = 0, picks = 0, partial = false;
  const relayr = R.createClient({ rpc: async () => { throw new Error('No wallet action authorized in this test'); }, fetch: async (_, options) => {
    if (options.method === 'POST') {
      assert.equal(store.load().published, true);
      posts++;
      return { ok: true, json: async () => ({ bundle_uuid: bundle, tx_uuids: ids, payment_info: [payment] }) };
    }
    const transactions = entries.map((entry, i) => ({ tx_uuid: ids[i], request: entry, status: { state: 'Pending' } })).reverse();
    return { ok: true, json: async () => ({ bundle_uuid: bundle, transactions: partial ? transactions.slice(0, 1) : transactions }) };
  } });
  const controller = Launch.createController({ store, relayr, choosePayment: async (options) => {
    picks++; assert.deepEqual(options, [payment]);
    assert.equal(store.load().quote.expectedTransactions.length, 2);
    return null;
  }, runPayment: async () => { throw new Error('Payment must not be sent'); } });
  controller.prepare(draft); await controller.run();
  partial = true;
  await controller.run();
  assert.equal(posts, 1);
  assert.equal(picks, 2);
  assert.equal(store.load().quote.expectedTransactions[0].chain, 1);
});
