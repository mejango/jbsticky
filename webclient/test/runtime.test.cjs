const { test } = require("node:test");
const assert = require("node:assert/strict");
const { address, assetUrl, deployment, jsonRpc, logs } = require("../runtime.js");
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require.resolve('../app.js'), 'utf8');
const abi = vm.runInNewContext(source.slice(source.indexOf('const strip ='), source.indexOf('// ------------------------------------------------------------- rpc plumbing'))
  + '\n({word, encAddress, decUint, decAddress, decString, decTranches, encode, hexToBytes})', {TextEncoder, TextDecoder});

test("metadata image URLs cannot inject markup or execute scripts", () => {
  assert.equal(assetUrl('javascript:alert(1)'), null);
  assert.equal(assetUrl('data:image/svg+xml,<svg onload="alert(1)">'), null);
  assert.equal(assetUrl('https://user:secret@example.com/logo'), null);
  assert.equal(assetUrl('ipfs://ipfs/bafy/logo.png'), 'https://ipfs.io/ipfs/bafy/logo.png');
  assert.equal(assetUrl('artizen.jpg', true), 'artizen.jpg');
  assert.equal(assetUrl('artizen.jpg'), null);
  assert.equal(assetUrl('../private.png', true), null);
  assert.equal(assetUrl('//evil.example/a.png', true), null);
  assert.equal(assetUrl('javascript:alert(1)', true), null);
  assert.equal(assetUrl('https://example.com/\" onerror=\"alert(1)'), 'https://example.com/%22%20onerror=%22alert(1)');
  assert.throws(() => address('0x' + '0'.repeat(40)));
});
test("a generated default deployment never enables an unconfigured chain", () => {
  const config = {defaultChainId:1,deployer:'main',distributor:'reward',chains:{1:{deployer:'main'},10:{rpcUrl:'op'}}};
  assert.equal(deployment(config,1).deployer,'main');
  assert.equal(deployment(config,10).deployer,undefined);
  assert.equal(deployment(config,10).distributor,undefined);
  assert.equal(deployment(config,8453).deployer,undefined);
  assert.equal(deployment({...config,chains:{10:{deployer:'op'}}},10).deployer,'op');
  assert.equal(deployment({deployer:'legacy',chains:{}},10).deployer,'legacy');
  assert.equal(deployment({deployer:'legacy',chains:{10:{deployer:''}}},10).deployer,'');
});
test("RPC rejects HTTP, malformed and missing-result responses while preserving reverts", async () => {
  const fetch = body => async () => ({ ok: true, json: async () => body });
  await assert.rejects(jsonRpc('rpc', 'eth_call', [], { fetch: async () => ({ ok: false, status: 503 }) }), /503/);
  await assert.rejects(jsonRpc('rpc', 'eth_call', [], { fetch: fetch({}) }), /no result/);
  await assert.rejects(jsonRpc('rpc', 'eth_call', [], { fetch: fetch({ error: { code: 3, message: 'execution reverted', data: '0x1234' } }) }), error => error.code === 3 && error.data === '0x1234');
  assert.equal(await jsonRpc('rpc', 'eth_call', [], { fetch: fetch({ result: null }) }), null);
});
test("range-limited logs are complete, ordered and deduplicated", async () => {
  const entry = n => ({ blockNumber: `0x${n.toString(16)}`, blockHash: `block${n}`, logIndex: '0x0', transactionHash: `tx${n}` });
  const result = await logs(async (method, [filter] = []) => {
    if (method === 'eth_blockNumber') return '0x7';
    const from = Number(BigInt(filter.fromBlock)), to = Number(BigInt(filter.toBlock));
    if (to - from > 2) throw new Error('block range exceeds limit');
    return Array.from({ length: to - from + 1 }, (_, i) => entry(to - i)).flatMap(row => [row, row]);
  }, { fromBlock: '0x2' });
  assert.deepEqual(result.map(row => Number(BigInt(row.blockNumber))), [2, 3, 4, 5, 6, 7]);
});
test("failed historical ranges never produce partial history", async () => {
  await assert.rejects(logs(async (method, [filter] = []) => {
    if (method === 'eth_blockNumber') return '0x2';
    if (filter.fromBlock === filter.toBlock) throw new Error('archive unavailable');
    throw new Error('range limit');
  }, { fromBlock: '0x0' }), /archive unavailable/);
});
test("malformed contract results are never interpreted as a zero balance or usable address", () => {
  for (const invalid of ['0x', '0x01', '0x' + 'g'.repeat(64)]) assert.throws(() => abi.decUint(invalid));
  assert.throws(() => abi.decAddress('0x' + 'ff'.repeat(32)));
  assert.throws(() => abi.encAddress('0x1234'));
  assert.throws(() => abi.word(-1));
  assert.throws(() => abi.word(2n ** 256n));
  assert.throws(() => abi.hexToBytes('0xzz'));
});
test("ERC20 string and bytes32 metadata are decoded without trusting offsets or lengths", () => {
  assert.equal(abi.decString('0x' + abi.encode(['string'], ['Sticky'])), 'Sticky');
  assert.equal(abi.decString('0x' + Buffer.from('ART').toString('hex').padEnd(64, '0')), 'ART');
  assert.throws(() => abi.decString('0x' + abi.word(2n ** 255n) + abi.word(100)));
  assert.throws(() => abi.decString('0x' + abi.word(32) + abi.word(100)));
  assert.throws(() => abi.decTranches('0x' + abi.word(32) + abi.word(2n ** 255n)));
});
