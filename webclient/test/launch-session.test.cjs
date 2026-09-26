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

// Juicebox Center listings (project intents).
const INTENT = '0f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b';
function listed(mode = 'direct', center = { state: 'pending', envelope: { format: 'sticky.center/deploy.v1' } }) {
  return { ...input(mode === 'center' ? 'relayr' : mode), mode, center };
}
function listingMock(calls, overrides = {}) {
  return {
    forwarder: address('f'),
    publish: async () => { calls.push('publish'); return { intentId: INTENT }; },
    record: async (session, chainId, result) => { calls.push(`record:${chainId}:${result.hash}`); return { status: 'recorded' }; },
    deploy: async () => { calls.push('deploy'); return { deploys: [] }; },
    status: async () => { calls.push('status'); return { deployments: [], deploys: [] }; },
    ...overrides,
  };
}
const sending = (calls, hashValue = hash('b')) => async (session, { beforeSend }) => {
  calls.push('review'); await beforeSend(); calls.push('send');
  return { status: 'confirmed', hash: hashValue };
};

test('a direct launch signs the listing after review and before sending, then records its chain once', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls), runDirect: sending(calls) });
  f.controller.prepare(listed());
  const state = await f.controller.run();
  assert.deepEqual(calls, ['review', 'publish', 'send', `record:1:${hash('b')}`]);
  assert.equal(state.center.state, 'published');
  assert.equal(state.center.intentId, INTENT);
  assert.deepEqual(state.center.recorded, { 1: hash('b') });
  await f.controller.refresh(); await f.controller.run();
  assert.equal(calls.filter((call) => call === 'publish').length, 1);
  assert.equal(calls.filter((call) => call.startsWith('record')).length, 1);
  assert.equal(Launch.needsPolling(f.store.load()), false);
});

test('Center refusing or unreachable never blocks a self-paid launch; retry lists and records it later', async () => {
  const calls = [];
  let up = false;
  const listing = listingMock(calls, { publish: async () => { calls.push('publish'); if (!up) throw new Error('Juicebox Center could not be reached.'); return { intentId: INTENT }; } });
  const f = fixture({ listing, runDirect: sending(calls) });
  f.controller.prepare(listed());
  const state = await f.controller.run();
  assert.equal(state.results[1].status, 'confirmed');
  assert.deepEqual(calls, ['review', 'publish', 'send']);
  assert.equal(state.center.state, 'unlisted');
  assert.equal(state.center.error, 'Juicebox Center could not be reached.');
  assert.equal(Launch.needsPolling(state), false, 'a refused listing is not retried in the background');
  up = true;
  const retried = await f.controller.list();
  assert.equal(retried.center.state, 'published');
  assert.deepEqual(retried.center.recorded, { 1: hash('b') });
  assert.equal(calls.filter((call) => call === 'publish').length, 2);
});

test('a record Center refuses keeps the listing ID; retry records without signing again', async () => {
  const calls = [];
  let refuse = true;
  const listing = listingMock(calls, { record: async (s, chainId) => { calls.push(`record:${chainId}`); if (refuse) throw new Error('Juicebox Center could not be reached.'); return { status: 'recorded' }; } });
  const f = fixture({ listing, runDirect: sending(calls) });
  f.controller.prepare(listed());
  const state = await f.controller.run();
  assert.equal(state.center.state, 'unlisted');
  assert.equal(state.center.intentId, INTENT);
  refuse = false;
  const retried = await f.controller.list();
  assert.equal(retried.center.state, 'published');
  assert.deepEqual(Object.keys(retried.center.recorded), ['1']);
  assert.equal(calls.filter((call) => call === 'publish').length, 1);
});

test('after a reload, a listing waiting for confirmations records exactly once', async () => {
  const calls = [];
  let confirmations = 1;
  const record = async (s, chainId) => { calls.push(`record:${chainId}`); return { status: confirmations < 2 ? 'wait' : 'recorded' }; };
  const f = fixture({ listing: listingMock(calls, { record }), runDirect: sending(calls) });
  f.controller.prepare(listed());
  const state = await f.controller.run();
  assert.deepEqual(state.center.recorded, {});
  assert.equal(Launch.needsPolling(state), true);
  // Reload: a new controller over the same browser storage.
  const again = [];
  const reloaded = fixture({ listing: listingMock(again, { record: async (s, chainId) => { again.push(`record:${chainId}`); return { status: confirmations < 2 ? 'wait' : 'recorded' }; } }),
    runDirect: async () => assert.fail('a reload never sends again') }, f.disk);
  confirmations = 2;
  await reloaded.controller.refresh();
  await reloaded.controller.refresh();
  await reloaded.controller.run();
  assert.deepEqual(again, ['record:1']);
  assert.ok(!again.includes('publish'));
  assert.deepEqual(reloaded.store.load().center.recorded, { 1: hash('b') });
  assert.equal(Launch.needsPolling(reloaded.store.load()), false);
});

