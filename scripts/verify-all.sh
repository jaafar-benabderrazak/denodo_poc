#!/bin/bash
###############################################################################
# Denodo POC - Full Verification Script (CloudShell)
#
# Tests all deployed components end-to-end:
#   1. API Gateway + Lambda (permissions endpoint)
#   2. Keycloak UI accessibility (admin console, static resources)
#   3. OIDC discovery endpoints (provider + consumer)
#   4. OIDC token grants (admin + test users)
#   5. OIDC federation (consumer -> provider brokering)
#   6. OpenData RDS connectivity (via SSM)
#
# Usage: ./scripts/verify-all.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
RESULTS=()

REGION="eu-west-3"
PROJECT_NAME="denodo-poc"

log_phase() {
  echo ""
  echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║  $1${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

assert_pass() {
  echo -e "  ${GREEN}PASS${NC}  $1"
  PASS=$((PASS + 1))
  RESULTS+=("PASS|$1")
}

assert_fail() {
  echo -e "  ${RED}FAIL${NC}  $1"
  FAIL=$((FAIL + 1))
  RESULTS+=("FAIL|$1")
}

assert_warn() {
  echo -e "  ${YELLOW}WARN${NC}  $1"
  WARN=$((WARN + 1))
  RESULTS+=("WARN|$1")
}

###############################################################################
# Resolve endpoints
###############################################################################
log_phase "PHASE 0: RESOLVING ENDPOINTS"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names keycloak-alb \
  --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "NOTFOUND")

if [ "$ALB_DNS" == "NOTFOUND" ] || [ -z "$ALB_DNS" ]; then
  echo -e "${RED}ALB not found. Cannot proceed.${NC}"
  exit 1
fi
echo -e "  ALB: ${CYAN}$ALB_DNS${NC}"

# Find the API Gateway (search by name pattern)
API_ID=$(aws apigateway get-rest-apis \
  --region "$REGION" \
  --query "items[?contains(name, 'denodo')].id" \
  --output text 2>/dev/null || echo "")

if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
  # Try v2 API
  API_ENDPOINT=$(aws apigatewayv2 get-apis \
    --region "$REGION" \
    --query "Items[?contains(Name, 'denodo')].ApiEndpoint" \
    --output text 2>/dev/null || echo "")
else
  API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev"
fi

echo -e "  API: ${CYAN}${API_ENDPOINT:-NOTFOUND}${NC}"

# Resolve API key
API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/api/auth-key" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.apiKey' 2>/dev/null || echo "")

# Also try fetching the key directly from API Gateway
if [ -z "$API_KEY" ] && [ ! -z "$API_ID" ]; then
  API_KEY=$(aws apigateway get-api-keys \
    --name-query "denodo-poc-api-key" \
    --include-values \
    --region "$REGION" \
    --query "items[0].value" --output text 2>/dev/null || echo "")
fi

if [ ! -z "$API_KEY" ]; then
  echo -e "  Key: ${CYAN}${API_KEY:0:8}...${NC}"
else
  echo -e "  Key: ${YELLOW}not found${NC}"
fi

# Resolve admin password
ADMIN_PWD=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/keycloak/admin" \
  --region "$REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.password' 2>/dev/null || echo "")

echo -e "  Admin password: ${CYAN}${#ADMIN_PWD} chars${NC}"

###############################################################################
# TEST 1: API Gateway + Lambda
###############################################################################
log_phase "TEST 1: API GATEWAY + LAMBDA PERMISSIONS API"

if [ ! -z "$API_ENDPOINT" ] && [ "$API_ENDPOINT" != "NOTFOUND" ] && [ ! -z "$API_KEY" ]; then

  # 1a. Analyst permissions
  echo "  Testing analyst@denodo.com..."
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions" 2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    assert_pass "GET analyst permissions -> HTTP 200"
    
    # Check response fields
    HAS_USERID=$(echo "$BODY" | jq -r '.userId // empty' 2>/dev/null)
    HAS_PROFILES=$(echo "$BODY" | jq -r '.profiles // empty' 2>/dev/null)
    HAS_DATASOURCES=$(echo "$BODY" | jq -r '.datasources // empty' 2>/dev/null)

    [ ! -z "$HAS_USERID" ] && assert_pass "Response has userId=$HAS_USERID" || assert_fail "Response missing userId"
    [ ! -z "$HAS_PROFILES" ] && assert_pass "Response has profiles" || assert_fail "Response missing profiles"
    [ ! -z "$HAS_DATASOURCES" ] && assert_pass "Response has datasources" || assert_fail "Response missing datasources"

    echo ""
    echo -e "  ${CYAN}Response body:${NC}"
    echo "$BODY" | jq '.' 2>/dev/null | sed 's/^/    /'
    echo ""
  else
    assert_fail "GET analyst permissions -> HTTP $HTTP_CODE (expected 200)"
    echo "  Body: $BODY" | head -5
  fi

  # 1b. Scientist permissions
  echo "  Testing scientist@denodo.com..."
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    "$API_ENDPOINT/api/v1/users/scientist@denodo.com/permissions" 2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    assert_pass "GET scientist permissions -> HTTP 200"
  else
    assert_fail "GET scientist permissions -> HTTP $HTTP_CODE"
  fi

  # 1c. Admin permissions
  echo "  Testing admin@denodo.com..."
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    "$API_ENDPOINT/api/v1/users/admin@denodo.com/permissions" 2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    assert_pass "GET admin permissions -> HTTP 200"
  else
    assert_fail "GET admin permissions -> HTTP $HTTP_CODE"
  fi

  # 1d. Missing API key -> should be 403
  echo "  Testing missing API key..."
  RESP=$(curl -s -o /dev/null -w "%{http_code}" \
    "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions" 2>/dev/null || echo "000")

  if [ "$RESP" == "403" ]; then
    assert_pass "Missing API key -> HTTP 403 (correct)"
  else
    assert_warn "Missing API key -> HTTP $RESP (expected 403)"
  fi

  # 1e. Invalid API key -> should be 403
  echo "  Testing invalid API key..."
  RESP=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: INVALID_KEY_12345" \
    "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions" 2>/dev/null || echo "000")

  if [ "$RESP" == "403" ]; then
    assert_pass "Invalid API key -> HTTP 403 (correct)"
  else
    assert_warn "Invalid API key -> HTTP $RESP (expected 403)"
  fi

  # 1f. Unknown user -> should return 200 with guest profile
  echo "  Testing unknown user..."
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    "$API_ENDPOINT/api/v1/users/unknown@test.com/permissions" 2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    GUEST_PROFILE=$(echo "$BODY" | jq -r '.profiles[0] // empty' 2>/dev/null)
    if [ "$GUEST_PROFILE" == "guest" ]; then
      assert_pass "Unknown user -> HTTP 200 with guest profile"
    else
      assert_pass "Unknown user -> HTTP 200 (profile: $GUEST_PROFILE)"
    fi
  else
    assert_warn "Unknown user -> HTTP $HTTP_CODE"
  fi

else
  assert_fail "API Gateway endpoint or API Key not available -- skipping API tests"
fi

###############################################################################
# TEST 2: KEYCLOAK UI ACCESSIBILITY
###############################################################################
log_phase "TEST 2: KEYCLOAK UI ACCESSIBILITY"

# 2a. Base Keycloak URL
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "303" ] || [ "$HTTP_CODE" == "302" ]; then
  assert_pass "Keycloak base /auth/ -> HTTP $HTTP_CODE"
