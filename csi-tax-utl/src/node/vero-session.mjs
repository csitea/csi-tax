// The one kept-open OmaVero browser (owner's choice, 2026-11-24: keep the
// window open and a persistent profile). Started by do_vero_fetch when no
// session runs; it then serves every fetch request of do_vero_fetch in the
// SAME window, so the owner logs in once per OmaVero session:
//   VERO_SESSION_DIR/session.pid          this process, while it serves
//   VERO_SESSION_DIR/requests/<id>.json   {"out": dir, "year": n, "login_timeout_s": n} or {"stop": true}
//   VERO_SESSION_DIR/results/<id>.log     the run's lines, as they happen
//   VERO_SESSION_DIR/results/<id>.json    {"rc": n}, written last
// The browser profile (VERO_PROFILE_DIR, mode 0700, outside git) keeps the
// session cookies on disk between restarts. The window is never closed by a
// run; only a stop request (do_vero_session_stop) or the owner closes it.
// Every PUT / PATCH / DELETE request is aborted (read-only in OmaVero).
// Each fetch loads the step code fresh (a copy of src/node/vero-*.mjs under
// VERO_SESSION_DIR/code/), so a fix to the steps needs no new window and no
// new login. Between fetches a second tab reloads the start page every
// VERO_KEEPALIVE_MIN minutes (default 2; VERO_KEEPALIVE=0 turns it off) so
// OmaVero does not drop the idle login; it reads only and clicks nothing.
import { appendFileSync, chmodSync, copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isWriteRequest, keepaliveDue } from './vero-lib.mjs';

const env = (k) => {
  if (!process.env[k]) { console.error(`vero-session: ${k} must be set (do_vero_fetch sets it)`); process.exit(2); }
  return process.env[k];
};
const BASE = env('VERO_BASE_URL');
const SDIR = env('VERO_SESSION_DIR');
const PROFILE = env('VERO_PROFILE_DIR');
const UI = JSON.parse(readFileSync(env('VERO_UI_CNF'), 'utf8'));
const PID = join(SDIR, 'session.pid');
const SRC = dirname(fileURLToPath(import.meta.url));
const slog = (m) => console.log(`${new Date().toISOString()} vero-session: ${m}`);

// steps <id>: the step code as it is on disk now, copied to code/<id>/ and
// imported from there (an import is cached per path).
async function steps(id) {
  const dir = join(SDIR, 'code', id);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const f of readdirSync(SRC).filter((n) => /^vero-.*\.mjs$/.test(n) && n !== 'vero-session.mjs')) copyFileSync(join(SRC, f), join(dir, f));
  return import(join(dir, 'vero-steps.mjs'));
}

// keepalive: reload the keep-alive tab (made on first use, again if closed).
async function keepalive(s) {
  try {
    if (!s.ka || s.ka.isClosed()) s.ka = await s.ctx.newPage();
    await s.ka.goto(BASE).catch(() => {});
    await s.ka.waitForLoadState('networkidle').catch(() => {});
    const on = await s.ka.getByText(UI.logged_in_text).first().isVisible().catch(() => false);
    slog(`keep-alive reload, ${on ? 'logged in' : 'NOT logged in'}`);
  } catch (e) {
    slog(`keep-alive failed: ${e.message.split('\n')[0]}`);
  }
}

function dirs() {
  for (const d of [SDIR, join(SDIR, 'requests'), join(SDIR, 'results'), PROFILE]) {
    mkdirSync(d, { recursive: true, mode: 0o700 });
    chmodSync(d, 0o700);
  }
}

async function open() {
  const { chromium, firefox } = await import('playwright');
  const engine = process.env.VERO_BROWSER === 'chromium' ? chromium : firefox;
  const ctx = await engine.launchPersistentContext(PROFILE, { headless: false, acceptDownloads: true, locale: 'fi-FI' });
  await ctx.route('**/*', (r) => (isWriteRequest(r.request().method()) ? r.abort() : r.continue()));
  const page = ctx.pages()[0] ?? await ctx.newPage();
  await page.goto(BASE);
  return { ctx, page };
}

// serve <id> <request>: one fetch run in the open window; its lines go to
// results/<id>.log, then results/<id>.json carries the exit code.
async function serve(s, id, req) {
  const logPath = join(SDIR, 'results', `${id}.log`);
  const logFn = (m) => appendFileSync(logPath, `vero-fetch: ${m}\n`, { mode: 0o600 });
  let rc;
  try {
    mkdirSync(req.out, { recursive: true, mode: 0o700 });
    const { runFetch, waitForLogin } = await steps(id);
    await waitForLogin(s.page, UI, Number(req.login_timeout_s ?? 900), logFn);
    rc = await runFetch({ ctx: s.ctx, page: s.page, ui: UI, base: BASE, year: Number(req.year), out: req.out, logFn });
  } catch (e) {
    logFn(`FATAL ${e.message.split('\n')[0]}`);
    rc = 2;
  }
  writeFileSync(join(SDIR, 'results', `${id}.json`), JSON.stringify({ rc }), { mode: 0o600 });
}

// next: the oldest request file, taken (renamed) so it runs once.
function next() {
  const f = readdirSync(join(SDIR, 'requests')).filter((n) => n.endsWith('.json')).sort()[0];
  if (!f) return null;
  const taken = join(SDIR, 'requests', `${f}.taken`);
  renameSync(join(SDIR, 'requests', f), taken);
  return { id: f.slice(0, -5), req: JSON.parse(readFileSync(taken, 'utf8')) };
}

async function main() {
  dirs();
  const s = await open();
  writeFileSync(PID, `${process.pid}\n`, { mode: 0o600 });
  let closed = false;
  s.ctx.on('close', () => { closed = true; });
  slog(`serving, pid ${process.pid}`);
  let last = Date.now();
  while (!closed) {
    const n = next();
    if (n?.req.stop) break;
    if (n) { await serve(s, n.id, n.req); last = Date.now(); continue; }
    if (keepaliveDue(Date.now(), last, process.env)) { await keepalive(s); last = Date.now(); }
    await new Promise((r) => setTimeout(r, 500));
  }
  if (existsSync(PID)) rmSync(PID);
  slog(closed ? 'the window was closed' : 'stopped on request');
  if (!closed) await s.ctx.close();
}

main().then(() => process.exit(0), (e) => {
  console.error(`vero-session: FATAL ${e.message}`);
  if (existsSync(PID)) rmSync(PID);
  process.exit(2);
});
