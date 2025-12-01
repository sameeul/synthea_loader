# Synthea OMOP CDM Loader

Automated loader scripts for importing Synthea-generated synthetic patient data into an OMOP Common Data Model (CDM) 5.3.0 PostgreSQL database.

## Overview

This repository contains scripts to:
- Download OMOP vocabulary data and Synthea patient data from AWS S3
- Deploy a PostgreSQL 16 database in Docker
- Create OMOP CDM 5.3.0 schema
- Load and validate standardized healthcare data

## Available Datasets

Two pre-configured datasets are available:

- **synthea1k**: Small dataset (~1,000 patients) - ideal for testing and development
- **synthea23m**: Large dataset (~23 million records) - suitable for production workloads

## Prerequisites

### Required Tools

- **Docker**: Container runtime for PostgreSQL
- **AWS CLI**: For downloading data from S3 (configured with `--no-sign-request` for public data)
- **PostgreSQL Client** (`psql`): For database operations
- **lzop**: For decompressing `.lzo` compressed patient data files
- **bunzip2**: For decompressing `.bz2` compressed vocabulary files

### Installation Examples

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install docker.io awscli postgresql-client lzop bzip2
```

**macOS (using Homebrew):**
```bash
brew install docker awscli postgresql lzop
```

**RHEL/CentOS:**
```bash
sudo yum install docker awscli postgresql lzop bzip2
```

## Quick Start

### Load Small Dataset (synthea1k)

```bash
./load_synthea1k.sh
```

This script will:
1. Download vocabulary and patient data (~1K patients)
2. Decompress files
3. Start PostgreSQL container on port **5434**
4. Create database `ohdsi` with schema `omop531`
5. Load OMOP CDM schema and data
6. Validate the installation

**Expected Runtime**: 5-15 minutes (depending on network speed)

### Load Large Dataset (synthea23m)

```bash
./load_synthea23m.sh
```

This script handles the 23 million record dataset with chunked file support.

**Expected Runtime**: 30-90 minutes (depending on hardware)

## Directory Structure

```
synthea_loader/
├── load_synthea1k.sh          # Loader script for 1K patient dataset
├── load_synthea23m.sh         # Loader script for 23M record dataset
├── omop-schema/
│   └── CDM5.3.0_DDL_PostgreSQL.sql  # OMOP CDM 5.3.0 DDL
├── omop-data/
│   ├── vocab/                 # OMOP standardized vocabularies (downloaded)
│   ├── synthea1k/             # Small patient dataset (downloaded)
│   └── synthea23m/            # Large patient dataset (downloaded)
└── pgdata/                    # PostgreSQL data persistence (created at runtime)
```

## Configuration

### Database Settings

Both scripts use the following default configuration:

| Parameter | Value |
|-----------|-------|
| PostgreSQL Image | `postgres:16` |
| Container Name | `pg-omop` |
| Database Name | `ohdsi` |
| Schema Name | `omop531` |
| Superuser | `postgres` |
| Password | `testpass123` |
| Host Port | `5434` |
| Container Port | `5432` |

### Data Sources

Data is automatically downloaded from public OHDSI S3 buckets:

- **Vocabulary**: `s3://ohdsi-sample-data/vocab`
- **synthea1k**: `s3://ohdsi-sample-data/synthea1k`
- **synthea23m**: `s3://ohdsi-sample-data/synthea23m`

### Customization

To use a different dataset, edit the `DATASET_NAME` variable in the script:

```bash
DATASET_NAME="synthea10k"  # or any other available dataset
```

## Database Schema

The loader creates a complete OMOP CDM 5.3.0 schema with **39 tables**:

### Vocabulary Tables
- concept, vocabulary, domain, concept_class
- concept_relationship, relationship, concept_synonym
- concept_ancestor, source_to_concept_map, drug_strength

### Metadata Tables
- cdm_source, metadata, cohort_definition, attribute_definition

### Clinical Data Tables
- person, observation_period, death, specimen
- visit_occurrence, visit_detail
- condition_occurrence, drug_exposure, device_exposure
- procedure_occurrence, measurement, observation
- note, note_nlp, fact_relationship

### Health System Tables
- location, care_site, provider, payer_plan_period, cost

### Derived Tables
- cohort, cohort_attribute
- drug_era, dose_era, condition_era

## Data Loading Process

The scripts follow a dependency-aware loading sequence:

1. **Vocabulary Reference Tables** (no dependencies)
   - vocabulary, domain, concept_class, relationship

2. **Concept Table** (depends on vocabulary tables)
   - concept (~3M rows)

3. **Concept Relationships** (depend on concept)
   - concept_relationship, concept_synonym, concept_ancestor

4. **Drug Strength** (depends on concept)
   - drug_strength

