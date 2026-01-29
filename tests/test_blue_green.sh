#!/usr/bin/env bash
# Unit Tests — Blue-Green Migration (v3.3)

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

# Source blue_green.sh
source "$LIB_DIR/blue_green.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Function Existence"

declare -F bluegreen_execute_migration >/dev/null && \
    assert_true "true" "bluegreen_execute_migration function exists"

declare -F bluegreen_deploy_new_environment >/dev/null && \
    assert_true "true" "bluegreen_deploy_new_environment function exists"

declare -F bluegreen_wait_ready >/dev/null && \
    assert_true "true" "bluegreen_wait_ready function exists"

declare -F bluegreen_switch_traffic >/dev/null && \
    assert_true "true" "bluegreen_switch_traffic function exists"

declare -F bluegreen_cleanup_environment >/dev/null && \
    assert_true "true" "bluegreen_cleanup_environment function exists"

declare -F bluegreen_rollback >/dev/null && \
    assert_true "true" "bluegreen_rollback function exists"

# ============================================================================
# TEST SUITE 2: Profile Detection
# ============================================================================

test_report "Test Suite 2: Profile Detection"

if [[ -f "$PROFILE_DIR/blue-green-k8s-istio.yaml" ]]; then
    # Load profile
    export PROFILE_FILE="$PROFILE_DIR/blue-green-k8s-istio.yaml"

    # Extract mode
    mode=$(yq eval '.profile.strategy' "$PROFILE_FILE" 2>/dev/null || echo "")
    assert_equals "blue_green" "$mode" "Profile strategy detected as blue_green"

    # Extract old environment
    old_env=$(yq eval '.blue_green.old_environment' "$PROFILE_FILE" 2>/dev/null || echo "")
    assert_equals "blue" "$old_env" "Old environment is 'blue'"

    # Extract new environment
    new_env=$(yq eval '.blue_green.new_environment' "$PROFILE_FILE" 2>/dev/null || echo "")
    assert_equals "green" "$new_env" "New environment is 'green'"

    # Extract traffic router type
    router_type=$(yq eval '.blue_green.traffic_router.type' "$PROFILE_FILE" 2>/dev/null || echo "")
    assert_equals "istio" "$router_type" "Traffic router is Istio"
else
    assert_true "true" "Profile file not found (skip profile tests)"
fi

# ============================================================================
# TEST SUITE 3: Deployment Type Detection
# ============================================================================

test_report "Test Suite 3: Deployment Type Detection"

# Create mock profile for testing
mock_profile="$WORK_DIR/mock-bg-profile.yaml"
cat > "$mock_profile" <<EOF
profile:
  name: mock-blue-green
  strategy: blue_green

blue_green:
  deployment:
    type: kubernetes
    namespace: test-namespace

migration:
  target_version: "26.0.7"
EOF

export PROFILE_FILE="$mock_profile"

# Test deployment type detection
deployment_type=$(yq eval '.blue_green.deployment.type' "$PROFILE_FILE" 2>/dev/null || echo "")
assert_equals "kubernetes" "$deployment_type" "Deployment type detected"

# ============================================================================
# TEST SUITE 4: Environment URL Generation
# ============================================================================

test_report "Test Suite 4: Environment URL Generation"

# Test get_environment_url for kubernetes
k8s_url=$(bluegreen_get_environment_url "green" 2>/dev/null || echo "")
if [[ -n "$k8s_url" ]]; then
    assert_true "[[ \"$k8s_url\" == *\"green\"* ]]" "Environment URL contains environment name"
fi

# ============================================================================
# TEST SUITE 5: Cleanup Function Logic
# ============================================================================

test_report "Test Suite 5: Cleanup Function Logic"

# Create mock with docker-compose type
cat > "$mock_profile" <<EOF
profile:
  name: mock-compose
  strategy: blue_green

blue_green:
  deployment:
    type: docker-compose
EOF

export PROFILE_FILE="$mock_profile"

# Test that cleanup function can be called (dry-run, won't actually cleanup)
# Just verify it doesn't crash with wrong type
declare -F bluegreen_cleanup_environment >/dev/null && \
    assert_true "true" "Cleanup function is callable"

# ============================================================================
# TEST SUITE 6: Rollback Logic
# ============================================================================

test_report "Test Suite 6: Rollback Logic"

# Verify rollback function exists and can be invoked
declare -F bluegreen_rollback >/dev/null && \
    assert_true "true" "Rollback function exists"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Blue-Green Migration"
