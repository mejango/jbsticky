const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../app.js'), 'utf8');
const address = (digit) => `0x${digit.repeat(40)}`;
const HOLDER = address('1');
const TOKEN = address('2');
const STICKY = address('3');
const TERMINAL = address('4');
const DISTRIBUTOR = address('5');
const ADAPTER = address('6');
const POCKETS = address('7');
const POCKET = address('8');
const OTHER = address('9');
const NATIVE = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const uint = (value) => `0x${BigInt(value).toString(16).padStart(64, '0')}`;
const words = (...values) => `0x${values.map((value) => uint(value).slice(2)).join('')}`;
const mintQuote = (mint) => words(...Array(9).fill(0), mint, 0, 384, 0);
const arg = (data, index) => BigInt(`0x${data.slice(10 + index * 64, 10 + (index + 1) * 64)}`);

function functionSource(name) {
  const match = new RegExp(`(?:^|\\n)(?:async )?function ${name}\\(`).exec(source);
  assert.ok(match, `missing function ${name}`);
  const start = match.index + (source[match.index] === '\n' ? 1 : 0);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}

const names = [
  'formatUnits', 'parseUnits', 'formatDuration', 'actionAddress', 'rewardTokenAddress', 'positiveAmount',
  'beginAction', 'reviewAction', 'actionCall', 'hasRewardsToVest', 'requireTokenBalance', 'tokenApprovalTxs',
  'rewardTokenMeta', 'asApproveTx', 'asTrustTx', 'asConfigTx', 'asDisableTxs', 'setTrust', 'fundRewards',
  'claimReward', 'saveAutoStick', 'toggleAutoStick', 'repairAutoStick', 'autoStickNow', 'beginAutoStickVesting',
  'claimAndStick', 'settleArrivals', 'stake', 'curveReclaim', 'previewStickMint', 'unstake', 'transferSticky',
  'readTranchePage', 'poolBacking', 'homeSecuredSeries', 'asStatusLine', 'renderStickQuote',
];

function fixture(overrides = {}) {
  const info = { stakedToken: TOKEN, stToken: STICKY, symbol: 'ART', stSymbol: 'STICKYART', decimals: 6, reward: 1000n };
  const fields = new Map();
  const plans = [];
  const reads = [];
  const context = vm.createContext({
    TextEncoder, TextDecoder, Uint8Array, console,
    ctx: { chainId: 1, currentId: 12n, terminal: TERMINAL, hook: POCKETS, store: DISTRIBUTOR, autoStick: null },
    window: {},
    $: (id) => {
      if (!fields.has(id)) fields.set(id, { value: '', close() {} });
      return fields.get(id);
    },
    txAccount: () => HOLDER,
    account: () => HOLDER,
    distributor: () => DISTRIBUTOR,
    autoStickAdapter: () => ADAPTER,
    stickyDeploymentFor: () => ({ pockets: POCKETS }),
    projectInfo: async () => info,
    stickyLabel: () => 'Sticky Artizen',
    shortAddr: (value) => value,
    rewardTokens: {},
    view: async (to, selector, args) => {
      reads.push({ to, selector, args });
      if (selector === '0xdd62ed3e') return uint(0);
      if (selector === '0x70a08231') return uint(100_000_000);
      if (selector === '0x95d89b41') return `0x${context.encode(['string'], ['ART'])}`;
      if (selector === '0x313ce567') return uint(6);
      return uint(0);
    },
    rpc: async (method, params) => {
      if (method === 'eth_call') return params[0].data.startsWith('0x0aff0c31') ? mintQuote(777n) : uint(123456);
      if (method === 'eth_getBalance') return uint(10n ** 20n);
      if (method === 'eth_getBlockByNumber') return { timestamp: uint(1000) };
      throw new Error(`unexpected RPC ${method}`);
    },
    confirmAndRun: async (title, txs, summary) => { plans.push({ title, txs, summary }); return true; },
    txStatus() {}, renderRewards: async () => {}, renderProject: async () => {}, renderTrustedSenders: async () => {},
  });
  const selectorsStart = source.indexOf('const SEL =');
  const selectors = source.slice(selectorsStart, source.indexOf('\n};', selectorsStart) + 3);
  const codec = source.slice(source.indexOf('const strip ='), source.indexOf('// ------------------------------------------------------------- rpc plumbing'));
  vm.runInContext(`${selectors}\n${codec}\nconst NATIVE_REWARD_TOKEN = '${NATIVE}';\nconst UNLIMITED = (1n << 256n) - 1n;\nconst MAX_TAX = 10000n;\nlet stickQuoteSequence = 0;\nconst AS_STATUS = { READY: 0, DISABLED: 1, INVALID_PROJECT: 2, INSUFFICIENT_ALLOWANCE: 6, ZERO_ISSUANCE: 7 };\n${names.map(functionSource).join('\n')}`, context);
  context.autoStickState = async () => null;
  Object.assign(context, overrides);
  return { context, fields, info, plans, reads };
}

