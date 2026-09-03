# Technical Design docs: static prose with no underlying data/widget to
# reconstruct, so served via addResourcePath() + <iframe> over the existing
# rendered output/reports/TD_*.html -- the one deliberate exception (besides
# nli_bm_explorer, see mod_reports.R) to native reconstruction, since there
# is nothing to reconstruct.

TD_RESOURCE_PATH <- "td_reports"

mod_td_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(width = 280, shiny::uiOutput(ns("picker"))),
    shiny::uiOutput(ns("frame"))
  )
}

mod_td_server <- function(id, manifest, nav_state) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    output$picker <- shiny::renderUI({
      df <- manifest$td_docs
      shiny::req(nrow(df) > 0)
      shiny::radioButtons(ns("doc"), "Design document",
        choices = stats::setNames(basename(df$path), df$title))
    })

    output$frame <- shiny::renderUI({
      shiny::req(input$doc)
      shiny::tags$iframe(
        src = file.path(TD_RESOURCE_PATH, input$doc),
        style = "width:100%; height:85vh; border:none;"
      )
    })

    shiny::observeEvent(nav_state$td, {
      req <- nav_state$td
      shiny::req(req$file)
      shiny::updateRadioButtons(session, "doc", selected = req$file)
    })
  })
}
