# QA data for the NLI fine-tuning training set (build_nli_training_data.R) --
# sibling to build_llm_verification_qa_data.R/build_nli_scores_qa_data.R:
# same "not a scoring result, a sanity check" framing, same
# cached-RDS-holding-a-prebuilt-DT-widget convention (quarto::quarto_render()
# runs the report qmd in a fresh session that never sources R/*.R, so the
# widget must be built and cached here, not in the qmd).
#
# granularity/nli_config/assessment are passed in explicitly rather than
# read back out of the training data's own columns, so the empty-state case
# (nothing to export for this combination) can still report which
# combination that was.
build_nli_training_qa_data <- function(
  nli_training_data_path,
  assessment_id,
  nli_active,
  granularity,
  output_root = "output/tables"
) {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

  fn <- file.path(
    output_root,
    sprintf("nli_training_qa_%s_%s_%s.rds", assessment_id, nli_active, granularity)
  )

  has_data <- function(path) {
    !is.null(path) && dir.exists(path) &&
      length(list.files(path, pattern = "\\.parquet$", recursive = TRUE)) > 0L
  }

  if (!has_data(nli_training_data_path)) {
    saveRDS(
      list(assessment = assessment_id, nli_config = nli_active, granularity = granularity, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  d <- arrow::open_dataset(nli_training_data_path) |> dplyr::collect()

  if (!nrow(d)) {
    saveRDS(
      list(assessment = assessment_id, nli_config = nli_active, granularity = granularity, empty = TRUE),
      file = fn
    )
    return(fn)
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

  # "assessment" is never select()ed by bare name -- nli_training_data_path
  # is already scoped INSIDE its own `assessment=<id>/` hive partition
  # directory, so Arrow doesn't reconstruct that segment as a column when
  # reading at that path level (confirmed directly: "Column `assessment`
  # doesn't exist"), same partition-above-the-dataset-root issue
  # build_nli_training_data.R hit for `llm_config`. Added back via
  # mutate(assessment = assessment_id) using the parameter already passed
  # in, rather than read from the data.
  # keypaper is a hive-partition segment (keypaper=true/keypaper=false), so
  # Arrow reconstructs it as the literal partition-directory STRING "true"/
  # "false", not a real logical -- confirmed directly (as.logical() handles
  # both cases/spellings fine, so this is a one-line fix, not a workaround).
  disp <- d |>
    dplyr::mutate(
      assessment = assessment_id,
      km = factor(km),
      bm = factor(bm),
      label = factor(label),
      source = factor(source),
      keypaper = factor(as.logical(keypaper)),
      work = mapply(work_link, work_id, doi),
      nli_confidence = round(nli_confidence, 3)
    ) |>
    dplyr::select(
      assessment, km, bm, label, source, keypaper, hypothesis, quote, work, title, abstract,
      llm_config, nli_label, nli_confidence
    )

  widget <- DT::datatable(
    data = disp,
    extensions = c("Buttons", "Scroller"),
    filter = "top",
    rownames = FALSE,
    options = list(
      dom = "Bfrtip",
      buttons = list(
        list(extend = "csv", filename = "nli_training_qa"),
        list(extend = "excel", filename = "nli_training_qa"),
        "print"
      ),
      scroller = TRUE,
      scrollY = "70vh",
      scrollX = TRUE
    ),
    escape = FALSE
  )

  label_counts <- d |> dplyr::count(label) |> tibble::deframe()
  source_counts <- d |> dplyr::count(source) |> tibble::deframe()
  keypaper_counts <- d |> dplyr::mutate(keypaper = as.logical(keypaper)) |> dplyr::count(keypaper) |> tibble::deframe()

  saveRDS(
    list(
      assessment = assessment_id,
      nli_config = nli_active,
      granularity = granularity,
      empty = FALSE,
      n_total = nrow(d),
      label_counts = label_counts,
      source_counts = source_counts,
      keypaper_counts = keypaper_counts,
      widget = widget
    ),
    file = fn
  )

  fn
}
