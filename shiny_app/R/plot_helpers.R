# Multi-assessment comparison plots for the General Reports (REFUTES/
# SUPPORTS funnel) tab. These are new, but deliberately reuse
# R/build_label_funnel_figures.R's own geom_col()/color/theme choices --
# only the faceting-by-assessment dimension is new. Small, tidy categorical
# summaries facet cleanly, unlike the ternary QA plot's per-dataset kde2d()
# density (see mod_qa.R for that call-once-per-selection + patchwork pattern
# instead).

combined_funnel_overall_plot <- function(funnel_overall_by_assessment, label) {
  level_order <- rev(funnel_overall_by_assessment[[1]]$label)
  df <- dplyr::bind_rows(funnel_overall_by_assessment, .id = "assessment") |>
    dplyr::mutate(level_label = factor(label, levels = level_order)) |>
    dplyr::group_by(assessment) |>
    dplyr::mutate(pct = round(100 * n / n[level == "level1"], 1)) |>
    dplyr::ungroup()

  ggplot2::ggplot(df, ggplot2::aes(x = n, y = level_label)) +
    ggplot2::geom_col(fill = nli_label_colors[[label]], width = 0.6) +
    ggplot2::geom_text(
      ggplot2::aes(label = sprintf("%s (%s%%)", format(n, big.mark = ","), pct)),
      hjust = -0.05, size = 3
    ) +
    ggplot2::facet_wrap(~assessment, ncol = 1, scales = "free_x") +
    ggplot2::scale_x_continuous(expand = ggplot2::expansion(mult = c(0, 0.3))) +
    ggplot2::labs(x = "distinct citing works", y = NULL) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid.major.y = ggplot2::element_blank())
}

# Normalized (not raw-count) by-BM comparison -- raw counts aren't
# comparable across assessments of very different corpus size, but each
# BM's own fraction-of-its-own-corpus is.
combined_funnel_by_bm_plot <- function(funnel_by_bm_by_assessment, funnel_overall_by_assessment) {
  level_key <- stats::setNames(
    funnel_overall_by_assessment[[1]]$label,
    sub("^level", "n", funnel_overall_by_assessment[[1]]$level)
  )
  level1_label <- funnel_overall_by_assessment[[1]]$label[funnel_overall_by_assessment[[1]]$level == "level1"]

  df <- dplyr::bind_rows(funnel_by_bm_by_assessment, .id = "assessment") |>
    tidyr::pivot_longer(c(n1, n2, n3), names_to = "level", values_to = "n") |>
    dplyr::mutate(level = factor(dplyr::recode(level, !!!level_key), levels = funnel_overall_by_assessment[[1]]$label)) |>
    dplyr::group_by(assessment, km, bm) |>
    dplyr::mutate(frac = n / n[level == level1_label]) |>
    dplyr::ungroup()

  ggplot2::ggplot(df, ggplot2::aes(x = bm, y = frac, fill = level)) +
    ggplot2::geom_col(position = "dodge", width = 0.8) +
    ggplot2::geom_hline(yintercept = 1, linetype = "dashed", linewidth = 0.4) +
    ggplot2::facet_grid(assessment ~ km, scales = "free_x", space = "free_x") +
    ggplot2::scale_y_continuous(limits = c(0, 1), expand = ggplot2::expansion(mult = c(0, 0.05))) +
    ggplot2::scale_fill_brewer(palette = "OrRd") +
    ggplot2::labs(x = NULL, y = "fraction of BM's own snowball corpus", fill = NULL) +
    ggplot2::theme_bw(base_size = 9) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1),
      legend.position = "bottom"
    )
}
