// The OmaVero fetch steps, run by vero-session.mjs in the one kept-open
// browser: read-only, everything of a year into an out dir:
//   pdf/<n>.pdf       decisions and letters (inbox + archive), renamed by do_vero_file
//   msg/<n>.txt       messages (HTML only in OmaVero, saved as text)
//   csv/<name>.csv    paid taxes and refunds (UTF-16LE, TAB, full history)
//   pages/<key>.txt   front page, balance table pages, tasks (for the report)
//   manifest.tsv      one row per file, MANIFEST_COLUMNS of vero-lib.mjs
// It never types into the login, never clicks a label of cnf forbidden_clicks
// (the session also aborts every PUT / PATCH / DELETE). Each step starts from
// the front page, so a step that fails leaves the next one a known page; a
// failed step logs a label-only probe (role, name, visible), the click log
// and what covers the page, no page data, and the run stops there.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import {
  arrivalDate, clickLog, dueDate, inYear, isPdf,
  manifestRow, MANIFEST_COLUMNS, driveCategory,
} from './vero-lib.mjs';
import { clickControl, clickEl, describeMatches, findControl, pageState, retrieveDoc } from './vero-click.mjs';

// One run's settings and results; set by runFetch, read by the steps.
let BASE, YEAR, OUT, UI, rows, log;

function sha256(buf) { return createHash('sha256').update(buf).digest('hex'); }

function save(sub, name, buf) {
  const dir = join(OUT, sub);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const p = join(dir, name);
  writeFileSync(p, buf, { mode: 0o600 });
  return `${sub}/${name}`;
}

// click: the control with this label (vero-click.mjs: exact role name,
// chevron-tolerant role name, then exact visible text); forbidden labels
// are refused before any lookup.
async function click(page, name, opts = {}) {
  await clickControl(page, name, UI.forbidden_clicks, opts.timeoutMs || 30000, { busy: UI.selectors.busy, ...opts });
}

// DEPTH: the history entries the run's own clicks made since it last stood
// on the front page; home() goes back at most that far (run 12).
let DEPTH = 0;
// FRONT_URL: the URL stepFront stood on; home() goes there first (same
// host only) before any back step (dispatch c-002 680943a3).
let FRONT_URL = null;
const sameHost = (url) => { try { return new URL(url).host === new URL(BASE).host; } catch { return false; } };

// counted: run a click; a URL change is one more own history entry.
async function counted(page, fn) {
  const before = page.url();
  const r = await fn();
  if (page.url() !== before) DEPTH++;
  return r;
}

// changedText: the main text once it differs from `before` and holds still
// for 500 ms, or null after ms (run 12: the text read right after the click
// was still the front page).
async function changedText(page, before, ms = 15000) {
  const end = Date.now() + ms;
  let last = null;
  while (Date.now() < end) {
    const t = await mainText(page).catch(() => '');
    if (sha256(t) !== before && t === last) return t;
    last = sha256(t) !== before ? t : null;
    await page.waitForTimeout(500);
  }
  return null;
}

// go: click a link that must open another view; OK only when the main text
// changed (and settled) within 15 s; returns that text.
async function go(page, name) {
  const before = sha256(await mainText(page).catch(() => ''));
  await counted(page, () => click(page, name));
  const t = await changedText(page, before);
  if (t === null) throw new Error(`clicked "${name}" but the page did not change in 15 s`);
  return t;
}

async function mainText(page) {
  return page.locator(UI.selectors.main).first().innerText();
}

// livePage: the tab a run drives (run 11: the session's own tab was closed
// during the login, the window stayed open). The newest open tab showing
// the logged-in text, else the newest open tab on the OmaVero host, else
// the newest open tab, else ONE new tab in the same window and profile.
// Never a new window. The session's tab is only the first choice.
let LIVE = null;
export async function livePage(ctx, page, ui, base) {
  const open = [page, ...ctx.pages().slice().reverse()].filter((p) => p && !p.isClosed());
  for (const p of open) if (await p.getByText(ui.logged_in_text).first().isVisible().catch(() => false)) return p;
  const host = (() => { try { return new URL(base).host; } catch { return ''; } })();
  return open.find((p) => host && p.url().includes(host)) ?? open[0] ?? ctx.newPage();
}

