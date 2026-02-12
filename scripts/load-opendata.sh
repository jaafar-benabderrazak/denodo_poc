#!/bin/bash
###############################################################################
# Denodo Keycloak POC - OpenData Loader
#
# Initializes the OpenData schema and loads sample data into the OpenData RDS.
#
# - Creates schema/tables/views/functions using sql/01-create-opendata-schema.sql
# - Loads communes from geo.api.gouv.fr (~36k rows)
# - Loads a generated sample of entreprises (default: 1000 rows)
#
# Prerequisites:
# - deployment-info.json must exist (created by deploy-denodo-keycloak.sh or
#   deploy-step-by-step.sh)
# - Tools: aws, jq, curl, python3, psql
#
# Usage:
#   ./scripts/load-opendata.sh
#   ./scripts/load-opendata.sh --entreprises 5000
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

# Defaults
ENTREPRISES_COUNT=1000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entreprises)
      ENTREPRISES_COUNT="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--entreprises N]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_phase() { echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"; echo -e "${MAGENTA}║ $1${NC}"; echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}\n"; }
log_step() { echo -e "${CYAN}▶ STEP $1:${NC} $2"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }

log_phase "OPENDATA LOADING"

if [ ! -f "$DEPLOYMENT_INFO" ]; then
  log_error "deployment-info.json not found at: $DEPLOYMENT_INFO"
  log_error "Run ./scripts/deploy-denodo-keycloak.sh first."
  exit 1
fi

for tool in aws jq curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Missing required tool: $tool"
    log_error "Install it, then re-run this script."
    exit 1
  fi
done

# Check for local psql only if not using SSM
if [ "${AWS_EXECUTION_ENV:-}" != "CloudShell" ] && [ "${CLOUDSHELL:-}" != "true" ]; then
  if ! command -v psql >/dev/null 2>&1; then
    log_error "Missing required tool: psql"
    log_error "Install postgresql-client, then re-run this script."
    exit 1
  fi
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
OPENDATA_DB_ENDPOINT=$(jq -r '.rdsEndpoints.opendata // empty' "$DEPLOYMENT_INFO")
DENODO_INSTANCE_ID=$(jq -r '.denodo.instanceId // "i-0aef555dcb0ff873f"' "$DEPLOYMENT_INFO")

if [ -z "$OPENDATA_DB_ENDPOINT" ] || [ "$OPENDATA_DB_ENDPOINT" == "null" ]; then
  log_error "OpenData RDS endpoint missing in deployment-info.json (.rdsEndpoints.opendata)"
  exit 1
fi

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/opendata/db" \
  --region "$REGION" \
  --query SecretString --output text | jq -r '.password')

if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
  log_error "Could not read OpenData DB password from Secrets Manager (${PROJECT_NAME}/opendata/db)."
  exit 1
fi

SQL_SCHEMA_FILE="$PROJECT_DIR/sql/01-create-opendata-schema.sql"
if [ ! -f "$SQL_SCHEMA_FILE" ]; then
  log_error "Schema SQL file not found: $SQL_SCHEMA_FILE"
  exit 1
fi

###############################################################################
# Detect CloudShell and setup SSM routing
###############################################################################
USE_SSM="false"

