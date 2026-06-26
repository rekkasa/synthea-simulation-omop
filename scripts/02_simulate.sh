#!/usr/bin/env bash
#
# 02_simulate.sh
# --------------
# Stage 2 of the Synthea -> OMOP pipeline.
#
# Generates an ADULT, RHEUMATOID-ARTHRITIS-ONLY synthetic cohort with Synthea
# and exports it as CSV. RA-only is enforced by the keep module
# (config/keep_ra.json, passed via -k); adults-only is enforced by the age
# range filter (-a 45-120).
#
# Synthea's -k flag already keeps generating internally until the requested
# population of *matching* patients is produced, so a single invocation is
# normally enough. The loop below is a safety net + accumulator: it re-runs
# Synthea with a fresh (deterministic) seed each iteration and merges the CSV
# output until the cumulative count of distinct adult RA patients reaches
# N_PATIENTS, guarding against an infinite loop with MAX_ITERATIONS.
#
# Generation speed: the built-in RA module only gives ~1% of simulated adults
# rheumatoid arthritis, so the RA-only keep module would otherwise discard ~99%
# of all simulation work. We override that module with config/modules/
# rheumatoid_arthritis.json (loaded via -d), which forces every adult onto the
# RA onset path. A same-named local module replaces the built-in one, so this is
# a drop-in override; only the onset incidence changes, not the RA disease model,
# so the kept active-RA cohort keeps the same characteristics with far less
# wasted simulation. See that file's remarks for the full rationale.
#
# Parameters (read from the environment, all optional):
#   N_PATIENTS      Target number of adult RA patients   (default: 1000)
#   SEED            Base random seed (reproducible)       (default: 20240101)
#   STATE           US state for demographics             (default: Massachusetts)
#   OUTPUT_DIR      Base output directory                 (default: data/synthea_output)
#   MODULE_DIR      Local Synthea module override dir     (default: config/modules)
#   MAX_ITERATIONS  Safety cap on generation batches      (default: 50)
#
set -euo pipefail

# Run from the project root regardless of the caller's working directory.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

N_PATIENTS="${N_PATIENTS:-1000}"
SEED="${SEED:-20240101}"
STATE="${STATE:-Massachusetts}"
OUTPUT_DIR="${OUTPUT_DIR:-data/synthea_output}"
MODULE_DIR="${MODULE_DIR:-config/modules}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"

JAR_PATH="tools/synthea-with-dependencies.jar"
KEEP_MODULE="config/keep_ra.json"
CSV_DIR="${OUTPUT_DIR}/csv"
RA_SNOMED_CODE="69896004"

# --- Preconditions ---------------------------------------------------------
if [[ ! -f "$JAR_PATH" ]]; then
  echo "ERROR: '${JAR_PATH}' not found. Run scripts/01_download_synthea.sh first." >&2
  exit 1
fi
if [[ ! -f "$KEEP_MODULE" ]]; then
  echo "ERROR: keep module '${KEEP_MODULE}' not found." >&2
  exit 1
fi
# Synthea's -d loads *every* .json in this directory as a module, so it must be
# a dedicated module dir (not config/, which also holds the keep module).
if [[ ! -d "$MODULE_DIR" ]]; then
  echo "ERROR: module override dir '${MODULE_DIR}' not found." >&2
  exit 1
fi

mkdir -p "$CSV_DIR" logs
LOG_FILE="logs/synthea_$(date +%Y%m%d_%H%M%S).log"
echo "Synthea run log: ${LOG_FILE}"

# --- Helpers ---------------------------------------------------------------

# Count distinct PATIENT ids in a Synthea conditions.csv that carry the RA
# SNOMED code. Column positions are discovered from the header so the function
# is robust to Synthea adding/removing columns. DESCRIPTION (which may contain
# commas) is the last column, so commas there never shift PATIENT or CODE.
count_ra_patients() {
  local conditions="$1"
  if [[ ! -f "$conditions" ]]; then
    echo 0
    return
  fi
  awk -F',' -v racode="$RA_SNOMED_CODE" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        h = $i; gsub(/"/, "", h)
        if (h == "PATIENT") p = i
        if (h == "CODE")    c = i
      }
      next
    }
    {
      code = $c; gsub(/"/, "", code)
      pid  = $p; gsub(/"/, "", pid)
      if (code == racode) seen[pid] = 1
    }
    END {
      n = 0
      for (k in seen) n++
      print n
    }
  ' "$conditions"
}

# Merge every *.csv from a batch directory into the cumulative CSV_DIR,
# keeping a single header row per file and appending subsequent data rows.
merge_csv() {
  local src_dir="$1"
  local dst_dir="$2"
  local f base dst
  for f in "$src_dir"/*.csv; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    dst="${dst_dir}/${base}"
    if [[ -f "$dst" ]]; then
      tail -n +2 "$f" >> "$dst"
    else
      cp "$f" "$dst"
    fi
  done
}

# --- Generation loop -------------------------------------------------------
iteration=0
total=0

echo "Target: ${N_PATIENTS} adult RA patients | state=${STATE} | base seed=${SEED}"

while (( total < N_PATIENTS )); do
  iteration=$(( iteration + 1 ))
  if (( iteration > MAX_ITERATIONS )); then
    echo "ERROR: reached MAX_ITERATIONS (${MAX_ITERATIONS}) with only ${total} adult RA patients (< ${N_PATIENTS})." >&2
    echo "Increase MAX_ITERATIONS, or check the keep module / Synthea output in ${LOG_FILE}." >&2
    exit 1
  fi

  remaining=$(( N_PATIENTS - total ))
  (( remaining < 1 )) && remaining=1
  iter_seed=$(( SEED + iteration ))
  batch_dir="${OUTPUT_DIR}/.batch_${iteration}"
  rm -rf "$batch_dir"
  mkdir -p "$batch_dir"

  echo "[iter ${iteration}] generating up to ${remaining} patients (seed=${iter_seed})..."
  java -jar "$JAR_PATH" \
    -p "$remaining" \
    -s "$iter_seed" \
    -a 45-120 \
    -d "$MODULE_DIR" \
    -k "$KEEP_MODULE" \
    --exporter.baseDirectory "$batch_dir" \
    --exporter.csv.export true \
    --exporter.csv.folder_per_run false \
    --exporter.csv.export.claims_transactions false \
    --exporter.fhir.export false \
    --exporter.hospital.fhir.export false \
    --exporter.practitioner.fhir.export false \
    "$STATE" \
    >> "$LOG_FILE" 2>&1

  merge_csv "${batch_dir}/csv" "$CSV_DIR"
  rm -rf "$batch_dir"

  total="$(count_ra_patients "${CSV_DIR}/conditions.csv")"
  echo "[iter ${iteration}] cumulative adult RA patients: ${total} / ${N_PATIENTS}"
done

echo "Done. ${total} adult RA patients exported to '${CSV_DIR}'."
