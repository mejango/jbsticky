const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const Chooser = require('../wallet-chooser.js');

const ISSUER = 'https://signa.center';

class FakeNode {
  constructor(tag, doc) {
    Object.assign(this, { tagName: tag.toUpperCase(), ownerDocument: doc, children: [], attributes: {}, listeners: {}, style: {}, textContent: '' });
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...nodes) { this.children = nodes; }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  click() { for (const listener of this.listeners.click || []) listener({}); }
  focus() { this.ownerDocument.focused = this; }
}
const all = (node) => [node, ...node.children.flatMap(all)];
const find = (root, predicate) => all(root).filter(predicate);

function harness(controller, overrides = {}) {
  const doc = { createElement: (tag) => new FakeNode(tag, doc) };
  const heading = new FakeNode('h2', doc);
  const body = new FakeNode('div', doc);
  const dialog = Object.assign(new FakeNode('dialog', doc), {
    open: false,
    showModal() { this.open = true; },
    close() { this.open = false; this.onclose?.(); },
  });
  const listeners = new Set();
  const posted = [];
  const win = {
    addEventListener: (type, listener) => type === 'message' && listeners.add(listener),
    removeEventListener: (type, listener) => type === 'message' && listeners.delete(listener),
    getComputedStyle: (node) => ({
      getPropertyValue: (name) => ({ '--jb-connect-bg': '#f8fcfd', '--jb-connect-accent': ' #0e7c91 ', '--jb-connect-radius': '8px' })[name] || '',
      fontFamily: node === heading ? 'Agrandir' : 'Beatrice',
    }),
  };
  let closed = 0;
  const chooser = Chooser.createChooser({ dialog, heading, body, controller, issuer: ISSUER, label: 'Touch ID', win,
    onClose: () => closed++, ...overrides });
  const send = (event) => { for (const listener of [...listeners]) listener(event); };
  return { chooser, dialog, heading, body, listeners, posted, send, closed: () => closed };
}

function mockController(options, initial = {}) {
  let state = { pending: null, error: null, handoffUri: null, frameName: null, frameOrigin: null, ...initial };
  const subscribers = new Set();
  const calls = { choose: [], cancel: 0 };
  return {
    options, calls,
    getState: () => state,
    subscribe(listener) { subscribers.add(listener); return () => subscribers.delete(listener); },
    set(next) { state = { ...state, ...next }; for (const listener of subscribers) listener(); },
    async choose(id) { calls.choose.push(id); },
    cancel() { calls.cancel++; },
  };
}

const signa = { id: 'juicebox-center', name: 'Signa', connect: async () => {} };
const rabby = { id: 'wallet:rabby', name: 'Rabby', icon: 'data:image/svg+xml;base64,PHN2Zy8+', connect: async () => {} };
const sneaky = { id: 'wallet:sneaky', name: 'Sneaky', icon: 'https://tracker.example/icon.png', connect: async () => {} };

test('the device passkey label follows Homerun', () => {
  assert.equal(Chooser.deviceLabel('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'), 'Touch ID');
  assert.equal(Chooser.deviceLabel('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)'), 'Face ID');
  assert.equal(Chooser.deviceLabel('Mozilla/5.0 (Windows NT 10.0; Win64; x64)'), 'Windows Hello');
  assert.equal(Chooser.deviceLabel('Mozilla/5.0 (X11; Linux x86_64)'), 'Device');
});

test('Signa comes first as the primary action, then every browser wallet as a named tile', () => {
  const controller = mockController([signa, rabby, sneaky]);
  const h = harness(controller);
  h.chooser.open();
  assert.equal(h.dialog.open, true);
  assert.equal(h.heading.textContent, 'Sign in');
  const [primary, divider, tiles] = h.body.children;
  assert.equal(primary.tagName, 'BUTTON');
  assert.equal(primary.textContent, 'Touch ID');
  assert.equal(divider.textContent, 'or connect a wallet');
  // Every wallet shows its name; that visible text is the button's accessible name.
  assert.deepEqual(tiles.children.map((tile) => tile.children[1].textContent), ['Rabby', 'Sneaky']);
  assert.ok(tiles.children.every((tile) => tile.tagName === 'BUTTON' && tile.getAttribute('aria-label') === null));
  assert.equal(tiles.children[0].children[0].getAttribute('src'), rabby.icon);
  assert.equal(tiles.children[0].children[0].getAttribute('alt'), '');
  // Only data: images render; a remote icon would leak the visit to its host.
  assert.equal(tiles.children[1].children[0].tagName, 'SPAN');
  assert.equal(tiles.children[1].children[0].getAttribute('aria-hidden'), 'true');
  primary.click();
  tiles.children[0].click();
  assert.deepEqual(controller.calls.choose, ['juicebox-center', 'wallet:rabby']);
});

