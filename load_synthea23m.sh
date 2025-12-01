#!/usr/bin/env bash
set -euo pipefail

# OMOP CDM Schema Test Script
# Tests the CDM5.3.0_DDL_PostgreSQL.sql schema file in a fresh PostgreSQL container
# and loads data from omop-data folder

########################################
# Configuration
########################################

# Docker / Postgres
POSTGRES_IMAGE="postgres:16"
CONTAINER_NAME="pg-omop"

PG_SUPERUSER="postgres"
PG_SUPERPASS="testpass123"

TEST_DB="ohdsi"
TEST_SCHEMA="omop531"

HOST_PORT=5434  # Different port to avoid conflicts
CONTAINER_PORT=5432

# Schema file to test
SCHEMA_FILE="./omop-schema/CDM5.3.0_DDL_PostgreSQL.sql"

# Dataset configuration
DATASET_NAME="synthea23m"  # Change this to use different datasets (synthea1k, synthea10k, synthea23m, etc.)

# Data paths
HOST_DATA_DIR="$PWD/omop-data"
VOCAB_DIR="$HOST_DATA_DIR/vocab"
PATIENT_DIR="$HOST_DATA_DIR/$DATASET_NAME"
CONTAINER_DATA_DIR="/data"

# PostgreSQL data persistence
PGDATA_DIR="$PWD/pgdata"

# S3 source (public OHDSI sample data)
S3_SYNTHEA="s3://ohdsi-sample-data/$DATASET_NAME"
S3_VOCAB="s3://ohdsi-sample-data/vocab"

########################################
# Helpers
########################################

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' not found in PATH. Please install it first." >&2
    exit 1
  fi
}

wait_for_postgres() {
  log "Waiting for Postgres to be ready..."
  local max_attempts=30
  local attempt=0
  until docker exec "$CONTAINER_NAME" pg_isready -U "$PG_SUPERUSER" > /dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ $attempt -ge $max_attempts ]; then
      log "ERROR: Postgres failed to start after $max_attempts attempts"
      exit 1
    fi
    sleep 1
  done
  log "Postgres is ready."
}

psql_super() {
  docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" "$@"
}

cleanup() {
  log "Cleaning up test container..."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  log "PostgreSQL data persisted at: $PGDATA_DIR"
  log "To remove the data, run: rm -rf $PGDATA_DIR"
}

########################################
# Step 0: Sanity checks
########################################

require_cmd docker
require_cmd aws
require_cmd psql
require_cmd lzop
require_cmd bunzip2

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "ERROR: Schema file '$SCHEMA_FILE' not found." >&2
  exit 1
fi

# Create data directories if they don't exist
mkdir -p "$VOCAB_DIR" "$PATIENT_DIR" "$PGDATA_DIR"

log "Testing schema file: $SCHEMA_FILE"
log "Data directory: $HOST_DATA_DIR"
log "PostgreSQL data directory: $PGDATA_DIR"

########################################
# Step 1: Download data from S3 (if not already present)
########################################

if [[ ! -f "$VOCAB_DIR/CONCEPT.csv" ]]; then
  log "Syncing OMOP vocabulary data from $S3_VOCAB ..."
  aws s3 sync "$S3_VOCAB" "$VOCAB_DIR" --no-sign-request
else
  log "Vocabulary data already present, skipping download."
fi

if [[ ! -f "$PATIENT_DIR/person.csv" ]]; then
  log "Syncing Synthea OMOP patient-level data from $S3_SYNTHEA ..."
  aws s3 sync "$S3_SYNTHEA" "$PATIENT_DIR" --no-sign-request
else
  log "Patient data already present, skipping download."
fi

########################################
# Step 2: Decompress data (lzop, bzip2)
########################################

