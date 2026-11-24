#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for the navigation of src/node/vero-steps.mjs (stepBalance's
# 'next' loop, home()'s way back) in a headless Playwright Firefox on a local
# fake OmaVero (a hash-routed page served by ctx.route): no network.
#   1. The 'next' loop stops when a click changes nothing: 3 pages, 3 files
#   2. Each saved page is the view after the click, never the page before
#   3. home() from a sub view goes to stepFront's URL and lands on the front
#   4. Without that URL, home() goes back over the run's own clicks only
#   5. With no own click to go back over, home() FAILs and stays on host
#   6. A back step that would leave the host goes forward again and FAILs
# Needs the module's playwright and its firefox build; without them it
# prints SKIP, which the fast tier counts as a failure.
#------------------------------------------------------------------------------
# test-timeout: 240
set -uo pipefail
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright}"
source "$(dirname "$0")/vero-test-lib.inc.sh"

if [[ ! -d "$MOD_ROOT/node_modules/playwright" ]]; then
  echo "SKIP: no playwright in $MOD_ROOT/node_modules (npm ci)"; finish
fi

cat >"$T/site.html" <<'HTML'
<html><body>
<header><div role="tablist" id="tabs"><a role="tab" aria-selected="true" href="#front">Omat verolajit</a></div></header>
<main id="m"></main>
<script>
function render() {
  const h = location.hash || '#front';
  const tabs = document.getElementById('tabs'), m = document.getElementById('m');
  if (h === '#front') {
    tabs.style.display = '';
    m.innerHTML = '<p>Etusivu</p><a href="#balance/1">Saldoerittely</a>';
  } else {
    const n = Number(h.split('/')[1]);
    tabs.style.display = 'none';
    m.innerHTML = '<p>Saldo sivu ' + n + '</p><button id="nx">Siirry seuraavalle sivulle</button>';
    document.getElementById('nx').onclick = () => { if (n < 3) location.hash = '#balance/' + (n + 1); };
  }
}
window.onhashchange = render; render();
</script></body></html>
HTML

cat >"$T/run.mjs" <<JS
import { firefox } from '$MOD_ROOT/node_modules/playwright/index.mjs';
import { readFileSync, readdirSync } from 'node:fs';
import { _test as S } from '$MOD_ROOT/src/node/vero-steps.mjs';
const forbidden = JSON.parse(readFileSync('$MOD_ROOT/cnf/vero-ui.json', 'utf8')).forbidden_clicks;
const ui = { tabs: { front: 'Omat verolajit' }, links: { balance: 'Saldoerittely', next_page: 'Siirry seuraavalle sivulle' },
  selectors: { main: 'main' }, forbidden_clicks: forbidden, logged_in_text: 'Omat verolajit' };
const B = 'https://omavero.test/';
const b = await firefox.launch({ headless: true });
const ctx = await b.newContext();
await ctx.route('https://omavero.test/**', (r) => r.fulfill({ contentType: 'text/html', body: readFileSync('$T/site.html', 'utf8') }));
await ctx.route('https://login.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<main>Tunnistaudu</main>' }));
const page = await ctx.newPage();
const out = {};
const host = () => new URL(page.url()).host;
const tryHome = () => S.home(page).then(() => 'front', (e) => e.message);
// 1-3
S.init({ base: B, ui, out: '$T/o1' });
await page.goto(B + '#front');
await S.stepFront(null, page);
await S.stepBalance(null, page);
const files = readdirSync('$T/o1/pages').filter((f) => f.startsWith('balance-')).sort();
out.t1 = files.join(',');
out.t2 = files.map((f) => readFileSync('$T/o1/pages/' + f, 'utf8').trim().split('\n')[0]).join('|');
out.t3 = await tryHome(); out.t3hash = new URL(page.url()).hash;
// 4
S.init({ base: B, ui, out: '$T/o2' });
await page.goto(B + '#front');
await S.stepBalance(null, page);
out.t4depth = S.depth();
out.t4 = await tryHome(); out.t4hash = new URL(page.url()).hash;
// 5
S.init({ base: B, ui, out: '$T/o3' });
await page.goto('https://login.test/');
await page.goto(B + '#balance/1');
out.t5 = await tryHome(); out.t5host = host();
// 6
S.init({ base: B, ui, out: '$T/o4' });
await page.goto('https://login.test/');
await page.goto(B + '#balance/1');
S.setDepth(2);
out.t6 = await tryHome(); out.t6host = host();
console.log(JSON.stringify(out));
await b.close();
JS
res=$(node "$T/run.mjs" 2>&1)
if ! jq -e . >/dev/null 2>&1 <<<"$res"; then
  grep -qiE "Executable doesn.t exist|npx playwright install" <<<"$res" && { echo "SKIP: no firefox build (npx playwright install firefox)"; finish; }
  fail "fixture run: $res"; finish
fi
v() { jq -r ".$1" <<<"$res"; }
[[ "$(v t1)" == "balance-1.txt,balance-2.txt,balance-3.txt" ]] && pass "1. unchanged 'next' click stops the loop (3 pages)" || fail "1. $(v t1)"
[[ "$(v t2)" == "Saldo sivu 1|Saldo sivu 2|Saldo sivu 3" ]] && pass "2. each saved page is the view after its click" || fail "2. $(v t2)"
[[ "$(v t3)" == front && "$(v t3hash)" == "#front" ]] && pass "3. home via stepFront's URL lands on the front" || fail "3. $(v t3) $(v t3hash)"
[[ "$(v t4)" == front && "$(v t4hash)" == "#front" && "$(v t4depth)" == 3 ]] && pass "4. home goes back over the run's own 3 clicks" || fail "4. $(v t4) $(v t4hash) depth=$(v t4depth)"
[[ "$(v t5)" == *"no own click left"* && "$(v t5host)" == omavero.test ]] && pass "5. no own click: FAIL, still on host" || fail "5. $(v t5) $(v t5host)"
[[ "$(v t6)" == *"would leave OmaVero"* && "$(v t6host)" == omavero.test ]] && pass "6. a back step off host goes forward and FAILs" || fail "6. $(v t6) $(v t6host)"
finish
