'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const Runtime = require('../runtime.js');

const source = fs.readFileSync(path.join(__dirname, '../app.js'), 'utf8');
function functionSource(name) {
  const match = new RegExp(`(?:^|\\n)(?:async )?function ${name}\\(`).exec(source);
  assert.ok(match, `missing function ${name}`);
  const start = match.index + (source[match.index] === '\n' ? 1 : 0);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
const block = (start) => {
  const at = source.indexOf(start);
  assert.ok(at >= 0, `missing ${start}`);
  return source.slice(at, source.indexOf('\n};', at) + 3);
};
const codec = source.slice(source.indexOf('const strip ='), source.indexOf('// ------------------------------------------------------------- rpc plumbing'));

const word = (value) => BigInt(value).toString(16).padStart(64, '0');
const addr = (digit) => '0x' + digit.repeat(40);
const HOLDER_A = addr('a');
const HOLDER_B = addr('b');
const HOLDER_C = addr('c');

function context(extra = {}, names = []) {
  const c = vm.createContext({ TextEncoder, TextDecoder, Uint8Array, console, StickyRuntime: Runtime, ...extra });
  vm.runInContext(`${block('const SEL =')}\n${block('const TOPIC =')}\n${codec}\n${names.map(functionSource).join('\n')}`, c);
  c.TOPIC = vm.runInContext('TOPIC', c);
  return c;
}

// ---------------------------------------------------------------- holders
function hookLog(c, topic, projectId, holder, data, ts) {
  return { topics: [c.TOPIC[topic], '0x' + word(projectId), '0x' + word(BigInt(holder))], data: '0x' + data, ts };
}

test('holders come from the hook events: last balance, live streak, and record, with no per-holder reads', () => {
  const c = context({}, ['holderRows']);
  const payer = word(BigInt(HOLDER_A));
  const logs = [
    // A: two stakes, then a partial exit. Streak from t=100.
    hookLog(c, 'StreakStarted', 7, HOLDER_A, payer, 100),
    hookLog(c, 'Staked', 7, HOLDER_A, payer + word(5n) + word(5n) + payer, 100),
    hookLog(c, 'Staked', 7, HOLDER_A, payer + word(3n) + word(8n) + payer, 200),
    hookLog(c, 'Unstaked', 7, HOLDER_A, word(2n) + word(6n) + payer, 300),
    // B: in and fully out; the ended streak is the record.
    hookLog(c, 'StreakStarted', 7, HOLDER_B, payer, 100),
    hookLog(c, 'Staked', 7, HOLDER_B, payer + word(4n) + word(4n) + payer, 100),
    hookLog(c, 'Unstaked', 7, HOLDER_B, word(4n) + word(0n) + payer, 900),
    hookLog(c, 'StreakEnded', 7, HOLDER_B, word(800n) + payer, 900),
    // Another project's event is ignored.
    hookLog(c, 'Staked', 8, HOLDER_C, payer + word(9n) + word(9n) + payer, 100),
  ];
  const rows = c.holderRows(7n, logs, 1000);
  assert.deepEqual(Array.from(rows, (row) => [row.holder, row.staked, row.current, row.longest]), [
    [HOLDER_A, 6n, 900, 900],
    [HOLDER_B, 0n, 0, 800],
  ]);
});

test('the header ages come from one pinned block and the streak start, the same definition as your position', async () => {
  const fields = {};
  const c = context({ $: (id) => (fields[id] ||= { textContent: '' }),
    rpc: async (method, params) => { assert.equal(JSON.stringify([method, params]), '["eth_getBlockByNumber",["latest",false]]'); return { number: '0x99', timestamp: '0x' + (1074).toString(16) }; } },
    ['holderRows', 'pinnedBlock', 'renderHeaderAges', 'formatDuration']);
  const payer = word(BigInt(HOLDER_A));
  const logs = [
    hookLog(c, 'StreakStarted', 7, HOLDER_A, payer, 1000),
    hookLog(c, 'Staked', 7, HOLDER_A, payer + word(5n) + word(5n) + payer, 1000),
    // A second stick 44 seconds later does not move the streak start.
    hookLog(c, 'Staked', 7, HOLDER_A, payer + word(2n) + word(7n) + payer, 1044),
  ];
  const pin = await c.pinnedBlock();
  assert.deepEqual({ ...pin }, { tag: '0x99', timestamp: 1074 });
  const rows = c.holderRows(7n, logs, pin.timestamp);
  c.renderHeaderAges(rows, pin.timestamp);
  assert.equal(fields['h-top'].textContent, c.formatDuration(74));
  assert.equal(fields['h-average'].textContent, c.formatDuration(74));
  assert.equal(rows[0].current, 74);
});

test('the shown holder page is re-read from the hook at one block and corrects a stale balance', async () => {
  const calls = [];
  const c = context({
    ctx: { hook: addr('4') },
    rpc: async (method, params) => {
      calls.push({ method, params });
      if (method === 'eth_blockNumber') return '0x77';
      return '0x' + word(params[0].data.includes(HOLDER_B.slice(2)) ? 3n : 6n);
    },
  }, ['verifyHolderPage']);
  const checked = await c.verifyHolderPage(7n, [{ holder: HOLDER_A, staked: 6n }, { holder: HOLDER_B, staked: 4n }]);
  assert.deepEqual(Array.from(checked, (row) => row.staked), [6n, 3n]);
  assert.ok(calls.filter((call) => call.method === 'eth_call').every((call) => call.params[1] === '0x77' && call.params[0].to === addr('4')));
  assert.equal(calls.filter((call) => call.method === 'eth_call').length, 2);
});

// ---------------------------------------------------------------- sibling chains
const LAUNCH = '11111111-2222-4333-8444-555555555555';
const uriFor = (launchId, chains = [84532, 11155420]) => 'data:application/json;charset=utf-8,'
  + encodeURIComponent(JSON.stringify({ protocol: 'Sticky', version: 1, launchId, environment: 'testnet', chains }));
function abiString(text) {
  const hex = Buffer.from(text, 'utf8').toString('hex');
  return '0x' + word(32) + word(hex.length / 2) + hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');
}

// Two testnets with Sticky configured, one production chain that must never be touched.
function siblingFixture({ opProjects }) {
  const calls = [];
  const deployer = addr('d');
  const chains = {
    84532: { rpcUrl: 'https://base-sepolia.test', deployer, fromBlock: '0x10' },
    11155420: { rpcUrl: 'https://op-sepolia.test', deployer, fromBlock: '0x20' },
    8453: { rpcUrl: 'https://base.test', deployer, fromBlock: '0x30' },
  };
  const uris = { '84532:12': uriFor(LAUNCH), ...Object.fromEntries(opProjects.map((p) => [`11155420:${p.id}`, p.uri])) };
  const deployLogs = (chainId) => (chainId === 11155420 ? opProjects : []).map((p, i) => ({
    topics: ['0xc00d5094bed981d0f08872f495cb40cf20020621153d33b7b379d10c953e59a1', '0x' + word(p.id), '0x' + word(1)],
    data: '0x' + word(0) + word(p.tax) + word(p.soulbound ? 1 : 0) + word(0),
    blockNumber: '0x' + (0x21 + i).toString(16), logIndex: '0x0', transactionHash: '0x' + word(i + 1), blockHash: '0x' + word(i + 9),
  }));
  const rpcAt = async (url, method, params) => {
    const chainId = Number(Object.entries(chains).find(([, chain]) => chain.rpcUrl === url)[0]);
    calls.push({ chainId, method, params });
    if (method === 'eth_blockNumber') return '0x40';
    if (method === 'eth_getLogs') return deployLogs(chainId);
    const data = params[0].data;
    if (data.startsWith('0xa312889b')) return abiString(uris[`${chainId}:${BigInt('0x' + data.slice(10, 74))}`] || '');
    return '0x' + word(BigInt(addr('e')));
  };
  const c = context({
    ctx: { chainId: 84532 },
    ORIGINS: [
      { chainId: 8453, environment: 'production', name: 'Base' },
      { chainId: 84532, environment: 'testnet', name: 'Base Sepolia' },
      { chainId: 11155420, environment: 'testnet', name: 'OP Sepolia' },
    ],
    stickyDeploymentFor: (chainId) => chains[chainId] || {},
    rpcAt,
  }, ['parseStickyProjectUri', 'chainRuntime', 'deployedProjectsOn', 'launchIdOf', 'siblingOn', 'launchSiblings', 'siblingTotals']);
  vm.runInContext(`
    const chainById = (chainId) => ORIGINS.find((origin) => origin.chainId === Number(chainId));
    const chainsForEnvironment = (environment) => ORIGINS.filter((origin) => origin.environment === environment);
    const viewAt = (deployment, to, selector, args = "") => rpcAt(deployment.rpcUrl, "eth_call", [{ to, data: selector + args }, "latest"]);
    const chainRuntimeCache = new Map(); const deployedCache = new Map(); const launchIdCache = new Map(); const siblingCache = new Map();
  `, c);
  return { c, calls };
}

test('a multichain launch finds its sibling by launch id, tax and transfer mode, scanning only its environment', async () => {
  const { c, calls } = siblingFixture({ opProjects: [
    { id: 3, tax: 500n, soulbound: false, uri: uriFor('other-launch') },
    { id: 4, tax: 0n, soulbound: false, uri: uriFor(LAUNCH) }, // same launch id, different tax: not a sibling
    { id: 5, tax: 500n, soulbound: false, uri: uriFor(LAUNCH) },
    { id: 6, tax: 500n, soulbound: false, uri: uriFor(LAUNCH) }, // a later copy cannot displace the first
  ] });
  const info = { reward: 500n, soulbound: false };
  const siblings = await c.launchSiblings(12n, info);
  assert.deepEqual(Array.from(siblings, (row) => [row.chainId, row.projectId, Boolean(row.self)]), [[84532, 12n, true], [11155420, 5n, false]]);
  // Scans are bounded by that chain's deployment block and never touch the production chain.
  const scans = calls.filter((call) => call.method === 'eth_getLogs');
  assert.ok(scans.length > 0 && scans.every((call) => call.chainId === 11155420 && call.params[0].fromBlock === '0x20'));
  assert.ok(!calls.some((call) => call.chainId === 8453));
  // Cached for the session: a second render makes no new calls.
  const before = calls.length;
  await c.launchSiblings(12n, info);
  assert.equal(calls.length, before);
});

test('a single-chain project, or one whose uri carries no launch id, has no siblings to scan', async () => {
  const { c, calls } = siblingFixture({ opProjects: [] });
  const siblings = await c.launchSiblings(99n, { reward: 0n, soulbound: false });
  assert.deepEqual(Array.from(siblings, (row) => row.chainId), [84532]);
  assert.ok(!calls.some((call) => call.method === 'eth_getLogs'));
});

test('sibling totals add supply everywhere, and backing only when every chain backs with the same token', () => {
  const { c } = siblingFixture({ opProjects: [] });
  const art = (backing, supply) => ({ backing: { backing, supply, symbol: 'ART', decimals: 6 } });
  assert.deepEqual({ ...c.siblingTotals([art(10n, 100n), art(5n, 50n)]) }, { supply: 150n, backing: 15n, decimals: 6, symbol: 'ART', complete: true });
  const mixed = c.siblingTotals([art(10n, 100n), { backing: { backing: 5n, supply: 50n, symbol: 'USDC', decimals: 6 } }]);
  assert.equal(mixed.backing, null);
  assert.equal(mixed.supply, 150n);
  assert.equal(c.siblingTotals([art(10n, 100n), { chainId: 10, error: 'down' }]).complete, false);
});

// ---------------------------------------------------------------- dialogs replace
test('the review replaces the dialog it came from and brings it back only when cancelled', () => {
  const dialog = (id) => ({ id, open: true, isConnected: true, close() { this.open = false; }, showModal() { this.open = true; } });
  const fund = dialog('fund-dialog');
  const confirm = dialog('confirm-dialog');
  const c = vm.createContext({ document: { querySelectorAll: () => [fund, confirm].filter((d) => d.open) } });
  vm.runInContext(`let confirmReturnTo = []; let confirmCompleted = false;\n${functionSource('replaceOpenDialogs')}\n${functionSource('restoreReplacedDialogs')}`, c);
  c.replaceOpenDialogs();
  assert.equal(fund.open, false);
  assert.equal(confirm.open, true);
  c.restoreReplacedDialogs();
  assert.equal(fund.open, true);
  // After a completed run the replaced dialog stays closed.
  c.replaceOpenDialogs();
  vm.runInContext('confirmCompleted = true;', c);
  c.restoreReplacedDialogs();
  assert.equal(fund.open, false);
});

// ---------------------------------------------------------------- one scan per view
test('a project view scans the hook once; granters and trusted senders reuse it, and a trust change rescans', async () => {
  const scans = [];
  const holder = HOLDER_A;
  const fields = new Map();
  const c = context({
    ctx: { chainId: 84532, currentId: 7n, hook: addr('4') },
    account: () => holder,
    autoStickAdapter: () => addr('5'),
    currentView: () => () => true,
    guard: (fn) => fn,
    esc: (value) => String(value),
    attachTimestamps: async (logs) => logs,
    $: (id) => { if (!fields.has(id)) fields.set(id, { innerHTML: '', querySelectorAll: () => [] }); return fields.get(id); },
    view: async () => '0x' + word(1),
  }, ['projectLogs', 'renderTrustedSenders']);
  const T = c.TOPIC;
  const trust = (who, sender) => ({ topics: [T.SetTrustedSender, '0x' + word(7), '0x' + word(BigInt(who)), '0x' + word(BigInt(sender))], data: '0x' + word(1) });
  const all = [
    { topics: [T.SetGranter, '0x' + word(7), '0x' + word(BigInt(addr('5')))], data: '0x' },
    trust(holder, addr('6')), trust(HOLDER_B, addr('7')), trust(holder, addr('5')),
    { topics: [T.Staked, '0x' + word(7), '0x' + word(BigInt(holder))], data: '0x' },
  ];
  c.getLogs = async (address, topics) => { scans.push(topics); return all.filter((log) => [].concat(topics[0]).includes(log.topics[0])); };
  vm.runInContext(`const POSITION_TOPICS = [TOPIC.Staked, TOPIC.Unstaked, TOPIC.StreakStarted, TOPIC.StreakEnded];
    const cachedProjectLogs = (projectId) => ctx.projectLogs?.chainId === ctx.chainId && ctx.projectLogs.projectId === BigInt(projectId) ? ctx.projectLogs : null;`, c);
  const scanned = await c.projectLogs(7n);
  assert.equal(scans.length, 1);
  assert.equal(scanned.position.length, 1);
  await c.renderTrustedSenders();
  await c.renderTrustedSenders();
  assert.equal(scans.length, 1, 'the 15-second refresh reuses the view scan');
  // Only this holder's senders, and AutoStick is shown on its own card instead.
  assert.match(fields.get('trusted-list').innerHTML, new RegExp(addr('6')));
  assert.doesNotMatch(fields.get('trusted-list').innerHTML, new RegExp(addr('7') + '|' + addr('5')));
  // After a trust change the cache is dropped: one holder scan, then reused.
  c.ctx.projectLogs = null;
  await c.renderTrustedSenders();
  await c.renderTrustedSenders();
  assert.equal(scans.length, 2);
});
