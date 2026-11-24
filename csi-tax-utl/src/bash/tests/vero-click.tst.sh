#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for src/node/vero-click.mjs on a local HTML fixture, in a
# headless Playwright Firefox: no network, no OmaVero. The fixture copies
# the shapes the live run of 2026-11-24 could not click.
#   1. An <a> without href (no link role) is found by its exact visible text
#   2. A link whose name carries a chevron is found by the plain label
#   3. A real button is found by its exact role name
#   4. A forbidden label is refused before any lookup, and nothing is clicked
#   5. A label outside main/nav/header is not clicked (times out)
#   7. A hidden duplicate is skipped: the visible one is clicked
#   8. A tab whose name carries a counter ("Viestit 3") is found by its label
#   9. An already selected tab is not clicked again with skipSelected
#  11. A text match inside a clickable cell clicks the cell (run 8)
#  12. A clickable ancestor holding a forbidden line is refused, not clicked
#  13. A control that never holds still (an endless animation) is clicked
#      by a DOM click event after clickMs, through a transparent layer
#  14. clickEl with the forbidden list refuses before any click
#  10. A click waits until the busy layer (.FastBusyOverlay) is hidden
#   6. A control named harmlessly (aria-label) whose visible text is a
#      forbidden action is refused after the lookup, not clicked
# Needs the module's playwright and its firefox build
# (cd csi-tax-utl && npm ci && npx playwright install firefox); without
# them it prints SKIP, which the fast tier counts as a failure.
#------------------------------------------------------------------------------
# test-timeout: 180
set -uo pipefail
# The browsers stay where npx playwright install put them: the test lib
# points XDG_CACHE_HOME at its temp dir, which Playwright also reads.
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright}"
source "$(dirname "$0")/vero-test-lib.inc.sh"

if [[ ! -d "$MOD_ROOT/node_modules/playwright" ]]; then
  echo "SKIP: no playwright in $MOD_ROOT/node_modules (npm ci)"; finish
fi

cat >"$T/fixture.html" <<'HTML'
<html><body>
<div class="FastBusyOverlay" id="busy" style="position:fixed;inset:0;display:none;z-index:9"></div>
<style>@keyframes wob{from{transform:translateX(0)}to{transform:translateX(40px)}} .wob{display:inline-block;animation:wob .2s infinite alternate}</style>
<header><div role="tablist"><a role="tab" aria-selected="true" href="#" onclick="hit('front');return false">Omat verolajit</a><a role="tab" href="#" onclick="busyFor(600);hit('contact2');return false">Asiakastiedot</a><a onclick="hit('contact')">Yhteydenpito</a><a role="tab" href="#" onclick="hit('tasks');return false">Viestit 3</a></div></header>
<main>
  <div style="display:none"><a href="#" onclick="hit('hidden');return false">Saldoerittely</a></div>
  <div><a href="#" onclick="hit('balance');return false"><span aria-hidden="false">›</span> Saldoerittely</a></div>
  <button onclick="hit('search')">Hae</button>
  <table role="presentation"><tr><td onclick="hit('cell')"><span>Maksutiedot</span></td></tr>
  <tr><td><a class="wob" href="#" onclick="hit('wobble');return false"><span>Saldot</span></a></td></tr>
  <tr><td onclick="hit('bad-cell')"><div>Viestit arkisto</div><div>Siirrä kaikki arkistoon</div></td></tr></table>
  <a href="#" onclick="hit('archive-move');return false">Siirrä arkistoon</a>
  <a href="#" aria-label="Lomake" onclick="hit('form');return false">Tee uusi ilmoitus</a>
</main>
<footer><span onclick="hit('footer')">Tehtävät</span></footer>
<script>window.clicks=[];function hit(x){window.clicks.push(x)}
function busyFor(ms){const b=document.getElementById('busy');b.style.display='block';setTimeout(()=>{b.style.display='none';window.clicks.push('idle')},ms)}</script>
</body></html>
HTML

