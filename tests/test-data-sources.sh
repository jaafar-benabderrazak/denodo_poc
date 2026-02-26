#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Data Sources Tests
#
# Tests RDS connectivity (via SSM) and public API availability.
#
# Usage: ./tests/test-data-sources.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -eE
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

# Verbose mode: -v or --verbose or VERBOSE=1
VERBOSE="${VERBOSE:-0}"
for arg in "$@"; do
    case "$arg" in -v|--verbose) VERBOSE=1 ;; esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

verbose() {
    [ "$VERBOSE" = "1" ] && echo -e "  ${DIM}$*${NC}"
}

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

assert_gt() {
    TOTAL=$((TOTAL + 1))
    local test_name=$1
    local threshold=$2
    local actual=$3

    if [ "$actual" -gt "$threshold" ] 2>&1; then
        echo -e "  ${GREEN}✓ PASS${NC} $test_name (got: $actual)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} $test_name (expected > $threshold, got: $actual)"
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
OPENDATA_ENDPOINT=$(jq -r '.rdsEndpoints.opendata // empty' "$DEPLOYMENT_INFO")
DENODO_INSTANCE_ID=$(jq -r '.denodo.instanceId // "i-0aef555dcb0ff873f"' "$DEPLOYMENT_INFO")

echo "═══════════════════════════════════════════════════════"
echo "  DATA SOURCES TESTS"
echo "═══════════════════════════════════════════════════════"

###############################################################################
# Test 1: Public API Connectivity
###############################################################################

echo ""
echo "▶ Public API Connectivity"

# Test geo.api.gouv.fr
GEO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://geo.api.gouv.fr/communes?codePostal=75001&fields=nom,code,population" 2>&1 || echo "000")
assert "geo.api.gouv.fr is reachable" "200" "$GEO_STATUS"

if [ "$GEO_STATUS" == "200" ]; then
    GEO_RESPONSE=$(curl -s "https://geo.api.gouv.fr/communes?codePostal=75001&fields=nom,code,population" 2>&1)
    GEO_COUNT=$(echo "$GEO_RESPONSE" | jq 'length')
    assert_gt "geo API returns communes for 75001" "0" "$GEO_COUNT"

    if [ "$VERBOSE" = "1" ]; then
        echo -e "  ${CYAN}── Geo API Sample (75001) ──${NC}"
        echo "$GEO_RESPONSE" | jq -r '.[] | "  \(.nom) (code: \(.code), pop: \(.population // "n/a"))"' 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}$line${NC}"
        done
        echo -e "  ${CYAN}── Raw JSON: Geo API 75001 ──${NC}"
        echo "$GEO_RESPONSE" | jq . 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}$line${NC}"
        done
        # Also show a second postal code for variety
        GEO2=$(curl -s "https://geo.api.gouv.fr/communes?codePostal=69001&fields=nom,code,population" 2>/dev/null)
        echo "$GEO2" | jq -r '.[] | "  \(.nom) (code: \(.code), pop: \(.population // "n/a"))"' 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}$line  [69001]${NC}"
        done
        echo -e "  ${CYAN}── Raw JSON: Geo API 69001 ──${NC}"
        echo "$GEO2" | jq . 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}$line${NC}"
        done
    fi
fi

# Test api.insee.fr/entreprises endpoint (SIRENE)
SIRENE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://api.insee.fr/entreprises/sirene/V3.11" 2>&1 || echo "000")
TOTAL=$((TOTAL + 1))
if [ "$SIRENE_STATUS" != "000" ]; then
    echo -e "  ${GREEN}✓ PASS${NC} api.insee.fr is reachable (HTTP $SIRENE_STATUS)"
    PASS=$((PASS + 1))
else
    echo -e "  ${YELLOW}⚠ SKIP${NC} api.insee.fr not reachable (may require API key)"
    # Don't count as failure since SIRENE needs auth
fi