test('amounts preserve token precision, including zero-decimal tokens', () => {
  const { context: c } = fixture();
  assert.equal(c.parseUnits('.000001', 6), 1n);
  assert.equal(c.parseUnits('12.000001', 6), 12000001n);
  assert.equal(c.parseUnits('12', 0), 12n);
  assert.equal(c.formatUnits(1000000000000000001n, 18, 18), '1.000000000000000001');
});

test('amount parser rejects truncation, malformed decimals, signs, exponents, and overflow', () => {
  const { context: c } = fixture();
  for (const amount of ['', '.', '1.2.3', '-1', '+1', '1e6', '0.0000001']) assert.throws(() => c.parseUnits(amount, 6));
  assert.throws(() => c.parseUnits('1.0', 0));
  assert.throws(() => c.parseUnits((1n << 256n).toString(), 0));
  assert.throws(() => c.parseUnits('1', 256));
  assert.throws(() => c.positiveAmount('0', 18));
});

test('mint quote uses the terminal beneficiary count and actual payer, beneficiary, and underlying amount', async () => {
  const calls = [];
  const { context: c, info } = fixture({ rpc: async (method, params) => {
    calls.push({ method, params });
    return mintQuote(123n);
  } });
  assert.equal(await c.previewStickMint(12n, info, 12345n, OTHER, ADAPTER), 123n);
  const call = calls[0].params[0];
  assert.equal(call.from, ADAPTER);
  assert.equal(call.to, TERMINAL);
  assert.equal(call.data.slice(0, 10), '0x0aff0c31');
  assert.equal(arg(call.data, 0), 12n);
  assert.equal(arg(call.data, 1), BigInt(TOKEN));
  assert.equal(arg(call.data, 2), 12345n);
  assert.equal(arg(call.data, 3), BigInt(OTHER));
});

test('mint quote fails closed on zero issuance, malformed ABI, reserved tokens, and RPC errors', async () => {
  const { context: c, info } = fixture();
  c.rpc = async () => mintQuote(0n);
  await assert.rejects(c.previewStickMint(12n, info, 1n, HOLDER), /too small/);
  for (const result of ['0x', uint(1), words(...Array(9).fill(0), 1, 1, 384, 0), words(...Array(9).fill(0), 1, 0, 32, 0)]) {
    c.rpc = async () => result;
    await assert.rejects(c.previewStickMint(12n, info, 1n, HOLDER), /valid Sticky mint quote/);
  }
  c.rpc = async () => { throw new Error('RPC unavailable'); };
  await assert.rejects(c.previewStickMint(12n, info, 1n, HOLDER), /RPC unavailable/);
});

test('a stale asynchronous mint estimate cannot replace a newer amount or project quote', async () => {
  const { context: c, info } = fixture();
  c.ctx.pool = { decimals: 6, stSymbol: info.stSymbol, reward: 0n };
  c.$('stake-amount').value = '1';
  const pending = [];
  c.previewStickMint = () => new Promise(resolve => pending.push(resolve));
  const first = c.renderStickQuote();
  await new Promise(setImmediate);
  c.$('stake-amount').value = '2';
  const second = c.renderStickQuote();
  await new Promise(setImmediate);
  pending[1](2n * 10n ** 18n);
  await second;
  pending[0](1n * 10n ** 18n);
  await first;
  assert.match(c.$('stake-quote').textContent, /Estimated mint: 2 STICKYART/);
  const third = c.renderStickQuote();
  await new Promise(setImmediate);
  c.ctx.currentId = 99n;
  pending[2](3n * 10n ** 18n);
  await third;
  assert.doesNotMatch(c.$('stake-quote').textContent, /Estimated mint: 3/);
  const fourth = c.renderStickQuote();
  await new Promise(setImmediate);
  c.account = () => OTHER;
  pending[3](4n * 10n ** 18n);
  await fourth;
  assert.doesNotMatch(c.$('stake-quote').textContent, /Estimated mint: 4/);
});