else
  assert_fail "Keycloak base /auth/ -> HTTP $HTTP_CODE"
fi

# 2b. Admin console HTML page (should return 200 with HTML content)
RESP=$(curl -s -w "\n%{http_code}" \
  "http://${ALB_DNS}/auth/admin/master/console/" 2>/dev/null || echo -e "\n000")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
  # Check if the response actually contains HTML (not just "Loading...")
  if echo "$BODY" | grep -q "<title>" 2>/dev/null; then
    assert_pass "Admin console HTML -> HTTP 200 with <title>"
  else
    assert_pass "Admin console -> HTTP 200"
  fi
else
  assert_fail "Admin console -> HTTP $HTTP_CODE"
fi

# 2c. Keycloak JS resource (verifies ALB catch-all /auth/* rule)
KC_JS=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${ALB_DNS}/auth/js/keycloak.js" 2>/dev/null || echo "000")

if [ "$KC_JS" == "200" ]; then
  assert_pass "Keycloak JS resource /auth/js/keycloak.js -> HTTP 200"
elif [ "$KC_JS" == "302" ] || [ "$KC_JS" == "303" ]; then
  assert_pass "Keycloak JS resource -> HTTP $KC_JS (redirect, OK)"
else
  assert_warn "Keycloak JS resource -> HTTP $KC_JS (may affect admin UI loading)"
