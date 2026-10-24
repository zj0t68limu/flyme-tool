# Data maintenance

This folder controls **how the firmware data is updated**. No app rebuild is required.

## Layout

```
.github/workflows/update-data.yml   runs automatically (cron + on manual-urls change)
tools/update_data.py                scrape the official site + merge manual links + normalise sorting
tools/check_sort.py                 CI guard: fails when the dataset is not sorted
data/manual-urls.txt                drop new links here, one per line
data/firmware.json                  generated dataset (the app reads this)
```

## Three everyday situations

### 1. The official site published a new build (fully automatic)

Nothing to do. The workflow runs on a schedule, scrapes
`https://www.flyme.com/firmwarelist-<device-id>.html` and fills **MD5 / file size / release
date** into the dataset.

> To run it immediately: repository → Actions → `update-firmware-data` → **Run workflow**.

### 2. You captured a new link (paste one line)

Edit `data/manual-urls.txt`, append the link and commit:

```
https://download.meizu.com/Firmware/Flyme/meizu21/12.7.0.0/cn/20261019043635/14f3162c/update.zip
```

- signed links with `auth_key` are accepted; the script strips the signature and keeps the
  permanent direct link
- the script extracts **model / version / region / build time / hash** from the URL path
- MD5 and release date stay empty (shown as "not published" in the UI) until the official site
  publishes them
- links that already exist are not added twice

### 3. A brand-new device (auto-created)

If the device code in the link is unknown, the script creates a new device entry:

- name is set to `<code>（新机型·待补名称）`
- `cdn` contains only that code
- you can later rename it by editing `name` in `data/firmware.json`

## Sorting rules and automatic verification

**Every group's builds are ordered by `ts` descending** (newest first within the same version),
and groups are ordered as *normal groups by version ascending, then beta/variant groups by
version ascending*.

`update_data.py` re-sorts the **whole dataset** on every run, so pasting a link can never leave
the file unsorted.

Verify only (no write):

```bash
python tools/check_sort.py                 # exits 1 and lists offending groups
python tools/update_data.py --check-sort   # same check, built-in mode
```

CI (`.github/workflows/update-data.yml`) runs `check_sort.py` right after the update step:
**if the order is wrong, the workflow fails and nothing is committed.**

If local data was edited by hand and got out of order, fix it with:

```bash
python tools/update_data.py      # re-sorts in place
```

(The repository-level `6-工具脚本/8-sort_builds.py` implements the same rules locally and can
write back all three `firmware.json` copies; it supports `--check` and `--dry`.)

## Build classification (`kind`)

Every build carries a `kind` that drives the filter chips in the UI. The rules below are the
ones already used throughout the historical dataset — they are derived from data, not guessed:

| `kind` | UI label | Rule |
|---|---|---|
| `official` | 官网稳定版 | the build whose `md5` **equals the MD5 published on the official device page** |
| `multi` | 同版本多构建 | a different build of a version that already has an `official` entry |
| `hidden` | 官网隐藏 | the version does **not** appear on the official page at all |
| `factory` | 出厂系统 | factory image listed on the official page |
| `beta` | 内测每日构建 | `region` is `cn_daily` / `cn_beta` / `beta` / `intl_beta` |
| `variant` | 联名同平台 | co-branded hardware sharing the same platform |

Evidence (Meizu 21 PRO, `12.6.0.0`):

```
md5 = adecb59640aad477d7f1485a4011ed6b  ==  official page md5  ->  kind=official, releaseDate=2026-06-30
other builds of the same version                                ->  kind=multi
12.7.0.0 (absent from the official page)                        ->  kind=hidden
```

Consequences:

- a newly imported link is **never** assumed to be `official`; without an official-page match it
  is stored as `hidden`
- `tools/update_data.py` promotes `hidden` → `official` only when the scraped MD5 matches, and
  never demotes a historical `official` entry (the page only lists the current stable version)
- same-version siblings of a confirmed official build are marked `multi`
- field conventions: `cn` rows use `suf='A'`, `code='206'`; `intl` rows use `suf=''`, `code=''`

## Running locally (optional)

```bash
python tools/update_data.py            # only process manual-urls.txt
python tools/update_data.py --scrape   # also scrape the official site for MD5/size/date
```

## Data source URL used by the app

```
https://raw.githubusercontent.com/<your-user>/<your-repo>/main/data/firmware.json
```

On any device: **Device settings → paste the URL → Refresh now**.
