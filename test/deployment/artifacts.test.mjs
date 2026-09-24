import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { constructorArgs, contracts, emit } from '../../script/artifacts.mjs';
import { networks, suite } from '../../script/deploy.mjs';

const code = '0x6080604052';
const addresses = {
  controller: '0x' + '11'.repeat(20), directory: '0x' + '22'.repeat(20), terminal: '0x' + '33'.repeat(20),
  deployer: '0x' + 'a1'.repeat(20), hook: '0x' + 'a2'.repeat(20), distributor: '0x' + 'a3'.repeat(20),
  rewardReceiverFactory: '0x' + 'a4'.repeat(20), autoStick: '0x' + 'a5'.repeat(20),
};
const word = value => BigInt(value).toString(16).padStart(64, '0');
const expectedArgs = {
  StickyDeployer: [addresses.controller, addresses.terminal],
  StickyHook: [addresses.directory, addresses.deployer],
  StickyDistributor: [addresses.controller, addresses.directory, addresses.hook, '604800', '4', '63072000'],
  StickyRewardReceiverFactory: [addresses.distributor],
  StickyAutoStick: [addresses.deployer, addresses.distributor],
};

function artifact(name) {
  return JSON.stringify({
    abi: [{ type: 'constructor', inputs: expectedArgs[name].map(value => ({ type: value.startsWith('0x') ? 'address' : 'uint256' })) }],
    bytecode: { object: code }, deployedBytecode: { object: '0x60' }, rawMetadata: `{"${name}":true}`,
  });
}

function fixture(group, { revision = 'abc123' } = {}) {
  const files = {};
  for (const [, , , folder] of networks[group]) {
    files[`deployments/${folder}/verified.json`] = JSON.stringify({ ...addresses, revision });
  }
  for (const { name } of contracts) files[`out/${name}.sol/${name}.json`] = artifact(name);
  const written = {};
  const verified = [];
  const fetched = [];
  return {
    written, verified, fetched,
    options: {
      env: { ETHERSCAN_API_KEY: 'key' },
      read: file => { if (!files[file]) throw new Error(`missing ${file}`); return files[file]; },
      write: (file, content) => { written[file] = JSON.parse(content); },
      spawn: (command, args) => { verified.push({ command, args }); return { status: 0, stdout: '' }; },
      async fetchJson(url) {
        fetched.push(url);
        const { searchParams } = new URL(url);
        if (searchParams.get('action') === 'getcontractcreation') {
          const address = searchParams.get('contractaddresses');
          const name = contracts.find(contract => addresses[contract.field] === address).name;
          const child = name === 'StickyHook';
          return { result: [{ txHash: `0xtx-${child ? 'StickyDeployer' : name}`,
            creationBytecode: child ? undefined : `${code}${expectedArgs[name].map(word).join('')}` }] };
        }
        return { result: { blockHash: '0x' + 'bb'.repeat(32), transactionHash: searchParams.get('txhash') } };
      },
    },
  };
}

test('the artifact contracts cover the whole suite the runner compares across chains', () => {
  assert.deepEqual(contracts.map(contract => contract.field), suite);
});

for (const group of Object.keys(networks)) {
  test(`${group}: every contract is verified on the explorer and written in the shared artifact layout`, async () => {
    const { written, verified, options } = fixture(group);
    await emit(group, options);
    for (const [alias, chainId, , folder] of networks[group]) {
      for (const contract of contracts) {
        const record = written[`deployments/${folder}/${contract.name}.json`];
        assert.ok(record, `${alias} must write ${contract.name}.json`);
        assert.equal(record.format, 'sphinx-sol-ct-artifact-1');
        assert.equal(record.address, addresses[contract.field].toLowerCase());
        assert.equal(record.sourceName, `src/${contract.name}.sol`);
        assert.equal(record.contractName, contract.name);
        assert.equal(record.chainId, `0x${chainId.toString(16)}`);
        assert.deepEqual(record.args, expectedArgs[contract.name]);
        assert.equal(record.bytecode, code);
        assert.equal(record.gitCommit, 'abc123');
        assert.equal(record.gitDirty, false);
        assert.equal(record.receipt.blockHash, '0x' + 'bb'.repeat(32));
        assert.deepEqual(record.history, []);
      }
      // The hook is created by the deployer's constructor, so its receipt is the deployer's creation transaction.
      assert.equal(written[`deployments/${folder}/StickyHook.json`].receipt.transactionHash, '0xtx-StickyDeployer');
    }
    assert.equal(verified.length, networks[group].length * contracts.length);
    for (const { command, args } of verified) {
      assert.equal(command, 'forge');
      assert.equal(args[0], 'verify-contract');
      const name = args[2].split(':')[1];
      assert.deepEqual(args.slice(-2), ['--constructor-args', `0x${expectedArgs[name].map(word).join('')}`]);
      assert.ok(args.includes('--via-ir') && args.includes('--skip-is-verified-check'));
      assert.ok(!args.includes('--broadcast'));
    }
    const chainIds = new Set(verified.map(({ args }) => args[args.indexOf('--chain-id') + 1]));
    assert.deepEqual([...chainIds], networks[group].map(([, chainId]) => String(chainId)));
  });
}

