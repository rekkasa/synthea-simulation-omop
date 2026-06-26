#!/usr/bin/env bash
#
# 01_download_synthea.sh
# ----------------------
# Stage 1 of the Synthea -> OMOP pipeline.
#
# Downloads the pinned Synthea "with dependencies" JAR from GitHub Releases.
# The download is idempotent: if the JAR is already present it is left alone.
# Fails fast with a clear message if Java is not available, since Synthea
# requires a JRE/JDK to run.
#
# Parameters (read from the environment, all optional):
#   SYNTHEA_VERSION   Synthea release to download (default: 3.3.0)
#   TOOLS_DIR         Directory to store the JAR        (default: tools)
#
set -euo pipefail

# Run from the project root regardless of the caller's working directory.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SYNTHEA_VERSION="${SYNTHEA_VERSION:-3.3.0}"
TOOLS_DIR="${TOOLS_DIR:-tools}"
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
