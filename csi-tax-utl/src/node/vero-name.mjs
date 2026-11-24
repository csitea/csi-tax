// node vero-name.mjs <manifest.tsv> <index.tsv|-> : the filing plan of
// do_vero_file, one line per manifest file not yet in the index (by sha256):
//   <source file>\t<index row in INDEX_COLUMNS order>
// The per-day sequence NN continues after the files the index already holds
// for that day, so a new letter on a filed day never reuses a name.
import { existsSync, readFileSync } from 'node:fs';
import { fileName, tsvField } from './vero-lib.mjs';

export const INDEX_COLUMNS = ['arrival_date', 'kind', 'type', 'tax_type', 'period', 'due_date', 'category', 'sha256', 'file_name'];

export function readTsv(path) {
  if (!path || path === '-' || !existsSync(path)) return [];
  const [head, ...lines] = readFileSync(path, 'utf8').split('\n').filter((l) => l.trim());
  const cols = head.split('\t');
  return lines.map((l) => Object.fromEntries(l.split('\t').map((v, i) => [cols[i], v])));
}

export function plan(manifest, index) {
  const seen = new Set(index.map((r) => r.sha256));
  const perDay = {};
  for (const r of index) perDay[r.arrival_date] = (perDay[r.arrival_date] ?? 0) + 1;
  const out = [];
  for (const r of manifest) {
    if (!r.sha256 || seen.has(r.sha256)) continue;
    seen.add(r.sha256);
    perDay[r.arrival_date] = (perDay[r.arrival_date] ?? 0) + 1;
    const ext = (r.file.match(/\.([a-z0-9]+)$/i) ?? [, 'pdf'])[1];
    const row = { ...r, file_name: fileName({ ...r, seq: perDay[r.arrival_date], ext }) };
    out.push([r.file, ...INDEX_COLUMNS.map((c) => tsvField(row[c]))].join('\t'));
  }
  return out;
}

if (process.argv[1] && process.argv[1].endsWith('vero-name.mjs')) {
  const lines = plan(readTsv(process.argv[2]), readTsv(process.argv[3]));
  if (lines.length) process.stdout.write(lines.join('\n') + '\n');
}
