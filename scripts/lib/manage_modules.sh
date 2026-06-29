#!/usr/bin/env bash
#
# manage_modules.sh
# ----------------
# Interactive Synthea module manager (pure bash).
#
# 1. Fetches available disease modules from the upstream Synthea repository.
# 2. Compares with modules already installed in config/modules/.
# 3. Lets the user choose which new modules to install.
# 4. For each selected module, asks:
#    - Whether to apply a 100 % incidence override.
#    - Whether to generate a "keep" JSON file.
#    - What patient attribute the keep module should check.
#
# Dependencies: curl, grep, sed, awk (standard Unix tools).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$ROOT_DIR/config/modules"
KEEP_DIR="$ROOT_DIR/config"

GITHUB_API_URL="https://api.github.com/repos/synthetichealth/synthea/contents/src/main/resources/modules"
RAW_BASE_URL="https://raw.githubusercontent.com/synthetichealth/synthea/master/src/main/resources/modules"

# ---- UI helpers -----------------------------------------------------------

box() {
  printf '\n%70s\n' | tr ' ' '='
  printf ' %s\n' "$1"
  printf '%70s\n\n' | tr ' ' '='
}

yesno() {
  local ans
  read -r -p "$1 " ans
  [[ "${ans,,}" == "y" ]]
}

# ---- Fetch available modules from GitHub ----------------------------------

fetch_available() {
  echo "Fetching module listing from GitHub ..." >&2
  curl -fsS "$GITHUB_API_URL" 2>/dev/null \
    | grep -oP '"name":\s*"\K[^"]+\.json(?=")' \
    | sort
}

# ---- List installed modules -----------------------------------------------

get_installed() {
  if [[ -d "$MODULES_DIR" ]]; then
    ls -1 "$MODULES_DIR" 2>/dev/null | grep '\.json$' | sort
  fi
}

# ---- Download -------------------------------------------------------------

do_download() {
  local name="$1"
  printf '  Downloading %s ...\n' "$name"
  curl -fsSL -o "${MODULES_DIR}/${name}" "${RAW_BASE_URL}/${name}" || {
    echo "  ERROR: Failed to download $name" >&2
    return 1
  }
  printf '  Saved to config/modules/%s\n' "$name"
}

# ---- Module analysis ------------------------------------------------------

# Returns one line:   type transition [pct]
#  "type" is one of:  direct  distributed  complex  unknown
examine_incidence() {
  local path="$1"

  # Find the Initial state start line number
  local init_line end_line
  init_line=$(grep -n '^    "Initial":' "$path" | head -1 | cut -d: -f1)
  [[ -z "$init_line" ]] && { echo "unknown"; return; }

  # Find the closing brace of the Initial block by counting braces
  end_line=$(awk -v start="$init_line" '
    NR >= start {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") depth--
      }
      if (depth == 0) { print NR; exit }
    }
  ' "$path")

  local block
  block=$(sed -n "${init_line},${end_line}p" "$path")

  # Direct transition?
  local dt
  dt=$(echo "$block" | grep -oP '"direct_transition":\s*"\K[^"]+' | head -1)
  if [[ -n "$dt" ]]; then
    echo "direct $dt"
    return
  fi

  # Distributed transition?
  if echo "$block" | grep -q '"distributed_transition"'; then
    # Extract first non-terminal transition and its distribution
    local transitions dists
    transitions=$(echo "$block" | grep -oP '"transition":\s*"\K[^"]+')
    dists=$(echo "$block" | grep -oP '"distribution":\s*\K[\d.]+')
    local -a tarr darr
    readarray -t tarr <<< "$transitions"
    readarray -t darr <<< "$dists"
    local i
    for i in "${!tarr[@]}"; do
      if [[ ! "${tarr[$i],,}" =~ terminal ]]; then
        local pct
        pct=$(awk "BEGIN {printf \"%.0f\", ${darr[$i]:-0} * 100}")
        echo "distributed ${tarr[$i]} $pct"
        return
      fi
    done
  fi

  # Complex transition?
  if echo "$block" | grep -q '"complex_transition"'; then
    local ct
    ct=$(echo "$block" | grep -oP '"transition":\s*"\K[^"]+' | grep -vi terminal | head -1)
    echo "complex ${ct:-unknown}"
    return
  fi

  echo "unknown"
}

