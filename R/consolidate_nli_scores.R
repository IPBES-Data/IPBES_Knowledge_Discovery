# Merge Phase 1's per-claim scratch files into one consolidated parquet per
# (nli_config, assessment, km, bm) group, and prune claims that no longer
# exist upstream.
#
# score_one_claim() deliberately writes each claim to its own scratch file
# (see that file's header for why): every branch owns a uniquely-named file,
# so scoring stays lock-free and embarrassingly parallel. The cost of a
# larger consolidated file — a full read + rewrite — is then paid ONCE per
# (km, bm) per run here, rather than once per claim, which is what makes the
# consolidated layout affordable at all.
#
# Orphan pruning lives here too. A claim_id that no longer exists upstream (a
# re-segmented BM, a renumbered sentence) was previously invisible:
# score_one_claim() only ever inspects its own claim, so a stale claim_id's
# rows persisted indefinitely and kept contributing to nli_overview_data and
# the funnel targets, which open_dataset() the whole tree unfiltered — only
# the manual find_orphaned_nli_scores() ever caught it. Consolidation is the
# natural place to fix that: the file is being rewritten anyway and the
# authoritative claim list is already a target.
#
# Deleting scored data costs real GPU time to recreate, so pruning is guarded:
# an empty upstream claim list for a group, or a prune that would remove more
# than `max_prune_fraction` of its rows, is treated as an upstream failure and
# stop()s rather than being carried out. Same caution find_orphaned_nli_scores()
# embodies with its delete = FALSE default.

# Columns encoded in the consolidated file's Hive path, therefore dropped from
# the file itself (Arrow re-materializes them on read; leaving them in the
# file would collide with the path-derived ones).
nli_scores_path_cols <- c("nli_config", "assessment", "km", "bm")

# Read parquet files that were written WITHOUT their Hive path columns, by
# explicit path — never open_dataset() on the directory, so a leftover
# legacy claim_id=*/ subdirectory can't be picked up as a partition level.
read_consolidated_group <- function(files) {
  if (!length(files)) {
    return(NULL)
  }
  tryCatch(
    arrow::open_dataset(files) |> dplyr::collect(),
    error = function(e) {
      stop(sprintf(
        "failed reading consolidated parquet (%s): %s",
        paste(basename(files), collapse = ", "), conditionMessage(e)
      ))
    }
  )
}

