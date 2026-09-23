import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { dependencies, networks, preflight, run, verifyDependencies } from '../../script/deploy.mjs';

function fixture(group) {
  const env = { SPHINX_ORG_ID: JSON.parse(readFileSync('sphinx.lock')).orgId, SPHINX_API_KEY: 'test-key',
    SPHINX_MANAGED_BASE_URL: 'https://sphinx.example.test' };
  const files = {};
  for (const [, chainId, key, folder] of networks[group]) {
    env[key] = 'http://127.0.0.1:8545';
    for (const name of ['JBController', 'JBDirectory', 'JBMultiTerminal']) {
      files[`node_modules/@bananapus/core-v6/deployments/${folder}/${name}.json`] = JSON.stringify({
        address: '0x' + '12'.repeat(20), chainId: `0x${chainId.toString(16)}`,
      });
    }
  }
  return { env, read: file => files[file] ?? readFileSync(file, 'utf8') };
}

const block = { number: '0x64', hash: '0x' + 'ab'.repeat(32) };
function readOnlyTool(command, args) {
  if (command === 'cast') return { status: 0, stdout: JSON.stringify({ schema_version: 1, success: true, data: block }) };
  if (command !== 'git') return;
  if (args[0] === '-C') {
    return { status: 0, stdout: args[2] === 'rev-parse' ? dependencies[args[1].replace('node_modules/', '')] : '' };
  }
  return { status: 0, stdout: args[0] === 'rev-parse' ? 'abc123\n' : '' };
}

for (const group of Object.keys(networks)) {
  test(`${group}: all four rehearsals precede the Sphinx proposal`, () => {
    const calls = [];
    run('propose', group, { ...fixture(group), spawn(command, args, options) {
      const tool = readOnlyTool(command, args);
      if (tool) return tool;
      calls.push({ command, args, chainId: options.env.STICKY_EXPECTED_CHAIN_ID });
      assert.equal(options.env.FOUNDRY_PROFILE, 'deploy');
      assert.equal(options.env.STICKY_REVISION, 'abc123');
      if (command === 'forge') {
        assert.equal(options.env.STICKY_RPC_BLOCK_NUMBER, '100');
        assert.equal(options.env.STICKY_RPC_BLOCK_HASH, block.hash);
        assert.deepEqual(args.slice(4, 6), ['--fork-block-number', '100']);
      }
      return { status: 0 };
    } });
    assert.deepEqual(calls.slice(0, 4).map(call => call.args[3]), networks[group].map(([alias]) => alias));
    assert.deepEqual(calls.slice(0, 4).map(call => call.chainId), networks[group].map(([, id]) => String(id)));
    assert.equal(calls[4].chainId, '0');
    assert.equal(calls[4].command, 'node_modules/.bin/sphinx');
    assert.deepEqual(calls[4].args.slice(-2), ['--networks', group]);
    assert.equal(calls.length, 5);
  });
}

test('failed rehearsal prevents proposal submission and remaining execution', () => {
  let attempts = 0;
  assert.throws(() => run('propose', 'testnets', { ...fixture('testnets'), spawn(command, args) {
    const tool = readOnlyTool(command, args);
    if (tool) return tool;
    attempts++;
    assert.equal(command, 'forge');
    return { status: 1 };
  } }), /stopping/);
  assert.equal(attempts, 1);
});

test('verification only runs read-only Verify on every destination', () => {
  let attempts = 0;
  run('verify', 'mainnets', { ...fixture('mainnets'), spawn(command, args) {
    const tool = readOnlyTool(command, args);
    if (tool) return tool;
    attempts++;
    assert.equal(command, 'forge');
    assert.equal(args[1], 'script/Verify.s.sol:Verify');
    assert.ok(!args.includes('--broadcast'));
    return { status: 0 };
  } });
  assert.equal(attempts, 4);
});

test('preflight rejects missing RPCs and mismatched artifacts without leaking values', () => {
  const { env, read } = fixture('testnets');
  delete env.RPC_BASE_SEPOLIA;
  assert.throws(() => preflight('testnets', env, read), /missing RPC_BASE_SEPOLIA/);
  assert.throws(() => preflight('mainnets', env, () => JSON.stringify({ address: '0x' + '12'.repeat(20), chainId: 1 })), /invalid JBController/);
  assert.throws(() => preflight('unknown'), /Network group/);
});

test('missing proposal credentials fail before any child process starts', () => {
  const setup = fixture('testnets');
  delete setup.env.SPHINX_API_KEY;
  assert.throws(() => run('propose', 'testnets', { ...setup, spawn() { assert.fail('must not execute'); } }), /Missing SPHINX_API_KEY/);
});


test('runner destinations match the Sphinx entrypoint exactly', () => {
  const source = readFileSync('script/Deploy.s.sol', 'utf8');
  for (const group of Object.keys(networks)) {
    const line = source.split('\n').find(line => line.includes(`sphinxConfig.${group} =`));
    const configured = JSON.parse(line.slice(line.indexOf('['), line.lastIndexOf(']') + 1));
    assert.deepEqual(networks[group].map(([alias]) => alias), configured);
  }
});


test('release dependencies must match pinned clean sources', () => {
  verifyDependencies(readOnlyTool);
  assert.throws(() => verifyDependencies((command, args) => ({ status: 0, stdout: args[2] === 'rev-parse' ? 'wrong' : '' })), /reviewed revision/);
  assert.throws(() => verifyDependencies((command, args) => args[2] === 'status'
    ? { status: 0, stdout: ' M src/JBController.sol' } : readOnlyTool(command, args)), /must be clean/);
  const workflow = readFileSync('.github/workflows/test.yml', 'utf8');
  for (const revision of Object.values(dependencies)) assert.ok(workflow.includes(revision));
});

test('missing block identity stops before any Forge or Sphinx execution', () => {
  assert.throws(() => run('rehearse', 'testnets', { ...fixture('testnets'), spawn(command, args) {
    if (command === 'cast') return { status: 1, stdout: '' };
    assert.equal(command, 'git');
    return readOnlyTool(command, args);
  } }), /canonical RPC block/);
});

test('proposal rejects a missing lock, wrong organization, or unregistered project', () => {
  for (const fault of ['missing', 'organization', 'project']) {
    const setup = fixture('testnets');
    const read = setup.read;
    setup.read = file => {
      if (file !== 'sphinx.lock') return read(file);
      if (fault === 'missing') throw new Error('not found');
      const lock = JSON.parse(read(file));
      if (fault === 'organization') lock.orgId = 'different-org';
      if (fault === 'project') lock.projects = {};
      return JSON.stringify(lock);
    };
    assert.throws(() => run('propose', 'testnets', { ...setup, spawn() { assert.fail('must not execute'); } }));
  }
});
