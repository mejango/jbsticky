const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require.resolve('../app.js'), 'utf8');
const Bridge = require('../bridge.js');
const A = n => '0x' + BigInt(n).toString(16).padStart(40, '0');
const H = n => '0x' + Bridge.word(n);
function functionSource(name) {
  const match = new RegExp(`(?:^|\\n)(?:async )?function ${name}\\(`).exec(source);
  assert.ok(match, 'missing ' + name);
  const start = match.index + (source[match.index] === '\n' ? 1 : 0);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}

function fixture() {
  const state = { owner: A(1), journal: null, mode: 'cancel', calls: 0, rows: [], failStorage: false, staleVerifiedWrite: false };
  const store = new Map();
  const discarded = new Set();
  const fields = { 'bridge-source-token': { value: A(3) }, 'bridge-route': { value: '0' }, 'bridge-amount': { value: '100' }, 'bridge-reward-token': { value: '' } };
  const route = { source: { chainId: 1, name: 'Ethereum', rpcUrl: 'https://one.example' }, destination: { chainId: 10, name: 'OP', rpcUrl: 'https://ten.example' },
    sourceSucker: A(7), sourceToken: A(3), rewardToken: A(4), backingToken: Bridge.NATIVE, sourceMeta: { symbol: 'TOK', decimals: 0 }, rewardMeta: { symbol: 'TOK', decimals: 0 } };
  const context = { source: route.source, destination: route.destination, pocket: A(5), info: { stToken: A(6) }, owner: A(1), key: 'bridge-key' };
  const record = { metadata: H(9), amount: '100', owner: A(1), route, phase: 'prepared', journalId: 'j1', prepareData: Bridge.SEL.prepare + '00'.repeat(160) };
  const engine = {
    load: () => state.journal,
    wasDiscarded: id => { if (!id) throw new Error('Invalid transaction recovery identifier'); return discarded.has(id); },
    discardUnsubmitted: async id => {
      if (!state.journal || state.journal.id !== id || state.journal.steps.some(step => ['unknown', 'pending', 'submitting'].includes(step.state))) throw new Error('cannot discard');
      discarded.add(id); state.journal = null;
    },
    acknowledge: async id => { if (state.journal?.id === id) state.journal.acknowledged = true; },
  };
  const api = {
    prepare: async args => {
      await state.onPrepare?.();
      return { txs: [{ data: record.prepareData, to: route.sourceSucker, from: args.owner, chainId: 1, rpcUrl: route.source.rpcUrl, sessionTag: 'sticky-bridge:' + args.metadata }] };
    },
    movements: async () => { state.movementReads = (state.movementReads || 0) + 1; return state.rows; },
    validateRoute: async () => {},
    verifySource: async (_route, row) => { if (!row.valid) throw new Error('not canonical'); },
  };
  const ctx = vm.createContext({
    StickyBridge: Bridge, Uint8Array,
    crypto: { getRandomValues: value => value.fill(17) },
    navigator: { locks: { request: async (_name, _opts, fn) => fn({}) } },
    localStorage: { getItem: key => store.get(key) ?? null, setItem: (key, value) => { if (state.failStorage) throw new Error('storage unavailable'); store.set(key, value); } },
    $: id => fields[id] ||= { value: '' },
    txAccount: () => state.owner,
    getTxEngine: () => engine,
    getBridgeApi: () => api,
    bridgeContext: async () => context,
    rehydrateBridgeRoute: value => value,
    bridgeRoutes: [route], bridgeDisplayedRows: [],
    parseUnits: value => BigInt(value), formatUnits: value => String(value),
    encAddress: value => value.slice(2).padStart(64, '0'), stickyLabel: () => 'Sticky Token',
    txStatus: () => {}, renderRewards: async () => {},
    confirmAndRun: async (_title, txs, _summary, hooks = {}) => {
      state.calls++;
      if (txs[0].from !== state.owner) throw new Error('account changed');
      if (state.mode === 'other-plan') { state.journal = { id: 'other', steps: [{ tx: { sessionTag: 'other' }, state: 'pending' }] }; throw new Error('other plan won'); }
      state.journal = { id: 'j1', title: 'Bridge', summary: [], steps: txs.map(tx => ({ tx, state: 'ready', attempts: [] })) };
      await hooks.onPrepared?.(state.journal);
      if (state.mode === 'unknown' || state.mode === 'rejected') {
        state.journal.steps[0].state = state.mode; state.journal.steps[0].submission = { nonceFloor: '0x1' };
        throw new Error(state.mode);
      }
      return false;
    },
  });
  const names = ['bridgeRecords', 'saveBridgeRecords', 'mutateBridgeRecords', 'canDiscardBridgeJournal', 'discardBridgeDraft', 'bridgeRouteId', 'reconcileBridgeRecord', 'prepareBridgeFunding', 'actOnBridgeMovement'];
  vm.runInContext(names.map(functionSource).join('\n'), ctx);
  const records = () => JSON.parse(store.get(context.key) || '[]');
  const save = values => store.set(context.key, JSON.stringify(values));
  return { ctx, state, engine, route, record, context, fields, store, records, save, discarded };
}

test('wallet-account change during bridge quote leaves no orphaned recovery record', async () => {
  const f = fixture();
  f.state.onPrepare = () => { f.state.owner = A(2); };
  await assert.rejects(f.ctx.prepareBridgeFunding(), /account changed/);
  assert.equal(f.records().length, 0);
  assert.equal(f.state.journal, null);
});