test('tranche pages stay bounded under a million dust entries and pin count and slice to one block', async () => {
  const calls = [];
  const { context: c } = fixture({ rpc: async (method, params) => {
    calls.push({ method, params });
    if (method === 'eth_blockNumber') return '0x55';
    if (params[0].data.startsWith('0x56dbba3b')) return uint(1000000);
    return words(32, 50, ...Array.from({ length: 50 }, () => [1, 100]).flat());
  } });
  const result = await c.readTranchePage(12n, HOLDER);
  assert.equal(result.tranches.length, 50);
  assert.equal(result.total, 1000000n);
  assert.equal(result.start, 999950n);
  assert.equal(calls.length, 3);
  assert.equal(calls[1].params[1], '0x55');
  assert.equal(calls[2].params[1], '0x55');
  assert.equal(arg(calls[2].params[0].data, 2), 999950n);
  assert.equal(arg(calls[2].params[0].data, 3), 50n);
});

test('tranche pagination clamps stale pages after burns and rejects truncated responses', async () => {
  const { context: c } = fixture({ rpc: async (method, params) => {
    if (method === 'eth_blockNumber') return '0x55';
    return params[0].data.startsWith('0x56dbba3b') ? uint(1) : words(32, 1, 2, 100);
  } });
  const result = await c.readTranchePage(12n, HOLDER, 1000000n);
  assert.equal(result.page, 0n);
  assert.equal(result.start, 0n);
  assert.equal(result.tranches[0].amount, 2n);
  c.rpc = async (method, params) => method === 'eth_blockNumber' ? '0x55'
    : params[0].data.startsWith('0x56dbba3b') ? uint(2) : words(32, 1, 2, 100);
  await assert.rejects(c.readTranchePage(12n, HOLDER), /incomplete tranche page/);
});

test('pool value excludes orphaned funds and treats all zero-supply backing as unowned', async () => {
  let supply = 10n ** 18n, orphaned = 4n;
  const calls = [];
  const { context: c, info } = fixture({ rpc: async (method, params) => {
    if (method === 'eth_blockNumber') return '0x55';
    calls.push(params);
    const selector = params[0].data.slice(0, 10);
    return uint(selector === '0x467f4cb9' ? 10 : selector === '0x325fcad5' ? orphaned : supply);
  } });
  assert.equal((await c.poolBacking(12n, info)).sigma, 6n);
  assert.ok(calls.every(params => params[1] === '0x55'));
  supply = 0n;
  const empty = await c.poolBacking(12n, info);
  assert.equal(empty.sigma, 0n);
  assert.equal(empty.orphaned, 10n);
  orphaned = 11n;
  await assert.rejects(c.poolBacking(12n, info), /inconsistent backing/);
});

test('home value uses underlying backing and decimals rather than assuming one asset per share', () => {
  const { context: c, info } = fixture();
  const now = Math.floor(Date.now() / 1000);
  c.projectStakedHistory = () => [{ ts: now - 86400, value: 5n * 10n ** 18n }, { ts: now, value: 10n * 10n ** 18n }];
  const card = { id: 12n, info, totalStaked: 10n * 10n ** 18n, pool: { sigma: 20000000n } };
  const series = c.homeSecuredSeries([], [card], new Map([['12', 2000000n]]));
  assert.equal(series.total, 40000000n);
  assert.equal(series.points[0].value, 20000000n);
});

test('auto-stick displays the appended zero-issuance status without treating it as ready', () => {
  const { context: c, info } = fixture();
  assert.match(c.asStatusLine({ info, status: 7, enabled: true }), /too small/);
});

