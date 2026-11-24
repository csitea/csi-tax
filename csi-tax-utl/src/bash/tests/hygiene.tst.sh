#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for the repo hygiene: no tax data, secret or box identity in git.
#   1. No PDF, CSV, index or manifest file is tracked
#   2. No home path, gcloud key path or service-account key file is tracked
#   3. No real bucket name: every gs:// in code is a placeholder or a variable
#   4. Every do_vero_* action has its own test file
#   5. .gitignore covers the staging, filed, reports and browser artefact dirs
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"
R=$(cd "$MOD_ROOT/.." && pwd)
files() { git -C "$R" ls-files --cached --others --exclude-standard; }

bad=$(files | grep -E '\.(pdf|csv)$|(^|/)(index|manifest)\.tsv$')
if [[ -z "$bad" ]]; then pass "1. no tax data file tracked"; else fail "1. $bad"; fi

home_rx='/'home'/[a-z]|\.gcp/\.|key-[a-z]+-[a-z]+-(dev|prd)\.json'
bad=$(cd "$R" && files | grep -v '^csi-tax-utl/src/bash/tests/' | xargs -r grep -lE "$home_rx" 2>/dev/null)
if [[ -z "$bad" ]]; then pass "2. no home or key path"; else fail "2. $bad"; fi

bad=$(cd "$R" && files | grep -v '^csi-tax-utl/src/bash/tests/' | xargs -r grep -hoE 'gs://[^ "$<]+' 2>/dev/null | grep -v '^gs://$' | sort -u)
if [[ -z "$bad" ]]; then pass "3. no literal bucket"; else fail "3. $bad"; fi

miss=""
for f in "$MOD_ROOT"/src/bash/run/vero-*.func.sh; do
  b=$(basename "$f" .func.sh)
  n="${b%-diff}" && n="${n%-report}"
  [[ "$b" == vero-weekly-due || "$b" == vero-cron-install ]] && n=vero-schedule
  [[ "$b" == vero-session-stop ]] && n=vero-fetch
  t=("$MOD_ROOT/src/bash/tests/$n.tst.sh")
  [[ -f "${t[0]}" ]] || miss+=" $b"
done
if [[ -z "$miss" ]]; then pass "4. every vero action has a test"; else fail "4. missing:$miss"; fi

ok=1; for p in staging/ filed/ reports/ .playwright-mcp/ '*.pdf' node_modules/; do grep -qxF "$p" "$R/.gitignore" || ok=0; done
if [[ $ok -eq 1 ]]; then pass "5. .gitignore covers the data dirs"; else fail "5."; fi
finish