cat >"$T/run.mjs" <<JS
import { firefox } from '$MOD_ROOT/node_modules/playwright/index.mjs';
import { readFileSync } from 'node:fs';
import { clickControl, clickEl, findControl } from '$MOD_ROOT/src/node/vero-click.mjs';
const forbidden = JSON.parse(readFileSync('$MOD_ROOT/cnf/vero-ui.json', 'utf8')).forbidden_clicks;
const b = await firefox.launch({ headless: true });
const page = await b.newPage();
await page.setContent(readFileSync('$T/fixture.html', 'utf8'));
const out = {};
const tryClick = async (k, name, ms) => { try { await clickControl(page, name, forbidden, ms); out[k] = 'clicked'; } catch (e) { out[k] = e.message; } };
await tryClick('c1', 'Yhteydenpito', 2000);
await tryClick('c2', 'Saldoerittely', 2000);
await tryClick('c3', 'Hae', 2000);
await tryClick('c4', 'Siirrä arkistoon', 2000);
await tryClick('c5', 'Tehtävät', 1000);
await tryClick('c6', 'Lomake', 1000);
await tryClick('c8', 'Viestit', 2000);
out.c9 = await clickControl(page, 'Omat verolajit', forbidden, 2000, { skipSelected: true });
out.c10 = await clickControl(page, 'Asiakastiedot', forbidden, 2000, { skipSelected: true });
out.c10b = await page.evaluate(() => window.clicks.slice(-2).join(','));
await tryClick('c11', 'Maksutiedot', 2000);
await tryClick('c12', 'Viestit arkisto', 2000);
await page.evaluate(() => { const b = document.getElementById('busy'); b.style.display = 'block'; b.style.opacity = '0'; });
const t13 = Date.now();
out.c13 = await clickControl(page, 'Saldot', forbidden, 2000, { clickMs: 1500 }).catch((e) => e.message);
out.c13ms = Date.now() - t13;
out.c14 = await clickEl(page.locator('main a', { hasText: 'Siirrä arkistoon' }), 500, forbidden).catch((e) => e.message);
out.clicks = await page.evaluate(() => window.clicks.join(','));
console.log(JSON.stringify(out));
await b.close();
JS
res=$(node "$T/run.mjs" 2>&1)
if ! jq -e . >/dev/null 2>&1 <<<"$res"; then
  grep -qiE "Executable doesn.t exist|npx playwright install" <<<"$res" && { echo "SKIP: no firefox build (npx playwright install firefox)"; finish; }
  fail "fixture run: $res"; finish
fi
v() { jq -r ".$1" <<<"$res"; }
[[ "$(v c1)" == clicked ]] && pass "1. href-less <a> found by visible text" || fail "1. $(v c1)"
[[ "$(v c2)" == clicked ]] && pass "2. chevron link found by its label" || fail "2. $(v c2)"
[[ "$(v c3)" == clicked ]] && pass "3. button found by role name" || fail "3. $(v c3)"
[[ "$(v c4)" == "refused forbidden click: Siirrä arkistoon" ]] && pass "4. forbidden label refused" || fail "4. $(v c4)"
[[ "$(v c5)" == "no control named \"Tehtävät\" within 1000 ms" ]] && pass "5. label outside main/nav not clicked" || fail "5. $(v c5)"
[[ "$(v c6)" == "refused forbidden click: Tee uusi ilmoitus" ]] && pass "6. forbidden text refused after lookup" || fail "6. $(v c6)"
[[ "$(v c8)" == clicked ]] && pass "8. tab with a counter found" || fail "8. $(v c8)"
[[ "$(v c9)" == selected ]] && pass "9. selected tab not clicked again" || fail "9. $(v c9)"
[[ "$(v c10)" == clicked && "$(v c10b)" == "contact2,idle" ]] && pass "10. click returns after the busy layer is hidden" || fail "10. $(v c10) $(v c10b)"
[[ "$(v c11)" == clicked ]] && pass "11. text in a clickable cell clicks the cell" || fail "11. $(v c11)"
[[ "$(v c12)" == "refused forbidden click: Siirrä kaikki arkistoon" ]] && pass "12. ancestor with a forbidden line refused" || fail "12. $(v c12)"
[[ "$(v c13)" == dom-clicked && "$(v c13ms)" -lt 10000 ]] && pass "13. unstable control DOM-clicked through a transparent layer" || fail "13. $(v c13) in $(v c13ms) ms"
[[ "$(v c14)" == "refused forbidden click: Siirrä arkistoon" ]] && pass "14. clickEl refuses a forbidden element" || fail "14. $(v c14)"
[[ "$(v clicks)" == "contact,balance,search,tasks,contact2,idle,cell,wobble" ]] && pass "clicks were exactly contact,balance,search,tasks,contact2,idle,cell,wobble" || fail "clicks: $(v clicks)"
finish
