const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const Callback = require('../center-callback.js');

const ORIGIN = 'https://sticky.center';
const CONFIG = { issuer: 'https://signa.center', audience: 'https://api.signa.center', manifest: { id: 'm', revision: '0x' + '1'.repeat(64) }, maximumNetworkFee: '1' };
const CODE_URL = `${ORIGIN}/center/callback?code=abc&state=def&iss=https%3A%2F%2Fsigna.center`;

function storage(entries = {}) {
  const values = new Map(Object.entries(entries));
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: (key) => values.delete(key), values };
}
function sdk({ delivered = false } = {}) {
  const calls = [];
  return {
    calls,
    deliverCenterCallback: async (url) => { calls.push(['deliver', url]); return delivered; },
    createCenterWalletClient: (options) => { calls.push(['client', options]); return { wallet: true }; },
    completeCenterCallback: async (wallet, url) => { calls.push(['complete', url]); return { kind: 'connection' }; },
  };
}

test('the return route is the saved hash route, read once, and nothing else', () => {
  const saved = storage({ [Callback.RETURN_KEY]: '#/project/12' });
  assert.equal(Callback.returnRoute(saved), '/#/project/12');
  assert.equal(saved.values.has(Callback.RETURN_KEY), false);
  for (const value of ['javascript:alert(1)', '//evil.example', '#/x"><script>', 'https://evil.example/#/', '']) {
    assert.equal(Callback.returnRoute(storage({ [Callback.RETURN_KEY]: value })), '/', value);
  }
  assert.equal(Callback.returnRoute({ getItem() { throw new Error('blocked'); } }), '/');
});

test('a framed or popup sign-in hands the callback to the Sticky page that started it', async () => {
  const fake = sdk({ delivered: true });
  const result = await Callback.complete({ url: CODE_URL, win: { location: { origin: ORIGIN } }, config: CONFIG, load: async () => fake });
  assert.equal(result, null);
  assert.deepEqual(fake.calls, [['deliver', CODE_URL]]);
});

test('a full-page sign-in finishes here with the pinned callback URI and returns to the saved route', async () => {
  const fake = sdk();
  const win = { location: { origin: ORIGIN }, sessionStorage: storage({ [Callback.RETURN_KEY]: '#/account/0x' + 'a'.repeat(40) }) };
  const result = await Callback.complete({ url: CODE_URL, win, config: CONFIG, load: async () => fake });
  assert.equal(result, '/#/account/0x' + 'a'.repeat(40));
  assert.deepEqual(fake.calls[1], ['client', { ...CONFIG, callbackUri: `${ORIGIN}/center/callback` }]);
  assert.deepEqual(fake.calls[2], ['complete', CODE_URL]);
});

test('a reload of the scrubbed callback retries the saved exchange without offering it upward', async () => {
  const fake = sdk({ delivered: true });
  const win = { location: { origin: ORIGIN }, sessionStorage: storage() };
  assert.equal(await Callback.complete({ url: `${ORIGIN}/center/callback`, win, config: CONFIG, load: async () => fake }), '/');
  assert.deepEqual(fake.calls.map(([name]) => name), ['client', 'complete']);
});

test('a site without Signa refuses the callback', async () => {
  await assert.rejects(Callback.complete({ url: CODE_URL, win: { location: { origin: ORIGIN } }, config: null, load: async () => sdk() }),
    /not configured/);
});

test('the callback page clears the code from the address bar before anything loads', () => {
  const html = fs.readFileSync(path.join(__dirname, '../center-callback.html'), 'utf8');
  assert.deepEqual([...html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)].map((match) => match[1]), ['/config.js', '/center-callback.js']);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)/);
  const source = fs.readFileSync(path.join(__dirname, '../center-callback.js'), 'utf8');
  const start = source.slice(source.indexOf('function start(win) {'));
  assert.ok(start.indexOf('replaceState') < start.indexOf('complete('), 'scrub before completing');
});

test('the vendored bundle matches the sha256 in its header', () => {
  const source = fs.readFileSync(path.join(__dirname, '../center-connect.js'), 'utf8');
  const header = /^\/\* center-connect\.js: @bananapus\/nana-sdk-connect\/core (\S+), @me\.jango\/center-wallet (\S+), viem (\S+), esbuild (\S+)\.\n.*sha256 of the body below: ([0-9a-f]{64}) \*\/\n/.exec(source);
  assert.ok(header, 'missing generated header');
  const lock = JSON.parse(fs.readFileSync(path.join(__dirname, '../vendor/package-lock.json'), 'utf8'));
  assert.equal(header[1], lock.packages['node_modules/@bananapus/nana-sdk-connect'].version);
  assert.equal(header[2], lock.packages['node_modules/@me.jango/center-wallet'].version);
  assert.equal(header[3], lock.packages['node_modules/viem'].version);
  assert.equal(header[4], lock.packages['node_modules/esbuild'].version);
  const body = source.slice(header[0].length);
  assert.equal(crypto.createHash('sha256').update(body).digest('hex'), header[5]);
});
