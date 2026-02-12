#!/bin/bash
###############################################################################
# Fix OpenData RDS Password Mismatch
#
# This script resets the RDS master password to match what's in Secrets Manager
# or vice versa.
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
echo "  FIX OPENDATA RDS PASSWORD"
echo "════════════════════════════════════════════════════════"
echo ""

if [ ! -f "$DEPLOYMENT_INFO" ]; then
  log_error "deployment-info.json not found"
  exit 1
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
OPENDATA_DB_ID=$(jq -r '.rdsInstances.opendata // empty' "$DEPLOYMENT_INFO")

if [ -z "$OPENDATA_DB_ID" ] || [ "$OPENDATA_DB_ID" == "null" ]; then
  OPENDATA_DB_ID="${PROJECT_NAME}-opendata-db"
fi

log_info "Region: $REGION"
log_info "Project: $PROJECT_NAME"
log_info "RDS Instance: $OPENDATA_DB_ID"
echo ""

# Get current secret
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/opendata/db" \
  --region "$REGION" \
  --query SecretString --output text)

CURRENT_PASSWORD=$(echo "$DB_SECRET" | jq -r '.password')
log_info "Current password in Secrets Manager: ${#CURRENT_PASSWORD} characters"

# Generate a new password
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
log_info "Generated new password: ${#NEW_PASSWORD} characters"
echo ""

# Option 1: Reset RDS password to match new password
log_info "Updating RDS master password..."
aws rds modify-db-instance \
  --db-instance-identifier "$OPENDATA_DB_ID" \
  --master-user-password "$NEW_PASSWORD" \
  --apply-immediately \
  --region "$REGION" >/dev/null

log_info "RDS password update initiated (takes ~1-2 minutes to apply)"

# Option 2: Update Secrets Manager with new password
log_info "Updating Secrets Manager with new password..."

# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$OPENDATA_DB_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

aws secretsmanager update-secret \
  --secret-id "${PROJECT_NAME}/opendata/db" \
  --secret-string "{\"username\":\"denodo\",\"password\":\"$NEW_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"opendata\",\"host\":\"$RDS_ENDPOINT\"}" \
  --region "$REGION" >/dev/null

log_info "Secrets Manager updated"
echo ""

# Wait for RDS modification to complete
log_info "Waiting for RDS password modification to complete..."
log_warn "This typically takes 1-2 minutes..."

WAIT_COUNT=0
MAX_WAIT=120

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  RDS_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$OPENDATA_DB_ID" \
    --region "$REGION" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null || echo "unknown")
  
  if [ "$RDS_STATUS" == "available" ]; then
    log_info "RDS instance is available"
    break
  elif [ "$RDS_STATUS" == "modifying" ]; then
    echo -n "."
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
  else
    log_warn "RDS status: $RDS_STATUS"
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
  fi
done

echo ""
echo ""
log_info "Password synchronization complete!"
log_info "RDS master password and Secrets Manager are now in sync"
echo ""
log_info "You can now run: ./scripts/diagnose-rds.sh"
