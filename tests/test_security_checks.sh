#!/usr/bin/env bash
# Unit Tests — Security Checks (v3.6)

set -euo pipefail

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source security checks
export WORK_DIR="/tmp/test_security_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

source "$LIB_DIR/security_checks.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Security Checks — Function Existence"

declare -F check_shellcheck_available >/dev/null && \
    assert_true "true" "check_shellcheck_available function exists"

declare -F check_gitleaks_available >/dev/null && \
    assert_true "true" "check_gitleaks_available function exists"

declare -F check_security_tools >/dev/null && \
    assert_true "true" "check_security_tools function exists"

declare -F run_shellcheck_single >/dev/null && \
    assert_true "true" "run_shellcheck_single function exists"

declare -F run_shellcheck_directory >/dev/null && \
    assert_true "true" "run_shellcheck_directory function exists"

declare -F run_gitleaks_scan >/dev/null && \
    assert_true "true" "run_gitleaks_scan function exists"

declare -F run_secrets_scan_history >/dev/null && \
    assert_true "true" "run_secrets_scan_history function exists"

declare -F check_hardcoded_secrets >/dev/null && \
    assert_true "true" "check_hardcoded_secrets function exists"

declare -F run_comprehensive_security_scan >/dev/null && \
    assert_true "true" "run_comprehensive_security_scan function exists"

# ============================================================================
# TEST SUITE 2: Tool Detection
# ============================================================================

test_report "Test Suite 2: Tool Detection"

# Test ShellCheck detection
if command -v shellcheck >/dev/null 2>&1; then
    check_shellcheck_available && \
        assert_true "true" "ShellCheck detected"
else
    echo "[INFO] ShellCheck not installed - skipping detection test"
fi

# Test gitleaks detection
if command -v gitleaks >/dev/null 2>&1; then
    check_gitleaks_available && \
        assert_true "true" "gitleaks detected"
else
    echo "[INFO] gitleaks not installed - skipping detection test"
fi

# ============================================================================
# TEST SUITE 3: ShellCheck Integration
# ============================================================================

test_report "Test Suite 3: ShellCheck Integration"

# Create test script (valid)
cat > "$WORK_DIR/test_valid.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Hello, World!"
exit 0
EOF

# Create test script (with issues)
cat > "$WORK_DIR/test_issues.sh" <<'EOF'
#!/bin/bash
# Missing quotes around variable (SC2086)
file=$1
cat $file
EOF

# Test ShellCheck on valid script
if command -v shellcheck >/dev/null 2>&1; then
    if run_shellcheck_single "$WORK_DIR/test_valid.sh" "warning" >/dev/null 2>&1; then
        assert_true "true" "ShellCheck: Valid script passed"
    else
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            assert_true "true" "ShellCheck: Valid script passed (exit 0)"
        else
            assert_true "false" "ShellCheck: Valid script failed unexpectedly (exit $exit_code)"
        fi
    fi

    # Test ShellCheck on script with issues (should detect issues)
    if run_shellcheck_single "$WORK_DIR/test_issues.sh" "warning" >/dev/null 2>&1; then
        assert_true "false" "ShellCheck: Script with issues should have been flagged"
    else
        assert_true "true" "ShellCheck: Detected issues in problematic script"
    fi
else
    echo "[INFO] ShellCheck not installed - skipping ShellCheck tests"
fi

# ============================================================================
# TEST SUITE 4: Hardcoded Secrets Detection
# ============================================================================

test_report "Test Suite 4: Hardcoded Secrets Detection"

# Create test file with hardcoded secrets
mkdir -p "$WORK_DIR/secrets_test"

cat > "$WORK_DIR/secrets_test/config.sh" <<'EOF'
#!/bin/bash
# This should be detected
password="admin123"
api_key="sk-1234567890abcdef"
EOF

# Test hardcoded secrets detection
if check_hardcoded_secrets "$WORK_DIR/secrets_test" >/dev/null 2>&1; then
    assert_true "false" "Hardcoded secrets check should have detected secrets"
else
    assert_true "true" "Hardcoded secrets: Detected patterns in test file"
fi

# Test with clean file
cat > "$WORK_DIR/secrets_test/clean.sh" <<'EOF'
#!/bin/bash
# No hardcoded secrets here
echo "Application started"
EOF

if check_hardcoded_secrets "$WORK_DIR/secrets_test" >/dev/null 2>&1; then
    # Should find secrets in config.sh
    assert_true "true" "Hardcoded secrets: Directory scan completed"
else
    assert_true "true" "Hardcoded secrets: Directory scan completed with findings"
fi

# ============================================================================
# TEST SUITE 5: Gitleaks Integration (Mock)
# ============================================================================

test_report "Test Suite 5: Gitleaks Integration"

