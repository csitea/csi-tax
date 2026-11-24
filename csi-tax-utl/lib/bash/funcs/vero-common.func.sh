#!/bin/bash
#------------------------------------------------------------------------------
# @description Shared helpers of the do_vero_* actions: where the year's data
# @description lives (outside git, mode 0700) and which index is last week's.
# @description Layout under VERO_DATA_DIR (default $HOME/var/csi-tax/vero):
# @description   <year>/staging/<run>/   one do_vero_fetch run (manifest.tsv)
# @description   <year>/filed/<yyyy-mm>/ the renamed files
# @description   <year>/index.tsv        every filed file, one row each
# @description   <year>/history/index.<yyyy-mm-dd>.tsv  a copy per filing day
# @description   <year>/reports/         diffs, issue drafts, weekly reports
# @example vero_year_dir 2026
#------------------------------------------------------------------------------

# vero_year: VERO_YEAR, else the current year.
vero_year() {
  echo "${VERO_YEAR:-$(date +%Y)}"
}

# vero_today: VERO_TODAY (tests), else today, yyyy-mm-dd.
vero_today() {
  echo "${VERO_TODAY:-$(date +%F)}"
}

# vero_year_dir <year>: the year's data dir, created 0700.
vero_year_dir() {
  local d="${VERO_DATA_DIR:-$HOME/var/csi-tax/vero}/$1"
  mkdir -p "$d" && chmod 700 "${VERO_DATA_DIR:-$HOME/var/csi-tax/vero}" "$d"
  echo "$d"
}

# vero_node_dir: the module's src/node, next to this lib.
vero_node_dir() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src/node"
}

# vero_prev_index <year dir> <today>: the newest history copy older than
# <today>, "-" when there is none (first run).
vero_prev_index() {
  local f best="-" d
  for f in "$1"/history/index.*.tsv; do
    [[ -f "$f" ]] || continue
    d="${f##*/index.}" && d="${d%.tsv}"
    [[ "$d" < "$2" ]] && best="$f"
  done
  echo "$best"
}

# vero_latest_run <year dir>: the newest staging run dir, or nothing.
vero_latest_run() {
  local r
  r=$(find "$1/staging" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)
  echo "$r"
}
