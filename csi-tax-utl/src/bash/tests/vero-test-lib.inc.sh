#!/usr/bin/env bash
# Shared fixture of the vero tests: a temp HOME-free data dir, a staging run
# with fake PDFs (no real document, no amount), and stub gcloud / rclone that
# log their argv. Sourced by the *.tst.sh files; defines no test.
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
finish() {
  echo "=========================================="
  echo "$(basename "$0"): $fails failure(s)"
  echo "=========================================="
  exit $((fails > 0))
}

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MOD_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VERO_DATA_DIR="$T/data" VERO_YEAR=2026
export XDG_CACHE_HOME="$T/cache"
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH" STUB_LOG="$T/stub.log"
for s in gcloud rclone; do
  printf '#!/bin/bash\necho "%s $*" >>"$STUB_LOG"\nexit ${STUB_RC_%s:-0}\n' "$s" "$s" >"$T/bin/$s"
  chmod +x "$T/bin/$s"
done

# vero_fixture_run <run name> <rows...>: a staging run whose manifest holds
# the rows ("date|kind|type|tax|period|due|category|body"), one file each.
vero_fixture_run() {
  local run="$VERO_DATA_DIR/2026/staging/$1" i=0 d k ty tx p du c body sum
  shift
  mkdir -p "$run/pdf"
  printf 'arrival_date\tkind\ttype\ttax_type\tperiod\tfile\tsha256\tdue_date\tcategory\n' >"$run/manifest.tsv"
  for r in "$@"; do
    IFS='|' read -r d k ty tx p du c body <<<"$r"
    i=$((i + 1))
    printf '%%PDF-1.4 fixture %s\n' "$body" >"$run/pdf/$i.pdf"
    sum=$(sha256sum "$run/pdf/$i.pdf" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\t%s\tpdf/%s.pdf\t%s\t%s\t%s\n' "$d" "$k" "$ty" "$tx" "$p" "$i" "$sum" "$du" "$c" >>"$run/manifest.tsv"
  done
  echo "$run"
}

# vero_run <env...> -- <action>: the module's ./run, output to $T/out, rc kept.
vero_run() {
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  (cd "$MOD_ROOT" && env "${envs[@]}" ./run -a "$1") >"$T/out" 2>&1
}
