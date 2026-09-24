'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(require.resolve('../app.js'), 'utf8');
const A = digit => `0x${digit.repeat(40)}`;
const H = digit => `0x${digit.repeat(64)}`;

function functionSource(name) {
  const match = new RegExp(`(?:^|\\n)(?:async )?function ${name}\\(`).exec(source);
  assert.ok(match, `missing ${name}`);
  const start = match.index + (source[match.index] === '\n' ? 1 : 0);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}

test('bridge preparation stops if navigation changes the destination project during its quote', async () => {
  const owner = A('1');
  const route = {
    source: { chainId: 1, name: 'Ethereum' },
    destination: { chainId: 10, name: 'Optimism' },
    sourceToken: A('2'), sourceSucker: A('3'), rewardToken: A('4'), backingToken: A('5'),
    sourceMeta: { symbol: 'OLD', decimals: 0 }, rewardMeta: { symbol: 'OLD', decimals: 0 },
  };
  const oldContext = {
    source: route.source, destination: route.destination, owner, receiver: A('6'),
    info: { symbol: 'OLD', stToken: A('7') }, key: 'old-project-bridge',
  };
  const fields = {
    'bridge-source-token': { value: route.sourceToken },
    'bridge-route': { value: '0' },
    'bridge-amount': { value: '1' },
  };
  const stored = new Map();
  let reviews = 0;
  const context = vm.createContext({
    ctx: { chainId: 10, currentId: 7n },
    bridgeRoutes: [route],
    localStorage: {
      getItem: key => stored.get(key) ?? null,
      setItem: (key, value) => stored.set(key, value),
    },
    navigator: { locks: { request: async (_name, _options, fn) => fn({}) } },
    crypto: { getRandomValues: bytes => bytes.fill(8) },
    Uint8Array,
    $: id => fields[id] ||= { value: '' },
    bridgeContext: async () => oldContext,
    getTxEngine: () => ({ load: () => null, discardUnsubmitted: async () => {} }),
    getBridgeApi: () => ({
      movements: async () => [],
      prepare: async ({ metadata }) => {
        // A same-chain SPA navigation can finish while the two-chain quote is in flight.
        context.ctx.currentId = 8n;
        return { txs: [{
          chainId: 1, from: owner, to: route.sourceSucker, data: '0xaf629bbb' + '00'.repeat(160),
          sessionTag: `sticky-bridge:${metadata}`,
        }] };
      },
    }),
    rehydrateBridgeRoute: value => value,
    reconcileBridgeRecord: async () => true,
    parseUnits: BigInt,
    formatUnits: String,
    stickyLabel: info => `Sticky ${info.symbol}`,
    confirmAndRun: async () => { reviews++; return true; },
    txStatus() {},
  });

  vm.runInContext([
    'bridgeRecords', 'saveBridgeRecords', 'mutateBridgeRecords', 'discardBridgeDraft',
    'prepareBridgeFunding',
  ].map(functionSource).join('\n'), context);

  await assert.rejects(context.prepareBridgeFunding(), /project changed|review this bridge again/i);
  assert.equal(reviews, 0, 'a stale destination must not reach wallet review');
  assert.equal(stored.get(oldContext.key), undefined, 'a stale quote must not leave recovery state');
});
