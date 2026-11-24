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
import { clickControl, findControl, retrieveDoc } from './vero-click.mjs';

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

async function mainText(page) {
  return page.locator(UI.selectors.main).first().innerText();
}

// waitForLogin: at once when the session is still logged in; else the
// owner logs in in the window, within loginS seconds.
export async function waitForLogin(page, ui, loginS, logFn) {
  const marker = page.getByText(ui.logged_in_text).first();
  if (await marker.isVisible().catch(() => false)) { logFn('logged in (session kept)'); return; }
  logFn(`waiting up to ${loginS}s for the owner to log in in the browser window`);
  await marker.waitFor({ timeout: loginS * 1000 });
  logFn('logged in');
}

// home: back to the front page; every step starts here. It clicks the
// front tab, unless that tab is already the selected one (a second click
// only reloads the view and the busy layer redraws the tab bar, run 7);
// a sub view without it (the decisions view, run 5) is left by
// going back. Reloading the start URL is the last resort: OmaVero aborts it
// (NS_BINDING_ABORTED, run 5), so its error is ignored and the login text
// decides.
async function home(page) {
  for (let i = 0; i < 5; i++) {
    try { await click(page, UI.tabs.front, { skipSelected: true, timeoutMs: 3000 }); return; } catch { /* not on this view */ }
    await page.goBack().catch(() => {});
    await page.waitForLoadState('networkidle').catch(() => {});
  }
  await page.goto(BASE).catch(() => {});
  await page.getByText(UI.logged_in_text).first().waitFor({ timeout: 30000 });
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
      text: (e.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 60) })))
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
  save('pages', 'front.txt', await mainText(page));
}

async function stepBalance(ctx, page) {
  await home(page);
  await click(page, UI.links.balance);
  for (let n = 1; n <= 50; n++) {
    save('pages', `balance-${n}.txt`, await mainText(page));
    const next = await findControl(page, UI.links.next_page, UI.forbidden_clicks, 3000).catch(() => null);
    if (!next || !(await next.isEnabled())) break;
    await next.click();
    await page.waitForLoadState('networkidle').catch(() => {});
  }
}

async function stepInbox(ctx, page) {
  await home(page);
  await click(page, UI.tabs.contact);
  await click(page, UI.links.decisions);
  await pdfRows(ctx, page, page.locator(UI.selectors.inbox_row_link), 'inbox');
}

async function stepArchive(ctx, page) {
  await home(page);
  await click(page, UI.tabs.contact);
  await click(page, UI.links.decisions);
  await click(page, UI.links.archive);
  const inputs = page.locator(UI.selectors.archive_date_inputs);
  await inputs.nth(0).fill(`1.1.${YEAR}`);
  await inputs.nth(1).fill(`31.12.${YEAR}`);
  await click(page, UI.links.archive_search);
  const rx = new RegExp(UI.selectors.archive_row_link_text, 'i');
  await pdfRows(ctx, page, page.locator(`${UI.selectors.main} a`).filter({ hasText: rx }), 'archive');
}

async function stepMessages(ctx, page) {
  await home(page);
  await click(page, UI.tabs.contact);
  await click(page, UI.links.messages);
  const n = await page.locator(`${UI.selectors.main} tr a`).count();
  for (let i = 0; i < n; i++) {
    const link = page.locator(`${UI.selectors.main} tr a`).nth(i);
    const td = await rowCells(link);
    const arrival = arrivalDate(td.join(' '));
    if (!inYear(arrival, YEAR)) continue;
    const title = (await link.innerText()).trim();
    await link.click();
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
  await click(page, UI.links.payments);
  await findControl(page, UI.links.payments_csv, UI.forbidden_clicks);
  const links = page.getByRole('link', { name: UI.links.payments_csv })
    .or(page.locator('main').getByText(UI.links.payments_csv, { exact: true }));
  const today = new Date().toISOString().slice(0, 10);
  for (let i = 0; i < await links.count(); i++) {
    const [dl] = await Promise.all([page.waitForEvent('download'), links.nth(i).click()]);
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
  await click(page, UI.tabs.tasks);
  save('pages', 'tasks.txt', await mainText(page));
}

// runFetch: the steps in order on the session's page; writes manifest.tsv
// and returns 0, or 3 when a step failed.
export async function runFetch({ ctx, page, ui, base, year, out, logFn }) {
  BASE = base; YEAR = year; OUT = out; UI = ui; rows = []; log = logFn;
  let failed = 0;
  for (const [name, step] of Object.entries({ stepFront, stepBalance, stepInbox, stepArchive, stepMessages, stepPayments, stepTasks })) {
    try {
      await step(ctx, page); log(`OK ${name}`);
    } catch (e) {
      failed++; log(`FAIL ${name}: ${e.message.split('\n')[0]}`);
      for (const l of clickLog(e.message)) log(`CLICKLOG ${name} ${l}`);
      log(`DIALOGS ${name} ${JSON.stringify(await dialogs(page))}`);
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
