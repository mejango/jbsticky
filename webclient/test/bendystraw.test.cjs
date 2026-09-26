'use strict';

// Bendystraw as a cache for discovery and history, with chain reads as the fallback.
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
function constSource(name) {
  const start = source.indexOf(`\nconst ${name} = `);
  assert.ok(start >= 0, `missing const ${name}`);
  const firstLine = source.slice(start + 1, source.indexOf('\n', start + 1));
  return source.slice(start, firstLine.endsWith('=> {') ? source.indexOf('\n};', start) + 3 : source.indexOf(';\n', start) + 2);
}
const block = (start) => source.slice(source.indexOf(start), source.indexOf('\n};', source.indexOf(start)) + 3);
const codec = source.slice(source.indexOf('const strip ='), source.indexOf('// ------------------------------------------------------------- rpc plumbing'));

const word = (value) => BigInt(value).toString(16).padStart(64, '0');
const DEPLOYER = '0xda38ec48b5b1d186b02ba99f297e95153bee33a9';
const HOLDER = '0x' + 'a'.repeat(40);
const OTHER = '0x' + 'b'.repeat(40);
const ORIGINS = [
  { chainId: 1, environment: 'production', name: 'Ethereum' },
  { chainId: 42161, environment: 'production', name: 'Arbitrum One' },
  { chainId: 84532, environment: 'testnet', name: 'Base Sepolia' },
  { chainId: 11155420, environment: 'testnet', name: 'OP Sepolia' },
];

// A Bendystraw stand-in: answers by operation name and records every request.
function bendystraw(handlers) {
  const requests = [];
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    const operation = /query (\w+)/.exec(body.query)[1];
    requests.push({ url, operation, variables: body.variables });
    const handler = handlers[operation];
    if (!handler) throw new Error(`unexpected ${operation}`);
    const result = await handler(body.variables);
    return { ok: true, status: 200, json: async () => result };
  };
  return { fetch, requests };
}
const status = (entries) => Object.fromEntries(entries.map(([name, id, number]) => [name, { id, block: { number, timestamp: 1 } }]));
const page = (items) => ({ items, pageInfo: { hasNextPage: false, endCursor: null } });

// ---------------------------------------------------------------- runtime helpers
test('the index lists each chain\'s Sticky projects and the block Bendystraw has indexed it through', async () => {
  const { fetch, requests } = bendystraw({
    StickyIndex: () => ({ data: {
      _meta: { status: status([['baseSepolia', 84532, 500], ['optimismSepolia', 11155420, 900], ['sepolia', 11155111, 7]]) },
      projects: page([
        { chainId: 84532, projectId: 38, version: 6, owner: DEPLOYER, metadataUri: 'data:x', createdAt: 5 },
        { chainId: 84532, projectId: 37, version: 6, owner: DEPLOYER, metadataUri: null, createdAt: 4 },
        { chainId: 84532, projectId: 3, version: 6, owner: OTHER, metadataUri: null, createdAt: 1 },
      ]),
    } }),
  });
  const index = await Runtime.stickyIndex('https://testnet.bendystraw.xyz', { 84532: DEPLOYER.toUpperCase().replace('0X', '0x'), 11155420: DEPLOYER }, { fetch });
  assert.equal(requests[0].url, 'https://testnet.bendystraw.xyz/graphql');
  assert.deepEqual(requests[0].variables.owners, [DEPLOYER]);
  assert.deepEqual([...index.keys()], [84532, 11155420], 'a chain without a configured deployer is left out');
  assert.equal(index.get(84532).block, 500n);
  assert.deepEqual(index.get(84532).projects.map((row) => row.projectId), [37n, 38n], 'sorted, and a project another owner holds is dropped');
  assert.deepEqual(index.get(11155420).projects, []);
});

