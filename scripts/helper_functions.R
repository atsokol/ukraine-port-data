# Shared helpers for the Ukraine port data pipeline.
#
# Both entry points build on these:
#   scripts/data_download.R  - full rebuild, downloads every source file
#   scripts/data_update.R    - incremental, downloads only new/changed source files
#
# Provenance model
# ----------------
# The source dataset publishes one XLSX per month, but a monthly file may carry
# rows belonging to neighbouring months (e.g. the July 2018 file holds ship calls
# departing in June and August). Month is therefore NOT a safe key for replacing
# rows. Instead every output row carries `source_id` - the data.gov.ua resource
# UUID it was parsed from - and inputs/source_manifest.csv records what was
# ingested from each resource. An update replaces whole per-resource row blocks.

library(jsonlite)
library(httr)
library(readxl)
library(dplyr)
library(purrr)
library(lubridate)
library(readr)

PORT_DATA_ID  <- "f5095ab0-5312-480d-9090-f8f2a42a023c"
PKG_API_URL   <- paste0("https://data.gov.ua/api/3/action/package_show?id=", PORT_DATA_ID)

CALLS_PATH    <- "data/ship calls.csv"
VOLUMES_PATH  <- "data/handling volumes.csv"
MANIFEST_PATH <- "inputs/source_manifest.csv"

ukr_months <- c(
  "Січень"   = 1,
  "Лютий"    = 2,
  "Березень" = 3,
  "Квітень"  = 4,
  "Травень"  = 5,
  "Червень"  = 6,
  "Липень"   = 7,
  "Серпень"  = 8,
  "Вересень" = 9,
  "Жовтень"  = 10,
  "Листопад" = 11,
  "Грудень"  = 12
)

# Sheet layouts of the source workbooks (sheet 1 = Ф-12, sheet 2 = Ф-13).
COLS_CALL <- list(
  names = c("port_name", "num", "arrival_date", "arrival_time", "departure_date",
            "departure_time", "ship_id", "ship_name", "ship_type", "ship_flag", "dwt",
            "call_purpose", "cargo_type", "volume", "agent"),
  types = c("text", "numeric", "text", "text", "text", "text", "text", "text", "text",
            "text", "numeric", "text", "text", "numeric", "text")
)
COLS_VOL <- list(
  names = c("port_name", "year", "month", "port_operator", "berth_no", "cargo_type",
            "direction", "volume", "unit"),
  types = c("text", "numeric", "text", "text", "text", "text", "text", "numeric", "text")
)

# Column specs for reading the published CSVs back in. Everything that is not a
# number stays character, deliberately:
#   * ship_id and berth_no would otherwise be re-written in a different form;
#   * date columns must NOT be re-parsed as dates. The source contains typo'd
#     dates with three-digit years, which dmy() reads literally (e.g. year 201).
#     Written out as a Date, write_csv emits those unpadded ("201-10-05") and
#     col_date() then cannot read them back - so a round trip would silently NA
#     out ~46 rows on every update. Dates are instead converted once at parse
#     time to zero-padded ISO strings (as_iso_date) and carried as character
#     from there on, which writes and reads back byte-identically.
SPEC_CALLS <- cols(
  port_name = col_character(), arrival_date = col_character(), arrival_time = col_character(),
  departure_date = col_character(), departure_time = col_character(), ship_id = col_character(),
  ship_name = col_character(), ship_type = col_character(), ship_flag = col_character(),
  dwt = col_double(), call_purpose = col_character(), cargo_type = col_character(),
  volume = col_double(), agent = col_character(), source_id = col_character()
)
SPEC_VOLUMES <- cols(
  port_name = col_character(), date = col_character(), port_operator = col_character(),
  berth_no = col_character(), cargo_type = col_character(), direction = col_character(),
  volume = col_double(), unit = col_character(), source_id = col_character()
)

SPEC_MANIFEST <- cols(
  period = col_character(), resource_id = col_character(), name = col_character(),
  last_modified = col_character(), url = col_character(),
  n_calls = col_integer(), n_volumes = col_integer()
)


# ---- Source discovery -------------------------------------------------------

# Derive the "YYYY-MM" period a resource covers from its (inconsistently worded)
# title, e.g. "Ф-12 та Ф-13 за липень 2026 року.xlsx" -> "2026-07".
parse_period <- function(name) {
  mon_pat <- paste(tolower(names(ukr_months)), collapse = "|")
  vapply(name, function(x) {
    lo <- tolower(x)
    m <- regexpr(mon_pat, lo)
    y <- regexpr("20[0-9]{2}", x)
    if (m < 0 || y < 0) return(NA_character_)
    month_no <- ukr_months[match(regmatches(lo, m), tolower(names(ukr_months)))]
    sprintf("%04d-%02d", as.integer(regmatches(x, y)), unname(month_no))
  }, character(1), USE.NAMES = FALSE)
}

# The live list of source files, one per period: where a month has been
# re-uploaded, only the most recently modified resource is kept.
fetch_resources <- function() {
  res <- fromJSON(PKG_API_URL, simplifyVector = TRUE)$result$resources

  all_res <- tibble(
    resource_id   = res$id,
    name          = res$name,
    url           = res$url,
    last_modified = res$last_modified,
    period        = parse_period(res$name)
  )

  unparsed <- filter(all_res, is.na(period))
  if (nrow(unparsed) > 0) {
    warning("Skipping ", nrow(unparsed), " resource(s) with an unrecognised period: ",
            paste(unparsed$name, collapse = "; "), call. = FALSE)
  }

  kept <- all_res |>
    filter(!is.na(period)) |>
    group_by(period) |>
    slice_max(last_modified, n = 1, with_ties = FALSE) |>
    ungroup() |>
    arrange(period)

  message("Source dataset: ", nrow(all_res), " resources, ", nrow(kept),
          " kept after collapsing re-uploads")
  kept
}


