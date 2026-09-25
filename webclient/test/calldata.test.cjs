const assert = require('node:assert/strict');
const test = require('node:test');
const Calldata = require('../calldata.js');
const { keccak256 } = require('../relayr.js');
// Encoded by Foundry's `cast calldata` (see the PR for the generating commands), not by this decoder's author.
const FIXTURES = require('./calldata-fixtures.json');

const A = '0x1111111111111111111111111111111111111111';
const B = '0x2222222222222222222222222222222222222222';
const C = '0x3333333333333333333333333333333333333333';
const NATIVE = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const M = '0x' + 'ab'.repeat(32);
const BW = '0x' + '0'.repeat(24) + B.slice(2);
const MAX = (1n << 256n) - 1n;
const utf8 = (text) => '0x' + Buffer.from(text, 'utf8').toString('hex');
const URI = 'data:application/json;charset=utf-8,%7B%22protocol%22%3A%22Sticky%22%2C%22version%22%3A1%2C%22launchId%22%3A%22abc%22%2C%22environment%22%3A%22testnet%22%2C%22chains%22%3A%5B84532%2C11155420%5D%7D';
const PROOF = Array.from({ length: 32 }, (_, i) => '0x' + (i + 1).toString(16).padStart(64, '0'));

// The decoded arguments each fixture must produce, in ABI order.
const EXPECTED = {
  approve: [A, MAX],
  transfer: [B, 5n * 10n ** 18n],
  deployStickyFor: [A, 'Sticky Artizen', 'STICKYART', URI, 1000n, [B, C], false],
  pay: [12n, A, 10_000_000n, B, 9_990_000_000_000_000_000n, '', '0x'],
  cashOutTokensOf: [B, 12n, 10n ** 18n, A, 975_000n, B, '0x'],
  fund: [C, NATIVE, 10n ** 18n, 4008n],
  beginVesting: [C, 4000n, [BigInt(B)], [A]],
  collectVestedRewards: [C, 0n, [BigInt(B)], [A], B],
  setConfigFor: [12n, true, 1_000_000n, 604_800n],
  compoundFor: [12n, B, [0n, 4000n]],
  stickRewardsFor: [12n, [0n]],
  beginVestingFor: [12n, B, [4008n]],
  setTrustedSenderFor: [12n, C, true],
  settleFor: [C, 1004n, A],
  prepayment: ['0x7c4b8a1e000040008000000000000001', 1_790_360_000n],
  prepare: [5n * 10n ** 18n, BW, 4_900_000n, A, M],
  toRemote: [A],
  claim: [[A, [7n, BW, 5n * 10n ** 18n, 4_900_000n, M], PROOF]],
};

test('every registered selector is the keccak256 of its canonical signature', () => {
  for (const [selector, signature] of Calldata.ABIS) {
    const { canonical } = Calldata.parseSignature(signature);
    assert.equal(keccak256(utf8(canonical)).slice(0, 10), selector, canonical);
  }
  assert.equal(new Set(Calldata.ABIS.map(([selector]) => selector)).size, Calldata.ABIS.length);
});

test('every write the site sends decodes from independently encoded calldata', () => {
  const names = Calldata.ABIS.map(([, signature]) => Calldata.parseSignature(signature).name);
  assert.deepEqual(Object.keys(FIXTURES).sort(), [...names].sort());
  for (const [name, data] of Object.entries(FIXTURES)) {
    const decoded = Calldata.decode(data);
    assert.equal(decoded.name, name);
    assert.deepEqual(decoded.params.map((param) => param.value), EXPECTED[name], name);
  }
});

test('an unknown selector is refused with a plain message', () => {
  assert.throws(() => Calldata.decode('0xdeadbeef' + '00'.repeat(32)), /unknown function \(0xdeadbeef\)/);
  assert.throws(() => Calldata.decode('0x'), /no function/);
  assert.throws(() => Calldata.decode('0x095ea7'), /no function/);
  assert.throws(() => Calldata.decode('0xzz'), /hexadecimal/);
});

test('non-canonical encodings are refused: dirty bits, padding, offsets, truncation, and trailing bytes', () => {
  const approve = FIXTURES.approve;
  // A dirty high byte in the spender address.
  assert.throws(() => Calldata.decode(approve.slice(0, 10) + 'ff' + approve.slice(12)), /dirty high bits/);
  // Truncated and trailing data.
  assert.throws(() => Calldata.decode(approve.slice(0, -2)), /hexadecimal|shorter/);
  assert.throws(() => Calldata.decode(approve + '00'.repeat(32)), /extra bytes/);
  // A bool that is neither 0 nor 1.
  const trust = FIXTURES.setTrustedSenderFor;
  assert.throws(() => Calldata.decode(trust.slice(0, -2) + '02'), /not 0 or 1/);
  // A uint128 over its width.
  const config = FIXTURES.setConfigFor;
  const minimumAt = 10 + 64 * 2;
  assert.throws(() => Calldata.decode(config.slice(0, minimumAt) + 'ff' + config.slice(minimumAt + 2)), /larger than its type/);
  // A string offset moved off the standard position (pointing the name at the symbol) is refused.
  const deploy = FIXTURES.deployStickyFor;
  const nameHead = 10 + 64;
  const moved = deploy.slice(0, nameHead) + (0x120).toString(16).padStart(64, '0') + deploy.slice(nameHead + 64);
  assert.throws(() => Calldata.decode(moved), /non-standard offset/);
  // Dirty padding after a string: the byte after "Sticky Artizen" (14 bytes at 0x100).
  const padAt = 10 + (0x100 + 14) * 2;
  assert.throws(() => Calldata.decode(deploy.slice(0, padAt) + '01' + deploy.slice(padAt + 2)), /dirty padding/);
  // A length that runs past the end of the data.
  assert.throws(() => Calldata.decode(FIXTURES.pay.slice(0, -2) + '01'), /shorter/);
});