test('cash-out curve matches core rounding and its 100% tax full-exit exception', () => {
  const { context: c } = fixture();
  assert.equal(c.curveReclaim({ sigma: 1000n, supply: 100n, reward: 1000n }, 10n), 91n);
  assert.equal(c.curveReclaim({ sigma: 1000n, supply: 100n, reward: 0n }, 10n), 100n);
  assert.equal(c.curveReclaim({ sigma: 1000n, supply: 100n, reward: 10000n }, 100n), 0n);
});

test('changing nonzero ERC20 allowances resets first and preserves exact requested cap', async () => {
  const { context: c, info } = fixture({ view: async () => uint(25) });
  const txs = await c.tokenApprovalTxs(TOKEN, TERMINAL, 100n, info);
  assert.equal(txs.length, 2);
  assert.equal(arg(txs[0].data, 1), 0n);
  assert.equal(arg(txs[1].data, 1), 100n);
  assert.equal(arg(txs[1].data, 0), BigInt(TERMINAL));
});

test('sufficient allowances skip approval but explicit lower caps are honored', async () => {
  const { context: c, info } = fixture({ view: async () => uint(100) });
  assert.equal((await c.tokenApprovalTxs(TOKEN, TERMINAL, 50n, info)).length, 0);
  const txs = await c.tokenApprovalTxs(TOKEN, TERMINAL, 50n, info, null, true);
  assert.equal(txs.length, 2);
  assert.equal(arg(txs[1].data, 1), 50n);
});

test('review freezes sender and chain and rejects async account/project changes', async () => {
  const { context: c, plans } = fixture();
  const action = c.beginAction();
  await c.reviewAction(action, 'test', [{ to: TOKEN, data: '0x' }]);
  assert.equal(plans[0].txs[0].from, HOLDER);
  assert.equal(plans[0].txs[0].chainId, 1);
  c.ctx.currentId = 99n;
  assert.throws(() => c.reviewAction(action, 'test', []), /changed/);
  c.ctx.currentId = 12n;
  c.txAccount = () => OTHER;
  assert.throws(() => c.reviewAction(action, 'test', []), /changed/);
});

test('stake reviews the exact canonical mint minimum, beneficiary, and payer', async () => {
  const { context: c, fields, plans } = fixture();
  c.$('stake-amount').value = '1.000001';
  await c.stake();
  assert.equal(plans.length, 1);
  const stake = plans[0].txs.at(-1);
  assert.equal(stake.from, HOLDER);
  assert.equal(arg(stake.data, 0), 12n);
  assert.equal(arg(stake.data, 2), 1000001n);
  assert.equal(arg(stake.data, 3), BigInt(HOLDER));
  assert.equal(arg(stake.data, 4), 777n);
  assert.ok(plans[0].summary.some(([label]) => label === 'Minimum Sticky tokens'));
  assert.equal(fields.get('stake-amount').value, '1.000001');
});

test('grants require holder trust or launch granter status before approval', async () => {
  const { context: c, plans } = fixture();
  c.$('stake-amount').value = '1';
  c.$('stake-beneficiary').value = OTHER;
  await assert.rejects(c.stake(), /must trust/);
  assert.equal(plans.length, 0);
  const baseView = c.view;
  c.view = async (to, selector, args) => selector === '0xb9f2a2ba' ? uint(1) : baseView(to, selector, args);
  await c.stake();
  assert.equal(arg(plans[0].txs.at(-1).data, 3), BigInt(OTHER));
});

test('stake rejects zero, tiny normalized amounts, and insufficient balances', async () => {
  const { context: c, info, plans } = fixture();
  c.$('stake-amount').value = '0';
  await assert.rejects(c.stake(), /greater than zero/);
  c.$('stake-amount').value = '101';
  await assert.rejects(c.stake(), /insufficient/);
  info.decimals = 20;
  c.$('stake-amount').value = '0.00000000000000000001';
  c.rpc = async () => mintQuote(0n);
  await assert.rejects(c.stake(), /too small/);
  assert.equal(plans.length, 0);
});

