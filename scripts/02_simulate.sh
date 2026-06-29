#!/usr/bin/env bash
#
# 02_simulate.sh
# --------------
# Stage 2 of the Synthea -> OMOP pipeline.
#
# Generates an ADULT, RHEUMATOID-ARTHRITIS-ONLY synthetic cohort with Synthea
# and exports it as CSV. RA-only is enforced by the keep module
# (config/keep_ra.json, passed via -k); adults-only is enforced by the age
# range filter read from config.yaml.
#
# The module override (config/modules/rheumatoid_arthritis.json) forces every
# adult onto the RA onset path, cutting wasted simulation by ~100x.
#
# Configuration is read from config.yaml (see project root).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Read config (env-var overrides take precedence) ------------------------
config_val() {
  local key="$1"
  local env_var="${2:-}"
  if [[ -n "${env_var:-}" ]] && [[ -n "${!env_var:-}" ]]; then
    echo "${!env_var}"
  else
    Rscript scripts/lib/read_config.R "$key"
  fi
}

N_PATIENTS="$(config_val simulation.n_patients    N_PATIENTS)"
SEED="$(config_val simulation.seed               SEED)"
STATE="$(config_val simulation.state             STATE)"
MAX_ITERATIONS="$(config_val simulation.max_iterations MAX_ITERATIONS)"
MODULE_DIR="$(config_val simulation.module_dir   MODULE_DIR)"
AGE_MIN="$(config_val simulation.age_min         AGE_MIN)"
AGE_MAX="$(config_val simulation.age_max         AGE_MAX)"
SYNTHEA_CSV_DIR="$(config_val etl.synthea_csv_dir SYNTHEA_CSV_DIR)"

JAR_PATH="tools/synthea-with-dependencies.jar"
KEEP_MODULE="config/keep_ra.json"
OUTPUT_DIR="$(dirname "$SYNTHEA_CSV_DIR")"
CSV_DIR="$SYNTHEA_CSV_DIR"
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
if [[ ! -d "$MODULE_DIR" ]]; then
  echo "ERROR: module override dir '${MODULE_DIR}' not found." >&2
  exit 1
fi

mkdir -p "$CSV_DIR" logs
LOG_FILE="logs/synthea_$(date +%Y%m%d_%H%M%S).log"
echo "Synthea run log: ${LOG_FILE}"

# --- Helpers ---------------------------------------------------------------

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

echo "Target: ${N_PATIENTS} adult RA patients | state=${STATE} | seed=${SEED} | age=${AGE_MIN}-${AGE_MAX}"

while (( total < N_PATIENTS )); do
  iteration=$(( iteration + 1 ))
  if (( iteration > MAX_ITERATIONS )); then
    echo "ERROR: reached MAX_ITERATIONS (${MAX_ITERATIONS}) with only ${total} RA patients." >&2
    echo "Increase simulation.max_iterations in config.yaml, or check ${LOG_FILE}." >&2
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
    -a "${AGE_MIN}-${AGE_MAX}" \
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

# --- Strip non-RA patients from CSV exports ----------------------------------
# Synthea's -k keep module controls generation count but does NOT filter CSV
# output. Patients who never got RA still appear in every CSV file. Remove
# their rows so the exported cohort exactly matches the RA count.
filter_ra_only() {
  local csv_dir="$1"
  local racode="$2"

  local work_dir
  work_dir="$(mktemp -d)"

  # Collect RA patient IDs from conditions.csv (column PATIENT).
  awk -F',' -v rc="$racode" '
    NR == 1 {
      for (i = 1; i <= NF; i++) { h = $i; gsub(/"/, "", h); if (h == "PATIENT") p = i; if (h == "CODE") c = i }
      next
    }
    { code = $c; gsub(/"/, "", code); pid = $p; gsub(/"/, "", pid)
      if (code == rc) ids[pid] = 1 }
    END { for (id in ids) print id }
  ' "${csv_dir}/conditions.csv" > "${work_dir}/ra_ids"

  local ra_count
  ra_count="$(wc -l < "${work_dir}/ra_ids")"
  if [[ "$ra_count" -eq 0 ]]; then
    echo "ERROR: no RA patients found in conditions.csv after generation." >&2
    rm -rf "$work_dir"
    return 1
  fi

  echo "Post-filtering: keeping only ${ra_count} RA patients across all CSV files."

  for f in "${csv_dir}"/*.csv; do
    [[ -e "$f" ]] || continue
    local base
    base="$(basename "$f")"

    # Discover PATIENT column position from header.
    # patients.csv uses "Id" instead of "PATIENT".
    local pat_col
    pat_col=$(head -1 "$f" | awk -F',' '{
      for (i = 1; i <= NF; i++) { h = $i; gsub(/"/, "", h); if (h == "PATIENT" || h == "Id") { print i; exit } }
    }')

    if [[ -z "$pat_col" ]]; then
      # Files without a PATIENT column (organizations, providers, payers) are left as-is.
      continue
    fi

    # Keep header + rows whose PATIENT column value is in the RA set.
    # NR==FNR: processing the ID file (first argument).
    # FNR==1 && NR!=FNR: header of the CSV (second argument).
    # Otherwise: CSV data row — print only if PATIENT is in the ID set.
    awk -F',' -v col="$pat_col" '
      NR == FNR          { ids[$0] = 1; next }
      FNR == 1           { print; next }
      { pid = $col; gsub(/"/, "", pid); if (pid in ids) print }
    ' "${work_dir}/ra_ids" "$f" > "${work_dir}/${base}"
    mv "${work_dir}/${base}" "$f"
  done

  rm -rf "$work_dir"
}

filter_ra_only "$CSV_DIR" "$RA_SNOMED_CODE"

echo "Done. ${total} adult RA patients exported to '${CSV_DIR}'."
