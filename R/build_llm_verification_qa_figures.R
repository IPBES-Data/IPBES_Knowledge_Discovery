# Two static PNGs for build_llm_verification_qa_data()'s output -- QA
# figures for Phase 2 (LLM verification), sibling to
# R/build_nli_scores_qa_figures.R (Phase 1's ternary QA figure). A literal
# ternary plot was considered and rejected for Phase 2: the LLM emits one
# categorical verdict, not a 3-part probability composition, so a simplex
# density would really just be NLI's own chart wearing a Phase-2 label.
# These two figures are built from what Phase 2 actually produces instead
# (llm_agrees, llm_label, nli_label, nli_confidence), each carrying a
# key-paper overlay analogous to Phase 1's ternary keypaper overlay -- same
# validation message, more honest chart form. Deliberately does NOT modify
# R/build_nli_scores_qa_figures.R or nli_scores_qa_ternary_plot() -- same
# "duplicate, don't call" discipline protecting Phase-1-adjacent
# (explicitly locked) code from unrelated invalidation.
build_llm_verification_qa_figures <- function(llm_verification_qa_data_path, output_root = "output/figures") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  x <- readRDS(llm_verification_qa_data_path)

  if (isTRUE(x$empty)) {
    return(character(0))
  }

  fn_decile <- file.path(
    output_root,
    sprintf("llm_verification_qa_decile_%s_%s.png", x$assessment, x$llm_active)
  )
  ggplot2::ggsave(
    fn_decile,
    llm_verification_qa_decile_plot(x$decile_agreement, x$keypaper_points, x$keypaper_agree_ref),
    width = 7.5, height = 5, bg = "white"
  )

  fn_alluvial <- file.path(
    output_root,
    sprintf("llm_verification_qa_alluvial_%s_%s.png", x$assessment, x$llm_active)
  )
  ggplot2::ggsave(
    fn_alluvial,
    llm_verification_qa_alluvial_plot(x$label_flow, x$keypaper_alluvial),
    width = 10.5, height = 5.5, bg = "white"
  )

  c(fn_decile, fn_alluvial)
}