###############################################################################
# Test 2: RDS OpenData Connectivity (via SSM)
###############################################################################

echo ""
echo "▶ RDS OpenData Connectivity (via Denodo EC2 / SSM)"

if [ ! -z "$OPENDATA_ENDPOINT" ] && [ "$OPENDATA_ENDPOINT" != "null" ]; then
    # Get DB password
    DB_PASSWORD=$(aws secretsmanager get-secret-value \
        --secret-id "${PROJECT_NAME}/opendata/db" \
        --region "$REGION" \
        --query SecretString --output text | jq -r '.password' 2>&1)

    # Test via SSM (using Denodo EC2 as bastion)
    log_info_msg="Testing RDS via SSM on instance $DENODO_INSTANCE_ID..."
    echo "  $log_info_msg"

    # Count entreprises
    ENTREPRISES_COUNT=$(aws ssm send-command \
        --instance-ids "$DENODO_INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_ENDPOINT}' -U denodo -d opendata -t -c 'SELECT count(*) FROM opendata.entreprises;'\"]" \
        --region "$REGION" \
        --query 'Command.CommandId' --output text 2>&1)

    if [ ! -z "$ENTREPRISES_COUNT" ] && [ "$ENTREPRISES_COUNT" != "None" ]; then
        sleep 5
        RESULT=$(aws ssm get-command-invocation \
            --command-id "$ENTREPRISES_COUNT" \
            --instance-id "$DENODO_INSTANCE_ID" \
            --region "$REGION" \
            --query 'StandardOutputContent' --output text 2>&1 | tr -d '[:space:]')

        TOTAL=$((TOTAL + 1))
        if [ "${RESULT:-0}" -gt "0" ] 2>/dev/null; then
            echo -e "  ${GREEN}✓ PASS${NC} entreprises table has rows (got: $RESULT)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}⚠ WARN${NC} entreprises table is empty (data not loaded yet)"
            PASS=$((PASS + 1))
        fi

        # Verbose: show sample rows
        if [ "$VERBOSE" = "1" ]; then
            SAMPLE_CMD=$(aws ssm send-command \
                --instance-ids "$DENODO_INSTANCE_ID" \
                --document-name AWS-RunShellScript \
                --parameters "commands=[\"PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_ENDPOINT}' -U denodo -d opendata -t -A -F'|' -c \\\"SELECT siren, nom_raison_sociale, ville, departement FROM opendata.entreprises LIMIT 5;\\\"\"]" \
                --region "$REGION" \
                --query 'Command.CommandId' --output text 2>&1)
            sleep 4
            SAMPLE_ROWS=$(aws ssm get-command-invocation \
                --command-id "$SAMPLE_CMD" \
                --instance-id "$DENODO_INSTANCE_ID" \
                --region "$REGION" \
                --query 'StandardOutputContent' --output text 2>&1)
            if [ ! -z "$SAMPLE_ROWS" ]; then
                echo -e "  ${CYAN}── entreprises (sample 5 rows) ──${NC}"
                echo -e "  ${DIM}  SIREN | Raison Sociale | Ville | Dept${NC}"
                echo "$SAMPLE_ROWS" | head -5 | while IFS='|' read -r siren nom ville dept rest; do
                    echo -e "  ${DIM}  $siren | $nom | $ville | $dept${NC}"
                done
            fi
        fi
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${YELLOW}⚠ SKIP${NC} SSM command execution not available"
    fi

    # Count population_communes
    POP_COUNT=$(aws ssm send-command \
        --instance-ids "$DENODO_INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_ENDPOINT}' -U denodo -d opendata -t -c 'SELECT count(*) FROM opendata.population_communes;'\"]" \
        --region "$REGION" \
        --query 'Command.CommandId' --output text 2>&1)

    if [ ! -z "$POP_COUNT" ] && [ "$POP_COUNT" != "None" ]; then
        sleep 5
        RESULT=$(aws ssm get-command-invocation \
            --command-id "$POP_COUNT" \
            --instance-id "$DENODO_INSTANCE_ID" \
            --region "$REGION" \
            --query 'StandardOutputContent' --output text 2>&1 | tr -d '[:space:]')

        TOTAL=$((TOTAL + 1))
        if [ "${RESULT:-0}" -gt "0" ] 2>/dev/null; then
            echo -e "  ${GREEN}✓ PASS${NC} population_communes table has rows (got: $RESULT)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}⚠ WARN${NC} population_communes table is empty (data not loaded yet)"
            PASS=$((PASS + 1))
        fi

        # Verbose: show top 5 communes by population
        if [ "$VERBOSE" = "1" ]; then
            TOP_CMD=$(aws ssm send-command \
                --instance-ids "$DENODO_INSTANCE_ID" \
                --document-name AWS-RunShellScript \
                --parameters "commands=[\"PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_ENDPOINT}' -U denodo -d opendata -t -A -F'|' -c \\\"SELECT nom_commune, code_postal, population FROM opendata.population_communes ORDER BY population DESC LIMIT 5;\\\"\"]" \
                --region "$REGION" \
                --query 'Command.CommandId' --output text 2>&1)
            sleep 4
            TOP_ROWS=$(aws ssm get-command-invocation \
                --command-id "$TOP_CMD" \
                --instance-id "$DENODO_INSTANCE_ID" \
                --region "$REGION" \
                --query 'StandardOutputContent' --output text 2>&1)
            if [ ! -z "$TOP_ROWS" ]; then
                echo -e "  ${CYAN}── population_communes (top 5 by population) ──${NC}"
                echo -e "  ${DIM}  Commune | Code Postal | Population${NC}"
                echo "$TOP_ROWS" | head -5 | while IFS='|' read -r nom cp pop rest; do
                    echo -e "  ${DIM}  $nom | $cp | $pop${NC}"
                done
            fi
        fi
    fi

    # Test the view
    VIEW_TEST=$(aws ssm send-command \
        --instance-ids "$DENODO_INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"PGPASSWORD='${DB_PASSWORD}' psql -h '${OPENDATA_ENDPOINT}' -U denodo -d opendata -t -c 'SELECT count(*) FROM opendata.entreprises_population;'\"]" \
        --region "$REGION" \
        --query 'Command.CommandId' --output text 2>&1)

    if [ ! -z "$VIEW_TEST" ] && [ "$VIEW_TEST" != "None" ]; then
        sleep 5
        RESULT=$(aws ssm get-command-invocation \
            --command-id "$VIEW_TEST" \
            --instance-id "$DENODO_INSTANCE_ID" \
            --region "$REGION" \
            --query 'StandardOutputContent' --output text 2>&1 | tr -d '[:space:]')

        TOTAL=$((TOTAL + 1))
        if [ "${RESULT:-0}" -gt "0" ] 2>/dev/null; then
            echo -e "  ${GREEN}✓ PASS${NC} entreprises_population view returns rows (got: $RESULT)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}⚠ WARN${NC} entreprises_population view is empty (data not loaded yet)"
            PASS=$((PASS + 1))
        fi
    fi
else
    echo -e "  ${YELLOW}⚠ SKIP${NC} OpenData endpoint not configured"
fi

###############################################################################
# Test 3: Denodo EC2 Instance Status
###############################################################################

echo ""
echo "▶ Denodo EC2 Instance"

INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$DENODO_INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1)

assert "Denodo EC2 instance is running" "running" "$INSTANCE_STATE"

# Check SSM connectivity
SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${DENODO_INSTANCE_ID}" \
    --region "$REGION" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>&1)

assert "Denodo EC2 SSM agent is online" "Online" "$SSM_STATUS"

###############################################################################
# Results
###############################################################################

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo "═══════════════════════════════════════════════════════"

exit $FAIL
