# READ-ONLY audit for Phase 1 (NLI scoring) output — NOT wired into
# _targets.R as a target.
#
# Orphaned claims (a since-changed segmentation boundary, a renumbered
# sentence, ...) are now pruned automatically by consolidate_nli_scores()
# (R/consolidate_nli_scores.R), which drops rows whose claim_id is absent from
# the current claim list each time it rewrites a (km, bm) group. This utility
# is what you run BEFORE that, to see what would go — in particular when
# consolidation refuses to prune (empty upstream claim list, or a prune
# exceeding max_prune_fraction) and you need to decide whether the upstream
# list is wrong or the removal is genuine. It never modifies anything.
#
# claim_id alone is not globally unique — the same claim_id string (e.g.
# "bm_description-01") is reused across every BM in an assessment — so the
# comparison is always on the full (km, bm, claim_id) triple.
#
# Since consolidation, `claim_id` is a COLUMN inside each group's parquet
# rather than a partition directory, so the on-disk side is read from the
# dataset itself instead of parsed out of directory names.

# One (assessment, granularity, nli_config) combination. nli_ready_path and
# nli_scores_path are the same assessment-scoped directories the pipeline
# itself uses (see nli_ready_evidence_parquet / nli_scores_by_claim_evidence
# in _targets.R) — pass them in already resolved, same convention as the
# rest of R/build_*.R.
find_orphaned_nli_scores <- function(nli_ready_path, nli_scores_path) {
  empty <- dplyr::tibble(
    km = character(), bm = character(), claim_id = character()
  )

  if (!dir.exists(nli_ready_path) || !dir.exists(nli_scores_path)) {
    return(empty)
  }

  # sprintf() isn't supported inside an Arrow-lazy dplyr::mutate() -- collect
  # the (already small) distinct km/bm/sentence_source/sentence_number keys
  # first, then derive claim_id in plain R, same formula as
  # build_nli_claim_units() (R/build_nli_claim_units.R).
  expected <- arrow::open_dataset(nli_ready_path) |>
    dplyr::distinct(km, bm, sentence_source, sentence_number) |>
    dplyr::collect() |>
    dplyr::mutate(claim_id = sprintf("%s-%02d", sentence_source, sentence_number)) |>
    dplyr::distinct(km, bm, claim_id)
  expected_key <- paste(expected$km, expected$bm, expected$claim_id, sep = "")

  on_disk <- tryCatch(
    arrow::open_dataset(nli_scores_path) |>
      dplyr::distinct(km, bm, claim_id) |>
      dplyr::collect(),
    error = function(e) {
      warning(sprintf(
        "[NLI orphan-check] could not read %s: %s",
        nli_scores_path, conditionMessage(e)
      ), call. = FALSE)
      NULL
    }
  )
  if (is.null(on_disk) || !nrow(on_disk)) {
    return(empty)
  }
  on_disk_key <- paste(on_disk$km, on_disk$bm, on_disk$claim_id, sep = "")

  orphaned <- on_disk[!(on_disk_key %in% expected_key), , drop = FALSE]

  if (nrow(orphaned)) {
    message(sprintf(
      "[NLI orphan-check] %d/%d scored claim%s under %s have no matching claim in %s",
      nrow(orphaned), nrow(on_disk), if (nrow(orphaned) == 1) "" else "s",
      nli_scores_path, nli_ready_path
    ))
    for (i in seq_len(nrow(orphaned))) {
      message(sprintf(
        "  - km=%s bm=%s claim_id=%s",
        orphaned$km[i], orphaned$bm[i], orphaned$claim_id[i]
      ))
    }
    message(
      "[NLI orphan-check] these are pruned automatically the next time ",
      "consolidate_nli_scores() rewrites their (km, bm) group."
    )
  } else {
    message(sprintf(
      "[NLI orphan-check] no orphans found under %s (%d claim%s checked)",
      nli_scores_path, nrow(on_disk), if (nrow(on_disk) == 1) "" else "s"
    ))
  }

  orphaned
}

# Convenience wrapper: runs find_orphaned_nli_scores() across every
# (assessment x granularity) combination this project tracks, resolving
# each granularity's own nli_config via nli_config_for_granularity()
# (R/branch_helpers.R) rather than assuming nli.active — same reasoning as
# the nli_overview_data/refutes_funnel_data/supports_funnel_data fix: each
# granularity is normally scored under its OWN dedicated config, not
# whichever one happens to be active right now. Read-only: removal is
# consolidate_nli_scores()'s job now, guarded by its own emptiness and
# max_prune_fraction checks.
find_orphaned_nli_scores_all <- function(
  config_path = "input/config.yaml",
  nli_granularities = c("naive_bm", "complete_bm", "atomic_bm")
) {
  cfg <- yaml::read_yaml(config_path)
  assessment_ids <- vapply(cfg[["assessments"]], `[[`, character(1), "id")
  nli_active <- cfg[["nli"]][["active"]]
  nli_configs_all <- cfg[["nli"]][["configs"]]

  combos <- expand.grid(
    assessment_id = assessment_ids,
    granularity   = nli_granularities,
    stringsAsFactors = FALSE
  )

  results <- lapply(seq_len(nrow(combos)), function(i) {
    assessment_id <- combos$assessment_id[[i]]
    granularity   <- combos$granularity[[i]]
    nli_config_name <- nli_config_for_granularity(nli_configs_all, granularity, nli_active)

    nli_ready_path <- file.path(
      "output/nli_ready_evidence", paste0("granularity=", granularity),
      paste0("assessment=", assessment_id)
    )
    nli_scores_path <- file.path(
      "output/nli_scores_evidence", paste0("granularity=", granularity),
      paste0("nli_config=", nli_config_name), paste0("assessment=", assessment_id)
    )

    out <- find_orphaned_nli_scores(nli_ready_path, nli_scores_path)
    if (nrow(out)) {
      out$assessment  <- assessment_id
      out$granularity <- granularity
      out$nli_config  <- nli_config_name
    }
    out
  })

  dplyr::bind_rows(results)
}
