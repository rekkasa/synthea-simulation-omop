#!/usr/bin/env Rscript
#
# 03_etl.R
# --------
# Stage 3 of the Synthea -> OMOP pipeline.
#
# Loads the Synthea CSV output (stage 2) into an OMOP CDM v5.4 database stored
# in DuckDB, using the ETL-Synthea package (installed as 'ETLSyntheaBuilder')
# on top of DatabaseConnector.
#
# Pipeline of ETL-Synthea calls (in order):
#   1. CreateCDMTables        - empty CDM v5.4 schema
#   2. CreateSyntheaTables    - staging tables matching Synthea 3.3.0 CSVs
#   3. LoadSyntheaTables      - load the raw Synthea CSVs into staging
#   4. LoadVocabFromCsv       - load the OMOP Athena vocabulary CSVs
#   5. CreateMapAndRollupTables
#   6. CreateExtraIndices     - optional (toggled in config.yaml)
#   7. LoadEventTables        - populate the CDM clinical event tables
#
# Configuration is read from config.yaml (see project root).
# CLI positional args override config.yaml values:
#   Rscript scripts/03_etl.R [synthea_csv_dir] [duckdb_path] [vocab_dir]
#
# Run from the project root.

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("R package 'yaml' is required. Run scripts/00_setup_renv.R first.", call. = FALSE)
}
cfg <- yaml::read_yaml("config.yaml", eval.expr = FALSE)

args <- commandArgs(trailingOnly = TRUE)
synthea_csv_dir <- if (length(args) >= 1) args[[1]] else cfg$etl$synthea_csv_dir
duckdb_path     <- if (length(args) >= 2) args[[2]] else cfg$etl$duckdb_path
vocab_dir       <- if (length(args) >= 3) args[[3]] else cfg$etl$vocab_dir
CREATE_INDICES  <- as.logical(cfg$etl$create_indices %||% FALSE)
cdmVersion      <- cfg$etl$cdm_version %||% "5.4"
syntheaVersion  <- cfg$etl$synthea_version %||% "3.3.0"

# --- Preconditions ---------------------------------------------------------
if (!dir.exists(synthea_csv_dir) ||
    !file.exists(file.path(synthea_csv_dir, "patients.csv"))) {
  stop(sprintf(
    "Synthea CSV directory '%s' is missing or has no patients.csv. Run stage 2 first.",
    synthea_csv_dir))
}

# Reproduce the locked R environment (see scripts/00_setup_renv.R).
if (file.exists("renv.lock") && requireNamespace("renv", quietly = TRUE)) {
  renv::restore(prompt = FALSE)
}

# Athena vocabulary files are required by LoadVocabFromCsv. They are NOT bundled
# and must be downloaded manually (see README, 'OMOP vocabularies' section).
concept_present <- length(list.files(vocab_dir, pattern = "^CONCEPT\\.csv$",
                                     ignore.case = TRUE)) > 0
if (!dir.exists(vocab_dir) || !concept_present) {
  stop(sprintf(paste0(
    "Vocabulary directory '%s' is missing or does not contain CONCEPT.csv.\n",
    "Download the OMOP vocabularies from https://athena.ohdsi.org and extract\n",
    "them into that directory before running the ETL (see README)."), vocab_dir))
}

dir.create(dirname(duckdb_path), recursive = TRUE, showWarnings = FALSE)

library(ETLSyntheaBuilder)
library(DatabaseConnector)
library(DBI)
library(duckdb)

# --- Connection + schema configuration -------------------------------------
# DuckDB is a single-file, single-schema database; both the CDM and the Synthea
# staging tables live in the default 'main' schema.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms   = "duckdb",
  server = duckdb_path
)

# Poke memory limits into the DuckDB driver config so large-join operations
# (CreateMapAndRollupTables, LoadEventTables) don't OOM the process.
# DatabaseConnector's connectDuckdb reads extraSettings$config and passes it to
# duckdb::duckdb(config = ...).
connectionDetails$extraSettings <- list(
  config = list(memory_limit = "2GB", threads = "1",
                temp_directory = "/tmp/duckdb_spill")
)

cdmSchema      <- "main"
syntheaSchema  <- "main"

