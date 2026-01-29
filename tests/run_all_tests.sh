#!/usr/bin/env bash
# Run all tests for Keycloak Migration v3.0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  Keycloak Migration v3.0 — Test Suite                ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_suite() {
    local test_file="$1"
    local name=$(basename "$test_file" .sh)
    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    echo ""
    echo -e "${BOLD}▶ Running: $name${NC}"

    if bash "$test_file"; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        echo -e "${RED}Suite $name FAILED${NC}"
    fi
}

# Run all test files
for test_file in "$SCRIPT_DIR"/test_*.sh; do
    [[ "$(basename "$test_file")" == "test_framework.sh" ]] && continue
    run_suite "$test_file"
done

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  SUITES: $TOTAL_SUITES | ${GREEN}PASSED: $PASSED_SUITES${NC}${BOLD} | ${RED}FAILED: $FAILED_SUITES${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

exit $FAILED_SUITES