test('a reload after signing but before sending resumes without publishing again', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls), runDirect: async (session, { beforeSend }) => { await beforeSend(); throw new Error('tab closed'); } });
  f.controller.prepare(listed());
  await assert.rejects(f.controller.run(), /tab closed/);
  assert.equal(f.store.load().center.state, 'published');
  const next = [];
  const reloaded = fixture({ listing: listingMock(next), runDirect: sending(next) }, f.disk);
  await reloaded.controller.run();
  assert.deepEqual(next, ['review', 'send', `record:1:${hash('b')}`]);
});

test('a Relayr launch signs the listing before paying and records every chain', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls), runPayment: async (session, { beforeSend }) => {
    calls.push('review'); await beforeSend(); calls.push('pay'); return { status: 'confirmed', hash: hash('a') };
  } });
  f.controller.prepare(listed('relayr'));
  await f.controller.run();
  assert.ok(calls.indexOf('publish') < calls.indexOf('pay'));
  f.rows([{ request: { chain: 1 }, hash: hash('b') }, { request: { chain: 10 }, hash: hash('c') }]);
  const state = await f.controller.refresh();
  assert.deepEqual(state.center.recorded, { 1: hash('b'), 10: hash('c') });
  assert.equal(Launch.needsPolling(state), false);
});

test('a launch whose listing was never signed is marked unlisted when it completes', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls), runDirect: async () => ({ status: 'confirmed', hash: hash('b') }) });
  f.controller.prepare(listed());
  const state = await f.controller.run();
  assert.equal(state.center.state, 'unlisted');
  assert.deepEqual(calls, []);
});

test('an unavailable listing never calls Center', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls), runDirect: sending(calls) });
  f.controller.prepare(listed('direct', { state: 'unavailable', reason: 'contract wallet' }));
  const state = await f.controller.run();
  assert.equal(state.center.state, 'unavailable');
  assert.deepEqual(calls, ['review', 'send']);
  assert.equal((await f.controller.list()).center.state, 'unavailable');
});

test('a sponsored launch publishes, asks Center to deploy, and verifies forwarded deployments', async () => {
  const calls = [];
  const verified = [];
  const status = async () => ({ deployments: [{ chainId: 1, transactionHash: hash('b') }], deploys: [{ chainId: 10, status: 'sent', transactionHash: hash('C') }] });
  const f = fixture({ listing: listingMock(calls, { status }),
    relayr: { verifyDeployment: async (txHash, entry, expected) => { verified.push(expected.forwarder); return { status: 'confirmed', hash: txHash, projectId: '7' }; } },
    runDirect: async () => assert.fail('no wallet transaction'), runPayment: async () => assert.fail('no wallet payment') });
  f.controller.prepare(listed('center'));
  const state = await f.controller.run();
  assert.deepEqual(calls.slice(0, 2), ['publish', 'deploy']);
  assert.equal(state.mode, 'center');
  assert.deepEqual(state.candidates[10], [hash('c')]);
  assert.ok(verified.every((forwarder) => forwarder === address('f')));
  assert.deepEqual(state.center.recorded, { 1: hash('b'), 10: hash('c') });
  assert.ok(!calls.some((call) => call.startsWith('record')), 'Center records its own deployments');
  assert.equal(Launch.canClear({ ...state, results: {} }), false);
});

test('a sponsored deploy still pending after a reload is polled and never requested twice', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls) });
  f.controller.prepare(listed('center'));
  await f.controller.run();
  assert.equal(Launch.needsPolling(f.store.load()), true);
  await f.controller.run();
  assert.equal(calls.filter((call) => call === 'deploy').length, 1);
});

test('Center refusing to sponsor before anything is queued falls back to a self-paid launch', async () => {
  const calls = [];
  const deploy = async () => { calls.push('deploy'); throw Object.assign(new Error('not sponsored'), { status: 400 }); };
  const f = fixture({ listing: listingMock(calls, { deploy }) });
  f.controller.prepare(listed('center'));
  const state = await f.controller.run();
  assert.equal(state.mode, 'relayr');
  assert.equal(state.center.state, 'published');
  assert.match(state.center.error, /could not sponsor/);
  assert.ok(f.calls.includes('post') && f.calls.includes('pay'));
});

