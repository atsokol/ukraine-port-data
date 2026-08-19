# Full rebuild of the dataset: downloads every source file from data.gov.ua and
# overwrites data/*.csv and inputs/source_manifest.csv from scratch.
#
# This is the expensive path (~77 files, and the source rate-limits aggressively).
# For routine refreshes use scripts/data_update.R, which downloads only what
# changed. Run this one when the parsing logic changes, or to repair a dataset
# that has drifted out of sync with its manifest.

source("scripts/helper_functions.R")

rebuild_dataset()
