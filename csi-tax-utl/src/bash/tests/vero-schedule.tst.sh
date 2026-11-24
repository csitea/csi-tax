#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_vero_weekly_due and do_vero_cron_install. A stub notify
# command and a stub crontab stand in; no real crontab is read or written.
#   1. Tuesday 15:30 Helsinki in winter (13:30Z) is due; the notice runs once
#   2. The same minute again that day -> "already sent", no second notice
#   3. Tuesday 15:30 Helsinki in summer (12:30Z) is due (DST followed)
#   4. 14:30Z on a winter Tuesday (16:30 Helsinki) and a Monday are not due
#   5. Due with no VERO_NOTIFY_CMD -> fails fast, names the var
#   6. The same instant reads the same in any box TZ (TZ=UTC vs Amsterdam)
#   7. cron install: no VERO_ENV_FILE -> exit 11; env file not 600 -> refused
#   8. cron install DRY_RUN=0 adds one marked line, keeps other lines, and a
#      rerun still leaves exactly one
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"
N="$T/notified"
NOTE="echo x >>'$N'"

vero_run VERO_NOW='2026-12-01 13:30Z' VERO_NOTIFY_CMD="$NOTE" DRY_RUN=0 -- do_vero_weekly_due; rc=$?
if [[ $rc -eq 0 && "$(wc -l <"$N" 2>/dev/null)" -eq 1 ]]; then pass "1. winter Tue 15:30 Helsinki due, one notice"; else fail "1. rc=$rc $(tail -2 "$T/out")"; fi

vero_run VERO_NOW='2026-12-01 13:30Z' VERO_NOTIFY_CMD="$NOTE" DRY_RUN=0 -- do_vero_weekly_due; rc=$?
if [[ $rc -eq 0 && "$(wc -l <"$N")" -eq 1 ]] && grep -q 'already sent' "$T/out"; then pass "2. second run same day sends nothing"; else fail "2. rc=$rc"; fi

vero_run VERO_NOW='2026-06-02 12:30Z' VERO_NOTIFY_CMD="$NOTE" DRY_RUN=0 -- do_vero_weekly_due; rc=$?
if [[ $rc -eq 0 && "$(wc -l <"$N")" -eq 2 ]]; then pass "3. summer Tue 15:30 Helsinki (12:30Z) due"; else fail "3. rc=$rc"; fi

vero_run VERO_NOW='2026-12-08 14:30Z' VERO_NOTIFY_CMD="$NOTE" DRY_RUN=0 -- do_vero_weekly_due; a=$?
vero_run VERO_NOW='2026-12-07 13:30Z' VERO_NOTIFY_CMD="$NOTE" DRY_RUN=0 -- do_vero_weekly_due; b=$?
if [[ $a -eq 0 && $b -eq 0 && "$(wc -l <"$N")" -eq 2 ]]; then pass "4. off-hour and Monday not due"; else fail "4. rc=$a/$b n=$(wc -l <"$N")"; fi

vero_run VERO_NOW='2026-12-15 13:30Z' VERO_NOTIFY_CMD= DRY_RUN=0 -- do_vero_weekly_due; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'VERO_NOTIFY_CMD must be set' "$T/out"; then pass "5. due without notify cmd fails fast"; else fail "5. rc=$rc"; fi

vero_run TZ=UTC VERO_NOW='2026-12-22 13:30Z' DRY_RUN=1 VERO_NOTIFY_CMD=true -- do_vero_weekly_due; a=$(grep -c 'PLAN' "$T/out")
vero_run TZ=Europe/Amsterdam VERO_NOW='2026-12-22 13:30Z' DRY_RUN=1 VERO_NOTIFY_CMD=true -- do_vero_weekly_due; b=$(grep -c 'PLAN' "$T/out")
if [[ $a -eq 1 && $b -eq 1 ]]; then pass "6. box TZ does not move the schedule"; else fail "6. utc=$a ams=$b"; fi

cat >"$T/bin/fakecrontab" <<'STUB'
#!/bin/bash
f="$FAKE_CRONTAB"
case "$1" in -l) [[ -f "$f" ]] && cat "$f" || exit 1 ;; -) cat >"$f" ;; esac
STUB
chmod +x "$T/bin/fakecrontab"
export FAKE_CRONTAB="$T/crontab"
echo '0 1 * * * other-job' >"$FAKE_CRONTAB"
printf 'VERO_NOTIFY_CMD=true\n' >"$T/vero.env"; chmod 644 "$T/vero.env"
vero_run VERO_ENV_FILE= -- do_vero_cron_install; a=$?
vero_run VERO_ENV_FILE="$T/vero.env" VERO_CRONTAB_BIN=fakecrontab DRY_RUN=0 -- do_vero_cron_install; b=$?
if [[ $a -eq 11 && $b -eq 2 ]] && grep -q 'mode 600' "$T/out"; then pass "7. env file required and 600"; else fail "7. rc=$a/$b"; fi

chmod 600 "$T/vero.env"
vero_run VERO_ENV_FILE="$T/vero.env" VERO_CRONTAB_BIN=fakecrontab DRY_RUN=0 -- do_vero_cron_install
vero_run VERO_ENV_FILE="$T/vero.env" VERO_CRONTAB_BIN=fakecrontab DRY_RUN=0 -- do_vero_cron_install; rc=$?
if [[ $rc -eq 0 ]] && [[ "$(grep -c 'csi-tax vero-weekly-due' "$FAKE_CRONTAB")" -eq 1 ]] && grep -qx '0 1 \* \* \* other-job' "$FAKE_CRONTAB" \
  && grep -q "^30 \* \* \* 1-3 \. '$T/vero.env' && cd '$MOD_ROOT' && DRY_RUN=0 ./run -a do_vero_weekly_due" "$FAKE_CRONTAB"; then
  pass "8. one marked line, other lines kept"; else fail "8. rc=$rc $(cat "$FAKE_CRONTAB")"; fi
finish
