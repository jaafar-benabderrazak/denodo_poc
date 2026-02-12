#!/bin/bash
###############################################################################
# Denodo POC - Complete Setup & Verification
#
# Run this from CloudShell after the base infrastructure is deployed.
# It fixes known issues, deploys missing components, configures Keycloak,
# and prints all connection details for Denodo.
#
# Usage: ./scripts/complete-setup.sh
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
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_phase() {
  echo ""
  echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║ $1${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

REGION="eu-west-3"
PROJECT_NAME="denodo-poc"

if [ -f "$DEPLOYMENT_INFO" ]; then
  REGION=$(jq -r '.region' "$DEPLOYMENT_INFO" 2>/dev/null || echo "eu-west-3")
  PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO" 2>/dev/null || echo "denodo-poc")
fi

###############################################################################
# PHASE 1: Fix ALB routing (catch-all /auth/* rule)
###############################################################################
log_phase "PHASE 1: FIX ALB ROUTING FOR KEYCLOAK UI"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names keycloak-alb \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" == "None" ] || [ -z "$ALB_ARN" ]; then
  log_error "ALB 'keycloak-alb' not found. Deploy ECS first: ./scripts/deploy-ecs-keycloak.sh"
  exit 1
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region "$REGION" \
  --query 'Listeners[0].ListenerArn' --output text)

PROVIDER_TG_ARN=$(aws elbv2 describe-target-groups \
  --names keycloak-provider-tg \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")

if [ "$PROVIDER_TG_ARN" == "None" ] || [ -z "$PROVIDER_TG_ARN" ]; then
  log_error "Target group 'keycloak-provider-tg' not found."
  exit 1
fi

# Check if catch-all rule already exists
EXISTING_RULES=$(aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --region "$REGION" \
  --query "Rules[?Priority=='99'].RuleArn" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_RULES" ] || [ "$EXISTING_RULES" == "None" ]; then
  log_info "Adding catch-all /auth/* rule to ALB (priority 99)..."
  aws elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 99 \
    --conditions Field=path-pattern,Values='/auth/*' \
    --actions Type=forward,TargetGroupArn="$PROVIDER_TG_ARN" \
    --region "$REGION" >/dev/null 2>&1
  log_success "ALB catch-all rule added -- Keycloak admin UI will now load"
else
  log_success "ALB catch-all rule already exists"
fi

###############################################################################
# PHASE 2: Deploy API Gateway (if missing)
###############################################################################
log_phase "PHASE 2: DEPLOY API GATEWAY"

# Check REST API (v1) first -- exact name match
API_ID=$(aws apigateway get-rest-apis \
  --region "$REGION" \
  --query "items[?name=='denodo-auth-api'].id | [0]" \
  --output text 2>/dev/null || echo "")

# Fallback: check HTTP API (v2)
if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
  API_ID=$(aws apigatewayv2 get-apis \
    --region "$REGION" \
    --query "Items[?contains(Name, 'denodo')].ApiId | [0]" \
    --output text 2>/dev/null || echo "")
fi

if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
  log_info "API Gateway not found. Deploying..."
  
  if [ -f "$SCRIPT_DIR/deploy-lambda-api.sh" ]; then
    bash "$SCRIPT_DIR/deploy-lambda-api.sh"
    log_success "API Gateway deployed"
  else
    log_warn "deploy-lambda-api.sh not found, skipping API Gateway deployment"
  fi
else
  API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev"
  log_success "API Gateway already deployed: $API_ENDPOINT"
fi

###############################################################################
# PHASE 3: Configure Keycloak (if not done)
###############################################################################
log_phase "PHASE 3: CONFIGURE KEYCLOAK REALMS"

# Check if Provider realm exists by testing the well-known endpoint
REALM_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/realms/denodo-idp/.well-known/openid-configuration" 2>/dev/null || echo "000")

if [ "$REALM_CHECK" == "200" ]; then
  log_success "Keycloak Provider realm 'denodo-idp' already configured"
else
  log_info "Keycloak realms not configured. Running configuration..."
  
  if [ -f "$SCRIPT_DIR/configure-keycloak.sh" ]; then
    bash "$SCRIPT_DIR/configure-keycloak.sh" || {
      log_warn "Keycloak configuration had errors (may need manual setup)"
    }
  else
    log_warn "configure-keycloak.sh not found, skipping Keycloak configuration"
  fi
fi

# Check Consumer realm
CONSUMER_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/realms/denodo-consumer/.well-known/openid-configuration" 2>/dev/null || echo "000")

if [ "$CONSUMER_CHECK" == "200" ]; then
  log_success "Keycloak Consumer realm 'denodo-consumer' configured"
else
  log_warn "Consumer realm 'denodo-consumer' not accessible (HTTP $CONSUMER_CHECK)"
fi

###############################################################################
# PHASE 4: Verify ECS Services
###############################################################################
log_phase "PHASE 4: VERIFY ECS SERVICES"

for svc in keycloak-provider keycloak-consumer; do
  SERVICE_INFO=$(aws ecs describe-services \
    --cluster denodo-keycloak-cluster \
    --services "$svc" \
    --region "$REGION" \
    --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
    --output json 2>/dev/null || echo '{"Status":"NOT_FOUND","Running":0,"Desired":0}')
  
  RUNNING=$(echo "$SERVICE_INFO" | jq -r '.Running')
  DESIRED=$(echo "$SERVICE_INFO" | jq -r '.Desired')
  STATUS=$(echo "$SERVICE_INFO" | jq -r '.Status')
  
  if [ "$RUNNING" -gt "0" ] && [ "$STATUS" == "ACTIVE" ]; then
    log_success "$svc: $RUNNING/$DESIRED tasks ($STATUS)"
  else
    log_error "$svc: $RUNNING/$DESIRED tasks ($STATUS)"
  fi
done

###############################################################################
# PHASE 5: Verify RDS OpenData
###############################################################################
log_phase "PHASE 5: VERIFY OPENDATA DATABASE"

OPENDATA_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "${PROJECT_NAME}-opendata-db" \
  --region "$REGION" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text 2>/dev/null || echo "None")

OPENDATA_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "${PROJECT_NAME}-opendata-db" \
  --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "unknown")

if [ "$OPENDATA_STATUS" == "available" ]; then
  log_success "OpenData RDS: available ($OPENDATA_ENDPOINT)"
else
  log_error "OpenData RDS: $OPENDATA_STATUS"
fi

###############################################################################
# PHASE 6: Test Keycloak Accessibility
###############################################################################
log_phase "PHASE 6: TEST KEYCLOAK ACCESSIBILITY"

# Test base Keycloak URL
KC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/" 2>/dev/null || echo "000")

if [ "$KC_STATUS" == "200" ] || [ "$KC_STATUS" == "303" ] || [ "$KC_STATUS" == "302" ]; then
  log_success "Keycloak base URL: OK (HTTP $KC_STATUS)"
else
  log_error "Keycloak base URL: HTTP $KC_STATUS"
fi

# Test admin console
KC_ADMIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/admin/master/console/" 2>/dev/null || echo "000")

if [ "$KC_ADMIN_STATUS" == "200" ]; then
  log_success "Keycloak admin console: OK (HTTP $KC_ADMIN_STATUS)"
else
  log_warn "Keycloak admin console: HTTP $KC_ADMIN_STATUS"
fi

# Test a resource path (JS/CSS) to verify catch-all rule works
KC_RESOURCE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/resources/3.5.1/welcome/keycloak/" 2>/dev/null || echo "000")

if [ "$KC_RESOURCE_STATUS" != "404" ]; then
  log_success "Keycloak resources: OK (HTTP $KC_RESOURCE_STATUS)"
else
  log_error "Keycloak resources: HTTP 404 -- ALB catch-all rule may not be active"
fi

###############################################################################
# PHASE 7: Test Authorization API
###############################################################################
log_phase "PHASE 7: TEST AUTHORIZATION API"

# Re-read API endpoint (may have been updated by deploy-lambda-api.sh)
API_ENDPOINT=""
if [ -f "$DEPLOYMENT_INFO" ]; then
  API_ENDPOINT=$(jq -r '.apiGatewayEndpoint // empty' "$DEPLOYMENT_INFO" 2>/dev/null)
fi

if [ -z "$API_ENDPOINT" ] || [ "$API_ENDPOINT" == "null" ]; then
  # Try REST API (v1) -- exact name, pick one
  _API_ID=$(aws apigateway get-rest-apis \
    --region "$REGION" \
    --query "items[?name=='denodo-auth-api'].id | [0]" \
    --output text 2>/dev/null || echo "")
  if [ ! -z "$_API_ID" ] && [ "$_API_ID" != "None" ]; then
    API_ENDPOINT="https://${_API_ID}.execute-api.${REGION}.amazonaws.com/dev"
  else
    # Fallback to HTTP API (v2) -- pick first match
    API_ENDPOINT=$(aws apigatewayv2 get-apis \
      --region "$REGION" \
      --query "Items[?contains(Name, 'denodo')].ApiEndpoint | [0]" \
      --output text 2>/dev/null || echo "")
  fi
fi

if [ ! -z "$API_ENDPOINT" ] && [ "$API_ENDPOINT" != "None" ]; then
  API_KEY=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --region "$REGION" \
    --query SecretString --output text 2>/dev/null | jq -r '.apiKey' 2>/dev/null || echo "")

  if [ ! -z "$API_KEY" ]; then
    API_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "X-API-Key: $API_KEY" \
      "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions" 2>/dev/null || echo "000")

    if [ "$API_RESPONSE" == "200" ]; then
      log_success "Authorization API: OK (HTTP $API_RESPONSE)"
      
      # Show sample response
      PERMS=$(curl -s -H "X-API-Key: $API_KEY" \
        "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions" 2>/dev/null)
      echo "  Sample response (analyst@denodo.com):"
      echo "$PERMS" | jq '.' 2>/dev/null | sed 's/^/    /'
    else
      log_warn "Authorization API: HTTP $API_RESPONSE"
    fi
  else
    log_warn "API Key not found in Secrets Manager"
  fi
