# "Additional reports" section: overlap tables, the NLI overview
# (label/confidence/alignment summaries + static figures), the publication-
# per-year figure, and the nli_bm_explorer widget -- the second deliberate
# iframe exception (see mod_td.R for the first): it's already a fully
# self-contained, fully interactive plotly+DT widget with its own
# client-side filtering, so reconstructing it natively would duplicate,
# not add, functionality.

BM_EXPLORER_RESOURCE_PATH <- "bm_explorer"

nli_overview_figure_paths <- function(data_path) {
  base <- sub("nli_overview_data_", "nli_overview_%s_", data_path)
  base <- sub("\\.rds$", ".png", base)
  base <- sub("output/tables/", "output/figures/", base)
  stats::setNames(
    sprintf(base, c("overall", "km", "bm", "conf", "aln")),
    c("overall", "km", "bm", "conf", "aln")
  )
}

mod_reports_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::navset_tab(
    id = ns("subtab"),
    bslib::nav_panel("Overlap tables",
      bslib::navset_pill(
        bslib::nav_panel("Key papers cited by >1 BM", DT::DTOutput(ns("overlap_key_paper"))),
        bslib::nav_panel("Sub-messages, post-2018 citing works", DT::DTOutput(ns("overlap_sub_messages"))),
        bslib::nav_panel("Background messages, post-2018 citing works", DT::DTOutput(ns("overlap_background_messages")))
      )
    ),
    bslib::nav_panel("NLI overview",
      bslib::layout_sidebar(
        sidebar = bslib::sidebar(width = 280, shiny::uiOutput(ns("overview_filters"))),
        shiny::uiOutput(ns("overview_content"))
      )
    ),
    bslib::nav_panel("Publications per year", shiny::plotOutput(ns("pub_per_year"), height = "500px")),
    bslib::nav_panel("BM explorer (interactive)",
      bslib::layout_sidebar(
        sidebar = bslib::sidebar(width = 280, shiny::uiOutput(ns("explorer_picker"))),
        shiny::uiOutput(ns("explorer_frame"))
      )
    )
  )
}

mod_reports_server <- function(id, manifest, nav_state) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ---- overlap tables ---------------------------------------------------

    output$overlap_key_paper <- DT::renderDT({
      shiny::req(!is.na(manifest$overlap_key_paper_rds))
      df <- readRDS(manifest$overlap_key_paper_rds)
      IPBES.R::table_dt(df, fixedColumns = list(leftColumns = 2))
    })
    output$overlap_sub_messages <- DT::renderDT({
      shiny::req(!is.na(manifest$overlap_sub_messages_rds))
      df <- readRDS(manifest$overlap_sub_messages_rds)
      IPBES.R::table_dt(df, fixedColumns = list(leftColumns = 2))
    })
    output$overlap_background_messages <- DT::renderDT({
      shiny::req(!is.na(manifest$overlap_background_messages_rds))
      df <- readRDS(manifest$overlap_background_messages_rds)
      IPBES.R::table_dt(df, fixedColumns = list(leftColumns = 2))
    })

    # ---- NLI overview -------------------------------------------------------

    output$overview_filters <- shiny::renderUI({
      df <- manifest$nli_overview_data
      shiny::tagList(
        shiny::selectInput(ns("ov_assessment"), "Assessment", choices = choices_from(df, "assessment")),
        shiny::selectInput(ns("ov_granularity"), "Granularity", choices = choices_from(df, "granularity"))
      )
    })

    overview_row <- shiny::reactive({
      shiny::req(input$ov_assessment, input$ov_granularity)
      df <- manifest$nli_overview_data
      df[df$assessment == input$ov_assessment & df$granularity == input$ov_granularity, ]
    })

    overview_data <- shiny::reactive({
      r <- overview_row()
      if (!nrow(r)) return(NULL)
      read_first_nonempty(r$path)
    })

    # The specific on-disk path actually behind overview_data()'s object --
    # not just overview_row()$path[[1]] -- so the figures shown always
    # match the summary stats/table shown, even when multiple candidate
    # files exist for the same (assessment, granularity) (see
    # read_first_nonempty()'s own comment).
    overview_path <- shiny::reactive({
      r <- overview_row()
      shiny::req(nrow(r) > 0)
      for (p in r$path) {
        x <- read_rds_safe(p)
        if (!is.null(x) && !isTRUE(x$empty)) return(p)
      }
      r$path[[1]]
    })

    output$overview_content <- shiny::renderUI({
      x <- overview_data()
      shiny::req(!is.null(x))
      if (isTRUE(x$empty)) return(empty_state())
      figs <- nli_overview_figure_paths(overview_path())
      shiny::tagList(
        shiny::p(shiny::strong("Total pairs: "), x$n_total, " across ", x$n_bm, " BMs / ", x$n_km, " KMs"),
        shiny::p(shiny::strong("Uncertain: "), sprintf("%.1f%%", x$pct_unc)),
        bslib::layout_columns(
          shiny::imageOutput(ns("ov_overall"), height = "320px"),
          shiny::imageOutput(ns("ov_conf"), height = "320px")
        ),
        bslib::layout_columns(
          shiny::imageOutput(ns("ov_km"), height = "320px"),
          shiny::imageOutput(ns("ov_aln"), height = "320px")
        ),
        shiny::h4("Per-BM label distribution (%)"),
        DT::DTOutput(ns("ov_table_bm"))
      )
    })

    render_ov_img <- function(name) shiny::renderImage({
      figs <- nli_overview_figure_paths(overview_path())
      shiny::req(file.exists(figs[[name]]))
      list(src = figs[[name]], contentType = "image/png", width = "100%")
    }, deleteFile = FALSE)

    output$ov_overall <- render_ov_img("overall")
    output$ov_km <- render_ov_img("km")
    output$ov_conf <- render_ov_img("conf")
    output$ov_aln <- render_ov_img("aln")

    output$ov_table_bm <- DT::renderDT({
      x <- overview_data()
      shiny::req(!is.null(x), !isTRUE(x$empty))
      DT::datatable(x$table_bm, options = list(pageLength = 15))
    })

    # ---- publications per year ---------------------------------------------

    output$pub_per_year <- shiny::renderImage({
      shiny::req(!is.na(manifest$fig_pub_per_year))
      list(src = manifest$fig_pub_per_year, contentType = "image/png", width = "100%")
    }, deleteFile = FALSE)

    # ---- BM explorer (iframe exception) -------------------------------------

    output$explorer_picker <- shiny::renderUI({
      df <- manifest$nli_bm_explorer
      shiny::req(nrow(df) > 0)
      shiny::selectInput(ns("explorer_file"), "Assessment / granularity",
        choices = stats::setNames(basename(df$path),
          paste0(df$assessment, ifelse(is.na(df$granularity), "", paste0(" / ", df$granularity)))))
    })

    output$explorer_frame <- shiny::renderUI({
      shiny::req(input$explorer_file)
      shiny::tags$iframe(
        src = file.path(BM_EXPLORER_RESOURCE_PATH, input$explorer_file),
        style = "width:100%; height:85vh; border:none;"
      )
    })

    shiny::observeEvent(nav_state$reports, {
      req <- nav_state$reports
      shiny::req(req$subtab)
      bslib::nav_select(id = "subtab", selected = req$subtab, session = session)
    })
  })
}
