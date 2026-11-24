# Weekly Vero check: runbook

Csitea's weekly read of OmaVero: fetch everything of the year, file it to the
private bucket and the owner's Drive, list what is new, and write the weekly
report for the csitea reports discussion. Every command runs from the
`csi-tax-utl` directory of the checkout, as the box's working user.

## 1. Who does what

### 1.1 The owner

1. Is at the desktop where the browser opens (it is headed).
2. Logs in to OmaVero himself, in the company role, in the one browser
   window the fetch opens. Nobody else types into the login. The window
   stays open (owner's choice, 2026-11-24): later runs reuse it and its
   login while OmaVero keeps the session, and every page the script opens
   in it shares that login. The browser profile (`VERO_PROFILE_DIR`, mode
   700, outside git) keeps the session cookies on disk; this replaces the
   earlier "store no login data" rule.
3. Answers the weekly login poll (section 5) and gives the go for posting
   the report.

### 1.2 The agent

1. Starts `do_vero_fetch` and waits for the owner's login.
2. Files the result (`do_vero_file`), lists what is new
   (`do_vero_weekly_diff`), writes the report (`do_vero_weekly_report`).
3. Sends the report and the issue drafts to the dispatch holder; it posts in
   no topic itself and never opens a PDF.

### 1.3 The kept-open window

`do_vero_fetch` starts one browser session (`src/node/vero-session.mjs`)
when none runs and hands it each fetch; no run closes the window. Close it
with:

```bash
DRY_RUN=0 ./run -a do_vero_session_stop
```

OmaVero and Suomi.fi end a session on their side after idle time; then the
window shows the login again and the next run waits for the owner.

### 1.4 Read-only in OmaVero

The fetch only navigates, reads and downloads. It refuses to click the labels
in `csi-tax-utl/cnf/vero-ui.json` `forbidden_clicks` (archive, send a
message, any "Tee ..." form, refund request, account number), aborts every
PUT, PATCH and DELETE request, and fills no field except the two archive
date fields. It navigates by tab and link names, never by the `#N` hash in
the URL (a per-session counter).

## 2. Where the files land

| what | where |
|---|---|
| browser session control, browser profile | `$VERO_SESSION_DIR`, `$VERO_PROFILE_DIR` (default under `$VERO_DATA_DIR`, mode 700) |
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

The window stays open for the next run. The run's staging dir stays (mode
700) as the record of what OmaVero showed. A failed step logs a `PROBE`
line: the role, name and visibility of the controls that carry a cnf label,
no page data.

## 5. The weekly schedule

Owner's choice (2026-11-24): **every Tuesday at 15:30 Europe/Helsinki**.

### 5.1 How it fires

The box cron (Debian `cron`) has no per-crontab timezone (`CRON_TZ`), so
one line fires at minute :30 of every hour, Monday to Wednesday in box time,
and `do_vero_weekly_due` acts only when the Helsinki time is Tuesday 15:30
(13:30Z in winter, 12:30Z in summer). It follows Helsinki across DST
whatever the box timezone, and sends at most one notice a day.

### 5.2 Who wakes whom

1. The cron line runs `do_vero_weekly_due`, which runs `VERO_NOTIFY_CMD`: a
   message to the standing tax seat, "weekly Vero check due".
2. The seat asks the owner, with a poll form in the csitea topic, when he can
   log in (now / in 15 min / in about 1 h / skip this week).
3. On his answer the seat runs 4.1 and the owner logs in; then 4.2, 4.3, 4.4.
4. The seat sends the report and the issue drafts to the dispatch holder,
   which posts the report in the csitea reports discussion and files one
   issue per new theme.

### 5.3 Install

The values live in an env file outside git, mode 600, named by
`VERO_ENV_FILE`; it holds `VERO_NOTIFY_CMD` and the section 3.2 values.
See the line first:

```bash
VERO_ENV_FILE="$VERO_ENV_FILE" ./run -a do_vero_cron_install
```

Then install it in the current user's crontab (a rerun replaces it):

```bash
VERO_ENV_FILE="$VERO_ENV_FILE" DRY_RUN=0 ./run -a do_vero_cron_install
```

Check it:

```bash
crontab -l
```

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
   (with amounts) in an untracked folder there: the session runs with its
   cwd in its own session dir and `.gitignore` names those folders.
4. The labels are not always links, tabs or buttons by their exact name (a
   chevron in the name, an `<a>` without href, a hidden duplicate): the
   lookup (`src/node/vero-click.mjs`) also takes the visible text, and only
   visible controls. Each step starts from the front page.
3. The payments CSVs are UTF-16LE, TAB separated, CRLF, decimal comma, and
   hold the whole history; they are filed as they are.