test('Bendystraw errors, HTTP failures and timeouts throw so the caller scans the chain', async () => {
  const errors = bendystraw({ StickyIndex: () => ({ errors: [{ message: 'Unknown field' }] }) });
  await assert.rejects(Runtime.stickyIndex('https://b.test', { 1: DEPLOYER }, { fetch: errors.fetch }), /Bendystraw: Unknown field/);
  const http = async () => ({ ok: false, status: 502, json: async () => { throw new Error('html'); } });
  await assert.rejects(Runtime.stickyIndex('https://b.test', { 1: DEPLOYER }, { fetch: http }), /HTTP 502/);
  const hang = (_url, init) => new Promise((_ok, fail) => init.signal.addEventListener('abort', () => fail(new Error('aborted'))));
  await assert.rejects(Runtime.stickyIndex('https://b.test', { 1: DEPLOYER }, { fetch: hang, timeout: 20 }), /timed out/);
  const noStatus = bendystraw({ StickyIndex: () => ({ data: { _meta: null, projects: page([]) } }) });
  await assert.rejects(Runtime.stickyIndex('https://b.test', { 1: DEPLOYER }, { fetch: noStatus.fetch }), /no indexing status/);
});

test('sticks and unsticks are read per chain and version, and rows for other projects are dropped', async () => {
  const pay = (projectId, extra = {}) => ({ chainId: 84532, projectId, version: 6, txHash: '0x1', logIndex: 1, timestamp: 20, caller: OTHER,
    beneficiary: HOLDER, amount: '5', newlyIssuedTokenCount: '50', ...extra });
  const { fetch, requests } = bendystraw({
    // Bendystraw has ignored filters before; a row outside the request must not reach the page.
    StickyPays: () => ({ data: { payEvents: page([pay(37), pay(99), pay(37, { version: 4 }), pay(37, { timestamp: 10, logIndex: 0 })]) } }),
    StickyCashOuts: () => ({ data: { cashOutTokensEvents: page([{ chainId: 84532, projectId: 37, version: 6, txHash: '0x2', logIndex: 2,
      timestamp: 30, caller: HOLDER, holder: HOLDER, beneficiary: HOLDER, cashOutCount: '20', reclaimAmount: '2' }]) } }),
  });
  const events = await Runtime.stickyEvents('https://b.test', [{ chainId: 84532, projectId: 37n, version: 6 }], { fetch });
  assert.deepEqual(requests.map((request) => [request.operation, JSON.stringify(request.variables.where)]), [
    ['StickyPays', '{"chainId":84532,"version":6,"projectId_in":[37]}'],
    ['StickyCashOuts', '{"chainId":84532,"version":6,"projectId_in":[37]}'],
  ]);
  assert.deepEqual(events.map((event) => [event.kind, event.ts, event.tokens]), [['stick', 10, 50n], ['stick', 20, 50n], ['unstick', 30, 20n]]);
  assert.equal(events[0].payer, OTHER);
  assert.equal(events[0].holder, HOLDER);
  assert.deepEqual(await Runtime.stickyEvents('https://b.test', [], { fetch }), []);
});

