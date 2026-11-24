#!/bin/bash
#------------------------------------------------------------------------------
# @description Close the kept-open OmaVero browser window: send the session a
# @description stop request and wait for it to end. No fetch run closes the
# @description window; this action, or the owner closing it, does. The
# @description profile (and its session cookies) stays on disk.
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_SESSION_DIR (optional) - default <VERO_DATA_DIR>/session
# @param DRY_RUN (optional) - 1 (default) says what it would stop; 0 stops it
# @example ./run -a do_vero_session_stop
# @example DRY_RUN=0 ./run -a do_vero_session_stop
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_session_stop() {
  local sdir pid i
  sdir=$(vero_session_dir)
  pid=$(vero_session_pid "$sdir") || { do_log "INFO no browser session runs"; return 0; }
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO PLAN stop the browser session pid $pid; DRY_RUN=0 to do it"
    return 0
  fi
  printf '{"stop":true}\n' >"$sdir/requests/zzzz-stop-$$.json"
  for ((i = 0; i < 60; i++)); do
    kill -0 "$pid" 2>/dev/null || { do_log "INFO OK do_vero_session_stop: the window is closed"; return 0; }
    sleep 0.5
  done
  do_log "ERROR the session pid $pid did not stop in 30 s"
  return 3
}
