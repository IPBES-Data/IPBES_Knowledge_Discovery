# Clickable workflow_nli.mmd navigation. render_mmd() (R/render_diagrams.R)
# is a headless mermaid-cli static render with no mermaid.js runtime
# attached, so `click <id> call <fn>(...)` JS-callback directives silently
# do nothing (verified directly against a scratchpad test render). `click
# <id> href "#!<token>" "<tooltip>"` DOES survive into the SVG as a real
# <a xlink:href="#!<token>"> wrapper -- confirmed the same way -- so that's
# the directive style input/mmd/workflow_nli.mmd uses. The SVG is embedded
# inline (not <img src=...>) so its <a> elements are reachable by page JS;
# a small click-delegation script intercepts them, prevents the real
# navigation (which would reload the whole Shiny session), and forwards the
# token to the server via Shiny.setInputValue().

mod_workflow_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::tags$script(shiny::HTML(sprintf('
      $(document).on("click", "#%s a", function(e) {
        var href = $(this).attr("xlink:href") || $(this).attr("href");
        if (!href || href.indexOf("#!") !== 0) return;
        e.preventDefault();
        Shiny.setInputValue("%s", href.substring(2), {priority: "event"});
      });
    ', ns("svg_container"), ns("node_click")))),
    shiny::div(
      shiny::p(shiny::em(
        "Click a database (cylinder) or processing (box) node to inspect it, ",
        "or jump to the report that documents it. Alongside the tab bar above, ",
        "this is a second, visual way to navigate the app."
      )),
      shiny::div(id = ns("svg_container"), shiny::uiOutput(ns("svg")))
    )
  )
}

mod_workflow_server <- function(id, manifest, nav_state, repo_root) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    output$svg <- shiny::renderUI({
      shiny::req(!is.na(manifest$workflow_svg))
      shiny::HTML(paste(readLines(manifest$workflow_svg, warn = FALSE), collapse = "\n"))
    })

    shiny::observeEvent(input$node_click, {
      node_id <- input$node_click
      meta <- workflow_node_metadata[workflow_node_metadata$node_id == node_id, ]
      if (!nrow(meta)) return(invisible(NULL))
      meta <- meta[1, ]
      nav <- workflow_node_nav[[node_id]]

      body <- switch(meta$kind,
        database = shiny::tagList(
          shiny::p(meta$description),
          shiny::uiOutput(ns("dataset_info"))
        ),
        action = shiny::tagList(
          shiny::p(meta$description),
          shiny::h5("Implementing source"),
          shiny::tags$ul(lapply(workflow_node_source_files[[node_id]] %||% character(), function(f) {
            # repo_root is passed in explicitly, NOT getwd() -- Shiny resets
            # the working directory to the app dir around each session's
            # reactive evaluation (see app.R's own comment on the manifest),
            # and a bare free-variable lookup of a top-level app.R local
            # wouldn't resolve anyway: shiny::runApp() evaluates app.R in
            # its own sandboxed environment, not .GlobalEnv, while source()
            # (used to load every R/*.R and shiny_app/R/*.R file) always
            # sources into .GlobalEnv -- confirmed directly (a first version
            # of this function referenced repo_root as a bare global and
            # errored "object 'repo_root' not found" the moment this
            # observer fired, since mod_workflow_server()'s own closure
            # environment is .GlobalEnv, which never had repo_root in it).
            abs_path <- normalizePath(file.path(repo_root, f), mustWork = FALSE)
            shiny::tags$li(shiny::tags$a(href = paste0("vscode://file/", abs_path), f))
          }))
        ),
        doc = shiny::p(meta$description)
      )

      footer <- shiny::tagList(
        if (!is.null(nav)) shiny::actionButton(ns("goto"), "Go to report"),
        shiny::modalButton("Close")
      )

      session$userData$workflow_pending_nav <- nav
      shiny::showModal(shiny::modalDialog(
        title = node_id, body, footer = footer, size = "l", easyClose = TRUE
      ))

      if (isTRUE(meta$kind == "database") && !is.na(meta$dataset_root)) {
        # repo_root (passed in), not getwd() -- see the source-file link
        # block above for why a bare global lookup would fail here.
        abs_root <- file.path(repo_root, meta$dataset_root)
        output$dataset_info <- shiny::renderUI({
          root <- meta$dataset_root
          if (!dir.exists(abs_root)) {
            return(shiny::p(shiny::em("Not built yet -- ", shiny::code(root), " does not exist on disk.")))
          }
          ds <- tryCatch(arrow::open_dataset(abs_root), error = function(e) NULL)
          if (is.null(ds)) {
            return(shiny::p(shiny::em("Could not open dataset at ", shiny::code(root), ".")))
          }
          n <- tryCatch(nrow(ds), error = function(e) NA_integer_)
          shiny::tagList(
            shiny::p(shiny::strong("Path: "), shiny::code(root)),
            shiny::p(shiny::strong("Rows: "), format(n, big.mark = ",")),
            shiny::p(shiny::strong("Columns: "), paste(names(ds), collapse = ", ")),
            shiny::downloadButton(ns("download_sample"), "Download sample (1000 rows, CSV)")
          )
        })
        output$download_sample <- shiny::downloadHandler(
          filename = function() paste0(node_id, "_sample.csv"),
          content = function(file) {
            ds <- arrow::open_dataset(abs_root)
            readr::write_csv(head(dplyr::collect(ds), 1000), file)
          }
        )
      }
    })

    shiny::observeEvent(input$goto, {
      nav <- session$userData$workflow_pending_nav
      shiny::removeModal()
      shiny::req(nav)
      nav_state$active_tab <- nav$tab
      if (nav$tab == "qa") nav_state$qa <- list(report_type = nav$report_type)
      if (nav$tab == "general") nav_state$general <- list(label = nav$label)
      if (nav$tab == "td") nav_state$td <- list(file = nav$file)
      if (nav$tab == "reports") nav_state$reports <- list(subtab = nav$subtab)
    })
  })
}
