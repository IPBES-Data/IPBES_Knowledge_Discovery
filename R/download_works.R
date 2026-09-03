download_works <- function(
  assessment,
  zotero_path,
  refs_path,
  output_root = "output/works",
  workers = 8
) {
  output_path <- branch_output_dir(output_root, assessment$id)
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  dois <- arrow::open_dataset(zotero_path) |>
    dplyr::select(doi) |>
    dplyr::filter(!is.na(doi)) |>
    dplyr::collect() |>
    dplyr::pull(doi) |>
    openalexPro::extract_doi(non_doi_value = "", normalize = TRUE, what = "doi")
  dois <- unique(dois[nzchar(dois)])

  if (!length(dois)) {
    stop("No DOIs found for assessment ", assessment$id)
  }
  message("Querying OpenAlex for ", length(dois), " DOIs [", assessment$id, "]")

  query_url <- openalexPro::pro_query(
    entity = "works",
    doi = dois
  )

  parquet_dir <- openalexPro::pro_fetch(
    query_url = query_url,
    project_folder = output_path,
    overwrite = TRUE,
    workers = workers,
    verbose = FALSE,
    progress = TRUE
  )

  if (!length(list.files(parquet_dir, pattern = "\\.parquet$", recursive = TRUE))) {
    stop("pro_fetch wrote no parquet files for ", assessment$id)
  }

  # doi_norm MUST go through extract_doi(), not just str_to_lower() --
  # confirmed directly this session that OpenAlex's own API always returns
  # doi as a full URL ("https://doi.org/10.xxxx"), while refs_parquet's
  # hasDoi values are INCONSISTENTLY formatted (a mix of bare "10.xxxx" and
  # full-URL within the same assessment -- real LOD data, not a parsing
  # artifact), and Zotero's own doi field (the backfill source below) is
  # always bare. str_to_lower() alone never strips the URL prefix, so the
  # previous version of this join only ever matched the subset of refs that
  # happened to already be in OpenAlex's own full-URL format -- silently
  # dropping the rest as unmatched, not erroring. Measured impact: one
  # assessment (VA, all-Zotero-backfilled, all bare) went from ~1947
  # available DOIs to just 9 surviving works; even GA1 (mixed formats) was
  # very likely losing the majority of its own legitimate matches, just
  # less visibly. extract_doi() is already used for the OpenAlex query
  # DOI list above; applying it here too makes both sides of the join
  # consistent regardless of source format.
  works_raw <- arrow::open_dataset(parquet_dir) |>
    dplyr::collect() |>
    dplyr::mutate(doi_norm = stringr::str_to_lower(openalexPro::extract_doi(
      doi, non_doi_value = "", normalize = TRUE, what = "doi"
    )))

  # Backfill a missing refs$doi from zotero_parquet's own already-fetched
  # DOI field, matched by Zotero item key parsed out of refs$zotero -- NOT
  # done inside write_refs_parquet.R/refs_parquet itself, since that would
  # make refs_parquet depend on zotero_parquet's OUTPUT while
  # zotero_parquet's own construction (infer_zotero_group_id()) already
  # depends on refs_parquet's zotero column -- a real cycle. This function
  # already receives both zotero_path and refs_path with no such cycle, so
  # it's the right place. Confirmed directly this session that this is a
  # real need, not hypothetical: one real assessment (VA) has 0 of ~3079
  # references with ipbes:hasDoi in its LOD graph at all, while Zotero's own
  # item metadata for the same references does carry real DOIs for the
  # large majority -- refs.sparql's own comment has the full story. No new
  # API calls here: zotero_path already has this data from the existing
  # zotero_parquet target. coalesce() prefers the LOD-sourced doi first, so
  # an assessment that already has hasDoi populated (GA1, TCA) is unaffected.
  # nzchar() is not an Arrow compute function -- confirmed directly
  # ("Expression not supported in Arrow... Call collect() first") -- so it
  # has to run after collect(), not chained into the lazy Dataset query
  # like the is.na() check above it.
  zotero_doi_by_key <- arrow::open_dataset(zotero_path) |>
    dplyr::select(key, zotero_doi = doi) |>
    dplyr::filter(!is.na(zotero_doi)) |>
    dplyr::collect() |>
    dplyr::filter(nzchar(zotero_doi)) |>
    dplyr::distinct(key, .keep_all = TRUE)

  refs_km_bm <- arrow::open_dataset(refs_path) |>
    dplyr::select(km, bm, doi, zotero) |>
    dplyr::collect() |>
    dplyr::mutate(zotero_key = sub("^.*/items/", "", zotero)) |>
    dplyr::left_join(zotero_doi_by_key, by = c("zotero_key" = "key")) |>
    dplyr::mutate(doi = dplyr::coalesce(doi, zotero_doi)) |>
    dplyr::filter(!is.na(doi)) |>
    # Same extract_doi()-before-lowercasing fix as works_raw's doi_norm
    # above, for the same reason -- this side's doi is a mix of bare
    # LOD-sourced and bare Zotero-backfilled values, neither of which
    # matched works_raw's full-URL OpenAlex format under plain
    # str_to_lower() alone.
    dplyr::mutate(doi_norm = stringr::str_to_lower(openalexPro::extract_doi(
      doi, non_doi_value = "", normalize = TRUE, what = "doi"
    ))) |>
    dplyr::select(km, bm, doi_norm) |>
    dplyr::distinct()

  assessment_id <- assessment$id
  works_with_km_bm <- works_raw |>
    dplyr::inner_join(refs_km_bm, by = "doi_norm", relationship = "many-to-many") |>
    dplyr::select(-doi_norm) |>
    dplyr::mutate(assessment = assessment_id)

  unlink(file.path(output_path, "json"),  recursive = TRUE, force = TRUE)
  unlink(file.path(output_path, "jsonl"), recursive = TRUE, force = TRUE)
  unlink(parquet_dir, recursive = TRUE, force = TRUE)

  # path = output_root (NOT output_path) -- output_path is already
  # assessment-scoped (branch_output_dir() returns ".../assessment=<id>"),
  # and works_with_km_bm still carries its own "assessment" column
  # (mutate() above), which partitioning = c("assessment", ...) turns into
  # ANOTHER "assessment=<id>/" level. Writing to output_path here doubled
  # that segment on disk (".../assessment=TCA/assessment=TCA/km=.../"),
  # confirmed directly across every assessment already run (GA1, IAS, TCA,
  # VA) -- a real, long-standing bug, not something introduced today.
  # output_root + full partitioning matches the convention
  # build_snowball_parquet.R already uses for its own nodes/edges output.
  arrow::write_dataset(
    dataset = works_with_km_bm,
    path = output_root,
    format = "parquet",
    partitioning = c("assessment", "km", "bm"),
    existing_data_behavior = "delete_matching"
  )

  output_path
}
