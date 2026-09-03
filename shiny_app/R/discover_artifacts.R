# Disk-as-ground-truth manifest layer.
#
# The set of (assessment x granularity x nli_config x llm_config)
# combinations actually built is incomplete and inconsistent with
# input/config.yaml -- newly-enabled assessments (VA/TCA) don't have every
# report type yet, and disabled ones (IAS) still have old outputs on disk.
# Every dropdown in the app is populated from these manifest tibbles, built
# by scanning output/ once at app startup -- never from config.yaml.
#
# Filenames follow R/branch_helpers.R's own paste0() convention:
#   "<stem>_<assessment><nli_model_suffix?><granularity_suffix?>.<ext>"
# nli_model_suffix()/granularity_suffix() are each either "" or "_<value>",
# so the generic parser below just strips a known trailing "_<granularity>"
# token (naive_bm/complete_bm/atomic_bm -- none is a suffix of another, so
# this is unambiguous) and then splits the remainder into the leading
# alnum-only assessment id (GA1/IAS/TCA/VA -- no assessment id contains an
# underscore) plus whatever config-identifying suffix is left.

GRANULARITIES <- c("naive_bm", "complete_bm", "atomic_bm")

.strip_ext <- function(f) sub("\\.[^.]+$", "", basename(f))

parse_stem <- function(stem, has_granularity = TRUE) {
  rest <- stem
  # "unspecified", not NA -- NA would silently vanish from every dropdown
  # (choices_from() sort()s, which drops NAs), hiding real stale-but-real
  # data left on disk from before the naive_bm/complete_bm/atomic_bm
  # granularity-suffix convention existed (confirmed directly: GA1's own
  # nli_overview_data_GA1.rds carries real, non-empty data under an
  # internal granularity of "sub_bm", a value that predates and isn't one
  # of the three current GRANULARITIES, while every current-scheme file for
  # GA1 is itself empty).
  granularity <- if (has_granularity) "unspecified" else NA_character_
  if (has_granularity) {
    for (g in GRANULARITIES) {
      suf <- paste0("_", g)
      if (endsWith(rest, suf)) {
        granularity <- g
        rest <- substr(rest, 1, nchar(rest) - nchar(suf))
        break
      }
    }
  }
  m <- regmatches(rest, regexpr("^[A-Za-z0-9]+", rest))
  assessment <- if (length(m)) m else rest
  config_suffix <- if (nchar(assessment) < nchar(rest)) {
    substring(rest, nchar(assessment) + 2)
  } else {
    ""
  }
  list(assessment = assessment, granularity = granularity, config_suffix = config_suffix)
}

# Some families (fine-tuned model, overlap tables) have no per-assessment
# axis at all -- parse_stem()'s "leading alnum run = assessment" convention
# would wrongly eat the first underscore-delimited chunk of a plain config
# name (e.g. "bge_m3_zeroshot_atomic_bm" -> assessment "bge", config_suffix
# "m3_zeroshot_atomic_bm", silently truncating the displayed name). This
# variant treats the whole remaining stem as `config_suffix`, no assessment.
list_family_no_assessment <- function(dir, prefix, ext) {
  pat <- paste0("^", prefix, ".+\\.", ext, "$")
  files <- if (dir.exists(dir)) list.files(dir, pattern = pat, full.names = TRUE) else character()
  if (!length(files)) {
    return(tibble::tibble(path = character(), config_suffix = character()))
  }
  tibble::tibble(
    path = files,
    config_suffix = sub(paste0("^", prefix), "", .strip_ext(files))
  )
}

list_family <- function(dir, prefix, ext, has_granularity = TRUE) {
  pat <- paste0("^", prefix, ".+\\.", ext, "$")
  files <- if (dir.exists(dir)) list.files(dir, pattern = pat, full.names = TRUE) else character()
  if (!length(files)) {
    return(tibble::tibble(
      path = character(), assessment = character(),
      granularity = character(), config_suffix = character()
    ))
  }
  stems <- sub(paste0("^", prefix), "", .strip_ext(files))
  parsed <- lapply(stems, parse_stem, has_granularity = has_granularity)
  tibble::tibble(
    path = files,
    assessment = vapply(parsed, `[[`, character(1), "assessment"),
    granularity = vapply(parsed, `[[`, character(1), "granularity"),
    config_suffix = vapply(parsed, `[[`, character(1), "config_suffix")
  )
}