consolidate_nli_scores <- function(
  scored_records,
  claim_units,
  output_root,
  nli_active,
  max_prune_fraction = 0.5
) {
  # ---- current (authoritative) claim list ---------------------------------
  cu <- Filter(Negate(is.null), claim_units)
  current <- dplyr::bind_rows(lapply(cu, function(u) {
    dplyr::tibble(
      assessment = u$assessment, km = u$km, bm = u$bm, claim_id = u$claim_id
    )
  }))
  current_key <- if (nrow(current)) {
    paste(current$assessment, current$km, current$bm, current$claim_id, sep = "\r")
  } else {
    character(0)
  }
  current_group <- if (nrow(current)) {
    unique(paste(current$assessment, current$km, current$bm, sep = "\r"))
  } else {
    character(0)
  }

  # ---- groups to visit ----------------------------------------------------
  # The union of (a) groups this run wrote scratch for, (b) groups already on
  # disk and (c) groups in the current claim list. (b) matters specifically
  # for orphan pruning: a (km, bm) whose claims ALL disappeared upstream
  # produces no scratch and appears in no claim list, so visiting only (a)
  # and (c) would leave its rows on disk forever.
  recs <- Filter(function(r) is.list(r) && !is.null(r$km), scored_records)

  scratch_root <- file.path(output_root, ".scratch", paste0("nli_config=", nli_active))
  disk_root <- file.path(output_root, paste0("nli_config=", nli_active))

  groups_from <- function(root) {
    if (!dir.exists(root)) {
      return(character(0))
    }
    dirs <- list.dirs(root, recursive = TRUE, full.names = TRUE)
    dirs <- grep("/assessment=[^/]+/km=[^/]+/bm=[^/]+$", dirs, value = TRUE)
    vapply(dirs, function(d) {
      p <- strsplit(d, "/", fixed = TRUE)[[1]]
      paste(
        sub("^assessment=", "", p[grepl("^assessment=", p)][[1L]]),
        sub("^km=", "", p[grepl("^km=", p)][[1L]]),
        sub("^bm=", "", p[grepl("^bm=", p)][[1L]]),
        sep = "\r"
      )
    }, character(1), USE.NAMES = FALSE)
  }

  groups <- unique(c(
    if (length(recs)) vapply(recs, function(r) paste(r$assessment, r$km, r$bm, sep = "\r"), character(1)) else character(0),
    groups_from(disk_root),
    groups_from(scratch_root),
    current_group
  ))

  if (!length(groups)) {
    message(sprintf("[NLI consolidate %s] nothing to consolidate", nli_active))
    dir.create(disk_root, recursive = TRUE, showWarnings = FALSE)
    return(disk_root)
  }

  n_written <- 0L
  n_pruned_total <- 0L

  for (g in groups) {
    parts <- strsplit(g, "\r", fixed = TRUE)[[1]]
    assessment_id <- parts[[1L]]
    km_val <- parts[[2L]]
    bm_val <- parts[[3L]]

    bm_dir <- file.path(
      disk_root, paste0("assessment=", assessment_id),
      paste0("km=", km_val), paste0("bm=", bm_val)
    )
    scratch_dir <- file.path(
      scratch_root, paste0("assessment=", assessment_id),
      paste0("km=", km_val), paste0("bm=", bm_val)
    )

    existing_files <- if (dir.exists(bm_dir)) {
      list.files(bm_dir, pattern = "\\.parquet$", full.names = TRUE)
    } else {
      character(0)
    }
    scratch_files <- if (dir.exists(scratch_dir)) {
      list.files(scratch_dir, pattern = "\\.parquet$", full.names = TRUE)
    } else {
      character(0)
    }

    old <- read_consolidated_group(existing_files)
    new <- if (length(scratch_files)) {
      dplyr::bind_rows(lapply(scratch_files, arrow::read_parquet)) |>
        dplyr::select(-dplyr::any_of(nli_scores_path_cols))
    } else {
      NULL
    }

    if (is.null(old) && is.null(new)) {
      next
    }

    # Rows for a claim_id present in scratch are superseded by it.
    if (!is.null(old) && !is.null(new)) {
      old <- old[!(old$claim_id %in% unique(new$claim_id)), , drop = FALSE]
    }
    merged <- dplyr::bind_rows(old, new)
    if (!nrow(merged)) {
      next
    }

    # ---- orphan pruning, guarded ------------------------------------------
    keep <- paste(assessment_id, km_val, bm_val, merged$claim_id, sep = "\r") %in% current_key
    n_prune <- sum(!keep)

    if (n_prune) {
      group_in_current <- g %in% current_group
      frac <- n_prune / nrow(merged)

      if (!group_in_current) {
        stop(sprintf(
          paste0(
            "[NLI consolidate] assessment=%s km=%s bm=%s has %d scored row(s) but the current ",
            "claim list contains NO claims for this group at all. Refusing to delete: this is ",
            "far more likely an upstream failure (empty/failed nli_ready_evidence_parquet) than ",
            "a genuine removal. Inspect with find_orphaned_nli_scores_all(), then re-run."
          ),
          assessment_id, km_val, bm_val, nrow(merged)
        ))
      }
      if (frac > max_prune_fraction) {
        stop(sprintf(
          paste0(
            "[NLI consolidate] assessment=%s km=%s bm=%s: pruning would drop %d/%d rows (%.1f%%), ",
            "above max_prune_fraction = %.2f. Refusing — verify the upstream claim list is correct ",
            "(find_orphaned_nli_scores_all()), then re-run with a higher threshold if genuinely intended."
          ),
          assessment_id, km_val, bm_val, n_prune, nrow(merged), 100 * frac, max_prune_fraction
        ))
      }

      dropped <- unique(merged$claim_id[!keep])
      message(sprintf(
        "[NLI consolidate] assessment=%s km=%s bm=%s: pruning %d orphaned row(s) across claim_id(s): %s",
        assessment_id, km_val, bm_val, n_prune, paste(dropped, collapse = ", ")
      ))
      merged <- merged[keep, , drop = FALSE]
      n_pruned_total <- n_pruned_total + n_prune
    }

    if (!nrow(merged)) {
      # Everything pruned and nothing left: remove the group's file rather
      # than leaving a zero-row parquet behind.
      unlink(existing_files, force = TRUE)
      unlink(scratch_files, force = TRUE)
      next
    }

    merged <- merged |> dplyr::select(-dplyr::any_of(nli_scores_path_cols))

    dir.create(bm_dir, recursive = TRUE, showWarnings = FALSE)
    target <- file.path(bm_dir, "part-0.parquet")
    tmp <- paste0(target, ".tmp")
    arrow::write_parquet(merged, tmp)
    # Write-temp-then-rename: an interrupted merge must never leave a
    # half-written consolidated file where the complete one used to be.
    file.rename(tmp, target)
    # Any other pre-existing file in the group (e.g. part-1 from an older
    # write) is now superseded by the single merged one.
    stale <- setdiff(existing_files, target)
    if (length(stale)) unlink(stale, force = TRUE)
    unlink(scratch_files, force = TRUE)
    n_written <- n_written + 1L
  }

  # Scratch dirs are left behind empty by unlink(); clear them so the tree
  # doesn't accumulate thousands of empty directories. Only ever removes a
  # subtree that holds no parquet at all, so a scratch file belonging to a
  # group this call didn't visit is never destroyed.
  for (d in c(scratch_root, file.path(output_root, ".scratch"))) {
    if (dir.exists(d) &&
      !length(list.files(d, pattern = "\\.parquet$", recursive = TRUE))) {
      unlink(d, recursive = TRUE, force = TRUE)
    }
  }

  message(sprintf(
    "[NLI consolidate %s] %d group(s) written%s",
    nli_active, n_written,
    if (n_pruned_total) sprintf(", %d orphaned row(s) pruned", n_pruned_total) else ""
  ))

  disk_root
}
