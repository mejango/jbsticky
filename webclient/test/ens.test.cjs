'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../app.js'), 'utf8');
const slice = (start, end) => source.slice(source.indexOf(start), source.indexOf(end));
const ADDRESS = '0x' + '11'.repeat(20);

function fixture(chainId) {
  const calls = [];
  const c = vm.createContext({
    ctx: { chainId, controller: '0xcontroller' },
    StickyRuntime: { jsonRpc: async (url, method, params) => { calls.push(params[0].to); return '0x'; } },
    window: { STICKY_CONFIG: {} },
    SEL: { ensReverseWithGateways: '0x', handleOf: '0x', PROJECTS: '0x', ownerOf: '0x' },
    word: () => '', strip: value => value.slice(2), decString: () => null,
    decAddress: () => ADDRESS, view: async () => '0x',
  });
  vm.runInContext(slice('const ensAvailable', '// @handle -> the sticky token')
    + slice('const ORIGINS = [', 'function stickyDeploymentFor'), c);
  return { c, calls };
}

test('ENS names and project handles are read only on production chains', async () => {
  for (const chainId of [1, 8453]) {
    const { c, calls } = fixture(chainId);
    await c.reverseEns(ADDRESS);
    await c.verifiedHandleOf(1n);
    assert.equal(calls.length, 2, `chain ${chainId}`);
  }
  for (const chainId of [11155111, 84532]) {
    const { c, calls } = fixture(chainId);
    assert.equal(await c.reverseEns(ADDRESS), null);
    assert.equal(await c.verifiedHandleOf(1n), null);
    assert.deepEqual(calls, [], `chain ${chainId}`);
  }
});
