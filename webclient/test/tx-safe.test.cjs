'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const { inspectSafeExecution, inspectSafeOutcome } = require('../tx-safe.js');

const SAFE = '0x1111111111111111111111111111111111111111';
const TARGET = '0x2222222222222222222222222222222222222222';
const EXECUTOR = '0x3333333333333333333333333333333333333333';
const ZERO = '0x0000000000000000000000000000000000000000';
const PROPOSAL = '0x' + 'ab'.repeat(32);
const TX_HASH = '0x' + 'cd'.repeat(32);
const OTHER_HASH = '0x' + 'ef'.repeat(32);
const SUCCESS = '0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e';
const FAILURE = '0x23428b18acfb3ea64b08dc0c1d296ea9c09702c09083ca5272e64d115b687d23';
const word = value => BigInt(value).toString(16).padStart(64, '0');
const addressWord = value => value.slice(2).padStart(64, '0');
const byteTail = value => word(value.length / 2) + value.padEnd(Math.ceil(value.length / 64) * 64, '0');

function encode({ to = TARGET, value = 9n, data = '0x1234abcd', operation = 0n, signatures = '11'.repeat(65) } = {}) {
  const callTail = byteTail(data.slice(2));
  const head = [addressWord(to), word(value), word(320), word(operation), word(100000), word(21000), word(2),
    addressWord(ZERO), addressWord(EXECUTOR), word(320 + callTail.length / 2)].join('');
  return '0x6a761202' + head + callTail + byteTail(signatures);
}

function replaceWord(input, index, value) {
  return input.slice(0, 10 + index * 64) + value + input.slice(10 + (index + 1) * 64);
}

function fixture(overrides = {}) {
  const expected = { from: SAFE, to: TARGET, value: 9n, data: '0x1234abcd', safeTxHash: PROPOSAL, ...overrides };
  const transaction = { from: EXECUTOR, to: SAFE, input: encode(), hash: TX_HASH, value: '0x0' };
  const receipt = { status: '0x1', transactionHash: TX_HASH, logs: [
    { address: SAFE, topics: [SUCCESS], data: PROPOSAL + word(1), transactionHash: TX_HASH },
  ] };
  return { expected, transaction, receipt };
}

test('matches an exact successful Safe call, independent of the executor and outer value', () => {
  const { transaction, receipt, expected } = fixture();
  assert.equal(inspectSafeExecution(transaction, receipt, expected), true);
  for (const status of [1, 1n, '1', 'success']) {
    assert.equal(inspectSafeExecution(transaction, { ...receipt, status }, expected), true);
  }
  assert.equal(inspectSafeExecution({ ...transaction, input: undefined, data: transaction.input }, receipt,
    { ...expected, value: '0x09' }), true);
  assert.equal(inspectSafeExecution(transaction, receipt, { ...expected, safeTxHash: undefined }), true);
});

test('accepts empty and multiword calldata and a canonical empty signatures tail', () => {
  for (const data of ['0x', '0x' + 'ab'.repeat(32), '0x' + 'ab'.repeat(97)]) {
    const { transaction, receipt, expected } = fixture({ data });
    assert.equal(inspectSafeExecution({ ...transaction, input: encode({ data, signatures: '' }) }, receipt, expected), true);
  }
});

test('rejects changes to Safe, target, amount, calldata, operation and proposal', () => {
  const { transaction, receipt, expected } = fixture();
  for (const change of [{ from: TARGET }, { to: SAFE }, { value: 10n }, { data: '0x1234abce' }, { safeTxHash: OTHER_HASH }]) {
    assert.equal(inspectSafeExecution(transaction, receipt, { ...expected, ...change }), false);
  }
  assert.equal(inspectSafeExecution({ ...transaction, to: TARGET }, receipt, expected), false);
  assert.equal(inspectSafeExecution({ ...transaction, input: encode({ operation: 1n }) }, receipt, expected), false);
  assert.equal(inspectSafeExecution({ ...transaction, input: '0x12345678' + transaction.input.slice(10) }, receipt, expected), false);
  assert.equal(inspectSafeExecution({ ...transaction, data: '0x1234' }, receipt, expected), false);
});

test('requires one successful Safe execution event and a successful outer receipt', () => {
  const { transaction, receipt, expected } = fixture();
  const success = receipt.logs[0];
  for (const status of [undefined, null, false, 0, 0n, '0x0', 'reverted', 2]) {
    assert.equal(inspectSafeExecution(transaction, { ...receipt, status }, expected), false);
  }
  for (const logs of [[], [{ ...success, address: TARGET }], [{ ...success, topics: [FAILURE] }],
    [success, { ...success, topics: [FAILURE] }], [success, success], [{ ...success, removed: true }],
    [{ ...success, topics: [SUCCESS, PROPOSAL] }], [{ ...success, data: PROPOSAL }],
    [{ ...success, data: success.data + '00' }]]) {
    assert.equal(inspectSafeExecution(transaction, { ...receipt, logs }, expected), false);
  }
  // Other contracts may emit lookalike events; only this Safe's outcome counts.
  assert.equal(inspectSafeExecution(transaction, { ...receipt, logs: [
    { ...success, address: TARGET, topics: [FAILURE] }, success,
  ] }, expected), true);
});