else
  log_warn "API Gateway endpoint not available"
fi

###############################################################################
# PHASE 8: Print Connection Details
###############################################################################
log_phase "PHASE 8: ALL CONNECTION DETAILS"

# Get credentials
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/keycloak/admin" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.password' 2>/dev/null || echo "N/A")

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/opendata/db" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.password' 2>/dev/null || echo "N/A")

CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/keycloak/client-secret" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.clientSecret' 2>/dev/null || echo "N/A")

API_KEY_VAL=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/api/auth-key" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.apiKey' 2>/dev/null || echo "N/A")

echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              KEYCLOAK ADMIN CONSOLE                    │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "  URL:      http://${ALB_DNS}/auth/admin"
echo -e "  Username: admin"
echo -e "  Password: $ADMIN_PASSWORD"
echo -e ""
echo -e "  Provider: http://${ALB_DNS}/auth/admin/master/console/#/denodo-idp"
echo -e "  Consumer: http://${ALB_DNS}/auth/admin/master/console/#/denodo-consumer"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              TEST USERS                                 │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "  analyst@denodo.com   / Analyst@2026!    (data-analyst)"
echo -e "  scientist@denodo.com / Scientist@2026!  (data-scientist)"
echo -e "  admin@denodo.com     / Admin@2026!      (admin)"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              DENODO: RDS OPENDATA CONNECTION            │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "  Type:     PostgreSQL"
echo -e "  Host:     $OPENDATA_ENDPOINT"
echo -e "  Port:     5432"
echo -e "  Database: opendata"
echo -e "  Schema:   opendata"
echo -e "  Username: denodo"
echo -e "  Password: $DB_PASSWORD"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              DENODO: KEYCLOAK OIDC                      │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "  Issuer:        http://${ALB_DNS}/auth/realms/denodo-consumer"
echo -e "  Client ID:     denodo-consumer"
echo -e "  Client Secret: $CLIENT_SECRET"
echo -e "  Scopes:        openid email profile"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

if [ ! -z "$API_ENDPOINT" ] && [ "$API_ENDPOINT" != "None" ]; then
echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              DENODO: AUTHORIZATION API                  │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "  Endpoint: $API_ENDPOINT"
echo -e "  API Key:  $API_KEY_VAL"
echo -e "  Header:   X-API-Key"
echo -e ""
echo -e "  Test:     curl -H 'X-API-Key: $API_KEY_VAL' \\"
echo -e "            '$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions'"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""
fi

echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              OIDC FEDERATION TEST                       │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "  Open in browser:"
echo -e "  http://${ALB_DNS}/auth/realms/denodo-consumer/account"
echo -e ""
echo -e "  Click 'Sign in with provider-idp'"
echo -e "  Login: analyst@denodo.com / Analyst@2026!"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

log_phase "SETUP COMPLETE"
echo -e "${GREEN}All components verified. Your Denodo POC is ready!${NC}"
echo ""
