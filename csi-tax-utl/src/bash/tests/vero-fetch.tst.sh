#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_vero_fetch and do_vero_session_stop. No browser opens and
# OmaVero is never called: a stub session (in place of vero-session.mjs)
# serves the requests the way the real one does.
#   1. Without VERO_BASE_URL ./run refuses before the action runs (exit 11)
#   2. DRY_RUN default prints the plan, starts nothing, makes no staging run
#   3. DRY_RUN=0 with no DISPLAY / WAYLAND_DISPLAY refuses (headed browser)
#   4. DRY_RUN=0 starts ONE session (profile dir 0700, the ui cnf passed) and
#      runs the fetch in a new 0700 staging run outside git
#   5. A second run REUSES the open session: no second start, same pid
#   6. A failing run (rc 3) fails the action, and the session stays open
#   7. VERO_YEAR that is not a year is refused
#   8. The scripts never close the window on a run, never type into a field
#      other than the archive dates, and hold no password or storageState code
#   9. do_vero_session_stop DRY_RUN=0 ends the session; the pid file is gone
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"
export VERO_SESSION_DIR="$T/session" VERO_PROFILE_DIR="$T/profile"
stub_down() { local p; p=$(cat "$VERO_SESSION_DIR/session.pid" 2>/dev/null) && kill "$p" 2>/dev/null; rm -rf "$T"; }
trap stub_down EXIT

cat >"$T/bin/fakenode" <<'STUB'
#!/bin/bash
# the stub session: $1 is .../vero-session.mjs
echo "start pid=$$ profile=$VERO_PROFILE_DIR cnf=$VERO_UI_CNF" >>"$STUB_LOG.node"
mkdir -p "$VERO_PROFILE_DIR" && chmod 700 "$VERO_PROFILE_DIR"
echo $$ >"$VERO_SESSION_DIR/session.pid"
while :; do
  for r in "$VERO_SESSION_DIR"/requests/*.json; do
    [[ -f "$r" ]] || continue
    id=$(basename "$r" .json); mv "$r" "$r.taken"
    grep -q '"stop"' "$r.taken" && { rm -f "$VERO_SESSION_DIR/session.pid"; exit 0; }
    out=$(jq -r .out "$r.taken")
    printf 'arrival_date\tkind\n2026-01-02\tdocument\n' >"$out/manifest.tsv"
    echo "vero-fetch: served $id cwd=$PWD" >>"$VERO_SESSION_DIR/results/$id.log"
    echo "{\"rc\":$(cat "$VERO_SESSION_DIR/next-rc" 2>/dev/null || echo 0)}" >"$VERO_SESSION_DIR/results/$id.json"
  done
  sleep 0.2
done
STUB
chmod +x "$T/bin/fakenode"
RUN=(VERO_BASE_URL=https://example.com/ DRY_RUN=0 DISPLAY=:9 VERO_NODE_BIN=fakenode)

vero_run VERO_BASE_URL= -- do_vero_fetch; rc=$?
if [[ $rc -eq 11 ]] && grep -q 'VERO_BASE_URL' "$T/out"; then pass "1. no VERO_BASE_URL -> exit 11"; else fail "1. rc=$rc"; fi

vero_run VERO_BASE_URL=https://example.com/ -- do_vero_fetch; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'PLAN' "$T/out" && [[ ! -d "$VERO_DATA_DIR/2026/staging" && ! -f "$STUB_LOG.node" ]]; then
  pass "2. dry run plans only"; else fail "2. rc=$rc"; fi

vero_run VERO_BASE_URL=https://example.com/ DRY_RUN=0 DISPLAY= WAYLAND_DISPLAY= VERO_NODE_BIN=fakenode -- do_vero_fetch; rc=$?
if [[ $rc -eq 2 ]] && grep -q 'DISPLAY' "$T/out" && [[ ! -f "$STUB_LOG.node" ]]; then pass "3. no desktop -> refused"; else fail "3. rc=$rc"; fi

vero_run "${RUN[@]}" -- do_vero_fetch; rc=$?
pid1=$(cat "$VERO_SESSION_DIR/session.pid" 2>/dev/null)
run=$(ls -d "$VERO_DATA_DIR"/2026/staging/* 2>/dev/null | tail -1)
if [[ $rc -eq 0 && -n "$pid1" && "$(stat -c %a "$VERO_PROFILE_DIR")" == 700 && "$(stat -c %a "$run")" == 700 && -f "$run/manifest.tsv" ]] \
  && grep -q 'cnf=.*/cnf/vero-ui.json' "$STUB_LOG.node" && grep -q 'vero-fetch: served' "$T/out" && ! git -C "$run" rev-parse 2>/dev/null; then
  pass "4. one session started, fetch served into a 0700 run"; else fail "4. rc=$rc $(tail -3 "$T/out")"; fi

vero_run "${RUN[@]}" -- do_vero_fetch; rc=$?
if [[ $rc -eq 0 && "$(grep -c '^start' "$STUB_LOG.node")" -eq 1 && "$(cat "$VERO_SESSION_DIR/session.pid")" == "$pid1" ]] && grep -q 'reusing the open browser session' "$T/out"; then
  pass "5. second run reuses the open session"; else fail "5. rc=$rc starts=$(grep -c '^start' "$STUB_LOG.node")"; fi

echo 3 >"$VERO_SESSION_DIR/next-rc"
vero_run "${RUN[@]}" -- do_vero_fetch; rc=$?
rm -f "$VERO_SESSION_DIR/next-rc"
if [[ $rc -eq 3 ]] && kill -0 "$pid1" 2>/dev/null; then pass "6. failing run -> exit 3, window stays open"; else fail "6. rc=$rc"; fi

vero_run VERO_BASE_URL=https://example.com/ VERO_YEAR=26 -- do_vero_fetch; rc=$?
if [[ $rc -eq 2 ]]; then pass "7. bad VERO_YEAR refused"; else fail "7. rc=$rc"; fi

N="$MOD_ROOT/src/node"
fills=$(cat "$N/vero-steps.mjs" "$N/vero-session.mjs" | grep -cE '\.(fill|type|press)\(')
closes=$(cat "$N/vero-steps.mjs" | grep -cE '(browser|ctx|context)\.close\(')
if [[ "$fills" -eq 2 && "$closes" -eq 0 ]] && [[ "$(grep -c 'ctx.close()' "$N/vero-session.mjs")" -eq 1 ]] && grep -q 'if (!closed) await s.ctx.close()' "$N/vero-session.mjs" \
  && ! cat "$N"/vero-*.mjs | grep -qiE 'password|storageState|addCookies'; then
  pass "8. no close on a run, 2 date fills only, no login code"; else fail "8. fills=$fills closes=$closes"; fi

vero_run DRY_RUN=0 -- do_vero_session_stop; rc=$?
if [[ $rc -eq 0 && ! -f "$VERO_SESSION_DIR/session.pid" ]] && ! kill -0 "$pid1" 2>/dev/null; then pass "9. stop ends the session"; else fail "9. rc=$rc $(tail -2 "$T/out")"; fi
finish
