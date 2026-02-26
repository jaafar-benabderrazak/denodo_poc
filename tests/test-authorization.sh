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

set -eE
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO.\033[0m"; echo -e "\033[0;31m  Command: $BASH_COMMAND\033[0m"; echo -e "\033[1;33m  Hint: Check that deployment-info.json exists, AWS credentials are valid, and the API Gateway + Lambda are deployed.\033[0m"' ERR

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
echo -e "${YELLOW}  Fetching API key from Secrets Manager (${PROJECT_NAME}/api/auth-key)...${NC}"
API_KEY_RAW=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --region "$REGION" \
    --query SecretString --output text 2>&1) || {
    echo -e "${RED}  Failed to retrieve API key from Secrets Manager.${NC}"
    echo -e "${RED}  Error: $API_KEY_RAW${NC}"
    echo -e "${YELLOW}  Check: aws secretsmanager list-secrets --region $REGION --query 'SecretList[?contains(Name,\`auth-key\`)].Name'${NC}"
    exit 1
}
API_KEY=$(echo "$API_KEY_RAW" | jq -r '.apiKey')
if [ -z "$API_KEY" ] || [ "$API_KEY" == "null" ]; then
    echo -e "${RED}  API key is empty or null. Raw secret value:${NC}"
    echo -e "  $API_KEY_RAW" | head -c 200
    echo ""
    exit 1
fi
echo -e "${GREEN}  API key retrieved (${#API_KEY} chars)${NC}"

PERMISSIONS_URL="${API_ENDPOINT}/api/v1/users"

# Pre-flight: verify API Gateway endpoint is reachable
API_HOST=$(echo "$API_ENDPOINT" | sed 's|https\?://||' | cut -d/ -f1)
if ! host "$API_HOST" >/dev/null 2>&1 && ! nslookup "$API_HOST" >/dev/null 2>&1; then
    echo -e "${RED}  DNS resolution failed for: $API_HOST${NC}"
    echo -e "${RED}  The API Gateway endpoint no longer exists.${NC}"
    echo -e "${YELLOW}  Fix: Redeploy the API Gateway:${NC}"
    echo -e "${YELLOW}    ./scripts/deploy-lambda-api.sh${NC}"
    echo -e "${YELLOW}  Then re-run this test.${NC}"
    exit 1
fi

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
    CURL_ERR=$(mktemp)
    HTTP_STATUS=$(curl -sS -o /tmp/auth_response.json -w "%{http_code}" \
        -H "X-API-Key: ${API_KEY}" \
        "${PERMISSIONS_URL}/${USER_EMAIL}/permissions" 2>"$CURL_ERR") || true

    if [ -s "$CURL_ERR" ]; then
        echo -e "  ${YELLOW}  curl stderr: $(cat "$CURL_ERR")${NC}"
    fi
    rm -f "$CURL_ERR"

    assert "GET /${USER_EMAIL}/permissions returns 200" "200" "$HTTP_STATUS"

    if [ "$HTTP_STATUS" != "200" ]; then
        echo -e "  ${YELLOW}    Response body:${NC}"
        cat /tmp/auth_response.json 2>/dev/null | jq . 2>/dev/null || cat /tmp/auth_response.json 2>/dev/null | head -c 500
        echo ""
    fi

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
            echo -e "  ${YELLOW}    Full response: $(echo "$RESPONSE" | jq -c . 2>/dev/null || echo "$RESPONSE" | head -c 300)${NC}"
            FAIL=$((FAIL + 1))
        fi

        HAS_DATASOURCES=$(echo "$RESPONSE" | jq -r '.datasources // empty')
        TOTAL=$((TOTAL + 1))
        if [ ! -z "$HAS_DATASOURCES" ] && [ "$HAS_DATASOURCES" != "null" ]; then
            echo -e "  ${GREEN}✓ PASS${NC} Response contains datasources for $USER_EMAIL"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} Response missing datasources for $USER_EMAIL"
            echo -e "  ${YELLOW}    Full response: $(echo "$RESPONSE" | jq -c . 2>/dev/null || echo "$RESPONSE" | head -c 300)${NC}"
            FAIL=$((FAIL + 1))
        fi
    fi
done

###############################################################################
# Test 2: Missing API Key
###############################################################################

echo ""
echo "▶ Security: Missing API Key"

CURL_ERR_NOKEY=$(mktemp)
HTTP_STATUS=$(curl -sS -o /tmp/auth_nokey.json -w "%{http_code}" \
    "${PERMISSIONS_URL}/analyst@denodo.com/permissions" 2>"$CURL_ERR_NOKEY") || true
[ -s "$CURL_ERR_NOKEY" ] && echo -e "  ${YELLOW}  curl error: $(cat "$CURL_ERR_NOKEY")${NC}"
rm -f "$CURL_ERR_NOKEY"

assert "Request without API key returns 403" "403" "$HTTP_STATUS"
if [ "$HTTP_STATUS" != "403" ]; then
    echo -e "  ${YELLOW}    Got HTTP $HTTP_STATUS — Response: $(cat /tmp/auth_nokey.json 2>/dev/null | head -c 300)${NC}"
fi
rm -f /tmp/auth_nokey.json

###############################################################################
# Test 3: Invalid API Key
###############################################################################

echo ""
echo "▶ Security: Invalid API Key"

CURL_ERR_BADKEY=$(mktemp)
HTTP_STATUS=$(curl -sS -o /tmp/auth_badkey.json -w "%{http_code}" \
    -H "X-API-Key: invalid-key-12345" \
    "${PERMISSIONS_URL}/analyst@denodo.com/permissions" 2>"$CURL_ERR_BADKEY") || true
[ -s "$CURL_ERR_BADKEY" ] && echo -e "  ${YELLOW}  curl error: $(cat "$CURL_ERR_BADKEY")${NC}"
rm -f "$CURL_ERR_BADKEY"

assert "Request with invalid API key returns 403" "403" "$HTTP_STATUS"
if [ "$HTTP_STATUS" != "403" ]; then
    echo -e "  ${YELLOW}    Got HTTP $HTTP_STATUS — Response: $(cat /tmp/auth_badkey.json 2>/dev/null | head -c 300)${NC}"
fi
rm -f /tmp/auth_badkey.json

###############################################################################
# Test 4: Unknown User
###############################################################################

echo ""
echo "▶ Unknown User Handling"

CURL_ERR_UNKNOWN=$(mktemp)
HTTP_STATUS=$(curl -sS -o /tmp/auth_unknown.json -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" \
    "${PERMISSIONS_URL}/unknown@denodo.com/permissions" 2>"$CURL_ERR_UNKNOWN") || true
[ -s "$CURL_ERR_UNKNOWN" ] && echo -e "  ${YELLOW}  curl error: $(cat "$CURL_ERR_UNKNOWN")${NC}"
rm -f "$CURL_ERR_UNKNOWN"

assert "Unknown user returns 200 with guest profile" "200" "$HTTP_STATUS"
if [ "$HTTP_STATUS" != "200" ]; then
    echo -e "  ${YELLOW}    Got HTTP $HTTP_STATUS — Response: $(cat /tmp/auth_unknown.json 2>/dev/null | head -c 300)${NC}"
fi

###############################################################################
# Test 5: Analyst Permissions Validation
###############################################################################

echo ""
echo "▶ Analyst Permission Scope"

HTTP_STATUS=$(curl -sS -o /tmp/auth_analyst.json -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" \
    "${PERMISSIONS_URL}/analyst@denodo.com/permissions" 2>/dev/null) || true

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
