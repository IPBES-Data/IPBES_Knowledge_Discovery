build_snowball_parquet <- function(
  assessment,
  works_path,
  output_root = "output/snowball"
) {
  assessment_id <- assessment$id
  nodes_root <- file.path(output_root, "nodes")
  edges_root <- file.path(output_root, "edges")
  keypaper_root <- file.path(output_root, "keypaper")

  nodes_assessment_dir <- file.path(
    nodes_root,
    paste0("assessment=", assessment_id)
  )
  edges_assessment_dir <- file.path(
    edges_root,
    paste0("assessment=", assessment_id)
  )
  keypaper_assessment_dir <- file.path(
    keypaper_root,
    paste0("assessment=", assessment_id)
  )

  unlink(nodes_assessment_dir, recursive = TRUE, force = TRUE)
  unlink(edges_assessment_dir, recursive = TRUE, force = TRUE)
  unlink(keypaper_assessment_dir, recursive = TRUE, force = TRUE)
  dir.create(nodes_root, showWarnings = FALSE, recursive = TRUE)
  dir.create(edges_root, showWarnings = FALSE, recursive = TRUE)
  dir.create(keypaper_root, showWarnings = FALSE, recursive = TRUE)

  works <- arrow::open_dataset(works_path) |>
    dplyr::select(km, bm, id) |>
    dplyr::collect() |>
    dplyr::mutate(w_id = sub("^https://openalex\\.org/", "", id))

  # One snowball run per assessment over the UNION of every key paper
  # across all its km/bm groups -- a single work can legitimately be a
  # seed for several BMs (see R/download_works.R's many-to-many join), so
  # calling pro_snowball() once per (km, bm) as before re-fetched the same
  # seed's citation graph redundantly, up to ~19-29x for some assessments.
  # Per-(km, bm) attribution is now derived downstream by joining the
  # unified edges/nodes tables against works_parquet's own (km, bm, id)
  # mapping -- see R/build_works_citing_parquet.R and
  # R/build_nli_ready_evidence_keypaper_parquet.R.
  ids <- unique(works$w_id)

  if (length(ids)) {
    message("Snowball [", assessment_id, "]: ", length(ids), " unique seeds")

    # openalexSnowball (confirmed on the installed 0.1.2) has a real
    # internal bug: when a seed set's snowball search finds ZERO
    # keypapers, its own code tries to read back an internal
    # "keypaper_parquet" temp directory via a glob pattern that matches
    # nothing, and duckdb/arrow raises an IO error instead of it just
    # returning an empty result -- reproduced twice on real assessment
    # data (VA and TCA), not a one-off. Narrowly catches ONLY this exact
    # error signature and treats it as "zero keypapers" (same as the
    # ids-empty case above) -- any OTHER pro_snowball() failure still
    # propagates and fails the pipeline loudly, since this is one
    # specific, understood package bug, not a blanket "ignore snowball
    # errors" escape hatch.
    sb_dir <- tryCatch(
      openalexSnowball::pro_snowball(
        identifier = ids,
        output = tempfile(fileext = ".snowball"),
        verbose = TRUE
      ),
      error = function(e) {
        msg <- conditionMessage(e)
        if (grepl("keypaper_parquet", msg, fixed = TRUE)) {
          warning(sprintf(
            "[snowball %s] openalexSnowball found no keypapers for this seed set (package-internal read error on empty result, treated as zero): %s",
            assessment_id, msg
          ), call. = FALSE)
          NULL
        } else {
          stop(e)
        }
      }
    )

    if (!is.null(sb_dir)) {
      # Stay in Arrow end-to-end: OpenAlex `nodes` carries list/struct
      # columns (authorships, topics, locations, mesh, ...) that don't
      # round-trip through an R data.frame — `collect() |> write_dataset()`
      # fails with "Degenerated data frame". `mutate()` on a Dataset is
      # lazy and works fine.
      nodes_ds <- arrow::open_dataset(file.path(sb_dir, "nodes")) |>
        dplyr::mutate(assessment = assessment_id)

      edges_ds <- arrow::open_dataset(file.path(sb_dir, "edges")) |>
        dplyr::mutate(assessment = assessment_id)

      # openalexSnowball >= 0.1.1 no longer emits a standalone keypaper
      # directory; keypapers are inside `nodes` with relation = "keypaper".
      keypaper_ds <- nodes_ds |> dplyr::filter(relation == "keypaper")

      arrow::write_dataset(
        nodes_ds,
        nodes_root,
        partitioning = c("assessment", "relation"),
        existing_data_behavior = "delete_matching"
      )
      arrow::write_dataset(
        edges_ds,
        edges_root,
        partitioning = c("assessment", "edge_type"),
        existing_data_behavior = "delete_matching"
      )
      arrow::write_dataset(
        keypaper_ds,
        keypaper_root,
        partitioning = c("assessment"),
        existing_data_behavior = "delete_matching"
      )

      unlink(sb_dir, recursive = TRUE, force = TRUE)
    }
  }

  c(nodes_assessment_dir, edges_assessment_dir, keypaper_assessment_dir)
}
