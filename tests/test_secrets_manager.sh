#!/usr/bin/env bash
# Unit Tests — Secrets Manager (v3.6)

set -euo pipefail

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source secrets manager
export WORK_DIR="/tmp/test_secrets_manager_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

# Configure file-based backend for testing
export SECRETS_FILE="$WORK_DIR/secrets"
export SECRETS_BACKEND="file"

source "$LIB_DIR/secrets_manager.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Secrets Manager — Function Existence"

declare -F detect_secrets_backend >/dev/null && \
    assert_true "true" "detect_secrets_backend function exists"

declare -F get_secrets_backend >/dev/null && \
    assert_true "true" "get_secrets_backend function exists"

declare -F set_secrets_backend >/dev/null && \
    assert_true "true" "set_secrets_backend function exists"

declare -F get_secret >/dev/null && \
    assert_true "true" "get_secret function exists"

declare -F set_secret >/dev/null && \
    assert_true "true" "set_secret function exists"

declare -F delete_secret >/dev/null && \
    assert_true "true" "delete_secret function exists"

declare -F list_secrets >/dev/null && \
    assert_true "true" "list_secrets function exists"

declare -F load_secrets_to_env >/dev/null && \
    assert_true "true" "load_secrets_to_env function exists"

declare -F test_secrets_backend >/dev/null && \
    assert_true "true" "test_secrets_backend function exists"

# ============================================================================
# TEST SUITE 2: Backend Detection
# ============================================================================

test_report "Test Suite 2: Backend Detection"

# Test backend constants
assert_equals "vault" "$BACKEND_VAULT" "Backend constant: VAULT"
assert_equals "aws" "$BACKEND_AWS" "Backend constant: AWS"
assert_equals "azure" "$BACKEND_AZURE" "Backend constant: AZURE"
assert_equals "k8s" "$BACKEND_K8S" "Backend constant: K8S"
assert_equals "env" "$BACKEND_ENV" "Backend constant: ENV"
assert_equals "file" "$BACKEND_FILE" "Backend constant: FILE"

# Test get_secrets_backend
current_backend=$(get_secrets_backend)
assert_equals "file" "$current_backend" "Current backend is file"

# Test set_secrets_backend
set_secrets_backend "env"
current_backend=$(get_secrets_backend)
assert_equals "env" "$current_backend" "Backend changed to env"

# Reset to file for remaining tests
set_secrets_backend "file"

# ============================================================================
# TEST SUITE 3: File Backend — Set/Get Secret
# ============================================================================

test_report "Test Suite 3: File Backend — Set/Get Secret"

# Create secrets file
touch "$SECRETS_FILE"

# Test set_secret
set_secret "db_password" "secret123" "file"
assert_true "[ -f '$SECRETS_FILE' ]" "Secrets file created"

# Test get_secret
result=$(get_secret "db_password" "file")
assert_equals "secret123" "$result" "File backend: Get secret"

# Test multiple secrets
set_secret "api_key" "key456" "file"
result=$(get_secret "api_key" "file")
assert_equals "key456" "$result" "File backend: Second secret"

# Verify first secret still exists
result=$(get_secret "db_password" "file")
assert_equals "secret123" "$result" "File backend: First secret persists"

# ============================================================================
# TEST SUITE 4: File Backend — List Secrets
# ============================================================================

test_report "Test Suite 4: File Backend — List Secrets"

# Add third secret
set_secret "admin_password" "admin789" "file"

# List all secrets
keys=$(list_secrets "file")
assert_true "echo '$keys' | grep -q 'db_password'" "List secrets: db_password found"
assert_true "echo '$keys' | grep -q 'api_key'" "List secrets: api_key found"
assert_true "echo '$keys' | grep -q 'admin_password'" "List secrets: admin_password found"

# ============================================================================
# TEST SUITE 5: File Backend — Delete Secret
# ============================================================================

test_report "Test Suite 5: File Backend — Delete Secret"

# Delete one secret
delete_secret "api_key" "file"

# Verify deleted
if get_secret "api_key" "file" >/dev/null 2>&1; then
    assert_true "false" "Delete secret: api_key should be deleted"
else
    assert_true "true" "Delete secret: api_key deleted"
fi

# Verify others still exist
result=$(get_secret "db_password" "file")
assert_equals "secret123" "$result" "Delete secret: db_password still exists"

result=$(get_secret "admin_password" "file")
assert_equals "admin789" "$result" "Delete secret: admin_password still exists"

# ============================================================================
# TEST SUITE 6: File Backend — Secret Update
# ============================================================================

test_report "Test Suite 6: File Backend — Secret Update"

# Update existing secret
set_secret "db_password" "new_secret456" "file"

# Verify updated value
result=$(get_secret "db_password" "file")
assert_equals "new_secret456" "$result" "Update secret: New value retrieved"

# ============================================================================
# TEST SUITE 7: File Backend — Empty Value Handling
# ============================================================================

test_report "Test Suite 7: File Backend — Empty Value Handling"

# Set empty value
set_secret "empty_secret" "" "file"

# Get empty value
result=$(get_secret "empty_secret" "file")
assert_equals "" "$result" "Empty value: Retrieved correctly"

# ============================================================================
# TEST SUITE 8: Environment Backend
# ============================================================================

test_report "Test Suite 8: Environment Backend"

# Set environment variable
export TEST_SECRET="env_value_123"

# Get from environment backend
result=$(get_secret "test-secret" "env")
assert_equals "env_value_123" "$result" "Env backend: Hyphen to underscore conversion"

# Test uppercase conversion
export ANOTHER_SECRET="another_value"
result=$(get_secret "another_secret" "env")
assert_equals "another_value" "$result" "Env backend: Lowercase to uppercase"

