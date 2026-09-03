# Fine-tunes the active NLI config's model, IF that config's own `train:`
# field is true in input/config.yaml (default false). Wraps
# scripts/training/train_nli.py -- the actual fine-tuning stays a Python
# script (real local CPU time, ~tens of minutes; see that script's own
# module docstring for why CPU, not MPS), this is just the thin bridge
# that lets targets track its output as a real dependency of the report.
#
# `train: false` (the default for every existing config) is NOT skipped by
# not creating a target at all -- it's represented by writing a small,
# real, empty-marker directory and returning that path, same "always
# return something real for format='file'" discipline every other
# conditionally-empty target in this project already uses (e.g.
# build_llm_verification_parquet()'s own empty-candidates branch). This
# means flipping train: true -> false correctly invalidates and replaces
# whatever real model was previously there, and a bare tar_make() never
# accidentally triggers a ~25min local training run just because some
# config happens to be active -- only an explicit train: true does that.
build_nli_finetuned_model <- function(
  train_enabled,
  nli_active,
  downsample_seed = NULL,
  # DAG-dependency-only, never read in this function's body -- train_nli.py
  # reads output/nli_training directly off disk at runtime, not through a
  # targets-tracked value. Its purpose is purely to make targets mark this
  # target outdated whenever nli_training_data changes (any assessment
  # re-extracted, or R/build_nli_training_data.R itself edited), same
  # bare-argument convention nli_scores_qa_data/llm_verification_qa_data
  # already use for their own upstream dependencies.
  nli_training_data_dep = NULL,
  python_bin = "~/.venvs/specter2-merge/bin/python3",
  script_path = "scripts/training/train_nli.py",
  output_root = "output/nli_training_finetuned"
) {
  disabled_path <- file.path(output_root, ".disabled", nli_active)

  if (!isTRUE(train_enabled)) {
    if (dir.exists(disabled_path)) unlink(disabled_path, recursive = TRUE, force = TRUE)
    dir.create(disabled_path, recursive = TRUE, showWarnings = FALSE)
    message(sprintf(
      "[nli_finetuned_model %s] train: false in input/config.yaml -- skipping (no training run)",
      nli_active
    ))
    return(disabled_path)
  }

  python_bin_expanded <- path.expand(python_bin)
  if (!file.exists(python_bin_expanded)) {
    stop(sprintf(
      "build_nli_finetuned_model: python binary not found at %s (edit the python_bin argument in _targets.R if your venv lives elsewhere)",
      python_bin
    ))
  }
  if (!file.exists(script_path)) {
    stop(sprintf("build_nli_finetuned_model: training script not found at %s", script_path))
  }

  message(sprintf(
    "[nli_finetuned_model %s] train: true -- running %s (real local CPU time, ~tens of minutes; see that script's own console output for live progress)",
    nli_active, script_path
  ))

  # stdout/stderr = "" streams live to this session's own console (a ~25min
  # run with no visible progress otherwise) rather than being captured as an
  # R character vector -- confirmed this project's own conventions elsewhere
  # favour visible progress for long real-compute steps. Recovering the
  # run's own timestamped output_dir afterward is therefore done via the
  # sentinel file the script itself writes (output_root/.last_run_dir.txt),
  # not by parsing captured stdout.
  cli_args <- c(shQuote(script_path), "--nli-config", shQuote(nli_active))
  if (!is.null(downsample_seed)) {
    cli_args <- c(cli_args, "--downsample-seed", shQuote(as.character(as.integer(downsample_seed))))
  }
  status <- system2(python_bin_expanded, args = cli_args, stdout = "", stderr = "")
  if (!identical(status, 0L)) {
    stop(sprintf(
      "build_nli_finetuned_model: train_nli.py failed (exit status %s) for nli_config=%s",
      status, nli_active
    ))
  }

  sentinel <- file.path(output_root, ".last_run_dir.txt")
  if (!file.exists(sentinel)) {
    stop(sprintf(
      "build_nli_finetuned_model: train_nli.py exited 0 but left no %s -- cannot recover the run's output_dir",
      sentinel
    ))
  }
  run_dir <- readLines(sentinel, warn = FALSE)[[1]]

  if (!dir.exists(run_dir)) {
    stop(sprintf(
      "build_nli_finetuned_model: %s named a run_dir that doesn't exist: %s",
      sentinel, run_dir
    ))
  }
  if (!file.exists(file.path(run_dir, "run_results.json"))) {
    stop(sprintf(
      "build_nli_finetuned_model: %s has no run_results.json -- train_nli.py may have failed partway through",
      run_dir
    ))
  }

  # A stale disabled-marker from a PREVIOUS train:false state would otherwise
  # sit around forever once a config switches to train:true -- clean it up
  # so it can't be mistaken for a live result.
  if (dir.exists(disabled_path)) unlink(disabled_path, recursive = TRUE, force = TRUE)

  message(sprintf("[nli_finetuned_model %s] wrote %s", nli_active, run_dir))
  run_dir
}
