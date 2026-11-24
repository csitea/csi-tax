#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_vero_weekly_diff and do_vero_weekly_report, on two weeks
# of fixture filings (fake PDFs) made by do_vero_file itself.
#   1. No index -> both refuse, exit 2
#   2. The diff compares with last week's dated copy and lists only the new
#      and the changed items, not last week's
#   3. One issue draft per new theme
#   4. The report has the sections 1, 2, 3.1-3.4; the due date inside the
#      window is listed, the one outside is not
#   5. No amount reaches the report (a label carrying one is scrubbed)
#   6. Report and diff are written 600 under <year>/reports/
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"
Y="$VERO_DATA_DIR/2026"

vero_run -- do_vero_weekly_diff; rc1=$?
vero_run -- do_vero_weekly_report; rc2=$?
if [[ $rc1 -eq 2 && $rc2 -eq 2 ]]; then pass "1. no index -> exit 2"; else fail "1. rc=$rc1/$rc2"; fi

vero_fixture_run 20260301T100000 \
  "2026-02-26|document|Verotuspäätös (pdf)|Tulovero|31.12.2025||decisions|old" \
  "2026-03-01|payments|Payments-table-1||||payments|pay-v1" >/dev/null
vero_run VERO_TODAY=2026-03-02 -- do_vero_file || fail "fixture week 1 filing"
vero_fixture_run 20260308T100000 \
  "2026-03-05|document|Kirje (pdf)|Arvonlisävero|||decisions|new1" \
  "2026-03-06|document|Tiliote 1 234,50 € (pdf)|||2026-03-20|statements|new2" \
  "2026-03-07|document|Päätös (pdf)|Ennakkovero||2026-06-30|decisions|new3" \
  "2026-03-08|payments|Payments-table-1||||payments|pay-v2" >/dev/null
vero_run VERO_TODAY=2026-03-09 -- do_vero_file || fail "fixture week 2 filing"

vero_run VERO_TODAY=2026-03-09 -- do_vero_weekly_diff; rc=$?
d="$Y/reports/diff-2026-03-09.md"
if [[ $rc -eq 0 ]] && grep -q '## 1. New (3)' "$d" && grep -q '## 2. Changed (1)' "$d" && ! grep -q 'Verotuspaatos' "$d"; then
  pass "2. diff lists only new + changed"; else fail "2. rc=$rc $(cat "$d" 2>&1 | head -20)"; fi

themes=$(ls "$Y/reports/issues" 2>/dev/null | tr '\n' ' ')
if [[ "$themes" == "2026-03-09-decisions.md 2026-03-09-payments.md 2026-03-09-statements.md " ]]; then pass "3. one draft per theme"; else fail "3. [$themes]"; fi

vero_run VERO_TODAY=2026-03-09 -- do_vero_weekly_report; rc=$?
r="$Y/reports/weekly-2026-03-09.md"
secs=$(grep -cE '^## (1|2|3)\. |^### 3\.[1-4] ' "$r" 2>/dev/null)
if [[ $rc -eq 0 && "$secs" -eq 7 ]] && grep -q '^- \*\*2026-03-20\*\*' "$r" && ! grep -q '2026-06-30\*\*' "$r"; then
  pass "4. sections + due window"; else fail "4. rc=$rc secs=$secs"; fi

if ! grep -qE '[0-9] ?€|€ ?[0-9]|234' "$r" && grep -q '<amount>' "$r"; then pass "5. no amount in the report"; else fail "5. $(grep -nE '€|1 234' "$r")"; fi

if [[ "$(stat -c %a "$r")" == 600 && "$(stat -c %a "$d")" == 600 ]]; then pass "6. reports are 600"; else fail "6."; fi
finish
