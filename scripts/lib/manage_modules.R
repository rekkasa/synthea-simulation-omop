#!/usr/bin/env Rscript
#
# manage_modules.R
# ---------------
# Interactive Synthea module manager.
#
# 1. Fetches available disease modules from the upstream Synthea repository.
# 2. Compares with modules already installed in config/modules/.
# 3. Lets the user choose which new modules to install.
# 4. For each selected module, asks:
#    - Whether to apply a 100 % incidence override (so every simulated
#      patient enters the disease pathway).
#    - Whether to generate a "keep" JSON file (so only patients who
#      developed the disease are retained after simulation).
#    - What patient attribute or prior-state the keep module should check.
#
# Dependencies (all managed by renv): jsonlite, httr, yaml

library(jsonlite)
library(httr)
library(yaml)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Detect the script location (works with both Rscript and source())
ARGS <- commandArgs(trailingOnly = FALSE)
SCRIPT_ARG <- grep("--file=", ARGS, value = TRUE)
if (length(SCRIPT_ARG) > 0) {
  SCRIPT_PATH <- sub("--file=", "", SCRIPT_ARG[1])
} else {
  # Assume we are already in the project root when sourced interactively
  SCRIPT_PATH <- file.path(getwd(), "scripts", "manage_modules.R")
}
ROOT_DIR <- normalizePath(file.path(dirname(SCRIPT_PATH), ".."))

MODULES_DIR <- file.path(ROOT_DIR, "config", "modules")
KEEP_DIR    <- file.path(ROOT_DIR, "config")

GITHUB_API_URL <- "https://api.github.com/repos/synthetichealth/synthea/contents/src/main/resources/modules"
RAW_BASE_URL   <- "https://raw.githubusercontent.com/synthetichealth/synthea/master/src/main/resources/modules"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

cat_box <- function(title) {
  line <- paste(rep("=", 70), collapse = "")
  cat("\n", line, "\n", sep = "")
  cat(" ", title, "\n")
  cat(line, "\n\n", sep = "")
}

# Fetch all .json module files from the upstream repo (file names only).
fetch_available_modules <- function() {
  cat("Fetching module listing from GitHub ...\n")
  resp <- GET(GITHUB_API_URL)
  if (http_error(resp)) {
    stop("Failed to fetch module list. HTTP ", status_code(resp))
  }
  items <- fromJSON(content(resp, as = "text", encoding = "UTF-8"),
                     simplifyDataFrame = TRUE)
  files <- items$name[items$type == "file" & grepl("\\.json$", items$name)]
  sort(files)
}

# List locally installed module .json files.
get_installed_modules <- function() {
  local <- list.files(MODULES_DIR, pattern = "\\.json$", full.names = FALSE)
  sort(local)
}

# Download a single module .json to config/modules/.
download_module <- function(name) {
  url  <- paste0(RAW_BASE_URL, "/", name)
  dest <- file.path(MODULES_DIR, name)
  cat(sprintf("  Downloading %s ...\n", name))
  resp <- GET(url)
  if (http_error(resp)) {
    stop(sprintf("  ERROR: Failed to download %s (HTTP %d)",
                 name, status_code(resp)))
  }
  writeLines(content(resp, as = "text", encoding = "UTF-8"), dest)
  cat(sprintf("  Saved to config/modules/%s\n", name))
  invisible(dest)
}

# ---------------------------------------------------------------------------
# Module analysis
# ---------------------------------------------------------------------------