test('another transaction winning journal publication does not strand the bridge draft', async () => {
  const f = fixture(); f.state.mode = 'other-plan';
  await assert.rejects(f.ctx.prepareBridgeFunding(), /other plan won/);
  assert.equal(f.records().length, 0);
  assert.equal(f.state.journal.id, 'other');
});

test('cancelled review records atomic discard before deleting bridge metadata', async () => {
  const f = fixture();
  await f.ctx.prepareBridgeFunding();
  assert.equal(f.records().length, 0);
  assert.equal(f.state.journal, null);
  assert.ok(f.discarded.has('j1'));
});

test('unknown wallet outcomes retain the exact prepared reference and journal', async () => {
  const f = fixture(); f.state.mode = 'unknown';
  await assert.rejects(f.ctx.prepareBridgeFunding(), /unknown/);
  const [record] = f.records();
  assert.equal(record.phase, 'prepared');
  assert.equal(record.journalId, 'j1');
  assert.ok(record.prepareData.startsWith(Bridge.SEL.prepare));
  assert.equal(await f.ctx.discardBridgeDraft(f.context, record), false);
  assert.equal(f.records().length, 1);
});

test('a wallet rejection can safely cancel its draft despite the retained submission context', async () => {
  const f = fixture(); f.state.mode = 'rejected';
  await assert.rejects(f.ctx.prepareBridgeFunding(), /rejected/);
  const [record] = f.records();
  assert.equal(await f.ctx.discardBridgeDraft(f.context, record), true);
  assert.equal(f.records().length, 0);
});

test('crash after journal discard but before metadata removal recovers from the tombstone', async () => {
  const f = fixture(); f.save([f.record]);
  f.discarded.add('j1');
  f.ctx.bridgeDisplayedRows = [{ route: f.route, record: f.record, status: 'recover' }];
  await f.ctx.actOnBridgeMovement(0);
  assert.equal(f.records().length, 0);
  assert.equal(f.state.calls, 0);
});

test('crash before publication can clear a created draft without sending', async () => {
  const f = fixture(); const record = { ...f.record, phase: 'created', journalId: undefined };
  f.save([record]); f.ctx.bridgeDisplayedRows = [{ route: f.route, record, status: 'recover' }];
  await f.ctx.actOnBridgeMovement(0);
  assert.equal(f.records().length, 0);
  assert.equal(f.state.calls, 0);
});

test('missing prepared wallet data has no fabricated safe reset', async () => {
  const f = fixture(); f.save([f.record]);
  f.ctx.bridgeDisplayedRows = [{ route: f.route, record: f.record, status: 'recover' }];
  await assert.rejects(f.ctx.actOnBridgeMovement(0), /wallet record is unavailable/);
  assert.equal(f.records().length, 1);
});

test('a created record with historical source evidence cannot be mistaken for an unsubmitted draft after a reorg', async () => {
  const f = fixture(); const record = { ...f.record, phase: 'created', journalId: undefined, sourceHash: H(55), sourceVerified: false };
  f.save([record]); f.ctx.bridgeDisplayedRows = [{ route: f.route, record, status: 'recover' }];
  await assert.rejects(f.ctx.actOnBridgeMovement(0), /wallet record is unavailable/);
  assert.equal(f.records().length, 1);
});

test('draft cleanup rechecks current durable history instead of trusting an old rendered row', async () => {
  const f = fixture(); const oldRecord = { ...f.record, phase: 'created', journalId: undefined };
  f.save([{ ...oldRecord, phase: 'submitted', sourceHash: H(55) }]);
  f.ctx.bridgeDisplayedRows = [{ route: f.route, record: oldRecord, status: 'recover' }];
  await assert.rejects(f.ctx.actOnBridgeMovement(0), /wallet history/);
  assert.equal(f.records().length, 1);
});

test('history limit is enforced before requesting any new wallet plan', async () => {
  const f = fixture(); f.save(Array.from({ length: 100 }, (_, i) => ({ ...f.record, metadata: H(i + 1), sourceVerified: true })));
  await assert.rejects(f.ctx.prepareBridgeFunding(), /history is full/);
  assert.equal(f.records().length, 100);
  assert.equal(f.state.calls, 0);
});

test('a disappeared or noncanonical source transfer keeps historical hash but blocks another prepare', async () => {
  const f = fixture(); f.save([{ ...f.record, sourceHash: H(55), sourceVerified: true }]);
  await assert.rejects(f.ctx.prepareBridgeFunding(), /Recover the saved origin transfer/);
  assert.equal(f.records()[0].sourceHash, H(55));
  assert.equal(f.records()[0].sourceVerified, false);
  assert.equal(f.state.calls, 0);
});

test('an unrelated donor copying metadata cannot release the saved transfer', async () => {
  const f = fixture(); f.save([f.record]);
  const row = { caller: A(999), valid: true, leaf: { metadata: f.record.metadata, projectTokenCount: 100n, beneficiary: '0x' + A(5).slice(2).padStart(64, '0') } };
  assert.equal(await f.ctx.reconcileBridgeRecord(f.context, f.record, [row]), false);
  assert.equal(f.records()[0].sourceVerified, false);
});

test('concurrent metadata mutations merge under the shared storage lock', async () => {
  const f = fixture();
  await Promise.all([
    f.ctx.mutateBridgeRecords(f.context.key, records => [...records, f.record]),
    f.ctx.mutateBridgeRecords(f.context.key, records => [...records, { ...f.record, metadata: H(10) }]),
  ]);
  assert.equal(f.records().length, 2);
});
