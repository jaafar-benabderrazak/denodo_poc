#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Authorization API Tests
#
# Tests the Lambda permissions API via API Gateway.
#
# Usage: ./tests/test-authorization.sh
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

assert_contains() {
    TOTAL=$((TOTAL + 1))
    local test_name=$1
    local expected=$2
    local actual=$3

    if echo "$actual" | grep -q "$expected"; then
        echo -e "  ${GREEN}✓ PASS${NC} $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} $test_name (output does not contain: $expected)"
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
API_ENDPOINT=$(jq -r '.apiGateway.endpoint // empty' "$DEPLOYMENT_INFO")

if [ -z "$API_ENDPOINT" ]; then
    echo -e "${RED}API endpoint not found in deployment-info.json. Run deploy-lambda-api.sh first.${NC}"
    exit 1
fi

# Get API key
API_KEY=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --region "$REGION" \
    --query SecretString --output text | jq -r '.apiKey')

PERMISSIONS_URL="${API_ENDPOINT}/api/v1/users"

echo "═══════════════════════════════════════════════════════"
echo "  AUTHORIZATION API TESTS"
echo "  Target: $PERMISSIONS_URL"
echo "═══════════════════════════════════════════════════════"

###############################################################################
# Test 1: Valid Requests
###############################################################################

echo ""
echo "▶ Valid API Requests"

for USER_EMAIL in analyst@denodo.com scientist@denodo.com admin@denodo.com; do
    HTTP_STATUS=$(curl -s -o /tmp/auth_response.json -w "%{http_code}" \
        -H "X-API-Key: ${API_KEY}" \
        "${PERMISSIONS_URL}/${USER_EMAIL}/permissions" 2>&1)

    assert "GET /${USER_EMAIL}/permissions returns 200" "200" "$HTTP_STATUS"

    if [ "$HTTP_STATUS" == "200" ]; then
        # Validate response structure
        RESPONSE=$(cat /tmp/auth_response.json)
        HAS_USER=$(echo "$RESPONSE" | jq -r '.userId // empty')
        assert "Response contains userId for $USER_EMAIL" "$USER_EMAIL" "$HAS_USER"

        HAS_PROFILES=$(echo "$RESPONSE" | jq -r '.profiles // empty')
        TOTAL=$((TOTAL + 1))
        if [ ! -z "$HAS_PROFILES" ] && [ "$HAS_PROFILES" != "null" ]; then
            echo -e "  ${GREEN}✓ PASS${NC} Response contains profiles for $USER_EMAIL"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} Response missing profiles for $USER_EMAIL"
            FAIL=$((FAIL + 1))
        fi

        HAS_DATASOURCES=$(echo "$RESPONSE" | jq -r '.datasourcePermissions // empty')
        TOTAL=$((TOTAL + 1))
        if [ ! -z "$HAS_DATASOURCES" ] && [ "$HAS_DATASOURCES" != "null" ]; then
            echo -e "  ${GREEN}✓ PASS${NC} Response contains datasourcePermissions for $USER_EMAIL"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} Response missing datasourcePermissions for $USER_EMAIL"
            FAIL=$((FAIL + 1))
        fi
    fi
done

###############################################################################
# Test 2: Missing API Key
###############################################################################

echo ""
echo "▶ Security: Missing API Key"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "${PERMISSIONS_URL}/analyst@denodo.com/permissions" 2>&1)

assert "Request without API key returns 403" "403" "$HTTP_STATUS"

###############################################################################
# Test 3: Invalid API Key
###############################################################################

echo ""
echo "▶ Security: Invalid API Key"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: invalid-key-12345" \
    "${PERMISSIONS_URL}/analyst@denodo.com/permissions" 2>&1)

assert "Request with invalid API key returns 403" "403" "$HTTP_STATUS"

###############################################################################
# Test 4: Unknown User
###############################################################################

echo ""
echo "▶ Unknown User Handling"

HTTP_STATUS=$(curl -s -o /tmp/auth_unknown.json -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" \
    "${PERMISSIONS_URL}/unknown@denodo.com/permissions" 2>&1)

assert "Unknown user returns 404" "404" "$HTTP_STATUS"

###############################################################################
# Test 5: Analyst Permissions Validation
###############################################################################

echo ""
echo "▶ Analyst Permission Scope"

HTTP_STATUS=$(curl -s -o /tmp/auth_analyst.json -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" \
    "${PERMISSIONS_URL}/analyst@denodo.com/permissions" 2>&1)

if [ "$HTTP_STATUS" == "200" ]; then
    ANALYST_RESPONSE=$(cat /tmp/auth_analyst.json)
    assert_contains "Analyst has data-analyst profile" "data-analyst" "$ANALYST_RESPONSE"
    assert_contains "Analyst has rds-opendata access" "rds-opendata" "$ANALYST_RESPONSE"
fi

###############################################################################
# Results
###############################################################################

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo "═══════════════════════════════════════════════════════"

rm -f /tmp/auth_response.json /tmp/auth_unknown.json /tmp/auth_analyst.json

exit $FAIL
