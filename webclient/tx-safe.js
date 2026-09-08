(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StickyTxSafe = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const EXECUTE = '6a761202';
  const SUCCESS = '0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e';
  const FAILURE = '0x23428b18acfb3ea64b08dc0c1d296ea9c09702c09083ca5272e64d115b687d23';
  const MAX_UINT256 = (1n << 256n) - 1n;

  function address(value) {
    return typeof value === 'string' && /^0x[0-9a-f]{40}$/i.test(value) ? value.toLowerCase() : null;
  }

  function bytes(value) {
    return typeof value === 'string' && /^0x(?:[0-9a-f]{2})*$/i.test(value) ? value.toLowerCase() : null;
  }

  function hash(value) {
    return typeof value === 'string' && /^0x[0-9a-f]{64}$/i.test(value) ? value.toLowerCase() : null;
  }

  function quantity(value) {
    if (typeof value === 'number' && !Number.isSafeInteger(value)) return null;
    if (typeof value !== 'bigint' && typeof value !== 'number' &&
        !(typeof value === 'string' && /^(?:0x[0-9a-f]+|[0-9]+)$/i.test(value))) return null;
    try {
      const result = BigInt(value);
      return result >= 0n && result <= MAX_UINT256 ? result : null;
    } catch (_) { return null; }
  }

  // Accept only the canonical ABI layout. Offsets and lengths are bounded by
  // the supplied bytes before conversion to Number or slicing.
  function decodeExecution(input) {
    const normalized = bytes(input);
    if (!normalized || normalized.slice(2, 10) !== EXECUTE) return null;
    const body = normalized.slice(10);
    if (body.length < 640 || body.length % 64 !== 0) return null;
    const word = index => body.slice(index * 64, (index + 1) * 64);
    if (![0, 7, 8].every(index => /^0{24}[0-9a-f]{40}$/.test(word(index)))) return null;
    if (BigInt('0x' + word(3)) !== 0n || BigInt('0x' + word(2)) !== 320n) return null;
    const totalBytes = BigInt(body.length / 2);

    function dynamic(offset) {
      if (offset > totalBytes - 32n || offset % 32n !== 0n) return null;
      const start = Number(offset) * 2;
      const length = BigInt('0x' + body.slice(start, start + 64));
      if (length > totalBytes - offset - 32n) return null;
      const padded = ((length + 31n) / 32n) * 32n;
      const end = offset + 32n + padded;
      if (end > totalBytes) return null;
      const valueEnd = start + 64 + Number(length) * 2;
      if (!/^0*$/.test(body.slice(valueEnd, Number(end) * 2))) return null;
      return { data: '0x' + body.slice(start + 64, valueEnd), end };
    }

    const call = dynamic(320n);
    if (!call || BigInt('0x' + word(9)) !== call.end) return null;
    const signatures = dynamic(call.end);
    if (!signatures || signatures.end !== totalBytes) return null;
    return { to: '0x' + word(0).slice(24), value: BigInt('0x' + word(1)), data: call.data };
  }

  /**
   * Recognize the outcome of an exact Safe execution of a saved inner call.
   * The caller must separately verify the transaction's chain, canonical block
   * and confirmations. A Safe service response is only a candidate hash.
   * expected.safeTxHash optionally binds the saved Safe proposal to its event.
   */
  function inspectSafeOutcome(transaction, receipt, expected) {
    try {
      if (!transaction || !receipt || !expected) return null;
      const status = receipt.status === 'success' ? 1n : receipt.status === 'reverted' ? 0n : quantity(receipt.status);
      if (status !== 0n && status !== 1n) return null;
      const safe = address(expected.from);
      const target = address(expected.to);
      const data = bytes(expected.data);
      const value = quantity(expected.value);
      if (!safe || !target || data === null || value === null || address(transaction.to) !== safe) return null;

      const input = transaction.input === undefined ? transaction.data : transaction.input;
      if (transaction.input !== undefined && transaction.data !== undefined &&
          bytes(transaction.input) !== bytes(transaction.data)) return null;
      const inner = decodeExecution(input);
      if (!inner || inner.to !== target || inner.value !== value || inner.data !== data) return null;

      const transactionHash = hash(transaction.hash);
      if (receipt.transactionHash !== undefined && (!transactionHash || hash(receipt.transactionHash) !== transactionHash)) return null;
      let proposal = null;
      if (expected.safeTxHash !== undefined) {
        proposal = hash(expected.safeTxHash);
        if (!proposal) return null;
      }

      // A reverted outer transaction cannot retain logs or execute its inner
      // call. Finality must still be proven by the caller before permitting retry.
      if (status === 0n) return Array.isArray(receipt.logs) && receipt.logs.length === 0 ? 'failure' : null;
      if (!Array.isArray(receipt.logs)) return null;
      let outcome = null;
      for (const log of receipt.logs) {
        if (!log || address(log.address) !== safe || !Array.isArray(log.topics)) continue;
        const topic = hash(log.topics[0]);
        if (topic !== SUCCESS && topic !== FAILURE) continue;
        // A top-level execTransaction emits one outcome. Reject ambiguous
        // nested executions instead of treating any success event as proof.
        if (outcome !== null || log.removed === true || log.topics.length !== 1) return null;
        const eventData = bytes(log.data);
        if (!eventData || eventData.length !== 130) return null;
        if (log.transactionHash !== undefined && (!transactionHash || hash(log.transactionHash) !== transactionHash)) return null;
        if (proposal && eventData.slice(0, 66) !== proposal) return null;
        outcome = topic === SUCCESS ? 'success' : 'failure';
      }
      return outcome;
    } catch (_) { return null; }
  }

  function inspectSafeExecution(transaction, receipt, expected) {
    return inspectSafeOutcome(transaction, receipt, expected) === 'success';
  }

  return Object.freeze({ inspectSafeExecution, inspectSafeOutcome });
});
