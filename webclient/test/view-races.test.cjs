'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../app.js'), 'utf8');
function functionSource(name) {
  const match = new RegExp(`(?:^|\\n)(?:async )?function ${name}\\(`).exec(source);
  assert.ok(match, `missing function ${name}`);
  const start = match.index + (source[match.index] === '\n' ? 1 : 0);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
function deferred() {
  let resolve;
  const promise = new Promise(value => { resolve = value; });
  return { promise, resolve };
}
function fixture(names = []) {
  const fields = new Map();
  const c = vm.createContext({
    ctx: { loaded: true, chainId: 1, currentId: null, pool: null },
    account: () => '0x' + '11'.repeat(20),
    location: { hash: '#/' },
    confirmResolve: null,
    closeWalletMenu() {}, clearHomeSecuredChart() {}, setTab() {}, status() {},
    homeFailed() {}, setHomeState() {}, configuredStickiestCards: () => [],
    $: id => {
      if (!fields.has(id)) fields.set(id, { textContent: '', dataset: {}, close() {}, classList: { add() {}, remove() {} } });
      return fields.get(id);
    },
    renderHome: async () => {}, renderProject: async () => {}, renderAccount: async () => {},
  });
  vm.runInContext(`let viewSequence = 0;\n${['currentView', 'route', ...names].map(functionSource).join('\n')}`, c);
  return c;
}

test('a delayed handle lookup cannot reopen its project after navigation to another project', async () => {
  const c = fixture();
  const lookup = deferred();
  const shown = [];
  c.projectIdForHandle = () => lookup.promise;
  c.renderProject = async id => { c.ctx.currentId = id; shown.push(id); };
  c.location.hash = '#/@slow';
  c.route();
  c.location.hash = '#/project/2';
  c.route();
  lookup.resolve(1n);
  await new Promise(setImmediate);
  assert.deepEqual(shown, [2n]);
  assert.equal(c.ctx.currentId, 2n);
  assert.equal(c.ctx.alias, null);
});

test('a delayed project read cannot overwrite the view or quote after navigation home', async () => {
  const c = fixture(['renderProject']);
  const info = deferred();
  c.projectInfo = () => info.promise;
  const rendering = c.renderProject(1n);
  c.route();
  info.resolve({ symbol: 'STALE' });
  await rendering;
  assert.equal(c.ctx.currentId, null);
  assert.equal(c.ctx.pool, null);
  assert.equal(c.$('h-symbol').textContent, '');
});

test('an obsolete home read cannot mount its chart after project navigation', async () => {
  const c = fixture(['renderHome']);
  const ids = deferred();
  c.projectIds = () => ids.promise;
  c.hookLogs = () => { throw new Error('obsolete home load continued'); };
  const rendering = c.renderHome();
  c.location.hash = '#/project/2';
  c.route();
  ids.resolve([]);
  await rendering;
});

test('reward reads for an old project cannot replace the current project reward controls', async () => {
  const c = fixture(['renderRewards']);
  const info = deferred();
  c.ctx.currentId = 1n;
  c.distributor = () => '0x' + '22'.repeat(20);
  c.projectInfo = () => info.promise;
  const rendering = c.renderRewards();
  c.location.hash = '#/project/2';
  c.route();
  info.resolve({ stakedToken: '0x' + '33'.repeat(20) });
  await rendering;
  assert.equal(c.$('rr-beneficiary').textContent, '');
});

test('view guards also invalidate when the account or chain changes', () => {
  const c = fixture();
  const first = c.currentView();
  assert.equal(first(), true);
  c.ctx.chainId = 10;
  assert.equal(first(), false);
  const second = c.currentView();
  c.account = () => '0x' + '44'.repeat(20);
  assert.equal(second(), false);
});

test('a superseded auto-stick render leaves the card hidden, never half drawn', async () => {
  const c = fixture(['renderAutoStick']);
  const hidden = new Set(['autostick-card']);
  const fields = new Map();
  c.$ = (id) => {
    if (!fields.has(id)) fields.set(id, { id, textContent: '', innerHTML: '', classList: {
      add: (name) => name === 'hide' && hidden.add(id), remove: (name) => name === 'hide' && hidden.delete(id),
      toggle: (name, on) => { if (name === 'hide') on ? hidden.add(id) : hidden.delete(id); } } });
    return fields.get(id);
  };
  vm.runInContext('var AS_STATUS = { INVALID_PROJECT: 1, READY: 2 };', c);
  const schedule = deferred();
  c.ctx.currentId = 1n;
  c.autoStickState = async () => ({ info: { symbol: 'CPN', decimals: 18 }, status: 2, enabled: true, minimum: 1n, cooldown: 86400 });
  c.unlockScheduleOf = () => schedule.promise;
  c.unlockScheduleSentence = () => '';
  c.vestableRewardGroups = async () => [];
  c.stickyLabel = (info) => `Sticky ${info.symbol}`;
  c.formatUnits = String; c.formatDuration = String; c.esc = String; c.asStatusLine = () => '';
  const rendering = c.renderAutoStick();
  await new Promise(setImmediate);
  c.route();
  schedule.resolve(null);
  await rendering;
  assert.ok(hidden.has('autostick-card'));
  assert.equal(c.$('as-toggle').textContent, '');
  const fresh = c.renderAutoStick();
  await fresh;
  assert.ok(!hidden.has('autostick-card'));
  assert.equal(c.$('as-toggle').textContent, 'Turn off auto-stick');
  assert.match(c.$('as-blurb').textContent, /Stick your CPN rewards into Sticky CPN as they unlock\./);
});