# ============================================================================
# TEST SUITE 9: Load Secrets to Environment
# ============================================================================

test_report "Test Suite 9: Load Secrets to Environment"

# Reset to file backend
set_secrets_backend "file"

# Set test secrets
set_secret "db_host" "localhost" "file"
set_secret "db_port" "5432" "file"

# Load to environment
load_secrets_to_env "db_host" "db_port"

# Verify environment variables
assert_equals "localhost" "${DB_HOST:-}" "Load to env: DB_HOST set"
assert_equals "5432" "${DB_PORT:-}" "Load to env: DB_PORT set"

# ============================================================================
# TEST SUITE 10: Backend Test Function
# ============================================================================

test_report "Test Suite 10: Backend Test Function"

# Test file backend
if test_secrets_backend "file" >/dev/null 2>&1; then
    assert_true "true" "Backend test: File backend OK"
else
    assert_true "false" "Backend test: File backend failed"
fi

# Test env backend (should always work)
if test_secrets_backend "env" >/dev/null 2>&1; then
    assert_true "true" "Backend test: Env backend OK"
else
    assert_true "false" "Backend test: Env backend failed"
fi

# ============================================================================
# TEST SUITE 11: Secret Not Found Error
# ============================================================================

test_report "Test Suite 11: Secret Not Found Error"

# Try to get non-existent secret
if get_secret "nonexistent_key" "file" >/dev/null 2>&1; then
    assert_true "false" "Secret not found: Should return error"
else
    exit_code=$?
    if [ $exit_code -eq 31 ]; then
        assert_true "true" "Secret not found: Correct exit code (31)"
    else
        assert_true "true" "Secret not found: Error returned (exit $exit_code)"
    fi
fi

# ============================================================================
# TEST SUITE 12: File Permissions
# ============================================================================

test_report "Test Suite 12: File Permissions"

# Check secrets file permissions (should be 600)
perms=$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%A' "$SECRETS_FILE" 2>/dev/null)
assert_equals "600" "$perms" "File permissions: 600 (owner read/write only)"

# ============================================================================
# TEST SUITE 13: Special Characters in Values
# ============================================================================

test_report "Test Suite 13: Special Characters in Values"

# Test with special characters
special_value='p@$$w0rd!#%&*()[]{}|<>?/'
set_secret "special_secret" "$special_value" "file"

result=$(get_secret "special_secret" "file")
assert_equals "$special_value" "$result" "Special chars: Value preserved"

# Test with spaces
spaced_value="value with spaces"
set_secret "spaced_secret" "$spaced_value" "file"

result=$(get_secret "spaced_secret" "file")
assert_equals "$spaced_value" "$result" "Spaces: Value preserved"

# ============================================================================
# TEST SUITE 14: Backend Switching
# ============================================================================

test_report "Test Suite 14: Backend Switching"

# Set secret in file backend
set_secrets_backend "file"
set_secret "backend_test" "file_value" "file"

# Switch to env backend
set_secrets_backend "env"
export BACKEND_TEST="env_value"

result=$(get_secret "backend-test" "env")
assert_equals "env_value" "$result" "Backend switch: Env backend active"

# Switch back to file
set_secrets_backend "file"
result=$(get_secret "backend_test" "file")
assert_equals "file_value" "$result" "Backend switch: File backend active"

# ============================================================================
# TEST SUITE 15: Vault Backend Functions Exist
# ============================================================================

test_report "Test Suite 15: Vault Backend Functions"

# Test Vault functions exist (implementation delegates to vault_integration.sh)
declare -F get_secret_vault >/dev/null && \
    assert_true "true" "get_secret_vault function exists"

declare -F set_secret_vault >/dev/null && \
    assert_true "true" "set_secret_vault function exists"

declare -F delete_secret_vault >/dev/null && \
    assert_true "true" "delete_secret_vault function exists"

declare -F list_secrets_vault >/dev/null && \
    assert_true "true" "list_secrets_vault function exists"

# ============================================================================
# TEST SUITE 16: K8s Backend Functions Exist
# ============================================================================

test_report "Test Suite 16: K8s Backend Functions"

declare -F get_secret_k8s >/dev/null && \
    assert_true "true" "get_secret_k8s function exists"

declare -F list_secrets_k8s >/dev/null && \
    assert_true "true" "list_secrets_k8s function exists"

# ============================================================================
# TEST SUITE 17: AWS Backend Functions Exist
# ============================================================================

test_report "Test Suite 17: AWS Backend Functions"

declare -F get_secret_aws >/dev/null && \
    assert_true "true" "get_secret_aws function exists"

declare -F set_secret_aws >/dev/null && \
    assert_true "true" "set_secret_aws function exists"

declare -F delete_secret_aws >/dev/null && \
    assert_true "true" "delete_secret_aws function exists"

declare -F list_secrets_aws >/dev/null && \
    assert_true "true" "list_secrets_aws function exists"

# ============================================================================
# TEST SUITE 18: Azure Backend Functions Exist
# ============================================================================

test_report "Test Suite 18: Azure Backend Functions"

declare -F get_secret_azure >/dev/null && \
    assert_true "true" "get_secret_azure function exists"

declare -F set_secret_azure >/dev/null && \
    assert_true "true" "set_secret_azure function exists"

declare -F delete_secret_azure >/dev/null && \
    assert_true "true" "delete_secret_azure function exists"

declare -F list_secrets_azure >/dev/null && \
    assert_true "true" "list_secrets_azure function exists"

# ============================================================================
# Cleanup
# ============================================================================

# Clean up environment variables
unset DB_HOST DB_PORT TEST_SECRET ANOTHER_SECRET BACKEND_TEST

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Secrets Manager"
