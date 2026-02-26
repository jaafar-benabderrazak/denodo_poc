#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Full Test Suite
#
# Orchestrator that runs all test scripts and reports overall results.
#
# Usage: ./tests/test-all.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

TOTAL_PASS=0
TOTAL_FAIL=0
SUITES_PASS=0
SUITES_FAIL=0

echo ""
echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║     DENODO KEYCLOAK POC - FULL TEST SUITE                 ║${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

SUITE_LOG_DIR="/tmp/denodo-test-logs"
mkdir -p "$SUITE_LOG_DIR"

run_test_suite() {
    local suite_name=$1
    local suite_script=$2
    local log_file="$SUITE_LOG_DIR/$(basename "$suite_script" .sh).log"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Running: $suite_name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ ! -f "$suite_script" ]; then
        echo -e "  ${YELLOW}⚠ SKIP${NC} Script not found: $suite_script"
        return
    fi

    chmod +x "$suite_script"
    set +e
    bash "$suite_script" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}
    set -e

    local duration_note=""
    if [ $exit_code -eq 0 ]; then
        echo -e "\n  ${GREEN}▶ Suite PASSED${NC}"
        SUITES_PASS=$((SUITES_PASS + 1))
    else
        echo -e "\n  ${RED}▶ Suite FAILED ($exit_code test(s) failed)${NC}"
        echo -e "  ${YELLOW}  Full log saved: $log_file${NC}"
        # Show last error context from log
        local fail_lines=$(grep -n "FAIL\|FATAL\|Error\|error" "$log_file" 2>/dev/null | tail -5)
        if [ -n "$fail_lines" ]; then
            echo -e "  ${YELLOW}  Error summary:${NC}"
            echo "$fail_lines" | while read -r line; do
                echo -e "    ${RED}$line${NC}"
            done
        fi
        SUITES_FAIL=$((SUITES_FAIL + 1))
        TOTAL_FAIL=$((TOTAL_FAIL + exit_code))
    fi
}

###############################################################################
# Run test suites
###############################################################################

run_test_suite "Authentication Tests" "$SCRIPT_DIR/test-authentication.sh"
run_test_suite "Authorization API Tests" "$SCRIPT_DIR/test-authorization.sh"
run_test_suite "Data Sources Tests" "$SCRIPT_DIR/test-data-sources.sh"

###############################################################################
# Overall Results
###############################################################################

TOTAL_SUITES=$((SUITES_PASS + SUITES_FAIL))

echo ""
echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║     OVERALL TEST RESULTS                                  ║${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Test Suites: $TOTAL_SUITES total"
echo -e "    ${GREEN}✓ $SUITES_PASS passed${NC}"
if [ $SUITES_FAIL -gt 0 ]; then
    echo -e "    ${RED}✗ $SUITES_FAIL failed${NC}"
fi
echo ""

if [ $SUITES_FAIL -eq 0 ]; then
    echo -e "  ${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  ✓ ALL TEST SUITES PASSED            ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  The Denodo Keycloak POC is fully operational."
    echo ""
    echo "  Keycloak Admin:        http://<ALB_DNS>/auth/admin"
    echo "  Authorization API:     <API_ENDPOINT>/api/v1/users/{userId}/permissions"
    echo "  Denodo VDP (EC2):      10.0.75.195:9999"
    echo ""
else
    echo -e "  ${RED}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  ✗ SOME TEST SUITES FAILED           ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  Review the failed tests above and check:"
    echo "    • ECS service logs:   aws logs tail /ecs/keycloak-provider --region eu-west-3"
    echo "    • Lambda logs:        aws logs tail /aws/lambda/denodo-permissions-api --region eu-west-3"
    echo "    • RDS connectivity:   Check security groups and subnets"
    echo ""
    echo -e "  ${YELLOW}Saved test logs:${NC}"
    for logfile in "$SUITE_LOG_DIR"/*.log; do
        [ -f "$logfile" ] && echo "    • $logfile"
    done
    echo ""
    echo "  Re-run a single failing suite for detailed output:"
    echo "    bash tests/test-authorization.sh"
    echo ""
fi

exit $SUITES_FAIL
