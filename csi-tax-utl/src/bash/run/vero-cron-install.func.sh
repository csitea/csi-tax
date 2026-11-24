#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the weekly Vero trigger in the current user's crontab:
# @description one line, marked "# csi-tax vero-weekly-due", that at minute :30
# @description of every hour Monday to Wednesday (box time) reads the env file
# @description VERO_ENV_FILE and runs do_vero_weekly_due from this checkout,
# @description which acts only at Tuesday 15:30 Europe/Helsinki. A rerun
# @description replaces the marked line and leaves every other line alone.
# @description The env file (outside git, mode 600) holds the VERO_* values,
# @description VERO_NOTIFY_CMD included. DRY_RUN=1 (default) prints the line.
# @param VERO_ENV_FILE (required) - the env file the cron line sources
# @param VERO_CRONTAB_BIN (optional) - default crontab
# @param DRY_RUN (optional) - 1 (default) prints the line; 0 installs it
# @example VERO_ENV_FILE=<env file> ./run -a do_vero_cron_install
# @example VERO_ENV_FILE=<env file> DRY_RUN=0 ./run -a do_vero_cron_install
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_cron_install() {
  : "${VERO_ENV_FILE:?VERO_ENV_FILE must be set (no default): the env file outside git}"
  local ct="${VERO_CRONTAB_BIN:-crontab}" dir line cur mark='# csi-tax vero-weekly-due'
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
  [[ -r "$VERO_ENV_FILE" ]] || { do_log "FATAL VERO_ENV_FILE is not readable"; return 2; }
  [[ "$(stat -c %a "$VERO_ENV_FILE")" == 600 ]] || { do_log "FATAL VERO_ENV_FILE must be mode 600"; return 2; }
  line="30 * * * 1-3 . '$VERO_ENV_FILE' && cd '$dir' && DRY_RUN=0 ./run -a do_vero_weekly_due >/dev/null 2>&1 $mark"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO PLAN crontab line: $line"
    return 0
  fi
  cur=$("$ct" -l 2>/dev/null | grep -vF "$mark" || true)
  printf '%s\n%s\n' "$cur" "$line" | sed '/^$/d' | "$ct" - || { do_log "ERROR crontab install failed"; return 3; }
  do_log "INFO OK do_vero_cron_install: $("$ct" -l | grep -cF "$mark") marked line in the crontab of $(id -un)"
}
