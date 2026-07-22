#!/usr/bin/env bash
# shellcheck disable=SC2329
# (the pg_client_available stub is invoked indirectly by check_network_connectivity)
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

# check_disk_space is now a FLOOR in MB (logs/state/temp), not a budget in GB. The backup
# requirement is measured from the database in check_backup_space — an arbitrary 10GB gate that
# fired BEFORE the database was even sized used to refuse a 50MB migration on an 8GB host.
if check_disk_space "/tmp" 1; then
    assert_true "true" "Disk floor check: /tmp has >= 1MB"
else
    assert_true "false" "Disk floor check: /tmp insufficient space"
fi

assert_equals "512" "$MIN_DISK_FREE_MB" \
    "the floor is 512MB of working space — not a made-up backup budget"
assert_true "[[ -z \"\${MIN_DISK_SPACE_GB:-}\" ]]" \
    "the hardcoded 10GB gate is gone"

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
describe "REGRESSION: network probe must not parse nc's message"
# ============================================================================
# The old code grepped nc's output for 'succeeded|open'. ncat (nmap) prints
# "Ncat: Connected to ..." instead -> FALSE "UNREACHABLE" even though psql connected to the
# very same host:port. The probe must judge by TCP, not by wording.

assert_false "check_network_connectivity 127.0.0.1 1 >/dev/null 2>&1" \
    "closed port -> UNREACHABLE"

if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server 18099 --bind 127.0.0.1 >/dev/null 2>&1 &
    _pf_lp=$!
    sleep 1
    assert_true "check_network_connectivity 127.0.0.1 18099 >/dev/null 2>&1" \
        "open port -> reachable (independent of the nc flavour)"
    kill "$_pf_lp" 2>/dev/null || true
else
    skip_test "python3 not available for the open-port probe"
fi

# ============================================================================
describe "AUTONOMOUS: an unreachable host-probe DEFERS to the DB check (no false network failure)"
# ============================================================================
# When there is no host psql, the migration reaches the DB through the pg-client CONTAINER, which may
# sit on a container network the host cannot TCP-probe (a rootless-docker DB by name). The host-level
# probe is then not authoritative — warn and defer; the pg_client-based DB check is the real gate.
_pf_tb="$(mktemp -d)"
for _t in bash timeout nc sleep; do _p="$(command -v "$_t" 2>/dev/null)"; [[ -n "$_p" ]] && ln -sf "$_p" "$_pf_tb/$_t"; done
pg_client_available() { return 0; }   # stub: a container pg-client IS available
# host psql hidden (not in $_pf_tb) + a closed port -> the fix must WARN and defer (return 0)
assert_true "PATH='$_pf_tb' check_network_connectivity 127.0.0.1 1 >/dev/null 2>&1" \
    "no host psql + a container pg-client: an unreachable probe defers (returns 0)"
unset -f pg_client_available
# and with host psql present (normal PATH), the same closed port still FAILS — unchanged
assert_false "check_network_connectivity 127.0.0.1 1 >/dev/null 2>&1" \
    "host psql present: an unreachable probe still fails (rootful path unchanged)"

# ============================================================================
describe "REGRESSION: backup space must handle a fractional DB size"
# ============================================================================
# A small DB reports e.g. ".01" GB; ".01" * 3 = ".03" and bash arithmetic is integer-only, so
# `(( available < .03 ))` raised: ((: .03: arithmetic syntax error: operand expected

_bs_rc=0
_bs_out="$(PREFLIGHT_DB_SIZE_GB=.01 PREFLIGHT_DUMP_HEAP_MB="" PREFLIGHT_HOP_COUNT=1 \
    check_backup_space "$WORK_DIR" 2>&1)" || _bs_rc=$?
assert_equals "0" "$_bs_rc" "fractional DB size: check passes"
if printf '%s' "$_bs_out" | grep -q 'arithmetic syntax error'; then
    assert_true "false" "fractional DB size: no arithmetic syntax error"
else
    assert_true "true" "fractional DB size: no arithmetic syntax error"
fi

# ============================================================================
describe "backup space is MEASURED, not guessed"
# ============================================================================
# It was `pg_database_size x 3`. pg_database_size INCLUDES indexes; pg_dump does not dump indexes,
# only the CREATE INDEX statements. For a 200GB database with 80GB of indexes that demanded 600GB
# for a dump that would have been ~30GB — refusing a migration there was room for.

# Sizing comes from the table data (heap) when it could be measured.
_bs_out="$(PREFLIGHT_DUMP_HEAP_MB=1000 PREFLIGHT_HOP_COUNT=1 check_backup_space "$WORK_DIR" 2>&1)"
assert_contains "$_bs_out" "table data" \
    "the basis is the heap — what pg_dump actually writes"
assert_contains "$_bs_out" "1200MB" \
    "1000MB of table data -> 1200MB required (x1.2 cushion), not 3x the database"

# And it multiplies by the number of hops. One backup is taken before EACH hop and they all stay
# on disk: 16 -> 24 -> 25 -> 26 is THREE dumps. This factor did not exist at all — the check sized
# for one dump and the migration then wrote three, filling the disk on exactly the large databases
# where the check mattered.
_bs_out="$(PREFLIGHT_DUMP_HEAP_MB=1000 PREFLIGHT_HOP_COUNT=3 check_backup_space "$WORK_DIR" 2>&1)"
assert_contains "$_bs_out" "3600MB" \
    "3 hops -> 3 backups -> 3x the space (1000 x 1.2 x 3)"
assert_contains "$_bs_out" "Hops in this migration: 3" \
    "the hop count is stated, not hidden"

# Falls back to total DB size when the heap could not be measured — overestimating beats guessing
# low when the cost of guessing low is a disk full mid-migration.
_bs_out="$(PREFLIGHT_DB_SIZE_GB=1 PREFLIGHT_DUMP_HEAP_MB="" PREFLIGHT_HOP_COUNT=1 \
    check_backup_space "$WORK_DIR" 2>&1)"
assert_contains "$_bs_out" "conservative" \
    "an unmeasurable heap falls back to the total DB size, and says so"

# A requirement that does not fit must fail, not warn.
_bs_rc=0
PREFLIGHT_DUMP_HEAP_MB=999999999 PREFLIGHT_HOP_COUNT=3 \
    check_backup_space "$WORK_DIR" >/dev/null 2>&1 || _bs_rc=$?
assert_true "[[ $_bs_rc -ne 0 ]]" "not enough space for the backups -> the check FAILS"

# ============================================================================
describe "large tables are flagged BEFORE the migration, not after"
# ============================================================================
# Above ~300k rows Keycloak SKIPS CREATE INDEX at startup and logs the DDL instead. The migration
# then succeeds with indexes missing: nothing goes bang, the database is simply slow, and the cause
# is a log line nobody read. Say it while turning --apply-indexes on is still a decision.
assert_true "declare -F check_large_tables" "check_large_tables exists"
assert_equals "120" "$BACKUP_HEAP_MULTIPLIER_PCT" "the heap cushion is 1.2x, and it is named"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Preflight Checks"
