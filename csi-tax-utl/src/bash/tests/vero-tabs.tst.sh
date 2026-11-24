#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for the tab choice of src/node/vero-steps.mjs (waitForLogin,
# livePage) in a headless Playwright Firefox on local pages: no network, no
# OmaVero. Run 11 (2026-11-24): the session's own tab was closed while the
# owner logged in; the window stayed open.
#   1. Own tab closed, another tab logged in: that tab is used at once
#   2. Own tab closed, no tab left: ONE new tab in the same context, and a
#      login that appears there later is picked up
#   3. Own tab open but logged out, the login lands in a second tab: picked up
#   4. Never a second context (window): one context throughout
# Needs the module's playwright and its firefox build; without them it
# prints SKIP, which the fast tier counts as a failure.
#------------------------------------------------------------------------------
# test-timeout: 180
set -uo pipefail
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright}"
source "$(dirname "$0")/vero-test-lib.inc.sh"

if [[ ! -d "$MOD_ROOT/node_modules/playwright" ]]; then
  echo "SKIP: no playwright in $MOD_ROOT/node_modules (npm ci)"; finish
fi

cat >"$T/run.mjs" <<JS
import { firefox } from '$MOD_ROOT/node_modules/playwright/index.mjs';
import { waitForLogin } from '$MOD_ROOT/src/node/vero-steps.mjs';
const ui = { logged_in_text: 'Omat verolajit' };
const IN = '<main><a role="tab">Omat verolajit</a></main>';
const b = await firefox.launch({ headless: true });
const ctx = await b.newContext();
const out = {};
const lines = [];
const log = (m) => lines.push(m);
// 1
let own = await ctx.newPage();
const other = await ctx.newPage(); await other.setContent(IN);
await own.close();
await waitForLogin(own, ui, 3, log).then(() => { out.t1 = lines.at(-1); }).catch((e) => { out.t1 = e.message; });
// 2
await other.close();
own = ctx.pages()[0] ?? null;
const dead = await ctx.newPage(); await dead.close();
setTimeout(async () => { const p = ctx.pages()[0]; if (p) await p.setContent(IN); }, 1500);
await waitForLogin(dead, ui, 10, log).then(() => { out.t2 = lines.at(-1); }).catch((e) => { out.t2 = e.message; });
out.t2pages = ctx.pages().length;
// 3
const first = ctx.pages()[0]; await first.setContent('<main>Tunnistaudu</main>');
const second = await ctx.newPage();
setTimeout(() => second.setContent(IN), 1500);
await waitForLogin(first, ui, 10, log).then(() => { out.t3 = lines.at(-1); }).catch((e) => { out.t3 = e.message; });
out.contexts = b.contexts().length;
console.log(JSON.stringify(out));
await b.close();
JS
res=$(node "$T/run.mjs" 2>&1)
if ! jq -e . >/dev/null 2>&1 <<<"$res"; then
  grep -qiE "Executable doesn.t exist|npx playwright install" <<<"$res" && { echo "SKIP: no firefox build (npx playwright install firefox)"; finish; }
  fail "fixture run: $res"; finish
fi
v() { jq -r ".$1" <<<"$res"; }
[[ "$(v t1)" == "logged in (session kept), in another tab of the window" ]] && pass "1. own tab closed: the logged-in tab is used" || fail "1. $(v t1)"
[[ "$(v t2)" == "logged in (in another tab of the window)" && "$(v t2pages)" == 1 ]] && pass "2. no tab left: one new tab, later login picked up" || fail "2. $(v t2) pages=$(v t2pages)"
[[ "$(v t3)" == "logged in (in another tab of the window)" ]] && pass "3. login in a second tab picked up" || fail "3. $(v t3)"
[[ "$(v contexts)" == 1 ]] && pass "4. one context (window) throughout" || fail "4. contexts=$(v contexts)"
finish
