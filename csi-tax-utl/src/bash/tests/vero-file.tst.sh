#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_vero_file, on a fixture staging run (fake PDFs) with stub
# gcloud and rclone; no bucket or Drive is reached.
#   1. No staging run -> refused, exit 2
#   2. DRY_RUN default files locally under filed/<yyyy-mm>/ with the names
#      <date>_<NN>_<Type>[_kausi-..].pdf, mode 600, and uploads nothing
#   3. The index has a header and one row per file; a dated copy is kept
#   4. A rerun adds nothing (same sha256)
#   5. DRY_RUN=0 without the upload env fails fast, naming the var
#   6. DRY_RUN=0 uploads each new file add-only to gs://<bucket>/vero/<y>/<y-m>/
#      with --account, and to Drive <y>/<y-m>/vero/<category>/ with the folder id
#   7. A failed Drive upload keeps the row out of the index (retried next run)
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"

vero_run -- do_vero_file; rc=$?
if [[ $rc -eq 2 ]] && grep -q 'run do_vero_fetch first' "$T/out"; then pass "1. no staging run -> exit 2"; else fail "1. rc=$rc"; fi

vero_fixture_run 20260301T100000 \
  "2026-03-04|document|Verotuspäätös (pdf)|Tulovero|31.12.2025||decisions|a" \
  "2026-03-04|document|Kirje (pdf)|Arvonlisävero|||decisions|b" \
  "2026-02-10|document|Tiliote (pdf)|||2026-03-12|statements|c" >/dev/null
Y="$VERO_DATA_DIR/2026"
vero_run VERO_TODAY=2026-03-05 -- do_vero_file; rc=$?
want="$Y/filed/2026-03/2026-03-04_01_Verotuspaatos_kausi-31.12.2025.pdf $Y/filed/2026-03/2026-03-04_02_Kirje.pdf $Y/filed/2026-02/2026-02-10_01_Tiliote.pdf"
ok=1; for f in $want; do [[ -f "$f" && "$(stat -c %a "$f")" == 600 ]] || ok=0; done
if [[ $rc -eq 0 && $ok -eq 1 && ! -s "$STUB_LOG" ]] && grep -q 'PLAN upload' "$T/out"; then pass "2. filed locally, named, 600, no upload"; else fail "2. rc=$rc ok=$ok $(ls -R "$Y/filed" 2>&1 | tr '\n' ' ')"; fi

if [[ "$(head -1 "$Y/index.tsv" | cut -f1)" == arrival_date && $(wc -l <"$Y/index.tsv") -eq 4 && -f "$Y/history/index.2026-03-05.tsv" ]]; then
  pass "3. index + dated copy"; else fail "3. $(wc -l <"$Y/index.tsv" 2>&1)"; fi

vero_run VERO_TODAY=2026-03-05 -- do_vero_file; rc=$?
if [[ $rc -eq 0 && $(wc -l <"$Y/index.tsv") -eq 4 ]] && grep -q '0 new file' "$T/out"; then pass "4. rerun adds nothing"; else fail "4. rc=$rc"; fi

vero_run DRY_RUN=0 -- do_vero_file; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'VERO_BUCKET must be set' "$T/out"; then pass "5. upload env fails fast"; else fail "5. rc=$rc $(tail -2 "$T/out")"; fi

echo '{"client_email":"writer@example.iam.gserviceaccount.com"}' >"$T/key.json"
UP=(DRY_RUN=0 VERO_BUCKET=test-bucket VERO_GCP_KEY_FILE="$T/key.json" VERO_DRIVE_FOLDER_ID=FOLDER123 VERO_DRIVE_SA_KEY_FILE="$T/key.json" VERO_TODAY=2026-03-12)
vero_fixture_run 20260311T100000 "2026-03-11|message|Viesti||||msgs|d" >/dev/null
vero_run "${UP[@]}" -- do_vero_file; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'gcloud storage cp --no-clobber .*2026-03-11_01_Viesti.pdf gs://test-bucket/vero/2026/2026-03/2026-03-11_01_Viesti.pdf --account=writer@example.iam.gserviceaccount.com' "$STUB_LOG" \
  && grep -q 'rclone copyto --ignore-existing .*--drive-root-folder-id=FOLDER123 .*:drive:2026/2026-03/vero/msgs/2026-03-11_01_Viesti.pdf' "$STUB_LOG" \
  && grep -q 'gs://test-bucket/vero/2026/index.tsv' "$STUB_LOG"; then
  pass "6. bucket + Drive add-only, --account, folder id"; else fail "6. rc=$rc $(cat "$STUB_LOG")"; fi

vero_fixture_run 20260318T100000 "2026-03-18|document|Päätös (pdf)||||decisions|e" >/dev/null
vero_run "${UP[@]}" STUB_RC_rclone=1 -- do_vero_file; rc=$?
if [[ $rc -eq 3 ]] && ! grep -q '2026-03-18' "$Y/index.tsv"; then pass "7. failed Drive upload stays out of the index"; else fail "7. rc=$rc"; fi
finish
