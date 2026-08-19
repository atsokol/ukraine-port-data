# Incremental update of the dataset.
#
# Compares the live resource list on data.gov.ua against inputs/source_manifest.csv
# and downloads only the source files that are new or have been re-uploaded since
# the last run, splicing their rows into the existing CSVs. Rows are matched to
# their source through the `source_id` column, so a changed month replaces exactly
# its own rows.
#
# Falls back to a full rebuild when there is nothing to update incrementally from:
# missing CSVs or manifest, CSVs without a `source_id` column (i.e. produced
# before this pipeline), or a manifest that disagrees with the CSVs.

source("scripts/helper_functions.R")

live     <- fetch_resources()
manifest <- read_manifest()
existing <- read_dataset()

# ---- Decide between incremental update and full rebuild ---------------------

needs_rebuild <- function() {
  if (is.null(manifest))  return("no manifest at inputs/source_manifest.csv")
  if (is.null(existing))  return("no existing CSVs, or they predate the source_id column")

  # A source can legitimately contribute zero rows to one of the two sheets, so
  # its id being absent from that CSV is not a disagreement. Only rows pointing
  # at a source the manifest has never heard of are; everything else (a source
  # missing entirely, or with the wrong number of rows) is caught by the count
  # check below, which reads a zero-row source as the zero it should be.
  for (nm in c("calls", "volumes")) {
    orphans <- setdiff(unique(existing[[nm]]$source_id), manifest$resource_id)
    if (length(orphans) > 0) {
      return(paste0(nm, " CSV holds ", length(orphans),
                    " source(s) the manifest does not list"))
    }
  }

  counted <- manifest |>
    mutate(
      csv_calls   = as.integer(tabulate(match(existing$calls$source_id, resource_id), n())),
      csv_volumes = as.integer(tabulate(match(existing$volumes$source_id, resource_id), n()))
    )
  if (!identical(counted$n_calls, counted$csv_calls) ||
      !identical(counted$n_volumes, counted$csv_volumes)) {
    return("manifest row counts do not match the CSVs")
  }
  NULL
}

# A rebuild re-downloads every source (~77 requests against a rate limiter that
# has failed us before), so it is never done unattended just because a check
# tripped: the weekly job stops and asks instead. Set ALLOW_REBUILD=true to let
# this script do it, or run scripts/data_download.R directly.
reason <- needs_rebuild()
if (!is.null(reason)) {
  if (isTRUE(as.logical(Sys.getenv("ALLOW_REBUILD", "false")))) {
    message("Full rebuild required: ", reason)
    rebuild_dataset()
    quit(save = "no", status = 0)
  }
  stop("Full rebuild required (", reason, "), which this script will not do ",
       "unattended - it re-downloads every source file from a rate-limited API. ",
       "Run the 'Full Data Rebuild (manual)' workflow, or re-run with ",
       "ALLOW_REBUILD=true.", call. = FALSE)
}

# ---- Work out what changed --------------------------------------------------

added   <- filter(live, !resource_id %in% manifest$resource_id)
changed <- live |>
  inner_join(select(manifest, resource_id, was_modified = last_modified), by = "resource_id") |>
  filter(last_modified != was_modified) |>
  select(-was_modified)
dropped <- filter(manifest, !resource_id %in% live$resource_id)

describe <- function(df, label) {
  if (nrow(df) == 0) return(invisible(NULL))
  message(label, " (", nrow(df), "): ", paste(df$period, collapse = ", "))
}
describe(added,   "New periods")
describe(changed, "Re-uploaded periods")
describe(dropped, "Periods no longer published (or superseded)")

if (nrow(added) == 0 && nrow(changed) == 0 && nrow(dropped) == 0) {
  message("Already up to date - nothing downloaded, no files written.")
  quit(save = "no", status = 0)
}

# ---- Fetch only what changed and splice it in -------------------------------

fetch <- bind_rows(added, changed)
parsed <- read_sources(fetch)

stale <- c(changed$resource_id, dropped$resource_id)
calls   <- bind_rows(filter(existing$calls,   !source_id %in% stale), parsed$calls)
volumes <- bind_rows(filter(existing$volumes, !source_id %in% stale), parsed$volumes)

message("Ship calls: ", nrow(existing$calls), " -> ", nrow(calls),
        " rows | handling volumes: ", nrow(existing$volumes), " -> ", nrow(volumes), " rows")

write_dataset(calls, volumes, live)
