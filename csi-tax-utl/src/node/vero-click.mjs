// Finding and clicking an OmaVero control by its label, for vero-fetch.mjs.
// The live run (2026-11-24) found none of its labels as a link/tab/button
// with that exact accessible name, though every label was on the page: a
// chevron inside the name, or an <a> without href (no link role). So the
// lookup tries, in order, until one matches or the wait runs out:
//   1. a link, tab or button with the exact accessible name
//   2. the same roles, the name allowed a leading/trailing chevron
//   3. the exact visible text inside main, nav, header or a tablist
// A forbidden label is refused before any lookup, and again on the text of
// what was found. Only VISIBLE matches count: run 4 found a hidden
// duplicate first and its click timed out. vero-click.tst.sh runs it on a
// local HTML fixture.
import { isForbiddenLabel } from './vero-lib.mjs';

const ROLES = ['link', 'tab', 'button'];
const SCOPE = 'main, nav, header, [role="tablist"], [role="navigation"]';
const CHEVRONS = '\\s›>»❯→';

// chevronRx("Saldoerittely") matches "› Saldoerittely", "Saldoerittely >".
export function chevronRx(name) {
  const esc = String(name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^[${CHEVRONS}]*${esc}[${CHEVRONS}]*$`, 'i');
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
  return (await t.count()) ? t.first() : null;
}

// findControl(page, name, forbidden, timeoutMs): the locator of the control,
// polled until it appears; throws on a forbidden label or a timeout.
export async function findControl(page, name, forbidden, timeoutMs = 30000) {
  if (isForbiddenLabel(name, forbidden)) throw new Error(`refused forbidden click: ${name}`);
  const end = Date.now() + timeoutMs;
  for (;;) {
    const hit = await firstHit(page, name);
    if (hit) {
      const text = (await hit.innerText().catch(() => '')).trim();
      if (text && isForbiddenLabel(text, forbidden)) throw new Error(`refused forbidden click: ${text}`);
      return hit;
    }
    if (Date.now() > end) throw new Error(`no control named "${name}" within ${timeoutMs} ms`);
    await page.waitForTimeout(250);
  }
}

// clickControl: findControl, click, wait for the page to settle.
export async function clickControl(page, name, forbidden, timeoutMs) {
  const loc = await findControl(page, name, forbidden, timeoutMs);
  await loc.click();
  await page.waitForLoadState('networkidle').catch(() => {});
}