test('unstake uses authoritative wallet balance and the exact terminal simulation as minimum', async () => {
  const { context: c, plans } = fixture({ view: async () => uint(10n ** 18n) });
  c.$('unstake-amount').value = '1';
  await c.unstake();
  const unstick = plans[0].txs.at(-1);
  assert.equal(arg(unstick.data, 0), BigInt(HOLDER));
  assert.equal(arg(unstick.data, 2), 10n ** 18n);
  assert.equal(arg(unstick.data, 4), 123456n);
  assert.ok(plans[0].summary.some(([label, value]) => label === 'Minimum you receive' && value === '0.123456 ART'));
});

test('unstake rejects excessive amount, quote failures, and malformed return data before review', async () => {
  const { context: c, plans } = fixture({ view: async () => uint(10n ** 18n) });
  c.$('unstake-amount').value = '2';
  await assert.rejects(c.unstake(), /exceeds/);
  c.$('unstake-amount').value = '1';
  c.rpc = async () => '0x';
  await assert.rejects(c.unstake(), /valid unstick quote/);
  assert.equal(plans.length, 0);
});

test('full exits disable fresh auto-stick settings and remove trust/allowance before cashing out', async () => {
  const { context: c, info, plans } = fixture({ view: async () => uint(10n ** 18n) });
  c.autoStickState = async () => ({ info, enabled: true, minimum: 1n, cooldown: 86400, personallyTrusted: true, allowance: 100n });
  c.$('unstake-amount').value = '1';
  await c.unstake();
  assert.equal(plans[0].txs.length, 4);
  assert.equal(plans[0].txs[0].data.slice(0, 10), '0x415174c8');
  assert.equal(arg(plans[0].txs[0].data, 1), 0n);
  assert.equal(plans[0].txs.at(-1).data.slice(0, 10), '0x13da8317');
});

test('zero-return cash outs disclose the burn without claiming any reclaim', async () => {
  const { context: c, plans } = fixture({ view: async () => uint(10n ** 18n), rpc: async () => uint(0) });
  c.$('unstake-amount').value = '1';
  await c.unstake();
  assert.match(plans[0].txs.at(-1).label, /without reclaiming/);
  assert.ok(plans[0].txs.at(-1).args.some(([label, value]) => label === 'EFFECT' && value.includes('no underlying')));
});

test('native ETH reward funding attaches exact value and never approves a sentinel', async () => {
  const { context: c, plans } = fixture();
  c.$('r-token').value = 'ETH';
  c.$('r-amount').value = '0.000000000000000001';
  await c.fundRewards();
  assert.equal(plans[0].txs.length, 1);
  assert.equal(plans[0].txs[0].value, '0x1');
  assert.equal(arg(plans[0].txs[0].data, 1), BigInt(NATIVE));
  assert.equal(arg(plans[0].txs[0].data, 2), 1n);
});

test('reward token decimals fail closed instead of silently assuming 18', async () => {
  const { context: c } = fixture({ view: async () => '0x' });
  await assert.rejects(c.rewardTokenMeta(TOKEN), /valid decimals/);
  assert.equal((await c.rewardTokenMeta(NATIVE)).decimals, 18);
});

test('normal reward collection is one transaction because the distributor already starts vesting', async () => {
  const { context: c, plans } = fixture();
  const baseView = c.view;
  c.view = async (to, selector, args) => selector === '0x77b8073a' ? uint(1) : baseView(to, selector, args);
  await c.claimReward(TOKEN);
  assert.equal(plans[0].txs.length, 1);
  assert.equal(plans[0].txs[0].data.slice(0, 10), '0xf8724f34');
  assert.equal(arg(plans[0].txs[0].data, 3), BigInt(HOLDER));
});

test('vesting-only claims refuse a verified empty allocation', async () => {
  const { context: c, plans } = fixture();
  c.hasRewardsToVest = async () => false;
  await assert.rejects(c.claimReward(TOKEN), /no rewards/);
  assert.equal(plans.length, 0);
});

