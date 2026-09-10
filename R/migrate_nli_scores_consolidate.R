# ONE-TIME migration: collapse Phase 1's per-claim_id partition directories
# into one consolidated parquet per (nli_config, assessment, km, bm) group.
#
# Deliberately NOT wired into _targets.R — it rewrites and moves real scored
# data, the same reason find_orphaned_nli_scores.R is a hand-run utility. Run
# it from an interactive R session.
#
# WHY IT MUST RUN BEFORE THE NEW score_one_claim() CODE IS USED: the new
# resumability check looks for a consolidated file per (km, bm). Against the
# old layout it would find none, conclude "nothing scored yet", and
# re-dispatch the entire corpus at real GPU cost. score_one_claim() does
# guard against exactly this (it stop()s when it sees legacy claim_id=*/
# directories with no consolidated file), but that guard is a safety net, not
# a substitute for running this first.
#
# Layout detail that makes this more than a file concatenation: in the OLD
# layout `claim_id` is a PARTITION level, so it is not stored inside the
# parquet files at all — it exists only in the directory name. The migration
# re-materializes it as a real column (verified: old files carry 11 columns,
# the 16-column output tibble minus the 5 partition columns).
#
# Old directories are MOVED to <output_root>/.premigration/ rather than
# deleted: rollback stays possible, and — importantly — they must not remain
# inside the dataset tree, or every downstream open_dataset() over the
# assessment would read both layouts and double-count.

migrate_nli_scores_consolidate <- function(
  scores_root,
  dry_run = TRUE,
  premigration_dir = NULL
) {
  if (!dir.exists(scores_root)) {
    message(sprintf("[migrate] %s does not exist — nothing to do", scores_root))
    return(invisible(dplyr::tibble()))
  }

  claim_dirs <- grep(
    "/claim_id=[^/]+$",
    list.dirs(scores_root, recursive = TRUE, full.names = TRUE),
    value = TRUE
  )
  claim_dirs <- claim_dirs[
    vapply(claim_dirs, function(d) {
      length(list.files(d, pattern = "\\.parquet$")) > 0L
    }, logical(1))
  ]

  if (!length(claim_dirs)) {
    message(sprintf("[migrate] no legacy claim_id=*/ directories under %s", scores_root))
    return(invisible(dplyr::tibble()))
  }

  # group each claim dir by its parent (the km=/bm= level)
  groups <- split(claim_dirs, dirname(claim_dirs))
  message(sprintf(
    "[migrate] %s: %d legacy claim director%s in %d (km, bm) group(s)%s",
    scores_root, length(claim_dirs),
    if (length(claim_dirs) == 1) "y" else "ies",
    length(groups), if (dry_run) "  [DRY RUN]" else ""
  ))

  report <- vector("list", length(groups))

  for (i in seq_along(groups)) {
    bm_dir <- names(groups)[[i]]
    dirs <- groups[[i]]

    pieces <- lapply(dirs, function(d) {
      cid <- sub("^claim_id=", "", basename(d))
      files <- list.files(d, pattern = "\\.parquet$", full.names = TRUE)
      # open_dataset() (not read_parquet + rbind) so files written
      # independently across runs get their schemas unified.
      tbl <- arrow::open_dataset(files) |> dplyr::collect()
      tbl$claim_id <- cid
      tbl
    })
    merged <- dplyr::bind_rows(pieces)

    src_rows <- sum(vapply(pieces, nrow, integer(1)))
    ok_rows <- nrow(merged) == src_rows

    # Verify claim-text fidelity per claim_id, not just row counts: the whole
    # point of the consolidated file is that score_one_claim() can still find
    # each claim's exact stored text.
    per_claim_src <- vapply(pieces, function(p) {
      if (!nrow(p) || !"claim" %in% names(p)) NA_character_ else as.character(p$claim[[1L]])
    }, character(1))
    names(per_claim_src) <- sub("^claim_id=", "", basename(dirs))
    per_claim_new <- vapply(names(per_claim_src), function(cid) {
      v <- merged$claim[merged$claim_id == cid]
      if (!length(v)) NA_character_ else as.character(v[[1L]])
    }, character(1))
    ok_claims <- identical(unname(per_claim_src), unname(per_claim_new))

    report[[i]] <- dplyr::tibble(
      bm_dir = bm_dir, n_claim_dirs = length(dirs),
      src_rows = src_rows, merged_rows = nrow(merged),
      rows_ok = ok_rows, claims_ok = ok_claims
    )

    if (!ok_rows || !ok_claims) {
      stop(sprintf(
        "[migrate] verification FAILED for %s (rows %d -> %d, rows_ok=%s, claims_ok=%s) — nothing moved",
        bm_dir, src_rows, nrow(merged), ok_rows, ok_claims
      ))
    }

    if (dry_run) next

    out <- merged |> dplyr::select(-dplyr::any_of(nli_scores_path_cols))
    target <- file.path(bm_dir, "part-0.parquet")
    tmp <- paste0(target, ".tmp")
    arrow::write_parquet(out, tmp)
    file.rename(tmp, target)

    # Move (never delete) the legacy directories out of the dataset tree.
    base <- premigration_dir %||% file.path(scores_root, ".premigration")
    for (d in dirs) {
      rel <- sub(paste0("^", scores_root, "/?"), "", d)
      dest <- file.path(base, rel)
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      file.rename(d, dest)
    }
  }

  out <- dplyr::bind_rows(report)
  message(sprintf(
    "[migrate] %s: %d group(s) verified (%d rows total)%s",
    scores_root, nrow(out), sum(out$src_rows),
    if (dry_run) " — DRY RUN, nothing written. Re-run with dry_run = FALSE." else " — consolidated"
  ))
  invisible(out)
}

# Every (granularity, nli_config) combination of both Phase 1 chains, resolving
# each granularity's own config via nli_config_for_granularity() rather than
# assuming nli.active — same reasoning as find_orphaned_nli_scores_all().
migrate_nli_scores_consolidate_all <- function(
  config_path = "input/config.yaml",
  nli_granularities = c("naive_bm", "complete_bm", "atomic_bm"),
  roots = c("output/nli_scores_evidence", "output/nli_scores_evidence_keypaper"),
  dry_run = TRUE
) {
  cfg <- yaml::read_yaml(config_path)
  nli_active <- cfg[["nli"]][["active"]]
  nli_configs_all <- cfg[["nli"]][["configs"]]

  combos <- expand.grid(
    root = roots, granularity = nli_granularities, stringsAsFactors = FALSE
  )

  res <- lapply(seq_len(nrow(combos)), function(i) {
    granularity <- combos$granularity[[i]]
    nli_config_name <- nli_config_for_granularity(nli_configs_all, granularity, nli_active)
    scores_root <- file.path(
      combos$root[[i]], paste0("granularity=", granularity),
      paste0("nli_config=", nli_config_name)
    )
    out <- migrate_nli_scores_consolidate(scores_root, dry_run = dry_run)
    if (nrow(out)) {
      out$root <- combos$root[[i]]
      out$granularity <- granularity
      out$nli_config <- nli_config_name
    }
    out
  })

  dplyr::bind_rows(res)
}