test('without Signa or wallets the chooser says so', () => {
  const h = harness(mockController([]));
  h.chooser.open();
  assert.deepEqual(h.body.children.map((node) => node.textContent),
    ['Connect a wallet', 'No wallet detected in this browser. Install a browser wallet.']);
});

test('a pending sign-in shows Homerun status copy and errors are alerts', () => {
  const controller = mockController([signa, rabby]);
  const h = harness(controller);
  h.chooser.open();
  controller.set({ pending: 'juicebox-center' });
  assert.equal(h.body.children[0].textContent, 'Connecting, just a sec...');
  controller.set({ pending: 'wallet:rabby' });
  assert.equal(h.body.children[0].textContent, 'Opening Rabby...');
  controller.set({ pending: null, error: 'Center rejected the wallet request.' });
  const alert = find(h.body, (node) => node.getAttribute('role') === 'alert');
  assert.equal(alert.length, 1);
  assert.equal(alert[0].textContent, 'Center rejected the wallet request.');
});

test('the Signa frame delegates passkeys to Signa by origin and survives re-renders', () => {
  const controller = mockController([signa, rabby]);
  const h = harness(controller);
  h.chooser.open();
  controller.set({ pending: 'juicebox-center', frameName: 'juicebox-center-frame', frameOrigin: ISSUER });
  const [frame] = find(h.body, (node) => node.tagName === 'IFRAME');
  assert.equal(frame.getAttribute('name'), 'juicebox-center-frame');
  assert.equal(frame.getAttribute('title'), 'Signa');
  assert.equal(frame.getAttribute('allow'), `publickey-credentials-get ${ISSUER}; publickey-credentials-create ${ISSUER}`);
  controller.set({ handoffUri: null });
  assert.equal(find(h.body, (node) => node.tagName === 'IFRAME')[0], frame);
});

test('size messages from the frame resize it and get Sticky theme tokens back, only from Signa', () => {
  const controller = mockController([signa]);
  const h = harness(controller);
  h.chooser.open();
  controller.set({ pending: 'juicebox-center', frameName: 'juicebox-center-frame', frameOrigin: ISSUER });
  const [frame] = find(h.body, (node) => node.tagName === 'IFRAME');
  const posted = [];
  frame.contentWindow = { postMessage: (message, origin) => posted.push([message, origin]) };
  h.send({ source: {}, origin: ISSUER, data: { type: 'juicebox-center:size', height: 500 } });
  assert.equal(frame.style.height, undefined);
  h.send({ source: frame.contentWindow, origin: ISSUER, data: { type: 'juicebox-center:size', height: 5000 } });
  assert.equal(frame.style.height, '1202px');
  assert.deepEqual(posted, [[{ type: 'juicebox-center:theme', theme: { background: '#f8fcfd', accent: '#0e7c91', radius: '8px',
    font: 'Beatrice', headingFont: 'Agrandir' } }, ISSUER]]);
  // The callback page inside the frame is this site; it resizes the frame but gets no theme.
  h.send({ source: frame.contentWindow, origin: 'https://sticky.center', data: { type: 'juicebox-center:size', height: 100 } });
  assert.equal(frame.style.height, '162px');
  assert.equal(posted.length, 1);
  h.send({ source: frame.contentWindow, origin: ISSUER, data: { type: 'juicebox-center:page', page: 'signup' } });
  assert.equal(h.heading.textContent, 'Sign up');
  h.send({ source: frame.contentWindow, origin: 'https://evil.example', data: { type: 'juicebox-center:page', page: 'signin' } });
  assert.equal(h.heading.textContent, 'Sign up');
});

test('closing cancels the attempt, closes the dialog and stops listening', () => {
  const controller = mockController([signa]);
  const h = harness(controller);
  h.chooser.open();
  assert.equal(h.listeners.size, 1);
  h.dialog.close();
  assert.equal(controller.calls.cancel, 1);
  assert.equal(h.dialog.open, false);
  assert.equal(h.listeners.size, 0);
  assert.equal(h.closed(), 1);
  h.chooser.close();
  assert.equal(h.closed(), 1);
});

test('the vendored connect controller drives the chooser end to end', async () => {
  const sdk = await import(pathToFileURL(path.join(__dirname, '../center-connect.js')).href);
  let connected = 0;
  const controller = sdk.createConnectController([
    { id: 'wallet:rabby', name: 'Rabby', connect: async () => { connected++; } },
    { id: 'wallet:broken', name: 'Broken', connect: async () => { throw new Error('The wallet is locked.'); } },
  ]);
  const h = harness(controller);
  h.chooser.open();
  const tiles = h.body.children[1].children;
  tiles[0].click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(connected, 1);
  tiles[1].click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(find(h.body, (node) => node.getAttribute('role') === 'alert')[0].textContent, 'The wallet is locked.');
});
