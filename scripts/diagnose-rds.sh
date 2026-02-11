#!/bin/bash
###############################################################################
# RDS Diagnostic Script
# Checks RDS instance configuration and database accessibility
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "════════════════════════════════════════════════════════"
echo "  RDS OPENDATA DIAGNOSTICS"
echo "════════════════════════════════════════════════════════"
echo ""

if [ ! -f "$DEPLOYMENT_INFO" ]; then
  log_error "deployment-info.json not found"
  exit 1
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
OPENDATA_DB_ID=$(jq -r '.rdsInstances.opendata // empty' "$DEPLOYMENT_INFO")
OPENDATA_DB_ENDPOINT=$(jq -r '.rdsEndpoints.opendata // empty' "$DEPLOYMENT_INFO")

# If instance ID is missing, derive from project name
if [ -z "$OPENDATA_DB_ID" ] || [ "$OPENDATA_DB_ID" == "null" ]; then
  OPENDATA_DB_ID="${PROJECT_NAME}-opendata-db"
  log_warn "RDS instance ID not in deployment-info.json, using: $OPENDATA_DB_ID"
fi

log_info "Region: $REGION"
log_info "Project: $PROJECT_NAME"
log_info "RDS Instance ID: $OPENDATA_DB_ID"

# Get DB credentials from Secrets Manager
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/opendata/db" \
  --region "$REGION" \
  --query SecretString --output text)

DB_USER=$(echo "$DB_SECRET" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET" | jq -r '.password')
DB_NAME=$(echo "$DB_SECRET" | jq -r '.dbname // "postgres"')

log_info "Username from secret: $DB_USER"
log_info "Database name from secret: $DB_NAME"
echo ""

# Check RDS instance details to get the actual endpoint
log_info "Querying RDS instance configuration..."
RDS_INFO=$(aws rds describe-db-instances \
  --db-instance-identifier "$OPENDATA_DB_ID" \
  --region "$REGION" 2>&1)

if [ $? -ne 0 ]; then
  log_error "Cannot find RDS instance: $OPENDATA_DB_ID"
  log_error "Error: $RDS_INFO"
  exit 1
fi

# Get endpoint from RDS if not in deployment-info
RDS_ENDPOINT=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].Endpoint.Address')
if [ -z "$OPENDATA_DB_ENDPOINT" ] || [ "$OPENDATA_DB_ENDPOINT" == "null" ]; then
  OPENDATA_DB_ENDPOINT="$RDS_ENDPOINT"
fi

log_info "RDS Endpoint: $OPENDATA_DB_ENDPOINT"

RDS_STATUS=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].DBInstanceStatus')
RDS_ENGINE=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].Engine')
RDS_ENGINE_VERSION=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].EngineVersion')
RDS_MASTER_USER=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].MasterUsername')
RDS_DB_NAME=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].DBName // "null"')
RDS_PORT=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].Endpoint.Port')

log_info "RDS Status: $RDS_STATUS"
log_info "Engine: $RDS_ENGINE $RDS_ENGINE_VERSION"
log_info "Master Username: $RDS_MASTER_USER"
log_info "Initial Database Name (DBName): $RDS_DB_NAME"
log_info "Port: $RDS_PORT"
echo ""

# Check if DBName is set
if [ "$RDS_DB_NAME" == "null" ] || [ -z "$RDS_DB_NAME" ]; then
  log_warn "RDS instance was created WITHOUT an initial database name (DBName)"
  log_warn "PostgreSQL defaults to creating 'postgres' database only"
  log_info "We need to create the 'opendata' database manually"
  echo ""
  DEFAULT_DB="postgres"
else
  log_info "RDS instance has initial database: $RDS_DB_NAME"
  DEFAULT_DB="$RDS_DB_NAME"
fi

# Test connection to default database
log_info "Testing connection to default database ($DEFAULT_DB)..."
export PGPASSWORD="$DB_PASSWORD"

if psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "$DEFAULT_DB" -p 5432 -c "SELECT version();" >/dev/null 2>&1; then
  log_info "✓ Successfully connected to database: $DEFAULT_DB"
  
  # List all databases
  log_info "Listing all databases..."
  DATABASES=$(psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "$DEFAULT_DB" -p 5432 -t -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>/dev/null)
  echo "$DATABASES" | while read db; do
    if [ ! -z "$db" ]; then
      echo "  - $db"
    fi
  done
  echo ""
  
  # Check if opendata database exists
  OPENDATA_EXISTS=$(psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "$DEFAULT_DB" -p 5432 -t -c "SELECT 1 FROM pg_database WHERE datname = 'opendata';" 2>/dev/null | xargs)
  
  if [ "$OPENDATA_EXISTS" == "1" ]; then
    log_info "✓ Database 'opendata' already exists"
    
    # Test connection to opendata database
    if psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "opendata" -p 5432 -c "SELECT 1;" >/dev/null 2>&1; then
      log_info "✓ Can connect to 'opendata' database"
      
      # Check for opendata schema
      SCHEMA_EXISTS=$(psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "opendata" -p 5432 -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'opendata';" 2>/dev/null | xargs)
      
      if [ "$SCHEMA_EXISTS" == "1" ]; then
        log_info "✓ Schema 'opendata' exists"
        
        # Check tables
        TABLES=$(psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "opendata" -p 5432 -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'opendata' ORDER BY tablename;" 2>/dev/null)
        if [ ! -z "$TABLES" ]; then
          log_info "Tables in opendata schema:"
          echo "$TABLES" | while read table; do
            if [ ! -z "$table" ]; then
              COUNT=$(psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "opendata" -p 5432 -t -c "SELECT COUNT(*) FROM opendata.$table;" 2>/dev/null | xargs)
              echo "  - $table ($COUNT rows)"
            fi
          done
        else
          log_warn "No tables found in opendata schema"
        fi
      else
        log_warn "Schema 'opendata' does not exist yet"
      fi
    else
      log_error "Cannot connect to 'opendata' database"
    fi
  else
    log_warn "Database 'opendata' does NOT exist"
    log_info "Creating database 'opendata'..."
    if psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "$DEFAULT_DB" -p 5432 -c "CREATE DATABASE opendata;" 2>&1; then
      log_info "✓ Database 'opendata' created successfully"
    else
      log_error "Failed to create database 'opendata'"
    fi
  fi
  
else
  log_error "✗ Cannot connect to database: $DEFAULT_DB"
  log_error "Check network connectivity, security groups, and credentials"
fi

unset PGPASSWORD

echo ""
log_info "Diagnosis complete"