// ---------------------------------------------------------------- home
function homeContext({ fetch, chains = { 1: DEPLOYER, 42161: DEPLOYER, 84532: DEPLOYER, 11155420: DEPLOYER }, logs = async () => [] } = {}) {
  const calls = [];
  const elements = new Map();
  const element = (id) => {
    const classes = new Set();
    const attributes = {};
    return { id, textContent: '', innerHTML: '', dataset: {}, attributes, setAttribute: (name, value) => { attributes[name] = value; },
      classList: { add: (name) => classes.add(name), remove: (name) => classes.delete(name), contains: (name) => classes.has(name),
        toggle: (name, on) => ((on ?? !classes.has(name)) ? classes.add(name) : classes.delete(name)) } };
  };
  const c = vm.createContext({
    TextEncoder, TextDecoder, Uint8Array, URL, console: { warn() {}, error() {} },
    window: { STICKY_CONFIG: { defaultChainId: 1, bendystrawUrl: 'https://prod.test', testnetBendystrawUrl: 'https://testnet.test' } },
    location: { hash: '#/', href: 'https://sticky.center/#/' },
    ctx: { loaded: false },
    ORIGINS,
    StickyRuntime: {
      ...Runtime,
      deployment: (_config, chainId) => ({ deployer: chains[chainId] }),
      stickyIndex: (url, deployers) => Runtime.stickyIndex(url, deployers, { fetch }),
      stickyEvents: (url, projects) => Runtime.stickyEvents(url, projects, { fetch }),
      logs: async (_rpc, filter) => { calls.push(['logs', filter.address, filter.fromBlock]); return logs(filter); },
    },
    stickyDeploymentFor: (chainId) => ({ deployer: chains[chainId], fromBlock: '0x10' }),
    chainRuntime: async (chainId) => ({ chainId, deployer: chains[chainId], rpcUrl: `rpc:${chainId}`, fromBlock: '0x10' }),
    rpcAt: async () => { throw new Error('no rpc in this test'); },
    chainReader: async (chainId) => ({ chainId, deployer: chains[chainId], hook: 'hook', projects: {} }),
    getLogsOn: async (reader, address) => { calls.push(['scan', reader.chainId, address]); return []; },
    attachTimestamps: async (value) => value,
    projectInfo: async () => ({ symbol: 'USDC', stSymbol: 'stUSDC', decimals: 6, reward: 500n, soulbound: true, stakedToken: '0x' + '2'.repeat(40) }),
    poolBacking: async () => ({ supply: 30n, sigma: 3n }),
    launchIdOf: async () => null,
    backingUsdPrices: async () => new Map(),
    autoStickAdapterOn: () => '0x' + '5'.repeat(40),
    account: () => null,
    tokenLogo: () => '', esc: String, formatUnits: (value) => String(value), ago: () => 'now', shortAddr: (value) => value,
    addressLabel: (value) => value, pct: String, stickyLabel: (info) => info.stSymbol, CHAIN_ICON_SVG: {},
    $: (id) => { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
    status() {}, clearHomeSecuredChart() {}, mountHomeSecuredChart() {}, homeSecuredSeries: () => ({}), hydrateLogos: async () => {},
    configuredStickiestCards: () => [], configuredAirdropItems: async () => [],
    renderFeed: (el, items, empty = 'no activity yet') => { el.innerHTML = items.length ? items.map((item) => item.html).join('') : empty; },
    activityItems: async () => [], airdropItems: async () => [], holderRows: () => [],
  });
  vm.runInContext(`${block('const TOPIC =')}\n${codec}\nlet viewSequence = 0;
    const chainById = (chainId) => ORIGINS.find((origin) => origin.chainId === Number(chainId));
    const chainsForEnvironment = (environment) => ORIGINS.filter((origin) => origin.environment === environment);
    const POSITION_TOPICS = [TOPIC.Staked, TOPIC.Unstaked, TOPIC.StreakStarted, TOPIC.StreakEnded];
    const startBlockCache = new Map();
    ${['bendystrawUrl', 'INDEX_TTL', 'indexCache', 'deployedCache', 'eventMoves', 'feedCard', 'isHomeRoute', 'projectHref'].map(constSource).join('\n')}
    ${['stickyIndexFor', 'indexedChain', 'deployedProjectsOn', 'rememberStartBlock', 'parseStickyProjectUri', 'homeChainData', 'scannedHomeChainData',
      'homeCards', 'indexedHolderCount', 'indexedActivityItems', 'indexedAirdropItems', 'logMoves', 'homeEnvironment', 'homeChains', 'chainIcons',
      'setHomeState', 'groupHomeCards', 'stickiestCardHtml', 'renderHome'].map(functionSource).join('\n')}`, c);
  c.calls = calls;
  c.home = () => c.$('view-home');
  return c;
}

const testnetIndex = (projects) => () => ({ data: {
  _meta: { status: status([['baseSepolia', 84532, 1000], ['optimismSepolia', 11155420, 2000]]) },
  projects: page(projects.map(([chainId, projectId]) => ({ chainId, projectId, version: 6, owner: DEPLOYER, metadataUri: null, createdAt: 1 }))),
} });

test('with Bendystraw, the home page lists projects and activity without scanning any chain\'s history', async () => {
  const pays = [
    { chainId: 84532, projectId: 37, version: 6, txHash: '0x1', logIndex: 1, timestamp: 10, caller: HOLDER, beneficiary: HOLDER, amount: '5', newlyIssuedTokenCount: '50' },
    { chainId: 84532, projectId: 37, version: 6, txHash: '0x2', logIndex: 1, timestamp: 11, caller: OTHER, beneficiary: OTHER.replace('b', 'c'), amount: '1', newlyIssuedTokenCount: '10' },
    { chainId: 84532, projectId: 37, version: 6, txHash: '0x3', logIndex: 1, timestamp: 12, caller: OTHER, beneficiary: OTHER, amount: '1', newlyIssuedTokenCount: '10' },
  ];
  const cashOuts = [{ chainId: 84532, projectId: 37, version: 6, txHash: '0x4', logIndex: 1, timestamp: 13, caller: OTHER, holder: OTHER, beneficiary: OTHER, cashOutCount: '10', reclaimAmount: '1' }];
  const { fetch, requests } = bendystraw({
    StickyIndex: testnetIndex([[84532, 37]]),
    StickyPays: ({ where }) => ({ data: { payEvents: page(pays.filter((row) => row.chainId === where.chainId)) } }),
    StickyCashOuts: ({ where }) => ({ data: { cashOutTokensEvents: page(cashOuts.filter((row) => row.chainId === where.chainId)) } }),
  });
  const c = homeContext({ fetch });
  const [base, op] = await Promise.all([c.homeChainData(84532), c.homeChainData(11155420)]);
  assert.equal(requests.filter((request) => request.operation === 'StickyIndex').length, 1, 'one index query serves every chain');
  assert.deepEqual(Array.from(base.cards, (card) => [card.key, card.sticks]), [['84532:37', 2]], 'two holders still hold tokens');
  assert.deepEqual(Array.from(base.moves, (move) => move.delta), [50n, 10n, 10n, -10n]);
  assert.equal(base.activity.length, 4);
  assert.match(base.activity[0].html, /unstuck<\/span> 10 stUSDC/);
  assert.match(base.activity[3].html, /"verb">stuck<\/span> 50 stUSDC/);
  assert.equal(base.airdrops.length, 1, 'a stick paid for someone else is an airdrop');
  assert.match(base.airdrops[0].html, new RegExp(`${OTHER.replace('b', 'c')}</span> received 10 stUSDC from <span class="addr">${OTHER}`));
  assert.equal(op.cards.length, 0);
  // Only the unindexed tail is scanned for launches: from the indexed block, never the deployment block.
  assert.deepEqual(c.calls.filter((call) => call[0] === 'logs'), [['logs', DEPLOYER, '0x3e9'], ['logs', DEPLOYER, '0x7d1']]);
  assert.ok(!c.calls.some((call) => call[0] === 'scan'), 'no hook history scan');
});

test('a launch Bendystraw has not indexed yet is found by the tail scan', async () => {
  const { fetch } = bendystraw({
    StickyIndex: testnetIndex([]),
    StickyPays: () => ({ data: { payEvents: page([]) } }),
    StickyCashOuts: () => ({ data: { cashOutTokensEvents: page([]) } }),
  });
  const deploy = { topics: ['0xc00d5094bed981d0f08872f495cb40cf20020621153d33b7b379d10c953e59a1', '0x' + word(42)],
    data: '0x' + word(0) + word(500) + word(1) + word(0), blockNumber: '0x5dc' };
  const c = homeContext({ fetch, logs: async (filter) => (filter.fromBlock === '0x3e9' ? [deploy] : []) });
  const data = await c.homeChainData(84532);
  assert.deepEqual(Array.from(data.cards, (card) => card.key), ['84532:42']);
  assert.equal(await vm.runInContext('startBlockCache.get("84532:42")', c), '0x5dc', 'its creation block is remembered');
});

test('Bendystraw failing falls back to the chain scan and never shows the zero state on that alone', async () => {
  const down = bendystraw({ StickyIndex: () => ({ errors: [{ message: 'database is down' }] }) });
  const c = homeContext({ fetch: down.fetch });
  c.scannedHomeChainData = async (chainId) => {
    c.calls.push(['scanned', chainId]);
    return { chainId, cards: chainId === 1 ? [{ id: 4n, chainId: 1, key: '1:4', totalStaked: 1n, sticks: 1, launchId: null,
      info: { symbol: 'ETH', stSymbol: 'stETH', decimals: 18, reward: 0n, soulbound: true, stakedToken: '0x' + '2'.repeat(40) }, pool: { sigma: 1n } }] : [],
    moves: [], prices: new Map(), activity: [], airdrops: [] };
  };
  await c.renderHome();
  assert.deepEqual(c.calls.filter((call) => call[0] === 'scanned').map((call) => call[1]), [1, 42161]);
  assert.equal(c.home().dataset.state, 'ready');

  // Events failing after a good index is also a fallback for that chain.
  const partial = bendystraw({ StickyIndex: testnetIndex([[84532, 37]]), StickyPays: () => ({ errors: [{ message: 'timeout' }] }),
    StickyCashOuts: () => ({ data: { cashOutTokensEvents: page([]) } }) });
  const d = homeContext({ fetch: partial.fetch });
  d.scannedHomeChainData = async (chainId) => { d.calls.push(['scanned', chainId]); return { chainId, cards: [], moves: [], prices: new Map(), activity: [], airdrops: [] }; };
  await d.homeChainData(84532);
  assert.deepEqual(d.calls.filter((call) => call[0] === 'scanned'), [['scanned', 84532]]);

  // Bendystraw down and every chain scan failing is an error with a retry, not "no sticky tokens yet".
  const e = homeContext({ fetch: down.fetch });
  e.scannedHomeChainData = async () => { throw new Error('range limit'); };
  await e.renderHome();
  assert.equal(e.home().dataset.state, 'error');
});

test('an empty production index is the zero state, with no chain history scanned', async () => {
  const { fetch } = bendystraw({ StickyIndex: () => ({ data: {
    _meta: { status: status([['ethereum', 1, 26061894], ['arbitrum', 42161, 509092274]]) }, projects: page([]),
  } }) });
  const c = homeContext({ fetch });
  await c.renderHome();
  assert.equal(c.home().dataset.state, 'empty');
  assert.equal(c.$('home-note-text').textContent, 'No sticky tokens yet.');
  assert.deepEqual(c.calls.filter((call) => call[0] === 'logs').map((call) => call[2]).sort(), ['0x18dac47', '0x1e5821b3']);
  assert.ok(!c.calls.some((call) => call[0] === 'scan'));
});

// ---------------------------------------------------------------- project start block
function startContext({ fetch, receipt, counts }) {
  const rpc = [];
  const c = vm.createContext({
    TextEncoder, TextDecoder, Uint8Array, console: { warn() {} },
    window: { STICKY_CONFIG: { bendystrawUrl: 'https://prod.test', testnetBendystrawUrl: 'https://testnet.test' } },
    location: { href: 'https://sticky.center/?chain=84532#/project/37' }, URL,
    ORIGINS,
    StickyRuntime: { ...Runtime, projectCreateTx: (url, ...args) => Runtime.projectCreateTx(url, ...args, { fetch }) },
    stickyDeploymentFor: (chainId) => ({ chainId, deployer: DEPLOYER, rpcUrl: 'rpc', fromBlock: '0x10' }),
    indexedChain: async () => null,
    viewAt: async (_deployment, _to, selector) => '0x' + word(BigInt('0x' + 'c'.repeat(40))),
    rpcAt: async (_url, method, params) => {
      rpc.push(method);
      if (method === 'eth_getTransactionReceipt') { if (!receipt) throw new Error('no receipt'); return receipt; }
      if (method === 'eth_blockNumber') return '0x100';
      if (method === 'eth_call') { if (!counts) throw new Error('missing trie node'); return '0x' + word(counts(BigInt(params[1]))); }
      throw new Error(method);
    },
  });
  vm.runInContext(`${block('const SEL =')}\n${block('const TOPIC =')}\n${codec}
    const chainById = (chainId) => ORIGINS.find((origin) => origin.chainId === Number(chainId));
    const startBlockCache = new Map();
    ${constSource('bendystrawUrl')}
    ${['projectStartBlock', 'createdBlockFromIndex', 'createdBlockFromCount'].map(functionSource).join('\n')}`, c);
  c.rpc = rpc;
  return c;
}
const created = { StickyCreate: () => ({ data: { projectCreateEvents: { items: [{ txHash: '0x' + '1'.repeat(64), timestamp: 1 }] } } }) };
const deployLog = (projectId, address = DEPLOYER) => ({ address, topics: ['0xc00d5094bed981d0f08872f495cb40cf20020621153d33b7b379d10c953e59a1', '0x' + word(projectId)] });

test('a project\'s scans start at its creation block, from Bendystraw\'s creating transaction', async () => {
  const { fetch, requests } = bendystraw(created);
  const c = startContext({ fetch, receipt: { blockNumber: '0x2d0f', logs: [deployLog(37)] } });
  assert.equal(await c.projectStartBlock(84532, 37n), '0x2d0f');
  assert.deepEqual(requests[0].variables.where, { chainId: 84532, projectId: 37, version: 6 });
  assert.equal(requests[0].url, 'https://sticky.center/bendystraw/testnet/graphql', 'through the same-origin relay');
  await c.projectStartBlock(84532, 37n);
  assert.equal(requests.length, 1, 'kept for the session');
  assert.deepEqual(c.rpc, ['eth_getTransactionReceipt']);
});

test('a creating transaction without this deployer\'s DeploySticky is not trusted; JBProjects.count() is searched instead', async () => {
  const { fetch } = bendystraw(created);
  const c = startContext({ fetch, receipt: { blockNumber: '0x20', logs: [deployLog(37, OTHER), deployLog(36)] }, counts: (block) => (block >= 0xab ? 37n : 36n) });
  assert.equal(await c.projectStartBlock(84532, 37n), '0xab');
  assert.ok(c.rpc.filter((method) => method === 'eth_call').length < 16, 'a binary search, not a scan');
});

test('with no Bendystraw and no archive reads, a project scan starts at the deployment block and retries next time', async () => {
  const { fetch, requests } = bendystraw({ StickyCreate: () => ({ errors: [{ message: 'down' }] }) });
  const c = startContext({ fetch });
  assert.equal(await c.projectStartBlock(8453, 7n), '0x10');
  await c.projectStartBlock(8453, 7n);
  assert.equal(requests.length, 2, 'a failed lookup is not remembered');
});

test('the scan limit error names the span and the request budget', async () => {
  const rpc = async (method) => {
    if (method === 'eth_blockNumber') return '0x' + (1_000_000).toString(16);
    throw new Error('eth_getLogs range of 1001 blocks exceeds the 500-block limit for this plan');
  };
  await assert.rejects(Runtime.logs(rpc, { fromBlock: '0x0' }, { maxRequests: 10 }),
    /^Error: This history spans 1000001 blocks, more than this RPC can scan in 10 requests\.$/);
});