# ---- Downloading and parsing ------------------------------------------------

# Download a file once, retrying with backoff on HTTP 429 rate limiting.
# Returns the local path of the downloaded file.
download_file <- function(file_url, name, max_tries = 5) {
  tf <- tempfile(fileext = ".xlsx")
  message("Downloading: ", name)
  for (attempt in seq_len(max_tries)) {
    resp <- GET(file_url, write_disk(tf, overwrite = TRUE), timeout(120))
    if (status_code(resp) == 429 && attempt < max_tries) {
      wait <- 2^attempt
      message("  Rate limited (429), retry ", attempt, "/", max_tries - 1, " in ", wait, "s ...")
      Sys.sleep(wait)
      next
    }
    stop_for_status(resp)
    return(tf)
  }
}

# Render a parsed Date as a zero-padded ISO string. Dates live as character from
# here on, so that freshly parsed rows and rows read back from the published CSVs
# are byte-identical (see the note on SPEC_CALLS above).
as_iso_date <- function(x) format(x, "%Y-%m-%d")

# Read a given sheet from an already-downloaded local file.
read_sheet <- function(path, name, sheet, col_names, col_types, skip = 4) {
  message("Reading: ", name, " | sheet: ", sheet)
  read_excel(path, sheet = sheet, col_names = col_names, col_types = col_types, skip = skip)
}

# Download one resource and parse both sheets from that single local copy.
# (Downloading per-sheet doubled the requests and tripped the source's rate limiter.)
read_source <- function(url, name, resource_id) {
  path <- download_file(url, name)
  on.exit(unlink(path), add = TRUE)

  calls <- read_sheet(path, name, 1, COLS_CALL$names, COLS_CALL$types) |>
    mutate(arrival_date = as_iso_date(dmy(arrival_date)),
           departure_date = as_iso_date(dmy(departure_date))) |>
    select(-num) |>
    mutate(source_id = resource_id)

  volumes <- read_sheet(path, name, 2, COLS_VOL$names, COLS_VOL$types) |>
    mutate(date = as_iso_date(ymd(paste(year, ukr_months[month], 1, sep = "-")))) |>
    select(-c(year, month)) |>
    relocate("date", .after = "port_name") |>
    mutate(source_id = resource_id)

  list(calls = calls, volumes = volumes)
}

# Download and parse a set of resources, pausing between files to stay under the
# source's rate limiter. Returns bound `calls` and `volumes` tibbles.
read_sources <- function(resources, pause = 2) {
  if (nrow(resources) == 0) {
    return(list(calls = NULL, volumes = NULL))
  }
  parsed <- pmap(
    list(resources$url, resources$name, resources$resource_id),
    function(url, name, resource_id) {
      out <- read_source(url, name, resource_id)
      if (pause > 0) Sys.sleep(pause)
      out
    }
  )
  list(
    calls   = bind_rows(map(parsed, "calls")),
    volumes = bind_rows(map(parsed, "volumes"))
  )
}


# ---- Reading and writing the published dataset ------------------------------

read_manifest <- function() {
  if (!file.exists(MANIFEST_PATH)) return(NULL)
  read_csv(MANIFEST_PATH, col_types = SPEC_MANIFEST)
}

read_dataset <- function() {
  if (!file.exists(CALLS_PATH) || !file.exists(VOLUMES_PATH)) return(NULL)
  calls   <- read_csv(CALLS_PATH,   col_types = SPEC_CALLS)
  volumes <- read_csv(VOLUMES_PATH, col_types = SPEC_VOLUMES)
  if (!"source_id" %in% names(calls) || !"source_id" %in% names(volumes)) return(NULL)
  list(calls = calls, volumes = volumes)
}

# Write both CSVs plus the manifest. Rows are ordered by the period of their
# source resource, so a new month appends at the end of the file and re-parsing
# an old month rewrites only its own block - keeping git diffs small.
write_dataset <- function(calls, volumes, resources) {
  order_by_period <- function(df) {
    df |>
      mutate(.ord = match(source_id, resources$resource_id)) |>
      arrange(.ord) |>
      select(-.ord)
  }
  calls   <- order_by_period(calls)
  volumes <- order_by_period(volumes)

  manifest <- resources |>
    mutate(
      n_calls   = as.integer(tabulate(match(calls$source_id, resource_id), nrow(resources))),
      n_volumes = as.integer(tabulate(match(volumes$source_id, resource_id), nrow(resources)))
    ) |>
    select(period, resource_id, name, last_modified, url, n_calls, n_volumes)

  dir.create(dirname(MANIFEST_PATH), showWarnings = FALSE, recursive = TRUE)
  write_csv(calls, CALLS_PATH)
  write_csv(volumes, VOLUMES_PATH)
  write_csv(manifest, MANIFEST_PATH)

  message("Wrote ", CALLS_PATH, ": ", nrow(calls), " rows")
  message("Wrote ", VOLUMES_PATH, ": ", nrow(volumes), " rows")
  message("Wrote ", MANIFEST_PATH, ": ", nrow(manifest), " sources (",
          min(manifest$period), " .. ", max(manifest$period), ")")
  invisible(manifest)
}

# Full rebuild: download every source file and overwrite the dataset.
rebuild_dataset <- function(pause = 2) {
  resources <- fetch_resources()
  parsed <- read_sources(resources, pause = pause)
  write_dataset(parsed$calls, parsed$volumes, resources)
}