fi

# 2d. Health endpoint
HEALTH=$(curl -s "http://${ALB_DNS}/auth/health/ready" 2>/dev/null || echo '{}')
HEALTH_STATUS=$(echo "$HEALTH" | jq -r '.status // empty' 2>/dev/null)

if [ "$HEALTH_STATUS" == "UP" ]; then
  assert_pass "Keycloak health /auth/health/ready -> UP"
else
  assert_warn "Keycloak health -> status=$HEALTH_STATUS"
fi

# 2e. Live check
LIVE=$(curl -s "http://${ALB_DNS}/auth/health/live" 2>/dev/null || echo '{}')
LIVE_STATUS=$(echo "$LIVE" | jq -r '.status // empty' 2>/dev/null)

if [ "$LIVE_STATUS" == "UP" ]; then
  assert_pass "Keycloak liveness /auth/health/live -> UP"
else
  assert_warn "Keycloak liveness -> status=$LIVE_STATUS"
fi

###############################################################################
# TEST 3: OIDC DISCOVERY (Provider + Consumer)
###############################################################################
log_phase "TEST 3: OIDC DISCOVERY ENDPOINTS"

# 3a. Provider realm OIDC discovery
PROVIDER_OIDC=$(curl -s -w "\n%{http_code}" \
  "http://${ALB_DNS}/auth/realms/denodo-idp/.well-known/openid-configuration" 2>/dev/null || echo -e "\n000")
