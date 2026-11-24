#!/bin/bash
#------------------------------------------------------------------------------
# @description The weekly trigger of the Vero check, run by cron: when the
# @description time in VERO_SCHEDULE_TZ is VERO_SCHEDULE_DAY at
# @description VERO_SCHEDULE_TIME, it runs VERO_NOTIFY_CMD once, which wakes
# @description the seat that asks the owner to log in (runbook section 5).
# @description At any other time it does nothing and exits 0. The box cron has
# @description no per-crontab timezone, so the cron line fires at minute :30 of
# @description every hour of the day and this guard picks the right one, the
# @description same across DST whatever the box timezone is.
# @description A stamp under VERO_DATA_DIR keeps it to one notice per day.
# @param VERO_NOTIFY_CMD (optional) - the command that wakes the seat; needed when due
# @param VERO_SCHEDULE_TZ (optional) - default Europe/Helsinki
# @param VERO_SCHEDULE_DAY (optional) - weekday, date +%a in C locale, default Tue
# @param VERO_SCHEDULE_TIME (optional) - HH:MM, default 15:30
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_NOW (optional) - a date -d time, for tests; default now
# @param DRY_RUN (optional) - 1 (default) prints the notice; 0 sends it
# @example ./run -a do_vero_weekly_due
# @example VERO_NOW='2026-12-01 13:30Z' ./run -a do_vero_weekly_due
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_weekly_due() {
  local tz="${VERO_SCHEDULE_TZ:-Europe/Helsinki}" now local_t want stamp
  now="${VERO_NOW:-now}"
  local_t=$(LC_ALL=C TZ="$tz" date -d "$now" '+%a %H:%M %F') || return 2
  want="${VERO_SCHEDULE_DAY:-Tue} ${VERO_SCHEDULE_TIME:-15:30}"
  if [[ "${local_t% *}" != "$want" ]]; then
    do_log "INFO do_vero_weekly_due: not due (${local_t% *} $tz, due $want)"
    return 0
  fi
  stamp="${VERO_DATA_DIR:-$HOME/var/csi-tax/vero}/.weekly-due.${local_t##* }"
  [[ -e "$stamp" ]] && { do_log "INFO do_vero_weekly_due: already sent today"; return 0; }
  : "${VERO_NOTIFY_CMD:?VERO_NOTIFY_CMD must be set (no default): the command that wakes the Vero seat}"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO PLAN do_vero_weekly_due: due ($want $tz); DRY_RUN=0 runs VERO_NOTIFY_CMD"
    return 0
  fi
  bash -c "$VERO_NOTIFY_CMD" || { do_log "ERROR do_vero_weekly_due: VERO_NOTIFY_CMD failed"; return 3; }
  mkdir -p "${stamp%/*}" && : >"$stamp"
  do_log "INFO OK do_vero_weekly_due: weekly Vero check notice sent ($want $tz)"
}
