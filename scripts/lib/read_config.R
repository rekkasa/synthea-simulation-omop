#!/usr/bin/env Rscript
#
# read_config.R
# -------------
# Prints the value of a dot-separated key path from config.yaml.
# Used by shell scripts that cannot parse YAML natively.
#
# Usage:
#   Rscript scripts/lib/read_config.R synthea.version
#   Rscript scripts/lib/read_config.R etl.create_indices
#
# Exit code 1 if the key is not found.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0) {
  stop("Usage: Rscript scripts/lib/read_config.R <key.path>", call. = FALSE)
}

key_arg  <- args[[1]]
cfg_file <- file.path(dirname(getwd()), "config.yaml")

# Determine the project root: handle both CWD=root and CWD=scripts/.
if (!file.exists(cfg_file)) {
  cfg_file <- "../config.yaml"
}
if (!file.exists(cfg_file)) {
  cfg_file <- "config.yaml"
}

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("R package 'yaml' is required. Run scripts/00_setup_renv.R first.", call. = FALSE)
}

cfg <- yaml::read_yaml(cfg_file, eval.expr = FALSE)

# Walk the key path (e.g. "synthea.version" -> cfg[["synthea"]][["version"]])
parts <- strsplit(key_arg, "\\.")[[1]]
val   <- cfg
for (part in parts) {
  if (!is.list(val) || !part %in% names(val)) {
    stop(sprintf("Key '%s' not found in %s", key_arg, cfg_file), call. = FALSE)
  }
  val <- val[[part]]
}

if (is.logical(val)) {
  writeLines(tolower(as.character(val)))
} else {
  writeLines(as.character(val))
}