test('does not accept receipt or log evidence from another transaction', () => {
  const { transaction, receipt, expected } = fixture();
  assert.equal(inspectSafeExecution(transaction, { ...receipt, transactionHash: OTHER_HASH }, expected), false);
  assert.equal(inspectSafeExecution(transaction, { ...receipt, logs: [{ ...receipt.logs[0], transactionHash: OTHER_HASH }] }, expected), false);
});

test('distinguishes a canonical inner Safe failure from a successful execution', () => {
  const { transaction, receipt, expected } = fixture();
  const failure = { ...receipt, logs: [{ ...receipt.logs[0], topics: [FAILURE] }] };
  assert.equal(inspectSafeOutcome(transaction, receipt, expected), 'success');
  assert.equal(inspectSafeOutcome(transaction, failure, expected), 'failure');
  assert.equal(inspectSafeExecution(transaction, failure, expected), false);
  assert.equal(inspectSafeOutcome(transaction, failure, { ...expected, safeTxHash: OTHER_HASH }), null);
  assert.equal(inspectSafeOutcome(transaction, { ...failure, logs: [...failure.logs, ...receipt.logs] }, expected), null);
  assert.equal(inspectSafeOutcome(transaction, { ...failure, logs: [{ ...failure.logs[0], address: TARGET }] }, expected), null);
});

test('reports an exact reverted outer Safe transaction only with empty logs', () => {
  const { transaction, receipt, expected } = fixture();
  for (const status of ['0x0', 'reverted', 0n]) {
    assert.equal(inspectSafeOutcome(transaction, { ...receipt, status, logs: [] }, expected), 'failure');
  }
  assert.equal(inspectSafeOutcome(transaction, { ...receipt, status: '0x0' }, expected), null);
  assert.equal(inspectSafeOutcome(transaction, { ...receipt, status: '0x0', logs: [] }, { ...expected, value: 10n }), null);
});

test('rejects malicious offsets, lengths, aliasing and noncanonical padding', () => {
  const { transaction, receipt, expected } = fixture();
  const max = 'f'.repeat(64);
  const input = transaction.input;
  const badInputs = [
    replaceWord(input, 2, word(0)),
    replaceWord(input, 2, word(321)),
    replaceWord(input, 2, max),
    replaceWord(input, 9, word(320)),
    replaceWord(input, 9, max),
    replaceWord(input, 10, max),
    replaceWord(input, 12, max),
    replaceWord(input, 0, '1' + addressWord(TARGET).slice(1)),
    replaceWord(input, 7, '1' + addressWord(ZERO).slice(1)),
    replaceWord(input, 8, '1' + addressWord(EXECUTOR).slice(1)),
    replaceWord(input, 3, word(256)),
    // Nonzero call padding, signature padding, truncation and extra tails.
    replaceWord(input, 11, '1234abcd' + '0'.repeat(55) + '1'),
    input.slice(0, -1) + '1',
    input.slice(0, -64),
    input + word(0),
    input.slice(0, -1),
    '0x6a761202',
  ];
  for (const badInput of badInputs) {
    assert.equal(inspectSafeExecution({ ...transaction, input: badInput }, receipt, expected), false);
  }
});

test('rejects malformed untrusted input without throwing', () => {
  const { transaction, receipt, expected } = fixture();
  for (const value of [null, true, -1, Number.MAX_SAFE_INTEGER + 1, {}, ' 9', '-1', '0x', 1n << 256n]) {
    assert.equal(inspectSafeExecution(transaction, receipt, { ...expected, value }), false);
  }
  for (const bad of [null, undefined, '0x', {}, []]) {
    assert.equal(inspectSafeExecution(bad, receipt, expected), false);
    assert.equal(inspectSafeExecution(transaction, bad, expected), false);
    assert.equal(inspectSafeExecution(transaction, receipt, bad), false);
  }
  assert.equal(inspectSafeExecution(transaction, receipt, { ...expected, safeTxHash: 'bad' }), false);
});

test('exports the same dependency-free API to a browser global', () => {
  const sandbox = {};
  vm.runInNewContext(fs.readFileSync(require.resolve('../tx-safe.js'), 'utf8'), sandbox);
  const { transaction, receipt, expected } = fixture();
  assert.equal(sandbox.StickyTxSafe.inspectSafeExecution(transaction, receipt, expected), true);
  assert.equal(Object.isFrozen(sandbox.StickyTxSafe), true);
});
