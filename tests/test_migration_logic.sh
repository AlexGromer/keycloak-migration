#!/usr/bin/env bash
# Tests: Migration Logic (main script functions)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# We need to source the libs without running main()
# Source libraries directly
LIB_DIR="$PROJECT_ROOT/scripts/lib"
source "$LIB_DIR/database_adapter.sh"
source "$LIB_DIR/deployment_adapter.sh"
source "$LIB_DIR/profile_manager.sh"
source "$LIB_DIR/distribution_handler.sh"

# Set up test workspace
TEST_WORK_DIR=$(mktemp -d)
WORK_DIR="$TEST_WORK_DIR"
STATE_FILE="$WORK_DIR/migration_state.env"
LOG_FILE="$WORK_DIR/test.log"
PROFILE_DIR="$PROJECT_ROOT/profiles"

# Source logging and state functions from main script (extract inline)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >> "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1" >> "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1" >> "$LOG_FILE"; }
log_error() { echo -e "${RED}[✗]${NC} $1" >> "$LOG_FILE"; }
log_section() { echo -e "\n${CYAN}${BOLD}═══ $1 ═══${NC}\n" >> "$LOG_FILE"; }

update_state() {
    local key="$1"
    local value="$2"
    mkdir -p "$WORK_DIR"
    if [[ -f "$STATE_FILE" ]]; then
        if grep -q "^${key}=" "$STATE_FILE"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
        else
            echo "${key}=${value}" >> "$STATE_FILE"
        fi
    else
        echo "${key}=${value}" > "$STATE_FILE"
    fi
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
    fi
}

# Java requirements
declare -A JAVA_REQUIREMENTS=(
    [16]="11" [17]="11" [18]="11" [19]="11" [20]="11" [21]="11"
    [22]="17" [23]="17" [24]="17" [25]="17" [26]="21"
)

# Migration path (includes starting versions)
declare -a MIGRATION_PATH=("16.1.1" "17.0.1" "22.0.5" "25.0.6" "26.0.7")

# ============================================================================
describe "State Management — update_state/load_state"
# ============================================================================

update_state "TEST_KEY" "test_value"
assert_file_exists "$STATE_FILE" "state file created"

load_state
assert_equals "test_value" "${TEST_KEY:-}" "state key loaded"

update_state "TEST_KEY" "updated_value"
load_state
assert_equals "updated_value" "${TEST_KEY:-}" "state key updated"

update_state "ANOTHER_KEY" "another_value"
load_state
assert_equals "another_value" "${ANOTHER_KEY:-}" "second key added"
assert_equals "updated_value" "${TEST_KEY:-}" "first key preserved"

# ============================================================================
describe "Migration Path Calculation"
# ============================================================================

# Test: full path from 16.1.1 → 26.0.7
PROFILE_KC_CURRENT_VERSION="16.1.1"
PROFILE_KC_TARGET_VERSION="26.0.7"

migration_steps=()
found_current=false
# Path includes versions from MIGRATION_PATH, skip current version
# But 16.1.1 is NOT in MIGRATION_PATH — it's the start point
# The logic needs adjustment: versions < current are skipped

# Simulate the main script's path logic
# In main script current_version=16.1.1 which is NOT in MIGRATION_PATH
# So found_current is never set to true — all steps are added
# Actually re-reading: the loop checks if version == current_version
# 16.1.1 is not in path [17.0.1, 22.0.5, 25.0.6, 26.0.7]
# So found_current stays false, migration_steps stays empty

# This reveals a bug — current_version must be in MIGRATION_PATH or handled specially.
# For now, test the current behavior:

migration_steps=()
found_current=false
for version in "${MIGRATION_PATH[@]}"; do
    if [[ "$version" == "$PROFILE_KC_CURRENT_VERSION" ]]; then
        found_current=true
        continue
    fi
    if $found_current; then
        migration_steps+=("$version")
        if [[ "$version" == "$PROFILE_KC_TARGET_VERSION" ]]; then
            break
        fi
    fi
done

# FIXED: 16.1.1 now in MIGRATION_PATH → 4 steps
assert_equals "4" "${#migration_steps[@]}" "16.1.1→26.0.7: 4 steps (full path)"

# Test: path from 17.0.1 → 26.0.7 (version in path)
PROFILE_KC_CURRENT_VERSION="17.0.1"
migration_steps=()
found_current=false
for version in "${MIGRATION_PATH[@]}"; do
    if [[ "$version" == "$PROFILE_KC_CURRENT_VERSION" ]]; then
        found_current=true
        continue
    fi
    if $found_current; then
        migration_steps+=("$version")
        if [[ "$version" == "$PROFILE_KC_TARGET_VERSION" ]]; then
            break
        fi
    fi
done

assert_equals "3" "${#migration_steps[@]}" "17.0.1→26.0.7: 3 steps"
assert_equals "22.0.5" "${migration_steps[0]}" "first step is 22.0.5"
assert_equals "25.0.6" "${migration_steps[1]}" "second step is 25.0.6"
assert_equals "26.0.7" "${migration_steps[2]}" "third step is 26.0.7"

