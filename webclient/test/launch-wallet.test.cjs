const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require.resolve('../app.js'), 'utf8');
const begin = source.indexOf('async function runStickyLaunchWallet(');
const end = source.indexOf('\nasync function pollStickyLaunchProgress', begin);
const fn = source.slice(begin, end);
const owner = '0x' + '1'.repeat(40), hash = '0x' + 'a'.repeat(64);
function make(state, overrides = {}) {
  let calls = 0;
  const session = state ? { steps: [{ state, tx: { sessionTag: 'saved-launch' }, ...(state === 'confirmed' ? { receipt: { transactionHash: hash } } : {}), ...(state === 'pending' ? { hash } : {}) }] } : null;
  const context = vm.createContext({ txAccount: () => owner, getTxEngine: () => ({ load: () => session }),
    confirmAndRun: async () => { calls++; return false; }, $: () => ({}), ...overrides });
  vm.runInContext(fn, context);
  return { run: (recovering = true) => context.runStickyLaunchWallet({ id: 'saved-launch', owner, symbol: 'S', summary: [] }, [{}], { recovering }), calls: () => calls };
}

test('closing a pending payment review preserves its hash and recovery intent', async () => {
  const f = make('pending'); const result = await f.run();
  assert.equal(result.status, 'pending'); assert.equal(result.hash, hash);
});
test('closing an unknown payment review never reports a safe cancellation', async () => {
  const f = make('unknown'); assert.equal((await f.run()).status, 'pending');
});
test('closing an already confirmed payment review still returns its canonical receipt', async () => {
  const f = make('confirmed'); const result = await f.run();
  assert.equal(result.status, 'confirmed'); assert.equal(result.hash, hash);
});
test('closing an unsent or wallet-rejected payment review safely cancels the intent', async () => {
  for (const state of ['ready', 'rejected']) assert.equal((await make(state).run()).status, 'cancelled');
});
test('missing wallet journal after reload blocks new payment submission', async () => {
  const f = make(null); await assert.rejects(f.run(), /wallet transaction record is missing/);
  assert.equal(f.calls(), 0);
});
test('another account cannot resume the frozen launch payment', async () => {
  const f = make('ready', { txAccount: () => '0x' + '2'.repeat(40) });
  await assert.rejects(f.run(), /Connect/); assert.equal(f.calls(), 0);
});
test('preparation failure before a tagged wallet plan exists safely releases its payment intent', async () => {
  const f = make(null, { confirmAndRun: async () => { throw new Error('unrelated transaction pending'); } });
  assert.equal((await f.run(false)).status, 'cancelled');
});

test('a quote finishing after its dialog closes cannot leave an invisible picker holding the launch lock', () => {
  const start = source.indexOf('function chooseStickyLaunchPayment(');
  const stop = source.indexOf('\nasync function runStickyLaunchPayment', start);
  const context = vm.createContext({ $: () => ({ open: false }),
    stickyLaunchRelayr: () => { throw new Error('closed review must not create a picker'); } });
  vm.runInContext(source.slice(start, stop), context);
  assert.equal(context.chooseStickyLaunchPayment([{ chain: 1 }], {}), null);
});