# Figure 1: NLI-confidence-decile agreement line. X = NLI confidence decile
# midpoint (same binning Phase 1's own confusion matrix already uses, so
# it's directly comparable). Y = % of LLM-reviewed pairs in that decile
# where llm_agrees == TRUE. Point size encodes n so a reader can see which
# deciles the line is well-supported at vs. thin.
#
# Key-paper overlay uses the SAME metric (llm_agrees), not a different one
# (e.g. "% SUPPORTS") -- individual jittered points at each key paper's own
# nli_confidence, plus a single dashed reference line at their aggregate
# agreement rate, so the two series are directly comparable on one y-axis.
# The "% confirmed SUPPORTS" framing lives in the report's plain-text
# summary bullets instead (see build_llm_verification_qa_data.R), not mixed
# into this chart's metric.
llm_verification_qa_decile_plot <- function(decile_agreement, keypaper_points = NULL, keypaper_agree_ref = NULL) {
  decile_levels <- sprintf("%.1f-%.1f", seq(0, 0.9, 0.1), seq(0.1, 1, 0.1))
  decile_mid <- stats::setNames(seq(0.05, 0.95, 0.1), decile_levels)

  line_df <- decile_agreement
  line_df$x <- decile_mid[as.character(line_df$decile)]

  p <- ggplot2::ggplot() +
    ggplot2::geom_line(
      data = line_df, ggplot2::aes(x = x, y = agree_pct),
      colour = "#0072B2", linewidth = 0.9, na.rm = TRUE
    ) +
    ggplot2::geom_point(
      data = line_df, ggplot2::aes(x = x, y = agree_pct, size = n),
      colour = "#0072B2", na.rm = TRUE
    ) +
    ggplot2::scale_size_continuous(name = "n pairs", range = c(1, 7)) +
    ggplot2::scale_x_continuous(
      name = "NLI confidence (decile midpoint)", limits = c(0, 1), breaks = seq(0, 1, 0.2)
    ) +
    ggplot2::scale_y_continuous(
      name = "% of LLM-reviewed pairs where llm_label agrees with NLI's label",
      limits = c(0, 100)
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(legend.position = "right")

  if (!is.null(keypaper_points) && nrow(keypaper_points)) {
    p <- p +
      ggplot2::geom_jitter(
        data = keypaper_points, ggplot2::aes(x = nli_confidence, y = y),
        width = 0.012, height = 3, alpha = 0.35, size = 1.6, colour = "#D55E00", shape = 16,
        na.rm = TRUE
      )
  }
  if (!is.null(keypaper_agree_ref)) {
    p <- p +
      ggplot2::geom_hline(
        yintercept = keypaper_agree_ref, colour = "#D55E00", linetype = "dashed", linewidth = 0.6
      ) +
      ggplot2::annotate(
        "text", x = 1, y = keypaper_agree_ref, hjust = 1, vjust = -0.6,
        label = sprintf("key papers: %.1f%% LLM/NLI agreement", keypaper_agree_ref),
        colour = "#D55E00", size = 3.1, fontface = "bold"
      )
  }
  p
}

# Figure 2: NLI-label -> LLM-label alluvial (Sankey-style) diagram. Band
# width = pair count flowing from each nli_label to each llm_label (the
# exact same 3x3 contingency the report's confusion-matrix table already
# shows), coloured by agreement (nli_label == llm_label) vs. disagreement.
# Shows the same information the table gives, but the PROPORTIONAL picture
# reads faster from a flow diagram than from a table of raw counts.
#
# Key papers get their own SIDE-BY-SIDE mini-alluvial rather than an
# overlaid second flow on the same axes: their own n is typically orders of
# magnitude smaller than the full reviewed corpus, so a flow scaled to the
# main plot's y-axis would be visually invisible; a separate panel with its
# own n-scale keeps their transitions readable, patchwork::wrap_plots()
# combining the two side by side.
llm_verification_qa_alluvial_plot <- function(label_flow, keypaper_alluvial = NULL) {
  single_alluvial <- function(df, subtitle) {
    df$nli_label <- factor(df$nli_label, levels = nli_label_levels)
    df$llm_label <- factor(df$llm_label, levels = nli_label_levels)
    df$agreement <- ifelse(df$nli_label == df$llm_label, "agree", "disagree")

    ggplot2::ggplot(df, ggplot2::aes(axis1 = nli_label, axis2 = llm_label, y = n)) +
      ggalluvial::geom_alluvium(ggplot2::aes(fill = agreement), width = 1 / 6, alpha = 0.85) +
      ggalluvial::geom_stratum(width = 1 / 6, fill = "grey92", colour = "grey40") +
      ggplot2::geom_text(
        stat = ggalluvial::StatStratum,
        ggplot2::aes(label = ggplot2::after_stat(stratum)),
        size = 2.4, na.rm = TRUE
      ) +
      ggplot2::scale_x_discrete(
        limits = c("NLI label", "LLM label"), expand = c(0.16, 0.05)
      ) +
      ggplot2::scale_fill_manual(
        values = c(agree = "#009E73", disagree = "#D55E00"), name = NULL
      ) +
      ggplot2::labs(subtitle = subtitle) +
      ggplot2::theme_minimal(base_size = 11) +
      ggplot2::theme(
        axis.title.y = ggplot2::element_blank(),
        axis.text.y = ggplot2::element_blank(),
        panel.grid = ggplot2::element_blank()
      )
  }

  p_main <- single_alluvial(
    label_flow, sprintf("All reviewed pairs (n=%s)", format(sum(label_flow$n), big.mark = ","))
  )

  if (is.null(keypaper_alluvial) || !nrow(keypaper_alluvial)) {
    return(p_main + ggplot2::theme(legend.position = "bottom"))
  }

  p_kp <- single_alluvial(
    keypaper_alluvial, sprintf("Key papers (n=%s)", format(sum(keypaper_alluvial$n), big.mark = ","))
  )

  patchwork::wrap_plots(p_main, p_kp, nrow = 1, widths = c(1.6, 1.3)) +
    patchwork::plot_layout(guides = "collect") &
    ggplot2::theme(legend.position = "bottom")
}