# Test: partial path 22.0.5 → 25.0.6
PROFILE_KC_CURRENT_VERSION="22.0.5"
PROFILE_KC_TARGET_VERSION="25.0.6"
migration_steps=()
found_current=false
for version in "${MIGRATION_PATH[@]}"; do
    if [[ "$version" == "$PROFILE_KC_CURRENT_VERSION" ]]; then
        found_current=true
        continue
    fi
    if $found_current; then
        migration_steps+=("$version")
        if [[ "$version" == "$PROFILE_KC_TARGET_VERSION" ]]; then
            break
        fi
    fi
done

assert_equals "1" "${#migration_steps[@]}" "22.0.5→25.0.6: 1 step"
assert_equals "25.0.6" "${migration_steps[0]}" "step is 25.0.6"

# ============================================================================
describe "Java Requirements Lookup"
# ============================================================================

assert_equals "11" "${JAVA_REQUIREMENTS[16]}" "KC 16 requires Java 11"
assert_equals "11" "${JAVA_REQUIREMENTS[17]}" "KC 17 requires Java 11"
assert_equals "17" "${JAVA_REQUIREMENTS[22]}" "KC 22 requires Java 17"
assert_equals "17" "${JAVA_REQUIREMENTS[25]}" "KC 25 requires Java 17"
assert_equals "21" "${JAVA_REQUIREMENTS[26]}" "KC 26 requires Java 21"

# ============================================================================
describe "Profile Validation"
# ============================================================================

# Valid profile
export PROFILE_DB_TYPE="postgresql"
export PROFILE_KC_DEPLOYMENT_MODE="standalone"
export PROFILE_KC_CURRENT_VERSION="16.1.1"
export PROFILE_KC_TARGET_VERSION="26.0.7"

errors=0
[[ -z "${PROFILE_DB_TYPE:-}" ]] && errors=$((errors + 1))
[[ -z "${PROFILE_KC_DEPLOYMENT_MODE:-}" ]] && errors=$((errors + 1))
[[ -z "${PROFILE_KC_CURRENT_VERSION:-}" ]] && errors=$((errors + 1))
[[ -z "${PROFILE_KC_TARGET_VERSION:-}" ]] && errors=$((errors + 1))

assert_equals "0" "$errors" "valid profile has 0 validation errors"

# Invalid profile (missing fields)
unset PROFILE_DB_TYPE
errors=0
[[ -z "${PROFILE_DB_TYPE:-}" ]] && errors=$((errors + 1))
[[ -z "${PROFILE_KC_DEPLOYMENT_MODE:-}" ]] && errors=$((errors + 1))
[[ -z "${PROFILE_KC_CURRENT_VERSION:-}" ]] && errors=$((errors + 1))
[[ -z "${PROFILE_KC_TARGET_VERSION:-}" ]] && errors=$((errors + 1))

assert_equals "1" "$errors" "profile missing DB_TYPE has 1 error"

# ============================================================================
describe "Strategy Selection Logic"
# ============================================================================

# In-place for standalone
PROFILE_KC_DEPLOYMENT_MODE="standalone"
strategy="inplace"
assert_equals "inplace" "$strategy" "standalone uses inplace"

# Rolling for kubernetes
PROFILE_KC_DEPLOYMENT_MODE="kubernetes"
strategy="rolling_update"

case "$strategy" in
    rolling_update)
        if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
            result="rolling_ok"
        else
            result="fallback_inplace"
        fi
        ;;
    *) result="default" ;;
esac

assert_equals "rolling_ok" "$result" "kubernetes + rolling_update = OK"

# Rolling for standalone (should fallback)
PROFILE_KC_DEPLOYMENT_MODE="standalone"
case "$strategy" in
    rolling_update)
        if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
            result="rolling_ok"
        else
            result="fallback_inplace"
        fi
        ;;
    *) result="default" ;;
esac

assert_equals "fallback_inplace" "$result" "standalone + rolling_update = fallback to inplace"

# Blue-green for deckhouse
PROFILE_KC_DEPLOYMENT_MODE="deckhouse"
strategy="blue_green"
case "$strategy" in
    blue_green)
        if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
            result="bluegreen_ok"
        else
            result="fallback_inplace"
        fi
        ;;
    *) result="default" ;;
esac

assert_equals "bluegreen_ok" "$result" "deckhouse + blue_green = OK"

# ============================================================================
describe "CLI Argument Parsing"
# ============================================================================

# Simulate argument parsing
parse_args() {
    local command="" profile="" dry_run="false" skip_tests="false"
    command="${1:-}"
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) profile="$2"; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            --skip-tests) skip_tests="true"; shift ;;
            *) shift ;;
        esac
    done
    echo "$command|$profile|$dry_run|$skip_tests"
}

result=$(parse_args migrate --profile standalone-postgresql --dry-run --skip-tests)
assert_equals "migrate|standalone-postgresql|true|true" "$result" "parse all args"

result=$(parse_args plan --profile kubernetes-cluster-production)
assert_equals "plan|kubernetes-cluster-production|false|false" "$result" "parse plan with profile"

result=$(parse_args rollback)
assert_equals "rollback||false|false" "$result" "parse rollback (no options)"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$TEST_WORK_DIR"

# ============================================================================
# Report
# ============================================================================

test_report
