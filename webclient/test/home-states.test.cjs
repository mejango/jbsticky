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
  const match = new RegExp(`\\nconst ${name} = [^\\n]*\\n`).exec(source);
  assert.ok(match, `missing const ${name}`);
  return match[0];
}

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

function fixture({ ids = [], cards = true, chainId = 1, hash = '#/' } = {}) {
  const elements = new Map();
  const statuses = [];
  const c = vm.createContext({
    URL, console: { error() {} }, confirmResolve: null,
    ctx: { loaded: true, chainId, currentId: null },
    location: { hash, href: `https://sticky.center/?chain=${chainId}${hash}` },
    window: { STICKY_CONFIG: {} },
    $: id => { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
    account: () => null,
    status: (message, cls) => statuses.push([message, cls]),
    clearHomeSecuredChart() {}, setTab() {}, closeWalletMenu() {},
    chainById: id => ({ 1: { name: 'Ethereum' }, 84532: { name: 'Base Sepolia' } })[Number(id)],
    configuredStickiestCards: () => [],
    projectIds: async () => ids,
    hookLogs: async () => [],
    projectInfo: async id => {
      if (!cards) throw new Error('rpc down');
      return { symbol: 'TKN', decimals: 18, reward: 0n, stakedToken: '0x' + '22'.repeat(20) };
    },
    decUint: () => 0n,
    holderRows: () => [],
    poolBacking: async () => ({ supply: 1n, sigma: 1n }),
    backingUsdPrices: async () => new Map(),
    homeSecuredSeries: () => ({ points: [], total: 0n, missing: [], hasValue: false }),
    mountHomeSecuredChart() {},
    tokenLogo: () => '', esc: String, stickyLabel: info => `Sticky ${info.symbol}`, formatUnits: String, pct: String,
    activityItems: async () => [], airdropItems: async () => [], configuredAirdropItems: async () => [],
    renderFeed: (el, items, empty = 'no activity yet') => { el.innerHTML = items.length ? items.join('') : empty; },
    hydrateLogos: async () => {},
    renderProject: async () => {}, renderAccount: async () => {}, projectIdForHandle: async () => null,
    loadDeployer: async () => {},
  });
  vm.runInContext(
    `let viewSequence = 0;\n${constSource('isHomeRoute')}\n` +
    ['currentView', 'siteChainName', 'setHomeState', 'homeFailed', 'retryHome', 'renderHome', 'route'].map(functionSource).join('\n'),
    c,
  );
  c.home = () => c.$('view-home');
  c.hidden = id => c.$(id).classList.contains('hide');
  c.statuses = statuses;
  return c;
}

test('the home page starts in the loading state with the chart caption hidden', () => {
  assert.match(html, /<div id="view-home" data-state="loading" aria-busy="true">/);
  assert.match(html, /<p class="mut hint hide" id="home-secured-note">History estimates/);
  assert.match(html, /\.list-card:empty/);
  assert.match(html, /\.home-secured-chart:empty/);
});

test('reads in flight keep the loading state and never show a note', async () => {
  const c = fixture({ ids: [1n] });
  let release;
  c.projectIds = () => new Promise(resolve => { release = resolve; });
  const rendering = c.renderHome();
  assert.equal(c.home().dataset.state, 'loading');
  assert.equal(c.home().attributes['aria-busy'], 'true');
  assert.equal(c.hidden('home-note'), true);
  release([]);
  await rendering;
});

test('the home loading pill is skipped on the home route and kept elsewhere', () => {
  const load = functionSource('loadDeployer');
  assert.match(load, /if \(!isHomeRoute\(\)\) status\("loading…"\);/);
  const c = fixture();
  assert.equal(vm.runInContext('isHomeRoute()', c), true);
  c.location.hash = '#/project/3';
  assert.equal(vm.runInContext('isHomeRoute()', c), false);
  c.location.hash = '#/@handle';
  assert.equal(vm.runInContext('isHomeRoute()', c), false);
});

test('a chain with no Sticky projects shows the zero state naming the chain', async () => {
  const c = fixture({ ids: [], chainId: 1 });
  let logsRead = false;
  c.hookLogs = async () => { logsRead = true; return []; };
  await c.renderHome();
  assert.equal(c.home().dataset.state, 'empty');
  assert.equal(c.home().attributes['aria-busy'], 'false');
  assert.equal(c.$('home-note-text').textContent, 'No sticky tokens on Ethereum yet.');
  assert.equal(c.hidden('home-note'), false);
  assert.equal(c.hidden('home-retry'), true);
  assert.equal(logsRead, false, 'an empty chain skips the log scan');
});

test('the zero state hides the dashboard and shows the three steps in CSS', () => {
  assert.match(html, /#view-home:is\(\[data-state="empty"\], \[data-state="error"\]\) :is\(\.home-secured, \.home-list-panel, \.home-mobile-tabs, \.home-ranking-tabs\) \{ display: none !important; \}/);
  assert.match(html, /\.home-steps \{ display: none; \}/);
  assert.match(html, /#view-home\[data-state="empty"\] \.home-steps \{/);
  for (const step of ['Stick', 'Earn', 'Unstick']) assert.match(html, new RegExp(`<li><b>${step}</b><span>[^<]+</span></li>`));
  const steps = html.match(/<ol class="home-steps"[\s\S]*?<\/ol>/)[0];
  assert.doesNotMatch(steps, /—|·/);
});

test('a failed project read shows one error line with a retry, not the zero state', async () => {
  const c = fixture();
  c.projectIds = async () => { throw new Error('fetch failed'); };
  c.route();
  await new Promise(setImmediate);
  assert.equal(c.home().dataset.state, 'error');
  assert.equal(c.$('home-note-text').textContent, 'Could not read Sticky tokens on Ethereum.');
  assert.equal(c.hidden('home-retry'), false);
  assert.deepEqual(c.statuses, [], 'the home page does not also raise the status pill');
});

test('projects that exist but cannot be read are an error, not an empty chain', async () => {
  const c = fixture({ ids: [37n, 38n], cards: false });
  await assert.rejects(c.renderHome(), /Could not read any Sticky token/);
  assert.equal(c.home().dataset.state, 'loading');
});

test('retry clears the dashboard, returns to loading, and renders the projects', async () => {
  const c = fixture({ ids: [37n] });
  c.homeFailed(new Error('fetch failed'));
  c.$('projects').innerHTML = 'stale';
  const seen = [];
  const read = c.projectIds;
  c.projectIds = async () => { seen.push(c.home().dataset.state); return read(); };
  await c.retryHome();
  assert.deepEqual(seen, ['loading']);
  assert.equal(c.home().dataset.state, 'ready');
  assert.equal(c.hidden('home-note'), true);
  assert.match(c.$('projects').innerHTML, /Sticky TKN/);
});

test('retry before the deployment loaded reruns the chain load', async () => {
  const c = fixture();
  c.ctx.loaded = false;
  let loads = 0;
  c.loadDeployer = async () => { loads++; throw new Error('rpc down'); };
  await c.retryHome();
  assert.equal(loads, 1);
  assert.equal(c.home().dataset.state, 'error');
});

test('a chain with projects renders the dashboard in the ready state', async () => {
  const c = fixture({ ids: [37n, 38n, 39n], chainId: 84532 });
  let mounted = 0;
  c.mountHomeSecuredChart = () => { mounted++; };
  await c.renderHome();
  assert.equal(c.home().dataset.state, 'ready');
  assert.equal(mounted, 1);
  assert.equal((c.$('projects').innerHTML.match(/card-item/g) || []).length, 3);
  assert.equal(c.$('activity').innerHTML, 'no activity yet');
  assert.equal(c.$('airdrops').innerHTML, 'no airdrops yet');
  assert.equal(c.hidden('home-note'), true);
});

test('a ready dashboard stays up while navigation back home rereads it', async () => {
  const c = fixture({ ids: [37n] });
  await c.renderHome();
  const states = [];
  const read = c.projectIds;
  c.projectIds = async () => { states.push(c.home().dataset.state); return read(); };
  await c.renderHome();
  assert.deepEqual(states, ['ready']);
});

test('the chart caption shows only when the chart has a value', () => {
  assert.match(functionSource('mountHomeSecuredChart'), /\$\("home-secured-note"\)\.classList\.toggle\("hide", !series\.hasValue\);/);
});

test('unsupported and unconfigured chains show the error line without a retry', () => {
  assert.match(source, /if \(!selected\) setHomeState\("error", "This chain is not supported\. Select a configured chain to continue\."\);/);
  assert.match(source, /else if \(\$\("deployer"\)\.value\) loadDeployer\(\)\.catch\(homeFailed\);/);
  assert.match(source, /else setHomeState\("error", `Sticky is not on \$\{selected\.name\} yet\.`\);/);
});
