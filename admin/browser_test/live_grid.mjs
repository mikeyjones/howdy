// Checks the live grid follows a change made outside the app, through
// Chromium's DevTools protocol. Run the admin example first:
//
//   cd examples/admin && gleam dev
//   node admin/browser_test/live_grid.mjs
//
// It updates and inserts rows in the example's SQLite file with sqlite3 and
// expects the grid to show them, marked "changed", within a few seconds.

import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8787';
const DATABASE = process.env.DATABASE || 'examples/admin/admin_example.sqlite';
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const SHOT = process.env.SCREENSHOT || '';

const HELPERS = `
window.grid = () => document.querySelector('lustre-server-component')?.shadowRoot;
window.gridText = () => window.grid()?.textContent || '';
`;

async function launch() {
  const profile = mkdtempSync(join(tmpdir(), 'howdy-admin-'));
  const child = spawn(CHROMIUM, ['--headless=new', '--remote-debugging-port=0', '--no-first-run',
    '--no-default-browser-check', '--disable-gpu', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  const portFile = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const [port] = readFileSync(portFile, 'utf8').split('\n');
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let next = 1;
  const pending = new Map();
  const listeners = new Set();
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      message.error ? reject(new Error(message.error.message)) : resolve(message.result);
    } else for (const listener of listeners) listener(message);
  };
  const send = (method, params = {}, sessionId) => {
    const id = next++;
    socket.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  };
  return { send, on: (l) => listeners.add(l), close() { child.kill(); rmSync(profile, { recursive: true, force: true }); } };
}

const browser = await launch();
let failed = false;
try {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  const send = (method, params) => browser.send(method, params, sessionId);
  const errors = [];
  browser.on((m) => { if (m.sessionId === sessionId && m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.text); });
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: HELPERS });
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result.value;
  };
  const until = async (name, expression, ms = 8000) => {
    for (let i = 0; i < ms / 100; i++) {
      if (await evaluate(expression)) { console.log('  ok    ' + name); return; }
      await sleep(100);
    }
    failed = true;
    console.log('  FAIL  ' + name + '\n        grid text: ' + JSON.stringify(await evaluate('gridText()')).slice(0, 400));
  };
  const sql = (s) => execFileSync('sqlite3', [DATABASE, s]);

  const stamp = Date.now().toString();
  sql(`INSERT INTO notes_notes (user_id, title, stars) SELECT id, 'seed ${stamp}', 1 FROM howdy_auth_users LIMIT 1`);
  await send('Page.navigate', { url: `${BASE}/_howdy/data/notes_notes` });
  await until('grid connects and shows the seeded row', `gridText().includes('seed ${stamp}')`);
  await until('the first load marks nothing as changed', `!gridText().includes('changed')`);

  sql(`UPDATE notes_notes SET title = 'renamed ${stamp}', stars = 9 WHERE title = 'seed ${stamp}'`);
  await until('an external UPDATE appears within a second', `gridText().includes('renamed ${stamp}')`, 4000);
  await until('the updated row is marked changed', `gridText().includes('changed')`, 2000);

  sql(`INSERT INTO notes_notes (user_id, title) SELECT id, 'inserted ${stamp}' FROM howdy_auth_users LIMIT 1`);
  await until('an external INSERT appears', `gridText().includes('inserted ${stamp}')`, 4000);
  await until('the mark clears after a few refreshes', `!gridText().includes('changed')`, 10000);

  const before = await evaluate(`(gridText().match(/(\\d+) rows/) || [])[1]`);
  await evaluate(`[...grid().querySelectorAll('tr')].find(tr => tr.textContent.includes('inserted ${stamp}')).querySelector('button').click()`);
  await until('deleting from the grid removes the row', `!gridText().includes('inserted ${stamp}')`, 4000);
  await until('the row count follows', `gridText().includes((${before} - 1) + ' rows')`, 4000);

  sql(`DELETE FROM notes_notes WHERE title LIKE '%${stamp}'`);
  if (SHOT) {
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(SHOT, Buffer.from(data, 'base64'));
    console.log('  saved ' + SHOT);
  }
  if (errors.length) { failed = true; console.log('  FAIL  page errors: ' + errors.join('; ')); }
} finally {
  browser.close();
}
process.exit(failed ? 1 : 0);