# Athena exports are tab-delimited despite the .csv extension.
vocab_delimiter <- "\t"

log_step <- function(msg) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), msg))

# Print row counts for a set of tables. Used after each ETL-Synthea load step
# so the user can verify that data actually landed in the database.
log_table_counts <- function(db_file, tables, label) {
  if (!file.exists(db_file)) return()
  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dbdir = db_file),
    error = function(e) NULL
  )
  if (is.null(con)) {
    log_step(sprintf("  Could not connect to %s to count %s tables", db_file, label))
    return()
  }
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  log_step(sprintf("  %s table counts:", label))
  for (tbl in tables) {
    n <- tryCatch(
      DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM main.%s", tbl))$n,
      error = function(e) NA_integer_
    )
    if (!is.na(n)) {
      message(sprintf("    %-30s %d", tbl, n))
    }
  }
}

# DuckDB-native vocabulary loader. ETLSyntheaBuilder::LoadVocabFromCsv loads
# entire CSVs into R data frames before inserting, which OOM-kills on machines
# with limited RAM. This loader uses DuckDB's native read_csv() to stream data
# directly from disk, bypassing R memory entirely.
load_vocab_duckdb_native <- function(db_file, vocab_dir, delimiter = "\t") {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_file)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  date_cast <- function(col) {
    sprintf("CAST(strptime(CAST(%s AS VARCHAR), '%%Y%%m%%d') AS DATE)", col)
  }

  load_one <- function(csv_basename, target_table, date_cols = character(0L),
                       where_clause = NULL) {
    csv_path  <- file.path(vocab_dir, csv_basename)
    if (!file.exists(csv_path)) {
      log_step(sprintf("  SKIP %s (file not found)", csv_basename))
      return()
    }
    log_step(sprintf("  Loading %s -> %s", csv_basename, target_table))

    cols <- DBI::dbGetQuery(con, sprintf(
      "SELECT column_name, data_type FROM information_schema.columns
       WHERE table_name = '%s' ORDER BY ordinal_position",
      target_table))

    # Build SELECT expressions: date cols get strptime cast, DECIMAL cols
    # get TRY_CAST (Athena exports can hold values outside DECIMAL range).
    select_parts <- sapply(seq_len(nrow(cols)), function(i) {
      cn <- cols$column_name[i]
      ct <- cols$data_type[i]
      if (cn %in% date_cols) {
        date_cast(cn)
      } else if (grepl("^DECIMAL", ct, ignore.case = TRUE)) {
        sprintf("TRY_CAST(%s AS %s)", cn, ct)
      } else {
        cn
      }
    })

    # Quote the CSV path for read_csv().
    read_src <- sprintf("read_csv('%s', header = true, delim = '%s',
      null_padding = true, ignore_errors = true)", csv_path, delimiter)

    # Build the source subquery; apply WHERE filter if provided.
    src_subq <- if (is.null(where_clause)) {
      read_src
    } else {
      sprintf("(SELECT * FROM %s WHERE %s)", read_src, where_clause)
    }

    DBI::dbExecute(con, sprintf("
      INSERT INTO %s (%s)
      SELECT %s FROM %s",
      target_table,
      paste(cols$column_name, collapse = ", "),
      paste(select_parts, collapse = ", "),
      src_subq))
  }

  # Core vocabulary tables. Athena exports dates as YYYYMMDD integers;
  # DuckDB DATE columns need explicit strptime casting.
  load_one("CONCEPT.csv",              "concept",
           date_cols = c("valid_start_date", "valid_end_date"))
  load_one("CONCEPT_CPT4.csv",         "concept",
           date_cols = c("valid_start_date", "valid_end_date"),
           where_clause = "concept_name IS NOT NULL AND concept_name != ''")
  load_one("VOCABULARY.csv",           "vocabulary")
  load_one("DOMAIN.csv",               "domain")
  load_one("CONCEPT_CLASS.csv",        "concept_class")
  load_one("RELATIONSHIP.csv",         "relationship")
  load_one("CONCEPT_SYNONYM.csv",      "concept_synonym")
  load_one("DRUG_STRENGTH.csv",        "drug_strength",
           date_cols = c("valid_start_date", "valid_end_date"))
  load_one("CONCEPT_RELATIONSHIP.csv", "concept_relationship",
           date_cols = c("valid_start_date", "valid_end_date"))
  load_one("CONCEPT_ANCESTOR.csv",     "concept_ancestor")

  log_step("  Vocabulary load complete.")
}