test('a dirty revision is recorded as such, and a missing explorer key stops before any read', async () => {
  const dirty = fixture('testnets', { revision: 'abc123-dirty' });
  await emit('testnets', dirty.options);
  assert.equal(dirty.written['deployments/sepolia/StickyDeployer.json'].gitDirty, true);
  const { options, fetched } = fixture('testnets');
  await assert.rejects(emit('testnets', { ...options, env: {} }), /Missing ETHERSCAN_API_KEY/);
  assert.equal(fetched.length, 0);
  await assert.rejects(emit('unknown', options), /Network group/);
});

test('creation bytecode that disagrees with the recorded bindings stops the group', async () => {
  const { options, written } = fixture('mainnets');
  const fetchJson = options.fetchJson;
  options.fetchJson = async url => {
    const body = await fetchJson(url);
    if (body.result?.[0]?.creationBytecode && url.includes(addresses.distributor)) {
      body.result[0].creationBytecode = `${code}${word(addresses.controller)}`;
    }
    return body;
  };
  await assert.rejects(emit('mainnets', options), /creation bytecode of StickyDistributor/);
  assert.ok(!written['deployments/ethereum/StickyDistributor.json']);
});

test('explorer verification failure stops the group, but an already verified source does not', async () => {
  const failing = fixture('testnets');
  failing.options.spawn = () => ({ status: 1, stdout: 'Compiler error' });
  await assert.rejects(emit('testnets', failing.options), /explorer verification of StickyDeployer failed/);
  const verified = fixture('testnets');
  verified.options.spawn = () => ({ status: 1, stderr: 'Contract source code already verified' });
  await emit('testnets', verified.options);
  assert.equal(Object.keys(verified.written).length, networks.testnets.length * contracts.length);
});

test('constructor bindings are encoded from the manifest and rejected when the compiled constructor changes', () => {
  const manifest = { ...addresses };
  const distributor = contracts.find(contract => contract.name === 'StickyDistributor');
  const { args, argsHex } = constructorArgs(distributor, manifest, JSON.parse(artifact('StickyDistributor')));
  assert.deepEqual(args, expectedArgs.StickyDistributor);
  assert.equal(argsHex, expectedArgs.StickyDistributor.map(word).join(''));
  assert.throws(() => constructorArgs(distributor, manifest, { abi: [{ type: 'constructor', inputs: [{ type: 'address' }] }] }), /no longer matches/);
  assert.throws(() => constructorArgs(distributor, manifest, { abi: [{ type: 'constructor',
    inputs: [...Array(5).fill({ type: 'address' }), { type: 'bytes' }] }] }), /no longer matches/);
  assert.throws(() => constructorArgs(distributor, { ...manifest, hook: undefined }, JSON.parse(artifact('StickyDistributor'))), /no hook address/);
  // The compiled distributor takes exactly the policy the helper encodes.
  const compiled = JSON.parse(readFileSync('out/StickyDistributor.sol/StickyDistributor.json', 'utf8'));
  assert.deepEqual(compiled.abi.find(entry => entry.type === 'constructor').inputs.map(input => input.type),
    ['address', 'address', 'address', 'uint256', 'uint256', 'uint48']);
});