if [ "${AWS_EXECUTION_ENV:-}" == "CloudShell" ] || [ "${CLOUDSHELL:-}" == "true" ]; then
  log_warn "Running in AWS CloudShell -- will route psql commands through Denodo EC2 via SSM"
  USE_SSM="true"

  # Verify SSM connectivity
  SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${DENODO_INSTANCE_ID}" \
    --region "$REGION" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "Unknown")

  if [ "$SSM_STATUS" != "Online" ]; then
    log_error "Denodo EC2 ($DENODO_INSTANCE_ID) SSM status: $SSM_STATUS (expected: Online)"
    exit 1
  fi
  log_info "Denodo EC2 SSM: Online"

  # Verify psql is available
  PSQL_CHECK_CMD_ID=$(aws ssm send-command \
    --instance-ids "$DENODO_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["which psql || echo MISSING"]' \
    --region "$REGION" \
    --query 'Command.CommandId' --output text 2>/dev/null || echo "")

  if [ ! -z "$PSQL_CHECK_CMD_ID" ]; then
    sleep 3
    PSQL_PATH=$(aws ssm get-command-invocation \
      --command-id "$PSQL_CHECK_CMD_ID" \
      --instance-id "$DENODO_INSTANCE_ID" \
      --region "$REGION" \
      --query 'StandardOutputContent' --output text 2>/dev/null | tr -d '[:space:]')

    if [ "$PSQL_PATH" == "MISSING" ] || [ -z "$PSQL_PATH" ]; then
      log_error "psql not found on Denodo EC2. Install postgresql client on the instance."
      exit 1
    fi
  fi
  log_info "psql available on Denodo EC2"
  echo ""
fi

if [ "$USE_SSM" == "false" ]; then
  export PGPASSWORD="$DB_PASSWORD"
fi

###############################################################################
# Helper: run_psql -- execute psql command locally or via SSM
###############################################################################
run_psql() {
  local db="$1"
  shift

  if [ "$USE_SSM" == "true" ]; then
    # Build psql command for remote execution
    local PSQL_CMD="PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_DB_ENDPOINT}' -U denodo -d '${db}' -p 5432"
    for arg in "$@"; do
      PSQL_CMD="$PSQL_CMD '$arg'"
    done

    local CMD_ID
    CMD_ID=$(aws ssm send-command \
      --instance-ids "$DENODO_INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters "commands=[\"${PSQL_CMD}\"]" \
      --region "$REGION" \
      --query 'Command.CommandId' --output text 2>/dev/null || echo "")

    if [ -z "$CMD_ID" ] || [ "$CMD_ID" == "None" ]; then
      return 1
    fi

    # Poll for completion
    local WAIT_SECS=0
    local CMD_STATUS="InProgress"
    while [ "$CMD_STATUS" == "InProgress" ] || [ "$CMD_STATUS" == "Pending" ]; do
      sleep 2
      WAIT_SECS=$((WAIT_SECS + 2))
      CMD_STATUS=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'Status' --output text 2>/dev/null || echo "InProgress")
      if [ "$WAIT_SECS" -ge 300 ]; then
        log_warn "SSM command timed out after ${WAIT_SECS}s"
        return 1
      fi
    done

    if [ "$CMD_STATUS" == "Success" ]; then
      aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || true
      return 0
    else
      aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardErrorContent' --output text 2>/dev/null >&2 || true
      return 1
    fi
  else
    # Direct local psql
    PGPASSWORD="$DB_PASSWORD" psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d "$db" -p 5432 "$@"
  fi
}

###############################################################################
# Helper: run_psql_file -- execute SQL file via psql (uses S3 for SSM mode)
###############################################################################
run_psql_file() {
  local db="$1"
  local sql_file="$2"
  shift 2
  local extra_args="$@"

  if [ "$USE_SSM" == "true" ]; then
    # For SSM mode, upload SQL file to S3, then download on EC2
    
    local S3_BUCKET="aws-cloudshell-$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo 'temp')"
    local S3_KEY="denodo-poc-temp/$(date +%s)-$(basename "$sql_file")"
    local S3_URI="s3://${S3_BUCKET}/${S3_KEY}"
    
    # Ensure bucket exists
    if ! aws s3 ls "s3://${S3_BUCKET}" --region "$REGION" >/dev/null 2>&1; then
      log_info "Creating S3 bucket for temporary files..."
      aws s3 mb "s3://${S3_BUCKET}" --region "$REGION" 2>&1 || {
        log_error "Failed to create S3 bucket"
        return 1
      }
    fi
    
    log_info "Uploading SQL file to S3..."
    # Upload to S3
    aws s3 cp "$sql_file" "$S3_URI" --region "$REGION" 2>&1 || {
      log_error "Failed to upload SQL file to S3"
      return 1
    }
    
    log_info "Executing SQL on Denodo EC2..."
    local REMOTE_TMP="/tmp/opendata-$(basename "$sql_file")"
    local EXEC_CMD="aws s3 cp '${S3_URI}' '${REMOTE_TMP}' --region '${REGION}' && PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_DB_ENDPOINT}' -U denodo -d '${db}' -p 5432 -f '${REMOTE_TMP}' ${extra_args} && rm -f '${REMOTE_TMP}'"
    
    local CMD_ID
    CMD_ID=$(aws ssm send-command \
      --instance-ids "$DENODO_INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters "commands=[\"${EXEC_CMD}\"]" \
      --region "$REGION" \
      --query 'Command.CommandId' --output text 2>/dev/null || echo "")

    if [ -z "$CMD_ID" ] || [ "$CMD_ID" == "None" ]; then
      aws s3 rm "$S3_URI" --region "$REGION" 2>/dev/null || true
      log_error "Failed to start SSM command"
      return 1
    fi

    # Poll for completion (allow up to 5 minutes for large SQL files)
    local WAIT_SECS=0
    local CMD_STATUS="InProgress"
    while [ "$CMD_STATUS" == "InProgress" ] || [ "$CMD_STATUS" == "Pending" ]; do
      sleep 3
      WAIT_SECS=$((WAIT_SECS + 3))
      CMD_STATUS=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'Status' --output text 2>/dev/null || echo "InProgress")
      if [ "$WAIT_SECS" -ge 300 ]; then
        log_warn "SSM command timed out after ${WAIT_SECS}s"
        aws s3 rm "$S3_URI" --region "$REGION" 2>/dev/null || true
        return 1
      fi
    done

    # Cleanup S3 file
    aws s3 rm "$S3_URI" --region "$REGION" 2>/dev/null || true

    if [ "$CMD_STATUS" == "Success" ]; then
      aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || true
      return 0
    else
      log_error "SQL execution failed on EC2"
      aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardErrorContent' --output text 2>/dev/null >&2 || true
      return 1
    fi
  else
    # Direct local psql
    PGPASSWORD="$DB_PASSWORD" psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d "$db" -p 5432 -f "$sql_file" $extra_args
  fi
}

log_step "0" "Ensuring database 'opendata' exists"
# Try connecting to opendata database directly
if run_psql "opendata" -c "SELECT 1;" >/dev/null 2>&1; then
  log_success "Database opendata is ready"
else
  log_warn "Database 'opendata' not accessible; checking if it needs to be created"
  
  # Check what databases exist
  EXISTING_DBS=$(run_psql "postgres" -t -c "SELECT datname FROM pg_database WHERE datname = 'opendata';" 2>/dev/null | xargs || echo "")
  
  if [ -z "$EXISTING_DBS" ]; then
    log_info "Creating database 'opendata'..."
    run_psql "postgres" -c "CREATE DATABASE opendata;" 2>&1 || {
      log_error "Failed to create database. Check permissions and RDS configuration."
      exit 1
    }
  fi
  
  # Verify connection again
  if run_psql "opendata" -c "SELECT 1;" >/dev/null 2>&1; then
    log_success "Database opendata is ready"
  else
    log_error "Cannot connect to database 'opendata'."
    exit 1
  fi
fi

log_step "1" "Initializing OpenData schema"
run_psql_file "opendata" "$SQL_SCHEMA_FILE" "-q"
log_success "Schema applied"

log_step "2" "Downloading communes dataset from geo.api.gouv.fr"
TEMP_DIR="$(mktemp -d)"
COMMUNES_JSON="$TEMP_DIR/communes.json"
curl -s "https://geo.api.gouv.fr/communes?fields=nom,code,codesPostaux,codeDepartement,codeRegion,population,surface&format=json&geometry=centre" > "$COMMUNES_JSON"
COMMUNE_COUNT=$(jq '. | length' "$COMMUNES_JSON" 2>/dev/null || echo "0")
log_success "Downloaded communes: $COMMUNE_COUNT"

log_step "3" "Generating SQL inserts for population_communes"
INSERT_COMMUNES_SQL="$TEMP_DIR/insert_communes.sql"
export COMMUNES_JSON_FILE="$COMMUNES_JSON"
python3 <<'PYTHON_SCRIPT' > "$INSERT_COMMUNES_SQL"
import json
import os

json_file = os.environ.get("COMMUNES_JSON_FILE")
with open(json_file, "r", encoding="utf-8") as f:
    communes = json.load(f)

print("-- Insert communes into opendata.population_communes")
print("BEGIN;")
for commune in communes:
    code = commune.get("code", "")
    nom = (commune.get("nom", "") or "").replace("'", "''")
    codes_postaux = commune.get("codesPostaux") or [""]
    code_postal = (codes_postaux[0] if codes_postaux else "") or ""
    code_dept = commune.get("codeDepartement", "") or ""
    code_region = commune.get("codeRegion", "") or ""
    population = commune.get("population", 0) or 0
    surface = commune.get("surface", 0) or 0

    coords = (commune.get("centre") or {}).get("coordinates") or [0, 0]
    longitude = coords[0] if len(coords) > 0 else 0
    latitude = coords[1] if len(coords) > 1 else 0

    print(
        "INSERT INTO opendata.population_communes "
        "(code_commune, nom_commune, code_postal, code_departement, code_region, population, superficie, latitude, longitude) "
        f"VALUES ('{code}', '{nom}', '{code_postal}', '{code_dept}', '{code_region}', {population}, {surface}, {latitude}, {longitude}) "
        "ON CONFLICT (code_commune) DO NOTHING;"
    )
print("COMMIT;")
PYTHON_SCRIPT
unset COMMUNES_JSON_FILE
log_success "SQL generated: $(basename "$INSERT_COMMUNES_SQL")"

log_step "4" "Generating sample entreprises dataset (${ENTREPRISES_COUNT} rows)"
INSERT_ENTREPRISES_SQL="$TEMP_DIR/insert_entreprises.sql"
{
  echo "-- Insert entreprises sample into opendata.entreprises"
  echo "BEGIN;"
} > "$INSERT_ENTREPRISES_SQL"

DEPARTEMENTS=("75" "69" "13" "31" "44" "33" "59" "35" "67" "34")
CODES_NAF=("6201Z" "6202A" "6311Z" "6312Z" "6399Z" "7022Z" "7112B")
EFFECTIFS=(5 10 20 50 100 250 500 1000)

for ((i=1; i<=ENTREPRISES_COUNT; i++)); do
  SIREN=$(printf "%09d" $((100000000 + RANDOM % 900000000)))
  NOM="Entreprise Test $i"
  DEPT=${DEPARTEMENTS[$RANDOM % ${#DEPARTEMENTS[@]}]}
  NAF=${CODES_NAF[$RANDOM % ${#CODES_NAF[@]}]}
  EFFECTIF=${EFFECTIFS[$RANDOM % ${#EFFECTIFS[@]}]}
  AGE_DAYS=$((RANDOM % 3650))
  CODE_POSTAL="${DEPT}001"

  echo "INSERT INTO opendata.entreprises (siren, nom_raison_sociale, code_naf, libelle_naf, statut, effectif, departement, ville, code_postal, date_creation) VALUES ('$SIREN', '$NOM', '$NAF', 'Activites informatiques', 'Actif', $EFFECTIF, '$DEPT', 'Ville Test', '$CODE_POSTAL', CURRENT_DATE - INTERVAL '$AGE_DAYS days') ON CONFLICT (siren) DO NOTHING;" >> "$INSERT_ENTREPRISES_SQL"
done
echo "COMMIT;" >> "$INSERT_ENTREPRISES_SQL"
log_success "SQL generated: $(basename "$INSERT_ENTREPRISES_SQL")"

log_step "5" "Loading data into RDS (this may take a few minutes)"
run_psql_file "opendata" "$INSERT_COMMUNES_SQL" "-q"
run_psql_file "opendata" "$INSERT_ENTREPRISES_SQL" "-q"
log_success "Data loaded"

log_step "6" "Verifying counts"
COMMUNE_DB_COUNT=$(run_psql "opendata" -t -c "SELECT COUNT(*) FROM opendata.population_communes;" | xargs)
ENTREPRISE_DB_COUNT=$(run_psql "opendata" -t -c "SELECT COUNT(*) FROM opendata.entreprises;" | xargs)
VIEW_DB_COUNT=$(run_psql "opendata" -t -c "SELECT COUNT(*) FROM opendata.entreprises_population;" | xargs)

log_success "population_communes: $COMMUNE_DB_COUNT"
log_success "entreprises: $ENTREPRISE_DB_COUNT"
log_success "entreprises_population view: $VIEW_DB_COUNT"

if [ "$USE_SSM" == "false" ]; then
  unset PGPASSWORD
fi
rm -rf "$TEMP_DIR"
log_success "Temporary files cleaned up"

log_phase "✓ OPENDATA LOADING COMPLETE"


