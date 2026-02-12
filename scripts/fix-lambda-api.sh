#!/bin/bash
###############################################################################
# Fix Lambda API - Clean up duplicates, redeploy Lambda + API Gateway
#
# Fixes the HTTP 500 errors from the permissions API by:
#   1. Cleaning up duplicate API Gateways (keeping only the latest)
#   2. Redeploying Lambda function code + configuration
#   3. Redeploying API Gateway stage
#   4. Testing the endpoint
#
# Usage: ./scripts/fix-lambda-api.sh
###############################################################################

set -e
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_phase() {
  echo ""
  echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║ $1${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

REGION="eu-west-3"
PROJECT_NAME="denodo-poc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAMBDA_FUNCTION_NAME="denodo-permissions-api"
API_NAME="denodo-auth-api"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

###############################################################################
# STEP 1: Clean up duplicate API Gateways
###############################################################################
log_phase "STEP 1: CLEAN UP DUPLICATE API GATEWAYS"

# Get all APIs named denodo-auth-api
ALL_API_IDS=$(aws apigateway get-rest-apis \
  --region "$REGION" \
  --query "items[?name=='${API_NAME}'].id" \
  --output text 2>/dev/null || echo "")

API_COUNT=$(echo "$ALL_API_IDS" | wc -w | tr -d ' ')
log_info "Found $API_COUNT API Gateway(s) named '$API_NAME'"

if [ "$API_COUNT" -gt 1 ]; then
  # Keep only the LAST one (most recent), delete the rest
  KEEP_API=$(echo "$ALL_API_IDS" | awk '{print $NF}')
  log_info "Keeping API: $KEEP_API (most recent)"

  for API in $ALL_API_IDS; do
    if [ "$API" != "$KEEP_API" ]; then
      log_info "Deleting duplicate API: $API"
      # Remove usage plan stage associations first
      for UP_ID in $(aws apigateway get-usage-plans --region "$REGION" \
        --query "items[?apiStages[?apiId=='$API']].id" --output text 2>/dev/null); do
        aws apigateway update-usage-plan \
          --usage-plan-id "$UP_ID" \
          --patch-operations "op=remove,path=/apiStages,value=${API}:dev" \
          --region "$REGION" 2>/dev/null || true
      done
      # Delete the stage
      aws apigateway delete-stage \
        --rest-api-id "$API" \
        --stage-name dev \
        --region "$REGION" 2>/dev/null || true
      # Now delete the API
      aws apigateway delete-rest-api \
        --rest-api-id "$API" \
        --region "$REGION" 2>/dev/null || log_warn "Could not delete API $API (may need manual cleanup)"
      sleep 2
    fi
  done
  log_success "Duplicate APIs cleaned up"
  API_ID="$KEEP_API"
elif [ "$API_COUNT" -eq 1 ]; then
  API_ID=$(echo "$ALL_API_IDS" | tr -d '[:space:]')
  log_success "Single API found: $API_ID"
else
  log_error "No API Gateway found. Run deploy-lambda-api.sh first."
  exit 1
fi

echo "  Active API: $API_ID"

###############################################################################
# STEP 2: Redeploy Lambda function (code + configuration)
###############################################################################
log_phase "STEP 2: REDEPLOY LAMBDA FUNCTION"

LAMBDA_SOURCE="$PROJECT_DIR/lambda/permissions_api.py"
if [ ! -f "$LAMBDA_SOURCE" ]; then
  log_error "Lambda source not found: $LAMBDA_SOURCE"
  exit 1
fi

# Package
LAMBDA_ZIP="/tmp/lambda-permissions-api.zip"
cd "$PROJECT_DIR/lambda"
zip -j "$LAMBDA_ZIP" permissions_api.py > /dev/null
cd "$PROJECT_DIR"
log_success "Lambda packaged"

# Update code
aws lambda update-function-code \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --zip-file "fileb://$LAMBDA_ZIP" \
  --region "$REGION" > /dev/null
log_success "Lambda code updated"

# Wait for update to complete
aws lambda wait function-updated-v2 \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --region "$REGION" 2>/dev/null || sleep 5

# Update configuration (env vars, timeout, memory)
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT_NAME}-lambda-execution-role"
aws lambda update-function-configuration \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --runtime python3.11 \
  --handler permissions_api.lambda_handler \
  --timeout 30 \
  --memory-size 256 \
  --environment "Variables={SECRET_NAME=${PROJECT_NAME}/api/auth-key,REGION=${REGION}}" \
  --region "$REGION" > /dev/null 2>&1 || log_warn "Config update skipped (may need wait)"

# Wait again
aws lambda wait function-updated-v2 \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --region "$REGION" 2>/dev/null || sleep 5

log_success "Lambda configuration updated"

# Ensure Lambda permission exists for the active API
aws lambda add-permission \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --statement-id "apigateway-invoke-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region "$REGION" 2>/dev/null || log_info "Lambda permission already exists"

###############################################################################
# STEP 3: Redeploy API Gateway stage
###############################################################################
log_phase "STEP 3: REDEPLOY API GATEWAY"

aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name dev \
  --description "Redeployment after Lambda fix" \
  --region "$REGION" > /dev/null 2>&1
log_success "API redeployed to dev stage"

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev"
echo "  Endpoint: $API_ENDPOINT"

###############################################################################
# STEP 4: Test the endpoint
###############################################################################
log_phase "STEP 4: TEST API ENDPOINT"

API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/api/auth-key" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.apiKey' 2>/dev/null || echo "")

if [ -z "$API_KEY" ]; then
  # Fallback: get from API Gateway
  API_KEY=$(aws apigateway get-api-keys \
    --name-query "${PROJECT_NAME}-api-key" \
    --include-values \
    --region "$REGION" \
    --query "items[0].value" --output text 2>/dev/null || echo "")
fi

if [ -z "$API_KEY" ]; then
  log_error "API Key not found"
  exit 1
fi

echo "  API Key: ${API_KEY:0:8}..."

# Wait a moment for deployment to propagate
log_info "Waiting 5s for deployment propagation..."
sleep 5

# Test each user
for USER in "analyst@denodo.com" "scientist@denodo.com" "admin@denodo.com"; do
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    "$API_ENDPOINT/api/v1/users/$USER/permissions" 2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    PROFILE=$(echo "$BODY" | jq -r '.profiles[0] // "N/A"' 2>/dev/null)
    log_success "$USER -> HTTP 200 (profile: $PROFILE)"
  else
    log_error "$USER -> HTTP $HTTP_CODE"
    echo "$BODY" | jq '.' 2>/dev/null | head -10 | sed 's/^/    /'
  fi
done

# Test security
SECURITY_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "$API_ENDPOINT/api/v1/users/test@test.com/permissions" 2>/dev/null || echo "000")
if [ "$SECURITY_CODE" == "403" ]; then
  log_success "Missing API key -> 403 (correct)"
else
  log_warn "Missing API key -> $SECURITY_CODE"
fi

echo ""
log_phase "FIX COMPLETE"
echo "  API Endpoint: $API_ENDPOINT"
echo "  API Key:      $API_KEY"
echo ""
echo "  Test manually:"
echo "    curl -H 'X-API-Key: $API_KEY' \\"
echo "      '$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions'"
echo ""

rm -f "$LAMBDA_ZIP"