# Reads a single-value manifest entry -> NA_character_ if the file doesn't
# exist, so downstream UI can render an explicit empty state rather than
# erroring on a missing path.
existing_or_na <- function(path) if (file.exists(path)) path else NA_character_

discover_artifacts <- function(
  tables_dir = "output/tables",
  figures_dir = "output/figures",
  reports_dir = "output/reports",
  training_dir = "output/nli_training"
) {
  td_files <- if (dir.exists(reports_dir)) {
    list.files(reports_dir, pattern = "^TD_.*\\.html$", full.names = TRUE)
  } else {
    character()
  }

  training_partitions <- tibble::tibble(
    granularity = character(), nli_config = character(),
    assessment = character(), keypaper = logical()
  )
  if (dir.exists(training_dir)) {
    ds <- tryCatch(arrow::open_dataset(training_dir), error = function(e) NULL)
    if (!is.null(ds)) {
      training_partitions <- ds |>
        dplyr::select(granularity, nli_config, assessment, keypaper) |>
        dplyr::distinct() |>
        dplyr::collect() |>
        dplyr::mutate(keypaper = as.logical(keypaper))
    }
  }

  list(
    nli_scores_qa           = list_family(tables_dir, "nli_scores_qa_", "rds"),
    nli_scores_qa_figures   = list_family(figures_dir, "nli_scores_qa_ternary_", "png"),
    llm_verification_qa     = list_family(tables_dir, "llm_verification_qa_", "rds", has_granularity = FALSE),
    nli_training_qa         = list_family(tables_dir, "nli_training_qa_", "rds"),
    nli_finetuned_model_qa  = list_family_no_assessment(tables_dir, "nli_finetuned_model_qa_", "rds"),
    bm_split                = list_family(tables_dir, "bm_split_highlighted_", "rds"),
    refutes_funnel_data     = list_family(tables_dir, "refutes_funnel_data_", "rds"),
    supports_funnel_data    = list_family(tables_dir, "supports_funnel_data_", "rds"),
    refutes_funnel_table_l3 = list_family(tables_dir, "refutes_funnel_table_l3_", "rds"),
    supports_funnel_table_l3 = list_family(tables_dir, "supports_funnel_table_l3_", "rds"),
    refutes_funnel_figures  = list_family(figures_dir, "fig_refutes_funnel_overall_", "png"),
    supports_funnel_figures = list_family(figures_dir, "fig_supports_funnel_overall_", "png"),
    nli_overview_data       = list_family(tables_dir, "nli_overview_data_", "rds"),
    nli_bm_explorer         = list_family(tables_dir, "nli_bm_explorer_", "html"),
    td_docs = tibble::tibble(
      path = td_files,
      title = tools::toTitleCase(gsub("_", " ", sub("^TD_", "", .strip_ext(td_files))))
    ),
    overlap_key_paper_rds = existing_or_na(file.path(tables_dir, "overlap_key_paper.rds")),
    overlap_sub_messages_rds = existing_or_na(file.path(tables_dir, "overlap_after_2018_sub_messages.rds")),
    overlap_background_messages_rds = existing_or_na(file.path(tables_dir, "overlap_after_2018_background_messages.rds")),
    fig_pub_per_year = existing_or_na(file.path(figures_dir, "fig_pub_per_year.png")),
    workflow_svg = existing_or_na(file.path(figures_dir, "workflow_nli.svg")),
    training_partitions = training_partitions,
    training_dir = training_dir
  )
}

# Builds fig_<label>_funnel_by_bm[_normalized]_<...>.png paths from an
# overall-figure path already resolved via the manifest (all three figures
# share the same "<...>" suffix, only the "overall"/"by_bm"/
# "by_bm_normalized" infix differs).
funnel_figure_siblings <- function(overall_path) {
  list(
    overall = overall_path,
    by_bm = sub("_overall_", "_by_bm_", overall_path),
    by_bm_normalized = sub("_overall_", "_by_bm_normalized_", overall_path)
  )
}
