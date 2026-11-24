// Pure helpers of the OmaVero fetch: no browser, no network, no file I/O,
// so src/bash/tests/vero-lib.tst.sh runs them without Playwright.

// parseFiDate("3.2.2026") -> "2026-02-03"; also takes an ISO date; else "".
export function parseFiDate(text) {
  const s = String(text ?? '');
  let m = s.match(/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  m = s.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : '';
}

// dueDate(rowText): the date after a due-date label (fi, sv, en), else "".
export function dueDate(text) {
  const m = String(text ?? '').match(/(eräpäivä|förfallodag|due date|due)\D{0,12}(\d{1,2}\.\d{1,2}\.\d{4}|\d{4}-\d{2}-\d{2})/i);
  return m ? parseFiDate(m[2]) : '';
}

// arrivalDate(rowText): the first date in the row that is not the due date.
export function arrivalDate(text) {
  const s = String(text ?? '');
  const due = dueDate(s);
  const all = [...s.matchAll(/\b\d{1,2}\.\d{1,2}\.\d{4}\b|\b\d{4}-\d{2}-\d{2}\b/g)].map((m) => parseFiDate(m[0]));
  return all.find((d) => d !== due) ?? all[0] ?? '';
}

// inYear("2026-03-01", 2026) -> true
export function inYear(isoDate, year) {
  return typeof isoDate === 'string' && isoDate.startsWith(`${year}-`);
}

// scrubAmounts: money amounts out of a text that may reach a message or git.
export function scrubAmounts(text) {
  return String(text ?? '')
    .replace(/(€|eur|euro[a-z]*)\s*-?\d[\d\s.,]*/gi, '<amount>')
    .replace(/-?\d[\d\s.]*(,\d{1,2})?\s*(€|eur\b|euro[a-z]*)/gi, '<amount>');
}

// tsvField: one TSV cell, tabs and newlines folded to spaces.
export function tsvField(v) {
  return String(v ?? '').replace(/[\t\r\n]+/g, ' ').trim();
}

// manifestRow: the staging manifest line, in the column order of
// MANIFEST_COLUMNS (do_vero_file reads it by that header).
export const MANIFEST_COLUMNS = ['arrival_date', 'kind', 'type', 'tax_type', 'period', 'file', 'sha256', 'due_date', 'category'];
export function manifestRow(r) {
  return MANIFEST_COLUMNS.map((c) => tsvField(r[c])).join('\t');
}

// fileName({arrival_date, seq, type, period}) ->
// "2026-03-04_01_Verotuspaatos[_kausi-31.12.2025].pdf": the name the
// first hand run used in the bucket, so the weekly files sort beside it.
export function fileName({ arrival_date: d, seq, type, period, ext = 'pdf' }) {
  const t = scrubAmounts(type).replace(/<amount>/g, '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .replace(/\(pdf\)/i, '').trim().replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'Document';
  const k = String(period ?? '').match(/\d{1,2}\.\d{1,2}\.\d{4}/);
  return `${d}_${String(seq).padStart(2, '0')}_${t}${k ? `_kausi-${k[0]}` : ''}.${ext}`;
}

// driveCategory(kind, type): the owner's Drive subdir under
// <yyyy>/<yyyy-mm>/vero/.
export function driveCategory(kind, type) {
  const t = String(type ?? '').toLowerCase();
  if (kind === 'message') return 'msgs';
  if (kind === 'payments') return 'payments';
  if (/saldo|balance/.test(t)) return 'balance';
  if (/todistus|intyg|certificate/.test(t)) return 'certificates';
  if (/tiliote|erittely|statement|kontoutdrag/.test(t)) return 'statements';
  return 'decisions';
}

// isForbiddenLabel(label, forbidden[]): true for a control the fetch must
// never click (archive, send, any form, refund, account number).
export function isForbiddenLabel(label, forbidden) {
  const l = String(label ?? '').trim().toLowerCase();
  return forbidden.some((f) => {
    const x = String(f).toLowerCase();
    return x.endsWith('*') ? l.startsWith(x.slice(0, -1)) : l === x || l.includes(x);
  });
}

// isPdf(bytes): the first five bytes are %PDF-.
export function isPdf(buf) {
  return !!buf && buf.length >= 5 && Buffer.from(buf.subarray(0, 5)).toString('latin1') === '%PDF-';
}

// isWriteRequest: the request methods the read-only guard aborts.
export function isWriteRequest(method) {
  return ['PUT', 'PATCH', 'DELETE'].includes(String(method).toUpperCase());
}

// keepaliveDue(now, last, env): the kept-open session reloads its keep-alive
// tab when VERO_KEEPALIVE is not 0 and VERO_KEEPALIVE_MIN minutes (default 2:
// the owner, msg c65f1716, OmaVero drops an idle login after about 5) have
// passed since the last reload or fetch. Times in ms.
export function keepaliveDue(now, last, env = {}) {
  if (String(env.VERO_KEEPALIVE ?? '1') === '0') return false;
  const min = Number(env.VERO_KEEPALIVE_MIN ?? 2);
  return Number.isFinite(min) && min > 0 && now - last >= min * 60000;
}

// clickLog(message): the lines of a Playwright error that say why a click
// did not land (run 6: every click timed out on a visible control), e.g.
// "<div class=overlay> intercepts pointer events"; deduped, at most 6,
// amounts scrubbed, each cut to 200 chars.
export function clickLog(message) {
  const keep = /intercepts pointer events|not stable|not visible|not enabled|outside of the viewport|waiting for|retrying|scrolling/i;
  const out = [];
  for (const raw of String(message).split('\n').slice(1)) {
    const l = scrubUrls(scrubAmounts(raw.trim().replace(/^-\s*/, ''))).slice(0, 200);
    if (l && keep.test(l) && !out.includes(l)) out.push(l);
    if (out.length === 6) break;
  }
  return out;
}

// scrubUrls(text): every URL without its query and fragment (run 10: a
// login redirect's one-time code reached the click log).
export function scrubUrls(text) {
  return String(text).replace(/(https?:\/\/[^\s?#"']+)[?#][^\s"']*/g, '$1?<scrubbed>');
}
