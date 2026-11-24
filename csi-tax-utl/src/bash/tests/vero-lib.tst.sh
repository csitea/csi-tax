#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for src/node/vero-lib.mjs, vero-name.mjs and vero-weekly.mjs:
# the pure helpers, run with node, no browser and no network.
#   1. Finnish dates parse; the due date and the arrival date are told apart
#   2. The file name: date, per-day number, type with dashes, kausi
#   3. The Drive category of a message, a payments table, a statement, a decision
#   4. The forbidden clicks are refused, a normal link is not
#   5. Amounts are scrubbed from a label; a date stays
#   6. Only PUT/PATCH/DELETE count as writes; isPdf reads the magic bytes
#   7. The namer skips a sha256 the index holds and continues the day's NN
#   8. The weekly compare tells new from changed
#   9. The keep-alive is due after 2 min by default, never with VERO_KEEPALIVE=0
#------------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/vero-test-lib.inc.sh"
N="$MOD_ROOT/src/node"

js() { node --input-type=module -e "import * as L from '$N/vero-lib.mjs'; import * as V from '$N/vero-name.mjs'; import * as W from '$N/vero-weekly.mjs'; $1" 2>&1; }

check() { # check <n> <name> <expected> <js>
  local got
  got=$(js "$4")
  if [[ "$got" == "$3" ]]; then pass "$1. $2"; else fail "$1. $2: want [$3] got [$got]"; fi
}

check 1a "fi date" "2026-02-03" "console.log(L.parseFiDate('Saapunut 3.2.2026'))"
check 1b "due date" "2026-03-12" "console.log(L.dueDate('Kausi 1.1.2026 Eräpäivä 12.3.2026'))"
check 1c "arrival is not the due date" "2026-02-03" "console.log(L.arrivalDate('Eräpäivä 12.3.2026 saapunut 3.2.2026'))"
check 2a "file name with kausi" "2026-03-04_02_Verotuspaatos_kausi-31.12.2025.pdf" \
  "console.log(L.fileName({arrival_date:'2026-03-04',seq:2,type:'Verotuspäätös (pdf)',period:'31.12.2025'}))"
check 2b "file name without kausi" "2026-03-04_01_Document.csv" \
  "console.log(L.fileName({arrival_date:'2026-03-04',seq:1,type:'',ext:'csv'}))"
check 3 "drive categories" "msgs payments statements balance certificates decisions" \
  "console.log([L.driveCategory('message','x'),L.driveCategory('payments','x'),L.driveCategory('document','Tiliote'),L.driveCategory('document','Saldoerittely'),L.driveCategory('document','Verovelkatodistus'),L.driveCategory('document','Päätös')].join(' '))"
check 4 "forbidden clicks" "true true true false" \
  "const f=['Siirrä arkistoon','Tee *','Ilmoita tilinumero']; console.log([L.isForbiddenLabel('Siirrä arkistoon',f),L.isForbiddenLabel('Tee oma-aloitteisen veron ilmoitus',f),L.isForbiddenLabel(' ilmoita tilinumero ',f),L.isForbiddenLabel('Avaa viestit',f)].join(' '))"
check 5 "amounts scrubbed" "Maksu <amount> eräpäivä 12.3.2026, <amount>" \
  "console.log(L.scrubAmounts('Maksu 1 234,50 € eräpäivä 12.3.2026, EUR 99'))"
check 6 "write methods, pdf magic" "true false false true false" \
  "console.log([L.isWriteRequest('delete'),L.isWriteRequest('POST'),L.isWriteRequest('GET'),L.isPdf(Buffer.from('%PDF-1.7')),L.isPdf(Buffer.from('<html>'))].join(' '))"
check 7 "namer: skip known sha, continue NN" "b.pdf 2026-03-04_02_Paatos.pdf" \
  "const p=V.plan([{arrival_date:'2026-03-04',type:'Päätös',file:'a.pdf',sha256:'s1'},{arrival_date:'2026-03-04',type:'Päätös',file:'b.pdf',sha256:'s2'}],[{arrival_date:'2026-03-04',sha256:'s1'}]); console.log(p.map(l=>{const c=l.split('\t');return c[0]+' '+c[9]}).join(';'))"
check 8 "weekly compare" "1 1" \
  "const prev=[{kind:'document',type:'A',tax_type:'',period:'',sha256:'1'}]; const idx=[...prev,{kind:'document',type:'A',tax_type:'',period:'',sha256:'2'},{kind:'document',type:'B',tax_type:'',period:'',sha256:'3'}]; const c=W.compare(idx,prev); console.log(c.added.length+' '+c.changed.length)"
check 9 "keep-alive due" "false true false true false" \
  "console.log([L.keepaliveDue(119999,0),L.keepaliveDue(120000,0),L.keepaliveDue(999999,0,{VERO_KEEPALIVE:'0'}),L.keepaliveDue(60000,0,{VERO_KEEPALIVE_MIN:'1'}),L.keepaliveDue(9e9,0,{VERO_KEEPALIVE_MIN:'0'})].join(' '))"
check 10 "click log keeps why a click did not land" "<div class=ov> intercepts pointer events|waiting for element to be visible, enabled and stable|2" \
  "const m='locator.click: Timeout 30000ms exceeded.\\nCall log:\\n  - waiting for element to be visible, enabled and stable\\n  - <div class=ov> intercepts pointer events\\n  - <div class=ov> intercepts pointer events\\n  - some other line'; const c=L.clickLog(m); console.log(c[1]+'|'+c[0]+'|'+c.length)"
check 11 "urls lose their query" "go https://id.example.com/return?<scrubbed> x https://a.example.com/p" \
  "console.log(L.scrubUrls('go https://id.example.com/return?code=abc&state=d x https://a.example.com/p'))"
finish