# Decompress .lzo in patient data, if present
if ls "$PATIENT_DIR"/*.lzo >/dev/null 2>&1; then
  require_cmd lzop
  log "Decompressing .lzo files in $DATASET_NAME ..."
  for f in "$PATIENT_DIR"/*.lzo; do
    log "  lzop -d $f"
    lzop -d "$f"
  done
else
  log "No .lzo files found in $DATASET_NAME; assuming plain .csv already."
fi

# Decompress .bz2 in vocab, if present
if ls "$VOCAB_DIR"/*.bz2 >/dev/null 2>&1; then
  require_cmd bunzip2
  log "Decompressing .bz2 files in vocab ..."
  for f in "$VOCAB_DIR"/*.bz2; do
    log "  bunzip2 $f"
    bunzip2 "$f"
  done
else
  log "No .bz2 files found in vocab; assuming plain .csv already."
fi

########################################
# Step 3: Clean up any existing test container
########################################

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
  log "Test container $CONTAINER_NAME already exists. Stopping & removing it..."
  cleanup
fi

########################################
# Step 4: Start fresh Postgres container
########################################

log "Starting test Postgres container: $CONTAINER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  -e POSTGRES_USER="$PG_SUPERUSER" \
  -e POSTGRES_PASSWORD="$PG_SUPERPASS" \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -v "${HOST_DATA_DIR}:${CONTAINER_DATA_DIR}" \
  -v "${PGDATA_DIR}:/var/lib/postgresql/data" \
  "$POSTGRES_IMAGE"

wait_for_postgres

########################################
# Step 5: Create test database and schema
########################################

log "Creating test database: $TEST_DB"
psql_super -c "CREATE DATABASE ${TEST_DB};"

log "Creating test schema: $TEST_SCHEMA"
psql_super -d "$TEST_DB" -c "CREATE SCHEMA ${TEST_SCHEMA};"

########################################
# Step 6: Apply OMOP CDM schema
########################################

log "Applying OMOP CDM schema..."
# Replace @cdmDatabaseSchema placeholder with test schema name
sed "s/@cdmDatabaseSchema/${TEST_SCHEMA}/g" "$SCHEMA_FILE" | psql_super -d "$TEST_DB"

log "Schema applied successfully."

########################################
# Step 7: Load data from omop-data folder
########################################

log "Loading data into OMOP CDM tables..."

# Helper function to load CSV with psql \copy
load_csv() {
  local table="$1"
  local file="$2"
  local delim="$3"   # ',' or '\t'
  local has_header="${4:-true}"  # Default to true for patient files
  
  if [[ ! -f "$file" ]]; then
    log "  SKIP: File not found: $file"
    return
  fi
  
  local row_count
  row_count=$(wc -l < "$file" | tr -d ' ')
  
  if [[ "$has_header" == "true" ]]; then
    log "  Loading ${table} from $(basename "$file") (${row_count} rows with header)..."
  else
    log "  Loading ${table} from $(basename "$file") (${row_count} rows, no header)..."
  fi
  
  # Use container path
  local container_file="${CONTAINER_DATA_DIR}${file#$HOST_DATA_DIR}"
  
  # For tab-delimited files, disable quoting since fields are not quoted
  # and may contain literal quote characters
  if [[ "$delim" == $'\t' ]]; then
    docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" -d "$TEST_DB" <<EOF
SET session_replication_role = 'replica';
\set ON_ERROR_STOP on
\copy ${TEST_SCHEMA}.${table} FROM '${container_file}' WITH (FORMAT text, DELIMITER E'\t', NULL '', HEADER ${has_header});
SET session_replication_role = 'origin';
EOF
  else
    # For comma-delimited files, use CSV format with proper quoting
    docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" -d "$TEST_DB" <<EOF
SET session_replication_role = 'replica';
\set ON_ERROR_STOP on
\copy ${TEST_SCHEMA}.${table} FROM '${container_file}' WITH (FORMAT csv, DELIMITER ',', QUOTE '"', ESCAPE '"', NULL '', HEADER ${has_header});
SET session_replication_role = 'origin';
EOF
  fi

  if [[ $? -eq 0 ]]; then
    local loaded_count
    loaded_count=$(psql_super -d "$TEST_DB" -t -c "SELECT COUNT(*) FROM ${TEST_SCHEMA}.${table};" | tr -d ' ')
    log "    ✓ Loaded ${loaded_count} rows into ${table}"
  else
    log "    ✗ Failed to load ${table}"
  fi
}

# Load data in dependency order
log "Step 1: Loading vocabulary reference tables (no dependencies)..."
load_csv "vocabulary" "$VOCAB_DIR/VOCABULARY.csv" $'\t'
load_csv "domain" "$VOCAB_DIR/DOMAIN.csv" $'\t'
load_csv "concept_class" "$VOCAB_DIR/CONCEPT_CLASS.csv" $'\t'
load_csv "relationship" "$VOCAB_DIR/RELATIONSHIP.csv" $'\t'

log "Step 2: Loading concept table (depends on vocabulary, domain, concept_class)..."
load_csv "concept" "$VOCAB_DIR/CONCEPT.csv" $'\t'

log "Step 3: Loading concept relationship tables (depend on concept)..."
load_csv "concept_relationship" "$VOCAB_DIR/CONCEPT_RELATIONSHIP.csv" $'\t'
load_csv "concept_synonym" "$VOCAB_DIR/CONCEPT_SYNONYM.csv" $'\t'
load_csv "concept_ancestor" "$VOCAB_DIR/CONCEPT_ANCESTOR.csv" $'\t'

log "Step 4: Loading drug strength (depends on concept)..."
load_csv "drug_strength" "$VOCAB_DIR/DRUG_STRENGTH.csv" $'\t'

log "Step 5: Loading person table (base patient table)..."
load_csv "person" "$PATIENT_DIR/person.csv" ','

log "Step 6: Loading clinical event tables (depend on person and concept)..."
load_csv "observation_period" "$PATIENT_DIR/observation_period.csv" ','

# For large datasets like synthea23m, files are split into chunks (.csv.0, .csv.1, etc.)
# Load all chunks for each table
for table_base in "visit_occurrence" "condition_occurrence" "drug_exposure" "procedure_occurrence" "measurement" "observation"; do
  if [[ -f "$PATIENT_DIR/${table_base}.csv" ]]; then
    # Single file exists (e.g., synthea1k)
    load_csv "$table_base" "$PATIENT_DIR/${table_base}.csv" ','
  else
    # Load chunked files (e.g., synthea23m: .csv.0, .csv.1, .csv.2, .csv.3)
    for chunk in "$PATIENT_DIR/${table_base}.csv."*; do
      if [[ -f "$chunk" ]] && [[ ! "$chunk" =~ \.lzo$ ]]; then
        log "  Loading chunk: $(basename "$chunk")"
        load_csv "$table_base" "$chunk" ','
      fi
    done
  fi
done

log "Step 7: Loading era tables (depend on clinical events)..."
for table_base in "drug_era" "condition_era"; do
  if [[ -f "$PATIENT_DIR/${table_base}.csv" ]]; then
    # Single file exists (e.g., synthea1k)
    load_csv "$table_base" "$PATIENT_DIR/${table_base}.csv" ','
  else
    # Load chunked files (e.g., synthea23m: .csv.0, .csv.1, .csv.2, .csv.3)
    for chunk in "$PATIENT_DIR/${table_base}.csv."*; do
      if [[ -f "$chunk" ]] && [[ ! "$chunk" =~ \.lzo$ ]]; then
        log "  Loading chunk: $(basename "$chunk")"
        load_csv "$table_base" "$chunk" ','
      fi
    done
  fi
done

log "Data loading complete."

########################################
# Step 8: Verify tables were created
########################################

log "Verifying tables were created..."

# Count tables in the schema
table_count=$(psql_super -d "$TEST_DB" -t -c "
SELECT COUNT(*)
FROM information_schema.tables
WHERE table_schema = '${TEST_SCHEMA}'
  AND table_type = 'BASE TABLE';
" | tr -d ' ')

log "Found $table_count tables in schema ${TEST_SCHEMA}"

# Expected OMOP CDM tables (39 tables in CDM 5.3)
expected_tables=(
  "concept"
  "vocabulary"
  "domain"
  "concept_class"
  "concept_relationship"
  "relationship"
  "concept_synonym"
  "concept_ancestor"
  "source_to_concept_map"
  "drug_strength"
  "cohort_definition"
  "attribute_definition"
  "cdm_source"
  "metadata"
  "person"
  "observation_period"
  "specimen"
  "death"
  "visit_occurrence"
  "visit_detail"
  "procedure_occurrence"
  "drug_exposure"
  "device_exposure"
  "condition_occurrence"
  "measurement"
  "note"
  "note_nlp"
  "observation"
  "fact_relationship"
  "location"
  "care_site"
  "provider"
  "payer_plan_period"
  "cost"
  "cohort"
  "cohort_attribute"
  "drug_era"
  "dose_era"
  "condition_era"
)

log "Checking for expected OMOP CDM tables..."
missing_tables=()
for table in "${expected_tables[@]}"; do
  exists=$(psql_super -d "$TEST_DB" -t -c "
  SELECT EXISTS (
    SELECT FROM information_schema.tables
    WHERE table_schema = '${TEST_SCHEMA}'
      AND table_name = '${table}'
  );" | tr -d ' ')
  
  if [[ "$exists" == "t" ]]; then
    echo "  ✓ ${table}"
  else
    echo "  ✗ ${table} (MISSING)"
    missing_tables+=("$table")
  fi
done

if [ ${#missing_tables[@]} -eq 0 ]; then
  log "✓ All expected tables found!"
else
  log "✗ Missing ${#missing_tables[@]} tables: ${missing_tables[*]}"
  exit 1
fi

########################################
# Step 6: Verify primary keys
########################################

log "Checking primary keys..."
pk_count=$(psql_super -d "$TEST_DB" -t -c "
SELECT COUNT(*)
FROM information_schema.table_constraints
WHERE table_schema = '${TEST_SCHEMA}'
  AND constraint_type = 'PRIMARY KEY';
" | tr -d ' ')

log "Found $pk_count primary key constraints"

# Check a few key tables have primary keys
key_tables_with_pk=("person" "concept" "observation_period")
for table in "${key_tables_with_pk[@]}"; do
  has_pk=$(psql_super -d "$TEST_DB" -t -c "
  SELECT EXISTS (
    SELECT FROM information_schema.table_constraints
    WHERE table_schema = '${TEST_SCHEMA}'
      AND table_name = '${table}'
      AND constraint_type = 'PRIMARY KEY'
  );" | tr -d ' ')
  
  if [[ "$has_pk" == "t" ]]; then
    echo "  ✓ ${table} has primary key"
  else
    echo "  ✗ ${table} missing primary key"
  fi
done

########################################
# Step 10: Verify foreign keys
########################################

log "Checking foreign keys..."
fk_count=$(psql_super -d "$TEST_DB" -t -c "
SELECT COUNT(*)
FROM information_schema.table_constraints
WHERE table_schema = '${TEST_SCHEMA}'
  AND constraint_type = 'FOREIGN KEY';
" | tr -d ' ')

log "Found $fk_count foreign key constraints"

########################################
# Step 11: Check for Redshift-specific syntax (should be none)
########################################

log "Checking for Redshift-specific syntax remnants..."
redshift_keywords=("DISTKEY" "DISTSTYLE" "SORTKEY" "encode" "compound sortkey")
found_redshift_syntax=false

for keyword in "${redshift_keywords[@]}"; do
  if grep -i "$keyword" "$SCHEMA_FILE" > /dev/null 2>&1; then
    log "  ✗ Found Redshift keyword: $keyword"
    found_redshift_syntax=true
  fi
done

if [ "$found_redshift_syntax" = false ]; then
  log "  ✓ No Redshift-specific syntax found"
fi

########################################
# Step 12: Test data types compatibility
########################################

log "Checking data type compatibility..."

# Check that TEXT is used instead of VARCHAR(MAX)
text_count=$(psql_super -d "$TEST_DB" -t -c "
SELECT COUNT(*)
FROM information_schema.columns
WHERE table_schema = '${TEST_SCHEMA}'
  AND data_type = 'text';
" | tr -d ' ')

log "Found $text_count TEXT columns (converted from VARCHAR(MAX))"

# Check BIGINT usage for large ID columns
bigint_count=$(psql_super -d "$TEST_DB" -t -c "
SELECT COUNT(*)
FROM information_schema.columns
WHERE table_schema = '${TEST_SCHEMA}'
  AND data_type = 'bigint';
" | tr -d ' ')

log "Found $bigint_count BIGINT columns"

########################################
# Step 13: Verify data was loaded
########################################

log "Verifying data was loaded..."

# Check row counts for key tables
check_row_count() {
  local table="$1"
  local count
  count=$(psql_super -d "$TEST_DB" -t -c "SELECT COUNT(*) FROM ${TEST_SCHEMA}.${table};" 2>/dev/null | tr -d ' ')
  if [[ -n "$count" && "$count" -gt 0 ]]; then
    log "  ✓ ${table}: ${count} rows" >&2
    echo "$count"
  else
    log "  ○ ${table}: 0 rows (or table doesn't exist)" >&2
    echo "0"
  fi
}

vocab_count=$(check_row_count "vocabulary")
concept_count=$(check_row_count "concept")
person_count=$(check_row_count "person")
visit_count=$(check_row_count "visit_occurrence")
condition_count=$(check_row_count "condition_occurrence")

########################################
# Step 14: Summary
########################################

log ""
log "=== SCHEMA AND DATA LOAD TEST SUMMARY ==="
log "Schema file: $SCHEMA_FILE"
log "Test database: $TEST_DB"
log "Test schema: $TEST_SCHEMA"
log ""
log "Schema Statistics:"
log "  Tables created: $table_count"
log "  Primary keys: $pk_count"
log "  Foreign keys: $fk_count"
log "  TEXT columns: $text_count"
log "  BIGINT columns: $bigint_count"
log ""
log "Data Statistics:"
log "  Vocabulary entries: $vocab_count"
log "  Concepts: $concept_count"
log "  Persons: $person_count"
log "  Visits: $visit_count"
log "  Conditions: $condition_count"
log ""

if [ ${#missing_tables[@]} -eq 0 ] && [ "$found_redshift_syntax" = false ]; then
  log "✓ Schema test PASSED!"
  
  if [[ "$concept_count" -gt 0 && "$person_count" -gt 0 ]]; then
    log "✓ Data loading PASSED!"
  else
    log "⚠ Data loading incomplete (some tables may be empty)"
  fi
  
  log ""
  log "To connect to the test database:"
  log "  psql -h localhost -p ${HOST_PORT} -U ${PG_SUPERUSER} -d ${TEST_DB}"
  log ""
  log "Example queries:"
  log "  SELECT COUNT(*) FROM ${TEST_SCHEMA}.person;"
  log "  SELECT * FROM ${TEST_SCHEMA}.person LIMIT 5;"
  log ""
  log "PostgreSQL data is persisted at: $PGDATA_DIR"
  log "Database size: $(du -sh "$PGDATA_DIR" 2>/dev/null | cut -f1 || echo 'calculating...')"
  log ""
  log "Container '$CONTAINER_NAME' is still running and accessible."
  log "To stop the container: docker stop $CONTAINER_NAME"
  log "To remove the container: docker rm $CONTAINER_NAME"
  log "To remove the persisted data: rm -rf $PGDATA_DIR"
  exit 0
else
  log "✗ Schema test FAILED!"
  exit 1
fi
