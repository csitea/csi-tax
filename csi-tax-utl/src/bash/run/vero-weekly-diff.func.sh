#!/bin/bash
#------------------------------------------------------------------------------
# @description Compare the year's OmaVero index with last week's copy (the
# @description newest history/index.<date>.tsv older than today, written by
# @description do_vero_file) and list only what is new or changed. Writes the
# @description diff to <year>/reports/diff-<today>.md and one issue draft per
# @description new theme (category) to <year>/reports/issues/<today>-<theme>.md;
# @description it files no issue itself. No amounts: it reads the index only.
# @param VERO_YEAR (optional) - default the current year
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_PREV_INDEX (optional) - the index to compare with, default last week's copy
# @param VERO_TODAY (optional) - yyyy-mm-dd, default today
# @example ./run -a do_vero_weekly_diff
# @example VERO_PREV_INDEX=<old index.tsv> ./run -a do_vero_weekly_diff
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_weekly_diff() {
  local ydir today prev out
  ydir=$(vero_year_dir "$(vero_year)") || return 2
  today=$(vero_today)
  [[ -f "$ydir/index.tsv" ]] || { do_log "FATAL no $ydir/index.tsv: run do_vero_file first"; return 2; }
  prev="${VERO_PREV_INDEX:-$(vero_prev_index "$ydir" "$today")}"
  mkdir -p "$ydir/reports" && chmod 700 "$ydir/reports"
  out="$ydir/reports/diff-$today.md"
  node "$(vero_node_dir)/vero-weekly.mjs" diff "$ydir/index.tsv" "$prev" "$today" "$ydir/reports/issues" >"$out" || return 2
  chmod 600 "$out"
  cat "$out"
  do_log "INFO OK do_vero_weekly_diff: $out (against ${prev##*/}); issue drafts in $ydir/reports/issues/"
}