#' Find the attribute(s) / prior-state(s) that signal disease occurrence.
#'
#' Returns a data.frame with columns:
#'   source, attribute, guard_type, guard_value, codes, state_name
#'
#' Deduplicated by (guard_type, attribute) so that multiple ConditionOnset
#' states that assign the same attribute appear as a single row.
analyze_module <- function(path) {
  mod    <- fromJSON(path, simplifyVector = FALSE)
  states <- mod$states
  results <- list()

  for (sname in names(states)) {
    s <- states[[sname]]

    # --- ConditionOnset with assign_to_attribute ---
    # Stores the condition entry; guard uses "is not nil" or PriorState.
    if (!is.null(s$type) && s$type == "ConditionOnset" &&
        !is.null(s$assign_to_attribute)) {
      codes <- if (!is.null(s$codes)) {
        paste(vapply(s$codes, function(x)
          paste0(x$code, " (", x$display, ")"), ""), collapse = "; ")
      } else {
        "no codes listed"
      }
      results[[length(results) + 1]] <- list(
        source      = sprintf("ConditionOnset '%s'", sname),
        attribute   = s$assign_to_attribute,
        guard_type  = sprintf("Attribute \"%s\" is not nil", s$assign_to_attribute),
        guard_value = sname,
        codes       = codes,
        state_name  = sname
      )
    }

    # --- Explicit SetAttribute states ---
    # Stores a named value; guard uses Attribute == <value>
    if (!is.null(s$type) && s$type == "SetAttribute" &&
        !is.null(s$attribute)) {
      val <- if (!is.null(s$value)) as.character(s$value) else "true"
      results[[length(results) + 1]] <- list(
        source      = sprintf("SetAttribute '%s'", sname),
        attribute   = s$attribute,
        guard_type  = sprintf("Attribute == %s", val),
        guard_value = val,
        codes       = NA_character_,
        state_name  = sname
      )
    }
  }

  if (length(results) == 0) return(NULL)

  df <- do.call(rbind, lapply(results, as.data.frame, stringsAsFactors = FALSE))
  rownames(df) <- NULL

  # Deduplicate: if multiple rows share the same (attribute, guard_type)
  # collapse them into one with merged codes.
  df <- df[order(df$source), ]
  keys <- paste(df$attribute, df$guard_type, sep = "::")
  dups <- duplicated(keys)
  if (any(dups)) {
    # For each unique key, combine codes and pick the first source name
    unique_keys <- unique(keys)
    merged <- lapply(unique_keys, function(k) {
      rows <- df[keys == k, , drop = FALSE]
      all_codes <- rows$codes[!is.na(rows$codes)]
      data.frame(
        source      = rows$source[1],
        attribute   = rows$attribute[1],
        guard_type  = rows$guard_type[1],
        guard_value = rows$guard_value[1],
        codes       = if (length(all_codes) > 0)
                        paste(unique(all_codes), collapse = " | ") else NA_character_,
        state_name  = rows$state_name[1],
        stringsAsFactors = FALSE
      )
    })
    df <- do.call(rbind, merged)
    rownames(df) <- NULL
  }

  df
}

#' Examine the Initial state to understand incidence gating.
#'
#' Returns a list with:
#'   - transition: the disease-pathway transition name (NULL if none)
#'   - probability: the incidence probability (1.0 if no gate)
#'   - type: "direct" / "distributed" / "complex" / "unknown"
examine_incidence <- function(path) {
  mod  <- fromJSON(path, simplifyVector = FALSE)
  init <- mod$states[["Initial"]]
  if (is.null(init)) {
    return(list(transition = NULL, probability = 1.0, type = "direct"))
  }

  # Already unconditional (direct transition)
  if (!is.null(init$direct_transition)) {
    return(list(
      transition  = init$direct_transition,
      probability = 1.0,
      type        = "direct"
    ))
  }

  # Gated by distributed_transition
  if (!is.null(init$distributed_transition)) {
    dts <- init$distributed_transition
    non_terminal <- Filter(
      function(x) !grepl("terminal", tolower(x$transition)), dts
    )
    if (length(non_terminal) == 0) {
      return(list(transition = NULL, probability = 0, type = "terminal_only"))
    }
    return(list(
      transition  = non_terminal[[1]]$transition,
      probability = non_terminal[[1]]$distribution,
      type        = "distributed"
    ))
  }

  # Complex transition (demographic-dependent branching)
  if (!is.null(init$complex_transition)) {
    transitions <- unique(vapply(init$complex_transition, function(branch) {
      branch$distributions[[1]]$transition
    }, ""))
    onset <- transitions[!grepl("terminal", tolower(transitions))]
    return(list(
      transition  = if (length(onset) > 0) onset[1] else NULL,
      probability = NA_real_,
      type        = "complex"
    ))
  }

  list(transition = NULL, probability = 1.0, type = "unknown")
}

# ---------------------------------------------------------------------------
# Incidence override
# ---------------------------------------------------------------------------

apply_incidence_override <- function(file_name, onset_transition) {
  path <- file.path(MODULES_DIR, file_name)
  mod  <- fromJSON(path, simplifyVector = FALSE)

  # Clear any gating mechanism
  mod$states[["Initial"]][["distributed_transition"]] <- NULL
  mod$states[["Initial"]][["complex_transition"]] <- NULL
  mod$states[["Initial"]][["direct_transition"]] <- onset_transition

  # Append a remark about the override
  new_remark <- sprintf(
    "LOCAL OVERRIDE: 100 %% incidence -- every patient is forced onto the '%s' disease pathway.",
    onset_transition
  )
  mod$remarks <- c(mod$remarks, new_remark)

  writeLines(toJSON(mod, auto_unbox = TRUE, pretty = TRUE), path)
  cat(sprintf("  Applied 100 %% incidence override (transition -> '%s').\n",
              onset_transition))
}

