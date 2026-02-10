#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Authentication Tests
#
# Tests Keycloak health, realm discovery, and token endpoints.
#
# Usage: ./tests/test-authentication.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

assert() {
    TOTAL=$((TOTAL + 1))
    local test_name=$1
    local expected=$2
    local actual=$3

    if [ "$actual" == "$expected" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} $test_name (expected: $expected, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    TOTAL=$((TOTAL + 1))
    local test_name=$1
    local value=$2

    if [ ! -z "$value" ] && [ "$value" != "null" ] && [ "$value" != "" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} $test_name (value is empty or null)"
        FAIL=$((FAIL + 1))
    fi
}

# Read deployment info
if [ ! -f "$DEPLOYMENT_INFO" ]; then
    echo -e "${RED}deployment-info.json not found${NC}"
    exit 1
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
ALB_DNS=$(jq -r '.alb.dns // empty' "$DEPLOYMENT_INFO")
KC_BASE_URL="http://${ALB_DNS}"

echo "═══════════════════════════════════════════════════════"
echo "  AUTHENTICATION TESTS"
echo "  Target: $KC_BASE_URL"
echo "═══════════════════════════════════════════════════════"

# Get admin password
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/keycloak/admin" \
    --region "$REGION" \
    --query SecretString --output text | jq -r '.password')

###############################################################################
# Test 1: Health Endpoints
###############################################################################

echo ""
echo "▶ Health Endpoints"

HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${KC_BASE_URL}/health/ready" 2>/dev/null || echo "000")
assert "Keycloak health/ready returns 200" "200" "$HEALTH_STATUS"

HEALTH_LIVE=$(curl -s -o /dev/null -w "%{http_code}" "${KC_BASE_URL}/health/live" 2>/dev/null || echo "000")
assert "Keycloak health/live returns 200" "200" "$HEALTH_LIVE"

###############################################################################
# Test 2: Provider Realm Discovery
###############################################################################

echo ""
echo "▶ Provider Realm (denodo-idp)"

PROVIDER_WELLKNOWN=$(curl -s "${KC_BASE_URL}/auth/realms/denodo-idp/.well-known/openid-configuration" 2>/dev/null)

PROVIDER_ISSUER=$(echo "$PROVIDER_WELLKNOWN" | jq -r '.issuer // empty')
assert_not_empty "Provider OIDC issuer is set" "$PROVIDER_ISSUER"

PROVIDER_AUTH_EP=$(echo "$PROVIDER_WELLKNOWN" | jq -r '.authorization_endpoint // empty')
assert_not_empty "Provider authorization_endpoint is set" "$PROVIDER_AUTH_EP"

PROVIDER_TOKEN_EP=$(echo "$PROVIDER_WELLKNOWN" | jq -r '.token_endpoint // empty')
assert_not_empty "Provider token_endpoint is set" "$PROVIDER_TOKEN_EP"

PROVIDER_USERINFO_EP=$(echo "$PROVIDER_WELLKNOWN" | jq -r '.userinfo_endpoint // empty')
assert_not_empty "Provider userinfo_endpoint is set" "$PROVIDER_USERINFO_EP"

PROVIDER_JWKS=$(echo "$PROVIDER_WELLKNOWN" | jq -r '.jwks_uri // empty')
assert_not_empty "Provider jwks_uri is set" "$PROVIDER_JWKS"

###############################################################################
# Test 3: Consumer Realm Discovery
###############################################################################

echo ""
echo "▶ Consumer Realm (denodo-consumer)"

CONSUMER_WELLKNOWN=$(curl -s "${KC_BASE_URL}/auth/realms/denodo-consumer/.well-known/openid-configuration" 2>/dev/null)

CONSUMER_ISSUER=$(echo "$CONSUMER_WELLKNOWN" | jq -r '.issuer // empty')
assert_not_empty "Consumer OIDC issuer is set" "$CONSUMER_ISSUER"

CONSUMER_TOKEN_EP=$(echo "$CONSUMER_WELLKNOWN" | jq -r '.token_endpoint // empty')
assert_not_empty "Consumer token_endpoint is set" "$CONSUMER_TOKEN_EP"

###############################################################################
# Test 4: Admin Authentication
###############################################################################

echo ""
echo "▶ Admin Token Grant"

ADMIN_TOKEN_RESPONSE=$(curl -s -X POST "${KC_BASE_URL}/auth/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" \
    -d "password=${ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" 2>/dev/null)

ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.access_token // empty')
assert_not_empty "Admin token grant returns access_token" "$ADMIN_TOKEN"

TOKEN_TYPE=$(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.token_type // empty')
assert "Admin token type is Bearer" "Bearer" "$TOKEN_TYPE"

###############################################################################
# Test 5: User Authentication on Provider Realm
###############################################################################

echo ""
echo "▶ User Token Grant (Provider Realm)"

for USER_EMAIL in analyst@denodo.com scientist@denodo.com admin@denodo.com; do
    case $USER_EMAIL in
        analyst@denodo.com)   PASSWORD="Analyst@2026!" ;;
        scientist@denodo.com) PASSWORD="Scientist@2026!" ;;
        admin@denodo.com)     PASSWORD="Admin@2026!" ;;
    esac

    # Get client secret
    CLIENT_SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "${PROJECT_NAME}/keycloak/client-secret" \
        --region "$REGION" \
        --query SecretString --output text | jq -r '.clientSecret')

    TOKEN_RESPONSE=$(curl -s -X POST "${KC_BASE_URL}/auth/realms/denodo-idp/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${USER_EMAIL}" \
        -d "password=${PASSWORD}" \
        -d "grant_type=password" \
        -d "client_id=denodo-consumer" \
        -d "client_secret=${CLIENT_SECRET}" 2>/dev/null)

    USER_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
    assert_not_empty "User $USER_EMAIL can authenticate" "$USER_TOKEN"
done

###############################################################################
# Results
###############################################################################

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo "═══════════════════════════════════════════════════════"

exit $FAIL
