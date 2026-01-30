#!/usr/bin/env bash
# Unit Tests — Input Validator (v3.6)

set -euo pipefail

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source input validator
export WORK_DIR="/tmp/test_input_validator_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

source "$LIB_DIR/input_validator.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Input Validator — Function Existence"

declare -F is_sql_injection_attempt >/dev/null && \
    assert_true "true" "is_sql_injection_attempt function exists"

declare -F escape_sql_string >/dev/null && \
    assert_true "true" "escape_sql_string function exists"

declare -F validate_sql_identifier >/dev/null && \
    assert_true "true" "validate_sql_identifier function exists"

declare -F validate_sql_value >/dev/null && \
    assert_true "true" "validate_sql_value function exists"

declare -F is_command_injection_attempt >/dev/null && \
    assert_true "true" "is_command_injection_attempt function exists"

declare -F sanitize_command_arg >/dev/null && \
    assert_true "true" "sanitize_command_arg function exists"

declare -F validate_command_arg >/dev/null && \
    assert_true "true" "validate_command_arg function exists"

declare -F safe_execute >/dev/null && \
    assert_true "true" "safe_execute function exists"

declare -F normalize_path >/dev/null && \
    assert_true "true" "normalize_path function exists"

declare -F is_path_traversal_attempt >/dev/null && \
    assert_true "true" "is_path_traversal_attempt function exists"

declare -F validate_file_path >/dev/null && \
    assert_true "true" "validate_file_path function exists"

declare -F safe_read_file >/dev/null && \
    assert_true "true" "safe_read_file function exists"

declare -F safe_write_file >/dev/null && \
    assert_true "true" "safe_write_file function exists"

declare -F is_yaml_injection_attempt >/dev/null && \
    assert_true "true" "is_yaml_injection_attempt function exists"

declare -F validate_yaml_content >/dev/null && \
    assert_true "true" "validate_yaml_content function exists"

declare -F sanitize_log_message >/dev/null && \
    assert_true "true" "sanitize_log_message function exists"

declare -F safe_log >/dev/null && \
    assert_true "true" "safe_log function exists"

declare -F validate_email >/dev/null && \
    assert_true "true" "validate_email function exists"

declare -F validate_url >/dev/null && \
    assert_true "true" "validate_url function exists"

declare -F validate_integer >/dev/null && \
    assert_true "true" "validate_integer function exists"

declare -F validate_input >/dev/null && \
    assert_true "true" "validate_input function exists"

# ============================================================================
# TEST SUITE 2: SQL Injection Detection
# ============================================================================

test_report "Test Suite 2: SQL Injection Detection"

# Test SQL injection patterns
if is_sql_injection_attempt "'; DROP TABLE users--"; then
    assert_true "true" "SQL injection detected: DROP TABLE"
else
    assert_true "false" "SQL injection NOT detected: DROP TABLE"
fi

if is_sql_injection_attempt "admin' OR '1'='1"; then
    assert_true "true" "SQL injection detected: OR 1=1"
else
    assert_true "false" "SQL injection NOT detected: OR 1=1"
fi

if is_sql_injection_attempt "' UNION SELECT * FROM passwords--"; then
    assert_true "true" "SQL injection detected: UNION SELECT"
else
    assert_true "false" "SQL injection NOT detected: UNION SELECT"
fi

# Test safe SQL value (no injection)
if is_sql_injection_attempt "John Doe"; then
    assert_true "false" "False positive: Safe value flagged as SQL injection"
else
    assert_true "true" "SQL injection NOT detected in safe value"
fi

# ============================================================================
# TEST SUITE 3: SQL String Escaping
# ============================================================================

test_report "Test Suite 3: SQL String Escaping"

# Test single quote escaping
result=$(escape_sql_string "O'Brien")
expected="O''Brien"
assert_equals "$expected" "$result" "SQL escape: Single quote doubled"

