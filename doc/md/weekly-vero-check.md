# Weekly Vero check: runbook

Csitea's weekly read of OmaVero: fetch everything of the year, file it to the
private bucket and the owner's Drive, list what is new, and write the weekly
report for the csitea reports discussion. Every command runs from the
`csi-tax-utl` directory of the checkout, as the box's working user.

## 1. Who does what

### 1.1 The owner

1. Is at the desktop where the browser opens (it is headed).
2. Logs in to OmaVero himself, in the company role, when the browser shows
   the login. Nobody else types into the login, and nothing stores it: the
   browser context is fresh and discarded when the fetch ends.
3. Gives the go for the weekly run (section 5) and for posting the report.

### 1.2 The agent

1. Starts `do_vero_fetch` and waits for the owner's login.
2. Files the result (`do_vero_file`), lists what is new
   (`do_vero_weekly_diff`), writes the report (`do_vero_weekly_report`).
3. Sends the report and the issue drafts to the dispatch holder; it posts in
   no topic itself and never opens a PDF.

### 1.3 Read-only in OmaVero

The fetch only navigates, reads and downloads. It refuses to click the labels
in `csi-tax-utl/cnf/vero-ui.json` `forbidden_clicks` (archive, send a
message, any "Tee ..." form, refund request, account number), aborts every
PUT, PATCH and DELETE request, and fills no field except the two archive
date fields. It navigates by tab and link names, never by the `#N` hash in
the URL (a per-session counter).

## 2. Where the files land

| what | where |
|---|---|
| one fetch run | `$VERO_DATA_DIR/<year>/staging/<yyyymmddThhmmss>/` (mode 700) |
| filed copies | `$VERO_DATA_DIR/<year>/filed/<yyyy-mm>/` |
| the index | `$VERO_DATA_DIR/<year>/index.tsv`, a dated copy per filing day in `history/` |
| diff, issue drafts, report | `$VERO_DATA_DIR/<year>/reports/` |
| bucket | `gs://$VERO_BUCKET/vero/<yyyy>/<yyyy-mm>/<file>` and `vero/<yyyy>/index.tsv` |
| Drive | `$VERO_DRIVE_FOLDER_ID/<yyyy>/<yyyy-mm>/vero/<category>/<file>` |

`VERO_DATA_DIR` defaults to `$HOME/var/csi-tax/vero`. `<yyyy-mm>` is the
month the item arrived. The categories are `decisions`, `statements`,
`balance`, `certificates`, `msgs` and `payments`. A file is named
`<yyyy-mm-dd>_<NN>_<Type>[_kausi-<dd.mm.yyyy>].<ext>`, `NN` numbering the
day's items. Bucket and Drive are add-only: an existing file is never
overwritten. Nothing of this is in git (`.gitignore`, `hygiene.tst.sh`).

## 3. One-time setup

### 3.1 Install the browser driver

Run once in `csi-tax-utl`:

```bash
npm ci
```

Then the browser build Playwright drives:

```bash
npx playwright install firefox
```

### 3.2 The environment, outside git

The values come from the owner and live in the working user's own env file,
never in this repository. The actions read:

| var | used by | what |
|---|---|---|
| `VERO_BASE_URL` | fetch | the OmaVero start URL |
| `VERO_BUCKET` | file | the private bucket name, no scheme |
| `VERO_GCP_KEY_FILE` | file | the key of the service account that writes the bucket |
| `VERO_DRIVE_FOLDER_ID` | file | the owner's Drive top folder |
| `VERO_DRIVE_SA_KEY_FILE` | file | the key of the service account that writes the Drive |

Each one fails fast when it is needed and missing. The bucket is written as
that service account in a throwaway `CLOUDSDK_CONFIG` with `--account` on
every call; the owner account is never used.

## 4. The weekly run

### 4.1 Fetch (the owner logs in)

See the plan first:

```bash
VERO_BASE_URL="$VERO_BASE_URL" ./run -a do_vero_fetch
```

Then open the browser; the owner logs in within 15 minutes
(`VERO_LOGIN_TIMEOUT_S`):

```bash
VERO_BASE_URL="$VERO_BASE_URL" DRY_RUN=0 ./run -a do_vero_fetch
```

It ends with the count of files and the staging run. Exit 3 means some steps
failed (each is named `FAIL <step>`); what was fetched is kept, and a rerun
fetches again.

### 4.2 File

Locally first; the uploads are printed as `PLAN`:

```bash
./run -a do_vero_file
```

Then upload:

```bash
DRY_RUN=0 ./run -a do_vero_file
```

A rerun adds only what the index does not hold. A row joins the index only
after both uploads succeeded, so a failed upload is retried next time.

### 4.3 What is new

```bash
./run -a do_vero_weekly_diff
```

It compares with last week's dated index and writes one issue draft per new
theme to `reports/issues/`.

### 4.4 The weekly report

```bash
./run -a do_vero_weekly_report
```

Sections: 1 new this week, 2 changed, 3 to take into consideration (3.1 due
dates in the next 30 days, `VERO_DUE_WINDOW_DAYS`; 3.2 decisions; 3.3
payments and balance tables that changed; 3.4 open questions). No amounts.
A sample made from fixture data: [weekly-report-sample.md](weekly-report-sample.md).

### 4.5 After the run

The fetch removes the browser's temp artefacts of its run. The run's
staging dir stays (mode 700) as the record of what OmaVero showed.

## 5. The weekly schedule (proposal, not installed)

Nothing is scheduled until the owner's go, relayed by the dispatch holder.
The proposal:

1. **Monday 09:00 Europe/Helsinki**, a box cron line on the box that holds
   the tax data sends one spool message to the standing tax seat: "weekly
   Vero check due".
2. The seat asks the owner, with a poll form in the csitea topic, when he can
   log in (now / in 1 hour / skip this week).
3. On "now", the seat runs 4.1 and the owner logs in; then 4.2, 4.3, 4.4.
4. The seat sends the report and the issue drafts to the dispatch holder,
   which posts the report in the csitea reports discussion and files one
   issue per new theme.
5. A week skipped twice is named in the next report.

## 6. Tests

```bash
bash src/bash/tests/run-all-tests.sh
```

No test reaches OmaVero, a bucket or the Drive: stub `node`, `gcloud` and
`rclone` stand in, on fixture files with no real data. One test,
`vero-click.tst.sh`, runs the label lookup in a headless Firefox on a local
HTML page; it needs section 3.1 done first.

## 7. Traps seen on the first, hand-made run

1. A row opens its PDF in a new tab. With an old tab still open, the wrong
   tab was taken on every second row: the fetch closes every other tab
   before each click, then waits for the tab on the `Retrieve` URL.
2. A browser tool run inside a git tree left downloads and page snapshots
   (with amounts) in an untracked folder there: the fetch runs with its cwd
   in the staging dir and `.gitignore` names those folders.
3. The payments CSVs are UTF-16LE, TAB separated, CRLF, decimal comma, and
   hold the whole history; they are filed as they are.
