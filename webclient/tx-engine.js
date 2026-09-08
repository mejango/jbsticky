/* Durable, dependency-free transaction execution. The RPC is frozen with the reviewed plan. */
(function (root, factory) {
  const api = factory(typeof module === "object" && module.exports ? require("./tx-safe.js") : root.StickyTxSafe);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyTx = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (safe) {
  "use strict";
  const STORAGE_KEY = "sticky.transactions.v1";
  const LOCK_NAME = "sticky-wallet-write";
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const HASH = /^0x[0-9a-fA-F]{64}$/;
  const DATA = /^0x(?:[0-9a-fA-F]{2})*$/;
  const STATES = new Set(["ready", "submitting", "pending", "unknown", "rejected", "reverted", "confirmed"]);
  const clone = (value) => JSON.parse(JSON.stringify(value));
  const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
  const quantity = (value) => {
    if (!(typeof value === "string" || typeof value === "number" || typeof value === "bigint")
      || (typeof value === "number" && !Number.isSafeInteger(value))
      || !/^(?:0x[0-9a-fA-F]+|[0-9]+)$/.test(String(value))) throw new Error("Invalid transaction quantity.");
    const amount = BigInt(value);
    if (amount < 0n || amount >= 2n ** 256n) throw new Error("Transaction quantity is outside uint256.");
    return `0x${amount.toString(16)}`;
  };
  const unfinished = (session) => session.steps.some((step) => step.state !== "confirmed");
  const protectedSession = (session) => !session.acknowledged && session.steps.some((step) => step.tx.sessionTag);

  function normalizeTx(tx) {
    if (!tx || !Number.isSafeInteger(Number(tx.chainId)) || Number(tx.chainId) <= 0) throw new Error("Invalid transaction chain.");
    if (!ADDRESS.test(tx.from) || !ADDRESS.test(tx.to) || /^0x0{40}$/i.test(tx.to)) throw new Error("Invalid transaction sender or recipient.");
    if (!DATA.test(tx.data || "0x")) throw new Error("Invalid transaction calldata.");
    let url;
    try { url = new URL(tx.rpcUrl); } catch { throw new Error("A fixed RPC is required for every transaction."); }
    if (url.username || url.password || !(url.protocol === "https:" || (url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) {
      throw new Error("Use an HTTPS RPC, or a loopback RPC for local development.");
    }
    return {
      chainId: Number(tx.chainId), from: tx.from.toLowerCase(), to: tx.to.toLowerCase(),
      data: (tx.data || "0x").toLowerCase(), value: quantity(tx.value ?? "0x0"), rpcUrl: url.href,
      label: String(tx.label || "Transaction"), fn: String(tx.fn || ""),
      args: Array.isArray(tx.args) ? tx.args.map(([key, value]) => [String(key), String(value)]) : [],
      ...(tx.chainLabel ? { chainLabel: String(tx.chainLabel) } : {}),
      ...(tx.contractName ? { contractName: String(tx.contractName) } : {}),
      ...(tx.valueLabel ? { valueLabel: String(tx.valueLabel) } : {}),
      ...(tx.sessionTag ? { sessionTag: String(tx.sessionTag) } : {}),
    };
  }

  function samePlan(session, txs) {
    const identity = (tx) => [tx.chainId, tx.from, tx.to, tx.data, tx.value, tx.rpcUrl, tx.sessionTag || ""];
    return JSON.stringify(session.steps.map((step) => identity(step.tx))) === JSON.stringify(txs.map(identity));
  }

  function validateSession(value) {
    if (!value || value.version !== 1 || typeof value.id !== "string" || !Array.isArray(value.steps)
      || !value.steps.length || value.steps.length > 100 || typeof value.title !== "string" || !Array.isArray(value.summary)) {
      throw new Error("Saved transaction data is unreadable. Keep this browser's data and recover the original transaction before sending again.");
    }
    for (const step of value.steps) {
      if (!step || !STATES.has(step.state) || !Array.isArray(step.attempts)) throw new Error("Saved transaction state is invalid.");
      const normalized = normalizeTx(step.tx);
      if (JSON.stringify(normalized) !== JSON.stringify(step.tx)) throw new Error("Saved transaction plan is invalid.");
      if (step.hash && !HASH.test(step.hash)) throw new Error("Saved transaction hash is invalid.");
      if (step.reportedHash && !HASH.test(step.reportedHash)) throw new Error("Saved wallet reference is invalid.");
      if (step.reportedHashKind !== undefined && !["unknown", "proposal", "execution"].includes(step.reportedHashKind)) throw new Error("Saved wallet reference type is invalid.");
      if (["submitting", "pending", "unknown", "reverted", "confirmed"].includes(step.state)) {
        if (!step.submission || !/^0x[0-9a-f]+$/.test(step.submission.blockNumber)
          || !/^0x[0-9a-f]+$/.test(step.submission.nonceFloor) || typeof step.submission.senderIsContract !== "boolean") {
          throw new Error("Saved submission evidence is invalid. Do not repeat the transaction.");
        }
      }
      if ((step.state === "confirmed" || step.state === "reverted") && (!HASH.test(step.hash) || !step.receipt)) {
        throw new Error("Saved receipt evidence is incomplete.");
      }
    }
    return value;
  }

  function createEngine(options) {
    const storage = options.storage;
    const locks = options.locks;
    const key = options.storageKey || STORAGE_KEY;
    const sleep = options.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    const attempts = options.pollAttempts ?? 20;
    const interval = options.pollInterval ?? 1500;
    let busy = false;

    function discardRecord(sessionId) {
      if (typeof sessionId !== "string" || !sessionId || sessionId.length > 200) throw new Error("Invalid transaction recovery identifier.");
      const raw = storage.getItem(`${key}.discarded.${sessionId}`);
      if (raw === null) return null;
      let record;
      try { record = JSON.parse(raw); } catch { throw new Error("Saved transaction cancellation evidence is unreadable."); }
      if (!record || record.version !== 1 || record.id !== sessionId || !Number.isSafeInteger(record.discardedAt)
        || !Array.isArray(record.sessionTags) || record.sessionTags.some((tag) => typeof tag !== "string" || !tag)) {
        throw new Error("Saved transaction cancellation evidence is invalid.");
      }
      return record;
    }

    function wasDiscarded(sessionId, sessionTag) {
      const record = discardRecord(sessionId);
      return !!record && (sessionTag === undefined || record.sessionTags.includes(sessionTag));
    }

    function load() {
      let raw;
      try { raw = storage.getItem(key); } catch { throw new Error("Browser storage is unavailable. Enable storage before sending a transaction."); }
      if (raw === null) return null;
      try {
        const session = validateSession(JSON.parse(raw));
        const discarded = discardRecord(session.id);
        if (discarded) {
          const tags = [...new Set(session.steps.map((step) => step.tx.sessionTag).filter(Boolean))].sort();
          if (JSON.stringify(discarded.sessionTags) !== JSON.stringify(tags)) throw new Error("Saved transaction cancellation does not match its original plan.");
          return null; // A crash after the tombstone write must never revive the cancelled plan.
        }
        return session;
      } catch (error) {
        throw new Error(`Transaction recovery is required: ${error.message}`);
      }
    }

    function save(session) {
      validateSession(session);
      const raw = JSON.stringify(session);
      try {
        storage.setItem(key, raw);
        if (storage.getItem(key) !== raw) throw new Error("Write was not retained.");
      } catch {
        throw new Error("Transaction state could not be saved. Keep this page open and do not submit again.");
      }
      options.onUpdate?.(clone(session));
    }

    async function lock(fn) {
      if (busy) throw new Error("A transaction is already being reviewed or checked.");
      if (!locks?.request) throw new Error("This browser cannot lock transaction storage safely. Use a current browser in a secure tab.");
      busy = true;
      try {
        return await locks.request(LOCK_NAME, { mode: "exclusive", ifAvailable: true }, async (held) => {
          if (!held) throw new Error("Another Sticky tab is handling a transaction. Finish it there first.");
          return fn();
        });
      } finally { busy = false; }
    }

    async function rpc(tx, method, params) { return options.rpc(tx, method, params); }
    async function chain(tx) {
      if (quantity(await rpc(tx, "eth_chainId", [])) !== quantity(tx.chainId)) throw new Error("The saved RPC reports a different chain. No transaction was sent.");
    }

    async function prepare(title, txs, summary = []) {
      return lock(async () => {
        if (!Array.isArray(txs) || !txs.length || txs.length > 100) throw new Error("Choose at least one transaction to review.");
        const plan = txs.map(normalizeTx);
        if (plan.some((tx) => !same(tx.from, plan[0].from))) throw new Error("All transaction steps must use the reviewed account.");
        const previous = load();
        if (previous && !unfinished(previous)) {
          for (const step of previous.steps) await check(previous, step);
        }
        if (previous && samePlan(previous, plan) && (unfinished(previous) || protectedSession(previous))) return clone(previous);
        const unsent = previous?.steps.every((step) => ["ready", "rejected"].includes(step.state));
        if (previous && ((unfinished(previous) && !unsent) || protectedSession(previous))) throw new Error("Finish or safely dismiss the saved transaction before starting another one.");
        const session = {
          version: 1, id: options.randomId?.() || globalThis.crypto.randomUUID(),
          createdAt: Date.now(), title: String(title), summary: summary.map(([key, value]) => [String(key), String(value)]),
          steps: plan.map((tx) => ({ tx, state: "ready", attempts: [] })),
        };
        save(session);
        return clone(session);
      });
    }

    async function inspect(step, hash) {
      if (!HASH.test(hash)) return null;
      const tx = step.tx;
      await chain(tx);
      const [transaction, receipt] = await Promise.all([
        rpc(tx, "eth_getTransactionByHash", [hash]), rpc(tx, "eth_getTransactionReceipt", [hash]),
      ]);
      if (!transaction || !receipt) return null;
      if (!same(transaction.hash, hash) || !same(receipt.transactionHash, hash)
        || !HASH.test(receipt.blockHash) || !same(transaction.blockHash, receipt.blockHash)
        || quantity(transaction.blockNumber) !== quantity(receipt.blockNumber)
        || BigInt(receipt.blockNumber) <= BigInt(step.submission.blockNumber)) return null;
      const block = await rpc(tx, "eth_getBlockByNumber", [quantity(receipt.blockNumber), false]);
      if (!block || !same(block.hash, receipt.blockHash) || quantity(block.number) !== quantity(receipt.blockNumber)) return null;
      if (transaction.chainId !== undefined && quantity(transaction.chainId) !== quantity(tx.chainId)) return null;
      const direct = same(transaction.from, tx.from) && same(transaction.to, tx.to)
        && same(transaction.input ?? transaction.data ?? "0x", tx.data)
        && quantity(transaction.value) === tx.value && BigInt(transaction.nonce) >= BigInt(step.submission.nonceFloor);
      // eth_sendTransaction does not identify whether its hash is a Safe proposal or an
      // execution transaction. Preserve that reference without assuming either meaning.
      const safeOutcome = !direct && step.submission.senderIsContract
        ? safe?.inspectSafeOutcome(transaction, receipt, {
          ...tx, ...(step.reportedHashKind === "proposal" ? { safeTxHash: step.reportedHash } : {}),
        }) : null;
      if (!direct && !safeOutcome) return null;
      if ((direct && quantity(receipt.status) === "0x1") || safeOutcome === "success") return { receipt, state: "confirmed" };
      if (!(direct && quantity(receipt.status) === "0x0") && safeOutcome !== "failure") return null;
      // An outer Safe revert does not consume the Safe nonce: its proposal can still
      // execute. An inner failure proves consumption only for the exact known proposal.
      if (!direct && (quantity(receipt.status) !== "0x1"
        || (step.reportedHashKind !== "proposal" && !same(hash, step.reportedHash)))) return { receipt, state: "pending" };
      // A failed transaction is retryable only after its canonical block is finalized.
      let finalized;
      try { finalized = await rpc(tx, "eth_getBlockByNumber", ["finalized", false]); } catch { return { receipt, state: "pending" }; }
      if (!finalized || BigInt(finalized.number) < BigInt(receipt.blockNumber)) return { receipt, state: "pending" };
      const stillCanonical = await rpc(tx, "eth_getBlockByNumber", [quantity(receipt.blockNumber), false]);
      if (!same(stillCanonical?.hash, receipt.blockHash)) return null;
      return { receipt, state: "reverted" };
    }

    async function check(session, step) {
      const evidence = step.hash ? await inspect(step, step.hash) : null;
      if (evidence && evidence.state !== "pending") {
        step.state = evidence.state;
        step.receipt = evidence.receipt;
        save(session);
      } else if (step.state === "confirmed" || step.state === "reverted" || step.state === "submitting") {
        step.state = step.hash ? "pending" : "unknown";
        delete step.receipt;
        save(session);
      }
      return evidence;
    }

    async function poll(session, step) {
      for (let i = 0; i < attempts; i++) {
        await check(session, step);
        if (step.state === "confirmed") return step.receipt;
        if (step.state === "reverted") throw new Error("This transaction reverted and is finalized. Review the saved plan before retrying this step.");
        if (i + 1 < attempts) await sleep(interval);
      }
      throw new Error(step.hash
        ? "The transaction or wallet proposal is still unresolved. Check its status or add its execution hash; it will not be sent again."
        : "The wallet did not return a transaction hash. Check your wallet and add the execution hash before continuing. This step will not be sent again.");
    }

    async function sender(tx) {
      const provider = options.wallet();
      if (provider) {
        await options.ensureChain(tx.chainId);
        const [accounts, chainId] = await Promise.all([
          provider.request({ method: "eth_accounts" }), provider.request({ method: "eth_chainId" }),
        ]);
        if (!Array.isArray(accounts) || !same(accounts[0], tx.from)) throw new Error("Connect the account in the saved transaction plan before continuing.");
        if (quantity(chainId) !== quantity(tx.chainId)) throw new Error("Your wallet changed chains. Review again on the saved chain.");
        return provider;
      }
      if (!options.localMode?.(tx)) throw new Error("Connect a wallet to send transactions. The account preview is read only.");
      return { request: ({ method, params }) => rpc(tx, method, params || []) };
    }

    async function submit(session, step) {
      const tx = step.tx;
      options.authorize?.(tx);
      await chain(tx);
      const provider = await sender(tx);
      const wire = { from: tx.from, to: tx.to, data: tx.data, value: tx.value };
      const simulation = await rpc(tx, "eth_call", [wire, "latest"]);
      if (tx.data.startsWith("0x095ea7b3") && simulation !== "0x" && !/^0x0{63}1$/i.test(simulation)) {
        throw new Error("The token did not accept this approval. No transaction was sent.");
      }
      const [blockNumber, nonce, code] = await Promise.all([
        rpc(tx, "eth_blockNumber", []), rpc(tx, "eth_getTransactionCount", [tx.from, "pending"]),
        rpc(tx, "eth_getCode", [tx.from, "latest"]),
      ]);
      // Recheck immediately before opening the wallet, after asynchronous simulation and RPC reads.
      options.authorize?.(tx);
      if (provider !== options.wallet() && !options.localMode?.(tx)) throw new Error("The connected wallet changed. Review again.");
      if (options.wallet()) {
        const accounts = await provider.request({ method: "eth_accounts" });
        const chainId = await provider.request({ method: "eth_chainId" });
        if (!same(accounts?.[0], tx.from) || quantity(chainId) !== quantity(tx.chainId)) throw new Error("The wallet account or chain changed. Review again.");
      }
      if (step.submission) step.attempts.push({ state: step.state, submission: step.submission, hash: step.hash, reportedHash: step.reportedHash, reportedHashKind: step.reportedHashKind, receipt: step.receipt });
      step.submission = { blockNumber: quantity(blockNumber), nonceFloor: quantity(nonce), senderIsContract: code !== "0x" && code !== "0x0" };
      step.state = "submitting";
      delete step.hash; delete step.reportedHash; delete step.receipt;
      step.reportedHashKind = "unknown";
      save(session); // Write ahead: a reload or any ambiguous wallet error must never resend this attempt.
      let result;
      try {
        result = await provider.request({ method: "eth_sendTransaction", params: [{ ...wire, chainId: quantity(tx.chainId) }] });
      } catch (error) {
        step.state = error?.code === 4001 ? "rejected" : "unknown";
        save(session);
        if (step.state === "rejected") throw new Error("You cancelled in your wallet. Review the saved plan to try again.");
        throw new Error("The wallet submission outcome is unknown. Check your wallet and recover its execution hash before continuing.");
      }
      if (!HASH.test(result)) {
        step.state = "unknown";
        save(session);
        throw new Error("The wallet returned no valid transaction hash. Recover the execution hash before continuing.");
      }
      step.hash = result.toLowerCase();
      step.reportedHash = result.toLowerCase();
      step.state = "pending";
      save(session);
      return poll(session, step);
    }

    async function run({ review, sessionId, shouldContinue = () => true } = {}) {
      return lock(async () => {
        const session = load();
        if (!session || (sessionId && session.id !== sessionId)) throw new Error("The saved transaction changed. Open its review again.");
        if (typeof review !== "function") throw new Error("Transaction review is required.");
        // Revalidate earlier receipts before relying on dependent state. Never replay missing receipts.
        for (const step of session.steps) if (step.state === "confirmed" || step.state === "reverted") await check(session, step);
        if (!(await review(clone(session)))) return { cancelled: true, session: clone(session) };
        for (const step of session.steps) {
          if (step.state === "confirmed") continue;
          if (!shouldContinue()) return { cancelled: true, session: clone(session) };
          if (["submitting", "unknown", "pending"].includes(step.state)) await poll(session, step);
          else await submit(session, step);
        }
        return { cancelled: false, session: clone(session) };
      });
    }

    async function recover(hash) {
      return lock(async () => {
        if (!HASH.test(hash)) throw new Error("Enter a full transaction execution hash.");
        const session = load();
        if (!session) throw new Error("There is no saved transaction to recover.");
        const step = session.steps.find((item) => item.state !== "confirmed");
        if (!step || !step.submission || !["submitting", "unknown", "pending"].includes(step.state)) throw new Error("This step does not need an execution hash.");
        const evidence = await inspect(step, hash);
        if (!evidence || evidence.state !== "confirmed") throw new Error("That hash does not prove the saved transaction completed. The original wallet reference has been kept.");
        step.hash = hash.toLowerCase();
        step.receipt = evidence.receipt;
        step.state = "confirmed";
        save(session);
        return clone(session);
      });
    }

    async function acknowledge(sessionId) {
      return lock(async () => {
        const session = load();
        if (!session || session.id !== sessionId) throw new Error("Transaction recovery data changed.");
        session.acknowledged = true;
        save(session);
      });
    }

    async function discardUnsubmitted(sessionId) {
      return lock(async () => {
        const alreadyDiscarded = discardRecord(sessionId);
        if (alreadyDiscarded) return clone(alreadyDiscarded);
        const session = load();
        if (!session || session.id !== sessionId) throw new Error("The saved transaction changed. Its cancellation could not be verified.");
        const neverBroadcast = (attempt) => !attempt.hash && !attempt.reportedHash && !attempt.receipt
          && (attempt.state === "rejected" || (attempt.state === "ready" && !attempt.submission));
        const provenNotExecuted = async (attempt, tx) => {
          if (neverBroadcast(attempt)) return true;
          if (attempt.state !== "reverted" || !attempt.submission || !attempt.hash || !attempt.receipt) return false;
          // Recheck every attempt, including failures before a later wallet rejection.
          // inspect retains the stricter Safe nonce-consumption and finality rules.
          const evidence = await inspect({ ...attempt, tx }, attempt.hash);
          return evidence?.state === "reverted";
        };
        let unexecutedSteps = 0;
        for (const step of session.steps) {
          for (const attempt of step.attempts) {
            if (!(await provenNotExecuted(attempt, step.tx))) throw new Error("A previous transaction attempt is unresolved. Recover it before cancelling this plan.");
          }
          if (await provenNotExecuted(step, step.tx)) {
            unexecutedSteps++;
            continue;
          }
          // A confirmed ERC20 approval can remain in place when a later transfer is
          // cancelled. No other executed contract call may be discarded this way.
          const exactApproval = step.tx.value === "0x0" && /^0x095ea7b30{24}[0-9a-f]{40}[0-9a-f]{64}$/.test(step.tx.data);
          if (step.state === "confirmed" && exactApproval) {
            const proof = await inspect(step, step.hash);
            if (proof?.state === "confirmed") continue;
          }
          throw new Error("A transaction may have been submitted. Recover it before cancelling this plan.");
        }
        if (!unexecutedSteps) throw new Error("This plan has already executed. Preserve its transaction record.");
        const record = {
          version: 1, id: session.id, discardedAt: Date.now(),
          sessionTags: [...new Set(session.steps.map((step) => step.tx.sessionTag).filter(Boolean))].sort(),
        };
        const tombstoneKey = `${key}.discarded.${session.id}`;
        const raw = JSON.stringify(record);
        storage.setItem(tombstoneKey, raw);
        if (storage.getItem(tombstoneKey) !== raw) throw new Error("Transaction cancellation could not be saved. Keep the recovery record.");
        storage.removeItem(key);
        if (storage.getItem(key) !== null) throw new Error("Transaction cancellation is saved, but its old journal could not be removed.");
        options.onUpdate?.(null);
        return clone(record);
      });
    }

    async function clear() {
      return lock(async () => {
        const session = load();
        if (!session) return;
        if (protectedSession(session)) throw new Error("Resume the launch before dismissing its payment record.");
        for (const step of session.steps) {
          if (step.state === "confirmed") await check(session, step);
          if (["submitting", "pending", "unknown"].includes(step.state)) throw new Error("The transaction may still execute. Recover it before dismissing this plan.");
          if (step.state === "reverted") {
            const result = await inspect(step, step.hash);
            if (result?.state !== "reverted") throw new Error("The failed transaction is not proven finalized. Keep its recovery record.");
          }
        }
        storage.removeItem(key);
        if (storage.getItem(key) !== null) throw new Error("Transaction recovery data could not be cleared.");
        options.onUpdate?.(null);
      });
    }

    return { load, prepare, run, recover, clear, acknowledge, discardUnsubmitted, wasDiscarded, isBusy: () => busy };
  }
  return { createEngine, normalizeTx, samePlan, validateSession, STORAGE_KEY, LOCK_NAME };
});