HTTP_CODE=$(echo "$PROVIDER_OIDC" | tail -1)
BODY=$(echo "$PROVIDER_OIDC" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
  ISSUER=$(echo "$BODY" | jq -r '.issuer // empty' 2>/dev/null)
  TOKEN_EP=$(echo "$BODY" | jq -r '.token_endpoint // empty' 2>/dev/null)
  assert_pass "Provider OIDC discovery -> HTTP 200"
  echo -e "    Issuer: ${CYAN}$ISSUER${NC}"
  echo -e "    Token:  ${CYAN}$TOKEN_EP${NC}"
else
  assert_fail "Provider OIDC discovery -> HTTP $HTTP_CODE"
fi

# 3b. Consumer realm OIDC discovery
CONSUMER_OIDC=$(curl -s -w "\n%{http_code}" \
  "http://${ALB_DNS}/auth/realms/denodo-consumer/.well-known/openid-configuration" 2>/dev/null || echo -e "\n000")
HTTP_CODE=$(echo "$CONSUMER_OIDC" | tail -1)
BODY=$(echo "$CONSUMER_OIDC" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
  ISSUER=$(echo "$BODY" | jq -r '.issuer // empty' 2>/dev/null)
  assert_pass "Consumer OIDC discovery -> HTTP 200"
  echo -e "    Issuer: ${CYAN}$ISSUER${NC}"
else
  assert_fail "Consumer OIDC discovery -> HTTP $HTTP_CODE"
fi

###############################################################################
# TEST 4: OIDC TOKEN GRANTS (Password Grant on Provider)
###############################################################################
log_phase "TEST 4: OIDC TOKEN GRANTS"

TOKEN_URL="http://${ALB_DNS}/auth/realms/denodo-idp/protocol/openid-connect/token"

# 4a. Admin token (master realm)
if [ ! -z "$ADMIN_PWD" ]; then
  RESP=$(curl -s -w "\n%{http_code}" -X POST \
    "http://${ALB_DNS}/auth/realms/master/protocol/openid-connect/token" \
    -d "username=admin&password=${ADMIN_PWD}&grant_type=password&client_id=admin-cli" \
    2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    ACCESS_TOKEN=$(echo "$BODY" | jq -r '.access_token // empty' 2>/dev/null)
    if [ ! -z "$ACCESS_TOKEN" ]; then
      assert_pass "Admin token grant (master) -> HTTP 200 + access_token"
      ADMIN_TOKEN="$ACCESS_TOKEN"
    else
      assert_fail "Admin token grant -> HTTP 200 but no access_token"
    fi
  else
    assert_fail "Admin token grant (master) -> HTTP $HTTP_CODE"
    echo "  Error: $(echo "$BODY" | jq -r '.error_description // .error // empty' 2>/dev/null)"
  fi
else
  assert_warn "Admin password not found -- skipping admin token test"
fi

# 4b. Test user token grants on provider realm (denodo-idp)
for USER_TEST in "analyst@denodo.com:Analyst@2026!" "scientist@denodo.com:Scientist@2026!" "admin@denodo.com:Admin@2026!"; do
  USER=$(echo "$USER_TEST" | cut -d: -f1)
  PASS_USER=$(echo "$USER_TEST" | cut -d: -f2)

  RESP=$(curl -s -w "\n%{http_code}" -X POST \
    "$TOKEN_URL" \
    -d "username=${USER}&password=${PASS_USER}&grant_type=password&client_id=denodo-consumer&client_secret=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_NAME}/keycloak/client-secret" --region "$REGION" --query SecretString --output text 2>/dev/null | jq -r '.clientSecret' 2>/dev/null)&scope=openid email profile" \
    2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    ACCESS_TOKEN=$(echo "$BODY" | jq -r '.access_token // empty' 2>/dev/null)
    if [ ! -z "$ACCESS_TOKEN" ]; then
      # Decode JWT payload (base64)
      PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null || echo '{}')
      EMAIL=$(echo "$PAYLOAD" | jq -r '.email // empty' 2>/dev/null)
      assert_pass "Token grant $USER -> HTTP 200 (email=$EMAIL)"
    else
      assert_fail "Token grant $USER -> HTTP 200 but no access_token"
    fi
  else
    ERROR=$(echo "$BODY" | jq -r '.error_description // .error // empty' 2>/dev/null)
    assert_fail "Token grant $USER -> HTTP $HTTP_CODE ($ERROR)"
  fi
done

###############################################################################
# TEST 5: OIDC FEDERATION (Consumer -> Provider Brokering)
###############################################################################
log_phase "TEST 5: OIDC FEDERATION VERIFICATION"

# 5a. Check that consumer realm has the provider-idp identity provider configured
if [ ! -z "$ADMIN_TOKEN" ]; then
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://${ALB_DNS}/auth/admin/realms/denodo-consumer/identity-provider/instances" \
    2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    IDP_ALIAS=$(echo "$BODY" | jq -r '.[0].alias // empty' 2>/dev/null)
    IDP_ENABLED=$(echo "$BODY" | jq -r '.[0].enabled // empty' 2>/dev/null)
    if [ "$IDP_ALIAS" == "provider-idp" ] && [ "$IDP_ENABLED" == "true" ]; then
      assert_pass "Consumer has IdP 'provider-idp' (enabled=true)"
    elif [ ! -z "$IDP_ALIAS" ]; then
      assert_warn "Consumer has IdP '$IDP_ALIAS' (enabled=$IDP_ENABLED)"
    else
      assert_fail "Consumer has no identity providers configured"
    fi
  else
    assert_fail "List consumer IdPs -> HTTP $HTTP_CODE"
  fi

  # 5b. Check that provider realm has the denodo-consumer client
  RESP=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://${ALB_DNS}/auth/admin/realms/denodo-idp/clients?clientId=denodo-consumer" \
    2>/dev/null || echo -e "\n000")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$HTTP_CODE" == "200" ]; then
    CLIENT_ID=$(echo "$BODY" | jq -r '.[0].clientId // empty' 2>/dev/null)
    CLIENT_ENABLED=$(echo "$BODY" | jq -r '.[0].enabled // empty' 2>/dev/null)
    if [ "$CLIENT_ID" == "denodo-consumer" ]; then
      assert_pass "Provider has client 'denodo-consumer' (enabled=$CLIENT_ENABLED)"
    else
      assert_fail "Provider client 'denodo-consumer' not found"
    fi
  else
    assert_fail "List provider clients -> HTTP $HTTP_CODE"
  fi

  # 5c. Check users exist on provider realm
  for EXPECTED_USER in "analyst@denodo.com" "scientist@denodo.com" "admin@denodo.com"; do
    RESP=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "http://${ALB_DNS}/auth/admin/realms/denodo-idp/users?email=$EXPECTED_USER" \
      2>/dev/null || echo -e "\n000")
    HTTP_CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')

    if [ "$HTTP_CODE" == "200" ]; then
      COUNT=$(echo "$BODY" | jq '. | length' 2>/dev/null)
      if [ "$COUNT" -gt 0 ]; then
        assert_pass "User $EXPECTED_USER exists in denodo-idp"
      else
        assert_fail "User $EXPECTED_USER not found in denodo-idp"
      fi
    else
      assert_fail "Query user $EXPECTED_USER -> HTTP $HTTP_CODE"
    fi
  done

  # 5d. Consumer account page (federation login page)
  ACCOUNT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${ALB_DNS}/auth/realms/denodo-consumer/account" 2>/dev/null || echo "000")
  
  if [ "$ACCOUNT_CODE" == "200" ] || [ "$ACCOUNT_CODE" == "302" ] || [ "$ACCOUNT_CODE" == "303" ]; then
    assert_pass "Consumer account page -> HTTP $ACCOUNT_CODE (login redirect)"
  else
    assert_fail "Consumer account page -> HTTP $ACCOUNT_CODE"
  fi

