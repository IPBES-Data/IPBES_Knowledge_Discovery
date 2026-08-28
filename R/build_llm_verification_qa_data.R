# QA data for Phase 2 (LLM verification) -- one assessment x llm_config
# combination. Sibling to R/build_nli_scores_qa_data.R (which QAs Phase 1
# scoring); this QAs Phase 2's independent LLM review of NLI-flagged pairs.
#
# Single-active-granularity, NOT cross()'d over nli_granularities like
# nli_scores_qa_data is -- llm_verification_parquet only ever reflects
# whichever granularity is CURRENTLY active (it reads via the single active
# nli_ready_evidence_parquet/nli_active, pattern = map(assessment, ...), no
# cross()), so there is nothing to cross here either.
#
# llm_verification_parquet's own output already carries everything needed
# in one row per reviewed pair (km, bm, claim_id, claim, work_id, nli_label,
# nli_confidence, p_supports/p_refutes/p_nei, direct_evidence_match,
# llm_label, llm_agrees, sufficient_evidence, quote, quote_verbatim,
# explanation) -- no need to re-join Phase 1's scored table. Only
# title/abstract/doi need joining in, from works_citing_parquet for citing
# works and from works_parquet for key papers (key papers are SEED/
# reference works, not in the citing-works dataset).
build_llm_verification_qa_data <- function(
  assessment,
  llm_verification_path,
  works_citing_path,
  llm_active,
  nli_active,
  output_root = "output/tables",
  per_claim_cap = 50L,
  llm_verification_keypaper_path = NULL,
  works_path = NULL
) {
  assessment_id <- assessment$id
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

  fn <- file.path(output_root, sprintf("llm_verification_qa_%s_%s.rds", assessment_id, llm_active))

  # llm_verification_parquet() can return output_path even when nothing was
  # written (zero routed candidates for this assessment) -- check dir.exists()
  # AND that it actually contains .parquet files, same guard pattern
  # tag_direct_evidence_match() already uses, not dir.exists() alone.
  has_data <- function(path) {
    !is.null(path) && dir.exists(path) &&
      length(list.files(path, pattern = "\\.parquet$", recursive = TRUE)) > 0L
  }

  if (!has_data(llm_verification_path)) {
    saveRDS(
      list(assessment = assessment_id, llm_active = llm_active, nli_active = nli_active, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  d <- arrow::open_dataset(llm_verification_path) |>
    dplyr::select(
      km, bm, claim_id, claim, work_id, nli_route,
      nli_label, uncertain, nli_confidence, p_supports, p_refutes, p_nei,
      direct_evidence_match, llm_label, llm_agrees, sufficient_evidence,
      quote, quote_verbatim, explanation
    ) |>
    dplyr::collect()

  if (!nrow(d)) {
    saveRDS(
      list(assessment = assessment_id, llm_active = llm_active, nli_active = nli_active, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  # Confusion matrix comparing the two classifiers on the same pairs -- the
  # natural Phase 2 analogue of Phase 1's label x confidence-decile matrix,
  # since Phase 2 has no numeric confidence of its own to bucket by. Kept in
  # both shapes: `label_flow` (long, nli_label/llm_label/n) is Figure 2's
  # (the alluvial diagram's) direct input; `confusion_matrix` (wide, pivoted)
  # is what the report's summary table renders -- computed once from the
  # same dplyr::count() so the two can never drift apart.
  label_flow <- d |> dplyr::count(nli_label, llm_label)
  matrix_tbl <- label_flow |>
    tidyr::pivot_wider(names_from = llm_label, values_from = n, values_fill = 0) |>
    dplyr::select(nli_label, dplyr::any_of(nli_label_levels)) |>
    dplyr::arrange(factor(nli_label, levels = nli_label_levels))

  # Figure 1 input: per-NLI-confidence-decile agreement rate, on the FULL
  # (uncapped) reviewed set. tidyr::complete() so an empty decile still
  # appears as n = 0 rather than silently vanishing from the line.
  decile_levels <- sprintf("%.1f-%.1f", seq(0, 0.9, 0.1), seq(0.1, 1, 0.1))
  decile_agreement <- d |>
    dplyr::mutate(
      decile = cut(
        nli_confidence, breaks = seq(0, 1, 0.1), include.lowest = TRUE,
        labels = decile_levels
      )
    ) |>
    dplyr::group_by(decile) |>
    dplyr::summarise(n = dplyr::n(), agree_pct = 100 * mean(llm_agrees), .groups = "drop") |>
    tidyr::complete(decile = factor(decile_levels, levels = decile_levels), fill = list(n = 0L, agree_pct = NA_real_))

  # Summary stats for the report's bullet list.
  n_total <- nrow(d)
  llm_agrees_pct <- 100 * mean(d$llm_agrees)
  sufficient_evidence_pct <- 100 * mean(d$sufficient_evidence)
  # quote_verbatim is NA when there's nothing to check (empty quote/no
  # source); FALSE means a quote was supplied but not found verbatim, which
  # is exactly the demotion build_llm_verification_parquet() already
  # applied upstream -- this measures that demotion rate, not a new check.
  quote_verbatim_demotion_pct <- 100 * mean(!is.na(d$quote_verbatim) & !d$quote_verbatim)
  direct_evidence_match_pct <- 100 * mean(d$direct_evidence_match, na.rm = TRUE)

  # Cap per (km, bm, claim_id) -- same never-silent-truncation ethos as
  # nli_scores_qa_data.R: n_total_claim carries the true group size.
  capped <- d |>
    dplyr::group_by(km, bm, claim_id) |>
    dplyr::mutate(n_total_claim = dplyr::n()) |>
    dplyr::arrange(dplyr::desc(nli_confidence), .by_group = TRUE) |>
    dplyr::slice_head(n = per_claim_cap) |>
    dplyr::ungroup()

  work_lookup <- function(path, ids) {
    if (is.null(path) || !length(ids)) {
      return(dplyr::tibble(work_id = character(), doi = character(), title = character(), abstract = character()))
    }
    arrow::open_dataset(path) |>
      dplyr::select(work_id = id, doi, title, abstract) |>
      dplyr::filter(work_id %in% ids) |>
      dplyr::collect() |>
      dplyr::group_by(work_id) |>
      dplyr::summarise(
        doi      = dplyr::first(doi[!is.na(doi)], default = NA_character_),
        title    = dplyr::first(title[!is.na(title)], default = NA_character_),
        abstract = dplyr::first(abstract[!is.na(abstract)], default = NA_character_),
        .groups = "drop"
      )
  }

  capped <- dplyr::left_join(capped, work_lookup(works_citing_path, unique(capped$work_id)), by = "work_id") |>
    dplyr::arrange(km, bm, claim_id, dplyr::desc(nli_confidence))

  widget <- llm_verification_qa_datatable(capped)

  # Key-paper LLM validation -- full-coverage chain
  # (R/build_llm_verification_keypaper_parquet.R), optional: degrades to
  # "no keypaper section" until that chain has actually been run, same
  # empty-state convention Phase 1's own keypaper_scores_path uses.
  keypaper_n <- NULL
  keypaper_llm_supports_pct <- NULL
  keypaper_llm_agrees_pct <- NULL
  keypaper_points <- NULL
  keypaper_agree_ref <- NULL
  keypaper_alluvial <- NULL
  keypaper_flagged_widget <- NULL

  if (has_data(llm_verification_keypaper_path)) {
    kp <- arrow::open_dataset(llm_verification_keypaper_path) |>
      dplyr::select(km, bm, claim_id, work_id, nli_label, nli_confidence, llm_label, llm_agrees, quote, explanation) |>
      dplyr::collect()

    if (nrow(kp)) {
      keypaper_n <- nrow(kp)
      keypaper_llm_supports_pct <- 100 * mean(kp$llm_label == "SUPPORTS")
      keypaper_llm_agrees_pct <- 100 * mean(kp$llm_agrees)

      # Figure 1 overlay: individual key-paper points (own nli_confidence,
      # 100/0 for llm_agrees) plus the aggregate reference line -- same
      # llm_agrees metric as the general-population line in that figure, so
      # the two series are directly comparable on one y-axis. (The
      # "% confirmed SUPPORTS" framing lives in the plain-text summary
      # bullets instead, not mixed into this chart's own metric.)
      keypaper_points <- kp |>
        dplyr::transmute(nli_confidence, y = ifelse(llm_agrees, 100, 0))
      keypaper_agree_ref <- keypaper_llm_agrees_pct

      # Figure 2 overlay: key papers' own nli_label -> llm_label flow.
      keypaper_alluvial <- kp |>
        dplyr::count(nli_label, llm_label)

      # The actionable subset: every key paper the LLM did NOT confirm as
      # SUPPORTS -- since a key paper IS the evidence a BM was written
      # from, any non-SUPPORTS verdict deserves a human look. Uncapped --
      # key papers are a bounded, small set.
      flagged <- kp |>
        dplyr::filter(llm_label != "SUPPORTS") |>
        dplyr::left_join(work_lookup(works_path, unique(kp$work_id[kp$llm_label != "SUPPORTS"])), by = "work_id") |>
        dplyr::arrange(km, bm, claim_id)

      keypaper_flagged_widget <- llm_verification_qa_keypaper_datatable(flagged)
    }
  }

  saveRDS(
    list(
      assessment = assessment_id,
      llm_active = llm_active,
      nli_active = nli_active,
      empty = FALSE,
      n_total = n_total,
      n_shown = nrow(capped),
      per_claim_cap = per_claim_cap,
      llm_agrees_pct = llm_agrees_pct,
      sufficient_evidence_pct = sufficient_evidence_pct,
      quote_verbatim_demotion_pct = quote_verbatim_demotion_pct,
      direct_evidence_match_pct = direct_evidence_match_pct,
      confusion_matrix = matrix_tbl,
      label_flow = label_flow,
      decile_agreement = decile_agreement,
      widget = widget,
      keypaper_n = keypaper_n,
      keypaper_llm_supports_pct = keypaper_llm_supports_pct,
      keypaper_llm_agrees_pct = keypaper_llm_agrees_pct,
      keypaper_points = keypaper_points,
      keypaper_agree_ref = keypaper_agree_ref,
      keypaper_alluvial = keypaper_alluvial,
      keypaper_flagged_widget = keypaper_flagged_widget
    ),
    file = fn
  )

  fn
}

# DT table for the claims x scores view. Called from
# build_llm_verification_qa_data() above (in the targets session, where
# this file is already sourced) -- the resulting widget object is what gets
# cached, not called again later, same reasoning nli_scores_qa_datatable()
# already documents (quarto::quarto_render() runs the qmd in a fresh
# session that never sources R/*.R).
llm_verification_qa_datatable <- function(df) {
  work_link <- function(work_id, doi) {
    id_short <- sub("^https://openalex\\.org/", "", work_id)
    if (!is.na(doi) && nzchar(doi)) {
      doi_short <- sub("^https://doi\\.org/", "", doi)
      sprintf('<a href="%s" target="_blank" rel="noopener">%s</a>', doi, doi_short)
    } else {
      sprintf('<a href="%s" target="_blank" rel="noopener">%s (OpenAlex)</a>', work_id, id_short)
    }
  }

  disp <- df |>
    dplyr::mutate(
      km    = factor(km),
      bm    = factor(bm),
      nli_label = factor(nli_label),
      llm_label = factor(llm_label),
      work  = mapply(work_link, work_id, doi),
      nli_confidence = round(nli_confidence, 3)
    ) |>
    dplyr::select(
      km, bm, claim_id, claim, work, title, abstract,
      nli_label, nli_confidence, llm_label, llm_agrees, sufficient_evidence,
      quote, quote_verbatim, direct_evidence_match, explanation, n_total_claim
    )

  DT::datatable(
    data = disp,
    extensions = c("Buttons", "FixedColumns", "Scroller"),
    filter = "top",
    rownames = FALSE,
    options = list(
      dom = "Bfrtip",
      buttons = list(
        list(extend = "csv", filename = "llm_verification_qa"),
        list(extend = "excel", filename = "llm_verification_qa"),
        "print"
      ),
      scroller = TRUE,
      scrollY = DT::JS("window.innerHeight * 0.7 + 'px'"),
      scrollX = TRUE,
      fixedColumns = list(leftColumns = 3)
    ),
    escape = FALSE
  )
}

# Small, unpaginated DT table for the flagged-key-papers view -- key papers
# are a bounded, small set, so unlike llm_verification_qa_datatable() above
# this is never capped and shows every row without pagination controls.
llm_verification_qa_keypaper_datatable <- function(df) {
  if (!nrow(df)) {
    return(NULL)
  }
  work_link <- function(work_id, doi) {
    id_short <- sub("^https://openalex\\.org/", "", work_id)
    if (!is.na(doi) && nzchar(doi)) {
      doi_short <- sub("^https://doi\\.org/", "", doi)
      sprintf('<a href="%s" target="_blank" rel="noopener">%s</a>', doi, doi_short)
    } else {
      sprintf('<a href="%s" target="_blank" rel="noopener">%s (OpenAlex)</a>', work_id, id_short)
    }
  }

  disp <- df |>
    dplyr::mutate(
      km = factor(km),
      bm = factor(bm),
      nli_label = factor(nli_label),
      llm_label = factor(llm_label),
      work = mapply(work_link, work_id, doi),
      nli_confidence = round(nli_confidence, 3)
    ) |>
    dplyr::select(km, bm, claim_id, work, title, nli_label, nli_confidence, llm_label, quote, explanation)

  DT::datatable(
    data = disp,
    filter = "top",
    rownames = FALSE,
    options = list(paging = FALSE, dom = "ft", scrollX = TRUE),
    escape = FALSE
  )
}
