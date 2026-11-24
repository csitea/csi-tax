#!/bin/bash
#------------------------------------------------------------------------------
# @description The weekly Vero report for the csitea reports discussion, in
# @description markdown: 1. what is new this week, 2. what changed, 3. what to
# @description take into consideration (due dates in the next
# @description VERO_DUE_WINDOW_DAYS, decisions received, payments and balance
# @description tables that changed, open questions). Built from the year's
# @description index and last week's copy, never from a PDF; labels are
# @description scrubbed of amounts. Writes <year>/reports/weekly-<today>.md and
# @description prints it; posting it is the dispatch holder's, on the
# @description owner's go.
# @param VERO_YEAR (optional) - default the current year
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_PREV_INDEX (optional) - the index to compare with, default last week's copy
# @param VERO_DUE_WINDOW_DAYS (optional) - default 30
# @param VERO_TODAY (optional) - yyyy-mm-dd, default today
# @example ./run -a do_vero_weekly_report
# @example VERO_DUE_WINDOW_DAYS=60 ./run -a do_vero_weekly_report
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_weekly_report() {
  local ydir today prev out
  ydir=$(vero_year_dir "$(vero_year)") || return 2
  today=$(vero_today)
  [[ -f "$ydir/index.tsv" ]] || { do_log "FATAL no $ydir/index.tsv: run do_vero_file first"; return 2; }
  prev="${VERO_PREV_INDEX:-$(vero_prev_index "$ydir" "$today")}"
  mkdir -p "$ydir/reports" && chmod 700 "$ydir/reports"
  out="$ydir/reports/weekly-$today.md"
  node "$(vero_node_dir)/vero-weekly.mjs" report "$ydir/index.tsv" "$prev" "$today" "${VERO_DUE_WINDOW_DAYS:-30}" >"$out" || return 2
  chmod 600 "$out"
  cat "$out"
  do_log "INFO OK do_vero_weekly_report: $out"
}
