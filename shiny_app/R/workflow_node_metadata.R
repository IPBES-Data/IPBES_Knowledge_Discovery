# One row per clickable node in input/mmd/workflow_nli.mmd. Maintained by
# hand alongside that .mmd file's own `click <id> href "#!..."` lines (see
# that file's own comment block for the encoding). `kind` drives the modal
# shown on click: "database" nodes get a live schema/row-count/download
# panel (dataset_root resolved via arrow::open_dataset()); "action" nodes
# get a description + links to their implementing R source; "doc" nodes
# jump straight to the matching report tab/filter state, no modal.
#
# nav: how clicking should update the app's navigation -- a list with
# `tab` (one of "qa"/"td"/"reports"/"general"/"training") and any
# tab-specific filter hints (e.g. report_type for the QA tab). NULL means
# "no natural app tab for this node" -- the modal still opens (for database/
# action kinds) but has no "Go to report" button.

workflow_node_metadata <- tibble::tribble(
  ~node_id,              ~kind,       ~description,                                                                 ~dataset_root,
  "refs_db",              "database", "References DB: KM -> BM -> SM -> SubChapter <- Reference, extracted from the IPBES LOD.", "output/refs",
  "key_messages_db",      "database", "Key + Background Messages DB: KM -> BM descriptive text with confidence flags.", "output/key_messages",
  "zotero_db",             "database", "Zotero group items, downloaded page by page via the Zotero API.",             "output/zotero",
  "works_db",              "database", "OpenAlex metadata for the GA1/assessment seed reference list (works cited as evidence).", "output/works",
  "citing_db",             "database", "Papers citing the seed works, from the forward-snowball search.",             "output/works_citing",
  "snowball_db",           "database", "Snowball search results: nodes / edges / keypaper partitions.",               "output/snowball/nodes",
  "llm_scope_db",          "database", "Per-claim citing-work match set feeding the direct_evidence_match tag.",       "output/llm_candidate_scope",
  "nli_ready_db",          "database", "Claim x citing-work premise pairs, ready for NLI scoring.",                    "output/nli_ready_evidence",
  "nli_scores_db",         "database", "Zero-shot NLI SUPPORTS/REFUTES/NEI scores per (claim, citing work).",         "output/nli_scores_evidence",
  "nli_scores_kp_db",      "database", "NLI scores for key/seed papers against their own BM's claims (QA check).",    "output/nli_scores_evidence_keypaper",
  "llm_scores_db",         "database", "Phase 2 LLM verification of NLI-flagged (REFUTES/SUPPORTS, certain) pairs.",  "output/llm_verification/scores",
  "llm_scores_kp_db",      "database", "Phase 2 LLM verification of every key/seed paper (full coverage, no routing).", "output/llm_verification/scores_keypaper",
  "training_db",           "database", "Fine-tuning training data export: positives / negatives / REFUTES pairs.",    "output/nli_training",

  "build_refs",            "action",   "SPARQL extraction of the reference hierarchy (KM -> BM -> SM -> SubChapter <- Reference) from the IPBES LOD.", NA_character_,
  "build_key_messages",    "action",   "SPARQL extraction of Key/Background Message descriptive text.",              NA_character_,
  "download_zotero",       "action",   "Downloads Zotero group items page by page via the Zotero API.",              NA_character_,
  "download_works",        "action",   "Queries OpenAlex for the seed reference DOIs, joins back to KM/BM via refs.", NA_character_,
  "snowball",               "action",   "Forward/keypaper snowball search via openalexSnowball, per KM/BM seed set.", NA_character_,
  "llm_scope",              "action",   "Matches citing works to a claim's own evidence sub-chapter references.",     NA_character_,
  "nli_segment",            "action",   "Segments each BM into claims (naive_bm/complete_bm/atomic_bm granularity).", NA_character_,
  "nli_scoring",            "action",   "Zero-shot NLI classification of each citing work against one BM claim.",     NA_character_,
  "nli_keypaper_scoring",   "action",   "NLI classification of key/seed papers against their own BM's claims (QA check).", NA_character_,
  "llm_verify",             "action",   "Phase 2 LLM review of NLI-flagged pairs, with a verbatim-quote check.",       NA_character_,
  "llm_verify_keypaper",    "action",   "Phase 2 LLM review of every key/seed paper, irrespective of NLI label.",     NA_character_,
  "training_extract",       "action",   "Extracts labelled (claim, work) pairs for NLI fine-tuning from Phase 2 output.", NA_character_,

  "qa_bm_split",            "doc",      "QA report: how each BM was actually split into claims.",                     NA_character_,
  "qa_nli_scores",          "doc",      "QA report: NLI score-distribution sanity check (ternary plot, key-paper overlay).", NA_character_,
  "qa_llm_verify",          "doc",      "QA report: Phase 2 LLM verification agreement with Phase 1 NLI.",            NA_character_,
  "qa_training",            "doc",      "QA report: fine-tuning training data composition.",                          NA_character_,
  "qa_finetuned",           "doc",      "QA report: fine-tuned model accuracy, loss curve, classification report.",   NA_character_,

  "report_overview",        "doc",      "NLI label/confidence/alignment overview, per assessment/granularity, plus the interactive BM explorer widget.", NA_character_,
  "report_overlap",         "doc",      "Overlap tables: key papers cited by more than one BM; post-2018 citing works cited by more than 5 BMs.", NA_character_,
  "report_pub_year",        "doc",      "New publications per year among papers citing the key papers, grouped by background message.", NA_character_,
  "report_funnel",          "doc",      "REFUTES/SUPPORTS label funnel: full snowball corpus -> NLI-flagged (certain) -> LLM-confirmed.", NA_character_
)