// waitForLogin: at once when a tab of the window is still logged in; else
// the owner logs in in the window, in any of its tabs, within loginS seconds.
export async function waitForLogin(page, ui, loginS, logFn, base = '') {
  const ctx = page.context();
  LIVE = await livePage(ctx, page, ui, base);
  const on = (p) => p.getByText(ui.logged_in_text).first().isVisible().catch(() => false);
  if (await on(LIVE)) { logFn(`logged in (session kept)${LIVE === page ? '' : ', in another tab of the window'}`); return; }
  logFn(`waiting up to ${loginS}s for the owner to log in in the browser window`);
  const end = Date.now() + loginS * 1000;
  for (;;) {
    for (const p of ctx.pages().slice().reverse()) {
      if (!p.isClosed() && await on(p)) { LIVE = p; logFn(`logged in${p === page ? '' : ' (in another tab of the window)'}`); return; }
    }
    if (Date.now() > end) throw new Error(`no tab of the window logged in within ${loginS}s`);
    await new Promise((r) => setTimeout(r, 1000));
  }
}

// home: back to the front page; every step starts here. It clicks the
// front tab, unless that tab is already the selected one (a second click
// only reloads the view and the busy layer redraws the tab bar, run 7);
// a view without the tab FAILs the step: no history back and no reload of
// the start URL (run 10: going back left OmaVero for the login pages).
async function home(page) {
  // never a start-URL reload, and back in history only over the run's own
  // clicks, each step checked to stay on the OmaVero host (run 10 went back
  // past OmaVero into the bank login chain and ended the login).
  const tab = () => click(page, UI.tabs.front, { skipSelected: true, timeoutMs: 5000 }).then(() => true, () => false);
  if (await tab()) { DEPTH = 0; return; }
  if (FRONT_URL && sameHost(FRONT_URL)) {
    await page.goto(FRONT_URL).catch(() => {});
    await page.waitForLoadState('networkidle').catch(() => {});
    if (sameHost(page.url()) && await tab()) { DEPTH = 0; return; }
    DEPTH++; // the goto is one more own history entry to go back over
  }
  while (DEPTH > 0) {
    await page.goBack().catch(() => {});
    DEPTH--;
    await page.waitForLoadState('networkidle').catch(() => {});
    if (!sameHost(page.url())) {
      await page.goForward().catch(() => {});
      throw new Error('front tab not found: going back would leave OmaVero, stopped');
    }
    if (await tab()) { DEPTH = 0; return; }
  }
  throw new Error('front tab not on this page and no own click left to go back over');
}

// dialogs: for a failed step, what may cover the page: visible dialogs,
// modals and fixed full-size layers, as tag / role / class / first 60 chars.
async function dialogs(page) {
  return page.evaluate(() => [...document.querySelectorAll('[role=dialog], [role=alertdialog], dialog, [aria-modal=true], .modal, body *')]
    .filter((e) => { if (!(e.offsetWidth || e.offsetHeight)) return false;
      const cs = getComputedStyle(e);
      return e.matches('[role=dialog], [role=alertdialog], dialog, [aria-modal=true], .modal')
        || ((cs.position === 'fixed' || cs.position === 'absolute') && e.offsetWidth >= innerWidth * 0.8 && e.offsetHeight >= innerHeight * 0.8); })
    .slice(0, 10).map((e) => ({ tag: e.tagName.toLowerCase(), role: e.getAttribute('role') || '', cls: String(e.className).slice(0, 60),
      text: (e.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 60),
      box: [e.offsetWidth, e.offsetHeight], opacity: getComputedStyle(e).opacity, pe: getComputedStyle(e).pointerEvents })))
    .catch((e) => [`dialogs failed: ${e.message}`]);
}

// probe: for a failed step, the controls whose text holds a cnf label, as
// role / tag / name / visible: enough to fix a lookup, no page data.
async function probe(page) {
  const labels = [...Object.values(UI.tabs), ...Object.values(UI.links)];
  return page.evaluate((ls) => [...document.querySelectorAll('a, button, [role], [onclick], [tabindex]')]
    .map((e) => ({ tag: e.tagName.toLowerCase(), role: e.getAttribute('role') || '', href: e.hasAttribute('href'),
      name: (e.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 60), visible: !!(e.offsetWidth || e.offsetHeight) }))
    .filter((c) => ls.some((l) => c.name.includes(l))).slice(0, 40), labels).catch((e) => [`probe failed: ${e.message}`]);
}

