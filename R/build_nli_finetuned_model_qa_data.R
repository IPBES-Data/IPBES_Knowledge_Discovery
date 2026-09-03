# QA data for the fine-tuned NLI model (scripts/training/train_nli.py, via
# the nli_finetuned_model target) -- sibling to the other QA_*_data
# builders in this project, same "not a scoring result, a progress/sanity
# check" framing. Reads run_results.json, the structured results
# train_nli.py itself writes (classification_report, label/keypaper
# composition, the full per-step loss/eval_loss history) -- NOT
# reconstructed from checkpoint-*/trainer_state.json (which has the loss
# curve but no classification_report at all) or console output (fragile --
# tqdm's carriage-return animation mangles plain print() lines under
# non-interactive capture, confirmed directly this session).
#
# Shapes confirmed directly via jsonlite::read_json(simplifyVector = TRUE)
# against a realistic run_results.json before writing this: classification_report
# stays a nested list (not simplified, since it isn't an array of uniform
# objects) -- extracted below via [["f1-score"]] (literal key, has a hyphen);
# log_history auto-simplifies to a real data.frame (one row per logged
# event, NA-filled for whichever fields that particular event didn't have);
# label_counts/keypaper_counts are named lists, unlist()ed into named vectors.
build_nli_finetuned_model_qa_data <- function(
  run_dir,
  nli_active,
  output_root = "output/tables"
) {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  fn <- file.path(output_root, sprintf("nli_finetuned_model_qa_%s.rds", nli_active))

  results_path <- file.path(run_dir, "run_results.json")
  if (!file.exists(results_path)) {
    # nli_finetuned_model's own train:false disabled-marker path, or a run
    # that failed before it ever got to writing run_results.json.
    saveRDS(list(nli_config = nli_active, empty = TRUE), file = fn)
    return(fn)
  }

  x <- jsonlite::read_json(results_path, simplifyVector = TRUE)

  cls <- x$classification_report
  class_names <- setdiff(names(cls), c("accuracy", "macro avg", "weighted avg"))
  row_for <- function(nm) {
    r <- cls[[nm]]
    dplyr::tibble(
      class = nm,
      precision = round(as.numeric(r$precision), 3),
      recall = round(as.numeric(r$recall), 3),
      f1_score = round(as.numeric(r[["f1-score"]]), 3),
      support = as.integer(r$support)
    )
  }
  classification_df <- dplyr::bind_rows(lapply(c(class_names, "macro avg", "weighted avg"), row_for))

  log_df <- x$log_history
  # Columns present depend on which fields that logged event happened to
  # carry (a training-step log has loss/grad_norm/learning_rate; an
  # eval-step log has eval_loss only) -- keep only what's actually there,
  # in a stable display order, rather than assuming every column exists.
  log_cols <- intersect(
    c("epoch", "step", "loss", "grad_norm", "learning_rate", "eval_loss"),
    names(log_df)
  )
  log_df <- log_df[, log_cols, drop = FALSE]

  eval_curve <- log_df[!is.na(log_df$eval_loss), c("epoch", "eval_loss")]
  eval_curve <- eval_curve[order(eval_curve$epoch), ]
  loss_plot <- if (nrow(eval_curve) > 0) {
    ggplot2::ggplot(eval_curve, ggplot2::aes(x = epoch, y = eval_loss)) +
      ggplot2::geom_line() +
      ggplot2::geom_point(size = 2) +
      ggplot2::labs(title = "Eval loss by epoch", x = "Epoch", y = "Eval loss") +
      ggplot2::theme_minimal()
  } else {
    NULL
  }

  saveRDS(
    list(
      nli_config = nli_active,
      empty = FALSE,
      run_id = x$run_id,
      timestamp = x$timestamp,
      model_id = x$model_id,
      premise_mode = x$premise_mode,
      filters = x$filters,
      n_rows_total = x$n_rows_total,
      n_rows_train = x$n_rows_train,
      n_rows_eval = x$n_rows_eval,
      label_counts = unlist(x$label_counts),
      keypaper_counts = unlist(x$keypaper_counts),
      assessments = x$assessments,
      granularity = x$granularity,
      nli_config_list = x$nli_config,
      accuracy = round(as.numeric(cls$accuracy), 3),
      classification_df = classification_df,
      log_df = log_df,
      loss_plot = loss_plot,
      best_metric = x$best_metric,
      best_model_checkpoint = x$best_model_checkpoint,
      run_dir = run_dir
    ),
    file = fn
  )
  fn
}
