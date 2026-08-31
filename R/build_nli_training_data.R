# NLI fine-tuning training data, per the revised strategy in
# TD_NLI_training.qmd. Sibling to the other Phase-2-derived QA/reporting
# builders (build_llm_verification_qa_data.R etc.) -- reads only
# already-built output/llm_verification/scores* data (no new LLM/API calls,
# a pure local Arrow query, same cost profile as any other QA data builder
# in this project).
#
# Positives: key papers the LLM confirmed SUPPORTS with a real verbatim
# quote (llm_verification_keypaper_parquet) -- NOT every cited paper
# unconditionally, per the qmd's own reasoning (only 2.6% of GA1's key
# papers actually have explicit abstract-level support; blindly labelling
# the rest SUPPORTS would teach the model the exact topic-adjacency-as-
# entailment confusion this fine-tuning effort exists to correct).
#
# Negatives: real NLI/LLM disagreements from BOTH Phase 2 chains (the main
# citing-works corpus and the key-paper chain) -- NLI called SUPPORTS or
# REFUTES with real confidence, but the LLM's grounded, quote-checked
# review said NOT_ENOUGH_INFO. Downsampled to roughly match the positive
# count for class balance.
#
# REFUTES: the real nli_label=="REFUTES" & llm_label=="REFUTES" rows from
# both chains, included unconditionally (too few to need downsampling).
#
# Output is hive-partitioned granularity=<g>/nli_config=<cfg>/assessment=<id>/,
# the SAME scheme output/nli_scores_evidence and friends already use --
# `llm_config` is carried through as a plain COLUMN, not a fourth partition
# level, matching Phase 1's own partition granularity rather than Phase 2's
# more granular one (llm_config/assessment/nli_route/km/bm): this is a
# deliberate simplification, since llm_verification_path/
# llm_verification_keypaper_path are already scoped to ONE (currently
# active) llm_config by construction (that's how llm_verification_parquet's
# own output_path is built) -- re-running under a DIFFERENT llm_config will
# overwrite this partition's training data rather than keep both side by
# side, same as switching nli.active would for a given granularity/assessment
# slot in Phase 1's own output.
build_nli_training_data <- function(
  assessment,
  llm_verification_path,
  llm_verification_keypaper_path,
  works_path,
  works_citing_path,
  nli_active,
  llm_active,
  granularity,
  output_root = "output/nli_training"
) {
  assessment_id <- assessment$id

  output_path <- file.path(
    output_root, paste0("granularity=", granularity),
    paste0("nli_config=", nli_active), paste0("assessment=", assessment_id)
  )

  has_data <- function(path) {
    !is.null(path) && dir.exists(path) &&
      length(list.files(path, pattern = "\\.parquet$", recursive = TRUE)) > 0L
  }

  # Title/abstract/doi lookup, same defensive collapse-to-one-row-per-id
  # pattern build_nli_scores_qa_data.R/build_llm_verification_qa_data.R
  # already use -- a work can repeat across the (km, bm) partitions it's
  # cited/reviewed from. doi is kept for the QA report's clickable work
  # link, not for training itself.
  work_lookup <- function(path, ids) {
    if (!has_data(path) || !length(ids)) {
      return(dplyr::tibble(work_id = character(), title = character(), abstract = character(), doi = character()))
    }
    arrow::open_dataset(path) |>
      dplyr::select(work_id = id, title, abstract, doi) |>
      dplyr::filter(work_id %in% ids) |>
      dplyr::collect() |>
      dplyr::group_by(work_id) |>
      dplyr::summarise(
        title    = dplyr::first(title[!is.na(title)], default = NA_character_),
        abstract = dplyr::first(abstract[!is.na(abstract)], default = NA_character_),
        doi      = dplyr::first(doi[!is.na(doi)], default = NA_character_),
        .groups = "drop"
      )
  }

  empty_pairs <- function() {
    dplyr::tibble(
      assessment = character(), km = character(), bm = character(),
      claim = character(), work_id = character(), quote = character(),
      nli_config = character(),
      nli_label = character(), nli_confidence = double()
    )
  }

  # --- Positives: LLM-verified key-paper SUPPORTS ---------------------------

  # NOTE: "assessment" is never included in these select() calls, even
  # though it's a real column in the source data -- this function's own
  # `assessment` PARAMETER (the assessment spec list) shadows the column
  # name for tidyselect's bare-symbol resolution, which errors trying to
  # use a list as a subscript ("Can't subset elements... not NULL"),
  # confirmed directly. Added back via mutate(assessment = assessment_id)
  # instead, which is unambiguous (named argument, not a bare symbol) and
  # already the authoritative value for this per-assessment branch anyway.
  #
  # NOTE: "llm_config" is likewise never select()ed from the source data --
  # llm_verification_path/llm_verification_keypaper_path are already scoped
  # INSIDE a `llm_config=<val>/` hive partition directory (that's how
  # build_llm_verification_parquet()'s own output_path is built), and Arrow
  # only reconstructs hive-partition segments that are BELOW the dataset
  # root it's given -- one that's already been "consumed" by the path
  # itself is genuinely absent from the schema at read time, confirmed
  # directly ("Column `llm_config` doesn't exist"). Added back via
  # mutate(llm_config = llm_active) instead, using the llm_active parameter
  # this function is called with -- same fix build_llm_verification_qa_data.R
  # already uses for its own llm_active handling.
  positives <- empty_pairs()
  if (has_data(llm_verification_keypaper_path)) {
    positives <- arrow::open_dataset(llm_verification_keypaper_path) |>
      dplyr::filter(llm_label == "SUPPORTS") |>
      dplyr::select(km, bm, claim, work_id, quote, nli_config) |>
      dplyr::collect()
    positives$nli_label <- NA_character_
    positives$nli_confidence <- NA_real_
  }
  positives <- positives |>
    dplyr::left_join(work_lookup(works_path, unique(positives$work_id)), by = "work_id") |>
    dplyr::mutate(
      assessment = assessment_id, llm_config = llm_active,
      hypothesis = claim, label = "SUPPORTS", source = "llm_verified"
    )

  # --- Negatives: real NLI/LLM disagreements, both chains -------------------

  real_negatives <- function(path) {
    if (!has_data(path)) return(empty_pairs())
    arrow::open_dataset(path) |>
      dplyr::filter(nli_label %in% c("SUPPORTS", "REFUTES"), !uncertain, llm_label == "NOT_ENOUGH_INFO") |>
      dplyr::select(km, bm, claim, work_id, quote, nli_config, nli_label, nli_confidence) |>
      dplyr::collect()
  }

  negatives_raw <- dplyr::bind_rows(
    real_negatives(llm_verification_path)         |> dplyr::mutate(.works_path = works_citing_path),
    real_negatives(llm_verification_keypaper_path) |> dplyr::mutate(.works_path = works_path)
  )

  set.seed(42)
  n_target <- max(nrow(positives), 1L)
  negatives <- if (nrow(negatives_raw) > n_target) {
    negatives_raw |> dplyr::slice_sample(n = n_target)
  } else {
    negatives_raw
  }

  neg_works <- dplyr::bind_rows(
    work_lookup(works_citing_path, unique(negatives$work_id[negatives$.works_path == works_citing_path])),
    work_lookup(works_path, unique(negatives$work_id[negatives$.works_path == works_path]))
  ) |> dplyr::distinct(work_id, .keep_all = TRUE)

  negatives <- negatives |>
    dplyr::select(-.works_path) |>
    dplyr::left_join(neg_works, by = "work_id") |>
    dplyr::mutate(
      assessment = assessment_id, llm_config = llm_active,
      hypothesis = claim, label = "NOT_ENOUGH_INFO", source = "llm_verified"
    )

  # --- REFUTES: real nli_label == llm_label == "REFUTES", both chains -------

  real_refutes <- function(path, wp) {
    if (!has_data(path)) return(dplyr::mutate(empty_pairs(), title = character(), abstract = character(), doi = character()))
    d <- arrow::open_dataset(path) |>
      dplyr::filter(nli_label == "REFUTES", llm_label == "REFUTES") |>
      dplyr::select(km, bm, claim, work_id, quote, nli_config, nli_label, nli_confidence) |>
      dplyr::collect()
    d |> dplyr::left_join(work_lookup(wp, unique(d$work_id)), by = "work_id")
  }

  refutes <- dplyr::bind_rows(
    real_refutes(llm_verification_path, works_citing_path),
    real_refutes(llm_verification_keypaper_path, works_path)
  ) |>
    dplyr::mutate(
      assessment = assessment_id, llm_config = llm_active,
      hypothesis = claim, label = "REFUTES", source = "llm_verified"
    )

  cols <- c(
    "assessment", "km", "bm", "work_id", "hypothesis", "quote", "title", "abstract", "doi",
    "label", "source", "llm_config", "nli_config", "nli_label", "nli_confidence"
  )
  training_pairs <- dplyr::bind_rows(positives, negatives, refutes)

  if (!nrow(training_pairs)) {
    if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    message(sprintf("[nli_training_data %s] no training pairs to export", assessment_id))
    return(output_path)
  }

  training_pairs <- training_pairs |> dplyr::select(dplyr::all_of(cols))
  training_pairs$granularity <- granularity

  if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
  arrow::write_dataset(
    dataset = training_pairs,
    path = output_root,
    format = "parquet",
    partitioning = c("granularity", "nli_config", "assessment"),
    existing_data_behavior = "delete_matching"
  )

  message(sprintf(
    "[nli_training_data %s] wrote %d rows to %s", assessment_id, nrow(training_pairs), output_path
  ))

  output_path
}
