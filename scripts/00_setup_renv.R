#!/usr/bin/env Rscript
#
# 00_setup_renv.R
# ---------------
# One-time R environment setup for the ETL (stage 3) and analysis (stage 4)
# scripts. Run this once before the first pipeline run.
#
# A valid renv.lock cannot be hand-authored (it records exact package versions
# and content hashes), so this script generates it: it initialises an renv
# project, installs the required packages at their current CRAN / GitHub
# versions, and snapshots them into renv.lock. Subsequent runs of 03_etl.R and
# 04_analyse.R call renv::restore() to reproduce this exact environment.
#
# Usage:
#   Rscript scripts/00_setup_renv.R
#
# Run from the project root.

repos <- "https://cloud.r-project.org"

if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv", repos = repos)
}

# Initialise an renv project in the current directory without trying to
# auto-discover dependencies (we declare them explicitly below).
if (!file.exists("renv/activate.R")) {
  renv::init(bare = TRUE, restart = FALSE)
}

cran_packages <- c(
  "DatabaseConnector",  # ETL backend abstraction (used with the duckdb driver)
  "duckdb",             # embedded analytical database / OMOP CDM backend
  "DBI",                # database interface used by the analysis stage
  "dplyr",
  "dbplyr",
  "tidyr",
  "lubridate",
  "readr",
  "glue"
)

renv::install(cran_packages)

# ETL-Synthea ships the package as 'ETLSyntheaBuilder' from GitHub.
renv::install("OHDSI/ETL-Synthea")

renv::snapshot(prompt = FALSE)

message("renv setup complete. renv.lock written. ",
        "Stages 3 and 4 will reproduce this environment via renv::restore().")
