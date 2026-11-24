#!/bin/bash
#------------------------------------------------------------------------------
# @description File the newest do_vero_fetch run: name each file by arrival
# @description date, per-day number and type
# @description (<yyyy-mm-dd>_<NN>_<Type>[_kausi-<dd.mm.yyyy>].pdf), copy it to
# @description VERO_DATA_DIR/<year>/filed/<yyyy-mm>/, add it to the year's
# @description index.tsv and keep a dated copy of the index for the weekly diff.
# @description A file whose sha256 the index holds is skipped, so a rerun adds
# @description nothing; a row joins the index only once its uploads succeeded,
# @description so a failed upload is retried on the next run. With DRY_RUN=0 it also uploads, add-only, each new file
# @description to gs://<VERO_BUCKET>/vero/<yyyy>/<yyyy-mm>/ (as the service
# @description account of VERO_GCP_KEY_FILE, a throwaway CLOUDSDK_CONFIG,
# @description --account on every call) and to the owner's Drive
# @description <VERO_DRIVE_FOLDER_ID>/<yyyy>/<yyyy-mm>/vero/<category>/ (rclone,
# @description the service account of VERO_DRIVE_SA_KEY_FILE), then the index.
# @description DRY_RUN=1 (default) files locally and prints the uploads.
# @param VERO_YEAR (optional) - default the current year
# @param VERO_DATA_DIR (optional) - default $HOME/var/csi-tax/vero
# @param VERO_STAGING_RUN (optional) - a staging run dir, default the newest
# @param VERO_BUCKET (optional) - the bucket name alone (no scheme); needed with DRY_RUN=0
# @param VERO_GCP_KEY_FILE (optional) - the bucket writer's SA key; needed with DRY_RUN=0
# @param VERO_DRIVE_FOLDER_ID (optional) - the owner's Drive top folder id; needed with DRY_RUN=0
# @param VERO_DRIVE_SA_KEY_FILE (optional) - the Drive writer's SA key; needed with DRY_RUN=0
# @param VERO_TODAY (optional) - yyyy-mm-dd of the index copy, default today
# @param DRY_RUN (optional) - 1 (default) files locally; 0 also uploads
# @example ./run -a do_vero_file
# @example VERO_BUCKET=<bucket> VERO_GCP_KEY_FILE=<key> VERO_DRIVE_FOLDER_ID=<id> VERO_DRIVE_SA_KEY_FILE=<key> DRY_RUN=0 ./run -a do_vero_file
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_vero_file() {
  local year ydir run plan n=0 src row name month cat f=()
  year=$(vero_year)
  ydir=$(vero_year_dir "$year") || return 2
  run="${VERO_STAGING_RUN:-$(vero_latest_run "$ydir")}"
  [[ -f "$run/manifest.tsv" ]] || { do_log "FATAL no manifest.tsv in '${run:-$ydir/staging/<none>}': run do_vero_fetch first"; return 2; }
  [[ "${DRY_RUN:-1}" == 0 ]] && { vero_file_need_upload_env || return $?; }
  plan=$(node "$(vero_node_dir)/vero-name.mjs" "$run/manifest.tsv" "$ydir/index.tsv") || return 2
  vero_file_index_head "$ydir/index.tsv"
  # Fields split on \x1f, not a tab: tab is IFS whitespace, so read would
  # fold the empty period and due date columns into one.
  while IFS=$'\x1f' read -r -a f; do
    ((${#f[@]} >= 10)) || continue
    src="${f[0]}" name="${f[9]}" month="${f[1]:0:7}" cat="${f[7]}"
    row=$(IFS=$'\t'; echo "${f[*]:1}")
    mkdir -p "$ydir/filed/$month" && chmod 700 "$ydir/filed" "$ydir/filed/$month"
    install -m 600 "$run/$src" "$ydir/filed/$month/$name" || return 2
    vero_file_upload "$ydir/filed/$month/$name" "$year" "$month" "$cat" || return $?
    printf '%s\n' "$row" >>"$ydir/index.tsv"
    n=$((n + 1))
  done < <(printf '%s\n' "$plan" | tr '\t' '\037')
  mkdir -p "$ydir/history" && install -m 600 "$ydir/index.tsv" "$ydir/history/index.$(vero_today).tsv"
  vero_file_upload_index "$ydir/index.tsv" "$year" || return $?
  do_log "INFO OK do_vero_file: $n new file(s) filed, index $ydir/index.tsv ($(($(wc -l <"$ydir/index.tsv") - 1)) rows)"
}

# vero_file_index_head <index>: a new index starts with its header.
vero_file_index_head() {
  [[ -s "$1" ]] && return 0
  printf 'arrival_date\tkind\ttype\ttax_type\tperiod\tdue_date\tcategory\tsha256\tfile_name\n' >"$1"
  chmod 600 "$1"
}

# vero_file_need_upload_env: every upload target, or a fail-fast naming it.
vero_file_need_upload_env() {
  : "${VERO_BUCKET:?VERO_BUCKET must be set with DRY_RUN=0 (no default): the private bucket name}" \
    "${VERO_GCP_KEY_FILE:?VERO_GCP_KEY_FILE must be set with DRY_RUN=0 (no default): the bucket writer SA key}" \
    "${VERO_DRIVE_FOLDER_ID:?VERO_DRIVE_FOLDER_ID must be set with DRY_RUN=0 (no default): the owner Drive top folder}" \
    "${VERO_DRIVE_SA_KEY_FILE:?VERO_DRIVE_SA_KEY_FILE must be set with DRY_RUN=0 (no default): the Drive writer SA key}"
  [[ -r "$VERO_GCP_KEY_FILE" && -r "$VERO_DRIVE_SA_KEY_FILE" ]] || { do_log "FATAL a VERO_*_KEY_FILE is not readable"; return 2; }
}

# vero_file_gcloud <args...>: gcloud as the key's service account, in a
# throwaway CLOUDSDK_CONFIG; the shared gcloud config is never touched.
vero_file_gcloud() {
  local cfg sa rc=0
  sa=$(jq -r .client_email "$VERO_GCP_KEY_FILE") || return 2
  cfg=$(mktemp -d)
  CLOUDSDK_CONFIG="$cfg" gcloud auth activate-service-account "$sa" --key-file="$VERO_GCP_KEY_FILE" --quiet >/dev/null 2>&1 &&
    CLOUDSDK_CONFIG="$cfg" gcloud "$@" --account="$sa" || rc=$?
  rm -rf "$cfg"
  return "$rc"
}

# vero_file_upload <file> <year> <yyyy-mm> <category>: add-only to the bucket
# and the Drive; DRY_RUN=1 prints both.
vero_file_upload() {
  local gs="gs://${VERO_BUCKET:-<VERO_BUCKET>}/vero/$2/$3/${1##*/}"
  local dr=":drive:$2/$3/vero/$4/${1##*/}"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO PLAN upload ${1##*/} -> $gs and Drive $2/$3/vero/$4/"
    return 0
  fi
  vero_file_gcloud storage cp --no-clobber "$1" "$gs" || { do_log "ERROR bucket upload failed: ${1##*/}"; return 3; }
  rclone copyto --ignore-existing --drive-scope=drive --drive-service-account-file="$VERO_DRIVE_SA_KEY_FILE" \
    --drive-root-folder-id="$VERO_DRIVE_FOLDER_ID" "$1" "$dr" || { do_log "ERROR Drive upload failed: ${1##*/}"; return 3; }
}

# vero_file_upload_index <index> <year>: the index replaces the bucket's
# copy (it only grows; the dated copies stay local).
vero_file_upload_index() {
  [[ "${DRY_RUN:-1}" != 0 ]] && { do_log "INFO PLAN upload index -> gs://${VERO_BUCKET:-<VERO_BUCKET>}/vero/$2/index.tsv"; return 0; }
  vero_file_gcloud storage cp "$1" "gs://$VERO_BUCKET/vero/$2/index.tsv" || { do_log "ERROR index upload failed"; return 3; }
}
