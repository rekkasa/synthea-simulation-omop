#!/usr/bin/env Rscript
#
# 04_analyse.R
# ------------
# Stage 4 of the Synthea -> OMOP pipeline.
#
# Reads the OMOP CDM v5.4 DuckDB database produced by stage 3 and produces three
# analyses for the rheumatoid-arthritis (RA) cohort:
#
#   1. Comorbidity profiling   - prevalence of cardiovascular disease,
#                                osteoporosis, depression and diabetes.
#   2. Disease progression     - longitudinal inflammatory markers (CRP, ESR)
#                                relative to each patient's RA index date.
#   3. Treatment patterns      - DMARD / biologic exposures, first-line agent,
#                                and time-to-first-treatment from the index date.
#
# Concept ids are resolved at runtime from the loaded vocabulary by their
# source codes (SNOMED / LOINC / RxNorm), so the script does not hard-code
# OMOP concept ids that might differ between vocabulary releases.
#
# Configuration is read from config.yaml (see project root).
# CLI positional arg overrides the duckdb_path:
#   Rscript scripts/04_analyse.R [duckdb_path]
#
# Run from the project root.

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("R package 'yaml' is required. Run scripts/00_setup_renv.R first.", call. = FALSE)
}
cfg <- yaml::read_yaml("config.yaml", eval.expr = FALSE)

args <- commandArgs(trailingOnly = TRUE)
duckdb_path <- if (length(args) >= 1) args[[1]] else cfg$etl$duckdb_path
results_dir <- cfg$analysis$results_dir %||% "results"

if (file.exists("renv.lock") && requireNamespace("renv", quietly = TRUE)) {
  renv::restore(prompt = FALSE)
}

if (!file.exists(duckdb_path)) {
  stop(sprintf("DuckDB database '%s' not found. Run stage 3 (03_etl.R) first.", duckdb_path))
}

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(readr)
})

dir.create(results_dir, recursive = TRUE, showWarnings = FALSE)

# Open read-write. DuckDB read-only connections can fail to see data if the
# previous writer did not fully checkpoint the file. The script does not modify
# CDM tables; it only reads and creates temporary tables.
con <- DBI::dbConnect(duckdb::duckdb(), dbdir = duckdb_path)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

log_step <- function(msg) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), msg))

# --- Concept resolution helpers -------------------------------------------

# Return the standard OMOP concept_id for a given source code + vocabulary, or
# NA if it is not present in the loaded vocabulary. Synthea condition/drug/
# measurement *_concept_id columns hold standard concepts, so we map the source
# code to its standard concept here.
resolve_standard_concept <- function(con, code, vocabulary_id) {
  q <- "
    SELECT concept_id
    FROM concept
    WHERE concept_code = ? AND vocabulary_id = ? AND standard_concept = 'S'
    LIMIT 1"
  res <- DBI::dbGetQuery(con, q, params = list(code, vocabulary_id))
  if (nrow(res) == 0) NA_integer_ else as.integer(res$concept_id[[1]])
}

