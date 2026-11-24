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
import { appendFileSync, chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { isWriteRequest } from './vero-lib.mjs';
import { runFetch, waitForLogin } from './vero-steps.mjs';

const env = (k) => {
  if (!process.env[k]) { console.error(`vero-session: ${k} must be set (do_vero_fetch sets it)`); process.exit(2); }
  return process.env[k];
};
const BASE = env('VERO_BASE_URL');
const SDIR = env('VERO_SESSION_DIR');
const PROFILE = env('VERO_PROFILE_DIR');
const UI = JSON.parse(readFileSync(env('VERO_UI_CNF'), 'utf8'));
const PID = join(SDIR, 'session.pid');

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
  console.log(`vero-session: serving, pid ${process.pid}`);
  while (!closed) {
    const n = next();
    if (n?.req.stop) break;
    if (n) await serve(s, n.id, n.req);
    else await new Promise((r) => setTimeout(r, 500));
  }
  if (existsSync(PID)) rmSync(PID);
  console.log(`vero-session: ${closed ? 'the window was closed' : 'stopped on request'}`);
  if (!closed) await s.ctx.close();
}

main().then(() => process.exit(0), (e) => {
  console.error(`vero-session: FATAL ${e.message}`);
  if (existsSync(PID)) rmSync(PID);
  process.exit(2);
});
