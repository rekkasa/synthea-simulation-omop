#!/usr/bin/env bash
#
# 02_simulate.sh
# --------------
# Stage 2 of the Synthea -> OMOP pipeline.
#
# Generates a disease-specific synthetic cohort with Synthea and exports it as
# CSV. The target disease is controlled by the keep module and SNOMED code
# configured in config.yaml (simulation.keep_module, simulation.disease_snomed_code).
# Adults-only is enforced by the age range filter read from config.yaml.
#
# The module override directory (simulation.module_dir) limits which disease
# modules are loaded, forcing every adult onto the target disease pathway.
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

N_PATIENTS="$(config_val simulation.n_patients           N_PATIENTS)"
SEED="$(config_val simulation.seed                        SEED)"
STATE="$(config_val simulation.state                      STATE)"
MODULE_DIR="$(config_val simulation.module_dir            MODULE_DIR)"
AGE_MIN="$(config_val simulation.age_min                  AGE_MIN)"
AGE_MAX="$(config_val simulation.age_max                  AGE_MAX)"
SYNTHEA_CSV_DIR="$(config_val etl.synthea_csv_dir         SYNTHEA_CSV_DIR)"
KEEP_MODULE="$(config_val simulation.keep_module          KEEP_MODULE)"
DISEASE_SNOMED_CODE="$(config_val simulation.disease_snomed_code DISEASE_SNOMED)"

JAR_PATH="tools/synthea-with-dependencies.jar"
OUTPUT_DIR="$(dirname "$SYNTHEA_CSV_DIR")"
CSV_DIR="$SYNTHEA_CSV_DIR"

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

count_disease_patients() {
  local conditions="$1"
  if [[ ! -f "$conditions" ]]; then
    echo 0
    return
  fi
  awk -F',' -v dcode="$DISEASE_SNOMED_CODE" '
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
      if (code == dcode) seen[pid] = 1
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

# --- Generation (oversample in one batch) -----------------------------------
# Instead of an iterative loop that requests a few patients per JVM startup,
# we oversample by a large factor, then randomly select exactly N patients
# from the qualifying pool.  One JVM run costs the same whether it generates
# 10 or 500 patients, so we generate many and sample down.
OVERSAMPLE_FACTOR=5
batch_size=$(( N_PATIENTS * OVERSAMPLE_FACTOR ))
(( batch_size < 100 )) && batch_size=100   # minimum for low-N to avoid variance

echo "Target: ${N_PATIENTS} adult patients (SNOMED ${DISEASE_SNOMED_CODE})"
echo "  state=${STATE} | seed=${SEED} | age=${AGE_MIN}-${AGE_MAX}"
echo "  module_dir=${MODULE_DIR} | keep=${KEEP_MODULE}"
echo "  oversampling: generating ${batch_size} to get ${N_PATIENTS}"

batch_dir="${OUTPUT_DIR}/.batch"
rm -rf "$batch_dir"
mkdir -p "$batch_dir"

echo "Generating ${batch_size} patients (seed=${SEED})..."
java -jar "$JAR_PATH" \
  -p "$batch_size" \
  -s "$SEED" \
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

total="$(count_disease_patients "${CSV_DIR}/conditions.csv")"
echo "Generated ${batch_size} → ${total} qualifying patients"

# If still short, do one more round with a bigger oversample
if (( total < N_PATIENTS )); then
  extra=$(( N_PATIENTS * 2 ))
  echo "Only ${total} qualifying; generating ${extra} more..."
  batch_dir="${OUTPUT_DIR}/.batch2"
  rm -rf "$batch_dir"
  mkdir -p "$batch_dir"

  java -jar "$JAR_PATH" \
    -p "$extra" \
    -s "$(( SEED + 1 ))" \
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
  total="$(count_disease_patients "${CSV_DIR}/conditions.csv")"
  echo "Now have ${total} qualifying patients"
fi

if (( total < N_PATIENTS )); then
  echo "ERROR: only ${total} qualifying patients after oversample; need ${N_PATIENTS}." >&2
  echo "Consider lowering the delay in the disease module or increasing age range." >&2
  exit 1
fi

# --- Filter to exactly N_PATIENTS randomly chosen patients -------------------
# Synthea's -k keep module filters during generation but does NOT trim CSV
# output.  We collect all qualifying patient IDs, randomly pick N, and strip
# the rest from every CSV file.
filter_disease_only() {
  local csv_dir="$1"
  local dcode="$2"
  local target_n="$3"

  local work_dir
  work_dir="$(mktemp -d)"

  # Collect all qualifying patient IDs
  awk -F',' -v rc="$dcode" '
    NR == 1 {
      for (i = 1; i <= NF; i++) { h = $i; gsub(/"/, "", h); if (h == "PATIENT") p = i; if (h == "CODE") c = i }
      next
    }
    { code = $c; gsub(/"/, "", code); pid = $p; gsub(/"/, "", pid)
      if (code == rc) ids[pid] = 1 }
    END { for (id in ids) print id }
  ' "${csv_dir}/conditions.csv" > "${work_dir}/all_ids"

  local pool_size
  pool_size=$(wc -l < "${work_dir}/all_ids")
  echo "Qualifying pool: ${pool_size} patients. Sampling ${target_n} at random."

  # Randomly select exactly target_n
  shuf -n "$target_n" "${work_dir}/all_ids" > "${work_dir}/disease_ids"

  for f in "${csv_dir}"/*.csv; do
    [[ -e "$f" ]] || continue
    local base
    base="$(basename "$f")"

    local pat_col
    pat_col=$(head -1 "$f" | awk -F',' '{
      for (i = 1; i <= NF; i++) { h = $i; gsub(/"/, "", h); if (h == "PATIENT" || h == "Id") { print i; exit } }
    }')

    if [[ -z "$pat_col" ]]; then
      continue
    fi

    awk -F',' -v col="$pat_col" '
      NR == FNR          { ids[$0] = 1; next }
      FNR == 1           { print; next }
      { pid = $col; gsub(/"/, "", pid); if (pid in ids) print }
    ' "${work_dir}/disease_ids" "$f" > "${work_dir}/${base}"
    mv "${work_dir}/${base}" "$f"
  done

  rm -rf "$work_dir"
}

filter_disease_only "$CSV_DIR" "$DISEASE_SNOMED_CODE" "$N_PATIENTS"

echo "Done. ${N_PATIENTS} patients exported to '${CSV_DIR}'."
