# QA section: nli_scores / llm_verification / training_data / finetuned_model
# / bm_split. One report-type selector at the top drives which manifest
# table feeds the filters below it. Cached DT widgets / ggplot objects are
# reused directly wherever the underlying build_*_qa_data.R already built
# one; only the ternary QA plot is re-plotted (via its own already-existing
# plotting function) when more than one assessment is selected, since its
# kde2d() density estimate is inherently per-dataset and can't be combined
# by pooling raw probabilities.

mod_qa_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 320,
      shiny::selectInput(
        ns("report_type"), "QA report",
        choices = c(
          "NLI scores (Phase 1)" = "nli_scores",
          "LLM verification (Phase 2)" = "llm_verification",
          "Training data export" = "training_data",
          "Fine-tuned model" = "finetuned_model",
          "BM claim segmentation" = "bm_split"
        )
      ),
      shiny::uiOutput(ns("filters"))
    ),
    shiny::uiOutput(ns("content"))
  )
}

mod_qa_server <- function(id, manifest, nav_state) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ---- filter UI, one block per report type -----------------------------
    output$filters <- shiny::renderUI({
      shiny::req(input$report_type)
      switch(input$report_type,
        nli_scores = {
          df <- manifest$nli_scores_qa
          shiny::tagList(
            shiny::selectizeInput(ns("nli_scores_assessment"), "Assessment(s)",
              choices = choices_from(df, "assessment"), multiple = TRUE,
              selected = utils::head(choices_from(df, "assessment"), 1)),
            shiny::selectInput(ns("nli_scores_granularity"), "Granularity",
              choices = choices_from(df, "granularity"))
          )
        },
        llm_verification = {
          df <- manifest$llm_verification_qa
          shiny::tagList(
            shiny::selectizeInput(ns("llmv_assessment"), "Assessment(s)",
              choices = choices_from(df, "assessment"), multiple = TRUE,
              selected = utils::head(choices_from(df, "assessment"), 1)),
            shiny::selectInput(ns("llmv_config"), "LLM config",
              choices = choices_from(df, "config_suffix"))
          )
        },
        training_data = {
          df <- manifest$nli_training_qa
          shiny::tagList(
            shiny::selectInput(ns("train_assessment"), "Assessment",
              choices = choices_from(df, "assessment")),
            shiny::selectInput(ns("train_granularity"), "Granularity",
              choices = choices_from(df, "granularity"))
          )
        },
        finetuned_model = {
          df <- manifest$nli_finetuned_model_qa
          shiny::selectInput(ns("ft_config"), "Model / nli config",
            choices = choices_from(df, "config_suffix"))
        },
        bm_split = {
          df <- manifest$bm_split
          shiny::tagList(
            shiny::selectInput(ns("split_assessment"), "Assessment",
              choices = choices_from(df, "assessment")),
            shiny::selectInput(ns("split_granularity"), "Granularity",
              choices = choices_from(df, "granularity"))
          )
        }
      )
    })

    # ---- nli_scores ---------------------------------------------------------

    nli_scores_paths <- shiny::reactive({
      shiny::req(input$nli_scores_assessment, input$nli_scores_granularity)
      df <- manifest$nli_scores_qa
      df[df$assessment %in% input$nli_scores_assessment &
           df$granularity == input$nli_scores_granularity, ]
    })

    nli_scores_focus <- shiny::reactive({
      p <- nli_scores_paths()
      if (!nrow(p)) return(NULL)
      read_first_nonempty(p$path)
    })

    output$nli_scores_widget <- DT::renderDT({
      x <- nli_scores_focus()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      x$widget
    })

    # Single assessment: reuse the already-built PNG (renderImage) --
    # nli_scores_qa_ternary_plot()'s MASS::kde2d() runs a 220x220-grid
    # density estimate over the FULL scored corpus (500K+ rows for
    # atomic_bm), confirmed directly to take real, non-trivial time; there
    # is no reason to pay that cost live when nothing about the plot
    # differs from what build_nli_scores_qa_figures() already cached.
    # Only a genuine multi-assessment comparison (no pre-built combined PNG
    # can exist for that) calls the plotting function live.
    nli_scores_ternary_single <- shiny::reactive({
      p <- nli_scores_paths()
      shiny::req(nrow(p) == 1)
      fdf <- manifest$nli_scores_qa_figures
      row <- fdf[fdf$assessment == p$assessment[[1]] & fdf$granularity == p$granularity[[1]], ]
      if (!nrow(row)) return(NULL)
      row$path[[1]]
    })

    output$nli_scores_ternary_img <- shiny::renderImage({
      f <- nli_scores_ternary_single()
      shiny::req(!is.null(f), file.exists(f))
      list(src = f, contentType = "image/png", width = "100%")
    }, deleteFile = FALSE)

    output$nli_scores_ternary_multi <- shiny::renderPlot({
      p <- nli_scores_paths()
      shiny::req(nrow(p) > 1)
      objs <- lapply(p$path, read_rds_safe)
      objs <- Filter(function(x) !is.null(x) && !isTRUE(x$empty), objs)
      shiny::req(length(objs) > 1)
      plots <- lapply(objs, function(x) {
        nli_scores_qa_ternary_plot(
          x$probs, x$label_pct,
          keypaper_points = x$keypaper_points,
          keypaper_label_pct = x$keypaper_label_pct,
          keypaper_label_pvalue = x$keypaper_label_pvalue,
          uncertain_threshold = x$uncertain_threshold
        ) + ggplot2::labs(subtitle = x$assessment)
      })
      patchwork::wrap_plots(plots)
    }, res = 96)

    # ---- llm_verification -----------------------------------------------

    llmv_paths <- shiny::reactive({
      shiny::req(input$llmv_assessment, input$llmv_config)
      df <- manifest$llm_verification_qa
      df[df$assessment %in% input$llmv_assessment &
           df$config_suffix == input$llmv_config, ]
    })

    llmv_focus <- shiny::reactive({
      p <- llmv_paths()
      if (!nrow(p)) return(NULL)
      read_first_nonempty(p$path)
    })

    output$llmv_widget <- DT::renderDT({
      x <- llmv_focus()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      x$widget
    })

    output$llmv_decile <- shiny::renderPlot({
      p <- llmv_paths()
      shiny::req(nrow(p) > 0)
      objs <- Filter(function(x) !is.null(x) && !isTRUE(x$empty), lapply(p$path, read_rds_safe))
      shiny::req(length(objs) > 0)
      plots <- lapply(objs, function(x) {
        llm_verification_qa_decile_plot(x$decile_agreement, x$keypaper_points, x$keypaper_agree_ref) +
          ggplot2::labs(subtitle = x$assessment)
      })
      if (length(plots) == 1) plots[[1]] else patchwork::wrap_plots(plots)
    }, res = 96)

    output$llmv_alluvial <- shiny::renderPlot({
      x <- llmv_focus()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      llm_verification_qa_alluvial_plot(x$label_flow, x$keypaper_alluvial)
    }, res = 96)

    output$llmv_keypaper_widget <- DT::renderDT({
      x <- llmv_focus()
      shiny::req(!is.null(x), !isTRUE(x$empty), !is.null(x$keypaper_flagged_widget))
      x$keypaper_flagged_widget
    })

    # ---- training_data ------------------------------------------------------

    train_data <- shiny::reactive({
      shiny::req(input$train_assessment, input$train_granularity)
      df <- manifest$nli_training_qa
      row <- df[df$assessment == input$train_assessment &
                  df$granularity == input$train_granularity, ]
      if (!nrow(row)) return(NULL)
      read_first_nonempty(row$path)
    })

    output$train_widget <- DT::renderDT({
      x <- train_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      x$widget
    })

    output$train_summary <- shiny::renderUI({
      x <- train_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      shiny::tagList(
        shiny::p(shiny::strong("Rows: "), x$n_total),
        shiny::p(shiny::strong("Label counts: "), paste(names(x$label_counts), x$label_counts, sep = "=", collapse = ", ")),
        shiny::p(shiny::strong("Source counts: "), paste(names(x$source_counts), x$source_counts, sep = "=", collapse = ", ")),
        shiny::p(shiny::strong("Key-paper counts: "), paste(names(x$keypaper_counts), x$keypaper_counts, sep = "=", collapse = ", "))
      )
    })

    # ---- finetuned_model ------------------------------------------------

    ft_data <- shiny::reactive({
      shiny::req(input$ft_config)
      df <- manifest$nli_finetuned_model_qa
      row <- df[df$config_suffix == input$ft_config, ]
      if (!nrow(row)) return(NULL)
      read_first_nonempty(row$path)
    })

    output$ft_summary <- shiny::renderUI({
      x <- ft_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      shiny::tagList(
        shiny::p(shiny::strong("Run: "), x$run_id, " (", x$timestamp, ")"),
        shiny::p(shiny::strong("Model: "), x$model_id),
        shiny::p(shiny::strong("Accuracy: "), x$accuracy),
        shiny::p(shiny::strong("Rows: "), x$n_rows_total, " (train ", x$n_rows_train, " / eval ", x$n_rows_eval, ")"),
        shiny::p(shiny::strong("Assessments: "), paste(x$assessments, collapse = ", ")),
        shiny::p(shiny::strong("Granularity: "), x$granularity),
        shiny::p(shiny::strong("Best metric: "), x$best_metric)
      )
    })

    output$ft_loss_plot <- shiny::renderPlot({
      x <- ft_data()
      shiny::req(!is.null(x), !isTRUE(x$empty), !is.null(x$loss_plot))
      x$loss_plot
    }, res = 96)

    output$ft_classification <- DT::renderDT({
      x <- ft_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      DT::datatable(x$classification_df, options = list(dom = "t", paging = FALSE))
    })

    output$ft_log <- DT::renderDT({
      x <- ft_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      DT::datatable(x$log_df)
    })

    # ---- bm_split -------------------------------------------------------

    split_data <- shiny::reactive({
      shiny::req(input$split_assessment, input$split_granularity)
      df <- manifest$bm_split
      row <- df[df$assessment == input$split_assessment &
                  df$granularity == input$split_granularity, ]
      if (!nrow(row)) return(NULL)
      read_first_nonempty(row$path)
    })

    output$split_html <- shiny::renderUI({
      x <- split_data()
      shiny::req(!is.null(x))
      html <- if (is.list(x) && !is.null(x$html)) x$html else x
      shiny::HTML(html)
    })

    # ---- content router -----------------------------------------------------

    output$content <- shiny::renderUI({
      shiny::req(input$report_type)
      switch(input$report_type,
        nli_scores = shiny::tagList(
          shiny::h4("Score distribution (ternary)"),
          if (length(input$nli_scores_assessment) > 1) {
            shiny::plotOutput(ns("nli_scores_ternary_multi"), height = sprintf("%dpx", 420 * length(input$nli_scores_assessment)))
          } else {
            shiny::imageOutput(ns("nli_scores_ternary_img"), height = "560px")
          },
          shiny::h4("Scored pairs (capped per claim)"),
          DT::DTOutput(ns("nli_scores_widget"))
        ),
        llm_verification = shiny::tagList(
          bslib::layout_columns(
            shiny::plotOutput(ns("llmv_decile"), height = "420px"),
            shiny::plotOutput(ns("llmv_alluvial"), height = "420px")
          ),
          shiny::h4("Reviewed pairs (capped per claim)"),
          DT::DTOutput(ns("llmv_widget")),
          shiny::h4("Key papers not confirmed SUPPORTS"),
          DT::DTOutput(ns("llmv_keypaper_widget"))
        ),
        training_data = shiny::tagList(
          shiny::uiOutput(ns("train_summary")),
          DT::DTOutput(ns("train_widget"))
        ),
        finetuned_model = shiny::tagList(
          shiny::uiOutput(ns("ft_summary")),
          shiny::plotOutput(ns("ft_loss_plot"), height = "360px"),
          shiny::h4("Classification report"),
          DT::DTOutput(ns("ft_classification")),
          shiny::h4("Training log"),
          DT::DTOutput(ns("ft_log"))
        ),
        bm_split = shiny::uiOutput(ns("split_html"))
      )
    })

    # ---- workflow-diagram navigation: set filters from an external node click
    shiny::observeEvent(nav_state$qa, {
      req <- nav_state$qa
      shiny::req(req)
      shiny::updateSelectInput(session, "report_type", selected = req$report_type %||% "nli_scores")
    })
  })
}