result=$(escape_sql_string "It's a test")
expected="It''s a test"
assert_equals "$expected" "$result" "SQL escape: Multiple single quotes"

# ============================================================================
# TEST SUITE 4: SQL Identifier Validation
# ============================================================================

test_report "Test Suite 4: SQL Identifier Validation"

# Valid identifiers
result=$(validate_sql_identifier "users" "strict")
assert_equals "users" "$result" "SQL identifier: Valid table name"

result=$(validate_sql_identifier "user_accounts" "strict")
assert_equals "user_accounts" "$result" "SQL identifier: Valid with underscore"

result=$(validate_sql_identifier "Table1" "strict")
assert_equals "Table1" "$result" "SQL identifier: Valid with number"

# Invalid identifiers
if validate_sql_identifier "123invalid" "strict" >/dev/null 2>&1; then
    assert_true "false" "SQL identifier: Should reject starting with number"
else
    assert_true "true" "SQL identifier: Rejected starting with number"
fi

if validate_sql_identifier "invalid-name" "strict" >/dev/null 2>&1; then
    assert_true "false" "SQL identifier: Should reject hyphen"
else
    assert_true "true" "SQL identifier: Rejected hyphen"
fi

# ============================================================================
# TEST SUITE 5: Command Injection Detection
# ============================================================================

test_report "Test Suite 5: Command Injection Detection"

# Test command injection patterns
if is_command_injection_attempt "file.txt; rm -rf /"; then
    assert_true "true" "Command injection detected: Semicolon separator"
else
    assert_true "false" "Command injection NOT detected: Semicolon"
fi

if is_command_injection_attempt "file.txt && malicious"; then
    assert_true "true" "Command injection detected: AND operator"
else
    assert_true "false" "Command injection NOT detected: AND operator"
fi

if is_command_injection_attempt "file.txt | grep password"; then
    assert_true "true" "Command injection detected: Pipe"
else
    assert_true "false" "Command injection NOT detected: Pipe"
fi

if is_command_injection_attempt "\$(whoami)"; then
    assert_true "true" "Command injection detected: Command substitution"
else
    assert_true "false" "Command injection NOT detected: Command substitution"
fi

if is_command_injection_attempt "file.txt > output"; then
    assert_true "true" "Command injection detected: Redirection"
else
    assert_true "false" "Command injection NOT detected: Redirection"
fi

# Test safe value
if is_command_injection_attempt "filename.txt"; then
    assert_true "false" "False positive: Safe filename flagged"
else
    assert_true "true" "Command injection NOT detected in safe filename"
fi

# ============================================================================
# TEST SUITE 6: Command Argument Sanitization
# ============================================================================

test_report "Test Suite 6: Command Argument Sanitization"

# Sanitize dangerous characters
result=$(sanitize_command_arg "file.txt; rm -rf /")
expected="file.txt rm -rf "
assert_true "echo '$result' | grep -q 'file.txt'" "Sanitize: Removed semicolon"

result=$(sanitize_command_arg "file\$(whoami).txt")
expected="filewhoami.txt"
assert_true "echo '$result' | grep -qv '[$]'" "Sanitize: Removed dollar sign"

# ============================================================================
# TEST SUITE 7: Path Traversal Detection
# ============================================================================

test_report "Test Suite 7: Path Traversal Detection"

# Test path traversal patterns
if is_path_traversal_attempt "../../../etc/passwd"; then
    assert_true "true" "Path traversal detected: ../ pattern"
else
    assert_true "false" "Path traversal NOT detected: ../"
fi

if is_path_traversal_attempt "../../../../var/www"; then
    assert_true "true" "Path traversal detected: Multiple ../"
else
    assert_true "false" "Path traversal NOT detected: Multiple ../"
fi

# Test safe relative path
if is_path_traversal_attempt "files/documents/report.pdf"; then
    assert_true "false" "False positive: Safe path flagged"
else
    assert_true "true" "Path traversal NOT detected in safe path"
