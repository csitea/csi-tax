// The weekly view of the OmaVero index, for do_vero_weekly_diff and
// do_vero_weekly_report:
//   node vero-weekly.mjs diff   <index> <prev|-> <today> <issues dir>
//   node vero-weekly.mjs report <index> <prev|-> <today> <due window days>
// Both print markdown on stdout. They read the index only (dates, labels,
// categories, hashes), never a PDF, and scrub amounts from every label.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readTsv } from './vero-name.mjs';
import { scrubAmounts } from './vero-lib.mjs';

const key = (r) => `${r.kind}|${r.type}|${r.tax_type}|${r.period}`;
const label = (r) => scrubAmounts([String(r.type ?? '').replace(/\s*\(pdf\)/i, ''), r.tax_type, r.period && `kausi ${r.period}`].filter(Boolean).join(', '));

export function compare(index, prev) {
  const prevSha = new Set(prev.map((r) => r.sha256));
  const fresh = index.filter((r) => !prevSha.has(r.sha256));
  const prevKeys = new Set(prev.map(key));
  return {
    added: fresh.filter((r) => !prevKeys.has(key(r))),
    changed: fresh.filter((r) => prevKeys.has(key(r))),
  };
}

function line(r) {
  const due = r.due_date ? `, due ${r.due_date}` : '';
  return `- ${r.arrival_date} ${label(r)} (${r.category}${due}): \`${r.file_name}\``;
}

function themes(rows) {
  const by = {};
  for (const r of rows) (by[r.category] ??= []).push(r);
  return by;
}

export function diffMd(index, prev, today) {
  const { added, changed } = compare(index, prev);
  const out = [`# OmaVero weekly diff ${today}`, '', `Compared with ${prev.length ? 'last week\'s index' : 'no earlier index (first run: everything is new)'}.`, ''];
  out.push(`## 1. New (${added.length})`, '', ...(added.length ? added.map(line) : ['- none']), '');
  out.push(`## 2. Changed (${changed.length})`, '', ...(changed.length ? changed.map(line) : ['- none']), '');
  return { md: out.join('\n'), themes: themes([...added, ...changed]) };
}

export function issueMd(theme, rows, today) {
  return [`# vero ${today}: ${theme} (${rows.length} new)`, '',
    'Draft issue, one per theme; the files are in the private bucket and the owner\'s Drive, never in the issue.', '',
    '## Items', '', ...rows.map(line), '',
    '## Next step', '', '- [ ] read the item(s) in the owner\'s Drive and note what has to be done, by when', ''].join('\n');
}

function upcoming(index, today, days) {
  const end = new Date(Date.parse(today) + days * 86400000).toISOString().slice(0, 10);
  return index.filter((r) => r.due_date && r.due_date >= today && r.due_date <= end)
    .sort((a, b) => a.due_date.localeCompare(b.due_date));
}

export function reportMd(index, prev, today, days) {
  const { added, changed } = compare(index, prev);
  const fresh = [...added, ...changed];
  const due = upcoming(index, today, days);
  const decisions = fresh.filter((r) => r.category === 'decisions');
  const pay = fresh.filter((r) => r.category === 'payments' || r.category === 'balance');
  const open = fresh.filter((r) => r.category === 'decisions' && !r.due_date);
  const list = (rs, f = line) => (rs.length ? rs.map(f) : ['- none']);
  return [`# Vero weekly report, week of ${today}`, '',
    'From the OmaVero index of this week\'s fetch. No amounts: they are in the files, in the owner\'s Drive.', '',
    `## 1. What is new this week (${added.length})`, '', ...list(added), '',
    `## 2. What changed (${changed.length})`, '', ...list(changed), '',
    '## 3. To take into consideration', '',
    `### 3.1 Due dates in the next ${days} days (${due.length})`, '', ...list(due, (r) => `- **${r.due_date}** ${label(r)}`), '',
    `### 3.2 Decisions received (${decisions.length})`, '', ...list(decisions), '',
    `### 3.3 Payments and balance (${pay.length})`, '', ...list(pay, (r) => `- ${label(r)}: the table changed, check it in Drive (\`${r.file_name}\`)`), '',
    `### 3.4 Open questions (${open.length})`, '', ...list(open, (r) => `- ${label(r)}: a decision with no due date, does it need an action?`), ''].join('\n');
}

if (process.argv[1] && process.argv[1].endsWith('vero-weekly.mjs')) {
  const [mode, idx, prv, today, arg] = process.argv.slice(2);
  const index = readTsv(idx), prev = readTsv(prv);
  if (mode === 'diff') {
    const { md, themes: th } = diffMd(index, prev, today);
    mkdirSync(arg, { recursive: true, mode: 0o700 });
    for (const [t, rs] of Object.entries(th)) writeFileSync(join(arg, `${today}-${t}.md`), issueMd(t, rs, today), { mode: 0o600 });
    process.stdout.write(md + '\n');
  } else if (mode === 'report') {
    process.stdout.write(reportMd(index, prev, today, Number(arg || 30)) + '\n');
  } else {
    console.error('usage: vero-weekly.mjs diff|report <index> <prev|-> <today> <arg>');
    process.exit(2);
  }
}