workflow_node_source_files <- list(
  build_refs           = c("R/extract_lod.R", "R/write_refs_parquet.R"),
  build_key_messages   = c("R/extract_lod.R", "R/write_key_messages_parquet.R"),
  download_zotero      = "R/download_zotero.R",
  download_works       = "R/download_works.R",
  snowball             = "R/build_snowball_parquet.R",
  llm_scope            = "R/build_llm_candidate_scope_parquet.R",
  nli_segment          = "R/build_nli_ready_evidence_parquet.R",
  nli_scoring          = c("R/score_one_claim.R", "R/build_nli_claim_units.R", "R/nli_http_helpers.R"),
  nli_keypaper_scoring = "R/build_nli_ready_evidence_keypaper_parquet.R",
  llm_verify           = "R/build_llm_verification_parquet.R",
  llm_verify_keypaper  = "R/build_llm_verification_keypaper_parquet.R",
  training_extract     = "R/build_nli_training_data.R"
)

# node_id -> list(tab=, ...tab-specific filter hints...); see mod_*'s own
# `nav_state$<tab>` observers for what each hint list is read as.
workflow_node_nav <- list(
  works_db              = list(tab = "reports", subtab = "Overlap tables"),
  citing_db             = list(tab = "reports", subtab = "Overlap tables"),
  snowball_db           = list(tab = "reports"),
  nli_ready_db          = list(tab = "qa", report_type = "bm_split"),
  nli_scores_db         = list(tab = "qa", report_type = "nli_scores"),
  nli_scores_kp_db      = list(tab = "qa", report_type = "nli_scores"),
  llm_scores_db         = list(tab = "qa", report_type = "llm_verification"),
  llm_scores_kp_db      = list(tab = "qa", report_type = "llm_verification"),
  training_db           = list(tab = "training"),
  nli_segment           = list(tab = "qa", report_type = "bm_split"),
  nli_scoring           = list(tab = "qa", report_type = "nli_scores"),
  nli_keypaper_scoring  = list(tab = "qa", report_type = "nli_scores"),
  llm_verify            = list(tab = "qa", report_type = "llm_verification"),
  llm_verify_keypaper   = list(tab = "qa", report_type = "llm_verification"),
  training_extract      = list(tab = "training"),
  qa_bm_split           = list(tab = "qa", report_type = "bm_split"),
  qa_nli_scores         = list(tab = "qa", report_type = "nli_scores"),
  qa_llm_verify         = list(tab = "qa", report_type = "llm_verification"),
  qa_training           = list(tab = "training"),
  qa_finetuned          = list(tab = "qa", report_type = "finetuned_model"),
  report_overview       = list(tab = "reports", subtab = "NLI overview"),
  report_overlap        = list(tab = "reports", subtab = "Overlap tables"),
  report_pub_year       = list(tab = "reports", subtab = "Publications per year"),
  report_funnel         = list(tab = "general", label = "REFUTES")
)