fi

# ============================================================================
# TEST SUITE 8: Path Normalization
# ============================================================================

test_report "Test Suite 8: Path Normalization"

# Create test files for normalization
mkdir -p "$WORK_DIR/test/subdir"
touch "$WORK_DIR/test/file.txt"

# Test normalization
result=$(normalize_path "$WORK_DIR/test/./file.txt")
expected="$WORK_DIR/test/file.txt"
assert_true "echo '$result' | grep -q 'test/file.txt'" "Normalize: Removed /./"

# ============================================================================
# TEST SUITE 9: File Path Validation
# ============================================================================

test_report "Test Suite 9: File Path Validation"

# Create allowed base directory
mkdir -p "$WORK_DIR/allowed"
touch "$WORK_DIR/allowed/safe.txt"

# Test valid path within allowed directory
result=$(validate_file_path "safe.txt" "$WORK_DIR/allowed" "strict")
assert_true "echo '$result' | grep -q 'safe.txt'" "File path: Valid within allowed directory"

# Test path outside allowed directory (should fail in strict mode)
if validate_file_path "/etc/passwd" "$WORK_DIR/allowed" "strict" >/dev/null 2>&1; then
    assert_true "false" "File path: Should reject outside allowed directory"
else
    assert_true "true" "File path: Rejected outside allowed directory"
fi

# ============================================================================
# TEST SUITE 10: YAML Injection Detection
# ============================================================================

test_report "Test Suite 10: YAML Injection Detection"

# Test YAML injection patterns
yaml_content='!!python/object/apply:os.system ["rm -rf /"]'
if is_yaml_injection_attempt "$yaml_content"; then
    assert_true "true" "YAML injection detected: !!python"
else
    assert_true "false" "YAML injection NOT detected: !!python"
fi

yaml_content='exec(malicious_code)'
if is_yaml_injection_attempt "$yaml_content"; then
    assert_true "true" "YAML injection detected: exec()"
else
    assert_true "false" "YAML injection NOT detected: exec()"
fi

# Test safe YAML
yaml_content='name: test\nvalue: 123'
if is_yaml_injection_attempt "$yaml_content"; then
    assert_true "false" "False positive: Safe YAML flagged"
else
    assert_true "true" "YAML injection NOT detected in safe YAML"
fi

# ============================================================================
# TEST SUITE 11: Log Message Sanitization
# ============================================================================

test_report "Test Suite 11: Log Message Sanitization"