const bound = Calldata.arg;
function stickTx(overrides = {}) {
  return {
    to: C, data: FIXTURES.pay,
    fn: 'pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)',
    args: [
      ['PROJECT', bound('projectId', 12n, { note: 'Sticky ART' })],
      ['TOKEN', bound('token', A, { names: { [A]: 'ART' } })],
      ['AMOUNT', bound('amount', 10_000_000n, { kind: 'units', decimals: 6, symbol: 'ART' })],
      ['BENEFICIARY', bound('beneficiary', B)],
      ['MINIMUM STICKY TOKENS', bound('minReturnedTokens', 9_990_000_000_000_000_000n, { kind: 'units', decimals: 18, symbol: 'STICKYART' })],
      ['MEMO', bound('memo', '')],
      ['METADATA', bound('metadata', '0x')],
      ['EFFECT', 'Mints Sticky tokens to the beneficiary.'],
    ],
    ...overrides,
  };
}

test('the review renders decoded values, formatted with the builder hints, in the builder order', () => {
  const { rows } = Calldata.review(stickTx());
  assert.deepEqual(rows, [
    ['PROJECT', '12 (Sticky ART)'],
    ['TOKEN', `${A} (ART)`],
    ['AMOUNT', '10 ART'],
    ['BENEFICIARY', B],
    ['MINIMUM STICKY TOKENS', '9.99 STICKYART'],
    ['MEMO', 'none'],
    ['METADATA', 'none'],
    ['EFFECT', 'Mints Sticky tokens to the beneficiary.'],
  ]);
});

test('tampered calldata is blocked: a changed amount, beneficiary, or function never reaches the wallet', () => {
  const tx = stickTx();
  // Raise the amount word inside otherwise valid calldata.
  const amountAt = 10 + 64 * 2;
  const raised = tx.data.slice(0, amountAt) + (20_000_000).toString(16).padStart(64, '0') + tx.data.slice(amountAt + 64);
  assert.throws(() => Calldata.review({ ...tx, data: raised }), /AMOUNT in the calldata does not match the review/);
  // Swap the beneficiary.
  const beneficiaryAt = 10 + 64 * 3;
  const swapped = tx.data.slice(0, beneficiaryAt) + '0'.repeat(24) + 'f'.repeat(40) + tx.data.slice(beneficiaryAt + 64);
  assert.throws(() => Calldata.review({ ...tx, data: swapped }), /BENEFICIARY in the calldata does not match/);
  // A different function under the same review.
  assert.throws(() => Calldata.review({ ...tx, data: FIXTURES.approve }), /review says pay\(.*\) but the calldata calls approve/);
  // An unknown selector under the same review.
  assert.throws(() => Calldata.review({ ...tx, data: '0x12345678' + tx.data.slice(10) }), /unknown function/);
});

test('a review that hides an argument, or shows one the function does not take, is blocked', () => {
  const tx = stickTx();
  assert.throws(() => Calldata.review({ ...tx, args: tx.args.filter(([label]) => label !== 'METADATA') }), /does not show metadata/);
  assert.throws(() => Calldata.review({ ...tx, args: [...tx.args, ['EXTRA', bound('recipient', B)]] }), /does not take/);
});

test('plans saved before reviews were bound show every argument as decoded', () => {
  const { rows } = Calldata.review({ data: FIXTURES.settleFor, fn: 'settleFor(address stickyToken, uint256 groupId, address token)', args: [['STUCK IN', 'anything']] });
  assert.deepEqual(rows, [['STICKY TOKEN', C], ['GROUP ID', '1004'], ['TOKEN', A]]);
});

