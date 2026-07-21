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

# Helper: download file once, retrying with backoff on HTTP 429 rate limiting.
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

# Helper: read a given sheet from an already-downloaded local file
read_sheet <- function(path, name, sheet, col_names, col_types, skip = 4) {
  message("Reading: ", name, " | sheet: ", sheet)
  read_excel(path, sheet = sheet, col_names = col_names, col_types = col_types, skip = skip)
}
