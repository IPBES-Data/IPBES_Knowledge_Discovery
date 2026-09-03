# Shiny app: dynamic display/download of already-computed QA reports and
# results. Pure read layer over output/ -- never calls targets::tar_make()
# or otherwise triggers new computation. See CLAUDE.md and
# /Users/rkrug/.claude/plans/gleaming-plotting-wirth.md for the design.

repo_root <- normalizePath("..")
setwd(repo_root)

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(DT)
  library(dplyr)
  library(arrow)
  library(ggplot2)
  library(patchwork)
  library(tidyr)
  library(stringr)
  library(digest)
  library(xml2)
  library(readr)
  library(IPBES.R)
})

invisible(lapply(list.files("R", full.names = TRUE), source))
invisible(lapply(list.files("shiny_app/R", full.names = TRUE), source))

addResourcePath(TD_RESOURCE_PATH, file.path(repo_root, "output/reports"))
addResourcePath(BM_EXPLORER_RESOURCE_PATH, file.path(repo_root, "output/tables"))

# Absolute paths, not relative -- Shiny resets the working directory to the
# app directory (shiny_app/) around each session's reactive evaluation, so
# a manifest built from repo-root-relative paths would 404/ENOENT the
# moment any renderXXX() callback (as opposed to this top-level app.R load)
# tries to read one. repo_root is already an absolute path.
manifest <- discover_artifacts(
  tables_dir = file.path(repo_root, "output/tables"),
  figures_dir = file.path(repo_root, "output/figures"),
  reports_dir = file.path(repo_root, "output/reports"),
  training_dir = file.path(repo_root, "output/nli_training")
)

ui <- bslib::page_navbar(
  title = "IPBES BM Fact Checker",
  id = "main_nav",
  # bslib's default Bootstrap 5 base font size (1rem = 16px) renders very
  # large for a dense, table/plot-heavy dashboard like this one -- scaled
  # down globally rather than fixing font-size on individual elements.
  theme = bslib::bs_theme(version = 5, font_size_base = "0.75rem"),
  bslib::nav_panel("QA", value = "qa", mod_qa_ui("qa")),
  bslib::nav_panel("Technical Design", value = "td", mod_td_ui("td")),
  bslib::nav_panel("Additional Reports", value = "reports", mod_reports_ui("reports")),
  bslib::nav_panel("General Reports", value = "general", mod_general_ui("general")),
  bslib::nav_panel("Training Dataset", value = "training", mod_training_ui("training")),
  bslib::nav_panel("Workflow diagram", value = "workflow", mod_workflow_ui("workflow")),
  fillable = TRUE
)

server <- function(input, output, session) {
  nav_state <- shiny::reactiveValues(
    active_tab = NULL, qa = NULL, td = NULL, reports = NULL, general = NULL, training = NULL
  )

  mod_qa_server("qa", manifest, nav_state)
  mod_td_server("td", manifest, nav_state)
  mod_reports_server("reports", manifest, nav_state)
  mod_general_server("general", manifest, nav_state)
  mod_training_server("training", manifest, nav_state)
  mod_workflow_server("workflow", manifest, nav_state, repo_root)

  shiny::observeEvent(nav_state$active_tab, {
    shiny::req(nav_state$active_tab)
    bslib::nav_select(id = "main_nav", selected = nav_state$active_tab, session = session)
  })
}

shiny::shinyApp(ui, server)
