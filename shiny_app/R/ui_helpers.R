# Small shared UI helpers used across modules.

`%||%` <- function(x, y) if (is.null(x)) y else x

empty_state <- function(msg = "No data on disk for this selection.") {
  shiny::div(
    class = "text-muted text-center p-5",
    shiny::icon("circle-info"), " ", msg
  )
}

# Dropdown choices from a manifest tibble column, "" (no matches) safe.
choices_from <- function(df, col) {
  if (is.null(df) || !nrow(df)) return(character())
  sort(unique(df[[col]]))
}

# Reads an .rds cache path reactively -- returns NULL for NA/missing paths
# rather than erroring, so callers can uniformly check is.null() first.
read_rds_safe <- function(path) {
  if (is.null(path) || is.na(path) || !file.exists(path)) return(NULL)
  readRDS(path)
}

# Real disk state can carry more than one file matching the same
# (assessment, granularity) filter -- e.g. a stale legacy-config run left
# alongside the current one (confirmed directly: nli_overview_data_GA1.rds
# and nli_overview_data_GA1_bge_m3_zeroshot_complete_bm.rds both exist for
# GA1/complete_bm). Picking path[[1]] blindly can land on an empty/stale
# one while a real one sits right next to it. Tries every candidate path in
# order and returns the first one that reads as real (non-empty) data,
# falling back to the first candidate's (possibly empty) object so callers
# still get a defined, empty-shaped list to show an explicit empty state.
read_first_nonempty <- function(paths) {
  if (!length(paths)) return(NULL)
  for (p in paths) {
    x <- read_rds_safe(p)
    if (!is.null(x) && !isTRUE(x$empty)) return(x)
  }
  read_rds_safe(paths[[1]])
}

pct_vec_to_df <- function(x, value_name = "pct") {
  if (is.null(x)) return(NULL)
  tibble::tibble(label = names(x), value = as.numeric(x)) |>
    stats::setNames(c("label", value_name))
}
