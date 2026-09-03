build_works_citing_parquet <- function(assessment, works_path, snowball_path,
                                       output_root = "output/works_citing") {
  assessment_id <- assessment$id
  output_path   <- file.path(output_root, paste0("assessment=", assessment_id))

  unlink(output_path, recursive = TRUE, force = TRUE)
  dir.create(output_root, showWarnings = FALSE, recursive = TRUE)

  nodes_path <- snowball_path[grepl("nodes", snowball_path)]
  edges_path <- snowball_path[grepl("edges", snowball_path)]

  # snowball_parquet now runs one unified pro_snowball() call per
  # assessment (over the union of every km/bm's key papers), so nodes/edges
  # carry no km/bm attribution of their own. Reconstruct it here by joining
  # works_parquet's own (km, bm, id) seed mapping against the edges table
  # (to == a seed's id) -- the same join build_llm_candidate_scope_parquet.R
  # already does for its own seed-id filtering.
  seeds <- arrow::open_dataset(works_path) |>
    dplyr::select(km, bm, id) |>
    dplyr::collect() |>
    dplyr::distinct()

  if (!dir.exists(edges_path) || !dir.exists(nodes_path)) {
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    return(output_path)
  }

  edges <- arrow::open_dataset(edges_path) |>
    dplyr::select(from, to) |>
    dplyr::distinct() |>
    dplyr::collect()

  km_bm_citing_ids <- seeds |>
    dplyr::inner_join(
      edges,
      by = c("id" = "to"),
      relationship = "many-to-many"
    ) |>
    dplyr::distinct(km, bm, from)

  if (!nrow(km_bm_citing_ids)) {
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    return(output_path)
  }

  # One schema for the whole assessment now (a single pro_snowball() call),
  # so a plain collect() is safe -- no more per-km/bm schema-inconsistency
  # file-copy workaround needed.
  citing_nodes <- arrow::open_dataset(nodes_path) |>
    dplyr::filter(relation == "citing") |>
    dplyr::collect()

  out <- km_bm_citing_ids |>
    dplyr::inner_join(
      citing_nodes,
      by = c("from" = "id"),
      relationship = "many-to-many"
    ) |>
    dplyr::rename(id = from) |>
    dplyr::mutate(assessment = assessment_id)

  if (!nrow(out)) {
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    return(output_path)
  }

  arrow::write_dataset(
    out,
    output_root,
    partitioning = c("assessment", "km", "bm"),
    existing_data_behavior = "delete_matching"
  )

  output_path
}
