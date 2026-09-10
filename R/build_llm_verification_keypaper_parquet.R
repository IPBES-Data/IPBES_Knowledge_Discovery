# Full-coverage LLM verification of key/seed papers -- QA sanity check,
# NOT the main Phase 2 corpus. Key papers (the actual seed/reference works
# IPBES cites as evidence for a BM -- same `relation == "keypaper"`
# snowball set as works_parquet) are a small, bounded, high-importance set:
# every one is worth an independent LLM check, regardless of what NLI
# predicted -- unlike the main citing-works corpus (millions of rows, hence
# the nli_labels/nli_certainty routing that exists there purely for cost
# control). This chain reviews ALL of them, irrespective of nli label or
# confidence.
#
# Structural sibling of build_llm_verification_parquet()
# (R/build_llm_verification_parquet.R) -- same "separate file, don't touch
# the delicate already-working builder" precedent
# R/build_nli_ready_evidence_keypaper_parquet.R already documents for its
# own Phase-1 counterpart, and doubly justified here since that function
# was only just stabilized (a pair_id collision fix) and shouldn't be
# touched again for an unrelated variant.
#
# Reuses (calls, does not duplicate) the small generic helpers already in
# R/build_llm_verification_parquet.R -- build_llm_verification_chat(),
# llm_verification_output_type(), normalise_llm_verification(),
# quote_is_verbatim(), render_template(), load_text_file(),
# nli_route_label(), and select_llm_verification_candidates() itself, which
# is already fully path-parameterized (not hardcoded to the citing-works
# tree) and already supports "no filter" via nli_labels = NULL,
# nli_certainty = NULL. The chunking/run_pairs()/retry/cache-write/
# output-assembly orchestration loop IS duplicated (adapted to the keypaper
# paths) rather than reusing build_llm_verification_parquet()'s own body,
# same reasoning.
#
# No direct_evidence_match tagging: that concept (does a CITING work trace
# back to a seed reference matching the claim's evidence braces) doesn't
# apply to a key paper, which IS a seed reference itself. Column omitted
# from this chain's output schema rather than a meaningless always-FALSE/NA
# placeholder.
build_llm_verification_keypaper_parquet <- function(
  assessment,
  nli_ready_keypaper_path,
  nli_scores_keypaper_path,
  nli_active,
  llm_active,
  cfg,
  system_prompt_file,
  user_prompt_file,
  nli_scores_keypaper_evidence = NULL, # unused -- establishes the DAG dependency on the key-paper NLI scoring chain
  cache_dir = "output/llm_verification/raw_keypaper",
  output_root = "output/llm_verification/scores_keypaper"
) {
  assessment_id <- assessment$id

  # Never collides with or invalidates the main citing-works output tree --
  # own root, same reasoning nli_scores_evidence_keypaper/
  # nli_ready_evidence_keypaper already use relative to their citing-works
  # counterparts.
  output_path <- file.path(
    output_root, paste0("llm_config=", llm_active),
    paste0("assessment=", assessment_id)
  )

  # Reviews EVERY key paper's NLI-scored pair, irrespective of nli_labels/
  # nli_certainty -- the whole point of this chain. Reuses
  # select_llm_verification_candidates() unchanged: it's already fully
  # path-parameterized and already supports "no filter" via NULL/NULL.
  candidates <- select_llm_verification_candidates(
    nli_scores_keypaper_path, nli_ready_keypaper_path,
    nli_labels = NULL, nli_certainty = NULL
  )
  if (!nrow(candidates)) {
    message(sprintf("[LLM verify keypaper %s] no key-paper pairs to review", assessment_id))
    # format = "file" targets require the returned path to actually exist --
    # see build_llm_verification_parquet()'s own identical fix for why.
    if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    return(output_path)
  }
  message(sprintf(
    "[LLM verify keypaper %s] %d key-paper pair(s) to review (all of them, regardless of nli label/confidence)",
    assessment_id, nrow(candidates)
  ))

  api_key <- Sys.getenv("API_openrouter")
  if (!nzchar(api_key)) {
    stop("API_openrouter environment variable is required (set from keyring in _targets.R)")
  }

  system_prompt <- load_text_file(system_prompt_file)
  user_template <- load_text_file(user_prompt_file)

  # Same hash discipline as the main chain -- covers prompts + schema, so
  # editing either starts a fresh cache namespace. Deliberately shares the
  # SAME prompt/schema hash space as the main chain would for identical
  # prompts (this is the same conceptual task, "does this text support the
  # claim"), but never the same cache DIRECTORY (own cache_dir root below),
  # so there is no possibility of a citing-work cache entry and a key-paper
  # cache entry colliding even if their pair_id ever happened to match.
  prompt_hash <- substr(
    digest::digest(
      list(
        system_prompt, user_template,
        paste(utils::capture.output(print(llm_verification_output_type())), collapse = "\n")
      ),
      algo = "xxhash64"
    ),
    1, 12
  )
  model_part <- gsub("[^A-Za-z0-9._-]", "_", cfg$model)
  model_cache <- file.path(
    cache_dir, paste0("model=", model_part), paste0("prompt=", prompt_hash),
    paste0("assessment=", sanitize_partition_value(assessment_id))
  )
  dir.create(model_cache, recursive = TRUE, showWarnings = FALSE)
  message(sprintf("[LLM verify keypaper %s] cache namespace: %s", assessment_id, model_cache))

  # pair_id (km/bm/claim_id/work_id, from select_llm_verification_candidates())
  # is already collision-safe within this assessment; sanitize_partition_value()
  # (R/branch_helpers.R) handles work_id's embedded "/" for the file path,
  # same as the main chain.
  cache_path <- function(id) file.path(model_cache, paste0(sanitize_partition_value(id), ".json"))
  cached <- file.exists(cache_path(candidates$pair_id))
  message(sprintf(
    "[LLM verify keypaper %s] %d pair(s), %d already cached, %d to call",
    assessment_id, nrow(candidates), sum(cached), sum(!cached)
  ))

  chat <- build_llm_verification_chat(cfg, system_prompt, api_key)
  type <- llm_verification_output_type()
  max_active <- as.integer(cfg$max_active %||% 8L)
  chunk_size <- max(1L, max_active * 10L)

  run_pairs <- function(idx) {
    prompts <- vapply(idx, function(i) {
      render_template(user_template, list(
        BM_TEXT        = candidates$claim[[i]],
        TITLE_ABSTRACT = candidates$premise[[i]],
        NLI_LABEL      = candidates$nli_label[[i]],
        NLI_CONFIDENCE = sprintf("%.2f", candidates$nli_confidence[[i]]),
        P_SUPPORTS     = sprintf("%.2f", candidates$p_supports[[i]]),
        P_REFUTES      = sprintf("%.2f", candidates$p_refutes[[i]]),
        P_NEI          = sprintf("%.2f", candidates$p_nei[[i]])
      ))
    }, character(1))

    starts <- seq(1, length(prompts), by = chunk_size)
    for (ci in seq_along(starts)) {
      lo <- starts[[ci]]
      hi <- min(lo + chunk_size - 1L, length(prompts))
      message(sprintf(
        "[LLM verify keypaper %s]   chunk %d/%d (pairs %d-%d of %d)",
        assessment_id, ci, length(starts), lo, hi, length(prompts)
      ))

      res <- tryCatch(
        ellmer::parallel_chat_structured(
          chat, as.list(prompts[lo:hi]),
          type = type, convert = TRUE, max_active = max_active, on_error = "continue"
        ),
        error = function(e) {
          message("    parallel_chat_structured failed: ", conditionMessage(e))
          NULL
        }
      )

      for (j in seq_len(hi - lo + 1L)) {
        i <- idx[[lo + j - 1L]]
        raw <- NULL
        if (!is.null(res) && nrow(res) >= j) {
          raw <- tryCatch(as.list(res[j, , drop = FALSE]), error = function(e) NULL)
        }
        err <- NULL
        if (!is.null(raw) && ".error" %in% names(raw)) {
          e <- raw[[".error"]]
          if (is.list(e) && length(e) == 1L) e <- e[[1]]
          if (!is.null(e)) {
            err <- tryCatch(conditionMessage(e), error = function(...) {
              paste(utils::capture.output(print(e)), collapse = " ")
            })
          }
          raw[[".error"]] <- NULL
        }
        parsed <- if (!is.null(err) && nzchar(err)) {
          normalise_llm_verification(NULL, reason = paste("LLM call failed:", err))
        } else {
          normalise_llm_verification(raw)
        }
        jsonlite::write_json(parsed, cache_path(candidates$pair_id[[i]]), auto_unbox = TRUE, na = "null")
      }
    }
  }

  todo <- which(!cached)
  if (length(todo)) run_pairs(todo)

  # Same tightened retry discipline as the main chain: first pass scans
  # every candidate (catches both pairs just run above and anything left
  # failed = TRUE from an earlier interrupted run); subsequent passes only
  # re-check the set just retried.
  failed_ids <- function(check = candidates$pair_id) {
    bad <- vapply(check, function(id) {
      p <- cache_path(id)
      if (!file.exists(p)) return(FALSE)
      r <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
      is.null(r) || !("failed" %in% names(r)) || isTRUE(any(as.logical(r$failed)))
    }, logical(1))
    match(check[bad], candidates$pair_id)
  }

  max_retries <- as.integer(cfg$max_retries %||% 2L)
  if (max_retries > 0L) {
    bad <- failed_ids()
    for (attempt in seq_len(max_retries)) {
      if (!length(bad)) break
      message(sprintf(
        "[LLM verify keypaper %s]   retry %d/%d: %d pair(s) failed -- usually transient",
        assessment_id, attempt, max_retries, length(bad)
      ))
      run_pairs(bad)
      bad <- failed_ids(candidates$pair_id[bad])
    }
  }

  verdicts <- dplyr::bind_rows(lapply(candidates$pair_id, function(id) {
    p <- cache_path(id)
    if (!file.exists(p)) return(NULL)
    r <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
    if (is.null(r)) return(NULL)
    r$pair_id <- id
    dplyr::as_tibble(r)
  }))

  if (!nrow(verdicts)) {
    stop(sprintf("[LLM verify keypaper %s] no verdicts were produced.", assessment_id))
  }

  missing_ids <- setdiff(candidates$pair_id, verdicts$pair_id)
  if (length(missing_ids)) {
    warning(sprintf(
      "[LLM verify keypaper %s] %d candidate pair(s) never produced a cache entry at all -- dropped from output: %s%s",
      assessment_id, length(missing_ids),
      paste(utils::head(missing_ids, 5), collapse = ", "),
      if (length(missing_ids) > 5) ", ..." else ""
    ), call. = FALSE)
  }

  failed_n <- sum(verdicts$failed)
  if (failed_n) {
    frac <- failed_n / nrow(verdicts)
    msg <- sprintf(
      "[LLM verify keypaper %s] %d of %d pair(s) (%.0f%%) produced no parseable response from '%s'.",
      assessment_id, failed_n, nrow(verdicts), 100 * frac, cfg$model
    )
    if (frac >= 0.5) {
      stop(msg, " This is a model/plumbing failure, not conservative abstention.", call. = FALSE)
    }
    warning(msg, " Recorded with failed = TRUE and NOT counted as abstentions.", call. = FALSE)
  }

  out <- dplyr::inner_join(candidates, verdicts, by = "pair_id")

  out$quote_verbatim <- mapply(quote_is_verbatim, out$quote, out$premise)
  bogus <- out$sufficient_evidence & !is.na(out$quote_verbatim) & !out$quote_verbatim
  if (any(bogus)) {
    message(sprintf(
      "[LLM verify keypaper %s]   %d quote(s) not found verbatim in the source text -- demoted",
      assessment_id, sum(bogus)
    ))
    out$sufficient_evidence[bogus] <- FALSE
    out$llm_label[bogus] <- "NOT_ENOUGH_INFO"
    out$explanation[bogus] <- paste(
      "Not enough data (cited quote does not appear in the supplied text).",
      out$explanation[bogus]
    )
  }

  out$llm_agrees <- out$llm_label == out$nli_label
  out$llm_config <- llm_active
  out$llm_model <- cfg$model
  out$nli_config <- nli_active
  out$assessment <- assessment_id

  out <- out |>
    dplyr::select(
      llm_config, nli_config, assessment, nli_route, km, bm, claim_id, work_id, claim,
      nli_label, uncertain, nli_confidence, p_supports, p_refutes, p_nei,
      llm_model, llm_label, llm_agrees, sufficient_evidence,
      quote, quote_verbatim, explanation
    )

  # Partitioned to nli_route, NOT down to km/bm: the key-paper corpus is
  # small and bounded, so km/bm partitioning produced 688 files averaging
  # ~145 KB, of which roughly 4.4 KB each is pure parquet footer/schema
  # overhead. km and bm remain ordinary columns, and nothing filters this
  # dataset on them at the Arrow level (nli_route IS filtered on -- see
  # build_label_funnel_data.R -- so that level stays).
  if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
  arrow::write_dataset(
    dataset = out,
    path = output_root,
    format = "parquet",
    partitioning = c("llm_config", "assessment", "nli_route"),
    existing_data_behavior = "delete_matching"
  )

  message(sprintf(
    "[LLM verify keypaper %s] wrote %d verified row(s) to %s", assessment_id, nrow(out), output_path
  ))
  output_path
}
