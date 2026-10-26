# Data maintenance (Swift iOS project)

This folder controls how `data/firmware.json` is updated; no app rebuild is needed for data-only
changes.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/update-data.yml` | scheduled/manual data refresh |
| `tools/update_data.py` | scrape official site + merge `manual-urls.txt` + sort + write dataset |
| `tools/check_sort.py` | CI guard: fails when a group is not sorted |
| `data/manual-urls.txt` | new links, one per line |
| `data/firmware.json` | dataset consumed by the app |

## Commands

```bash
python tools/update_data.py            # process manual-urls.txt only
python tools/update_data.py --scrape   # also scrape the official site
python tools/update_data.py --check-sort
python tools/check_sort.py
```

`update_data.py` rewrites the whole dataset in sorted order. `check_sort.py` only verifies and
exits non-zero on an unsorted group.

## URL rules

- permanent: `https://download.meizu.com/Firmware/Flyme/<model>/<ver>/<region>/<ts>/<hash>/update.zip`
- signed temporary `firmware-res.flyme.com` URLs: `auth_key` is removed
- `cn_daily` range timestamps `start-end` are stored with `ts` empty and the range kept in the URL
- duplicate links are skipped
- unknown model codes create a new device entry named `<code>（新机型·待补名称）`

## Sorting

- builds inside a group: `ts` descending (empty `ts` sorts last)
- groups: normal groups by version ascending, then beta/variant groups by version ascending
- `update_data.py` sorts the whole dataset on every run
- the repository-level `6-工具脚本/8-sort_builds.py` implements the same rule and writes all three
  `firmware.json` copies; it supports `--check` and `--dry`

## kind rules

`official` = MD5 matches the official page; `multi` = same version as an official build;
`hidden` = not on the official page; `factory` = official factory image;
`beta` = `cn_daily` / `cn_beta` / `beta` / `intl_beta`; `variant` = co-branded platform.

A newly imported link stays `hidden` until the official-page MD5 matches.

Run `python 6-工具脚本/11-check_docs.py` from the project root after editing docs.
