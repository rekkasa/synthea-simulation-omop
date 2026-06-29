#!/usr/bin/env bash
#
# 01_download_synthea.sh
# ----------------------
# Stage 1 of the Synthea -> OMOP pipeline.
#
# Downloads the pinned Synthea "with dependencies" JAR from GitHub Releases.
# The download is idempotent: if the JAR is already present it is left alone.
# Fails fast with a clear message if Java is not available.
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

SYNTHEA_VERSION="${SYNTHEA_VERSION:-$(config_val synthea.version SYNTHEA_VERSION)}"
TOOLS_DIR="${TOOLS_DIR:-$(config_val synthea.jar_dir TOOLS_DIR)}"
JAR_PATH="${TOOLS_DIR}/synthea-with-dependencies.jar"
DOWNLOAD_URL="https://github.com/synthetichealth/synthea/releases/download/v${SYNTHEA_VERSION}/synthea-with-dependencies.jar"

# --- Java check ------------------------------------------------------------
if ! command -v java >/dev/null 2>&1; then
  echo "ERROR: 'java' was not found in PATH." >&2
  echo "Synthea requires Java 11 or newer. Install a JDK, e.g.:" >&2
  echo "  sudo apt-get install openjdk-17-jdk    # Debian/Ubuntu" >&2
  echo "  brew install openjdk@17                 # macOS" >&2
  exit 1
fi

# --- Idempotent download ---------------------------------------------------
if [[ -f "$JAR_PATH" ]]; then
  echo "Synthea JAR already present at '${JAR_PATH}'; skipping download."
  exit 0
fi

mkdir -p "$TOOLS_DIR"
echo "Downloading Synthea v${SYNTHEA_VERSION}"
echo "  from: ${DOWNLOAD_URL}"
echo "  to:   ${JAR_PATH}"

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 -o "$JAR_PATH" "$DOWNLOAD_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$JAR_PATH" "$DOWNLOAD_URL"
else
  echo "ERROR: neither 'curl' nor 'wget' is available to download the JAR." >&2
  exit 1
fi

# --- Sanity check ----------------------------------------------------------
if [[ ! -s "$JAR_PATH" ]]; then
  echo "ERROR: download produced an empty file at '${JAR_PATH}'." >&2
  rm -f "$JAR_PATH"
  exit 1
fi

echo "Done. Synthea JAR is ready at '${JAR_PATH}'."
