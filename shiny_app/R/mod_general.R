# General reports: the REFUTES/SUPPORTS label funnel -- the user's own named
# example of a question-focused report. Label + multi-select assessment +
# granularity filters. A single selected assessment shows the cached funnel
# PNGs plus a natively-rebuilt level-3 detail table; multiple assessments
# combine into one comparison plot (plot_helpers.R) plus a download of the
# combined underlying data.

mod_general_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 320,
      shiny::radioButtons(ns("label"), "Label", choices = c("REFUTES", "SUPPORTS")),
      shiny::uiOutput(ns("filters"))
    ),
    shiny::uiOutput(ns("content"))
  )
}

mod_general_server <- function(id, manifest, nav_state) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    data_manifest <- shiny::reactive({
      shiny::req(input$label)
      if (input$label == "REFUTES") manifest$refutes_funnel_data else manifest$supports_funnel_data
    })

    output$filters <- shiny::renderUI({
      df <- data_manifest()
      shiny::tagList(
        shiny::selectizeInput(ns("assessment"), "Assessment(s)",
          choices = choices_from(df, "assessment"), multiple = TRUE,
          selected = utils::head(choices_from(df, "assessment"), 1)),
        shiny::selectInput(ns("granularity"), "Granularity", choices = choices_from(df, "granularity"))
      )
    })

    selected_rows <- shiny::reactive({
      shiny::req(input$assessment, input$granularity)
      df <- data_manifest()
      df[df$assessment %in% input$assessment & df$granularity == input$granularity, ]
    })

    selected_objs <- shiny::reactive({
      rows <- selected_rows()
      shiny::req(nrow(rows) > 0)
      objs <- stats::setNames(lapply(rows$path, read_rds_safe), rows$assessment)
      Filter(function(x) !is.null(x) && !isTRUE(x$empty), objs)
    })

    # ---- single-assessment view: cached PNGs + native level-3 table --------

    figure_manifest <- shiny::reactive({
      if (identical(input$label, "REFUTES")) manifest$refutes_funnel_figures else manifest$supports_funnel_figures
    })

    single_figs <- shiny::reactive({
      objs <- selected_objs()
      shiny::req(length(objs) == 1)
      fdf <- figure_manifest()
      row <- fdf[fdf$assessment == names(objs) & fdf$granularity == input$granularity, ]
      shiny::req(nrow(row) > 0)
      funnel_figure_siblings(row$path[[1]])
    })

    render_fig <- function(name) shiny::renderImage({
      figs <- single_figs()
      shiny::req(file.exists(figs[[name]]))
      list(src = figs[[name]], contentType = "image/png", width = "100%")
    }, deleteFile = FALSE)

    output$fig_overall <- render_fig("overall")
    output$fig_by_bm <- render_fig("by_bm")
    output$fig_by_bm_norm <- render_fig("by_bm_normalized")

    l3_table_manifest <- shiny::reactive({
      if (identical(input$label, "REFUTES")) manifest$refutes_funnel_table_l3 else manifest$supports_funnel_table_l3
    })

    output$l3_widget <- DT::renderDT({
      objs <- selected_objs()
      shiny::req(length(objs) == 1)
      tdf <- l3_table_manifest()
      row <- tdf[tdf$assessment == names(objs) & tdf$granularity == input$granularity, ]
      shiny::req(nrow(row) > 0)
      l3 <- readRDS(row$path[[1]])
      IPBES.R::table_dt(l3, fixedColumns = list(leftColumns = 2))
    })

    # ---- multi-assessment view: combined plot + download --------------------

    output$combined_overall <- shiny::renderPlot({
      objs <- selected_objs()
      shiny::req(length(objs) > 1)
      combined_funnel_overall_plot(lapply(objs, `[[`, "funnel_overall"), input$label)
    }, res = 96)

    output$combined_by_bm <- shiny::renderPlot({
      objs <- selected_objs()
      shiny::req(length(objs) > 1)
      combined_funnel_by_bm_plot(lapply(objs, `[[`, "funnel_by_bm"), lapply(objs, `[[`, "funnel_overall"))
    }, res = 96)

    output$download_combined <- shiny::downloadHandler(
      filename = function() sprintf("%s_funnel_%s_%s.csv", tolower(input$label %||% "refutes"),
        paste(input$assessment, collapse = "-"), input$granularity %||% "na"),
      content = function(file) {
        objs <- selected_objs()
        readr::write_csv(dplyr::bind_rows(lapply(objs, `[[`, "funnel_by_bm"), .id = "assessment"), file)
      }
    )

    output$content <- shiny::renderUI({
      objs <- selected_objs()
      if (!length(objs)) return(empty_state())
      if (length(objs) == 1) {
        shiny::tagList(
          shiny::h4(sprintf("%s funnel -- %s", input$label, names(objs))),
          shiny::imageOutput(ns("fig_overall"), height = "220px"),
          bslib::layout_columns(
            shiny::imageOutput(ns("fig_by_bm"), height = "420px"),
            shiny::imageOutput(ns("fig_by_bm_norm"), height = "420px")
          ),
          shiny::h4("Level 3 detail: LLM-confirmed matches"),
          DT::DTOutput(ns("l3_widget"))
        )
      } else {
        shiny::tagList(
          shiny::h4(sprintf("%s funnel -- comparing %d assessments", input$label, length(objs))),
          shiny::plotOutput(ns("combined_overall"), height = sprintf("%dpx", 160 * length(objs))),
          shiny::plotOutput(ns("combined_by_bm"), height = "500px"),
          shiny::downloadButton(ns("download_combined"), "Download combined by-BM data (CSV)")
        )
      }
    })

    shiny::observeEvent(nav_state$general, {
      req <- nav_state$general
      shiny::req(req)
      shiny::updateRadioButtons(session, "label", selected = req$label %||% "REFUTES")
    })
  })
}