test('vesting checks exclude current and expired rounds and use historical voting power', async () => {
  const calls = [];
  const { context: c, info } = fixture({ view: async (to, selector, data) => {
    calls.push({ to, selector, data });
    if (selector === '0x8a19c8bc') return uint(3);
    if (selector === '0x5fef1a8a') return uint(1);
    if (selector === '0xc45c9bf6') {
      const round = BigInt(`0x${data.slice(-64)}`);
      return round === 1n ? words(100, 12, 0, 900, 100) : words(100, 13, 0, 0, 100);
    }
    if (selector === '0x3a46b1a8') return uint(1);
    throw new Error('unexpected read');
  } });
  assert.equal(await c.hasRewardsToVest(info, HOLDER, TOKEN), true);
  assert.equal(calls.filter((call) => call.selector === '0xc45c9bf6').length, 2);
  const votes = calls.filter((call) => call.selector === '0x3a46b1a8');
  assert.equal(votes.length, 1);
  assert.equal(BigInt(`0x${votes[0].data.slice(-64)}`), 13n);
});

test('auto-stick configuration validates contract-width bounds', () => {
  const { context: c, info } = fixture();
  assert.throws(() => c.asConfigTx(info, true, 0n, 86400n), /minimum/);
  assert.throws(() => c.asConfigTx(info, true, 1n << 128n, 86400n), /minimum/);
  assert.throws(() => c.asConfigTx(info, true, 1n, 1n << 48n), /cooldown/);
  assert.throws(() => c.asConfigTx(info, false, 0n, 86400n), /minimum/);
  assert.throws(() => c.asConfigTx(info, false, 1n, 60n), /cooldown/);
  assert.equal(arg(c.asConfigTx(info, false, 1n, 86400n).data, 1), 0n);
});

test('auto-stick renewal disables old settings before increasing allowance, then enables new settings last', async () => {
  const { context: c, info, plans } = fixture();
  c.autoStickState = async () => ({ info, enabled: true, minimum: 100n, cooldown: 86400, personallyTrusted: true, allowance: 0n });
  c.asDialogMode = 'enable';
  c.asAllowanceChoice = 'unlimited';
  c.asCooldownChoice = 86400;
  c.$('as-min').value = '2';
  await c.saveAutoStick();
  const txs = plans[0].txs;
  assert.equal(txs[0].data.slice(0, 10), '0x415174c8');
  assert.equal(arg(txs[0].data, 1), 0n);
  assert.equal(txs[1].data.slice(0, 10), '0x095ea7b3');
  assert.equal(txs.at(-1).data.slice(0, 10), '0x415174c8');
  assert.equal(arg(txs.at(-1).data, 1), 1n);
  assert.equal(arg(txs.at(-1).data, 2), 2000000n);
  assert.equal(arg(txs.at(-1).data, 3), 86400n);
});

test('claim-and-stick adds missing holder trust before the atomic claim', async () => {
  const { context: c, info, plans } = fixture();
  c.autoStickState = async () => ({ info, projectGranter: false, personallyTrusted: false });
  const baseView = c.view;
  c.view = async (to, selector, data) => selector === '0x77b8073a' ? uint(500) : baseView(to, selector, data);
  await c.claimAndStick();
  assert.equal(plans[0].txs.length, 3);
  assert.equal(plans[0].txs[1].data.slice(0, 10), '0x3a799596');
  assert.equal(plans[0].txs[2].data.slice(0, 10), '0xd3a651da');
});

test('manual and automatic compounding reject a zero canonical mint for any token precision', async () => {
  const { context: c, info, plans } = fixture();
  info.decimals = 20;
  c.autoStickState = async () => ({ info, status: 0, enabled: true, minimum: 1n, collectable: 1n, projectGranter: true });
  c.view = async () => uint(1);
  c.rpc = async () => mintQuote(0n);
  await assert.rejects(c.claimAndStick(), /too small/);
  await assert.rejects(c.autoStickNow(), /too small/);
  // The threshold is denominated in underlying rewards; issuance is checked against live backing at execution.
  assert.equal(arg(c.asConfigTx(info, true, 1n, 86400n).data, 2), 1n);
  assert.equal(arg(c.asConfigTx(info, false, 1n, 86400n).data, 1), 0n);
  assert.equal(plans.length, 0);
});