# Resolve RxNorm ingredient concept_ids by name (case-insensitive). Treatment
# analysis works at the ingredient level and rolls drug exposures up to their
# ingredient via concept_ancestor.
resolve_ingredients <- function(con, names) {
  placeholders <- paste(rep("?", length(names)), collapse = ", ")
  q <- sprintf("
    SELECT concept_id, lower(concept_name) AS ingredient
    FROM concept
    WHERE vocabulary_id = 'RxNorm'
      AND concept_class_id = 'Ingredient'
      AND standard_concept = 'S'
      AND lower(concept_name) IN (%s)", placeholders)
  DBI::dbGetQuery(con, q, params = as.list(tolower(names)))
}

# Comma-separated list of an SQL integer set, for IN (...) clauses.
int_set <- function(ids) paste(ids, collapse = ", ")

# --- RA cohort -------------------------------------------------------------
# Cohort = persons with any condition that is RA or a descendant of RA in the
# vocabulary hierarchy (e.g. seropositive RA). Index date = earliest such
# condition_start_date.
ra_concept <- resolve_standard_concept(con, "69896004", "SNOMED")
if (is.na(ra_concept)) {
  stop("Could not resolve the standard concept for Rheumatoid arthritis (SNOMED 69896004). ",
       "Is the vocabulary loaded?")
}
log_step(sprintf("RA standard concept_id = %d", ra_concept))

DBI::dbExecute(con, sprintf("
  CREATE TEMP TABLE ra_cohort AS
  SELECT co.person_id, MIN(co.condition_start_date) AS index_date
  FROM condition_occurrence co
  WHERE co.condition_concept_id IN (
    SELECT descendant_concept_id FROM concept_ancestor WHERE ancestor_concept_id = %d
  )
  GROUP BY co.person_id", ra_concept))

cohort_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ra_cohort")$n
log_step(sprintf("RA cohort size = %d persons", cohort_n))
if (cohort_n == 0) {
  stop("RA cohort is empty - no RA conditions found in CONDITION_OCCURRENCE.")
}

# ===========================================================================
# 1. Comorbidity profiling
# ===========================================================================
log_step("Analysis 1/3: comorbidity prevalence")

comorbidities <- list(
  "Cardiovascular disease" = "49601007",  # Disorder of cardiovascular system
  "Osteoporosis"           = "64859006",
  "Depressive disorder"    = "35489007",
  "Diabetes mellitus"      = "73211009"
)

comorbidity_rows <- lapply(names(comorbidities), function(label) {
  snomed <- comorbidities[[label]]
  cid <- resolve_standard_concept(con, snomed, "SNOMED")
  if (is.na(cid)) {
    return(data.frame(comorbidity = label, snomed_code = snomed,
                      concept_id = NA_integer_, n_with = NA_integer_,
                      n_cohort = cohort_n, prevalence = NA_real_))
  }
  n_with <- DBI::dbGetQuery(con, sprintf("
    SELECT COUNT(DISTINCT rc.person_id) AS n
    FROM ra_cohort rc
    JOIN condition_occurrence co ON co.person_id = rc.person_id
    WHERE co.condition_concept_id IN (
      SELECT descendant_concept_id FROM concept_ancestor WHERE ancestor_concept_id = %d
    )", cid))$n
  data.frame(comorbidity = label, snomed_code = snomed, concept_id = cid,
             n_with = n_with, n_cohort = cohort_n,
             prevalence = round(n_with / cohort_n, 4))
})
comorbidity_prevalence <- do.call(rbind, comorbidity_rows)
readr::write_csv(comorbidity_prevalence,
                 file.path(results_dir, "comorbidity_prevalence.csv"))
print(comorbidity_prevalence)

# ===========================================================================
# 2. Disease progression (longitudinal inflammatory markers)
# ===========================================================================
log_step("Analysis 2/3: disease progression (CRP / ESR)")

markers <- list(
  "C-reactive protein"             = "1988-5",
  "Erythrocyte sedimentation rate" = "4537-7"
)

marker_ids <- vapply(markers, function(loinc) resolve_standard_concept(con, loinc, "LOINC"),
                     integer(1))
marker_ids <- marker_ids[!is.na(marker_ids)]

if (length(marker_ids) == 0) {
  log_step("No CRP/ESR measurement concepts found; writing empty progression table.")
  disease_progression <- data.frame(
    person_id = integer(0), measurement_concept_id = integer(0),
    marker = character(0), measurement_date = as.Date(character(0)),
    days_from_index = integer(0), value_as_number = numeric(0))
} else {
  label_map <- data.frame(
    measurement_concept_id = unname(marker_ids),
    marker = names(marker_ids),
    stringsAsFactors = FALSE)
  disease_progression <- DBI::dbGetQuery(con, sprintf("
    SELECT m.person_id,
           m.measurement_concept_id,
           m.measurement_date,
           CAST(m.measurement_date - rc.index_date AS INTEGER) AS days_from_index,
           m.value_as_number
    FROM measurement m
    JOIN ra_cohort rc ON rc.person_id = m.person_id
    WHERE m.measurement_concept_id IN (%s)
    ORDER BY m.person_id, m.measurement_date", int_set(unname(marker_ids))))
  disease_progression <- merge(disease_progression, label_map,
                               by = "measurement_concept_id", all.x = TRUE)
}
readr::write_csv(disease_progression,
                 file.path(results_dir, "disease_progression.csv"))
log_step(sprintf("Disease progression: %d measurement rows", nrow(disease_progression)))

# ===========================================================================
# 3. Treatment patterns (DMARDs / biologics)
# ===========================================================================
log_step("Analysis 3/3: treatment patterns")

dmards    <- c("methotrexate", "hydroxychloroquine", "sulfasalazine", "leflunomide")
biologics <- c("adalimumab", "etanercept", "infliximab", "rituximab",
               "tocilizumab", "abatacept")
ing_class <- c(setNames(rep("DMARD", length(dmards)), dmards),
               setNames(rep("biologic", length(biologics)), biologics))

ingredients <- resolve_ingredients(con, names(ing_class))

if (nrow(ingredients) == 0) {
  log_step("No RA treatment ingredients found; writing empty treatment tables.")
  treatment_exposures <- data.frame(
    person_id = integer(0), ingredient = character(0), drug_class = character(0),
    first_exposure_date = as.Date(character(0)), days_from_index = integer(0))
  time_to_first_treatment <- data.frame(
    person_id = integer(0), first_treatment_date = as.Date(character(0)),
    days_from_index = integer(0))
} else {
  ingredients$drug_class <- ing_class[ingredients$ingredient]

  # First exposure per person per ingredient. drug_exposure.drug_concept_id is
  # rolled up to its ingredient via concept_ancestor.
  per_ingredient <- lapply(seq_len(nrow(ingredients)), function(i) {
    ing_id    <- ingredients$concept_id[[i]]
    ing_name  <- ingredients$ingredient[[i]]
    ing_class <- ingredients$drug_class[[i]]
    rows <- DBI::dbGetQuery(con, sprintf("
      SELECT de.person_id,
             MIN(de.drug_exposure_start_date) AS first_exposure_date,
             CAST(MIN(de.drug_exposure_start_date) - rc.index_date AS INTEGER) AS days_from_index
      FROM drug_exposure de
      JOIN ra_cohort rc ON rc.person_id = de.person_id
      WHERE de.drug_concept_id IN (
        SELECT descendant_concept_id FROM concept_ancestor WHERE ancestor_concept_id = %d
      )
      GROUP BY de.person_id, rc.index_date", ing_id))
    if (nrow(rows) == 0) return(NULL)
    rows$ingredient <- ing_name
    rows$drug_class <- ing_class
    rows[, c("person_id", "ingredient", "drug_class",
             "first_exposure_date", "days_from_index")]
  })
  treatment_exposures <- do.call(rbind, Filter(Negate(is.null), per_ingredient))
  if (is.null(treatment_exposures)) {
    treatment_exposures <- data.frame(
      person_id = integer(0), ingredient = character(0), drug_class = character(0),
      first_exposure_date = as.Date(character(0)), days_from_index = integer(0))
  }

  # Time to first RA treatment of any kind, per person.
  if (nrow(treatment_exposures) > 0) {
    ord <- order(treatment_exposures$person_id, treatment_exposures$first_exposure_date)
    te <- treatment_exposures[ord, ]
    first_idx <- !duplicated(te$person_id)
    time_to_first_treatment <- data.frame(
      person_id            = te$person_id[first_idx],
      first_treatment_date = te$first_exposure_date[first_idx],
      first_agent          = te$ingredient[first_idx],
      first_agent_class    = te$drug_class[first_idx],
      days_from_index      = te$days_from_index[first_idx])
  } else {
    time_to_first_treatment <- data.frame(
      person_id = integer(0), first_treatment_date = as.Date(character(0)),
      first_agent = character(0), first_agent_class = character(0),
      days_from_index = integer(0))
  }
}

readr::write_csv(treatment_exposures,
                 file.path(results_dir, "treatment_exposures.csv"))
readr::write_csv(time_to_first_treatment,
                 file.path(results_dir, "time_to_first_treatment.csv"))
log_step(sprintf("Treatment exposures: %d rows; patients treated: %d",
                 nrow(treatment_exposures), nrow(time_to_first_treatment)))

log_step(sprintf("Analysis complete. Results written to '%s/'.", results_dir))