5. **Person Table** (base patient table)
   - person

6. **Clinical Event Tables** (depend on person and concept)
   - observation_period, visit_occurrence, condition_occurrence
   - drug_exposure, procedure_occurrence, measurement, observation

7. **Era Tables** (depend on clinical events)
   - drug_era, condition_era

### File Format Handling

- **Vocabulary files**: Tab-delimited (`.csv`), no headers
- **Patient files**: Comma-delimited (`.csv`), with headers
- **Compression**: Automatic decompression of `.lzo` and `.bz2` files
- **Chunked files**: Support for split files (e.g., `table.csv.0`, `table.csv.1`)

## Connecting to the Database

After successful loading, connect using:

```bash
psql -h localhost -p 5434 -U postgres -d ohdsi
```

Password: `testpass123`

### Example Queries

```sql
-- Set schema
SET search_path TO omop531;

-- Count patients
SELECT COUNT(*) FROM person;

-- View sample patient data
SELECT * FROM person LIMIT 5;

-- Count clinical observations
SELECT 
  'Conditions' AS type, COUNT(*) AS count FROM condition_occurrence
UNION ALL
SELECT 'Drug Exposures', COUNT(*) FROM drug_exposure
UNION ALL
SELECT 'Procedures', COUNT(*) FROM procedure_occurrence
UNION ALL
SELECT 'Measurements', COUNT(*) FROM measurement;

-- Get vocabulary statistics
SELECT COUNT(*) AS total_concepts FROM concept;
```

## Data Persistence

PostgreSQL data is persisted in the `pgdata/` directory, allowing the container to be stopped and restarted without data loss.

### Container Management

```bash
# Check container status
docker ps -a | grep pg-omop

# Stop the container
docker stop pg-omop

# Start the container again
docker start pg-omop

# Remove the container (data persists)
docker rm pg-omop

# Remove all data (WARNING: destructive)
rm -rf pgdata/
```

## Validation

Both scripts perform comprehensive validation:

✅ **Schema Validation**
- Verifies all 39 OMOP CDM tables are created
- Checks primary key constraints
- Validates foreign key relationships
- Confirms data type compatibility (TEXT, BIGINT)
- Ensures no Redshift-specific syntax remains

✅ **Data Validation**
- Confirms vocabulary data loaded (concepts, domains, etc.)
- Verifies patient data loaded (persons, visits, conditions)
- Reports row counts for all major tables
- Validates data integrity

## Troubleshooting

### Docker Permission Issues
```bash
sudo usermod -aG docker $USER
# Log out and back in
```

### Port Already in Use
Change the `HOST_PORT` variable in the script to an available port:
```bash
HOST_PORT=5435  # or any other available port
```

### AWS CLI Configuration
The scripts use `--no-sign-request` for public data access. No AWS credentials needed.

### Insufficient Disk Space
- **synthea1k**: Requires ~2-5 GB
- **synthea23m**: Requires ~130 GB

### Memory Issues (Large Dataset)
For synthea23m, ensure Docker has at least 4GB RAM allocated:
```bash
# Check Docker resources
docker stats
```

## Script Features

### Error Handling
- `set -euo pipefail`: Fail fast on errors
- Dependency checking before execution
- Graceful cleanup on failure

### Logging
- Timestamped log messages
- Progress indicators for long operations
- Detailed summary statistics

### Idempotency
- Skips re-downloading existing data files
- Cleans up existing containers before starting
- Safe to re-run after failures

## Performance Notes

### synthea1k (Small Dataset)
- **Download**: 1-3 minutes
- **Schema Creation**: < 1 minute
- **Data Loading**: 2-5 minutes
- **Total**: 5-15 minutes

### synthea23m (Large Dataset)
- **Download**: 10-20 minutes
- **Schema Creation**: < 1 minute
- **Data Loading**: 20-60 minutes
- **Total**: 30-90 minutes

*Performance varies based on network speed, disk I/O, and CPU capabilities.*

## License

This project uses:
- **OMOP CDM**: Apache License 2.0
- **Synthea Data**: Public domain synthetic data from OHDSI

## Additional Resources

- [OHDSI OMOP CDM Documentation](https://ohdsi.github.io/CommonDataModel/)
- [OHDSI Community Forums](https://forums.ohdsi.org/)
- [Synthea Patient Generator](https://synthetichealth.github.io/synthea/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)

## Support

For issues related to:
- **OMOP CDM Schema**: [OHDSI GitHub](https://github.com/OHDSI/CommonDataModel)
- **Synthea Data**: [OHDSI Forums](https://forums.ohdsi.org/)
- **This Loader**: Open an issue in this repository

## Version Information

- **OMOP CDM Version**: 5.3.0
- **PostgreSQL Version**: 16
- **Last Updated**: December 2025
