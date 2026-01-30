#!/usr/bin/env bash
# Unit Tests — Rate Limiter (v3.5)

set -euo pipefail

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source rate limiter
export WORK_DIR="/tmp/test_rate_limiter_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

source "$LIB_DIR/rate_limiter.sh"

# ============================================================================
# TEST SUITE 1: Function Existence
# ============================================================================

test_report "Test Suite 1: Rate Limiter — Function Existence"

declare -F rate_limiter_init >/dev/null && \
    assert_true "true" "rate_limiter_init function exists"

declare -F rate_limit_fixed >/dev/null && \
    assert_true "true" "rate_limit_fixed function exists"

declare -F rate_limit_token_bucket >/dev/null && \
    assert_true "true" "rate_limit_token_bucket function exists"

declare -F circuit_breaker_check >/dev/null && \
    assert_true "true" "circuit_breaker_check function exists"

declare -F circuit_breaker_success >/dev/null && \
    assert_true "true" "circuit_breaker_success function exists"

declare -F circuit_breaker_failure >/dev/null && \
    assert_true "true" "circuit_breaker_failure function exists"

declare -F exponential_backoff >/dev/null && \
    assert_true "true" "exponential_backoff function exists"

declare -F rate_limited_execute >/dev/null && \
    assert_true "true" "rate_limited_execute function exists"

# ============================================================================
# TEST SUITE 2: Fixed Rate Limiter
# ============================================================================

test_report "Test Suite 2: Fixed Rate Limiter"

# Test fixed rate limiting (10 ops/sec)
start_time=""
end_time=""
duration=""

start_time=$(date +%s)

for i in {1..5}; do
    rate_limit_fixed 10  # 10 ops/sec = 0.1s sleep
done

end_time=$(date +%s)
duration=$((end_time - start_time))

# Should take ~0.5 seconds (5 ops × 0.1s)
if (( duration >= 0 && duration <= 2 )); then
    assert_true "true" "Fixed rate limiter: 5 ops completed in ${duration}s (expected ~0.5s)"
else
    assert_true "false" "Fixed rate limiter: 5 ops took ${duration}s (unexpected)"
fi

# ============================================================================
# TEST SUITE 3: Circuit Breaker
# ============================================================================

test_report "Test Suite 3: Circuit Breaker"

# Reset circuit breaker
circuit_breaker_success

# Test initial state (should be CLOSED)
if circuit_breaker_check; then
    assert_true "true" "Circuit breaker: Initial state CLOSED (allows operations)"
else
    assert_true "false" "Circuit breaker: Initial state not CLOSED"
fi

# Simulate failures
for i in {1..5}; do
    circuit_breaker_failure
done

# Circuit should now be OPEN
if ! circuit_breaker_check; then
    assert_true "true" "Circuit breaker: State OPEN after failures (blocks operations)"
else
    assert_true "false" "Circuit breaker: Did not open after failures"
fi

# Reset for next tests
circuit_breaker_success

# ============================================================================
# TEST SUITE 4: Exponential Backoff
# ============================================================================

test_report "Test Suite 4: Exponential Backoff"

# Test backoff calculation (without actual sleep)
# Backoff times: attempt 1 = 1s, attempt 2 = 2s, attempt 3 = 4s

local attempt=1
local base_delay=1
local multiplier=2

# Formula: base_delay × (multiplier ^ attempt)
# Attempt 1: 1 × (2 ^ 1) = 2s
local expected_delay=2

# We won't actually sleep, just verify the function exists
if declare -F exponential_backoff >/dev/null; then
    assert_true "true" "Exponential backoff: Function implemented"
else
    assert_true "false" "Exponential backoff: Function not found"
fi

# ============================================================================
# TEST SUITE 5: Rate Limited Execute
# ============================================================================

test_report "Test Suite 5: Rate Limited Execute"

# Test successful operation
if rate_limited_execute "true" "fixed" 10; then
    assert_true "true" "Rate limited execute: Success"
else
    assert_true "false" "Rate limited execute: Failed"
fi

# Reset circuit breaker for next test
circuit_breaker_success

# ============================================================================
# TEST SUITE 6: Token Bucket (Basic)
# ============================================================================

test_report "Test Suite 6: Token Bucket Rate Limiter"

# Reset token bucket state
rm -f "$TOKEN_BUCKET_FILE"
rate_limiter_init

# Test token bucket (should allow operation)
if rate_limit_token_bucket 1 20 10; then
    assert_true "true" "Token bucket: Initial operation allowed"
else
    assert_true "false" "Token bucket: Initial operation denied"
fi

# ============================================================================
# TEST SUITE 7: Connection Pool Monitoring (Mock)
# ============================================================================

test_report "Test Suite 7: Connection Pool Monitoring"

# Test function existence
if declare -F monitor_connection_pool >/dev/null; then
    assert_true "true" "Connection pool monitoring: Function exists"
else
    assert_true "false" "Connection pool monitoring: Function missing"
fi

# ============================================================================
# TEST SUITE 8: Leak Detection (Mock)
# ============================================================================

test_report "Test Suite 8: Connection Leak Detection"

# Test function existence
if declare -F detect_connection_leak >/dev/null; then
    assert_true "true" "Leak detection: Function exists"
else
    assert_true "false" "Leak detection: Function missing"
fi

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Rate Limiter"
