// OmaVero fetch, run by do_vero_fetch (never by hand): a HEADED browser on the
// owner's desktop, the OWNER logs in himself, then this script reads and
// downloads, read-only, everything of VERO_YEAR into VERO_OUT_DIR:
//   pdf/<n>.pdf       decisions and letters (inbox + archive), then renamed by do_vero_file
//   msg/<n>.txt       messages (HTML only in OmaVero, saved as text)
//   csv/<name>.csv    paid taxes and refunds (UTF-16LE, TAB, full history)
//   pages/<key>.txt   front page, balance table pages, tasks (for the report)
//   manifest.tsv      one row per file, MANIFEST_COLUMNS of vero-lib.mjs
// It never types into the login, never stores a cookie (a fresh, discarded
// browser context), never clicks a label of cnf forbidden_clicks, and aborts
// every PUT / PATCH / DELETE request.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import {
  arrivalDate, dueDate, inYear, isForbiddenLabel, isPdf, isWriteRequest,
  manifestRow, MANIFEST_COLUMNS, driveCategory,
} from './vero-lib.mjs';

const env = (k, d) => process.env[k] ?? d;
const BASE = env('VERO_BASE_URL');
const YEAR = Number(env('VERO_YEAR', String(new Date().getFullYear())));
const OUT = env('VERO_OUT_DIR');
const UI = JSON.parse(readFileSync(env('VERO_UI_CNF'), 'utf8'));
const LOGIN_S = Number(env('VERO_LOGIN_TIMEOUT_S', '900'));
const rows = [];
const log = (m) => console.log(`vero-fetch: ${m}`);

function sha256(buf) { return createHash('sha256').update(buf).digest('hex'); }

function save(sub, name, buf) {
  const dir = join(OUT, sub);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const p = join(dir, name);
  writeFileSync(p, buf, { mode: 0o600 });
  return `${sub}/${name}`;
}

// click: a link, tab or button by its exact visible name; a forbidden label
// is refused before any locator is touched.
async function click(page, name) {
  if (isForbiddenLabel(name, UI.forbidden_clicks)) throw new Error(`refused forbidden click: ${name}`);
  const loc = page.getByRole('link', { name, exact: true })
    .or(page.getByRole('tab', { name, exact: true }))
    .or(page.getByRole('button', { name, exact: true })).first();
  await loc.click();
  await page.waitForLoadState('networkidle').catch(() => {});
}

async function mainText(page) {
  return page.locator(UI.selectors.main).first().innerText();
}

async function waitForLogin(page) {
  log(`waiting up to ${LOGIN_S}s for the owner to log in in the browser window`);
  await page.getByText(UI.logged_in_text).first().waitFor({ timeout: LOGIN_S * 1000 });
  log('logged in');
}

// closeOthers: every tab but the main one. The first hand run took the wrong
// popup on every second row when an old tab was still open.
async function closeOthers(ctx, page) {
  for (const p of ctx.pages()) if (p !== page) await p.close().catch(() => {});
}

// retrieveUrl: click a row link, poll the tabs until one opens on the
// Retrieve URL, take that URL and close the tab.
async function retrieveUrl(ctx, page, link) {
  await closeOthers(ctx, page);
  const label = await link.innerText();
  if (isForbiddenLabel(label, UI.forbidden_clicks)) throw new Error(`refused forbidden click: ${label}`);
  await link.click();
  for (let i = 0; i < 120; i++) {
    const hit = ctx.pages().find((p) => p !== page && p.url().includes(UI.selectors.retrieve_url));
    if (hit) { const u = hit.url(); await hit.close(); return u; }
    await page.waitForTimeout(250);
  }
  throw new Error(`no Retrieve tab opened for "${label}"`);
}

async function rowCells(link) {
  return link.locator('xpath=ancestor::tr[1]/td').allInnerTexts();
}

// pdfRows: every row link of a decisions list whose arrival date is in YEAR.
async function pdfRows(ctx, page, links, source) {
  const n = await links.count();
  for (let i = 0; i < n; i++) {
    const link = links.nth(i);
    const td = await rowCells(link);
    const arrival = arrivalDate(td[0] ?? '');
    if (!inYear(arrival, YEAR)) continue;
    const res = await ctx.request.get(await retrieveUrl(ctx, page, link));
    const buf = await res.body();
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
  await click(page, UI.tabs.front);
  save('pages', 'front.txt', await mainText(page));
}

async function stepBalance(ctx, page) {
  await click(page, UI.tabs.front);
  await click(page, UI.links.balance);
  for (let n = 1; n <= 50; n++) {
    save('pages', `balance-${n}.txt`, await mainText(page));
    const next = page.getByRole('link', { name: UI.links.next_page }).or(page.getByRole('button', { name: UI.links.next_page }));
    if (!(await next.count()) || !(await next.first().isEnabled())) break;
    await next.first().click();
    await page.waitForLoadState('networkidle').catch(() => {});
  }
}

async function stepInbox(ctx, page) {
  await click(page, UI.tabs.contact);
  await click(page, UI.links.decisions);
  await pdfRows(ctx, page, page.locator(UI.selectors.inbox_row_link), 'inbox');
}

async function stepArchive(ctx, page) {
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
  await click(page, UI.tabs.front);
  await click(page, UI.links.payments);
  const links = page.getByRole('link', { name: UI.links.payments_csv });
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
  await click(page, UI.tabs.tasks);
  save('pages', 'tasks.txt', await mainText(page));
}

async function run() {
  if (!BASE || !OUT) throw new Error('VERO_BASE_URL and VERO_OUT_DIR must be set (do_vero_fetch sets them)');
  const { chromium, firefox } = await import('playwright');
  const engine = env('VERO_BROWSER', 'firefox') === 'chromium' ? chromium : firefox;
  const browser = await engine.launch({ headless: false });
  const ctx = await browser.newContext({ acceptDownloads: true, locale: 'fi-FI' });
  await ctx.route('**/*', (r) => (isWriteRequest(r.request().method()) ? r.abort() : r.continue()));
  const page = await ctx.newPage();
  await page.goto(BASE);
  await waitForLogin(page);
  let failed = 0;
  for (const [name, step] of Object.entries({ stepFront, stepBalance, stepInbox, stepArchive, stepMessages, stepPayments, stepTasks })) {
    try { await step(ctx, page); log(`OK ${name}`); } catch (e) { failed++; log(`FAIL ${name}: ${e.message}`); }
  }
  writeFileSync(join(OUT, 'manifest.tsv'), [MANIFEST_COLUMNS.join('\t'), ...rows.map(manifestRow)].join('\n') + '\n', { mode: 0o600 });
  log(`${rows.length} file(s), ${failed} failed step(s); manifest ${join(OUT, 'manifest.tsv')}`);
  await browser.close();
  return failed ? 3 : 0;
}

run().then((rc) => process.exit(rc), (e) => { log(`FATAL ${e.message}`); process.exit(2); });
