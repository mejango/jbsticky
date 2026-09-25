/* Durable Sticky launches. A published deployStickyFor call is not replay protected. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyLaunch = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";
  const KEY = "sticky-launch-v1";
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const HASH = /^0x[0-9a-fA-F]{64}$/;
  const MODES = ["direct", "relayr", "center"];
  // pending: not listed yet; published: listed, deployments recorded as they confirm;
  // unlisted: Center refused or was unreachable, retry by hand; unavailable: can't be listed.
  const CENTER_STATES = ["pending", "published", "unlisted", "unavailable"];
  const clone = (value) => JSON.parse(JSON.stringify(value));
  function validate(value) {
    if (!value || value.version !== 1 || typeof value.id !== "string" || !value.id
      || !ADDRESS.test(value.owner) || !MODES.includes(value.mode)
      || !Array.isArray(value.targets) || !value.targets.length || !Array.isArray(value.txs)
      || value.targets.length !== value.txs.length || typeof value.published !== "boolean"
      || !value.results || !value.candidates || !value.fundingRpcs) throw new Error("Stored launch is unreadable. Keep this browser's launch data while recovering it.");
    const chains = new Set();
    for (let i = 0; i < value.targets.length; i++) {
      const target = value.targets[i], tx = value.txs[i];
      if (!Number.isSafeInteger(target.chainId) || chains.has(target.chainId)
        || !ADDRESS.test(target.deployer) || !ADDRESS.test(target.controller) || !ADDRESS.test(target.projects)
        || !ADDRESS.test(target.expected?.stakedToken) || !/^\d+$/.test(target.expected?.cashOutTaxRate)
        || typeof target.expected?.soulbound !== "boolean" || typeof target.rpcUrl !== "string"
        || tx.chainId !== target.chainId || tx.to?.toLowerCase() !== target.deployer.toLowerCase()
        || !/^0x00d5ce37[0-9a-fA-F]+$/.test(tx.data) || !/^0x[0-9a-fA-F]+$/.test(tx.value)
        || !Array.isArray(value.candidates[target.chainId])
        || value.candidates[target.chainId].some((hash) => !HASH.test(hash))) throw new Error("Stored launch transactions are invalid. Keep the recovery data.");
      chains.add(target.chainId);
    }
    if (value.mode === "direct" && value.targets.length !== 1) throw new Error("Invalid direct launch.");
    const center = value.center;
    if (center !== undefined && center !== null && (typeof center !== "object" || !CENTER_STATES.includes(center.state)
      || (center.intentId !== null && typeof center.intentId !== "string") || !center.recorded || typeof center.recorded !== "object"
      || (center.state === "published" && !center.intentId))) throw new Error("Stored launch listing is invalid. Keep the recovery data.");
    if (value.mode === "center" && center?.state === "unavailable") throw new Error("Invalid sponsored launch.");
    if (value.quote && !value.published) throw new Error("Invalid launch publication record.");
    return value;
  }
  function createStore(storage, key = KEY) {
    function load() {
      const raw = storage.getItem(key);
      if (raw === null) return null;
      try { return validate(JSON.parse(raw)); }
      catch (error) { throw new Error(`Cannot resume the saved Sticky launch: ${error.message}`); }
    }
    function save(value) {
      validate(value);
      const raw = JSON.stringify(value);
      storage.setItem(key, raw);
      if (storage.getItem(key) !== raw) throw new Error("The browser could not save the launch. Nothing further will be submitted.");
      return clone(value);
    }
    return { load, save, remove() { storage.removeItem(key); if (storage.getItem(key) !== null) throw new Error("Could not clear the saved launch."); } };
  }
  const entriesOf = (session) => session.txs.map((tx) => ({ chain: tx.chainId, target: tx.to, data: tx.data, value: BigInt(tx.value).toString() }));
  const complete = (session) => session.targets.every((target) => session.results[target.chainId]?.status === "confirmed");
  const canClear = (session) => complete(session)
    || (!session.published && !session.paymentIntent && !session.directIntent && !session.center?.deployRequested);
  const unrecorded = (session) => session.targets.some((target) => !session.center?.recorded?.[target.chainId]);
  // Background checks: an open Relayr or Center deployment, or a listing still waiting to record.
  const needsPolling = (session) => Boolean(session) && (complete(session)
    ? session.center?.state === "published" && unrecorded(session)
    : Boolean(session.quote || (session.mode === "center" && session.center?.deployRequested)));
  function createController({ store, relayr, listing = null, choosePayment, runPayment, runDirect, acknowledge = async () => {}, onChange = () => {} }) {
    let running = false;
    function update(session, patch) { const saved = store.save({ ...session, ...patch }); onChange(saved); return saved; }
    function prepare(input) {
      if (store.load()) throw new Error("Resume or finish the saved Sticky launch first.");
      return update({ ...clone(input), version: 1, published: false, quote: null, paymentIntent: null, directIntent: false,
        center: input.center ? { intentId: null, recorded: {}, error: null, ...clone(input.center) } : null,
        results: {}, candidates: Object.fromEntries(input.targets.map((target) => [target.chainId, []])) }, {});
    }
    const withCenter = (session, patch) => update(session, { center: { ...session.center, ...patch } });
    // Publishes the signed listing. Center refusing it or being down never blocks the launch.
    async function publishListing(session) {
      if (!listing || !session.center || session.center.intentId || !["pending", "unlisted"].includes(session.center.state)) return session;
      try {
        const { intentId } = await listing.publish(session);
        return withCenter(session, { state: "published", intentId, error: null });
      } catch (error) {
        return withCenter(session, { state: "unlisted", error: error.message });
      }
    }
    // Records each confirmed chain once. Center counts 2 confirmations, so "wait" retries later.
    async function recordListing(session) {
      let latest = session;
      if (!listing || !latest.center) return latest;
      if (latest.center.state === "pending" && complete(latest)) return withCenter(latest, { state: "unlisted", error: null });
      if (latest.center.state !== "published") return latest;
      for (const target of latest.targets) {
        const result = latest.results[target.chainId];
        if (result?.status !== "confirmed" || latest.center.recorded[target.chainId]) continue;
        try {
          const outcome = latest.mode === "center" ? { status: "recorded" } : await listing.record(latest, target.chainId, result);
          if (outcome.status === "recorded") latest = withCenter(latest, { recorded: { ...latest.center.recorded, [target.chainId]: result.hash } });
        } catch (error) {
          latest = withCenter(latest, { state: "unlisted", error: error.message });
          break;
        }
      }
      return latest;
    }
    const fallbackMode = (session) => session.targets.length > 1 ? "relayr" : "direct";
    // Center deploys the published listing through the forwarder. A refusal before anything
    // is queued falls back to a self-paid launch; an unknown outcome keeps the request.
    async function runSponsored(session) {
      if (!session.center?.intentId) {
        session = await publishListing(session);
        if (!session.center.intentId) return update(session, { mode: fallbackMode(session) });
      }
      if (!session.center.deployRequested) {
        try {
          await listing.deploy(session);
          session = withCenter(session, { deployRequested: true });
        } catch (error) {
          if (!(error.status >= 400 && error.status < 500)) throw error;
          return update(session, { mode: fallbackMode(session), center: { ...session.center, error: `Juicebox Center could not sponsor this launch: ${error.message}` } });
        }
      }
      return refreshSession(session);
    }
    async function verifyCandidates(session) {
      let latest = session;
      for (let i = 0; i < latest.targets.length; i++) {
        const target = latest.targets[i];
        // Keep every candidate hash, but never treat stale or reorged evidence as completion.
        const results = { ...latest.results };
        delete results[target.chainId];
        latest = update(latest, { results });
        for (const hash of latest.candidates[target.chainId]) {
          try {
            const result = await relayr.verifyDeployment(hash, entriesOf(latest)[i], {
              projects: target.projects, controller: target.controller, ...target.expected,
              ...(latest.mode === "direct" ? { from: latest.owner } : {}),
              ...(latest.mode === "center" ? { forwarder: listing.forwarder } : {}),
            });
            if (result.status === "confirmed") {
              latest = update(latest, { results: { ...latest.results, [target.chainId]: result } });
              break;
            }
          } catch (error) {
            // One bad provider hash cannot erase other candidates or block other chains.
            latest = update(latest, { lastEvidenceError: error.message });
          }
        }
      }
      return latest;
    }
    async function refreshSession(session) {
      let latest = session, statusError;
      if (latest.quote) {
        try {
          const bound = await relayr.bindQuote(latest.quote, entriesOf(latest));
          latest = update(latest, { quote: bound });
          const status = await relayr.fetchStatus(bound);
          const candidates = clone(latest.candidates);
          for (const record of status) {
            const chainId = Number(record.request?.chain);
            const hash = relayr.destinationHash(record);
            if (candidates[chainId] && HASH.test(hash || "") && !candidates[chainId].includes(hash)) candidates[chainId].push(hash);
          }
          latest = update(latest, { candidates, lastStatusError: null });
        } catch (error) { statusError = error; latest = update(latest, { lastStatusError: error.message }); }
      }
      if (latest.mode === "center" && latest.center?.deployRequested) {
        try {
          const intent = await listing.status(latest);
          const candidates = clone(latest.candidates);
          const hashes = [...(intent.deployments || []), ...(intent.deploys || [])].map((row) => [Number(row.chainId), row.transactionHash]);
          for (const [chainId, hash] of hashes) {
            if (candidates[chainId] && HASH.test(hash || "") && !candidates[chainId].includes(hash.toLowerCase())) candidates[chainId].push(hash.toLowerCase());
          }
          const failed = (intent.deploys || []).filter((row) => row.status === "failed").map((row) => Number(row.chainId));
          const names = latest.targets.filter((target) => failed.includes(target.chainId)).map((target) => target.name);
          latest = update(latest, { candidates, lastStatusError: names.length ? `Juicebox Center could not deploy on ${names.join(", ")}.` : null });
        } catch (error) { statusError = error; latest = update(latest, { lastStatusError: error.message }); }
      }
      latest = await verifyCandidates(latest);
      latest = await recordListing(latest);
      if (latest.paymentHash && latest.paymentIntent) {
        try {
          const proof = await relayr.verifyPayment(latest.paymentHash, latest.paymentIntent, latest.quote.bundle_uuid, latest.owner);
          latest = update(latest, { paymentConfirmed: proof.status === "confirmed" ? proof : null, lastPaymentError: null });
        } catch (error) { latest = update(latest, { paymentConfirmed: null, lastPaymentError: error.message }); }
      }
      if (complete(latest)) latest = update(latest, { completedAt: latest.completedAt || Date.now() });
      if (statusError && !complete(latest)) latest.lastStatusError = statusError.message;
      return latest;
    }
    async function run() {
      if (running) throw new Error("This launch is already being processed.");
      running = true;
      try {
        let session = store.load();
        if (!session) throw new Error("No Sticky launch is saved.");
        session = await refreshSession(session);
        if (complete(session)) { await acknowledge(session); return session; }
        if (session.mode === "center") {
          session = await runSponsored(session);
          if (session.mode === "center") return session;
        }
        // Signed after the wallet review is confirmed and before anything is sent.
        const beforeSend = async () => { if (session.center?.state === "pending") session = await publishListing(session); };
        if (session.mode === "direct") {
          const recovering = session.directIntent;
          session = update(session, { directIntent: true });
          const result = await runDirect(session, { recovering, beforeSend });
          if (result.status === "cancelled") {
            session = update(session, { directIntent: false });
            await acknowledge(session);
            return session;
          }
          if (HASH.test(result.hash || "")) {
            const chainId = session.targets[0].chainId;
            session = update(session, { candidates: { ...session.candidates, [chainId]: [...new Set([...session.candidates[chainId], result.hash])] } });
          }
          session = await verifyCandidates(session);
          if (complete(session)) { session = update(session, { completedAt: Date.now() }); await acknowledge(session); }
          return await recordListing(session);
        }
        if (!session.published) {
          await relayr.postBundle(entriesOf(session), {
            beforePublish: async () => { session = update(session, { published: true, publishedAt: Date.now() }); },
            onPublished: async (quote) => { session = update(session, { quote }); },
          }).then((quote) => { session = update(session, { quote }); });
        }
        if (!session.quote) throw new Error("Relayr may have received this launch, but its quote ID was not returned. Keep this launch saved; submitting again could deploy duplicates.");
        session = await refreshSession(session);
        if (complete(session)) { await acknowledge(session); return session; }
        if (session.lastStatusError) throw new Error(`Could not verify the saved Relayr quote: ${session.lastStatusError}`);
        if (session.paymentConfirmed) return session;
        let recovering = Boolean(session.paymentIntent);
        if (!session.paymentIntent) {
          // Every actual Relayr option is shown with no default, including a single option.
          const options = relayr.paymentOptions(session.quote, session.targets.map((target) => target.chainId))
            .filter((payment) => session.fundingRpcs[payment.chain]);
          const payment = await choosePayment(options, session);
          if (!payment) return session;
          if (!options.some((option) => JSON.stringify(option) === JSON.stringify(payment))) throw new Error("Choose one of Relayr's quoted funding options.");
          await relayr.validatePayment(payment, session.quote.bundle_uuid, session.owner);
          session = update(session, { paymentIntent: clone(payment) });
          recovering = false;
        }
        const result = await runPayment(session, { recovering, beforeSend });
        if (result.status === "cancelled") {
          session = update(session, { paymentIntent: null });
          await acknowledge(session);
          return session;
        }
        if (HASH.test(result.hash || "")) session = update(session, { paymentHash: result.hash });
        if (session.paymentHash) {
          const verified = await relayr.verifyPayment(session.paymentHash, session.paymentIntent, session.quote.bundle_uuid, session.owner);
          if (verified.status === "confirmed") {
            session = update(session, { paymentConfirmed: verified });
            await acknowledge(session);
          }
        }
        return await refreshSession(session);
      } finally { running = false; }
    }
    async function refresh() {
      if (running) throw new Error("This launch is already being processed.");
      running = true;
      try { const session = store.load(); return session ? await refreshSession(session) : null; }
      finally { running = false; }
    }
    // Lists a launch Center refused or couldn't reach, then records what already confirmed.
    async function list() {
      if (running) throw new Error("This launch is already being processed.");
      running = true;
      try {
        let session = store.load();
        if (!session?.center || session.center.state === "unavailable") return session;
        if (!session.center.intentId) session = await publishListing(session);
        if (session.center.intentId) session = await recordListing(withCenter(session, { state: "published", error: null }));
        return session;
      } finally { running = false; }
    }
    async function addHash(chainId, hash) {
      if (!HASH.test(hash)) throw new Error("Enter an execution transaction hash.");
      if (running) throw new Error("This launch is already being processed.");
      let session = store.load();
      if (!session?.candidates[chainId]) throw new Error("This chain is not part of the saved launch.");
      session = update(session, { candidates: { ...session.candidates, [chainId]: [...new Set([...session.candidates[chainId], hash])] } });
      return refresh();
    }
    async function clear() {
      if (running) throw new Error("This launch is already being processed.");
      running = true;
      try {
        let session = store.load();
        if (session && complete(session)) session = await refreshSession(session);
        if (session && !canClear(session)) throw new Error("This launch has published or submitted transactions. Finish recovering it before starting another.");
        if (session) await acknowledge(session);
        store.remove(); onChange(null);
      } finally { running = false; }
    }
    return { prepare, run, refresh, list, addHash, clear, load: store.load };
  }
  return { KEY, createStore, createController, entriesOf, complete, canClear, needsPolling, validate };
});