# ---------------------------------------------------------------------------
# Keep JSON generation
# ---------------------------------------------------------------------------

generate_keep_json <- function(file_name, info, keep_file) {
  # info is a one-row data.frame from analyze_module()
  module_name <- sub("\\.json$", "", file_name)
  attr_name   <- info$attribute

  # Determine the guard to use.
  # - ConditionOnset with assign_to_attribute  -> Attribute is-not-nil
  #   (one attribute shared by all subtypes, all set it)
  # - SetAttribute with explicit value         -> Attribute == <value>
  if (grepl("ConditionOnset", info$source)) {
    guard <- list(
      type = "Guard",
      allow = list(
        condition_type = "Attribute",
        attribute = attr_name,
        operator = "is not nil"
      ),
      direct_transition = "Keep"
    )
    guard_desc <- sprintf("Attribute '%s' is not nil", attr_name)
  } else {
    # Determine if the value is boolean or string
    gv <- info$guard_value
    is_bool <- tolower(gv) %in% c("true", "false")
    guard_value <- if (is_bool) as.logical(toupper(gv)) else gv
    guard <- list(
      type = "Guard",
      allow = list(
        condition_type = "Attribute",
        attribute = attr_name,
        operator = "==",
        value = guard_value
      ),
      direct_transition = "Keep"
    )
    guard_desc <- sprintf("Attribute '%s' == %s", attr_name, info$guard_value)
  }

  keep <- list(
    name = sprintf("Keep %s Patients",
                   gsub("_", " ", module_name)),
    remarks = c(
      "Synthea 'keep module' used with the -k command line flag.",
      "After a patient is fully simulated, Synthea runs this module against",
      "the finished record. The Guard state below only allows the module to",
      "reach the Keep state when the patient was ever diagnosed with the",
      "condition.",
      "",
      sprintf("Detection: %s", guard_desc),
      sprintf("Set by the '%s' module.", module_name)
    ),
    states = list(
      Initial = list(
        type = "Initial",
        direct_transition = "Keep_If_Condition"
      ),
      Keep_If_Condition = guard,
      Keep = list(
        type = "Terminal"
      )
    )
  )

  writeLines(toJSON(keep, auto_unbox = TRUE, pretty = TRUE), keep_file)
  cat(sprintf("  Generated keep module: config/%s  (%s)\n",
              basename(keep_file), guard_desc))
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

choose_modules <- function(new_modules) {
  if (length(new_modules) == 0) {
    cat("All upstream modules are already installed.\n")
    return(character(0))
  }

  cat_box("NEW MODULES AVAILABLE")
  for (i in seq_along(new_modules)) {
    cat(sprintf("  [%2d] %s\n", i, sub("\\.json$", "", new_modules[i])))
  }
  cat(sprintf("  [%2d] All of the above\n", length(new_modules) + 1))
  cat(sprintf("  [%2d] None (quit)\n\n", length(new_modules) + 2))

  repeat {
    ans <- readline("Enter number(s) separated by commas (e.g. 1,3,5): ")
    if (tolower(trimws(ans)) == "q"   ||
        trimws(ans) == ""             ||
        ans == as.character(length(new_modules) + 2)) {
      return(character(0))
    }

    nums <- suppressWarnings(
      as.integer(strsplit(gsub(" ", "", ans), ",")[[1]])
    )
    if (all(is.na(nums))) {
      cat("  Please enter valid numbers.\n")
      next
    }

    if (any(nums == length(new_modules) + 1)) {
      return(new_modules)
    }

    if (any(nums > length(new_modules) | nums < 1)) {
      cat(sprintf("  Numbers must be between 1 and %d.\n",
                  length(new_modules) + 2))
      next
    }

    return(new_modules[unique(nums)])
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main <- function() {
  cat_box("SYNTHEA MODULE MANAGER")

  # ---- Step 1: fetch upstream modules ----
  available <- fetch_available_modules()
  cat(sprintf("  Found %d modules upstream.\n", length(available)))

  # ---- Step 2: list installed ----
  installed <- get_installed_modules()

  # ---- Step 3: compute diff ----
  new_modules <- setdiff(available, installed)

  cat_box("STATUS")
  cat(sprintf("  Installed: %d\n", length(installed)))
  if (length(installed) > 0) {
    for (m in installed)
      cat(sprintf("    - %s\n", sub("\\.json$", "", m)))
  }
  cat(sprintf("  New (available, not installed): %d\n\n", length(new_modules)))

  # ---- Step 4: user picks modules to install ----
  selected <- choose_modules(new_modules)
  if (length(selected) == 0) {
    cat("No modules selected. Exiting.\n")
    return(invisible())
  }

  # ---- Step 5: for each selected module ----
  for (mod_name in selected) {
    cat_box(sprintf("INSTALLING: %s", sub("\\.json$", "", mod_name)))

    # 5a. Download
    download_module(mod_name)
    path <- file.path(MODULES_DIR, mod_name)

    # 5b. Incidence override
    inc <- examine_incidence(path)
    if (inc$type == "distributed") {
      cat(sprintf(
        "\n  Incidence is currently GATED at %.0f %% (transition '%s').\n",
        100 * inc$probability, inc$transition
      ))
      ans <- readline(
        "  Apply 100 %% incidence override? (every patient gets the disease) [y/N]: "
      )
      if (tolower(trimws(ans)) == "y") {
        apply_incidence_override(mod_name, inc$transition)
      }
    } else if (inc$type == "complex") {
      cat(sprintf(
        "\n  Incidence uses COMPLEX demographic-dependent branching (e.g. by gender/age).\n"
      ))
      cat(sprintf(
        "  Disease pathway transitions: %s\n",
        inc$transition
      ))
      cat("  Simplifying to a direct transition would lose demographic heterogeneity.\n")
      ans <- readline(
        "  Override anyway with a direct transition? [y/N]: "
      )
      if (tolower(trimws(ans)) == "y") {
        apply_incidence_override(mod_name, inc$transition)
      }
    } else {
      cat(sprintf(
        "\n  Incidence is UNCONDITIONAL (direct to '%s' -- already 100 %%).\n",
        inc$transition
      ))
    }

    # 5c. Keep JSON generation
    cat("\n")
    ans <- readline(
      "  Generate a 'keep' JSON file for this module? [y/N]: "
    )

    if (tolower(trimws(ans)) == "y") {
      attrs <- analyze_module(path)

      if (is.null(attrs) || nrow(attrs) == 0) {
        cat(
          "\n  WARNING: Could not auto-detect disease-signalling mechanisms.\n"
        )
        cat(
          "  You can manually create a keep file later. See config/keep_ra.json\n",
          "  for an example. Supported guards:\n",
          "    - PriorState: checks if patient ever entered a named state\n",
          "    - Attribute == value: checks if a patient attribute matches\n\n"
        )
      } else {
        cat("\n  Detected disease-signalling mechanisms in the module:\n\n")
        for (i in seq_len(nrow(attrs))) {
          cat(sprintf("    [%d] Source : %s\n", i, attrs$source[i]))
          cat(sprintf("        Attribute : \"%s\"\n", attrs$attribute[i]))
          cat(sprintf("        Guard     : %s\n", attrs$guard_type[i]))
          if (!is.na(attrs$codes[i])) {
            cat(sprintf("        SNOMED    : %s\n", attrs$codes[i]))
          }
          cat("\n")
        }

        if (nrow(attrs) == 1) {
          chosen <- attrs[1, ]
          cat(sprintf("  Using: %s\n", chosen$guard_type))
        } else {
          ans2 <- readline(
            sprintf("  Which mechanism to use? [1-%d] (default 1): ", nrow(attrs))
          )
          idx <- suppressWarnings(as.integer(trimws(ans2)))
          if (is.na(idx) || idx < 1 || idx > nrow(attrs)) idx <- 1
          chosen <- attrs[idx, ]
        }

        base      <- sub("\\.json$", "", mod_name)
        keep_file <- file.path(KEEP_DIR, paste0("keep_", base, ".json"))
        generate_keep_json(mod_name, chosen, keep_file)
      }
    }
  }

  # ---- Done ----
  cat_box("DONE")
  cat("Installed modules are in:  config/modules/\n")
  cat("Keep files (if any) are in: config/\n\n")
  cat("Next steps:\n")
  cat("  1. Place your desired disease module(s) in config/modules/\n")
  cat("  2. Update KEEP_MODULE and MODULE_DIR in scripts/02_simulate.sh\n")
  cat("     (or edit config.yaml to point to the correct paths)\n")
  cat("  3. Update any SNOMED-code filters in the simulation script\n")
  cat("  4. Run:  bash scripts/02_simulate.sh\n")
}

# ---- Run ----
if (sys.nframe() == 0L) {
  main()
}
