#!/usr/bin/env Rscript
#
# 00_setup_renv.R
# ---------------
# One-time R environment setup for the ETL (stage 3) and analysis (stage 4)
# scripts. Run this once before the first pipeline run.
#
# Usage:
#   Rscript scripts/00_setup_renv.R
#
# Run from the project root.

repos <- c(
  P3M = "https://packagemanager.posit.co/cran/__linux__/noble/latest",
  CRAN = "https://cloud.r-project.org"
)
options(repos = repos)

Sys.setenv(JAVA_HOME = "/usr/lib/jvm/java-21-openjdk-amd64")
Sys.setenv(MAKEFLAGS = "-j2")

if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

if (!file.exists("renv/activate.R")) {
  renv::init(bare = TRUE, restart = FALSE)
}

# Install from binary repos first (pre-compiled, fast), falling back to
# source for any package not available as a binary.
cran_packages <- c(
  "DatabaseConnector", "duckdb", "DBI",
  "dplyr", "dbplyr", "tidyr", "lubridate", "readr", "glue"
)

renv::install(cran_packages, type = "binary")

# rJava needs source install with JAVA_HOME set.
renv::install("rJava")

# ETL-Synthea from GitHub (source only, but no C++ compilation).
renv::install("OHDSI/ETL-Synthea")

renv::snapshot(prompt = FALSE)

message("renv setup complete. renv.lock written. ",
        "Stages 3 and 4 will reproduce this environment via renv::restore().")
