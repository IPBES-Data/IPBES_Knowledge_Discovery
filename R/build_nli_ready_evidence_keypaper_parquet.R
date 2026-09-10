# Build the NLI-ready parquet database for KEY PAPERS -- the seed/reference
# works IPBES actually cites as evidence for a BM (relation == "keypaper" in
# the snowball nodes, same set as works_parquet), scored against their OWN
# BM's claim text. This is a QA sanity check, not part of the main scoring
# corpus: a key paper is, by construction, the evidence a BM was written
# FROM, so it should overwhelmingly land in the SUPPORTS region when scored
# -- if it doesn't, that's a signal something's off (segmentation, premise
# cleaning, or the NLI model itself), not a normal finding to report on.
#
# Structurally this is build_nli_ready_evidence_parquet()'s twin -- same
# claims-building logic (calls that file's segment_bm_by_evidence()/
# segment_bm_whole()/segment_bm_atomic()/complete_bm_fragments() directly;
# R/*.R all share one sourced environment, so this is a normal function
# call, not a copy of their regex logic) and the identical
# scalar_cols/premise-cleaning/cross-join shape for the per-work step --
# only the work SOURCE differs (keypaper snowball nodes instead of
# works_citing_parquet) and so does the output_root, keeping this entirely
# separate from the already-scored citing-works chain. Deliberately a
# parallel file rather than a generalized/parameterized
# build_nli_ready_evidence_parquet() -- editing that function's body would
# mark the existing (real, already-scored) nli_ready_evidence_parquet
# target outdated for no functional reason; see build_llm_candidate_scope_parquet.R's
# own comment for the same reasoning applied elsewhere in this project.
#
# `snowball_path` is the raw snowball_parquet target value (a 3-element
# vector: nodes/edges/keypaper assessment dirs) -- the keypaper dir is
# extracted internally, same convention build_works_citing_parquet() uses
# for its own `nodes` extraction from that same vector. Since
# snowball_parquet now runs one unified pro_snowball() call per assessment,
# the keypaper table itself carries no km/bm attribution any more --
# `works_path` (works_parquet) supplies the (km, bm, id) seed mapping used
# to split it back apart per (km, bm) below, the same join
# build_works_citing_parquet() uses for its own edges/nodes attribution.
build_nli_ready_evidence_keypaper_parquet <- function(
  assessment,
  key_messages_parquet,
  works_path,
  snowball_path,
  workers = 1L,
  output_root = "output/nli_ready_evidence_keypaper",
  granularity = "naive_bm",
  completion_model = NULL
) {
  assessment_id <- assessment$id
  output_path <- file.path(output_root, paste0("assessment=", assessment_id))

  # Same resumability convention as build_nli_ready_evidence_parquet(): skip
  # entirely if this exact (assessment, granularity) combination already has
  # output, so switching nli.active back and forth doesn't force atomic_bm's
  # real LLM completion calls to be redone for no reason.
  if (dir.exists(output_path) &&
    length(list.files(output_path, pattern = "\\.parquet$", recursive = TRUE))) {
    message(sprintf(
      "[NLI_READY_EV_KP %s] output already exists at %s (granularity=%s) -- skipping",
      assessment_id, output_path, granularity
    ))
    return(output_path)
  }

  keypaper_path <- snowball_path[grepl("keypaper", snowball_path)]

  now <- function() format(Sys.time(), "%H:%M:%S")
  completion_cfg <- NULL
  completion_api_key <- NULL
  if (identical(granularity, "atomic_bm")) {
    completion_cfg <- list(model = completion_model %||% "openai/gpt-4o-mini")
    completion_api_key <- Sys.getenv("API_openrouter")
    if (!nzchar(completion_api_key)) {
      stop("API_openrouter environment variable is required for granularity = \"atomic_bm\" (set from keyring in _targets.R)")
    }
  }

  # ── 1. BM claims -- identical logic to build_nli_ready_evidence_parquet(),
  # calling its segmenters directly (see file header for why this block is
  # duplicated rather than the outer function being generalized). ─────────
  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  bm_info <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, km_label, bm, bm_label, bm_description) |>
    dplyr::distinct() |>
    dplyr::collect()

  claims <- dplyr::bind_rows(lapply(seq_len(nrow(bm_info)), function(i) {
    row <- bm_info[i, , drop = FALSE]
    has_desc <- !is.na(row$bm_description) && nzchar(row$bm_description)
    has_label <- !is.na(row$bm_label) && nzchar(row$bm_label)

    sources <- list()
    if (has_desc) sources[["bm_description"]] <- row$bm_description
    if (has_label) sources[["bm_label"]] <- row$bm_label
    if (!length(sources)) {
      return(NULL)
    }

    if (identical(granularity, "complete_bm") && has_desc && has_label &&
      identical(stringr::str_squish(row$bm_description), stringr::str_squish(row$bm_label))) {
      sources[["bm_label"]] <- NULL
    }

    dplyr::bind_rows(lapply(names(sources), function(src) {
      if (identical(granularity, "atomic_bm")) {
        raw <- segment_bm_atomic(sources[[src]])
        if (!nrow(raw)) {
          return(NULL)
        }
        completed <- complete_bm_fragments(
          raw$claim, completion_cfg, completion_api_key,
          confidence = raw$confidence
        )
        if (!nrow(completed)) {
          return(NULL)
        }
        return(dplyr::tibble(
          km = row$km, km_label = row$km_label, bm = row$bm, bm_label = row$bm_label,
          sentence_source = src, sentence_number = seq_len(nrow(completed)),
          claim = completed$completed_claim, confidence = completed$confidence
        ))
      }
      if (identical(granularity, "naive_bm")) {
        raw <- segment_bm_by_evidence(sources[[src]])
        if (!nrow(raw)) {
          return(NULL)
        }
        return(dplyr::tibble(
          km = row$km, km_label = row$km_label, bm = row$bm, bm_label = row$bm_label,
          sentence_source = src, sentence_number = seq_len(nrow(raw)),
          claim = raw$claim, confidence = raw$confidence
        ))
      }
      # complete_bm
      raw <- segment_bm_whole(sources[[src]])
      if (!nrow(raw)) {
        return(NULL)
      }
      dplyr::tibble(
        km = row$km, km_label = row$km_label, bm = row$bm, bm_label = row$bm_label,
        sentence_source = src, sentence_number = seq_len(nrow(raw)),
        claim = raw$claim, confidence = raw$confidence
      )
    }))
  }))

  # ── 2. Process each (km, bm) group in parallel, filtering the one
  # unified keypaper table down to that group's own seed ids. ─────────────
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }

  scalar_cols <- c("id", "doi", "title", "abstract", "publication_year")

  # snowball_parquet's keypaper table is now unified (one row per unique
  # seed across the whole assessment, no km/bm split) -- read it once and
  # re-split per (km, bm) via works_parquet's own seed mapping, instead of
  # walking km=/bm= directories that no longer exist.
  seeds <- arrow::open_dataset(works_path) |>
    dplyr::select(km, bm, id) |>
    dplyr::collect() |>
    dplyr::distinct()

  keypapers_all <- arrow::open_dataset(keypaper_path) |>
    dplyr::select(dplyr::any_of(scalar_cols)) |>
    dplyr::collect()

  bm_pairs <- split(seeds, paste(seeds$km, seeds$bm, sep = "\r"))

  results <- parallel::mclapply(bm_pairs, function(pair) {
    km_val <- pair$km[[1L]]
    bm_val <- pair$bm[[1L]]

    sents_bm <- claims[claims$km == km_val & claims$bm == bm_val, , drop = FALSE]
    if (!nrow(sents_bm)) {
      message(sprintf(
        "[NLI_READY_EV_KP %s] %s km=%s / bm=%s: no claims — skipping",
        assessment_id, now(), km_val, bm_val
      ))
      return(NULL)
    }

    works <- keypapers_all |> dplyr::filter(id %in% pair$id)
    if (!nrow(works)) {
      return(NULL)
    }

    for (mc in setdiff(scalar_cols, names(works))) works[[mc]] <- NA
    works <- works |>
      dplyr::mutate(
        dplyr::across(dplyr::any_of(c("id", "doi", "title", "abstract")), as.character),
        publication_year = suppressWarnings(as.integer(publication_year))
      ) |>
      dplyr::rename(work_id = id) |>
      dplyr::mutate(
        premise = trimws(paste(
          dplyr::coalesce(vapply(title, clean_title, character(1L)), ""),
          dplyr::coalesce(vapply(abstract, clean_abstract, character(1L)), "")
        ))
      ) |>
      dplyr::select(work_id, premise)

    out <- dplyr::cross_join(
      sents_bm |> dplyr::select(sentence_source, sentence_number, claim, dplyr::any_of("confidence")),
      works
    ) |>
      dplyr::mutate(
        assessment = assessment_id,
        km = km_val,
        bm = bm_val,
        abstract_tokens = as.integer(round(nchar(premise) / 4)),
        sentence_tokens = as.integer(round(nchar(claim) / 4)),
        approx_tokens = abstract_tokens + sentence_tokens + 3L
      ) |>
      dplyr::select(
        km, bm, sentence_number, claim, sentence_source,
        work_id, premise, abstract_tokens, sentence_tokens, approx_tokens,
        assessment, dplyr::any_of("confidence")
      )

    message(sprintf(
      "[NLI_READY_EV_KP %s] %s km=%s / bm=%s: %d key papers × %d claims = %d rows",
      assessment_id, now(), km_val, bm_val,
      nrow(works), nrow(sents_bm), nrow(out)
    ))

    out
  }, mc.cores = workers)

  # One write for the whole assessment rather than one per (km, bm). The
  # key-paper corpus is small (single-digit MB per assessment), so collecting
  # it costs nothing, while per-km/bm partitioning produced 343 files
  # averaging ~25 KB -- most of which was parquet footer/schema overhead.
  # km and bm stay ordinary columns; nothing filters this dataset on them at
  # the Arrow level (the per-group work above subsets an in-memory frame).
  results <- Filter(function(x) is.data.frame(x) && nrow(x), results)

  if (!length(results)) {
    message(sprintf("[NLI_READY_EV_KP %s] no partitions written", assessment_id))
    return(output_path)
  }

  arrow::write_dataset(
    dataset = dplyr::bind_rows(results),
    path = output_root,
    format = "parquet",
    partitioning = "assessment",
    existing_data_behavior = "overwrite"
  )

  output_path
}