# Output: one line per discovered mechanism
# Format:  COND|attribute|is-not-nil|codes|statename
#          SETATTR|attribute|value||statename
analyze_attrs() {
  local path="$1"

  # ConditionOnset with assign_to_attribute:
  # Find each state that is a ConditionOnset and extracts assign_to_attribute + codes.
  # Strategy: use sed to extract each state block, then grep within it.
  awk '
    /^    "[A-Za-z_]+": \{/ {
      if (block_name != "" && is_co && assign != "") {
        printf "COND|%s|is-not-nil|%s|%s\n", assign, codes, block_name
      }
      block_name = $0
      gsub(/^[[:space:]]*"|": \{.*/, "", block_name)
      is_co = 0; assign = ""; codes = ""
    }
    is_co == 0 && /"type": "ConditionOnset"/ { is_co = 1 }
    is_co == 1 && /"assign_to_attribute"/ {
      gsub(/.*"assign_to_attribute": "/, "")
      gsub(/".*/, "")
      assign = $0
    }
    is_co == 1 && /"code": "/ {
      gsub(/.*"code": "/, "")
      gsub(/".*/, "")
      codes = codes (codes == "" ? "" : " | ") $0
    }
    END {
      if (block_name != "" && is_co && assign != "") {
        printf "COND|%s|is-not-nil|%s|%s\n", assign, codes, block_name
      }
    }
  ' "$path"

  # SetAttribute (non-joint_replacement):
  awk '
    /^    "[A-Za-z_]+": \{/ {
      if (block_name != "" && is_sa && attr != "" && attr != "joint_replacement") {
        printf "SETATTR|%s|%s||%s\n", attr, val, block_name
      }
      block_name = $0
      gsub(/^[[:space:]]*"|": \{.*/, "", block_name)
      is_sa = 0; attr = ""; val = ""
    }
    is_sa == 0 && /"type": "SetAttribute"/ { is_sa = 1 }
    is_sa == 1 && /"attribute":/ {
      gsub(/.*"attribute": "/, "")
      gsub(/".*/, "")
      attr = $0
    }
    is_sa == 1 && /"value":/ {
      if ($0 ~ /"value": true/) val = "true"
      else if ($0 ~ /"value": false/) val = "false"
      else { gsub(/.*"value": "/, ""); gsub(/".*/, ""); val = $0 }
    }
    END {
      if (block_name != "" && is_sa && attr != "" && attr != "joint_replacement") {
        printf "SETATTR|%s|%s||%s\n", attr, val, block_name
      }
    }
  ' "$path"
}

# ---- Incidence override (pure sed/awk) ------------------------------------

apply_override() {
  local file_name="$1" onset_transition="$2"
  local path="${MODULES_DIR}/${file_name}"

  # Remove distributed_transition / complex_transition blocks from Initial
  # state, then insert direct_transition.  Uses awk state machine.
  local tmp
  tmp=$(mktemp)
  awk -v onset="$onset_transition" '
    BEGIN { in_init = 0; depth = 0; skip_nested = 0; inserted = 0 }

    /^    "Initial": \{/   { in_init = 1 }
    /^    "[A-Za-z_]+": \{/ { if ($0 !~ /"Initial"/) in_init = 0 }

    in_init && /"distributed_transition"/ { skip_nested = 1 }
    in_init && /"complex_transition"/      { skip_nested = 1 }

    {
      if (skip_nested) {
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == "[" || c == "{") depth++
          else if (c == "]" || c == "}") depth--
        }
        # Also count closing brace on same line as last array element
        if (depth <= 0) skip_nested = 0
        next
      }
    }

    in_init && !inserted && /"type": "Initial"/ {
      print
      printf "      \"direct_transition\": \"%s\",\n", onset
      inserted = 1
      next
    }

    { print }
  ' "$path" > "$tmp"
  mv "$tmp" "$path"

  # Add a remark about the override
  sed -i 's/\("gmf_version"\)/    "LOCAL OVERRIDE: 100% incidence -- every patient is forced onto the disease pathway.",\n  \1/' "$path" 2>/dev/null || true

  printf "  Applied 100%% incidence override (transition -> '%s').\n" "$onset_transition"
}

# ---- Keep JSON generation -------------------------------------------------

generate_keep() {
  local module_name="$1" attr="$2" op="$3" val="$4" dest="$5"
  local human
  human=$(echo "$module_name" | tr '_' ' ')

  if [[ "$op" == "is-not-nil" ]]; then
    cat > "$dest" <<JSON
{
  "name": "Keep ${human} Patients",
  "remarks": [
    "Synthea 'keep module' used with the -k command line flag.",
    "After a patient is fully simulated, Synthea runs this module against",
    "the finished record. The Guard state below only allows the module to",
    "reach the Keep state when the patient was ever diagnosed with the",
    "condition.",
    "",
    "Detection: Attribute '${attr}' is not nil",
    "Set by the '${module_name}' module."
  ],
  "states": {
    "Initial": {
      "type": "Initial",
      "direct_transition": "Keep_If_Condition"
    },
    "Keep_If_Condition": {
      "type": "Guard",
      "allow": {
        "condition_type": "Attribute",
        "attribute": "${attr}",
        "operator": "is not nil"
      },
      "direct_transition": "Keep"
    },
    "Keep": {
      "type": "Terminal"
    }
  }
}
JSON
  else
    cat > "$dest" <<JSON
{
  "name": "Keep ${human} Patients",
  "remarks": [
    "Synthea 'keep module' used with the -k command line flag.",
    "After a patient is fully simulated, Synthea runs this module against",
    "the finished record. The Guard state below only allows the module to",
    "reach the Keep state when the patient was ever diagnosed with the",
    "condition.",
    "",
    "Detection: Attribute '${attr}' == ${val}",
    "Set by the '${module_name}' module."
  ],
  "states": {
    "Initial": {
      "type": "Initial",
      "direct_transition": "Keep_If_Condition"
    },
    "Keep_If_Condition": {
      "type": "Guard",
      "allow": {
        "condition_type": "Attribute",
        "attribute": "${attr}",
        "operator": "==",
        "value": ${val}
      },
      "direct_transition": "Keep"
    },
    "Keep": {
      "type": "Terminal"
    }
  }
}
JSON
  fi
  printf "  Generated keep module: config/%s\n" "$(basename "$dest")"
}

# ---- Interactive module picker --------------------------------------------

choose_modules() {
  local -n ref=$1
  local n=${#ref[@]}

  if [[ $n -eq 0 ]]; then
    echo "All upstream modules are already installed."
    return 1
  fi

  box "NEW MODULES AVAILABLE"
  local i
  for i in "${!ref[@]}"; do
    printf '  [%2d] %s\n' "$((i + 1))" "${ref[$i]%.json}"
  done
  printf '  [%2d] All of the above\n' "$((n + 1))"
  printf '  [%2d] None (quit)\n' "$((n + 2))"
  echo

  while true; do
    read -r -p "Enter number(s) separated by commas (e.g. 1,3,5): " ans
    ans=$(echo "$ans" | tr -d '[:space:]')

    if [[ -z "$ans" || "${ans,,}" == "q" || "$ans" == "$((n + 2))" ]]; then
      return 1
    fi

    if [[ "$ans" == "$((n + 1))" ]]; then
      return 0
    fi

    local -a nums result
    IFS=',' read -ra nums <<< "$ans"
    local ok=1
    for x in "${nums[@]}"; do
      if [[ "$x" =~ ^[0-9]+$ ]] && (( x >= 1 && x <= n )); then
        result+=("${ref[$((x - 1))]}")
      else
        ok=0; break
      fi
    done

    if (( ok )); then
      ref=("${result[@]}")
      return 0
    fi
    printf '  Please enter valid numbers (1-%d).\n' "$n"
  done
}

# ---- Main -----------------------------------------------------------------

main() {
  box "SYNTHEA MODULE MANAGER"

  # Step 1: fetch
  local -a available installed
  readarray -t available < <(fetch_available)
  printf '  Found %d modules upstream.\n' "${#available[@]}"

  # Step 2: installed
  readarray -t installed < <(get_installed)
  local -A seen
  for m in "${installed[@]}"; do seen["$m"]=1; done

  # Step 3: diff
  local -a new=()
  for m in "${available[@]}"; do
    [[ -z "${seen[$m]:-}" ]] && new+=("$m")
  done

  box "STATUS"
  printf '  Installed: %d\n' "${#installed[@]}"
  for m in "${installed[@]}"; do printf '    - %s\n' "${m%.json}"; done
  printf '  New (available, not installed): %d\n\n' "${#new[@]}"

  # Step 4: pick
  if ! choose_modules new; then
    echo "No modules selected. Exiting."
    exit 0
  fi
  echo

  # Step 5: process each
  for mod_name in "${new[@]}"; do
    box "INSTALLING: ${mod_name%.json}"

    mkdir -p "$MODULES_DIR"
    do_download "$mod_name" || continue
    local path="${MODULES_DIR}/${mod_name}"

    # --- Incidence ---
    read -r inc_type inc_trans inc_pct <<< "$(examine_incidence "$path")"

    case "$inc_type" in
      direct)
        printf '\n  Incidence is UNCONDITIONAL (direct -> %s -- already 100%%).\n' "$inc_trans"
        ;;
      distributed)
        printf '\n  Incidence is currently GATED at %s%% (transition: %s).\n' "$inc_pct" "$inc_trans"
        if yesno "  Apply 100% incidence override? [y/N]:"; then
          apply_override "$mod_name" "$inc_trans"
        fi
        ;;
      complex)
        printf '\n  Incidence uses COMPLEX demographic-dependent branching.\n'
        printf '  Disease pathway transition: %s\n' "$inc_trans"
        echo  '  Simplifying to a direct transition would lose demographic heterogeneity.'
        if yesno "  Override anyway with a direct transition? [y/N]:"; then
          apply_override "$mod_name" "$inc_trans"
        fi
        ;;
      *)
        printf '\n  Could not determine incidence mechanism.\n'
        ;;
    esac

    # --- Keep JSON ---
    echo
    if yesno "  Generate a keep JSON file for this module? [y/N]:"; then
      local -a lines
      readarray -t lines < <(analyze_attrs "$path")

      if [[ ${#lines[@]} -eq 0 ]]; then
        echo
        echo "  WARNING: Could not auto-detect disease-signalling mechanisms."
        echo "  You can manually create a keep file. See config/keep_ra.json"
        echo "  for an example. Supported guards:"
        echo "    - Attribute is not nil"
        echo "    - Attribute == value"
      else
        echo
        echo "  Detected disease-signalling mechanisms:"
        echo
        # Deduplicate and present
        local -A dedup
        local -a choices
        local idx=1

        for line in "${lines[@]}"; do
          IFS='|' read -r typ attr op val codes sname <<< "$line"
          local key="${attr}|${op}"
          [[ -n "${dedup[$key]:-}" ]] && continue
          dedup[$key]=1

          printf '    [%d] Source : %s (%s)\n' "$idx" "$typ" "$sname"
          printf '        Attribute : "%s"\n' "$attr"
          printf '        Guard     : %s\n' "$op"
          [[ -n "$codes" ]] && printf '        SNOMED    : %s\n' "$codes"
          echo
          choices+=("$line")
          ((idx++))
        done

        local pick=1
        if [[ ${#choices[@]} -gt 1 ]]; then
          read -r -p "  Which mechanism to use? [1-${#choices[@]}] (default 1): " pick
          [[ -z "$pick" || ! "$pick" =~ ^[0-9]+$ ]] && pick=1
          if (( pick < 1 || pick > ${#choices[@]} )); then pick=1; fi
        fi

        IFS='|' read -r typ attr op val codes sname <<< "${choices[$((pick - 1))]}"

        local base="${mod_name%.json}"
        local keep_file="${KEEP_DIR}/keep_${base}.json"
        mkdir -p "$KEEP_DIR"
        generate_keep "$base" "$attr" "$op" "$val" "$keep_file"
      fi
    fi
    echo
  done

  box "DONE"
  echo "Installed modules are in:  config/modules/"
  echo "Keep files (if any) are in: config/"
  echo
  echo "Next steps:"
  echo "  1. Your module(s) are in config/modules/"
  echo "  2. Update KEEP_MODULE in scripts/02_simulate.sh (or config.yaml)"
  echo "  3. Update any SNOMED-code filters in the simulation script"
  echo "  4. Run:  bash scripts/02_simulate.sh"
}

main "$@"
