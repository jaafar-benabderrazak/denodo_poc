#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Lambda API Deployment Script
#
# Deploys the Authorization API (Lambda + API Gateway)
#
# Prerequisites:
# - deployment-info.json must exist
# - lambda/permissions_api.py must exist
#
# Usage: ./scripts/deploy-lambda-api.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

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

###############################################################################
# PHASE 0: Read deployment info
###############################################################################

log_phase "PHASE 0: READING DEPLOYMENT INFO"

if [ ! -f "$DEPLOYMENT_INFO" ]; then
    log_error "deployment-info.json not found. Run deploy-denodo-keycloak.sh first."
    exit 1
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
ACCOUNT_ID=$(jq -r '.accountId' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
VPC_ID=$(jq -r '.vpcId' "$DEPLOYMENT_INFO")
PRIVATE_SUBNET_1=$(jq -r '.subnets.private[0]' "$DEPLOYMENT_INFO")
PRIVATE_SUBNET_2=$(jq -r '.subnets.private[1]' "$DEPLOYMENT_INFO")

LAMBDA_FUNCTION_NAME="denodo-permissions-api"
API_NAME="denodo-auth-api"
LAMBDA_ROLE_NAME="${PROJECT_NAME}-lambda-execution-role"

log_success "Region: $REGION | Account: $ACCOUNT_ID"

###############################################################################
# PHASE 1: IAM Role for Lambda
###############################################################################

log_phase "PHASE 1: CREATING LAMBDA IAM ROLE"

log_step "1.1" "Creating Lambda execution role"

cat > /tmp/lambda-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
    --tags Key=Project,Value="$PROJECT_NAME" \
    2>&1 || log_warn "Lambda role already exists"

# Attach basic Lambda execution policy (CloudWatch Logs)
aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
    2>&1 || log_warn "Basic execution policy already attached"

# Custom policy for Secrets Manager
cat > /tmp/lambda-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${PROJECT_NAME}/*"
    }
  ]
}
EOF

LAMBDA_SECRETS_POLICY_ARN=$(aws iam create-policy \
    --policy-name "${PROJECT_NAME}-lambda-secrets-access" \
    --policy-document file:///tmp/lambda-secrets-policy.json \
    --query 'Policy.Arn' --output text 2>/dev/null || \
    echo "arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT_NAME}-lambda-secrets-access")

aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn "$LAMBDA_SECRETS_POLICY_ARN" \
    2>&1 || log_warn "Secrets policy already attached"

LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
log_success "Lambda role: $LAMBDA_ROLE_ARN"

# Wait for IAM propagation
log_info "Waiting 10s for IAM role propagation..."
sleep 10

###############################################################################
# PHASE 2: Create CloudWatch Log Group for Lambda
###############################################################################

log_phase "PHASE 2: CLOUDWATCH LOG GROUP"

aws logs create-log-group \
    --log-group-name "/aws/lambda/${LAMBDA_FUNCTION_NAME}" \
    --region "$REGION" \
    2>&1 || log_warn "Lambda log group already exists"

aws logs put-retention-policy \
    --log-group-name "/aws/lambda/${LAMBDA_FUNCTION_NAME}" \
    --retention-in-days 30 \
    --region "$REGION" 2>&1 || true

log_success "Log group /aws/lambda/${LAMBDA_FUNCTION_NAME} created"

###############################################################################
# PHASE 3: Package and Deploy Lambda
###############################################################################

log_phase "PHASE 3: DEPLOYING LAMBDA FUNCTION"

log_step "3.1" "Packaging Lambda function"

LAMBDA_SOURCE="$PROJECT_DIR/lambda/permissions_api.py"
if [ ! -f "$LAMBDA_SOURCE" ]; then
    log_error "Lambda source not found: $LAMBDA_SOURCE"
    exit 1
fi

LAMBDA_ZIP="/tmp/lambda-permissions-api.zip"
cd "$PROJECT_DIR/lambda"
zip -j "$LAMBDA_ZIP" permissions_api.py > /dev/null
cd "$PROJECT_DIR"

log_success "Lambda packaged: $LAMBDA_ZIP"

log_step "3.2" "Creating/updating Lambda function"

# Get API key secret ARN
API_KEY_SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --region "$REGION" \
    --query 'ARN' --output text 2>&1)

# Try to create, update if exists
aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --runtime python3.11 \
    --handler permissions_api.lambda_handler \
    --role "$LAMBDA_ROLE_ARN" \
    --zip-file "fileb://$LAMBDA_ZIP" \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={SECRET_NAME=${PROJECT_NAME}/api/auth-key,REGION=${REGION}}" \
    --tags Project="$PROJECT_NAME",Environment=dev \
    --region "$REGION" \
    2>&1 || \
aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file "fileb://$LAMBDA_ZIP" \
    --region "$REGION" > /dev/null

# Wait for function to be active
aws lambda wait function-active-v2 \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$REGION" 2>&1 || true

LAMBDA_ARN=$(aws lambda get-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$REGION" \
    --query 'Configuration.FunctionArn' --output text)

log_success "Lambda function: $LAMBDA_ARN"

###############################################################################
# PHASE 4: API Gateway
###############################################################################

log_phase "PHASE 4: CREATING API GATEWAY"

log_step "4.1" "Creating REST API"

# Reuse existing API Gateway if one exists, otherwise create new
# Use [0] to pick the first match if duplicates exist
API_ID=$(aws apigateway get-rest-apis \
    --region "$REGION" \
    --query "items[?name=='${API_NAME}'].id | [0]" --output text 2>/dev/null)

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ] || [ "$API_ID" = "null" ]; then
    API_ID=$(aws apigateway create-rest-api \
        --name "$API_NAME" \
        --description "Denodo POC Authorization API" \
        --endpoint-configuration types=REGIONAL \
        --tags Project="$PROJECT_NAME" \
        --region "$REGION" \
        --query 'id' --output text)
    log_success "API Gateway created: $API_ID"
else
    # Clean up duplicate API Gateways (keep only the first)
    DUPLICATE_IDS=$(aws apigateway get-rest-apis \
        --region "$REGION" \
        --query "items[?name=='${API_NAME}'].id" --output text 2>/dev/null)
    for DUP_ID in $DUPLICATE_IDS; do
        if [ "$DUP_ID" != "$API_ID" ]; then
            log_warn "Deleting duplicate API Gateway: $DUP_ID"
            aws apigateway delete-rest-api --rest-api-id "$DUP_ID" --region "$REGION" 2>/dev/null || true
        fi
    done
    log_info "Reusing existing API Gateway: $API_ID"
fi

log_success "API Gateway ID: $API_ID"

log_step "4.2" "Creating API resources"

# Get root resource ID
ROOT_RESOURCE_ID=$(aws apigateway get-resources \
    --rest-api-id "$API_ID" \
    --region "$REGION" \
    --query 'items[?path==`/`].id' --output text)

# Create /api
API_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$ROOT_RESOURCE_ID" \
    --path-part "api" \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-resources \
        --rest-api-id "$API_ID" \
        --region "$REGION" \
        --query "items[?pathPart=='api'].id" --output text)

# Create /api/v1
V1_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$API_RESOURCE_ID" \
    --path-part "v1" \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-resources \
        --rest-api-id "$API_ID" \
        --region "$REGION" \
        --query "items[?pathPart=='v1'].id" --output text)

# Create /api/v1/users
USERS_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$V1_RESOURCE_ID" \
    --path-part "users" \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-resources \
        --rest-api-id "$API_ID" \
        --region "$REGION" \
        --query "items[?pathPart=='users'].id" --output text)

# Create /api/v1/users/{userId}
USERID_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$USERS_RESOURCE_ID" \
    --path-part "{userId}" \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-resources \
        --rest-api-id "$API_ID" \
        --region "$REGION" \
        --query "items[?pathPart=='{userId}'].id" --output text)

# Create /api/v1/users/{userId}/permissions
PERMISSIONS_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$USERID_RESOURCE_ID" \
    --path-part "permissions" \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-resources \
        --rest-api-id "$API_ID" \
        --region "$REGION" \
        --query "items[?pathPart=='permissions'].id" --output text)

log_success "API resources created: /api/v1/users/{userId}/permissions"

log_step "4.3" "Creating GET method"

# Create GET method (API key required)
aws apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$PERMISSIONS_RESOURCE_ID" \
    --http-method GET \
    --authorization-type NONE \
    --api-key-required \
    --request-parameters "method.request.path.userId=true,method.request.header.X-API-Key=true" \
    --region "$REGION" 2>&1 || log_warn "GET method already exists"

# Lambda integration
aws apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$PERMISSIONS_RESOURCE_ID" \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
    --region "$REGION" 2>&1 || log_warn "Integration already exists"

log_success "GET method with Lambda proxy integration configured"

log_step "4.4" "Adding CORS support (OPTIONS method)"

aws apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$PERMISSIONS_RESOURCE_ID" \
    --http-method OPTIONS \
    --authorization-type NONE \
    --region "$REGION" 2>&1 || log_warn "OPTIONS method already exists"

aws apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$PERMISSIONS_RESOURCE_ID" \
    --http-method OPTIONS \
    --type MOCK \
    --request-templates '{"application/json": "{\"statusCode\": 200}"}' \
    --region "$REGION" 2>&1 || true

aws apigateway put-method-response \
    --rest-api-id "$API_ID" \
    --resource-id "$PERMISSIONS_RESOURCE_ID" \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters "method.response.header.Access-Control-Allow-Headers=false,method.response.header.Access-Control-Allow-Methods=false,method.response.header.Access-Control-Allow-Origin=false" \
    --region "$REGION" 2>&1 || true

aws apigateway put-integration-response \
    --rest-api-id "$API_ID" \
    --resource-id "$PERMISSIONS_RESOURCE_ID" \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers":"'"'"'Content-Type,X-API-Key'"'"'","method.response.header.Access-Control-Allow-Methods":"'"'"'GET,OPTIONS'"'"'","method.response.header.Access-Control-Allow-Origin":"'"'"'*'"'"'"}' \
    --region "$REGION" 2>&1 || true

log_success "CORS support configured"

log_step "4.5" "Granting API Gateway permission to invoke Lambda"

# Remove stale permission first (may point to old API Gateway ID), then re-add
aws lambda remove-permission \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --statement-id apigateway-invoke \
    --region "$REGION" 2>/dev/null || true

aws lambda add-permission \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --statement-id apigateway-invoke \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
    --region "$REGION" 2>&1

log_success "Lambda invoke permission granted (API ID: ${API_ID})"

log_step "4.6" "Creating API key and usage plan"

# Create API key
API_KEY_VALUE=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --region "$REGION" \
    --query SecretString --output text | jq -r '.apiKey')

API_KEY_ID=$(aws apigateway create-api-key \
    --name "${PROJECT_NAME}-api-key" \
    --description "API key for Denodo POC authorization API" \
    --enabled \
    --value "$API_KEY_VALUE" \
    --tags Project="$PROJECT_NAME" \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-api-keys \
        --name-query "${PROJECT_NAME}-api-key" \
        --region "$REGION" \
        --query 'items[0].id' --output text)

log_success "API Key created: $API_KEY_ID"

# Create usage plan
USAGE_PLAN_ID=$(aws apigateway create-usage-plan \
    --name "${PROJECT_NAME}-usage-plan" \
    --description "Usage plan for Denodo POC" \
    --throttle burstLimit=100,rateLimit=50 \
    --quota limit=10000,period=MONTH \
    --region "$REGION" \
    --query 'id' --output text 2>/dev/null || \
    aws apigateway get-usage-plans \
        --region "$REGION" \
        --query "items[?name=='${PROJECT_NAME}-usage-plan'].id" --output text)

log_success "Usage plan: $USAGE_PLAN_ID"

# Associate API key with usage plan
aws apigateway create-usage-plan-key \
    --usage-plan-id "$USAGE_PLAN_ID" \
    --key-id "$API_KEY_ID" \
    --key-type API_KEY \
    --region "$REGION" 2>&1 || log_warn "API key already associated"

log_step "4.7" "Deploying API to 'dev' stage"

aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --stage-name dev \
    --description "Initial deployment" \
    --region "$REGION" > /dev/null 2>&1

# Associate usage plan with stage
aws apigateway update-usage-plan \
    --usage-plan-id "$USAGE_PLAN_ID" \
    --patch-operations "op=add,path=/apiStages,value=${API_ID}:dev" \
    --region "$REGION" 2>&1 || log_warn "Stage already associated"

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev"
log_success "API deployed at: $API_ENDPOINT"

###############################################################################
# PHASE 5: Update deployment-info.json
###############################################################################

log_phase "PHASE 5: UPDATING DEPLOYMENT INFO"

UPDATED_INFO=$(jq \
    --arg lambda_arn "$LAMBDA_ARN" \
    --arg api_id "$API_ID" \
    --arg api_endpoint "$API_ENDPOINT" \
    --arg api_key_id "$API_KEY_ID" \
    --arg usage_plan_id "$USAGE_PLAN_ID" \
    --arg lambda_role "$LAMBDA_ROLE_ARN" \
    '. + {
        "lambda": {
            "functionArn": $lambda_arn,
            "functionName": "denodo-permissions-api"
        },
        "apiGateway": {
            "apiId": $api_id,
            "endpoint": $api_endpoint,
            "apiKeyId": $api_key_id,
            "usagePlanId": $usage_plan_id,
            "permissionsUrl": ($api_endpoint + "/api/v1/users/{userId}/permissions")
        },
        "iamRoles": (.iamRoles // {} | . + {"lambdaRole": $lambda_role})
    }' "$DEPLOYMENT_INFO")

echo "$UPDATED_INFO" > "$DEPLOYMENT_INFO"
log_success "deployment-info.json updated"

###############################################################################
# SUMMARY
###############################################################################

echo ""
log_phase "✓ LAMBDA API DEPLOYMENT COMPLETE"
echo ""
echo "Resources Created:"
echo "  ✓ 1 IAM Role (${LAMBDA_ROLE_NAME})"
echo "  ✓ 1 Lambda Function (${LAMBDA_FUNCTION_NAME})"
echo "  ✓ 1 API Gateway (${API_NAME})"
echo "  ✓ 1 API Key + Usage Plan"
echo "  ✓ 1 CloudWatch Log Group"
echo ""
echo "Test the API:"
echo "  curl -H \"X-API-Key: \$API_KEY\" \\"
echo "    \"${API_ENDPOINT}/api/v1/users/analyst@denodo.com/permissions\""
echo ""
echo -e "${YELLOW}Next step:${NC}"
echo "  ./scripts/configure-keycloak.sh"
echo ""

rm -f /tmp/lambda-trust-policy.json /tmp/lambda-secrets-policy.json "$LAMBDA_ZIP"