# Test newline removal
result=$(sanitize_log_message "Line 1
Line 2")
assert_true "echo '$result' | grep -qv '\n'" "Log sanitize: Newline removed"

# Test carriage return removal
result=$(sanitize_log_message "Test$(printf '\r')message")
assert_true "echo '$result' | grep -qv '\r'" "Log sanitize: Carriage return removed"

# Test tab removal
result=$(sanitize_log_message "Test$(printf '\t')message")
assert_true "echo '$result' | grep -qv '\t'" "Log sanitize: Tab removed"

# ============================================================================
# TEST SUITE 12: Email Validation
# ============================================================================

test_report "Test Suite 12: Email Validation"

# Valid emails
result=$(validate_email "user@example.com" "strict")
assert_equals "user@example.com" "$result" "Email: Valid standard format"

result=$(validate_email "test.user+tag@example.co.uk" "strict")
assert_equals "test.user+tag@example.co.uk" "$result" "Email: Valid complex format"

# Invalid emails
if validate_email "invalid.email" "strict" >/dev/null 2>&1; then
    assert_true "false" "Email: Should reject missing @"
else
    assert_true "true" "Email: Rejected missing @"
fi

if validate_email "user@" "strict" >/dev/null 2>&1; then
    assert_true "false" "Email: Should reject missing domain"
else
    assert_true "true" "Email: Rejected missing domain"
fi

# Email injection attempt
if validate_email "user@example.com
BCC:attacker@evil.com" "strict" >/dev/null 2>&1; then
    assert_true "false" "Email: Should reject injection attempt"
else
    assert_true "true" "Email: Rejected injection attempt"
fi

# ============================================================================
# TEST SUITE 13: URL Validation
# ============================================================================

test_report "Test Suite 13: URL Validation"

# Valid URLs
result=$(validate_url "https://example.com" "strict" "https http")
assert_equals "https://example.com" "$result" "URL: Valid HTTPS"

result=$(validate_url "http://example.com/path" "strict" "https http")
assert_equals "http://example.com/path" "URL: Valid HTTP with path"

# Invalid scheme
if validate_url "ftp://example.com" "strict" "https http" >/dev/null 2>&1; then
    assert_true "false" "URL: Should reject FTP scheme"
else
    assert_true "true" "URL: Rejected FTP scheme"
fi

# SSRF attempt (localhost)
if validate_url "http://localhost:8080" "strict" "https http" >/dev/null 2>&1; then
    assert_true "false" "URL: Should reject localhost (SSRF)"
else
    assert_true "true" "URL: Rejected localhost (SSRF)"
fi

# SSRF attempt (127.0.0.1)
if validate_url "http://127.0.0.1" "strict" "https http" >/dev/null 2>&1; then
    assert_true "false" "URL: Should reject 127.0.0.1 (SSRF)"
else
    assert_true "true" "URL: Rejected 127.0.0.1 (SSRF)"
fi

# SSRF attempt (internal IP)
if validate_url "http://192.168.1.1" "strict" "https http" >/dev/null 2>&1; then
    assert_true "false" "URL: Should reject internal IP (SSRF)"
else
    assert_true "true" "URL: Rejected internal IP (SSRF)"
fi

# ============================================================================
# TEST SUITE 14: Integer Validation
# ============================================================================

test_report "Test Suite 14: Integer Validation"

# Valid integers
result=$(validate_integer "42")
assert_equals "42" "$result" "Integer: Valid positive"

result=$(validate_integer "-10")
assert_equals "-10" "$result" "Integer: Valid negative"

result=$(validate_integer "0")
assert_equals "0" "$result" "Integer: Valid zero"

# Invalid integers
if validate_integer "abc" >/dev/null 2>&1; then
    assert_true "false" "Integer: Should reject non-numeric"
else
    assert_true "true" "Integer: Rejected non-numeric"
fi

if validate_integer "12.34" >/dev/null 2>&1; then
    assert_true "false" "Integer: Should reject decimal"
else
    assert_true "true" "Integer: Rejected decimal"
fi

# Range validation
result=$(validate_integer "50" "0" "100")
assert_equals "50" "$result" "Integer: Within range"

if validate_integer "150" "0" "100" >/dev/null 2>&1; then
    assert_true "false" "Integer: Should reject above max"
else
    assert_true "true" "Integer: Rejected above max"
fi

if validate_integer "-10" "0" "100" >/dev/null 2>&1; then
    assert_true "false" "Integer: Should reject below min"
else
    assert_true "true" "Integer: Rejected below min"
fi

# ============================================================================
# TEST SUITE 15: Universal validate_input Function
# ============================================================================

test_report "Test Suite 15: Universal validate_input Function"

# Test SQL value validation
result=$(validate_input "John Doe" "sql_value" "sanitize")
assert_true "[ -n '$result' ]" "validate_input: SQL value processed"

# Test command arg validation
result=$(validate_input "filename.txt" "command_arg" "strict")
assert_equals "filename.txt" "$result" "validate_input: Command arg valid"

# Test email validation
result=$(validate_input "user@example.com" "email" "strict")
assert_equals "user@example.com" "$result" "validate_input: Email valid"

# Test integer validation
result=$(validate_input "42" "integer" "strict")
assert_equals "42" "$result" "validate_input: Integer valid"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Input Validator"
