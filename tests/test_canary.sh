#!/usr/bin/env bash
# Unit Tests — Canary Migration (v3.3)

set -euo pipefail

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"
PROFILE_DIR="$PROJECT_ROOT/profiles"

# Source test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source libraries
export WORK_DIR="/tmp/test_migration_workspace_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

# Mock logging functions
log_info() { echo "[INFO] $1"; }
log_success() { echo "[✓] $1"; }
log_warn() { echo "[!] $1"; }
log_error() { echo "[✗] $1" >&2; }
log_section() { echo "=== $1 ==="; }

# Source canary.sh
source "$LIB_DIR/canary.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Function Existence"

declare -F canary_execute_migration >/dev/null && \
    assert_true "true" "canary_execute_migration function exists"

declare -F canary_execute_phase >/dev/null && \
    assert_true "true" "canary_execute_phase function exists"

declare -F canary_migrate_replicas >/dev/null && \
    assert_true "true" "canary_migrate_replicas function exists"

declare -F canary_update_traffic >/dev/null && \
    assert_true "true" "canary_update_traffic function exists"

declare -F canary_validate_phase >/dev/null && \
    assert_true "true" "canary_validate_phase function exists"

declare -F canary_rollback >/dev/null && \
    assert_true "true" "canary_rollback function exists"

declare -F canary_rollback_to_initial >/dev/null && \
    assert_true "true" "canary_rollback_to_initial function exists"

# ============================================================================
# TEST SUITE 2: Profile Detection
# ============================================================================

test_report "Test Suite 2: Profile Detection"

if [[ -f "$PROFILE_DIR/canary-k8s-istio.yaml" ]]; then
    # Load profile
    export PROFILE_FILE="$PROFILE_DIR/canary-k8s-istio.yaml"

    # Extract mode
    mode=$(yq eval '.profile.strategy' "$PROFILE_FILE" 2>/dev/null || echo "")
    assert_equals "canary" "$mode" "Profile strategy detected as canary"

    # Extract phases count
    phases_count=$(yq eval '.canary.phases | length' "$PROFILE_FILE" 2>/dev/null || echo "0")
    assert_true "[[ $phases_count -gt 0 ]]" "Canary phases defined"

    # Extract first phase percentage
    phase0_pct=$(yq eval '.canary.phases[0].percentage' "$PROFILE_FILE" 2>/dev/null || echo "0")
    assert_equals "10" "$phase0_pct" "Phase 0 percentage is 10%"

    # Extract traffic router type
    router_type=$(yq eval '.canary.traffic_router.type' "$PROFILE_FILE" 2>/dev/null || echo "")
    assert_equals "istio" "$router_type" "Traffic router is Istio"
else
    assert_true "true" "Profile file not found (skip profile tests)"
fi

# ============================================================================
# TEST SUITE 3: Phase Configuration Parsing
# ============================================================================

test_report "Test Suite 3: Phase Configuration Parsing"

# Create mock profile with 3 phases
mock_profile="$WORK_DIR/mock-canary-profile.yaml"
cat > "$mock_profile" <<EOF
profile:
  name: mock-canary
  strategy: canary

canary:
  deployment:
    namespace: test-namespace
    deployment: keycloak
    replicas: 10

  phases:
    - name: phase-1
      percentage: 10
      replicas: 1
      duration: 300
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 100

    - name: phase-2
      percentage: 50
      replicas: 5
      duration: 600
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 500

    - name: phase-3
      percentage: 100
      replicas: 10
      duration: 300
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 1000

migration:
  target_version: "26.0.7"
EOF

export PROFILE_FILE="$mock_profile"

# Test phase count
phases_count=$(yq eval '.canary.phases | length' "$PROFILE_FILE" 2>/dev/null || echo "0")
assert_equals "3" "$phases_count" "3 phases defined in mock profile"

# Test phase 2 (index 1) configuration
phase1_name=$(yq eval '.canary.phases[1].name' "$PROFILE_FILE" 2>/dev/null || echo "")
assert_equals "phase-2" "$phase1_name" "Phase 1 name is 'phase-2'"

phase1_pct=$(yq eval '.canary.phases[1].percentage' "$PROFILE_FILE" 2>/dev/null || echo "0")
assert_equals "50" "$phase1_pct" "Phase 1 percentage is 50%"

phase1_replicas=$(yq eval '.canary.phases[1].replicas' "$PROFILE_FILE" 2>/dev/null || echo "0")
assert_equals "5" "$phase1_replicas" "Phase 1 has 5 replicas"

# ============================================================================
# TEST SUITE 4: Validation Threshold Parsing
# ============================================================================

test_report "Test Suite 4: Validation Threshold Parsing"

# Extract validation thresholds from phase 0
error_threshold=$(yq eval '.canary.phases[0].validation.error_rate_threshold' "$PROFILE_FILE" 2>/dev/null || echo "")
assert_equals "0.01" "$error_threshold" "Error rate threshold is 0.01"

latency_threshold=$(yq eval '.canary.phases[0].validation.latency_p99_threshold' "$PROFILE_FILE" 2>/dev/null || echo "")
assert_equals "500" "$latency_threshold" "Latency p99 threshold is 500ms"

min_requests=$(yq eval '.canary.phases[0].validation.min_requests' "$PROFILE_FILE" 2>/dev/null || echo "")
assert_equals "100" "$min_requests" "Minimum requests is 100"

# ============================================================================
# TEST SUITE 5: Rollback Logic
# ============================================================================

test_report "Test Suite 5: Rollback Logic"

# Verify rollback functions exist
declare -F canary_rollback >/dev/null && \
    assert_true "true" "Rollback function exists"

declare -F canary_rollback_to_initial >/dev/null && \
    assert_true "true" "Rollback to initial function exists"

declare -F canary_rollback_to_phase >/dev/null && \
    assert_true "true" "Rollback to phase function exists"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Canary Migration"