async function rowCells(link) {
  return link.locator('xpath=ancestor::tr[1]/td').allInnerTexts();
}

// pdfRows: every row link of a decisions list whose arrival date is in YEAR.
// A list with no row at all is a failure (run 5 said OK with 0 rows).
async function pdfRows(ctx, page, links, source) {
  await links.first().waitFor({ timeout: 15000 }).catch(() => { throw new Error(`no ${source} rows found`); });
  const n = await links.count();
  for (let i = 0; i < n; i++) {
    const link = links.nth(i);
    const td = await rowCells(link);
    const arrival = arrivalDate(td[0] ?? '');
    if (!inYear(arrival, YEAR)) continue;
    const buf = await retrieveDoc(ctx, page, link, UI.forbidden_clicks, UI.selectors.retrieve_url);
    if (!isPdf(buf)) { log(`not a PDF, skipped: ${source} row ${i + 1}`); continue; }
    const sum = sha256(buf);
    if (rows.some((r) => r.sha256 === sum)) continue;
    const type = (td[1] ?? '').trim();
    rows.push({ arrival_date: arrival, kind: 'document', type, tax_type: td[2], period: td[3],
      file: save('pdf', `${sum.slice(0, 16)}.pdf`, buf), sha256: sum,
      due_date: dueDate(td.join(' ')), category: driveCategory('document', type) });
  }
}

async function stepFront(ctx, page) {
  await home(page);
  if (sameHost(page.url())) FRONT_URL = page.url();
  save('pages', 'front.txt', await mainText(page));
}

async function stepBalance(ctx, page) {
  await home(page);
  let text = await go(page, UI.links.balance);
  for (let n = 1; n <= 50; n++) {
    save('pages', `balance-${n}.txt`, text);
    const next = await findControl(page, UI.links.next_page, UI.forbidden_clicks, 3000).catch(() => null);
    if (!next || !(await next.isEnabled())) break;
    await counted(page, () => clickEl(next, 5000, UI.forbidden_clicks));
    // the last page: 'next' changes nothing (run 12 saved 48 copies)
    text = await changedText(page, sha256(text), 10000);
    if (text === null) break;
  }
}

async function stepInbox(ctx, page) {
  await home(page);
  await counted(page, () => click(page, UI.tabs.contact));
  await go(page, UI.links.decisions);
  await pdfRows(ctx, page, page.locator(UI.selectors.inbox_row_link), 'inbox');
}

async function stepArchive(ctx, page) {
  await home(page);
  await counted(page, () => click(page, UI.tabs.contact));
  await go(page, UI.links.decisions);
  await go(page, UI.links.archive);
  const inputs = page.locator(UI.selectors.archive_date_inputs);
  await inputs.nth(0).fill(`1.1.${YEAR}`);
  await inputs.nth(1).fill(`31.12.${YEAR}`);
  await counted(page, () => click(page, UI.links.archive_search));
  const rx = new RegExp(UI.selectors.archive_row_link_text, 'i');
  await pdfRows(ctx, page, page.locator(`${UI.selectors.main} a`).filter({ hasText: rx }), 'archive');
}

async function stepMessages(ctx, page) {
  await home(page);
  await counted(page, () => click(page, UI.tabs.contact));
  await go(page, UI.links.messages);
  const n = await page.locator(`${UI.selectors.main} tr a`).count();
  for (let i = 0; i < n; i++) {
    const link = page.locator(`${UI.selectors.main} tr a`).nth(i);
    const td = await rowCells(link);
    const arrival = arrivalDate(td.join(' '));
    if (!inYear(arrival, YEAR)) continue;
    const title = (await link.innerText()).trim();
    await clickEl(link, 5000, UI.forbidden_clicks);
    await page.waitForLoadState('networkidle').catch(() => {});
    const text = await mainText(page);
    const sum = sha256(text);
    rows.push({ arrival_date: arrival, kind: 'message', type: title, file: save('msg', `${sum.slice(0, 16)}.txt`, text),
      sha256: sum, due_date: dueDate(text), category: 'msgs' });
    await page.goBack();
    await page.waitForLoadState('networkidle').catch(() => {});
  }
}

