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

function accountPage({ lifecycle = false, fail = null } = {}) {
  const ids = Object.fromEntries(['account', 'status', 'sessions', 'refresh-sessions', 'password-change', 'logout'].map(id => [id, new Element()]));
  if (lifecycle) {
    for (const id of ['linked-providers', 'email-change', 'email-confirm', 'account-delete']) ids[id] = new Element();
    for (const id of ['email-change', 'email-confirm', 'account-delete']) {
      ids[id].button = new Element();
      const field = id === 'email-confirm' ? 'token' : 'email';
      ids[id].elements[field] = {value: field === 'token' ? 'confirmation-secret' : 'new@example.com', focus() { this.focused = true; }};
    }
    ids['email-confirm'].hidden = true;
  }
  ids.account.dataset.api = '/api/auth';
  ids['password-change'].button = new Element();
  ids['password-change'].elements.password = { value: 'new synthetic test password' };
  ids.account.buttons = [ids['logout'], ids['refresh-sessions'], ids['password-change'].button];
  if (lifecycle) ids.account.buttons.push(...['email-change', 'email-confirm', 'account-delete'].map(id => ids[id].button));
  const calls = [];
  let sessions = [
    { id: 'digest-current', current: true, method: 'email', created_at: 100, last_seen_at: 200 },
    { id: 'digest-other', current: false, method: 'password', created_at: 100, last_seen_at: 200 },
  ];
  vm.runInNewContext(script, {
    document: { getElementById: id => ids[id] || null, createElement: () => new Element() },
    fetch: async (url, options) => {
      calls.push({ url, ...options });
      if (fail && url.endsWith(fail)) return {status: 403, ok: false, json: async () => ({error: 'Sign in again'})};
      if (url.endsWith('/providers')) return {status: 200, ok: true, json: async () => [{provider: 'google', issuer: 'https://accounts.google.com'}]};
      if (url.endsWith('/email/change')) return {status: 202, ok: true, json: async () => ({message: 'Check your new email address'})};
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

test('Google-only login page works without an email form or account controls', () => {
  const status = new Element();
  vm.runInNewContext(script, {
    document: { getElementById: id => id === 'status' ? status : null },
    fetch: () => { throw Error('provider-only login must use its browser form'); },
  });
});


test('email change requests proof then confirms it and disables signed-out controls', async () => {
  const {ids, calls} = accountPage({lifecycle: true});
  await settle();
  await ids['email-change'].fire('submit');
  assert.equal(ids['email-confirm'].hidden, false);
  assert.equal(ids['email-confirm'].elements.token.focused, true);
  assert.equal(ids['email-change'].elements.email.value, '');
  await ids['email-confirm'].fire('submit');
  assert.equal(ids['email-confirm'].elements.token.value, '');
  assert.match(ids.status.textContent, /Email changed/);
  assert.ok(ids.account.buttons.every(button => button.disabled));
  assert.equal(ids.sessions.children.length, 0);
  const confirmation = calls.find(call => call.url.endsWith('/email/confirm'));
  assert.equal(confirmation.method, 'POST');
  assert.deepEqual(JSON.parse(confirmation.body), {token: 'confirmation-secret'});
});

test('provider unlink submits only the selected issuer and signs out', async () => {
  const {ids, calls} = accountPage({lifecycle: true});
  await settle();
  await ids['linked-providers'].children[0].children[0].fire('click');
  assert.match(ids.status.textContent, /Provider unlinked/);
  const unlink = calls.find(call => call.url.endsWith('/providers/unlink'));
  assert.equal(unlink.method, 'POST');
  assert.deepEqual(JSON.parse(unlink.body), {issuer: 'https://accounts.google.com'});
  assert.equal(ids['linked-providers'].children.length, 0);
  assert.ok(ids.account.buttons.every(button => button.disabled));
});

test('deletion submits explicit email confirmation and handles a stale session without claiming success', async () => {
  const rejected = accountPage({lifecycle: true, fail: '/account/delete'});
  await settle();
  await rejected.ids['account-delete'].fire('submit');
  assert.equal(rejected.ids.status.textContent, 'Sign in again');
  assert.equal(rejected.ids['account-delete'].button.disabled, false);
  assert.equal(rejected.ids['account-delete'].elements.email.value, 'new@example.com');
  const {ids, calls} = accountPage({lifecycle: true});
  await settle();
  await ids['account-delete'].fire('submit');
  assert.equal(ids.status.textContent, 'Your account has been deleted.');
  assert.ok(ids.account.buttons.every(button => button.disabled));
  const deletion = calls.find(call => call.url.endsWith('/account/delete'));
  assert.equal(deletion.method, 'POST');
  assert.deepEqual(JSON.parse(deletion.body), {email: 'new@example.com'});
});
