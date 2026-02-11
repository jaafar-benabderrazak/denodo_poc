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

for tool in aws jq curl python3 psql; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Missing required tool: $tool"
    log_error "Install it, then re-run this script."
    exit 1
  fi
done

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
OPENDATA_DB_ENDPOINT=$(jq -r '.rdsEndpoints.opendata // empty' "$DEPLOYMENT_INFO")

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

export PGPASSWORD="$DB_PASSWORD"

log_step "0" "Ensuring database 'opendata' exists"
if ! psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -c "SELECT 1;" >/dev/null 2>&1; then
  log_warn "Database opendata not reachable yet; attempting to create it via 'postgres' database"
  psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d postgres -p 5432 -c "CREATE DATABASE opendata;" >/dev/null 2>&1 || true
fi
log_success "Database opendata is ready"

log_step "1" "Initializing OpenData schema"
psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -f "$SQL_SCHEMA_FILE" >/dev/null
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
psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -f "$INSERT_COMMUNES_SQL" -q
psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -f "$INSERT_ENTREPRISES_SQL" -q
log_success "Data loaded"

log_step "6" "Verifying counts"
COMMUNE_DB_COUNT=$(psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -t -c "SELECT COUNT(*) FROM opendata.population_communes;" | xargs)
ENTREPRISE_DB_COUNT=$(psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -t -c "SELECT COUNT(*) FROM opendata.entreprises;" | xargs)
VIEW_DB_COUNT=$(psql -h "$OPENDATA_DB_ENDPOINT" -U denodo -d opendata -p 5432 -t -c "SELECT COUNT(*) FROM opendata.entreprises_population;" | xargs)

log_success "population_communes: $COMMUNE_DB_COUNT"
log_success "entreprises: $ENTREPRISE_DB_COUNT"
log_success "entreprises_population view: $VIEW_DB_COUNT"

unset PGPASSWORD
rm -rf "$TEMP_DIR"
log_success "Temporary files cleaned up"

log_phase "✓ OPENDATA LOADING COMPLETE"


