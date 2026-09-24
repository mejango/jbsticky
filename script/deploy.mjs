import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Match the reviewed source checkouts used by CI; local file dependencies have no npm integrity hash.
export const dependencies = {
  '@bananapus/core-v6': 'feff600654aee6fb1747dded692f18068b2230a6',
  '@bananapus/distributor-v6': '79af754e642b648347aba0c7df8a3398215e74a5',
};

export function verifyDependencies(spawn = spawnSync) {
  for (const [name, expected] of Object.entries(dependencies)) {
    const args = ['-C', `node_modules/${name}`];
    const revision = spawn('git', [...args, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
    const status = spawn('git', [...args, 'status', '--porcelain', '--untracked-files=normal'], { encoding: 'utf8' });
    // Only a linked package's `src/` compiles into the contracts; tests, scratch files and Finder droppings do not.
    const sourceChanges = status.stdout?.split('\n')
      .filter(line => /^.{3}(.* -> )?src\//.test(line) && !/\/\.DS_Store$/.test(line)) ?? [];
    if (revision.status !== 0 || revision.stdout.trim() !== expected || status.status !== 0 || sourceChanges.length) {
      throw new Error(`${name} must be clean under src/ at the reviewed revision ${expected}.`);
    }
  }
}

export const networks = {
  mainnets: [
    ['ethereum', 1, 'RPC_ETHEREUM_MAINNET', 'ethereum'],
    ['optimism', 10, 'RPC_OPTIMISM_MAINNET', 'optimism'],
    ['base', 8453, 'RPC_BASE_MAINNET', 'base'],
    ['arbitrum', 42161, 'RPC_ARBITRUM_MAINNET', 'arbitrum'],
  ],
  testnets: [
    ['ethereum_sepolia', 11155111, 'RPC_ETHEREUM_SEPOLIA', 'sepolia'],
    ['optimism_sepolia', 11155420, 'RPC_OPTIMISM_SEPOLIA', 'optimism_sepolia'],
    ['base_sepolia', 84532, 'RPC_BASE_SEPOLIA', 'base_sepolia'],
    ['arbitrum_sepolia', 421614, 'RPC_ARBITRUM_SEPOLIA', 'arbitrum_sepolia'],
  ],
};

export function preflight(group, env = process.env, read = readFileSync) {
  if (!networks[group]) throw new Error('Network group must be testnets or mainnets.');
  const errors = [];
  const root = env.NANA_CORE_DEPLOYMENT_PATH || 'node_modules/@bananapus/core-v6/deployments';
  for (const [alias, chainId, variable, folder] of networks[group]) {
    if (!env[variable]?.trim()) errors.push(`${alias}: missing ${variable}`);
    for (const name of ['JBController', 'JBDirectory', 'JBMultiTerminal']) {
      const file = `${root}/${folder}/${name}.json`;
      try {
        const artifact = JSON.parse(read(file, 'utf8'));
        if (!/^0x[\da-fA-F]{40}$/.test(artifact.address || '') || /^0x0{40}$/.test(artifact.address)) {
          throw new Error('invalid contract address');
        }
        if (BigInt(artifact.chainId) !== BigInt(chainId)) throw new Error('wrong chain ID');
      } catch {
        errors.push(`${alias}: missing or invalid ${name} artifact (address/chain ID)`);
      }
    }
  }
  if (errors.length) throw new Error(errors.join('\n'));
}

// The manifest fields every chain of a group must predict identically; the core binds the same addresses everywhere.
export const suite = ['deployer', 'hook', 'distributor', 'rewardReceiverFactory', 'autoStick'];

// Every chain of a group must predict one suite.
export function requireOneAddressPerGroup(group, kind, read = readFileSync) {
  let expected;
  for (const [alias, , , folder] of networks[group]) {
    const manifest = JSON.parse(read(`deployments/${folder}/${kind}.json`, 'utf8'));
    const identity = suite.map(field => `${field}=${String(manifest[field]).toLowerCase()}`).join(' ');
    expected ??= identity;
    if (identity !== expected) throw new Error(`${alias} predicts a different deployment than the rest of ${group}: ${identity}`);
  }
}

export function run(action, group, { env = process.env, spawn = spawnSync, read = readFileSync } = {}) {
  if (!['preflight', 'rehearse', 'propose', 'verify', 'artifacts'].includes(action)) {
    throw new Error('Usage: deploy.sh <preflight|rehearse|propose|verify|artifacts> <testnets|mainnets>');
  }
  preflight(group, env, read);
  if (action === 'propose') {
    for (const key of ['SPHINX_MANAGED_BASE_URL', 'SPHINX_ORG_ID', 'SPHINX_API_KEY']) {
      if (!env[key]?.trim()) throw new Error(`Missing ${key}`);
    }
    // Sphinx resolves the organization and Safe from this public lock before collecting any transactions.
    let lock;
    let projectName;
    try {
      lock = JSON.parse(read('sphinx.lock', 'utf8'));
      projectName = read('script/Deploy.s.sol', 'utf8').match(/sphinxConfig\.projectName\s*=\s*"([^"]+)"/)?.[1];
      if (!projectName || lock.projects?.[projectName]?.projectName !== projectName) throw new Error();
    } catch {
      throw new Error('The committed sphinx.lock must contain the deployment script\'s registered Sphinx project.');
    }
    if (lock.orgId !== env.SPHINX_ORG_ID.trim()) {
      throw new Error('SPHINX_ORG_ID does not match the committed sphinx.lock organization.');
    }
  }
  if (action !== 'rehearse') verifyDependencies(spawn);
  if (action === 'preflight') return;
  const revision = spawn('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (revision.status !== 0) throw new Error('Cannot record the source revision.');
  const status = spawn('git', ['status', '--porcelain', '--untracked-files=normal'], { encoding: 'utf8' });
  if (status.status !== 0) throw new Error('Cannot inspect the source checkout.');
  // The runner's own outputs under deployments/ do not make the reviewed source dirty.
  const dirty = status.stdout.split('\n').some(line => line.trim() && !/^.{3}deployments\//.test(line));
  // Only a committed checkout may reach the Safe or certify a live deployment; rehearsals may carry development changes.
  if (dirty && action !== 'rehearse') throw new Error(`Commit the reviewed checkout before ${action}; it has uncommitted changes.`);
  const childEnv = {
    ...env, FOUNDRY_PROFILE: 'deploy',
    STICKY_REVISION: revision.stdout.trim() + (dirty ? '-dirty' : ''),
  };
  const execute = (command, args, chainId = 0, block = { number: '0', hash: '0x' + '00'.repeat(32) }) => {
    const result = spawn(command, args, { env: {
      ...childEnv, STICKY_EXPECTED_CHAIN_ID: String(chainId),
      STICKY_RPC_BLOCK_NUMBER: block.number, STICKY_RPC_BLOCK_HASH: block.hash,
    }, stdio: 'inherit' });
    if (result.error || result.status !== 0) throw new Error(`${command} failed; stopping ${group} ${action}.`);
  };
  // Explorer verification and per-contract artifacts read the verified manifests, so they follow a verify.
  if (action === 'artifacts') {
    execute('node', ['script/artifacts.mjs', group]);
    return;
  }
  // Rehearse every destination successfully before creating a Sphinx proposal.
  const script = action === 'verify' ? 'Verify' : 'Rehearse';
  for (const [alias, chainId] of networks[group]) {
    console.log(`${action}: ${alias}`);
    // RPC block heights identify fork state even on chains where EVM block.number means an L1 height.
    const header = spawn('cast', ['block', 'latest', '--json', '--rpc-url', alias], { env: childEnv, encoding: 'utf8' });
    let block;
    try {
      if (header.status !== 0) throw new Error();
      const payload = JSON.parse(header.stdout);
      if (payload.success === false) throw new Error();
      block = payload.data ?? payload;
      block.number = BigInt(block.number).toString();
      if (BigInt(block.number) <= 0n || !/^0x[\da-fA-F]{64}$/.test(block.hash)) throw new Error();
    } catch {
      throw new Error(`${alias}: cannot read a canonical RPC block; stopping ${action}.`);
    }
    execute('forge', ['script', `script/${script}.s.sol:${script}`, '--rpc-url', alias,
      '--fork-block-number', block.number, '-vv'], chainId, block);
  }
  requireOneAddressPerGroup(group, script === 'Verify' ? 'verified' : 'simulation', read);
  if (action === 'propose') {
    execute('node_modules/.bin/sphinx', ['propose', 'script/Deploy.s.sol', '--target-contract', 'Deploy', '--networks', group]);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: deploy.sh <preflight|rehearse|propose|verify|artifacts> <testnets|mainnets>');
    run(process.argv[2], process.argv[3]);
    console.log(`Sticky ${process.argv[2]} completed for ${process.argv[3]}.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
