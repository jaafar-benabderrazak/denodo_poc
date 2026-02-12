#!/bin/bash
###############################################################################
# RDS Diagnostic Script
# Checks RDS instance configuration and database accessibility
#
# When running from AWS CloudShell (which cannot reach private RDS directly),
# psql commands are executed remotely on the Denodo EC2 instance via SSM
# RunShellScript. Direct psql is used when running from a host with network
# access to the RDS (e.g. the Denodo EC2 itself).
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
DENODO_INSTANCE_ID=$(jq -r '.denodo.instanceId // "i-0aef555dcb0ff873f"' "$DEPLOYMENT_INFO")

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
RDS_PUBLIC=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].PubliclyAccessible')

log_info "RDS Status: $RDS_STATUS"
log_info "Engine: $RDS_ENGINE $RDS_ENGINE_VERSION"
log_info "Master Username: $RDS_MASTER_USER"
log_info "Initial Database Name (DBName): $RDS_DB_NAME"
log_info "Port: $RDS_PORT"
log_info "Publicly Accessible: $RDS_PUBLIC"
echo ""

###############################################################################
# Detect execution environment and choose connectivity method
###############################################################################
USE_SSM="false"

if [ "${AWS_EXECUTION_ENV:-}" == "CloudShell" ] || [ "${CLOUDSHELL:-}" == "true" ]; then
  log_warn "Running in AWS CloudShell -- RDS is in a private subnet, no direct access"
  log_info "Will route psql commands through Denodo EC2 ($DENODO_INSTANCE_ID) via SSM"
  USE_SSM="true"

  # Verify the EC2 instance is SSM-managed and online
  SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${DENODO_INSTANCE_ID}" \
    --region "$REGION" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "Unknown")

  if [ "$SSM_STATUS" != "Online" ]; then
    log_error "Denodo EC2 ($DENODO_INSTANCE_ID) SSM status: $SSM_STATUS (expected: Online)"
    log_error "Ensure SSM agent is running and the instance has the AmazonSSMManagedInstanceCore policy"
    exit 1
  fi
  log_info "Denodo EC2 SSM status: Online"

  # Verify psql is available on the EC2 instance
  PSQL_CHECK_CMD_ID=$(aws ssm send-command \
    --instance-ids "$DENODO_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["which psql || echo MISSING"]' \
    --region "$REGION" \
    --query 'Command.CommandId' --output text 2>/dev/null)

  sleep 3
  PSQL_CHECK_RESULT=$(aws ssm get-command-invocation \
    --command-id "$PSQL_CHECK_CMD_ID" \
    --instance-id "$DENODO_INSTANCE_ID" \
    --region "$REGION" \
    --query 'StandardOutputContent' --output text 2>/dev/null | tr -d '[:space:]')

  if [ "$PSQL_CHECK_RESULT" == "MISSING" ] || [ -z "$PSQL_CHECK_RESULT" ]; then
    log_warn "psql not found on Denodo EC2 -- installing postgresql client..."
    INSTALL_CMD_ID=$(aws ssm send-command \
      --instance-ids "$DENODO_INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["sudo yum install -y postgresql15 2>/dev/null || sudo yum install -y postgresql 2>/dev/null || sudo amazon-linux-extras install postgresql15 -y 2>/dev/null || echo INSTALL_FAILED"]' \
      --region "$REGION" \
      --query 'Command.CommandId' --output text 2>/dev/null)
    sleep 10
    INSTALL_STATUS=$(aws ssm get-command-invocation \
      --command-id "$INSTALL_CMD_ID" \
      --instance-id "$DENODO_INSTANCE_ID" \
      --region "$REGION" \
      --query 'Status' --output text 2>/dev/null)
    if [ "$INSTALL_STATUS" != "Success" ]; then
      log_error "Failed to install psql on Denodo EC2. Install postgresql client manually."
      exit 1
    fi
    log_info "postgresql client installed on Denodo EC2"
  else
    log_info "psql available on Denodo EC2: $PSQL_CHECK_RESULT"
  fi

  # Test network connectivity from Denodo EC2 to RDS
  log_info "Testing network connectivity from Denodo EC2 to RDS endpoint..."
  NETCAT_CMD_ID=$(aws ssm send-command \
    --instance-ids "$DENODO_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"timeout 5 bash -c '</dev/tcp/${OPENDATA_DB_ENDPOINT}/5432' 2>/dev/null && echo REACHABLE || echo UNREACHABLE\"]" \
    --region "$REGION" \
    --query 'Command.CommandId' --output text 2>/dev/null || echo "")

  if [ ! -z "$NETCAT_CMD_ID" ] && [ "$NETCAT_CMD_ID" != "None" ]; then
    sleep 4
    NETCAT_RESULT=$(aws ssm get-command-invocation \
      --command-id "$NETCAT_CMD_ID" \
      --instance-id "$DENODO_INSTANCE_ID" \
      --region "$REGION" \
      --query 'StandardOutputContent' --output text 2>/dev/null | tr -d '[:space:]')

    if [ "$NETCAT_RESULT" == "REACHABLE" ]; then
      log_info "Network connectivity: RDS port 5432 is reachable from Denodo EC2"
    else
      log_error "Network connectivity: RDS port 5432 is NOT reachable from Denodo EC2"
      log_error "This indicates a security group or network routing issue"
      
      # Get Denodo EC2 security groups
      DENODO_SGS=$(aws ec2 describe-instances \
        --instance-ids "$DENODO_INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' \
        --output text 2>/dev/null || echo "")
      
      # Get RDS security groups
      RDS_SGS=$(echo "$RDS_INFO" | jq -r '.DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' | tr '\n' ' ')
      
      log_warn "Denodo EC2 security groups: ${DENODO_SGS:-unknown}"
      log_warn "RDS security groups: ${RDS_SGS:-unknown}"
      log_warn "Check that RDS security group allows inbound 5432 from Denodo EC2 IP or SG"
      echo ""
    fi
  fi
  echo ""
fi

###############################################################################
# Helper: run_psql -- execute a psql command locally or via SSM
#
# Usage: run_psql <database> <psql_flags_and_query>
# Returns: stdout from psql; exit code 0 on success, 1 on failure
#
# Examples:
#   run_psql postgres "-c" "SELECT version();"
#   run_psql opendata "-t" "-c" "SELECT count(*) FROM opendata.entreprises;"
###############################################################################
run_psql() {
  local db="$1"
  shift

  if [ "$USE_SSM" == "true" ]; then
    # Build the full psql command string for remote execution
    local PSQL_CMD="PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_DB_ENDPOINT}' -U '${DB_USER}' -d '${db}' -p 5432"
    # Append remaining arguments, quoting each one
    for arg in "$@"; do
      PSQL_CMD="$PSQL_CMD '$arg'"
    done

    # Use || echo "" to prevent set -e from killing the caller
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

    # Poll for completion (max ~30s)
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
      if [ "$WAIT_SECS" -ge 30 ]; then
        log_warn "SSM command timed out after ${WAIT_SECS}s (command: $CMD_ID)"
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
    PGPASSWORD="$DB_PASSWORD" psql -h "$OPENDATA_DB_ENDPOINT" -U "$DB_USER" -d "$db" -p 5432 "$@"
  fi
}

###############################################################################
# Database checks
###############################################################################

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
if [ "$USE_SSM" == "false" ]; then
  export PGPASSWORD="$DB_PASSWORD"
fi

if run_psql "$DEFAULT_DB" -c "SELECT version();" >/dev/null 2>&1; then
  log_info "Successfully connected to database: $DEFAULT_DB"
  
  # List all databases
  log_info "Listing all databases..."
  DATABASES=$(run_psql "$DEFAULT_DB" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>/dev/null)
  echo "$DATABASES" | while read db; do
    db=$(echo "$db" | xargs)
    if [ ! -z "$db" ]; then
      echo "  - $db"
    fi
  done
  echo ""
  
  # Check if opendata database exists
  OPENDATA_EXISTS=$(run_psql "$DEFAULT_DB" -t -c "SELECT 1 FROM pg_database WHERE datname = 'opendata';" 2>/dev/null | xargs)
  
  if [ "$OPENDATA_EXISTS" == "1" ]; then
    log_info "Database 'opendata' already exists"
    
    # Test connection to opendata database
    if run_psql "opendata" -c "SELECT 1;" >/dev/null 2>&1; then
      log_info "Can connect to 'opendata' database"
      
      # Check for opendata schema
      SCHEMA_EXISTS=$(run_psql "opendata" -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'opendata';" 2>/dev/null | xargs)
      
      if [ "$SCHEMA_EXISTS" == "1" ]; then
        log_info "Schema 'opendata' exists"
        
        # Check tables
        TABLES=$(run_psql "opendata" -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'opendata' ORDER BY tablename;" 2>/dev/null)
        if [ ! -z "$TABLES" ]; then
          log_info "Tables in opendata schema:"
          echo "$TABLES" | while read table; do
            table=$(echo "$table" | xargs)
            if [ ! -z "$table" ]; then
              COUNT=$(run_psql "opendata" -t -c "SELECT COUNT(*) FROM opendata.${table};" 2>/dev/null | xargs)
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
    if run_psql "$DEFAULT_DB" -c "CREATE DATABASE opendata;" 2>&1; then
      log_info "Database 'opendata' created successfully"
    else
      log_error "Failed to create database 'opendata'"
    fi
  fi
  
else
  log_error "Cannot connect to database: $DEFAULT_DB"
  if [ "$USE_SSM" == "true" ]; then
    log_error "SSM command failed. Check that Denodo EC2 can reach RDS and credentials are correct."
  else
    log_error "Check network connectivity, security groups, and credentials"
  fi
fi

if [ "$USE_SSM" == "false" ]; then
  unset PGPASSWORD
fi

echo ""
log_info "Diagnosis complete"
