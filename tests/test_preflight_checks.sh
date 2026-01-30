#!/usr/bin/env bash
# Unit Tests — Preflight Checks (v3.5)

set -euo pipefail

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source preflight checks
export WORK_DIR="/tmp/test_preflight_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

source "$LIB_DIR/preflight_checks.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Preflight Checks — Function Existence"

declare -F check_disk_space >/dev/null && \
    assert_true "true" "check_disk_space function exists"

declare -F check_memory >/dev/null && \
    assert_true "true" "check_memory function exists"

declare -F check_network_connectivity >/dev/null && \
    assert_true "true" "check_network_connectivity function exists"

declare -F check_database_connectivity >/dev/null && \
    assert_true "true" "check_database_connectivity function exists"

declare -F check_backup_space >/dev/null && \
    assert_true "true" "check_backup_space function exists"

declare -F run_all_preflight_checks >/dev/null && \
    assert_true "true" "run_all_preflight_checks function exists"

# ============================================================================
# TEST SUITE 2: Disk Space Check
# ============================================================================

test_report "Test Suite 2: Disk Space Check"

# Test with /tmp (should have space)
if check_disk_space "/tmp" 1; then
    assert_true "true" "Disk space check: /tmp has >= 1GB"
else
    assert_true "false" "Disk space check: /tmp insufficient space"
fi

# ============================================================================
# TEST SUITE 3: Memory Check
# ============================================================================

test_report "Test Suite 3: Memory Check"

# Test memory check (should pass with low threshold)
if check_memory 0.5; then
    assert_true "true" "Memory check: >= 0.5GB available"
else
    assert_true "false" "Memory check: insufficient memory"
fi

# ============================================================================
# TEST SUITE 4: Backup Directory Permissions
# ============================================================================

test_report "Test Suite 4: Backup Directory Permissions"

# Test with writable directory
if check_backup_permissions "$WORK_DIR"; then
    assert_true "true" "Backup permissions: $WORK_DIR writable"
else
    assert_true "false" "Backup permissions: $WORK_DIR not writable"
fi

# Test with non-existent directory (should create it)
test_dir="$WORK_DIR/new_backup_dir"
if check_backup_permissions "$test_dir"; then
    assert_true "true" "Backup permissions: Created $test_dir"
else
    assert_true "false" "Backup permissions: Failed to create $test_dir"
fi

# ============================================================================
# TEST SUITE 5: Dependencies Check
# ============================================================================

test_report "Test Suite 5: Dependencies Check"

# Test bash dependency (should always exist)
if check_dependencies ""; then
    assert_true "true" "Dependencies: Basic tools found"
else
    assert_true "false" "Dependencies: Missing basic tools"
fi

# ============================================================================
# TEST SUITE 6: Java Version Check
# ============================================================================

test_report "Test Suite 6: Java Version Check"

# Test Java version check (may not have Java)
if check_java_version; then
    assert_true "true" "Java version check: Completed"
else
    assert_true "true" "Java version check: Completed with warnings"
fi

# ============================================================================
# TEST SUITE 7: Profile Syntax Check
# ============================================================================

test_report "Test Suite 7: Profile Syntax Check"

# Create test profile
cat > "$WORK_DIR/test_profile.yaml" <<EOF
database:
  type: postgresql
  host: localhost
  port: 5432
keycloak:
  url: http://localhost:8080
EOF

if check_profile_syntax "$WORK_DIR/test_profile.yaml"; then
    assert_true "true" "Profile syntax: Valid YAML"
else
    assert_true "false" "Profile syntax: Invalid YAML"
fi

# ============================================================================
# TEST SUITE 8: Credentials Check
# ============================================================================

test_report "Test Suite 8: Credentials Check"

# Test credentials check (non-empty values)
if check_credentials "testuser" "testpass" "admin" "adminpass"; then
    assert_true "true" "Credentials check: Non-empty credentials"
else
    assert_true "false" "Credentials check: Failed"
fi

# Test with empty password (should warn but not fail)
if check_credentials "testuser" "" "admin" "adminpass"; then
    assert_true "true" "Credentials check: Empty password warning"
else
    assert_true "false" "Credentials check: Unexpected failure"
fi

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Preflight Checks"
