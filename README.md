# csi-tax

Csitea's tax paperwork, automated where it can be: today the weekly read of
OmaVero (the Finnish tax administration's e-service, Vero.fi). The scripts
open OmaVero in a browser window on the company owner's own machine, fetch
the year's decisions, letters and payment data read-only, file them by month
and type, and write a weekly report of what is new and what is due.

- **The owner logs in himself.** The scripts never type, read or store
  credentials; they wait in the open window until the login is done.
- **No tax data, secret or key is ever in git.** The documents live outside
  the tree (`VERO_DATA_DIR`, a private bucket and Drive); the bucket, folder
  and service account keys are read from variables you set, never defaults.

Licence: GNU AGPL v3, the same as [csi-spl](https://github.com/csitea/csi-spl)
(see [LICENSE](LICENSE)).

| dir | holds |
|---|---|
| `csi-tax-utl` | the `./run` actions, their tests and the OmaVero fetch (`src/node`) |
| `doc/md` | the runbook and a sample report |
| `src/bash/run/run.sh` | the repo-root `./run`: hands an action to the module that defines it |

The `./run` framework is copied from csi-spl (`run.sh` 3.10.0).

## Actions

| action | does |
|---|---|
| `./run -a do_vero_fetch` | read-only fetch of the year in the one kept-open browser window (a 2-min keep-alive between runs); the owner logs in once |
| `./run -a do_vero_session_stop` | closes that window |
| `./run -a do_vero_file` | name, file, index; with `DRY_RUN=0` upload to the bucket and the Drive |
| `./run -a do_vero_weekly_diff` | what is new since last week, one issue draft per theme |
| `./run -a do_vero_weekly_report` | the weekly markdown report |
| `./run -a do_vero_weekly_due` | the cron trigger: acts only at Tuesday 15:30 Europe/Helsinki |
| `./run -a do_vero_cron_install` | installs that trigger in the current user's crontab |

Each one is a dry run or read-only by default; `./run --help` lists them.
How to run the week: [doc/md/weekly-vero-check.md](doc/md/weekly-vero-check.md).

## Tests

```bash
bash csi-tax-utl/src/bash/tests/run-all-tests.sh
```
