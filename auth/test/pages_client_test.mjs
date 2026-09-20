// Exercise the exact script embedded in the Gleam starter pages with a minimal
// DOM and HTTP transport. No dependency or browser installation is required.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const gleam = readFileSync(new URL('../src/howdy/auth/pages.gleam', import.meta.url), 'utf8');
const encoded = gleam.slice(gleam.indexOf('const script = "') + 'const script = '.length).trim();
const script = JSON.parse(encoded.replaceAll('\n', '\\n'));
const settle = () => new Promise(resolve => setImmediate(resolve));

class Element {
  constructor() { this.children = []; this.handlers = {}; this.dataset = {}; this.elements = {}; }
  addEventListener(event, callback) { this.handlers[event] = callback; }
  async fire(event) { await this.handlers[event]({ preventDefault() {}, currentTarget: this }); await settle(); }
  append(child) { child.parent = this; this.children.push(child); }
  replaceChildren() { this.children = []; }
  remove() { this.parent.children = this.parent.children.filter(child => child !== this); }
  querySelector() { return this.button; }
  querySelectorAll() { return this.buttons || []; }
  reset() { for (const input of Object.values(this.elements)) input.value = ''; }
}

function accountPage() {
  const ids = Object.fromEntries(['account', 'status', 'sessions', 'refresh-sessions', 'password-change', 'logout'].map(id => [id, new Element()]));
  ids.account.dataset.api = '/api/auth';
  ids['password-change'].button = new Element();
  ids['password-change'].elements.password = { value: 'new synthetic test password' };
  ids.account.buttons = [ids['logout'], ids['refresh-sessions'], ids['password-change'].button];
  const calls = [];
  let sessions = [
    { id: 'digest-current', current: true, method: 'email', created_at: 100, last_seen_at: 200 },
    { id: 'digest-other', current: false, method: 'password', created_at: 100, last_seen_at: 200 },
  ];
  vm.runInNewContext(script, {
    document: { getElementById: id => ids[id] || null, createElement: () => new Element() },
    fetch: async (url, options) => {
      calls.push({ url, ...options });
      if (url.endsWith('/sessions')) return { status: 200, ok: true, json: async () => sessions };
      if (url.endsWith('/password')) sessions = sessions.filter(s => s.current);
      if (url.endsWith('/sessions/revoke')) sessions = sessions.filter(s => s.id !== JSON.parse(options.body).id);
      return { status: 204, ok: true, json: () => { throw Error('204 must not be parsed as JSON'); } };
    },
  });
  return { ids, calls };
}

test('account password reset handles 204, clears the input and refreshes sessions', async () => {
  const { ids, calls } = accountPage();
  await settle();
  assert.equal(ids.sessions.children.length, 2);
  await ids['password-change'].fire('submit');
  assert.equal(ids['password-change'].elements.password.value, '');
  assert.equal(ids.sessions.children.length, 1);
  assert.match(ids.status.textContent, /Password saved/);
  const post = calls.find(call => call.url.endsWith('/password'));
  assert.equal(post.method, 'POST');
  assert.equal(post.credentials, 'same-origin');
  assert.equal(post.headers['Content-Type'], 'application/json');
});

test('revoke and logout use POST, remove the session and disable signed-out controls', async () => {
  const { ids, calls } = accountPage();
  await settle();
  const other = ids.sessions.children[1];
  await other.children[0].fire('click');
  assert.equal(ids.sessions.children.length, 1);
  const revoke = calls.find(call => call.url.endsWith('/sessions/revoke'));
  assert.deepEqual(JSON.parse(revoke.body), { id: 'digest-other' });
  await ids.logout.fire('click');
  assert.equal(ids.sessions.children.length, 0);
  assert.equal(ids.status.textContent, 'You are signed out.');
  assert.ok(ids.account.buttons.every(button => button.disabled));
});

test('revoking the current session leaves the page signed out', async () => {
  const { ids } = accountPage();
  await settle();
  await ids.sessions.children[0].children[0].fire('click');
  assert.equal(ids.status.textContent, 'You are signed out.');
  assert.ok(ids.account.buttons.every(button => button.disabled));
});
