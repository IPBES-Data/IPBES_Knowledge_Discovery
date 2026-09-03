# Training dataset section: (1) a thin reuse of the QA section's
# nli_training_qa treatment, (2) a raw browsable table read straight from
# output/nli_training/ via arrow, filtered lazily before collect() so
# unselected partitions are never read. Displays the new `id` column
# (R/build_nli_training_data.R) and a visibly disabled placeholder "Edit"
# column -- marks where the future label-correction feature attaches
# without building it.

mod_training_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::navset_tab(
    bslib::nav_panel("QA summary",
      bslib::layout_sidebar(
        sidebar = bslib::sidebar(
          width = 280,
          shiny::uiOutput(ns("qa_filters"))
        ),
        shiny::uiOutput(ns("qa_summary")),
        DT::DTOutput(ns("qa_widget"))
      )
    ),
    bslib::nav_panel("Browse raw training pairs",
      bslib::layout_sidebar(
        sidebar = bslib::sidebar(
          width = 280,
          shiny::uiOutput(ns("browse_filters")),
          shiny::downloadButton(ns("download_browse"), "Download filtered rows (CSV)")
        ),
        DT::DTOutput(ns("browse_widget"))
      )
    )
  )
}

mod_training_server <- function(id, manifest, nav_state) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ---- QA summary (reuses build_nli_training_qa_data()'s cached widget) --

    output$qa_filters <- shiny::renderUI({
      df <- manifest$nli_training_qa
      shiny::tagList(
        shiny::selectInput(ns("qa_assessment"), "Assessment", choices = choices_from(df, "assessment")),
        shiny::selectInput(ns("qa_granularity"), "Granularity", choices = choices_from(df, "granularity"))
      )
    })

    qa_data <- shiny::reactive({
      shiny::req(input$qa_assessment, input$qa_granularity)
      df <- manifest$nli_training_qa
      row <- df[df$assessment == input$qa_assessment & df$granularity == input$qa_granularity, ]
      if (!nrow(row)) return(NULL)
      read_first_nonempty(row$path)
    })

    output$qa_summary <- shiny::renderUI({
      x <- qa_data()
      shiny::req(!is.null(x))
      if (isTRUE(x$empty)) return(empty_state())
      shiny::tagList(
        shiny::p(shiny::strong("Rows: "), x$n_total),
        shiny::p(shiny::strong("Label counts: "), paste(names(x$label_counts), x$label_counts, sep = "=", collapse = ", ")),
        shiny::p(shiny::strong("Source counts: "), paste(names(x$source_counts), x$source_counts, sep = "=", collapse = ", ")),
        shiny::p(shiny::strong("Key-paper counts: "), paste(names(x$keypaper_counts), x$keypaper_counts, sep = "=", collapse = ", "))
      )
    })

    output$qa_widget <- DT::renderDT({
      x <- qa_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      x$widget
    })

    # ---- raw browsable table -------------------------------------------------

    output$browse_filters <- shiny::renderUI({
      p <- manifest$training_partitions
      shiny::tagList(
        shiny::selectizeInput(ns("b_assessment"), "Assessment(s)",
          choices = choices_from(p, "assessment"), multiple = TRUE),
        shiny::selectizeInput(ns("b_granularity"), "Granularity", choices = choices_from(p, "granularity"), multiple = TRUE),
        shiny::selectizeInput(ns("b_nli_config"), "NLI config", choices = choices_from(p, "nli_config"), multiple = TRUE),
        shiny::selectizeInput(ns("b_label"), "Label",
          choices = c("SUPPORTS", "NOT_ENOUGH_INFO", "REFUTES"), multiple = TRUE),
        shiny::checkboxInput(ns("b_keypaper"), "Key papers only", value = FALSE)
      )
    })

    browse_data <- shiny::reactive({
      shiny::req(dir.exists(manifest$training_dir))
      ds <- arrow::open_dataset(manifest$training_dir)
      if (length(input$b_assessment)) ds <- dplyr::filter(ds, assessment %in% input$b_assessment)
      if (length(input$b_granularity)) ds <- dplyr::filter(ds, granularity %in% input$b_granularity)
      if (length(input$b_nli_config)) ds <- dplyr::filter(ds, nli_config %in% input$b_nli_config)
      if (length(input$b_label)) ds <- dplyr::filter(ds, label %in% input$b_label)
      out <- ds |> dplyr::collect() |> dplyr::mutate(keypaper = as.logical(keypaper))
      if (isTRUE(input$b_keypaper)) out <- dplyr::filter(out, keypaper)
      out
    })

    output$browse_widget <- DT::renderDT({
      df <- browse_data()
      shiny::req(nrow(df) > 0)
      df$Edit <- '<button class="btn btn-sm btn-outline-secondary" disabled title="Label correction not yet implemented">Edit</button>'
      DT::datatable(
        df, escape = FALSE, filter = "top",
        extensions = c("Buttons", "Scroller"),
        options = list(
          dom = "Bfrtip", buttons = c("csv", "excel"),
          scrollY = "60vh", scroller = TRUE, scrollX = TRUE
        )
      )
    })

    output$download_browse <- shiny::downloadHandler(
      filename = function() "nli_training_data_filtered.csv",
      content = function(file) readr::write_csv(browse_data(), file)
    )

    shiny::observeEvent(nav_state$training, {
      req <- nav_state$training
      shiny::req(req)
    })
  })
}
