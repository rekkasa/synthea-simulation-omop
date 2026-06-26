#!/usr/bin/env Rscript
#
# 03_etl.R
# --------
# Stage 3 of the Synthea -> OMOP pipeline.
#
# Loads the Synthea CSV output (stage 2) into an OMOP CDM v5.4 database stored
# in DuckDB, using the ETL-Synthea package (installed as 'ETLSyntheaBuilder')
# on top of DatabaseConnector.
#
# Pipeline of ETL-Synthea calls (in order):
#   1. CreateCDMTables        - empty CDM v5.4 schema
#   2. CreateSyntheaTables    - staging tables matching Synthea 3.3.0 CSVs
#   3. LoadSyntheaTables      - load the raw Synthea CSVs into staging
#   4. LoadVocabFromCsv       - load the OMOP Athena vocabulary CSVs
#   5. CreateMapAndRollupTables
#   6. CreateExtraIndices     - optional (toggled by CREATE_INDICES below)
#   7. LoadEventTables        - populate the CDM clinical event tables
#
# Usage:
#   Rscript scripts/03_etl.R [synthea_csv_dir] [duckdb_path] [vocab_dir]
#
# Defaults:
#   synthea_csv_dir = data/synthea_output/csv
#   duckdb_path     = data/omop.duckdb
#   vocab_dir       = data/vocab
#
# Run from the project root.

args <- commandArgs(trailingOnly = TRUE)
synthea_csv_dir <- if (length(args) >= 1) args[[1]] else "data/synthea_output/csv"
duckdb_path     <- if (length(args) >= 2) args[[2]] else "data/omop.duckdb"
vocab_dir       <- if (length(args) >= 3) args[[3]] else "data/vocab"

# Reproduce the locked R environment (see scripts/00_setup_renv.R).
if (file.exists("renv.lock") && requireNamespace("renv", quietly = TRUE)) {
  renv::restore(prompt = FALSE)
}

# --- Preconditions ---------------------------------------------------------
if (!dir.exists(synthea_csv_dir) ||
    !file.exists(file.path(synthea_csv_dir, "patients.csv"))) {
  stop(sprintf(
    "Synthea CSV directory '%s' is missing or has no patients.csv. Run stage 2 first.",
    synthea_csv_dir))
}

# Athena vocabulary files are required by LoadVocabFromCsv. They are NOT bundled
# and must be downloaded manually (see README, 'OMOP vocabularies' section).
concept_present <- length(list.files(vocab_dir, pattern = "^CONCEPT\\.csv$",
                                     ignore.case = TRUE)) > 0
if (!dir.exists(vocab_dir) || !concept_present) {
  stop(sprintf(paste0(
    "Vocabulary directory '%s' is missing or does not contain CONCEPT.csv.\n",
    "Download the OMOP vocabularies from https://athena.ohdsi.org and extract\n",
    "them into that directory before running the ETL (see README)."), vocab_dir))
}

dir.create(dirname(duckdb_path), recursive = TRUE, showWarnings = FALSE)

library(ETLSyntheaBuilder)
library(DatabaseConnector)

# --- Connection + schema configuration -------------------------------------
# DuckDB is a single-file, single-schema database; both the CDM and the Synthea
# staging tables live in the default 'main' schema.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms   = "duckdb",
  server = duckdb_path
)

cdmSchema      <- "main"
syntheaSchema  <- "main"
cdmVersion     <- "5.4"
syntheaVersion <- "3.3.0"

# Athena exports are tab-delimited despite the .csv extension.
vocab_delimiter <- "\t"

# Toggle creation of extra (non-essential) indices. They speed up downstream
# queries but lengthen the ETL; disabled by default for a fast first build.
CREATE_INDICES <- as.logical(Sys.getenv("CREATE_INDICES", "FALSE"))

log_step <- function(msg) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), msg))

# --- ETL sequence ----------------------------------------------------------
log_step("1/7 CreateCDMTables (CDM v5.4)")
ETLSyntheaBuilder::CreateCDMTables(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  cdmVersion        = cdmVersion
)

log_step("2/7 CreateSyntheaTables (Synthea 3.3.0 staging)")
ETLSyntheaBuilder::CreateSyntheaTables(
  connectionDetails = connectionDetails,
  syntheaSchema     = syntheaSchema,
  syntheaVersion    = syntheaVersion
)

log_step(sprintf("3/7 LoadSyntheaTables from %s", synthea_csv_dir))
log_step("    (duplicate CSV headers will be sanitized to a temp copy)")

# Synthea v3.3.0 can emit CSVs with duplicate column headers (notably
# claims_transactions.csv). DatabaseConnector/DuckDB rejects these when
# registering the R data frame. Work on a sanitized copy of the CSV directory
# so the original Synthea output is preserved.
sanitize_csv_dir <- function(src_dir) {
  dst_dir <- file.path(tempdir(), paste0("synthea_csv_sanitized_", Sys.getpid()))
  if (dir.exists(dst_dir)) unlink(dst_dir, recursive = TRUE)
  dir.create(dst_dir, recursive = TRUE, showWarnings = FALSE)

  files <- list.files(src_dir, pattern = "\\.csv$", full.names = TRUE)
  for (f in files) {
    header <- tryCatch(readLines(f, n = 1), error = function(e) NULL)
    out_file <- file.path(dst_dir, basename(f))

    if (is.null(header) || length(header) == 0) {
      file.copy(f, out_file)
      next
    }

    cols <- strsplit(header, ",")[[1]]
    cols <- gsub('^"|"$', "", cols)
    if (anyDuplicated(cols) == 0) {
      file.copy(f, out_file)
      next
    }

    message(sprintf("  Sanitizing duplicate headers in %s", basename(f)))
    df <- utils::read.csv(f, check.names = FALSE, stringsAsFactors = FALSE)
    df <- df[, !duplicated(names(df)), drop = FALSE]
    utils::write.csv(df, out_file, row.names = FALSE, quote = TRUE)
  }
  dst_dir
}

synthea_csv_dir_sanitized <- sanitize_csv_dir(synthea_csv_dir)

ETLSyntheaBuilder::LoadSyntheaTables(
  connectionDetails = connectionDetails,
  syntheaSchema     = syntheaSchema,
  syntheaFileLoc    = synthea_csv_dir_sanitized
)

log_step(sprintf("4/7 LoadVocabFromCsv from %s", vocab_dir))
ETLSyntheaBuilder::LoadVocabFromCsv(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  vocabFileLoc      = vocab_dir,
  delimiter         = vocab_delimiter
)

log_step("5/7 CreateMapAndRollupTables")
ETLSyntheaBuilder::CreateMapAndRollupTables(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  syntheaSchema     = syntheaSchema,
  cdmVersion        = cdmVersion,
  syntheaVersion    = syntheaVersion
)

if (CREATE_INDICES) {
  log_step("6/7 CreateExtraIndices")
  ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connectionDetails,
    cdmSchema         = cdmSchema,
    syntheaSchema     = syntheaSchema,
    syntheaVersion    = syntheaVersion
  )
} else {
  log_step("6/7 CreateExtraIndices (skipped; set CREATE_INDICES=TRUE to enable)")
}

log_step("7/7 LoadEventTables")
ETLSyntheaBuilder::LoadEventTables(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  syntheaSchema     = syntheaSchema,
  cdmVersion        = cdmVersion,
  syntheaVersion    = syntheaVersion
)

log_step(sprintf("ETL complete. OMOP CDM v5.4 written to %s", duckdb_path))