test('display hints cover groups, holders, allowances, durations, receivers, claims, and Relayr payments', () => {
  const show = (name, index, fmt) => {
    const param = Calldata.decode(FIXTURES[name]).params[index];
    return Calldata.formatValue(param.value, param.type, fmt);
  };
  assert.equal(show('fund', 3, { kind: 'group' }), 'Staked 4–8 weeks (group 4008)');
  assert.equal(show('compoundFor', 2, { kind: 'groups' }), 'Everyone, Staked 4+ weeks');
  assert.equal(show('collectVestedRewards', 2, { kind: 'holders' }), B);
  assert.equal(show('approve', 1, { kind: 'units', unlimited: true, decimals: 6, symbol: 'ART' }), 'unlimited');
  assert.equal(show('setConfigFor', 3, { kind: 'duration' }), '7d 0h');
  assert.equal(show('setConfigFor', 1, { yes: 'on', no: 'off' }), 'on');
  assert.equal(show('deployStickyFor', 4, { kind: 'bps' }), '10%');
  assert.equal(show('deployStickyFor', 3, { kind: 'uri' }), 'Sticky launch abc on chains 84532, 11155420');
  assert.equal(show('deployStickyFor', 5, { names: { [C]: 'AutoStick' } }), `${B}, ${C} (AutoStick)`);
  assert.equal(show('prepare', 1, { kind: 'bytes32Address' }), B);
  assert.equal(show('prepayment', 0, { kind: 'uuid' }), '7c4b8a1e-0000-4000-8000-000000000001');
  assert.equal(show('prepayment', 1, { kind: 'time' }), '2026-09-25 18:13:20 UTC');
  assert.equal(show('claim', 0, { kind: 'claim', decimals: 18, symbol: 'NANA' }), `leaf 7, 5 NANA of ${A} to ${B}`);
});

// The launch and Relayr builders from app.js, run as the site runs them.
function appBuilders() {
  const fs = require('node:fs');
  const vm = require('node:vm');
  const source = fs.readFileSync(require.resolve('../app.js'), 'utf8');
  const fn = (name) => {
    const start = source.indexOf(`\nfunction ${name}(`) + 1;
    return source.slice(start, source.indexOf('\n}', start) + 2);
  };
  const selectors = source.slice(source.indexOf('const SEL ='), source.indexOf('\n};', source.indexOf('const SEL =')) + 3);
  const codec = source.slice(source.indexOf('const strip ='), source.indexOf('// ------------------------------------------------------------- rpc plumbing'));
  const context = vm.createContext({ TextEncoder, TextDecoder, Uint8Array, StickyCalldata: Calldata });
  vm.runInContext(`${selectors}\n${codec}\nconst bind = (param, expect, fmt) => StickyCalldata.arg(param, expect, fmt);\n`
    + `const named = (...pairs) => Object.fromEntries(pairs.filter(([a]) => a).map(([a, n]) => [a.toLowerCase(), n]));\n`
    + `${fn('launchDeployTx')}\n${fn('relayrPaymentTx')}`, context);
  return context;
}

test('a launch shows every deployStickyFor argument decoded, and a tampered launch is blocked', () => {
  const c = appBuilders();
  const target = { chainId: 84532, name: 'Base Sepolia', label: 'BASE SEPOLIA', deployer: C, autoStickAdapter: B, granters: [A, B], fee: 10n ** 15n };
  const tx = c.launchDeployTx(target, { token: A, tokenSymbol: 'CPN', name: 'Sticky CPN', symbol: 'STICKYCPN', projectUri: URI, reward: 500n, soulbound: false });
  const rows = Object.fromEntries(Calldata.review(tx).rows);
  assert.equal(rows.LOCKS, `${A} (CPN)`);
  assert.equal(rows['STICKINESS BONUS'], '5% (cash out tax. Part of each unstick stays with the holders who remain)');
  assert.equal(rows['TRUSTED SENDERS'], `${A}, ${B} (AutoStick, each holder opts in)`);
  assert.equal(rows.TRANSFERS, 'Unlocked. Transfers restart the stickiness clock.');
  assert.equal(rows.LISTING, 'Sticky launch abc on chains 84532, 11155420');
  // Drop AutoStick from the granters in the calldata only: the review still says it is there.
  const other = c.launchDeployTx({ ...target, granters: [A] }, { token: A, tokenSymbol: 'CPN', name: 'Sticky CPN', symbol: 'STICKYCPN', projectUri: URI, reward: 500n, soulbound: false });
  assert.throws(() => Calldata.review({ ...tx, data: other.data }), /TRUSTED SENDERS in the calldata does not match/);
});

test('a Relayr prepayment shows its bundle and deadline decoded from the payment calldata', () => {
  const c = appBuilders();
  const details = { chainId: 84532, target: '0x1c05f7841379d4393574c0ffa17908ec40ffd97d', amount: 10n ** 16n,
    calldata: FIXTURES.prepayment, bundleUuid: '7c4b8a1e-0000-4000-8000-000000000001', deadline: 1_790_360_000n };
  const session = { owner: B, id: 'launch', symbol: 'STICKYCPN', fundingRpcs: { 84532: 'https://sepolia.base.org' }, targets: [{ name: 'Base Sepolia' }] };
  const tx = c.relayrPaymentTx(session, details);
  const rows = Object.fromEntries(Calldata.review(tx).rows);
  assert.equal(rows.QUOTE, '7c4b8a1e-0000-4000-8000-000000000001');
  assert.equal(rows['PAY BY'], '2026-09-25 18:13:20 UTC');
  // Calldata for a different bundle under the same review is blocked.
  const swapped = FIXTURES.prepayment.replace('7c4b8a1e', '7c4b8a1f');
  assert.throws(() => Calldata.review({ ...tx, data: swapped }), /QUOTE in the calldata does not match/);
});
