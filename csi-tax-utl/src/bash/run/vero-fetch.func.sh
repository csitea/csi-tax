#!/bin/bash
#------------------------------------------------------------------------------
# @description Fetch a year of OmaVero, read-only, in the ONE kept-open
# @description browser window (owner's choice 2026-11-24): the first run starts
# @description the session (src/node/vero-session.mjs) with a persistent
# @description profile; the owner logs in himself in that window; later runs
# @description reuse the window and the login while OmaVero keeps it. No run
# @description closes the window; do_vero_session_stop does. The profile dir
# @description (VERO_PROFILE_DIR, 0700, outside git) holds the session cookies.
# @description It saves the decisions and letters (inbox and archive, every
# @description PDF), the messages, the payments csv, the balance pages and the
# @description tasks page into a new staging run under VERO_DATA_DIR/<year>/,
# @description never clicks archive, send, a form, refund or account number
# @description (cnf/vero-ui.json forbidden_clicks) and aborts every PUT, PATCH
# @description and DELETE. Next: do_vero_file.
# @description DRY_RUN=1 (default) prints the plan and opens nothing.
# @param VERO_BASE_URL (required) - the OmaVero start URL
# @param VERO_YEAR (optional) - the year to fetch, default the current year
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_SESSION_DIR (optional) - the session's control dir, default <VERO_DATA_DIR>/session
# @param VERO_PROFILE_DIR (optional) - the browser profile, default <VERO_DATA_DIR>/browser-profile
# @param VERO_BROWSER (optional) - firefox (default) or chromium
# @param VERO_LOGIN_TIMEOUT_S (optional) - seconds the owner has to log in, default 900
# @param VERO_FETCH_TIMEOUT_S (optional) - seconds to wait for the run, default 3600
# @param VERO_NODE_BIN (optional) - default node
# @param DRY_RUN (optional) - 1 (default) prints the plan; 0 runs it
# @example VERO_BASE_URL=<omavero url> ./run -a do_vero_fetch
# @example VERO_BASE_URL=<omavero url> VERO_YEAR=2026 DRY_RUN=0 ./run -a do_vero_fetch
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_fetch() {
  : "${VERO_BASE_URL:?VERO_BASE_URL must be set (no default), the OmaVero start URL}"
  local year ydir run node_dir node="${VERO_NODE_BIN:-node}" sdir id rc
  year=$(vero_year)
  [[ "$year" =~ ^20[0-9]{2}$ ]] || { do_log "FATAL VERO_YEAR must be a year, got '$year'"; return 2; }
  ydir=$(vero_year_dir "$year") || return 2
  run="$ydir/staging/$(date +%Y%m%dT%H%M%S)"
  sdir=$(vero_session_dir)
  node_dir=$(vero_node_dir)
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO PLAN do_vero_fetch year=$year browser=${VERO_BROWSER:-firefox} out=$run"
    do_log "INFO PLAN session $(vero_session_pid "$sdir" >/dev/null && echo 'running: reuse its window' || echo 'none: start one, the owner logs in')"
    do_log "INFO PLAN DRY_RUN=0 to run it"
    return 0
  fi
  vero_fetch_ready "$node" "$node_dir" || return $?
  mkdir -p "$run" && chmod 700 "$run"
  vero_session_start "$node" "$node_dir" "$sdir" || return $?
  id="$(date +%Y%m%dT%H%M%S)-$$"
  printf '{"out":"%s","year":%s,"login_timeout_s":%s}\n' "$run" "$year" "${VERO_LOGIN_TIMEOUT_S:-900}" >"$sdir/requests/$id.json.tmp"
  mv "$sdir/requests/$id.json.tmp" "$sdir/requests/$id.json"
  rc=$(vero_session_wait "$sdir" "$id") || return $?
  if ((rc != 0)); then
    do_log "ERROR do_vero_fetch: the fetch exited $rc (3 = some steps failed, 2 = it did not start); files so far: $run"
    return "$rc"
  fi
  do_log "INFO OK do_vero_fetch: $(($(wc -l <"$run/manifest.tsv") - 1)) file(s) in $run; the window stays open; next: ./run -a do_vero_file"
}

# vero_session_start <node> <node dir> <session dir>: reuse the running
# session, else start one detached (it outlives this run) and wait for it.
vero_session_start() {
  local i
  vero_session_pid "$3" >/dev/null && { do_log "INFO reusing the open browser session"; return 0; }
  mkdir -p "$3/requests" "$3/results" && chmod 700 "$3" "$3/requests" "$3/results"
  rm -f "$3/session.pid"
  ( cd "$3" && VERO_SESSION_DIR="$3" VERO_PROFILE_DIR="$(vero_profile_dir)" VERO_UI_CNF="$2/../../cnf/vero-ui.json" \
      setsid nohup "$1" "$2/vero-session.mjs" >>"$3/session.log" 2>&1 </dev/null & )
  for ((i = 0; i < 240; i++)); do
    vero_session_pid "$3" >/dev/null && { do_log "INFO started the browser session; the owner logs in in its window"; return 0; }
    sleep 0.5
  done
  do_log "FATAL the browser session did not start in 120 s: $3/session.log"
  return 2
}

# vero_session_wait <session dir> <id>: print the run's lines as they come,
# then its exit code on stdout's last line; 2 when the session died first.
vero_session_wait() {
  local log="$1/results/$2.log" res="$1/results/$2.json" off=0 n end=$((SECONDS + ${VERO_FETCH_TIMEOUT_S:-3600}))
  while [[ ! -f "$res" ]]; do
    if [[ -f "$log" ]]; then n=$(wc -c <"$log"); ((n > off)) && { tail -c +$((off + 1)) "$log" | head -c $((n - off)) >&2; off=$n; }; fi
    vero_session_pid "$1" >/dev/null || { do_log "ERROR the browser session ended before the run finished" >&2; echo 2; return 0; }
    ((SECONDS < end)) || { do_log "ERROR no result in ${VERO_FETCH_TIMEOUT_S:-3600} s" >&2; echo 2; return 0; }
    sleep 1
  done
  [[ -f "$log" ]] && tail -c +$((off + 1)) "$log" >&2
  jq -r .rc "$res"
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
