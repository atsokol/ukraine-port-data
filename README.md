# ukraine-port-data

Ukraine port statistics database, built from the Ukrainian Sea Ports Authority's
[Ф-12 / Ф-13 dataset](https://data.gov.ua/dataset/3f67ad69-fdd7-4afd-ab5c-765681286f48)
on data.gov.ua. The source publishes one XLSX per month; this repo parses them
into two tidy CSVs.

## Data

| File | Contents |
| --- | --- |
| [data/ship calls.csv](data/ship%20calls.csv) | Ф-12 register of ship calls |
| [data/handling volumes.csv](data/handling%20volumes.csv) | Ф-13 cargo handling by terminal and berth |
| [inputs/source_manifest.csv](inputs/source_manifest.csv) | One row per ingested source file |

Both CSVs carry a trailing `source_id` column: the data.gov.ua resource UUID of
the monthly file the row was parsed from. This is what makes incremental updates
possible — a monthly file can contain rows belonging to neighbouring months (the
July 2018 file, for example, holds ship calls departing in June and August), so
month alone cannot identify which rows came from where.

Where the source has re-uploaded a month more than once, only the most recently
modified resource is kept. Rows are ordered by their source file's period, so a
new month appends at the end and re-parsing an old month rewrites only its block.

## Scripts

| Script | Purpose |
| --- | --- |
| [scripts/data_update.R](scripts/data_update.R) | Incremental. Downloads only source files that are new or re-uploaded since the last run, and splices their rows in. |
| [scripts/data_download.R](scripts/data_download.R) | Full rebuild. Downloads all ~77 source files and regenerates everything. |
| [scripts/helper_functions.R](scripts/helper_functions.R) | Shared download, parsing and I/O helpers. |

`data_update.R` falls back to a full rebuild on its own if the CSVs and the
manifest are missing or disagree, so it is always safe to run.

## Automation

| Workflow | Trigger |
| --- | --- |
| [Weekly Data Update](.github/workflows/update.yml) | Every Sunday 23:00 UTC, plus manual |
| [Full Data Rebuild](.github/workflows/download.yml) | Manual only |

The rebuild is manual because the source rate-limits aggressively and a full run
makes ~77 requests. Run it after changing the parsing logic; otherwise the weekly
incremental update is enough.
