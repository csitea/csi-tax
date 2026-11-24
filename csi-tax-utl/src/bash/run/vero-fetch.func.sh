#!/bin/bash
#------------------------------------------------------------------------------
# @description Fetch a year of OmaVero, read-only: open a HEADED browser on the
# @description owner's desktop, WAIT for the owner to log in himself (the action
# @description never types, reads or stores login data: a fresh browser
# @description context, discarded at the end), then save the decisions and
# @description letters (inbox and archive, every PDF), the messages, the paid
# @description taxes and refunds tables (csv), the balance pages and the tasks
# @description page into a new staging run under VERO_DATA_DIR/<year>/staging/.
# @description It never clicks archive, send, a form, refund or account number
# @description (cnf/vero-ui.json forbidden_clicks) and aborts every PUT, PATCH
# @description and DELETE. The browser runs with its cwd in the staging run,
# @description so no tool artefact lands in a git tree. Next: do_vero_file.
# @description DRY_RUN=1 (default) prints the plan and opens nothing.
# @param VERO_BASE_URL (required) - the OmaVero start URL
# @param VERO_YEAR (optional) - the year to fetch, default the current year
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_BROWSER (optional) - firefox (default) or chromium
# @param VERO_LOGIN_TIMEOUT_S (optional) - seconds the owner has to log in, default 900
# @param VERO_NODE_BIN (optional) - default node
# @param DRY_RUN (optional) - 1 (default) prints the plan; 0 opens the browser
# @example VERO_BASE_URL=<omavero url> ./run -a do_vero_fetch
# @example VERO_BASE_URL=<omavero url> VERO_YEAR=2026 DRY_RUN=0 ./run -a do_vero_fetch
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_fetch() {
  : "${VERO_BASE_URL:?VERO_BASE_URL must be set (no default), the OmaVero start URL}"
  local year ydir run node_dir node="${VERO_NODE_BIN:-node}" rc=0 marker
  year=$(vero_year)
  [[ "$year" =~ ^20[0-9]{2}$ ]] || { do_log "FATAL VERO_YEAR must be a year, got '$year'"; return 2; }
  ydir=$(vero_year_dir "$year") || return 2
  run="$ydir/staging/$(date +%Y%m%dT%H%M%S)"
  node_dir=$(vero_node_dir)
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO PLAN do_vero_fetch year=$year browser=${VERO_BROWSER:-firefox} out=$run"
    do_log "INFO PLAN the owner logs in in the browser window; then inbox, archive, messages, payments csv, balance, tasks"
    do_log "INFO PLAN DRY_RUN=0 to open the browser"
    return 0
  fi
  vero_fetch_ready "$node" "$node_dir" || return $?
  mkdir -p "$run" && chmod 700 "$run"
  marker="$run/.started"
  : >"$marker"
  ( cd "$run" && VERO_OUT_DIR="$run" VERO_YEAR="$year" VERO_UI_CNF="$node_dir/../../cnf/vero-ui.json" \
      "$node" "$node_dir/vero-fetch.mjs" ) || rc=$?
  vero_fetch_cleanup "$marker"
  if ((rc != 0)); then
    do_log "ERROR do_vero_fetch: the fetch exited $rc (3 = some steps failed, 2 = it did not start); files so far: $run"
    return "$rc"
  fi
  do_log "INFO OK do_vero_fetch: $(($(wc -l <"$run/manifest.tsv") - 1)) file(s) in $run; next: ./run -a do_vero_file"
}

# vero_fetch_ready <node> <node dir>: a desktop to show the browser on, node
# and the module's playwright; names the fix for each one missing.
vero_fetch_ready() {
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    do_log "FATAL no DISPLAY or WAYLAND_DISPLAY: run it in the owner's desktop session, the browser is headed"
    return 2
  fi
  command -v "$1" >/dev/null || { do_log "FATAL $1 not found"; return 2; }
  if [[ "$1" == node && ! -d "$2/../../node_modules/playwright" ]]; then
    do_log "FATAL playwright missing: cd $(cd "$2/../.." && pwd) && npm ci && npx playwright install ${VERO_BROWSER:-firefox}"
    return 2
  fi
}

# vero_fetch_cleanup <marker>: the browser's temp artefacts of this run (its
# owner only, newer than the run's start) never outlive it.
vero_fetch_cleanup() {
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'playwright-artifacts-*' -user "$(id -un)" -newer "$1" \
    -exec rm -rf {} + 2>/dev/null || true
  rm -f "$1"
}
