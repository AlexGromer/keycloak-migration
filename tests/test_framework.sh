#!/usr/bin/env bash
# Test Framework for Keycloak Migration v3.0
# Lightweight bash test framework (no external dependencies)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # auto: pre-existing finding, behavior-preserving
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# YAML helper — yq flavor-agnostic (mikefarah/Go-yq OR kislyuk/python-yq)
# ============================================================================
yq_get() {
    # yq_get '<jq-path>' <file>  -> raw value on stdout; non-zero if absent
    local path="$1" file="$2" out
    if out=$(yq eval "$path" "$file" 2>/dev/null) && [[ -n "$out" && "$out" != "null" ]]; then
        printf '%s' "$out"; return 0
    fi
    if out=$(yq -r "$path" "$file" 2>/dev/null) && [[ -n "$out" && "$out" != "null" ]]; then
        printf '%s' "$out"; return 0
    fi
    return 1
}

# ============================================================================
# Assertions
# ============================================================================

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} ${msg:-assert_equals}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} ${msg:-assert_equals}"
        echo -e "    Expected: ${GREEN}$expected${NC}"
        echo -e "    Actual:   ${RED}$actual${NC}"
    fi
    return 0
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-value is not empty}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -n "$value" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (value is empty)"
    fi
    return 0
}

assert_empty() {
    local value="$1"
    local msg="${2:-value is empty}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -z "$value" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (value: '$value')"
    fi
    return 0
}

assert_true() {
    local condition="$1"
    local msg="${2:-condition is true}"

    TESTS_RUN=$((TESTS_RUN + 1))

    local _rc=0
    # The condition is often a pipeline ending in `grep -q`, whose early exit SIGPIPEs the writer.
    # Under `set -o pipefail` that turns a satisfied condition into a failed assertion, dependent on
    # timing. The assertion cares about the LAST command's status, so evaluate without pipefail.
    local _had_pipefail=""; [[ -o pipefail ]] && _had_pipefail=1
    set +o pipefail
    eval "$condition" || _rc=$?
    [[ -n "$_had_pipefail" ]] && set -o pipefail

    if [[ $_rc -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg"
        return 0
    fi
}

assert_false() {
    local condition="$1"
    local msg="${2:-condition is false}"

    TESTS_RUN=$((TESTS_RUN + 1))

    local _rc=0
    # The condition is often a pipeline ending in `grep -q`, whose early exit SIGPIPEs the writer.
    # Under `set -o pipefail` that turns a satisfied condition into a failed assertion, dependent on
    # timing. The assertion cares about the LAST command's status, so evaluate without pipefail.
    local _had_pipefail=""; [[ -o pipefail ]] && _had_pipefail=1
    set +o pipefail
    eval "$condition" || _rc=$?
    [[ -n "$_had_pipefail" ]] && set -o pipefail

    if [[ $_rc -ne 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (was true)"
        return 0
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="${2:-file exists: $path}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -f "$path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (not found)"
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    # shellcheck disable=SC2016 # auto: pre-existing finding, behavior-preserving
    local msg="${3:-contains '$needle'}"

    TESTS_RUN=$((TESTS_RUN + 1))

    # NO PIPELINE HERE. `echo ... | grep -q` looks harmless and is not: grep -q exits at the FIRST
    # match, the writer then takes SIGPIPE, and under `set -o pipefail` (which every suite sets) the
    # pipeline reports failure for a needle that IS present. Reproduced 100/100 with a needle near the
    # start of a large haystack and 0/100 with one at the end — which is precisely the shape of the
    # rare, arbitrary-looking suite failures this framework produced under load.
    # A here-string has no writer to kill. `--` keeps a needle that starts with '-' from being read
    # as grep's own options.
    if grep -q -- "$needle" <<<"$haystack"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg"
    fi
    return 0
}

assert_exit_code() {
    local expected="$1"
    shift
    local msg="${*: -1}"
    set -- "${@:1:$(($#-1))}"

    TESTS_RUN=$((TESTS_RUN + 1))

    set +e
    # shellcheck disable=SC2294 # auto: pre-existing finding, behavior-preserving
    eval "$@" >/dev/null 2>&1
    local actual=$?
    set -e

    if [[ "$expected" -eq "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (exit=$actual, expected=$expected)"
        return 1
    fi
}

skip_test() {
    local msg="${1:-skipped}"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    echo -e "  ${YELLOW}⊘${NC} SKIP: $msg"
}

# ============================================================================
# Test Suite Management
# ============================================================================

describe() {
    local suite_name="$1"
    echo ""
    echo -e "${CYAN}${BOLD}━━━ $suite_name ━━━${NC}"
}

# ============================================================================
# Report
# ============================================================================

test_report() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}TEST RESULTS${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Total:   $TESTS_RUN"
    echo -e "  ${GREEN}Passed:  $TESTS_PASSED${NC}"
    echo -e "  ${RED}Failed:  $TESTS_FAILED${NC}"
    echo -e "  ${YELLOW}Skipped: $TESTS_SKIPPED${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    else
        echo -e "${RED}${BOLD}$TESTS_FAILED TEST(S) FAILED${NC}"
    fi
    echo ""

    # Return non-zero if any tests failed (but don't exceed 125)
    [[ $TESTS_FAILED -gt 0 ]] && return 1 || return 0
}
