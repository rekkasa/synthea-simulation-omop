#!/usr/bin/env bash
#
# run_all.sh
# ----------
# Single entry point for the Synthea -> OMOP RA pipeline. Defines all shared,
# tunable parameters once and runs the four stages in order, aborting on the
# first failure.
#
# Override any parameter on the command line, e.g.:
#   N_PATIENTS=100 SEED=42 STATE=California ./run_all.sh
#
set -euo pipefail

# Run from the project root regardless of the caller's working directory.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# --- Shared parameters (all overridable via environment) -------------------
export N_PATIENTS="${N_PATIENTS:-10}"          # number of adult RA patients
export SEED="${SEED:-20240101}"                  # base random seed (reproducible)
export STATE="${STATE:-Massachusetts}"           # US state for demographics
export SYNTHEA_VERSION="${SYNTHEA_VERSION:-3.3.0}"
export OUTPUT_DIR="${OUTPUT_DIR:-data/synthea_output}"
export DUCKDB_PATH="${DUCKDB_PATH:-data/omop.duckdb}"
export VOCAB_DIR="${VOCAB_DIR:-data/vocab}"

echo "=========================================================="
echo " Synthea -> OMOP RA pipeline"
echo "   N_PATIENTS      = ${N_PATIENTS}"
echo "   SEED            = ${SEED}"
echo "   STATE           = ${STATE}"
echo "   SYNTHEA_VERSION = ${SYNTHEA_VERSION}"
echo "   OUTPUT_DIR      = ${OUTPUT_DIR}"
echo "   DUCKDB_PATH     = ${DUCKDB_PATH}"
echo "   VOCAB_DIR       = ${VOCAB_DIR}"
echo "=========================================================="

# --- One-time R environment setup -----------------------------------------
if [[ ! -f "renv.lock" ]]; then
  echo ">>> renv.lock not found; running one-time R environment setup..."
  Rscript scripts/00_setup_renv.R
fi

# --- Stage 1: download Synthea --------------------------------------------
echo ">>> Stage 1: download Synthea JAR"
bash scripts/01_download_synthea.sh

# --- Stage 2: simulate RA cohort ------------------------------------------
echo ">>> Stage 2: simulate adult RA cohort"
bash scripts/02_simulate.sh

# --- Stage 3: ETL to OMOP CDM (DuckDB) ------------------------------------
echo ">>> Stage 3: ETL Synthea CSV -> OMOP CDM v5.4 (DuckDB)"
Rscript scripts/03_etl.R "${OUTPUT_DIR}/csv" "${DUCKDB_PATH}" "${VOCAB_DIR}"

# --- Stage 4: analyses -----------------------------------------------------
echo ">>> Stage 4: analyses (comorbidity, progression, treatment)"
Rscript scripts/04_analyse.R "${DUCKDB_PATH}"

echo "=========================================================="
echo " Pipeline complete."
echo "   OMOP CDM : ${DUCKDB_PATH}"
echo "   Results  : results/"
echo "=========================================================="