# Fallback loader used when ETL-Synthea's LoadEventTables populates zero rows
# under DuckDB. Builds the OMOP CDM event tables needed by the analyses
# directly from the Synthea staging tables using DuckDB-native SQL.
load_event_tables_duckdb_fallback <- function(db_file) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_file)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  run_sql <- function(label, sql) {
    n <- tryCatch(
      DBI::dbExecute(con, sql),
      error = function(e) {
        warning(sprintf("Fallback load failed for %s: %s", label, e$message), call. = FALSE)
        0L
      }
    )
    log_step(sprintf("  fallback %s: %d rows inserted", label, n))
  }

  # Synthea patient and encounter IDs are UUIDs, but OMOP uses BIGINT keys.
  # Build deterministic integer surrogate mappings once and reuse them.
  DBI::dbExecute(con, "
    CREATE TEMP TABLE patient_person_map AS
    SELECT Id AS patient_id, ROW_NUMBER() OVER ()::BIGINT AS person_id
    FROM patients
  ")
  DBI::dbExecute(con, "
    CREATE TEMP TABLE encounter_visit_map AS
    SELECT Id AS encounter_id, ROW_NUMBER() OVER ()::BIGINT AS visit_occurrence_id
    FROM encounters
  ")

  # person --------------------------------------------------------------------
  run_sql("person", "
    INSERT INTO person (
      person_id, gender_concept_id, year_of_birth, month_of_birth, day_of_birth,
      birth_datetime, race_concept_id, ethnicity_concept_id, gender_source_value,
      race_source_value, ethnicity_source_value
    )
    SELECT
      pm.person_id,
      COALESCE(g.concept_id, 0),
      EXTRACT(YEAR FROM p.BIRTHDATE::DATE)::INTEGER,
      EXTRACT(MONTH FROM p.BIRTHDATE::DATE)::INTEGER,
      EXTRACT(DAY FROM p.BIRTHDATE::DATE)::INTEGER,
      p.BIRTHDATE::TIMESTAMP,
      COALESCE(r.concept_id, 0),
      COALESCE(e.concept_id, 0),
      p.gender,
      p.race,
      p.ethnicity
    FROM patients p
    JOIN patient_person_map pm ON pm.patient_id = p.Id
    LEFT JOIN concept g ON g.concept_code = p.gender AND g.vocabulary_id = 'Gender' AND g.standard_concept = 'S'
    LEFT JOIN concept r ON r.concept_code = p.race AND r.vocabulary_id = 'Race' AND r.standard_concept = 'S'
    LEFT JOIN concept e ON e.concept_code = p.ethnicity AND e.vocabulary_id = 'Ethnicity' AND e.standard_concept = 'S'
  ")

  # observation_period --------------------------------------------------------
  run_sql("observation_period", "
    INSERT INTO observation_period (
      observation_period_id, person_id, observation_period_start_date,
      observation_period_end_date, period_type_concept_id
    )
    SELECT
      ROW_NUMBER() OVER ()::BIGINT,
      pm.person_id,
      p.BIRTHDATE::DATE,
      COALESCE(p.DEATHDATE::DATE, CURRENT_DATE),
      32817
    FROM patients p
    JOIN patient_person_map pm ON pm.patient_id = p.Id
  ")

  # visit_occurrence ----------------------------------------------------------
  run_sql("visit_occurrence", "
    INSERT INTO visit_occurrence (
      visit_occurrence_id, person_id, visit_concept_id, visit_start_date,
      visit_end_date, visit_type_concept_id, visit_source_value,
      visit_source_concept_id
    )
    SELECT
      m.visit_occurrence_id,
      pm.person_id,
      COALESCE(vc.concept_id, 0),
      e.START::DATE,
      e.STOP::DATE,
      32817,
      e.CODE,
      COALESCE(vcs.concept_id, 0)
    FROM encounters e
    JOIN encounter_visit_map m ON m.encounter_id = e.Id
    JOIN patient_person_map pm ON pm.patient_id = e.PATIENT
    LEFT JOIN concept vcs
      ON vcs.concept_code = e.CODE
     AND vcs.vocabulary_id = 'Visit'
     AND vcs.standard_concept = 'S'
    LEFT JOIN concept_relationship cr
      ON cr.concept_id_1 = vcs.concept_id AND cr.relationship_id = 'Maps to'
    LEFT JOIN concept vc
      ON vc.concept_id = COALESCE(cr.concept_id_2, vcs.concept_id)
     AND vc.standard_concept = 'S'
  ")

  # condition_occurrence ------------------------------------------------------
  run_sql("condition_occurrence", "
    INSERT INTO condition_occurrence (
      condition_occurrence_id, person_id, condition_concept_id,
      condition_start_date, condition_end_date, condition_type_concept_id,
      condition_status_concept_id, visit_occurrence_id, condition_source_value,
      condition_source_concept_id
    )
    SELECT
      ROW_NUMBER() OVER ()::BIGINT,
      pm.person_id,
      COALESCE(src.concept_id, 0),
      c.START::DATE,
      c.STOP::DATE,
      32817,
      0,
      m.visit_occurrence_id,
      c.CODE,
      COALESCE(src.concept_id, 0)
    FROM conditions c
    JOIN patient_person_map pm ON pm.patient_id = c.PATIENT
    LEFT JOIN encounter_visit_map m ON m.encounter_id = c.ENCOUNTER
    LEFT JOIN concept src
      ON src.concept_code = c.CODE
     AND src.vocabulary_id = 'SNOMED'
     AND src.standard_concept = 'S'
  ")

  # drug_exposure -------------------------------------------------------------
  run_sql("drug_exposure", "
    INSERT INTO drug_exposure (
      drug_exposure_id, person_id, drug_concept_id, drug_exposure_start_date,
      drug_exposure_end_date, drug_type_concept_id, visit_occurrence_id,
      drug_source_value, drug_source_concept_id
    )
    SELECT
      ROW_NUMBER() OVER ()::BIGINT,
      pm.person_id,
      COALESCE(src.concept_id, 0),
      m.START::DATE,
      m.STOP::DATE,
      32817,
      v.visit_occurrence_id,
      m.CODE,
      COALESCE(src.concept_id, 0)
    FROM medications m
    JOIN patient_person_map pm ON pm.patient_id = m.PATIENT
    LEFT JOIN encounter_visit_map v ON v.encounter_id = m.ENCOUNTER
    LEFT JOIN concept src
      ON src.concept_code = m.CODE
     AND src.vocabulary_id = 'RxNorm'
     AND src.standard_concept = 'S'
  ")

  # measurement ---------------------------------------------------------------
  run_sql("measurement", "
    INSERT INTO measurement (
      measurement_id, person_id, measurement_concept_id, measurement_date,
      measurement_type_concept_id, value_as_number, unit_concept_id,
      visit_occurrence_id, measurement_source_value, measurement_source_concept_id
    )
    SELECT
      ROW_NUMBER() OVER ()::BIGINT,
      pm.person_id,
      COALESCE(src.concept_id, 0),
      o.DATE::DATE,
      32817,
      TRY_CAST(o.VALUE AS DOUBLE),
      COALESCE(u.concept_id, 0),
      v.visit_occurrence_id,
      o.CODE,
      COALESCE(src.concept_id, 0)
    FROM observations o
    JOIN patient_person_map pm ON pm.patient_id = o.PATIENT
    LEFT JOIN encounter_visit_map v ON v.encounter_id = o.ENCOUNTER
    LEFT JOIN concept src
      ON src.concept_code = o.CODE
     AND src.vocabulary_id = 'LOINC'
     AND src.standard_concept = 'S'
    LEFT JOIN concept u
      ON u.concept_code = o.UNITS
     AND u.vocabulary_id = 'UCUM'
     AND u.standard_concept = 'S'
    WHERE o.TYPE IS NULL OR o.TYPE NOT IN ('text', 'string', 'social-history')
  ")

  # procedure_occurrence ------------------------------------------------------
  run_sql("procedure_occurrence", "
    INSERT INTO procedure_occurrence (
      procedure_occurrence_id, person_id, procedure_concept_id,
      procedure_date, procedure_type_concept_id, visit_occurrence_id,
      procedure_source_value, procedure_source_concept_id
    )
    SELECT
      ROW_NUMBER() OVER ()::BIGINT,
      pm.person_id,
      COALESCE(src.concept_id, 0),
      pr.START::DATE,
      32817,
      v.visit_occurrence_id,
      pr.CODE,
      COALESCE(src.concept_id, 0)
    FROM procedures pr
    JOIN patient_person_map pm ON pm.patient_id = pr.PATIENT
    LEFT JOIN encounter_visit_map v ON v.encounter_id = pr.ENCOUNTER
    LEFT JOIN concept src
      ON src.concept_code = pr.CODE
     AND src.vocabulary_id = 'SNOMED'
     AND src.standard_concept = 'S'
  ")

  # observation ---------------------------------------------------------------
  run_sql("observation", "
    INSERT INTO observation (
      observation_id, person_id, observation_concept_id, observation_date,
      observation_type_concept_id, value_as_string, value_as_number,
      unit_concept_id, visit_occurrence_id, observation_source_value,
      observation_source_concept_id
    )
    SELECT
      ROW_NUMBER() OVER ()::BIGINT,
      pm.person_id,
      COALESCE(src.concept_id, 0),
      o.DATE::DATE,
      32817,
      CASE WHEN o.TYPE IN ('text', 'string', 'social-history') THEN o.VALUE END,
      CASE WHEN o.TYPE = 'numeric' THEN TRY_CAST(o.VALUE AS DOUBLE) END,
      COALESCE(u.concept_id, 0),
      v.visit_occurrence_id,
      o.CODE,
      COALESCE(src.concept_id, 0)
    FROM observations o
    JOIN patient_person_map pm ON pm.patient_id = o.PATIENT
    LEFT JOIN encounter_visit_map v ON v.encounter_id = o.ENCOUNTER
    LEFT JOIN concept src
      ON src.concept_code = o.CODE
     AND src.vocabulary_id = 'LOINC'
     AND src.standard_concept = 'S'
    LEFT JOIN concept u
      ON u.concept_code = o.UNITS
     AND u.vocabulary_id = 'UCUM'
     AND u.standard_concept = 'S'
    WHERE o.TYPE IN ('text', 'string', 'social-history')
  ")

  # death ---------------------------------------------------------------------
  run_sql("death", "
    INSERT INTO death (person_id, death_date, death_type_concept_id)
    SELECT pm.person_id, p.DEATHDATE::DATE, 32817
    FROM patients p
    JOIN patient_person_map pm ON pm.patient_id = p.Id
    WHERE p.DEATHDATE IS NOT NULL AND p.DEATHDATE <> ''
  ")
}

# --- ETL sequence ----------------------------------------------------------
log_step("1/7 CreateCDMTables (CDM v5.4)")
ETLSyntheaBuilder::CreateCDMTables(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  cdmVersion        = cdmVersion
)

log_step("2/7 CreateSyntheaTables (Synthea 3.3.0 staging)")
ETLSyntheaBuilder::CreateSyntheaTables(
  connectionDetails = connectionDetails,
  syntheaSchema     = syntheaSchema,
  syntheaVersion    = syntheaVersion
)

log_step(sprintf("3/7 LoadSyntheaTables from %s", synthea_csv_dir))
log_step("    (duplicate CSV headers will be sanitized to a temp copy)")

# Synthea v3.3.0 can emit CSVs with duplicate column headers (notably
# claims_transactions.csv). DatabaseConnector/DuckDB rejects these when
# registering the R data frame. Work on a sanitized copy of the CSV directory
# so the original Synthea output is preserved.
sanitize_csv_dir <- function(src_dir) {
  dst_dir <- file.path(tempdir(), paste0("synthea_csv_sanitized_", Sys.getpid()))
  if (dir.exists(dst_dir)) unlink(dst_dir, recursive = TRUE)
  dir.create(dst_dir, recursive = TRUE, showWarnings = FALSE)

  files <- list.files(src_dir, pattern = "\\.csv$", full.names = TRUE)
  for (f in files) {
    header <- tryCatch(readLines(f, n = 1), error = function(e) NULL)
    out_file <- file.path(dst_dir, basename(f))

    if (is.null(header) || length(header) == 0) {
      file.copy(f, out_file)
      next
    }

    cols <- strsplit(header, ",")[[1]]
    cols <- gsub('^"|"$', "", cols)
    if (anyDuplicated(cols) == 0) {
      file.copy(f, out_file)
      next
    }

    message(sprintf("  Sanitizing duplicate headers in %s", basename(f)))
    df <- utils::read.csv(f, check.names = FALSE, stringsAsFactors = FALSE)
    df <- df[, !duplicated(names(df)), drop = FALSE]
    utils::write.csv(df, out_file, row.names = FALSE, quote = TRUE)
  }
  dst_dir
}

synthea_csv_dir_sanitized <- sanitize_csv_dir(synthea_csv_dir)

ETLSyntheaBuilder::LoadSyntheaTables(
  connectionDetails = connectionDetails,
  syntheaSchema     = syntheaSchema,
  syntheaFileLoc    = synthea_csv_dir_sanitized
)

# DuckDB + SqlRender schema-qualification bug: when syntheaSchema = "main",
# LoadSyntheaTables may insert into tables literally named "main.patients"
# (with a dot in the identifier) rather than the unqualified "patients".
# The unprefixed staging tables created by CreateSyntheaTables remain empty.
# Move the data from the prefixed tables into the correct unprefixed ones.
fix_duckdb_schema_prefix <- function(db_file, tables) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_file)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  for (tbl in tables) {
    prefixed <- sprintf("main.%s", tbl)
    has_prefixed <- tryCatch(
      DBI::dbGetQuery(con, sprintf(
        "SELECT COUNT(*) AS n FROM \"%s\"", prefixed))$n > 0,
      error = function(e) FALSE
    )
    if (has_prefixed) {
      log_step(sprintf("  Moving data from \"%s\" -> %s", prefixed, tbl))
      DBI::dbExecute(con, sprintf(
        "INSERT INTO %s SELECT * FROM \"%s\"", tbl, prefixed))
      DBI::dbExecute(con, sprintf("DROP TABLE \"%s\"", prefixed))
    }
  }
}

fix_duckdb_schema_prefix(duckdb_path, c(
  "patients", "encounters", "conditions", "medications", "procedures",
  "observations", "immunizations", "allergies", "careplans", "devices",
  "supplies", "imaging_studies", "organizations", "providers", "payers",
  "claims", "claims_transactions"
))

log_table_counts(duckdb_path, c(
  "patients", "encounters", "conditions", "medications", "procedures",
  "observations", "immunizations", "allergies", "careplans", "devices",
  "supplies", "imaging_studies", "organizations", "providers", "payers",
  "claims", "claims_transactions"
), "Synthea staging")

# Fail fast if staging tables are empty — the OMOP mapping steps and the
# DuckDB-native fallback both depend on them having data.
staging_patients_n <- local({
  con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dbdir = duckdb_path), error = function(e) NULL)
  if (is.null(con)) return(NA_integer_)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tryCatch(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM main.patients")$n,
    error = function(e) NA_integer_
  )
})
if (is.na(staging_patients_n) || staging_patients_n == 0) {
  stop(sprintf(paste0(
    "Staging table 'patients' is empty (%s rows). ",
    "LoadSyntheaTables did not populate the staging schema.\n",
    "  This usually means the SQL Server -> DuckDB translation in ",
    "ETLSyntheaBuilder did not produce valid DuckDB SQL.\n",
    "  Re-run with the ETL-Synthea steps replaced by DuckDB-native calls."),
    if (is.na(staging_patients_n)) "NA" else as.character(staging_patients_n)))
}

log_step(sprintf("4/7 LoadVocabFromCsv (DuckDB-native) from %s", vocab_dir))
load_vocab_duckdb_native(duckdb_path, vocab_dir, vocab_delimiter)
log_table_counts(duckdb_path, c(
  "concept", "concept_relationship", "concept_ancestor", "concept_synonym",
  "vocabulary", "domain", "concept_class", "relationship", "drug_strength"
), "Vocabulary")

log_step("5/7 CreateMapAndRollupTables")
ETLSyntheaBuilder::CreateMapAndRollupTables(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  syntheaSchema     = syntheaSchema,
  cdmVersion        = cdmVersion,
  syntheaVersion    = syntheaVersion
)
log_table_counts(duckdb_path, c(
  "source_to_concept_map", "source_to_standard_vocab_map",
  "source_to_source_vocab_map", "concept_counts"
), "ETL mapping")

if (CREATE_INDICES) {
  log_step("6/7 CreateExtraIndices")
  ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connectionDetails,
    cdmSchema         = cdmSchema,
    syntheaSchema     = syntheaSchema,
    syntheaVersion    = syntheaVersion
  )
} else {
  log_step("6/7 CreateExtraIndices (skipped; set CREATE_INDICES=TRUE to enable)")
}

log_step("7/7 LoadEventTables")
ETLSyntheaBuilder::LoadEventTables(
  connectionDetails = connectionDetails,
  cdmSchema         = cdmSchema,
  syntheaSchema     = syntheaSchema,
  cdmVersion        = cdmVersion,
  syntheaVersion    = syntheaVersion
)
log_table_counts(duckdb_path, c(
  "person", "observation_period", "visit_occurrence", "visit_detail",
  "condition_occurrence", "drug_exposure", "procedure_occurrence",
  "device_exposure", "measurement", "observation", "death", "location",
  "care_site", "provider", "payer_plan_period", "cost", "drug_era",
  "dose_era", "condition_era"
), "OMOP CDM event")

# ETL-Synthea's LoadEventTables can return success but populate zero rows when
# used with DuckDB via DatabaseConnector. If person is empty or missing, run a
# minimal DuckDB-native fallback that builds the tables the downstream analyses
# need.  (person_n_after_etl may be NA when the table does not exist at all —
# a silent SQL Server->DuckDB translation failure in CreateCDMTables.)
person_n_after_etl <- local({
  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dbdir = duckdb_path),
    error = function(e) NULL
  )
  if (is.null(con)) return(NA_integer_)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tryCatch(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM main.person")$n,
    error = function(e) NA_integer_
  )
})

if (is.na(person_n_after_etl) || person_n_after_etl == 0) {
  log_step("LoadEventTables produced 0 rows; running DuckDB fallback loader")
  load_event_tables_duckdb_fallback(duckdb_path)
  log_table_counts(duckdb_path, c(
    "person", "observation_period", "visit_occurrence",
    "condition_occurrence", "drug_exposure", "measurement",
    "procedure_occurrence", "device_exposure", "observation", "death"
  ), "OMOP CDM event (fallback)")
}

# Explicitly shut down the DuckDB file so the write-ahead log is fully
# checkpointed. ETL-Synthea's DatabaseConnector path may not trigger this for
# DuckDB, and a later read-only DBI connection (e.g. in 04_analyse.R) can then
# see empty tables.
shutdown_duckdb <- function(db_file) {
  if (!file.exists(db_file)) return()
  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dbdir = db_file),
    error = function(e) NULL
  )
  if (!is.null(con)) {
    DBI::dbDisconnect(con, shutdown = TRUE)
  }
}
shutdown_duckdb(duckdb_path)

# Final sanity check: if the person table is empty, the downstream analyses
# cannot run. Print a pointed warning rather than failing silently.
person_n <- local({
  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dbdir = duckdb_path),
    error = function(e) NULL
  )
  if (is.null(con)) return(NA_integer_)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tryCatch(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM main.person")$n,
    error = function(e) NA_integer_
  )
})

if (is.na(person_n) || person_n == 0) {
  warning(
    "\n",
    "=====================================================================\n",
    " OMOP CDM event tables are EMPTY. The most common causes are:\n",
    "  1. Stage 2 did not generate any patients (check logs/synthea_*.log).\n",
    "  2. Synthea staging tables are empty (check the 'Synthea staging'\n",
    "     counts printed above).\n",
    "  3. ETL-Synthea's LoadEventTables did not map rows for DuckDB\n",
    "     (check the 'ETL mapping' counts printed above).\n",
    "=====================================================================",
    call. = FALSE
  )
}

log_step(sprintf("ETL complete. OMOP CDM v5.4 written to %s", duckdb_path))
