'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../app.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');
function functionSource(name) {
  const match = new RegExp(`(?:^|\\n)(?:async )?function ${name}\\(`).exec(source);
  assert.ok(match, `missing function ${name}`);
  const start = match.index + (source[match.index] === '\n' ? 1 : 0);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
function constSource(name) {
  const start = source.indexOf(`\nconst ${name} = `);
  assert.ok(start >= 0, `missing const ${name}`);
  return source.slice(start, source.indexOf(';\n', start) + 2);
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

const CHAINS = {
  1: { chainId: 1, name: 'Ethereum', icon: 'eth', environment: 'production' },
  10: { chainId: 10, name: 'OP Mainnet', icon: 'op', environment: 'production' },
  8453: { chainId: 8453, name: 'Base', icon: 'base', environment: 'production' },
  84532: { chainId: 84532, name: 'Base Sepolia', icon: 'base', environment: 'testnet' },
  11155420: { chainId: 11155420, name: 'OP Sepolia', icon: 'op', environment: 'testnet' },
};

function element(id) {
  const classes = new Set(['home-note', 'home-retry', 'home-secured-note'].includes(id) ? ['hide'] : []);
  const attributes = {};
  return {
    id, textContent: '', innerHTML: '', dataset: {}, attributes,
    setAttribute: (name, value) => { attributes[name] = value; },
    classList: {
      add: name => classes.add(name), remove: name => classes.delete(name),
      toggle: (name, on) => (on ?? !classes.has(name)) ? classes.add(name) : classes.delete(name),
      contains: name => classes.has(name),
    },
  };
}

function card(chainId, id, extra = {}) {
  return {
    id: BigInt(id), chainId, key: `${chainId}:${id}`, totalStaked: 10n ** 18n, sticks: 1, launchId: null,
    info: { symbol: 'CPN', stSymbol: 'STK', decimals: 18, reward: 1000n, soulbound: false, stakedToken: '0x' + '22'.repeat(20) },
    pool: { sigma: 10n ** 18n }, ...extra,
  };
}
const chainResult = (chainId, cards = [], extra = {}) => ({ chainId, cards, moves: [], prices: new Map(), activity: [], airdrops: [], ...extra });

function fixture({ chain = null, deployed = [1, 10, 8453, 84532, 11155420], hash = '#/' } = {}) {
  const elements = new Map();
  const statuses = [];
  const search = chain ? `?chain=${chain}` : '';
  const c = vm.createContext({
    URL, console: { error() {} }, confirmResolve: null,
    ctx: { loaded: false, chainId: undefined, currentId: null },
    location: { hash, href: `https://sticky.center/${search}${hash}` },
    window: { STICKY_CONFIG: { defaultChainId: 1 } },
    StickyRuntime: { deployment: (_config, chainId) => (deployed.includes(Number(chainId)) ? { deployer: '0x' + '33'.repeat(20) } : {}) },
    chainById: id => CHAINS[Number(id)],
    chainsForEnvironment: environment => Object.values(CHAINS).filter(row => row.environment === environment),
    CHAIN_ICON_SVG: { eth: '<svg>eth</svg>', op: '<svg>op</svg>', base: '<svg>base</svg>' },
    $: id => { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
    account: () => null,
    status: (message, cls) => statuses.push([message, cls]),
    clearHomeSecuredChart() {}, setTab() {}, closeWalletMenu() {},
    configuredStickiestCards: () => [], configuredAirdropItems: async () => [],
    mountHomeSecuredChart() {}, homeSecuredSeries: () => ({}), hydrateLogos: async () => {},
    tokenLogo: () => '', esc: String, stickyLabel: info => info.stSymbol, formatUnits: value => String(value), pct: String,
    renderFeed: (el, items, empty = 'no activity yet') => { el.innerHTML = items.length ? items.map(item => item.html ?? item).join('') : empty; },
    renderProject: async () => {}, renderAccount: async () => {}, projectIdForHandle: async () => null,
    homeChainData: async chainId => chainResult(chainId),
  });
  vm.runInContext(
    `let viewSequence = 0;\n${['isHomeRoute', 'projectHref'].map(constSource).join('\n')}\n` +
    ['homeEnvironment', 'homeChains', 'chainIcons', 'setHomeState', 'homeFailed', 'retryHome', 'groupHomeCards',
      'stickiestCardHtml', 'renderHome', 'route', 'currentView'].map(functionSource).join('\n'),
    c,
  );
  c.home = () => c.$('view-home');
  c.hidden = id => c.$(id).classList.contains('hide');
  c.note = () => (c.hidden('home-note') ? '' : c.$('home-note-text').textContent);
  c.statuses = statuses;
  return c;
}

test('the page starts in the loading state with the chart caption hidden and no chain picker', () => {
  assert.match(html, /<div id="view-home" data-state="loading" aria-busy="true">/);
  assert.match(html, /<p class="mut hint hide" id="home-secured-note">History estimates/);
  assert.match(html, /\.list-card:empty/);
  assert.match(html, /\.home-secured-chart:empty/);
  assert.doesNotMatch(html, /id="site-chain"/);
  assert.match(html, /<button class="connect-btn" id="connect-btn">Sign in<\/button>/);
  assert.match(source, /walletAccount \? shortAddr\(walletAccount\) : "Sign in";/);
});

test('home reads every configured chain of the environment its link names', () => {
  assert.deepEqual([...fixture().homeChains()], [1, 10, 8453]);
  assert.deepEqual([...fixture({ chain: 8453 }).homeChains()], [1, 10, 8453]);
  assert.deepEqual([...fixture({ chain: 84532 }).homeChains()], [84532, 11155420]);
  assert.deepEqual([...fixture({ deployed: [1, 84532] }).homeChains()], [1]);
});

test('home links open the project on its own chain', () => {
  const c = fixture();
  assert.equal(vm.runInContext('projectHref(8453, 7n)', c), '?chain=8453#/project/7');
  c.ctx.chainId = 8453;
  assert.equal(vm.runInContext('projectHref(8453, 7n)', c), '#/project/7');
});

test('reads in flight keep the loading state and never show a note', async () => {
  const c = fixture();
  const pending = deferred();
  c.homeChainData = () => pending.promise;
  const rendering = c.renderHome();
  await new Promise(setImmediate);
  assert.equal(c.home().dataset.state, 'loading');
  assert.equal(c.home().attributes['aria-busy'], 'true');
  assert.equal(c.note(), '');
  pending.resolve(chainResult(1));
  await rendering;
});

test('one empty chain does not decide the zero state while others load', async () => {
  const c = fixture();
  const slow = deferred();
  c.homeChainData = async chainId => (chainId === 8453 ? slow.promise : chainResult(chainId));
  const rendering = c.renderHome();
  await new Promise(setImmediate);
  assert.equal(c.home().dataset.state, 'loading');
  slow.resolve(chainResult(8453));
  await rendering;
  assert.equal(c.home().dataset.state, 'empty');
});

test('the loading pill is skipped on the home route and kept elsewhere', () => {
  assert.match(functionSource('loadDeployer'), /if \(!isHomeRoute\(\)\) status\("loading…"\);/);
  const c = fixture();
  assert.equal(vm.runInContext('isHomeRoute()', c), true);
  c.location.hash = '#/project/3';
  assert.equal(vm.runInContext('isHomeRoute()', c), false);
  c.location.hash = '#/@handle';
  assert.equal(vm.runInContext('isHomeRoute()', c), false);
});

test('no Sticky tokens on any production chain shows the zero state', async () => {
  const c = fixture();
  await c.renderHome();
  assert.equal(c.home().dataset.state, 'empty');
  assert.equal(c.home().attributes['aria-busy'], 'false');
  assert.equal(c.note(), 'No sticky tokens yet.');
  assert.equal(c.hidden('home-retry'), true);
});

test('the testnet zero state names testnets', async () => {
  const c = fixture({ chain: 84532 });
  await c.renderHome();
  assert.equal(c.note(), 'No sticky tokens on testnets yet.');
});

test('the zero state hides the dashboard and shows the three steps in CSS', () => {
  assert.match(html, /#view-home:is\(\[data-state="empty"\], \[data-state="error"\]\) :is\(\.home-secured, \.home-list-panel, \.home-mobile-tabs, \.home-ranking-tabs\) \{ display: none !important; \}/);
  assert.match(html, /\.home-steps \{ display: none; \}/);
  assert.match(html, /#view-home\[data-state="empty"\] \.home-steps \{/);
  for (const step of ['Stick', 'Earn', 'Unstick']) assert.match(html, new RegExp(`<li><b>${step}</b><span>[^<]+</span></li>`));
  const steps = html.match(/<ol class="home-steps"[\s\S]*?<\/ol>/)[0];
  assert.doesNotMatch(steps, /—|·/);
});

test('every chain failing shows one error line with a retry, not the zero state', async () => {
  const c = fixture();
  c.homeChainData = async () => { throw new Error('fetch failed'); };
  c.route();
  for (let i = 0; i < 5; i++) await new Promise(setImmediate);
  assert.equal(c.home().dataset.state, 'error');
  assert.equal(c.note(), 'Could not read Sticky tokens.');
  assert.equal(c.hidden('home-retry'), false);
  assert.deepEqual(c.statuses, [], 'the home page does not also raise the status pill');
});

test('a failed chain among empty ones is an error naming that chain, not a zero state', async () => {
  const c = fixture();
  c.homeChainData = async chainId => { if (chainId === 8453) throw new Error('rpc down'); return chainResult(chainId); };
  await c.renderHome();
  assert.equal(c.home().dataset.state, 'error');
  assert.equal(c.note(), 'Could not read Sticky tokens on Base.');
});

test('a failed chain never blanks the chains that loaded', async () => {
  const c = fixture();
  c.homeChainData = async chainId => {
    if (chainId === 10) throw new Error('rpc down');
    return chainResult(chainId, chainId === 1 ? [card(1, 4)] : [card(8453, 9)]);
  };
  await c.renderHome();
  assert.equal(c.home().dataset.state, 'ready');
  assert.equal((c.$('projects').innerHTML.match(/class="card-item/g) || []).length, 2);
  assert.equal(c.note(), 'Could not read Sticky tokens on OP Mainnet.');
  assert.equal(c.hidden('home-retry'), false);
});

test('the dashboard draws as each chain arrives', async () => {
  const c = fixture();
  const slow = deferred();
  c.homeChainData = async chainId => (chainId === 8453 ? slow.promise : chainResult(chainId, chainId === 1 ? [card(1, 4)] : []));
  const rendering = c.renderHome();
  await new Promise(setImmediate);
  await new Promise(setImmediate);
  assert.equal(c.home().dataset.state, 'ready');
  assert.equal((c.$('projects').innerHTML.match(/class="card-item/g) || []).length, 1);
  slow.resolve(chainResult(8453, [card(8453, 9)]));
  await rendering;
  assert.equal((c.$('projects').innerHTML.match(/class="card-item/g) || []).length, 2);
});

test('cards and feeds merge across chains with chain icons and chain links', async () => {
  const c = fixture({ chain: 84532 });
  c.homeChainData = async chainId => chainResult(chainId, [card(chainId, chainId === 84532 ? 37 : 20)], {
    activity: [{ ts: chainId === 84532 ? 5 : 9, html: `<i>${chainId}</i>` }],
  });
  await c.renderHome();
  const projects = c.$('projects').innerHTML;
  assert.match(projects, /href="\?chain=84532#\/project\/37"/);
  assert.match(projects, /href="\?chain=11155420#\/project\/20"/);
  assert.match(projects, /aria-label="Base Sepolia"/);
  assert.match(projects, /aria-label="OP Sepolia"/);
  assert.equal(c.$('activity').innerHTML, '<i>11155420</i><i>84532</i>', 'newest first across chains');
});

test('sibling projects of one launch collapse into one card with every chain icon', async () => {
  const c = fixture({ chain: 84532 });
  const launch = { launchId: 'L1' };
  c.homeChainData = async chainId => chainResult(chainId, chainId === 84532
    ? [card(84532, 37, launch), card(84532, 38, launch), card(84532, 39)]
    : [card(11155420, 20, launch)]);
  await c.renderHome();
  const items = c.$('projects').innerHTML.split('<a ').slice(1);
  assert.equal(items.length, 3, 'a second project on the same chain with a copied launch id stays separate');
  const grouped = items.find(item => item.includes('Base Sepolia, OP Sepolia'));
  assert.ok(grouped, 'the launch card lists both chains');
  assert.match(grouped, /Sticks:<\/span> 2/);
  assert.match(grouped, /Backing:<\/span> 2000000000000000000 CPN/);
});

test('launch grouping requires matching tax and transfer mode', () => {
  const c = fixture();
  const groups = c.groupHomeCards([
    card(1, 1, { launchId: 'L' }),
    card(10, 2, { launchId: 'L', info: { ...card(10, 2).info, reward: 5n } }),
    card(8453, 3, { launchId: 'L' }),
  ]);
  assert.equal(JSON.stringify(groups.map(group => group.cards.map(row => row.chainId))), '[[1,8453],[10]]');
});

test('retry clears the dashboard, returns to loading, and renders again', async () => {
  const c = fixture();
  c.homeFailed(new Error('fetch failed'));
  c.$('projects').innerHTML = 'stale';
  const seen = [];
  c.homeChainData = async chainId => { seen.push(c.home().dataset.state); return chainResult(chainId, chainId === 1 ? [card(1, 4)] : []); };
  await c.retryHome();
  assert.deepEqual(seen, ['loading', 'loading', 'loading']);
  assert.equal(c.home().dataset.state, 'ready');
  assert.equal(c.note(), '');
  assert.match(c.$('projects').innerHTML, /STK/);
});

test('a ready dashboard stays up while navigation back home rereads it', async () => {
  const c = fixture();
  c.homeChainData = async chainId => chainResult(chainId, [card(chainId, 1)]);
  await c.renderHome();
  const states = [];
  c.homeChainData = async chainId => { states.push(c.home().dataset.state); return chainResult(chainId, [card(chainId, 1)]); };
  await c.renderHome();
  assert.deepEqual(states, ['ready', 'ready', 'ready']);
});

test('the chart caption shows only when the chart has a value', () => {
  assert.match(functionSource('mountHomeSecuredChart'), /\$\("home-secured-note"\)\.classList\.toggle\("hide", !series\.hasValue\);/);
});

test('without Bendystraw, one chain\'s home data scans its own deployer, then its hook from the first launch', async () => {
  const c = fixture();
  const reader = { chainId: 8453, deployer: 'D', hook: 'H', projects: {} };
  const calls = [];
  Object.assign(c, {
    TOPIC: { DeploySticky: 'deploy' }, POSITION_TOPICS: ['p'],
    decUint: value => BigInt(value),
    chainReader: async chainId => { calls.push(['reader', chainId]); return reader; },
    getLogsOn: async (on, address, _topics, from) => { calls.push(['logs', address, from]); return address === 'D' ? [{ topics: ['deploy', '37'], blockNumber: '0x99' }] : [{ topics: ['p', '37'] }]; },
    logMoves: (logs) => logs.map((log) => ({ chainId: log.chainId })),
    attachTimestamps: async logs => logs,
    projectInfo: async (id, on) => { assert.equal(on, reader); return card(8453, id).info; },
    poolBacking: async (_id, _info, on) => { assert.equal(on, reader); return { supply: 5n, sigma: 6n }; },
    launchIdOf: async () => 'L1',
    holderRows: () => [{ staked: 1n }, { staked: 0n }],
    backingUsdPrices: async (_cards, chainId) => { calls.push(['prices', chainId]); return new Map(); },
    activityItems: async (_logs, _include, on) => { assert.equal(on, reader); return []; },
    airdropItems: async (_logs, on) => { assert.equal(on, reader); return []; },
  });
  vm.runInContext(functionSource('scannedHomeChainData') + functionSource('homeCards'), c);
  const data = await c.scannedHomeChainData(8453);
  assert.equal(data.cards.length, 1);
  assert.equal(data.cards[0].key, '8453:37');
  assert.equal(data.cards[0].launchId, 'L1');
  assert.equal(data.cards[0].sticks, 1);
  assert.equal(data.moves[0].chainId, 8453);
  assert.deepEqual(calls, [['reader', 8453], ['logs', 'D', undefined], ['logs', 'H', '0x99'], ['prices', 8453]]);
});

test('a chain whose projects all fail to read is an error for that chain', async () => {
  const c = fixture();
  Object.assign(c, {
    TOPIC: { DeploySticky: 'deploy' }, POSITION_TOPICS: ['p'], decUint: value => BigInt(value),
    chainReader: async () => ({ chainId: 8453, deployer: 'D', hook: 'H' }),
    getLogsOn: async (_on, address) => (address === 'D' ? [{ topics: ['deploy', '37'], blockNumber: '0x1' }] : []),
    attachTimestamps: async logs => logs,
    projectInfo: async () => { throw new Error('rpc down'); },
  });
  vm.runInContext(functionSource('scannedHomeChainData') + functionSource('homeCards'), c);
  await assert.rejects(c.scannedHomeChainData(8453), /Could not read any Sticky token on Base/);
});

test('boot starts the home page without waiting for the page chain', () => {
  assert.match(source, /if \(isHomeRoute\(\)\) route\(\);\n  if \(selected && \$\("deployer"\)\.value\) loadDeployer\(\)\.catch/);
  assert.match(functionSource('loadDeployer'), /if \(!isHomeRoute\(\) \|\| window\.__DEMO_RPC\) route\(\);/);
});