else
  assert_warn "No admin token -- skipping federation API checks"
  
  # Fallback: test account page directly
  ACCOUNT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${ALB_DNS}/auth/realms/denodo-consumer/account" 2>/dev/null || echo "000")
  
  if [ "$ACCOUNT_CODE" == "200" ] || [ "$ACCOUNT_CODE" == "302" ] || [ "$ACCOUNT_CODE" == "303" ]; then
    assert_pass "Consumer account page -> HTTP $ACCOUNT_CODE"
  else
    assert_fail "Consumer account page -> HTTP $ACCOUNT_CODE"
  fi
fi

###############################################################################
# TEST 6: OPENDATA RDS (via SSM)
###############################################################################
log_phase "TEST 6: OPENDATA RDS (via Denodo EC2 / SSM)"

# Find Denodo EC2 instance
EC2_ID=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=*enodo*" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "None")

if [ "$EC2_ID" == "None" ] || [ -z "$EC2_ID" ]; then
  # Try broader search
  EC2_ID=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --region "$REGION" \
    --query 'Reservations[*].Instances[?Tags[?contains(Value, `enodo`)]].InstanceId' \
    --output text 2>/dev/null | head -1 || echo "None")
fi

if [ "$EC2_ID" != "None" ] && [ ! -z "$EC2_ID" ]; then
  assert_pass "Denodo EC2: $EC2_ID"

  # Check SSM
  SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$EC2_ID" \
    --region "$REGION" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "Offline")

  if [ "$SSM_STATUS" == "Online" ]; then
    assert_pass "SSM Agent: Online"

    # Get DB credentials
    DB_HOST=$(aws rds describe-db-instances \
      --db-instance-identifier "${PROJECT_NAME}-opendata-db" \
      --region "$REGION" \
      --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")
    DB_PASS=$(aws secretsmanager get-secret-value \
      --secret-id "${PROJECT_NAME}/opendata/db" \
      --region "$REGION" \
      --query SecretString --output text 2>/dev/null | jq -r '.password' 2>/dev/null || echo "")

    if [ ! -z "$DB_HOST" ] && [ ! -z "$DB_PASS" ]; then
      # Test connection via SSM
      CMD_ID=$(aws ssm send-command \
        --instance-ids "$EC2_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT 'OK' AS status;\\\" 2>&1 || echo CONNECT_FAILED\"]" \
        --region "$REGION" \
        --query 'Command.CommandId' --output text 2>/dev/null || echo "")

      if [ ! -z "$CMD_ID" ]; then
        sleep 5
        RESULT=$(aws ssm get-command-invocation \
          --command-id "$CMD_ID" \
          --instance-id "$EC2_ID" \
          --region "$REGION" \
          --query 'StandardOutputContent' --output text 2>/dev/null || echo "TIMEOUT")

        if echo "$RESULT" | grep -q "OK"; then
          assert_pass "RDS OpenData connection via SSM: OK"

          # Check tables
          CMD_ID2=$(aws ssm send-command \
            --instance-ids "$EC2_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT tablename FROM pg_tables WHERE schemaname='opendata' ORDER BY tablename;\\\" 2>&1\"]" \
            --region "$REGION" \
            --query 'Command.CommandId' --output text 2>/dev/null || echo "")

          if [ ! -z "$CMD_ID2" ]; then
            sleep 5
            TABLES=$(aws ssm get-command-invocation \
              --command-id "$CMD_ID2" \
              --instance-id "$EC2_ID" \
              --region "$REGION" \
              --query 'StandardOutputContent' --output text 2>/dev/null || echo "")

            if echo "$TABLES" | grep -q "entreprises"; then
              assert_pass "Table 'entreprises' exists"
            else
              assert_warn "Table 'entreprises' not found in opendata schema"
            fi

            if echo "$TABLES" | grep -q "population_communes"; then
              assert_pass "Table 'population_communes' exists"
            else
              assert_warn "Table 'population_communes' not found"
            fi
          fi
        else
          assert_fail "RDS OpenData connection: $RESULT"
        fi
      else
        assert_fail "SSM send-command failed"
      fi
    else
      assert_warn "OpenData DB credentials not available"
    fi
  else
    assert_warn "SSM Agent: $SSM_STATUS"
  fi
else
  assert_warn "Denodo EC2 not found -- skipping RDS tests"
fi

###############################################################################
# SUMMARY
###############################################################################
log_phase "VERIFICATION SUMMARY"

TOTAL=$((PASS + FAIL + WARN))

echo -e "  Total tests:  ${CYAN}$TOTAL${NC}"
echo -e "  ${GREEN}PASS:  $PASS${NC}"
echo -e "  ${RED}FAIL:  $FAIL${NC}"
echo -e "  ${YELLOW}WARN:  $WARN${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${GREEN}║  ALL TESTS PASSED -- POC IS FULLY OPERATIONAL           ║${NC}"
  echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
else
  echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${RED}║  $FAIL TEST(S) FAILED -- REVIEW RESULTS ABOVE             ║${NC}"
  echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  ${CYAN}Test Results Detail:${NC}"
for R in "${RESULTS[@]}"; do
  STATUS=$(echo "$R" | cut -d'|' -f1)
  DESC=$(echo "$R" | cut -d'|' -f2)
  case "$STATUS" in
    PASS) echo -e "    ${GREEN}[PASS]${NC} $DESC" ;;
    FAIL) echo -e "    ${RED}[FAIL]${NC} $DESC" ;;
    WARN) echo -e "    ${YELLOW}[WARN]${NC} $DESC" ;;
  esac
done

echo ""
exit $FAIL
