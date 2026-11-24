// Finding and clicking an OmaVero control by its label, for vero-fetch.mjs.
// The live run (2026-11-24) found none of its labels as a link/tab/button
// with that exact accessible name, though every label was on the page: a
// chevron inside the name, or an <a> without href (no link role). So the
// lookup tries, in order, until one matches or the wait runs out:
//   1. a link, tab or button with the exact accessible name
//   2. the same roles, the name allowed a leading/trailing chevron and a
//      trailing counter (run 5: the tasks tab reads "Tehtävät 1")
//   3. the exact visible text inside main, nav, header or a tablist
// A forbidden label is refused before any lookup, and again on the text of
// what was found. Only VISIBLE matches count: run 4 found a hidden
// duplicate first and its click timed out. vero-click.tst.sh runs it on a
// local HTML fixture.
import { isForbiddenLabel, maskPath, maskText } from './vero-lib.mjs';

const ROLES = ['link', 'tab', 'button'];
const SCOPE = 'main, nav, header, [role="tablist"], [role="navigation"]';
const CHEVRONS = '\\s›>»❯→';

// chevronRx("Saldoerittely") matches "› Saldoerittely", "Saldoerittely >";
// chevronRx("Tehtävät") matches "Tehtävät 1".
export function chevronRx(name) {
  const esc = String(name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^[${CHEVRONS}]*${esc}[${CHEVRONS}]*(\\d+)?[${CHEVRONS}]*$`, 'i');
}

async function firstHit(page, name) {
  for (const role of ROLES) {
    const l = page.getByRole(role, { name, exact: true }).filter({ visible: true });
    if (await l.count()) return l.first();
  }
  const rx = chevronRx(name);
  for (const role of ROLES) {
    const l = page.getByRole(role, { name: rx }).filter({ visible: true });
    if (await l.count()) return l.first();
  }
  const t = page.locator(SCOPE).getByText(name, { exact: true }).filter({ visible: true });
  if (!(await t.count())) return null;
  // run 8: the text match was a part of the clickable element and never
  // became clickable itself; click its nearest clickable ancestor instead.
  const up = t.first().locator(`xpath=ancestor-or-self::*[${CLICKABLE}][1]`);
  return (await up.count()) && (await up.isVisible()) ? up : t.first();
}

const CLICKABLE = 'self::a or self::button or @role="link" or @role="button" or @role="tab" or @onclick';

// describeMatches: for a click that did not land, each element carrying the
// label, as tag / role / box / opacity / href / onclick / its clickable
// ancestor's tag: shapes only, no page data.
export async function describeMatches(page, name) {
  return page.evaluate((n) => [...document.querySelectorAll('body *')]
    .filter((e) => [...e.childNodes].some((c) => c.nodeType === 3 && c.textContent.trim() === n))
    .slice(0, 6).map((e) => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e);
      const up = e.closest('a, button, [role=link], [role=button], [role=tab], [onclick]');
      return { tag: e.tagName.toLowerCase(), role: e.getAttribute('role') || '', box: [r.x, r.y, r.width, r.height].map(Math.round),
        opacity: cs.opacity, pe: cs.pointerEvents, href: e.hasAttribute('href'), onclick: e.hasAttribute('onclick'),
        up: up ? `${up.tagName.toLowerCase()}${up.hasAttribute('href') ? '[href]' : ''}${up.hasAttribute('onclick') ? '[onclick]' : ''}` : '' }; }), name)
    .catch((e) => [`describe failed: ${e.message}`]);
}

// findControl(page, name, forbidden, timeoutMs): the locator of the control,
// polled until it appears; throws on a forbidden label or a timeout.
export async function findControl(page, name, forbidden, timeoutMs = 30000) {
  if (isForbiddenLabel(name, forbidden)) throw new Error(`refused forbidden click: ${name}`);
  const end = Date.now() + timeoutMs;
  for (;;) {
    const hit = await firstHit(page, name);
    if (hit) {
      // the whole text and each line of it: a clickable ancestor (run 8)
      // may hold more than the label, and none of it may be forbidden.
      const text = (await hit.innerText().catch(() => '')).trim();
      const bad = [...text.split(/\n+/).map((l) => l.trim()), text].find((l) => l && isForbiddenLabel(l, forbidden));
      if (bad) throw new Error(`refused forbidden click: ${bad}`);
      return hit;
    }
    if (Date.now() > end) throw new Error(`no control named "${name}" within ${timeoutMs} ms`);
    await page.waitForTimeout(250);
  }
}

// OmaVero's "busy" layer (run 7: div.FastBusyOverlay was up while the tab
// bar kept being redrawn, and the click on the tab timed out: "element was
// detached from the DOM, retrying"). cnf selectors.busy overrides it.
export const DEFAULT_BUSY = '.FastBusyOverlay';

// settle: the page is quiet: network idle and the busy layer hidden or
// transparent (run 9: it stays up, full size, at opacity 0). Polled on a
// timer, not on animation frames: a background window draws none.
export async function settle(page, busy = DEFAULT_BUSY, timeoutMs = 30000) {
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForFunction((sel) => [...document.querySelectorAll(sel)]
    .every((e) => !(e.offsetWidth || e.offsetHeight) || getComputedStyle(e).opacity === '0'),
  busy, { polling: 250, timeout: timeoutMs }).catch(() => {});
}

// isSelected: a tab that is already the open one (aria-selected on it or
// its tab item). Clicking it again only reloads the view (run 7).
export async function isSelected(loc) {
  return loc.evaluate((e) => [e, e.parentElement].some((x) => x && x.getAttribute('aria-selected') === 'true')).catch(() => false);
}

// clickControl: settle, findControl, click (unless opts.skipSelected and it
// is already selected), settle again. Returns 'clicked', 'dom-clicked' or
// 'selected'. A mouse click that does not land within opts.clickMs (default
// 5 s) becomes a DOM click event on the same, already forbidden-checked
// element (run 9: in a background window Playwright's "stable" check never
// passes, and a transparent full-page layer would take a mouse click).
export async function clickControl(page, name, forbidden, timeoutMs, opts = {}) {
  const busy = opts.busy || DEFAULT_BUSY;
  await settle(page, busy);
  const loc = await findControl(page, name, forbidden, timeoutMs);
  if (opts.skipSelected && await isSelected(loc)) return 'selected';
  let how;
  try { how = await clickEl(loc, opts.clickMs, forbidden); } catch (e) { e.label = name; throw e; }
  await settle(page, busy);
  return how;
}

// clickEl: a mouse click, or after clickMs (default 5 s) a DOM click event
// on the same element. Every click of the fetch goes through here; with a
// forbidden list, the element's text and each line of it are checked
// first, so no click of either kind lands on a forbidden control.
export async function clickEl(loc, clickMs = 5000, forbidden = null) {
  if (forbidden) {
    const text = (await loc.innerText().catch(() => '')).trim();
    const bad = [...text.split(/\n+/).map((l) => l.trim()), text].find((l) => l && isForbiddenLabel(l, forbidden));
    if (bad) throw new Error(`refused forbidden click: ${bad}`);
  }
  try {
    await loc.click({ timeout: clickMs });
    return 'clicked';
  } catch (e) {
    if (e.name !== 'TimeoutError') throw e;
    await loc.dispatchEvent('click');
    return 'dom-clicked';
  }
}

// pageState: is the page shown and focused (a background window draws no
// frames)? For the failure log.
export async function pageState(page) {
  return page.evaluate(() => ({ visibility: document.visibilityState, focus: document.hasFocus() }))
    .catch((e) => ({ error: e.message }));
}

// retrieveDoc(ctx, page, link, forbidden, retrieveMark): the bytes of the
// document a row link opens, however OmaVero hands it over (the owner, msg
// 17dc84fa: "a really confusing way of downloading files"): a new tab on the
// Retrieve URL (its URL is read over the same login), a download, or the
// main page itself going to the Retrieve URL (then it goes back). It closes
// only the tabs its own click opened, never the main page or another tab.
export async function retrieveDoc(ctx, page, link, forbidden, retrieveMark, timeoutMs = 30000) {
  const label = (await link.innerText()).trim();
  if (isForbiddenLabel(label, forbidden)) throw new Error(`refused forbidden click: ${label}`);
  const before = new Set(ctx.pages());
  let dl = null;
  const onDl = (d) => { dl = d; };
  const onPage = (p) => p.on('download', onDl);
  page.on('download', onDl);
  ctx.on('page', onPage);
  const mine = () => ctx.pages().filter((p) => !before.has(p));
  try {
    await clickEl(link, 5000, forbidden);
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      if (dl) {
        const path = await dl.path();
        const { readFileSync } = await import('node:fs');
        return readFileSync(path);
      }
      const hit = mine().find((p) => p.url().includes(retrieveMark));
      if (hit) return await (await ctx.request.get(hit.url())).body();
      if (page.url().includes(retrieveMark)) {
        const body = await (await ctx.request.get(page.url())).body();
        await page.goBack().catch(() => {});
        return body;
      }
      await page.waitForTimeout(250);
    }
    throw new Error(`no document opened for "${label}" within ${timeoutMs} ms`);
  } finally {
    page.off('download', onDl);
    ctx.off('page', onPage);
    for (const p of mine()) await p.close().catch(() => {});
  }
}

// viewShape(page, keep): the shape of the view for offline fixes (VERO_RECORD
// _SHAPES): the masked path, every control (tag, role, href, visible, in
// main, masked text) and every table's row/column count. Texts are masked
// in node before anything is written (maskText); no page data is kept.
export async function viewShape(page, keep) {
  const raw = await page.evaluate(() => ({
    url: location.href,
    controls: [...document.querySelectorAll('a, button, input, select, [role=tab], [role=tablist], [role=link], [role=button], [onclick]')]
      .slice(0, 300).map((e) => ({ tag: e.tagName.toLowerCase(), role: e.getAttribute('role') || '', type: e.getAttribute('type') || '',
        href: e.hasAttribute('href'), onclick: e.hasAttribute('onclick'), selected: e.getAttribute('aria-selected') === 'true',
        visible: !!(e.offsetWidth || e.offsetHeight), main: !!e.closest('main'), text: (e.innerText || e.value || '').slice(0, 200) })),
    tables: [...document.querySelectorAll('table')].slice(0, 50).map((t) => ({ rows: t.rows.length,
      cols: Math.max(0, ...[...t.rows].map((r) => r.cells.length)), main: !!t.closest('main'), visible: !!(t.offsetWidth || t.offsetHeight) })),
  }));
  return { path: maskPath(raw.url), controls: raw.controls.map((c) => ({ ...c, text: maskText(c.text, keep) })), tables: raw.tables };
}
