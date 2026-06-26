# Synthea → OMOP: Rheumatoid Arthritis Cohort

A modular, parameterizable pipeline that simulates an **adult, rheumatoid-arthritis-only**
synthetic patient cohort with [Synthea](https://github.com/synthetichealth/synthea),
maps it to the **OMOP CDM v5.4** in a [DuckDB](https://duckdb.org/) database using
[ETL-Synthea](https://github.com/OHDSI/ETL-Synthea), and runs RA-focused analyses
(comorbidity profiling, disease progression, treatment patterns).

- **Simulation** is done in **bash** (Synthea is a Java JAR).
- **ETL and analysis** are done in **R** (ETL-Synthea + DuckDB).
- Everything is **parameterizable** (patient count, seed, state, …) and reproducible
  via a fixed default random seed.

---

## Pipeline at a glance

| Stage | Script | Language | Output |
|------:|--------|----------|--------|
| 0 | `scripts/00_setup_renv.R` | R | `renv.lock` (one-time) |
| 1 | `scripts/01_download_synthea.sh` | bash | `tools/synthea-with-dependencies.jar` |
| 2 | `scripts/02_simulate.sh` | bash | `data/synthea_output/csv/*.csv` |
| 3 | `scripts/03_etl.R` | R | `data/omop.duckdb` (OMOP CDM v5.4) |
| 4 | `scripts/04_analyse.R` | R | `results/*.csv` |
| — | `run_all.sh` | bash | runs stages 1→4 end-to-end |

The RA-only constraint is enforced by a Synthea **keep module**
(`config/keep_ra.json`, applied with `-k`), which discards any simulated patient
who does not have an active Rheumatoid arthritis condition (SNOMED 69896004).
The adults-only constraint is enforced with Synthea's age filter (`-a 18-`).

To keep that filter from throwing away ~99% of all simulation work (RA's
natural incidence is only ~1%), stage 2 also loads a **module override**
(`config/modules/rheumatoid_arthritis.json`, applied with `-d`) that forces
every adult onto the RA onset path. It changes only the onset probability, not
the RA disease model, so the kept cohort is statistically the same — just far
cheaper to produce.

---

## Prerequisites

1. **Java 11+** (to run the Synthea JAR) — `java -version`
2. **R ≥ 4.1** with internet access (to install R packages on first run)
3. **OMOP Athena vocabularies** (manual download — see below)
4. `curl` or `wget`

The Synthea JAR pinned by default is **v3.3.0**.

### OMOP vocabularies (required, manual step)

ETL-Synthea's `LoadVocabFromCsv` needs the OMOP Standardized Vocabularies, which
are **not** bundled and must be downloaded by hand (the site requires a login):

1. Go to <https://athena.ohdsi.org> and create a free account / log in.
2. Click **Download** and select at least these vocabularies:
   **SNOMED, RxNorm, LOINC, ICD10CM, CPT4, Visit, Gender, Race, Ethnicity**.
3. Submit the request; Athena emails a download link when the bundle is ready.
4. Download the ZIP and **extract it into `data/vocab/`**. After extraction the
   directory should contain `CONCEPT.csv`, `CONCEPT_RELATIONSHIP.csv`,
   `CONCEPT_ANCESTOR.csv`, `VOCABULARY.csv`, `DRUG_STRENGTH.csv`, etc.

> Athena's files are **tab-delimited** even though they end in `.csv`. Stage 3
> already accounts for this (`delimiter = "\t"`). The vocabulary files are large
> and are git-ignored.

---

## Quick start (end-to-end)

```bash
# from the project root
./run_all.sh
```

On the first run this will: generate `renv.lock` (installing R packages),
download the Synthea JAR, simulate 1,000 adult RA patients, build the OMOP CDM
in `data/omop.duckdb`, and write analysis CSVs to `results/`.

Make the scripts executable once if needed:

```bash
chmod +x run_all.sh scripts/*.sh
```

---

## Parameters

All parameters are environment variables with sensible defaults. Override them
inline:

```bash
# 100 patients, a different seed, California demographics
N_PATIENTS=100 SEED=42 STATE=California ./run_all.sh
```

| Variable | Default | Used by | Meaning |
|----------|---------|---------|---------|
| `N_PATIENTS` | `1000` | stage 2 | Number of adult RA patients to generate |
| `SEED` | `20240101` | stage 2 | Base random seed (reproducible cohort) |
| `STATE` | `Massachusetts` | stage 2 | US state for demographics |
| `SYNTHEA_VERSION` | `3.3.0` | stage 1 | Synthea release to download |
| `OUTPUT_DIR` | `data/synthea_output` | stages 2–3 | Synthea CSV output directory |
| `MODULE_DIR` | `config/modules` | stage 2 | Local Synthea module override dir (`-d`) |
| `DUCKDB_PATH` | `data/omop.duckdb` | stages 3–4 | OMOP CDM database file |
| `VOCAB_DIR` | `data/vocab` | stage 3 | Athena vocabulary directory |
| `MAX_ITERATIONS` | `50` | stage 2 | Safety cap on generation batches |
| `CREATE_INDICES` | `FALSE` | stage 3 | Build optional extra CDM indices |

For a fresh (non-reproducible) cohort each run, pass a varying seed, e.g.
`SEED=$RANDOM`.

---

## Running stages independently

Each stage is self-contained and can be re-run without re-running the others,
as long as its inputs exist.

```bash
# One-time R environment setup (creates renv.lock)
Rscript scripts/00_setup_renv.R

# Stage 1 — download the Synthea JAR (idempotent)
bash scripts/01_download_synthea.sh

# Stage 2 — simulate (re-uses the JAR)
N_PATIENTS=500 bash scripts/02_simulate.sh

# Stage 3 — ETL into OMOP (re-uses the CSVs and vocabularies)
Rscript scripts/03_etl.R data/synthea_output/csv data/omop.duckdb data/vocab

# Stage 4 — analyses (re-uses the OMOP database)
Rscript scripts/04_analyse.R data/omop.duckdb
```

> **Re-running stage 2** appends to the existing `data/synthea_output/csv`.
> Delete that directory first if you want a clean cohort.

---

## Outputs

### OMOP CDM database
`data/omop.duckdb` — a full OMOP CDM v5.4 instance (single `main` schema).
Query it from R:

```r
library(DBI)
con <- dbConnect(duckdb::duckdb(), "data/omop.duckdb", read_only = TRUE)
dbGetQuery(con, "SELECT COUNT(*) FROM person")
```

### Analysis results (`results/`)
| File | Contents |
|------|----------|
| `comorbidity_prevalence.csv` | Prevalence of CVD, osteoporosis, depression, diabetes in the RA cohort |
| `disease_progression.csv` | Longitudinal CRP / ESR values, with days from each patient's RA index date |
| `treatment_exposures.csv` | First exposure to each DMARD / biologic per patient |
| `time_to_first_treatment.csv` | First RA agent and days-to-first-treatment per patient |

---

## How the analyses resolve concepts

`04_analyse.R` does **not** hard-code OMOP concept ids. It resolves them at
runtime from the loaded vocabulary by their source codes, then expands to all
descendants via `concept_ancestor`:

- **RA cohort** — SNOMED `69896004` (Rheumatoid arthritis) and descendants.
- **Comorbidities** — SNOMED `49601007` (cardiovascular), `64859006`
  (osteoporosis), `35489007` (depression), `73211009` (diabetes).
- **Disease progression** — LOINC `1988-5` (CRP), `4537-7` (ESR).
- **Treatments** — RxNorm ingredients (methotrexate, hydroxychloroquine,
  sulfasalazine, leflunomide; adalimumab, etanercept, infliximab, rituximab,
  tocilizumab, abatacept).

If a code or domain has no data in the generated cohort, that section is written
as an empty table rather than failing. To target different conditions, drugs, or
markers, edit the code/name lists near the top of each analysis section.

---

## Repository layout

```
.
├── README.md
├── run_all.sh                     # end-to-end orchestrator
├── config/
│   ├── keep_ra.json               # Synthea keep module (RA-only filter)
│   └── modules/
│       └── rheumatoid_arthritis.json  # local module override (forces RA onset)
├── scripts/
│   ├── 00_setup_renv.R            # one-time R environment / renv.lock
│   ├── 01_download_synthea.sh     # download Synthea JAR
│   ├── 02_simulate.sh             # generate adult RA cohort (CSV)
│   ├── 03_etl.R                   # CSV -> OMOP CDM v5.4 (DuckDB)
│   └── 04_analyse.R               # RA analyses -> results/
├── tools/                         # (generated) Synthea JAR
├── data/
│   ├── synthea_output/csv/        # (generated) Synthea CSVs
│   ├── vocab/                     # (manual) Athena vocabularies
│   └── omop.duckdb                # (generated) OMOP CDM database
├── logs/                          # (generated) Synthea run logs
└── results/                       # (generated) analysis CSVs
```

---

## Troubleshooting

- **`java not found`** — install a JDK 11+ and ensure `java` is on `PATH`.
- **`CONCEPT.csv` missing / `LoadVocabFromCsv` fails** — the Athena vocabularies
  are not in `data/vocab/`. See the *OMOP vocabularies* section above.
- **Stage 2 hits `MAX_ITERATIONS`** — Synthea could not reach `N_PATIENTS`
  matching RA patients within the cap. Increase `MAX_ITERATIONS`, and check the
  newest `logs/synthea_*.log` for errors.
- **Package install fails in stage 0** — `ETLSyntheaBuilder` is installed from
  GitHub (`OHDSI/ETL-Synthea`); ensure R has internet access and the
  `remotes`/`renv` toolchain can reach GitHub.