test('an unknown sponsored deploy outcome is kept for a retry, not replaced by a paid launch', async () => {
  const calls = [];
  const deploy = async () => { calls.push('deploy'); throw Object.assign(new Error('Juicebox Center could not be reached.'), { status: 0 }); };
  const f = fixture({ listing: listingMock(calls, { deploy }) });
  f.controller.prepare(listed('center'));
  await assert.rejects(f.controller.run(), /could not be reached/);
  assert.equal(f.store.load().mode, 'center');
  assert.ok(!f.calls.includes('post'));
});

test('a sponsored listing Center refuses falls back to a self-paid, unlisted launch', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls, { publish: async () => { throw new Error('Juicebox Center does not accept listings from this site yet.'); } }),
    runDirect: sending(calls) });
  f.controller.prepare({ ...listed('direct'), mode: 'center' });
  const state = await f.controller.run();
  assert.equal(state.mode, 'direct');
  assert.equal(state.center.state, 'unlisted');
  assert.equal(state.results[1].status, 'confirmed');
});

// Center accepted a sponsored launch but its sponsor cannot pay yet: the rows wait, with an error.
const unfunded = (chainIds, extra = {}) => ({ deployments: [], deploys: chainIds.map((chainId) => ({ chainId, status: 'queued',
  transactionHash: null, bundleUuid: null, error: 'SPONSOR_UNFUNDED', ...extra })) });
const respecting = (calls, hashValue = hash('b')) => async (session, { beforeSend }) => {
  calls.push('review');
  if ((await beforeSend()) === false) return { status: 'cancelled' };
  calls.push('send');
  return { status: 'confirmed', hash: hashValue };
};

test('a queued sponsored row with an error is surfaced in plain words and offers a self-paid launch', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls, { status: async () => { calls.push('status'); return unfunded([1]); } }),
    runDirect: async () => assert.fail('nothing is sent until the holder chooses') });
  f.controller.prepare({ ...listed('direct'), mode: 'center' });
  const state = await f.controller.run();
  assert.equal(state.mode, 'center');
  assert.equal(state.center.sponsor.note, "Juicebox Center can't cover this launch right now.");
  assert.equal(state.center.sponsor.selfPay, true);
  assert.equal(state.lastStatusError, null);
  assert.equal(Launch.canClear(state), false, 'Center may still deploy it');
  assert.equal(Launch.needsPolling(state), true);
});

test('launching it yourself sends the same listed call, checks Center first, and records it on the same listing', async () => {
  const calls = [];
  const sent = [];
  const status = async () => { calls.push('status'); return unfunded([1]); };
  const f = fixture({ listing: listingMock(calls, { status }),
    runDirect: async (session, options) => { sent.push(session.txs.map((tx) => tx.data)); return respecting(calls)(session, options); } });
  f.controller.prepare({ ...listed('direct'), mode: 'center' });
  const before = await f.controller.run();
  const state = await f.controller.selfPay();
  assert.equal(state.mode, 'direct');
  assert.equal(state.center.intentId, INTENT);
  assert.equal(state.center.selfPaid, true);
  assert.deepEqual(sent, [before.txs.map((tx) => tx.data)]);
  assert.ok(calls.lastIndexOf('status') < calls.indexOf('send'), 'Center is checked right before sending');
  assert.deepEqual(calls.filter((call) => call === 'deploy' || call === 'publish'), ['publish', 'deploy']);
  assert.deepEqual(state.center.recorded, { 1: hash('b') });
  assert.ok(calls.includes(`record:1:${hash('b')}`));
  assert.equal(Launch.complete(state), true);
});

test('a multichain launch falls back to one Relayr bundle for the same calls', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls, { status: async () => unfunded([1, 10]) }),
    runPayment: async (session, options) => { calls.push('pay-review'); if ((await options.beforeSend()) === false) return { status: 'cancelled' }; calls.push('pay'); return { status: 'confirmed', hash: hash('a') }; } });
  f.controller.prepare(listed('center'));
  await f.controller.run();
  const state = await f.controller.selfPay();
  assert.equal(state.mode, 'relayr');
  assert.equal(f.calls.filter((call) => call === 'post').length, 1);
  assert.deepEqual(calls.filter((call) => call === 'pay'), ['pay']);
});

