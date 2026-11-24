#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
# Copied from csi-spl (origin/master 6d81d4447, csi-spl-iac), renamed.
#
# Each test runs under a PER-TEST TIMEOUT (TAX_TEST_TIMEOUT, default 120 s): a
# test that hangs is KILLED and counted as a FAILURE with its name, never a hang.
#
# TAX_TEST_TIER=fast leaves out every test whose header carries the line
# '# pre-push-tier: slow' and names each one. In the fast tier a test that
# prints 'SKIP:' FAILS: a missing tool is a loud failure, never a green.
#
# The files run TAX_TEST_JOBS at a time (default 4; 1 = one at a time). A test
# whose first 40 lines carry '# serial' runs alone, after the pool; one with
# '# test-timeout: <s>' gets max(<s>, TAX_TEST_TIMEOUT).
#
# TAX_TEST_ONLY="<a.tst.sh> <b.tst.sh>" runs only the files named (basenames).
set -uo pipefail
# A git hook (pre-push) exports GIT_DIR (+ GIT_PREFIX): inherited, it turns a
# test fixture's `git -C "$T/app" init/remote` into a write on the CALLER's
# repo (2026-10-06: a shared .git/config got core.bare=true and a fixture origin).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
dir=$(cd "$(dirname "$0")" && pwd)
to="${TAX_TEST_TIMEOUT:-120}"
tier="${TAX_TEST_TIER:-full}"
case "$tier" in full|fast) ;; *) echo "TAX_TEST_TIER must be full or fast (got '$tier')" >&2; exit 2 ;; esac
njobs="${TAX_TEST_JOBS:-}"
if [[ -z "$njobs" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then njobs=6; else njobs=4; fi
fi
[[ "$njobs" =~ ^[1-9][0-9]*$ ]] || { echo "TAX_TEST_JOBS must be a positive integer (got '$njobs')" >&2; exit 2; }
fails=0 n=0 slow=0 bad=()
work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
pool=() serial=()
# file_to <file>: that file's timeout in seconds.
file_to() {
  local own
  own=$(sed -nE '1,40{/^# test-timeout: [1-9][0-9]*( |$)/{s/^# test-timeout: ([0-9]+).*/\1/p;q}}' "$1")
  if [[ -n "$own" ]] && (( own > to )); then echo "$own"; else echo "$to"; fi
}
only=" ${TAX_TEST_ONLY:-} "
for o in ${TAX_TEST_ONLY:-}; do
  [[ -f "$dir/$o" ]] || { echo "TAX_TEST_ONLY names no test file: $o" >&2; exit 2; }
done
for t in "$dir"/*.tst.sh; do
  [[ -f "$t" ]] || continue
  [[ -n "${TAX_TEST_ONLY:-}" && "$only" != *" $(basename "$t") "* ]] && continue
  if [[ "$tier" == fast ]] && head -40 "$t" | grep -E '^# pre-push-tier: slow( |$)' >/dev/null; then
    echo "SKIP-TIER (fast tier): $(basename "$t")"; slow=$((slow + 1))
    continue
  fi
  if head -40 "$t" | grep -E '^# serial( |$)' >/dev/null; then serial+=("$t"); else pool+=("$t"); fi
done
files=("${pool[@]}" "${serial[@]}")
n=${#files[@]}
# start <i>: run file i in the background under the timeout; <i>.rc appears
# only once the file is done, so an existing <i>.rc means <i>.out is complete.
start() {
  ( rc=0 t0=$SECONDS; timeout -k 5 "$(file_to "${files[$1]}")" bash "${files[$1]}" </dev/null >"$work/$1.out" 2>&1 || rc=$?
    echo "$((SECONDS - t0))" >"$work/$1.secs"
    echo "$rc" >"$work/$1.rc.tmp"; mv "$work/$1.rc.tmp" "$work/$1.rc" ) &
}
next=0
flush() {
  local name rc out
  while (( next < n )) && [[ -f "$work/$next.rc" ]]; do
    name=$(basename "${files[$next]}") rc=$(cat "$work/$next.rc") out="$work/$next.out"
    echo "=== $name"
    cat "$out"
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      echo "TIMED OUT (>$(file_to "${files[$next]}")s), killed: $name"; fails=$((fails + 1))
      bad+=("$name (timed out >$(file_to "${files[$next]}")s)")
    elif [[ "$rc" -ne 0 ]]; then
      echo "FAILED: $name"; fails=$((fails + 1)); bad+=("$name")
    elif [[ "$tier" == fast ]] && grep -q '^SKIP:' "$out"; then
      echo "FAILED: $name SKIPPED a check in the fast tier ($(grep -m1 '^SKIP:' "$out")) -- install what it names"
      fails=$((fails + 1)); bad+=("$name (skipped a check)")
    fi
    echo "--- $name took $(cat "$work/$next.secs")s"
    next=$((next + 1))
  done
}
running=0
for ((i = 0; i < ${#pool[@]}; i++)); do
  if (( running >= njobs )); then wait -n; running=$((running - 1)); flush; fi
  start "$i"; running=$((running + 1))
done
wait; flush
for ((i = ${#pool[@]}; i < n; i++)); do start "$i"; wait; flush; done
# The summary names what did not pass.
summary="=== $((n - fails))/$n test files passed (tier=$tier, $slow slow left out)"
if (( ${#bad[@]} )); then summary+="; not passing: $(printf '%s, ' "${bad[@]}")"; summary="${summary%, }"; fi
echo "$summary"
[[ "$fails" -eq 0 ]]
