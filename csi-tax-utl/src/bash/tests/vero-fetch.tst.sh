#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_vero_fetch. No browser opens and OmaVero is never called:
# a stub node stands in for the fetch script.
#   1. Without VERO_BASE_URL ./run refuses before the action runs (exit 11)
#   2. DRY_RUN default prints the plan, starts nothing, makes no staging run
#   3. DRY_RUN=0 with no DISPLAY / WAYLAND_DISPLAY refuses (headed browser)
#   4. DRY_RUN=0 runs the fetch with its cwd in a new 0700 staging run, outside git
#   5. The fetch gets the year, the out dir and the ui cnf
#   6. A failing fetch (exit 3) fails the action with that code
#   7. VERO_YEAR that is not a year is refused
#   8. The fetch script never types into a field other than the archive dates,
#      and holds no password / cookie / storageState code
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"

cat >"$T/bin/fakenode" <<'STUB'
#!/bin/bash
{ echo "cwd=$PWD"; echo "out=$VERO_OUT_DIR"; echo "year=$VERO_YEAR"; echo "cnf=$VERO_UI_CNF"; echo "script=$1"; } >"$STUB_LOG.node"
printf 'arrival_date\tkind\n2026-01-02\tdocument\n' >"$VERO_OUT_DIR/manifest.tsv"
exit "${FAKE_NODE_RC:-0}"
STUB
chmod +x "$T/bin/fakenode"

vero_run VERO_BASE_URL= -- do_vero_fetch; rc=$?
if [[ $rc -eq 11 ]] && grep -q 'VERO_BASE_URL' "$T/out"; then pass "1. no VERO_BASE_URL -> exit 11"; else fail "1. rc=$rc $(tail -2 "$T/out")"; fi

vero_run VERO_BASE_URL=https://example.com/ -- do_vero_fetch; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'PLAN' "$T/out" && [[ ! -d "$VERO_DATA_DIR/2026/staging" ]] && [[ ! -f "$STUB_LOG.node" ]]; then
  pass "2. dry run plans only"; else fail "2. rc=$rc"; fi

vero_run VERO_BASE_URL=https://example.com/ DRY_RUN=0 DISPLAY= WAYLAND_DISPLAY= VERO_NODE_BIN=fakenode -- do_vero_fetch; rc=$?
if [[ $rc -eq 2 ]] && grep -q 'DISPLAY' "$T/out" && [[ ! -f "$STUB_LOG.node" ]]; then pass "3. no desktop -> refused"; else fail "3. rc=$rc"; fi

vero_run VERO_BASE_URL=https://example.com/ DRY_RUN=0 DISPLAY=:9 VERO_NODE_BIN=fakenode -- do_vero_fetch; rc=$?
run=$(sed -n 's/^out=//p' "$STUB_LOG.node" 2>/dev/null)
cwd=$(sed -n 's/^cwd=//p' "$STUB_LOG.node" 2>/dev/null)
if [[ $rc -eq 0 && -n "$run" && "$cwd" == "$run" && "$(stat -c %a "$run")" == 700 ]] && ! git -C "$run" rev-parse 2>/dev/null; then
  pass "4. fetch ran in a 0700 staging run outside git"; else fail "4. rc=$rc run=$run cwd=$cwd $(tail -3 "$T/out")"; fi

if grep -qx 'year=2026' "$STUB_LOG.node" && grep -q 'cnf=.*/cnf/vero-ui.json$' "$STUB_LOG.node" && grep -q 'script=.*/src/node/vero-fetch.mjs$' "$STUB_LOG.node"; then
  pass "5. year, out dir, ui cnf and script passed"; else fail "5. $(cat "$STUB_LOG.node")"; fi

vero_run VERO_BASE_URL=https://example.com/ DRY_RUN=0 DISPLAY=:9 VERO_NODE_BIN=fakenode FAKE_NODE_RC=3 -- do_vero_fetch; rc=$?
if [[ $rc -eq 3 ]]; then pass "6. failing fetch -> exit 3"; else fail "6. rc=$rc"; fi

vero_run VERO_BASE_URL=https://example.com/ VERO_YEAR=26 -- do_vero_fetch; rc=$?
if [[ $rc -eq 2 ]]; then pass "7. bad VERO_YEAR refused"; else fail "7. rc=$rc"; fi

src="$MOD_ROOT/src/node/vero-fetch.mjs"
fills=$(grep -cE '\.(fill|type|press)\(' "$src")
if [[ "$fills" -eq 2 ]] && ! grep -qiE 'password|storageState|cookies\(|addCookies|launchPersistentContext' "$src"; then
  pass "8. only the two archive date fields are filled; no login or cookie code"; else fail "8. fills=$fills"; fi
finish