test('the self-paid launch is refused once Center has started or paid for it', async () => {
  for (const started of [{ bundleUuid: 'b0c1d2e3-0000-4000-8000-000000000000' }, { status: 'sent', transactionHash: hash('c') }]) {
    const calls = [];
    const f = fixture({ listing: listingMock(calls, { status: async () => unfunded([1], started) }),
      runDirect: async () => assert.fail('never sent') });
    f.controller.prepare({ ...listed('direct'), mode: 'center' });
    const state = await f.controller.run();
    assert.equal(state.center.sponsor.selfPay, false);
    await assert.rejects(f.controller.selfPay(), /has started this launch/);
    assert.equal(f.store.load().mode, 'center');
  }
});

test('Center starting between the review and the send cancels the send and goes back to waiting', async () => {
  const calls = [];
  let rows = unfunded([1]);
  const f = fixture({ listing: listingMock(calls, { status: async () => rows }),
    runDirect: async (session, options) => { rows = unfunded([1], { status: 'sent', transactionHash: hash('c'), error: null }); return respecting(calls)(session, options); } });
  f.controller.prepare({ ...listed('direct'), mode: 'center' });
  await f.controller.run();
  const state = await f.controller.selfPay();
  assert.ok(!calls.includes('send'));
  assert.equal(state.mode, 'center');
  assert.equal(state.center.selfPaid, false);
  assert.equal(state.directIntent, false);
  assert.equal(Launch.needsPolling(state), true);
});

test('a self-paid choice survives a reload and sends exactly once', async () => {
  const calls = [];
  const listing = listingMock(calls, { status: async () => unfunded([1]) });
  const first = fixture({ listing, runDirect: async () => { throw new Error('tab closed'); } });
  first.controller.prepare({ ...listed('direct'), mode: 'center' });
  await first.controller.run();
  await assert.rejects(first.controller.selfPay(), /tab closed/);
  assert.equal(first.store.load().mode, 'direct');
  let sends = 0;
  const reloaded = fixture({ listing, runDirect: async (session, options) => { sends++; return respecting(calls)(session, options); } }, first.disk);
  const state = await reloaded.controller.run();
  await reloaded.controller.run();
  assert.equal(sends, 1);
  assert.equal(Launch.complete(state), true);
  assert.equal(calls.filter((call) => call === 'deploy').length, 1);
});

test('failed sponsored rows with nothing deployed can be launched yourself or discarded', async () => {
  const calls = [];
  const f = fixture({ listing: listingMock(calls, { status: async () => unfunded([1], { status: 'failed', error: 'retries exhausted' }) }) });
  f.controller.prepare({ ...listed('direct'), mode: 'center' });
  const state = await f.controller.run();
  assert.equal(state.center.sponsor.note, 'Juicebox Center could not deploy on 1.');
  assert.equal(state.center.sponsor.selfPay, true);
  assert.equal(Launch.canClear(state), true);
});

test('a sponsored launch is reviewed before its listing is signed', async () => {
  const calls = [];
  const declined = fixture({ listing: listingMock(calls), reviewSponsored: async () => { calls.push('review'); return false; } });
  declined.controller.prepare(listed('center'));
  const state = await declined.controller.run();
  assert.deepEqual(calls, ['review']);
  assert.equal(state.center.state, 'pending');
  assert.equal(Launch.canClear(state), true);
  const confirmedCalls = [];
  const confirmed = fixture({ listing: listingMock(confirmedCalls),
    reviewSponsored: async (session, sign) => { confirmedCalls.push('review'); await sign(); confirmedCalls.push('signed'); return true; } });
  confirmed.controller.prepare(listed('center'));
  await confirmed.controller.run();
  assert.deepEqual(confirmedCalls.slice(0, 4), ['review', 'publish', 'signed', 'deploy']);
});

test('stored listings are validated', () => {
  const disk = storage();
  const store = Launch.createStore(disk);
  const base = { ...input('direct'), version: 1, published: false, results: {}, candidates: { 1: [] } };
  store.save({ ...base, center: { state: 'published', intentId: INTENT, recorded: {} } });
  for (const center of [{ state: 'odd', intentId: null, recorded: {} }, { state: 'published', intentId: null, recorded: {} }, { state: 'pending', intentId: 5, recorded: {} }, { state: 'pending', intentId: null }]) {
    assert.throws(() => store.save({ ...base, center }), /listing is invalid/);
  }
  assert.throws(() => store.save({ ...base, mode: 'center', center: { state: 'unavailable', intentId: null, recorded: {} } }), /sponsored/);
});
