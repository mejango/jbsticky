const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const { readFileSync } = require('node:fs')
const { createServer } = require('node:http')
const { once } = require('node:events')
const test = require('node:test')

const { checkRequiredTomlOptions } = require('@sphinx-labs/plugins/dist/foundry/options')
const { assertValidVersions, validateProposalNetworks } = require('@sphinx-labs/plugins/dist/foundry/utils')

// Exercise the installed Sphinx validator and its real JSON-RPC client without contacting public networks.
test('Sphinx accepts both configured network groups and the required Foundry artifact output', async () => {
  const result = spawnSync('forge', ['config', '--json'], { encoding: 'utf8', env: { ...process.env, FOUNDRY_PROFILE: 'deploy' } })
  assert.equal(result.status, 0, result.stderr)
  const config = JSON.parse(result.stdout)
  checkRequiredTomlOptions({ extraOutput: config.extra_output })
  assert.equal(config.isolate, false, "Sphinx deployment profile must use its compatible call model")

  const source = readFileSync('script/Deploy.s.sol', 'utf8')
  const mainnets = JSON.parse(source.match(/sphinxConfig\.mainnets\s*=\s*(\[[^;]+\]);/)[1])
  const testnets = JSON.parse(source.match(/sphinxConfig\.testnets\s*=\s*(\[[^;]+\]);/)[1])
  const chainIds = {
    ethereum: 1, optimism: 10, base: 8453, arbitrum: 42161,
    ethereum_sepolia: 11155111, optimism_sepolia: 11155420,
    base_sepolia: 84532, arbitrum_sepolia: 421614,
  }
  const requested = new Set()
  const server = createServer(async (req, res) => {
    const alias = req.url.slice(1)
    assert.ok(chainIds[alias], `Unexpected RPC alias: ${alias}`)
    const chunks = []
    for await (const chunk of req) chunks.push(chunk)
    const payload = JSON.parse(Buffer.concat(chunks))
    const answer = (request) => {
      assert.equal(request.method, 'eth_chainId')
      requested.add(alias)
      return { jsonrpc: '2.0', id: request.id, result: `0x${chainIds[alias].toString(16)}` }
    }
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify(Array.isArray(payload) ? payload.map(answer) : answer(payload)))
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  try {
    const endpoints = Object.fromEntries(Object.keys(chainIds).map((alias) => {
      assert.ok(config.rpc_endpoints[alias], `Missing Foundry RPC mapping: ${alias}`)
      return [alias, `http://127.0.0.1:${server.address().port}/${alias}`]
    }))
    const mainnet = await validateProposalNetworks(['mainnets'], testnets, mainnets, endpoints)
    assert.equal(mainnet.isTestnet, false)
    assert.equal(mainnet.rpcUrls.length, 4)
    const testnet = await validateProposalNetworks(['testnets'], testnets, mainnets, endpoints)
    assert.equal(testnet.isTestnet, true)
    assert.equal(testnet.rpcUrls.length, 4)
    assert.deepEqual([...requested].sort(), Object.keys(chainIds).sort())
  } finally {
    server.closeAllConnections()
    await new Promise((resolve) => server.close(resolve))
  }
})

// This invokes Sphinx's own local compatibility probe; it does not collect a proposal or use an RPC.
test('the installed Sphinx library and pinned Foundry state-diff recorder are compatible', async () => {
  const previous = process.env.FOUNDRY_PROFILE
  process.env.FOUNDRY_PROFILE = 'deploy'
  try {
    await assertValidVersions('script/Deploy.s.sol', 'Deploy')
  } finally {
    if (previous === undefined) delete process.env.FOUNDRY_PROFILE
    else process.env.FOUNDRY_PROFILE = previous
  }
})