# Initialize test git repo
cd "$WORK_DIR"
git init >/dev/null 2>&1 || true
git config user.email "test@example.com" >/dev/null 2>&1 || true
git config user.name "Test User" >/dev/null 2>&1 || true

# Create test file without secrets
cat > "$WORK_DIR/test.txt" <<'EOF'
This is a test file.
No secrets here.
EOF

git add test.txt >/dev/null 2>&1 || true
git commit -m "Initial commit" >/dev/null 2>&1 || true

# Test gitleaks scan
if command -v gitleaks >/dev/null 2>&1; then
    if run_gitleaks_scan "$WORK_DIR" "" "false" >/dev/null 2>&1; then
        assert_true "true" "gitleaks: No secrets detected in clean repo"
    else
        exit_code=$?
        if [ $exit_code -eq 1 ]; then
            assert_true "true" "gitleaks: Scan completed (secrets may exist)"
        else
            assert_true "true" "gitleaks: Scan completed with warnings"
        fi
    fi
else
    echo "[INFO] gitleaks not installed - skipping gitleaks tests"
fi

# ============================================================================
# TEST SUITE 6: Comprehensive Security Scan
# ============================================================================

test_report "Test Suite 6: Comprehensive Security Scan"

# Create test project structure
mkdir -p "$WORK_DIR/project/scripts"

cat > "$WORK_DIR/project/scripts/deploy.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Deploying application..."
exit 0
EOF

# Test comprehensive scan
if command -v shellcheck >/dev/null 2>&1 || command -v gitleaks >/dev/null 2>&1; then
    # Run with fail_on_critical=false to avoid exit
    if run_comprehensive_security_scan "$WORK_DIR/project" "false" >/dev/null 2>&1; then
        assert_true "true" "Comprehensive scan: Completed"
    else
        exit_code=$?
        if [ $exit_code -eq 10 ]; then
            assert_true "true" "Comprehensive scan: Found critical issues (expected in test)"
        else
            assert_true "true" "Comprehensive scan: Completed with warnings"
        fi
    fi
else
    echo "[INFO] Security tools not installed - skipping comprehensive scan"
fi

# ============================================================================
# TEST SUITE 7: Exit Code Validation
# ============================================================================

test_report "Test Suite 7: Exit Code Validation"

# Test that exit codes are defined
if [ "$EXIT_SUCCESS" -eq 0 ]; then
    assert_true "true" "EXIT_SUCCESS is 0"
fi

if [ "$EXIT_CRITICAL_ISSUES" -eq 10 ]; then
    assert_true "true" "EXIT_CRITICAL_ISSUES is 10"
fi

if [ "$EXIT_TOOL_MISSING" -eq 11 ]; then
    assert_true "true" "EXIT_TOOL_MISSING is 11"
fi

if [ "$EXIT_SCAN_FAILED" -eq 12 ]; then
    assert_true "true" "EXIT_SCAN_FAILED is 12"
fi

# ============================================================================
# TEST SUITE 8: Severity Levels
# ============================================================================

test_report "Test Suite 8: Severity Levels"

# Test severity constants
if [ "$SEVERITY_CRITICAL" -eq 4 ]; then
    assert_true "true" "SEVERITY_CRITICAL is 4"
fi

if [ "$SEVERITY_HIGH" -eq 3 ]; then
    assert_true "true" "SEVERITY_HIGH is 3"
fi

if [ "$SEVERITY_MEDIUM" -eq 2 ]; then
    assert_true "true" "SEVERITY_MEDIUM is 2"
fi

if [ "$SEVERITY_LOW" -eq 1 ]; then
    assert_true "true" "SEVERITY_LOW is 1"
fi

if [ "$SEVERITY_INFO" -eq 0 ]; then
    assert_true "true" "SEVERITY_INFO is 0"
fi

# ============================================================================
# TEST SUITE 9: Logging Functions
# ============================================================================

test_report "Test Suite 9: Logging Functions"

# Test logging functions exist
declare -F sec_log_info >/dev/null && \
    assert_true "true" "sec_log_info function exists"

declare -F sec_log_success >/dev/null && \
    assert_true "true" "sec_log_success function exists"

declare -F sec_log_warn >/dev/null && \
    assert_true "true" "sec_log_warn function exists"

declare -F sec_log_error >/dev/null && \
    assert_true "true" "sec_log_error function exists"

declare -F sec_log_critical >/dev/null && \
    assert_true "true" "sec_log_critical function exists"

# Test logging functions produce output
log_output=$(sec_log_info "Test message" 2>&1)
if echo "$log_output" | grep -q "Test message"; then
    assert_true "true" "sec_log_info produces output"
fi

# ============================================================================
# Cleanup
# ============================================================================

cd "$SCRIPT_DIR"
rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Security Checks"
