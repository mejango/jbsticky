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
  'claimAndStick', 'settleArrivals', 'stake', 'curveReclaim', 'stickMintOf', 'unstake', 'transferSticky',
];

function fixture(overrides = {}) {
  const info = { stakedToken: TOKEN, stToken: STICKY, symbol: 'ART', stSymbol: 'STICKYART', decimals: 6, reward: 1000n };
  const fields = new Map();
  const plans = [];
  const reads = [];
  const context = vm.createContext({
    TextEncoder, TextDecoder, Uint8Array, console,
    ctx: { chainId: 1, currentId: 12n, terminal: TERMINAL, hook: POCKETS, autoStick: null },
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
    rpc: async (method) => {
      if (method === 'eth_call') return uint(123456);
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
  vm.runInContext(`${selectors}\n${codec}\nconst NATIVE_REWARD_TOKEN = '${NATIVE}';\nconst UNLIMITED = (1n << 256n) - 1n;\nconst MAX_TAX = 10000n;\nconst AS_STATUS = { READY: 0, DISABLED: 1, INVALID_PROJECT: 2, INSUFFICIENT_ALLOWANCE: 6 };\n${names.map(functionSource).join('\n')}`, context);
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

test('sticky mint remains one for one when pool backing changes and handles more than 18 decimals', () => {
  const { context: c } = fixture();
  assert.equal(c.stickMintOf({ decimals: 6, sigma: 100000000n, supply: 10n ** 18n }, 1000000n), 10n ** 18n);
  assert.equal(c.stickMintOf({ decimals: 20, sigma: 0n, supply: 0n }, 12345n), 123n);
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

test('stake reviews exact 1:1 minimum, beneficiary, and payer', async () => {
  const { context: c, fields, plans } = fixture();
  c.$('stake-amount').value = '1.000001';
  await c.stake();
  assert.equal(plans.length, 1);
  const stake = plans[0].txs.at(-1);
  assert.equal(stake.from, HOLDER);
  assert.equal(arg(stake.data, 0), 12n);
  assert.equal(arg(stake.data, 2), 1000001n);
  assert.equal(arg(stake.data, 3), BigInt(HOLDER));
  assert.equal(arg(stake.data, 4), 1000001000000000000n);
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

test('manual and automatic compounding cannot donate sub-unit reward dust for tokens above 18 decimals', async () => {
  const { context: c, info, plans } = fixture();
  info.decimals = 20;
  c.autoStickState = async () => ({ info, status: 0, enabled: true, minimum: 1n, collectable: 1n, projectGranter: true });
  c.view = async () => uint(1);
  await assert.rejects(c.claimAndStick(), /more than 18 decimals/);
  await assert.rejects(c.autoStickNow(), /update the auto-stick minimum/);
  c.autoStickState = async () => ({ info, status: 0, enabled: true, minimum: 100n, collectable: 1n, projectGranter: true });
  await assert.rejects(c.autoStickNow(), /too small/);
  assert.throws(() => c.asConfigTx(info, true, 99n, 86400n), /too small/);
  assert.equal(arg(c.asConfigTx(info, true, 100n, 86400n).data, 2), 100n);
  // An existing unsafe minimum can still be disabled.
  assert.equal(arg(c.asConfigTx(info, false, 1n, 86400n).data, 1), 0n);
  assert.equal(plans.length, 0);
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