test('claim-and-stick supports more than 18 decimals and discloses a changing backing-price estimate', async () => {
  const { context: c, info, plans } = fixture();
  info.decimals = 24;
  c.autoStickState = async () => ({ info, status: 0, enabled: true, minimum: 1n, collectable: 1000000n, projectGranter: true });
  const baseView = c.view;
  c.view = async (to, selector, data) => selector === '0x77b8073a' ? uint(1000000n) : baseView(to, selector, data);
  await c.claimAndStick();
  assert.equal(plans[0].txs.at(-1).data.slice(0, 10), '0xd3a651da');
  assert.ok(plans[0].summary.some(([label, value]) => label === 'Estimated Sticky tokens' && value.includes('0.000000000000000777')));
  assert.ok(plans[0].summary.some(([label, value]) => label === 'Rate' && value.includes('can change')));
});

test('pocket settlement uses the selected destination reward token, verifies distributor, and rejects empty arrivals', async () => {
  const { context: c, plans } = fixture();
  c.$('bridge-reward-token').value = OTHER;
  const baseView = c.view;
  c.view = async (to, selector, data) => {
    if (selector === '0x9c26149f') return uint(BigInt(DISTRIBUTOR));
    if (selector === '0x7780193e') return uint(BigInt(POCKET));
    return baseView(to, selector, data);
  };
  await c.settleArrivals();
  assert.equal(arg(plans[0].txs[0].data, 1), BigInt(OTHER));
  c.view = async (to, selector, data) => selector === '0x9c26149f' ? uint(BigInt(OTHER)) : baseView(to, selector, data);
  await assert.rejects(c.settleArrivals(), /different distributor/);
  c.view = async (to, selector, data) => {
    if (selector === '0x9c26149f') return uint(BigInt(DISTRIBUTOR));
    if (selector === '0x7780193e') return uint(BigInt(POCKET));
    if (selector === '0x70a08231') return uint(0);
    return baseView(to, selector, data);
  };
  await assert.rejects(c.settleArrivals(), /no ART arrivals/);
});

test('pockets reject native ETH rather than falsely describing an ERC20 settlement', async () => {
  const { context: c, plans } = fixture();
  c.$('bridge-reward-token').value = 'ETH';
  await assert.rejects(c.settleArrivals(), /settle ERC-20/);
  assert.equal(plans.length, 0);
});

test('locked sticky tokens reject transfers before wallet authorization', async () => {
  const { context: c, info, plans } = fixture({ txAccount: () => { throw new Error('wallet requested'); } });
  info.soulbound = true;
  await assert.rejects(c.transferSticky(), /locked and cannot be transferred/);
  assert.equal(plans.length, 0);
});

test('unlocked sticky transfers use 18 decimals, exact recipient and amount, with a tranche reset review', async () => {
  const { context: c, info, plans } = fixture({ view: async () => uint(2n * 10n ** 18n) });
  info.soulbound = false;
  c.$('transfer-recipient').value = OTHER;
  c.$('transfer-amount').value = '1.000000000000000001';
  await c.transferSticky();
  const tx = plans[0].txs[0];
  assert.equal(tx.to, STICKY);
  assert.equal(tx.from, HOLDER);
  assert.equal(tx.data.slice(0, 10), '0xa9059cbb');
  assert.equal(arg(tx.data, 0), BigInt(OTHER));
  assert.equal(arg(tx.data, 1), 1000000000000000001n);
  assert.ok(tx.args.some(([label, value]) => label === 'STREAK' && value.includes('start a new tranche')));
});

test('sticky transfers reject zero, excessive balances, and self or zero recipients', async () => {
  const { context: c, info, plans } = fixture();
  info.soulbound = false;
  c.$('transfer-recipient').value = OTHER;
  c.$('transfer-amount').value = '0';
  await assert.rejects(c.transferSticky(), /greater than zero/);
  c.$('transfer-amount').value = '1';
  await assert.rejects(c.transferSticky(), /insufficient/);
  c.$('transfer-recipient').value = HOLDER;
  await assert.rejects(c.transferSticky(), /different recipient/);
  c.$('transfer-recipient').value = address('0');
  await assert.rejects(c.transferSticky(), /valid recipient/);
  assert.equal(plans.length, 0);
});