async function stepPayments(ctx, page) {
  await home(page);
  await go(page, UI.links.payments);
  await findControl(page, UI.links.payments_csv, UI.forbidden_clicks);
  const links = page.getByRole('link', { name: UI.links.payments_csv })
    .or(page.locator('main').getByText(UI.links.payments_csv, { exact: true }));
  const today = new Date().toISOString().slice(0, 10);
  for (let i = 0; i < await links.count(); i++) {
    const [dl] = await Promise.all([page.waitForEvent('download'), clickEl(links.nth(i), 5000, UI.forbidden_clicks)]);
    const p = join(OUT, 'csv', `payments-${i + 1}.csv`);
    mkdirSync(join(OUT, 'csv'), { recursive: true, mode: 0o700 });
    await dl.saveAs(p);
    chmodSync(p, 0o600);
    const sum = sha256(readFileSync(p));
    rows.push({ arrival_date: today, kind: 'payments', type: `Payments-table-${i + 1}`, ext: 'csv',
      file: `csv/payments-${i + 1}.csv`, sha256: sum, category: 'payments' });
  }
}

async function stepTasks(ctx, page) {
  await home(page);
  await counted(page, () => click(page, UI.tabs.tasks));
  save('pages', 'tasks.txt', await mainText(page));
}

// runFetch: the steps in order on the session's page; writes manifest.tsv
// and returns 0, or 3 when a step failed.
// the labels each step clicks, for the diagnostics of the next steps
// when one fails (dispatch c-003 93d9a8d3: one failure tells more).
const STEP_TARGETS = {
  stepFront: ['front'], stepBalance: ['balance', 'next_page'], stepInbox: ['contact', 'decisions'],
  stepArchive: ['archive', 'archive_search'], stepMessages: ['contact', 'messages'],
  stepPayments: ['payments', 'payments_csv'], stepTasks: ['tasks'],
};
const label = (k) => UI.tabs[k] || UI.links[k];

export async function runFetch({ ctx, page, ui, base, year, out, logFn }) {
  BASE = base; YEAR = year; OUT = out; UI = ui; rows = []; log = logFn; DEPTH = 0; FRONT_URL = null;
  if (LIVE && !LIVE.isClosed()) page = LIVE;
  else if (page.isClosed()) page = await livePage(ctx, page, ui, base);
  let failed = 0;
  const steps = Object.entries({ stepFront, stepBalance, stepInbox, stepArchive, stepMessages, stepPayments, stepTasks });
  for (const [idx, [name, step]] of steps.entries()) {
    // visibility and focus at every step (dispatch c-002 481b549c): a
    // background window draws no frames (run 9).
    log(`PAGE ${name} ${JSON.stringify(await pageState(page))}`);
    try {
      await step(ctx, page); log(`OK ${name}`);
    } catch (e) {
      failed++; log(`FAIL ${name}: ${e.message.split('\n')[0]}`);
      for (const l of clickLog(e.message)) log(`CLICKLOG ${name} ${l}`);
      if (e.label) log(`MATCHES ${name} ${e.label}: ${JSON.stringify(await describeMatches(page, e.label))}`);
      for (const [next] of steps.slice(idx + 1, idx + 3)) {
        for (const l of (STEP_TARGETS[next] || []).map(label)) {
          const m = await describeMatches(page, l);
          log(`NEXT ${next} ${l}: ${m.length ? JSON.stringify(m) : 'not on this page'}`);
        }
      }
      log(`DIALOGS ${name} ${JSON.stringify(await dialogs(page))}`);
      log(`PAGE ${name} at failure ${JSON.stringify(await pageState(page))}`);
      log(`PROBE ${name} ${JSON.stringify(await probe(page))}`);
      // stop at the first failure (dispatch rule for live runs): the next
      // steps start from a page in an unknown state.
      log(`STOP after ${name}: the remaining steps did not run`);
      break;
    }
  }
  writeFileSync(join(OUT, 'manifest.tsv'), [MANIFEST_COLUMNS.join('\t'), ...rows.map(manifestRow)].join('\n') + '\n', { mode: 0o600 });
  log(`${rows.length} file(s), ${failed} failed step(s); manifest ${join(OUT, 'manifest.tsv')}`);
  return failed ? 3 : 0;
}

// for vero-steps.tst.sh only: the steps on a local fixture.
export const _test = {
  init({ base, ui, out, logFn = () => {} }) { BASE = base; UI = ui; OUT = out; rows = []; log = logFn; DEPTH = 0; FRONT_URL = null; },
  stepFront, stepBalance, home, depth: () => DEPTH, setDepth: (n) => { DEPTH = n; },
};
