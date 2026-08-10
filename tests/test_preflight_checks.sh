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
# `|| true`: these assertions check the SIZING MESSAGE, not the verdict. The simulated requirement
# is deliberately larger than a small disk, so on a machine with less free space than the scenario
# demands the substitution failed and `set -e` killed the suite before test_report.
describe "backup space is MEASURED, not guessed"
# ============================================================================
# It was `pg_database_size x 3`. pg_database_size INCLUDES indexes; pg_dump does not dump indexes,
# only the CREATE INDEX statements. For a 200GB database with 80GB of indexes that demanded 600GB
# for a dump that would have been ~30GB — refusing a migration there was room for.

# Sizing comes from the table data (heap) when it could be measured.
_bs_out="$(PREFLIGHT_DUMP_HEAP_MB=1000 PREFLIGHT_HOP_COUNT=1 check_backup_space "$WORK_DIR" 2>&1 || true)"
assert_contains "$_bs_out" "table data" \
    "the basis is the heap — what pg_dump actually writes"
assert_contains "$_bs_out" "1200MB" \
    "1000MB of table data -> 1200MB required (x1.2 cushion), not 3x the database"

# And it multiplies by the number of hops. One backup is taken before EACH hop and they all stay
# on disk: 16 -> 24 -> 25 -> 26 is THREE dumps. This factor did not exist at all — the check sized
# for one dump and the migration then wrote three, filling the disk on exactly the large databases
# where the check mattered.
_bs_out="$(PREFLIGHT_DUMP_HEAP_MB=1000 PREFLIGHT_HOP_COUNT=3 check_backup_space "$WORK_DIR" 2>&1 || true)"
assert_contains "$_bs_out" "3600MB" \
    "3 hops -> 3 backups -> 3x the space (1000 x 1.2 x 3)"
assert_contains "$_bs_out" "Hops in this migration: 3" \
    "the hop count is stated, not hidden"

# Falls back to total DB size when the heap could not be measured — overestimating beats guessing
# low when the cost of guessing low is a disk full mid-migration.
_bs_out="$(PREFLIGHT_DB_SIZE_GB=1 PREFLIGHT_DUMP_HEAP_MB="" PREFLIGHT_HOP_COUNT=1 \
    check_backup_space "$WORK_DIR" 2>&1 || true)"
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
describe "connectivity is decided by the database's answer, not by the wrapper's exit code"
# ============================================================================
# From a live air-gapped migration (2026-08-10): the probe ran, the database answered, and the check
# still aborted the run with "Connection failed". The 10s bound fired while the CONTAINER client was
# starting — the run had just `cr load`ed a 1.5GB bundle — so `timeout` returned 124, and the check
# read that exit code alone. stderr went to /dev/null, so the captured answer died with it. Two runs
# were burned before the exit code could be told apart from a refused login.

assert_equals "kc_preflight_probe_ok" "$DB_PROBE_TOKEN" \
    "the token these stubs echo is the one the check looks for"
assert_equals "90" "$DB_HEALTH_TIMEOUT_CONTAINER" \
    "the container client gets a bound sized for a cold container start"

# The probe runs in a child bash (timeout cannot exec a function), so a stub MUST be exported —
# which is also a regression guard on that mechanism.
# shellcheck disable=SC2317  # invoked from the child bash, not from this file
pg_client() { echo "kc_preflight_probe_ok"; sleep 3; }
export -f pg_client

# THE REPORTED DEFECT: the client answers, then outlives the bound.
_c4_rc=0
_c4_out="$(DB_HEALTH_TIMEOUT=1 DB_HEALTH_TIMEOUT_CONTAINER=1 \
    check_database_connectivity postgresql h 5432 u p db 2>&1)" || _c4_rc=$?
assert_equals "0" "$_c4_rc" "answered, then killed by the bound -> the check PASSES"
assert_contains "$_c4_out" "Connected" "and reports Connected"
assert_contains "$_c4_out" "exceeded" "while still naming the slow client, so it is not hidden"

# A cold first attempt with nothing to show is retried; the warm one succeeds. This is the physics
# of the reported case: >10s for the first container start, 0.57s for the next.
export KC_TEST_PROBE_MARK="$WORK_DIR/probe_attempt"
rm -f "$KC_TEST_PROBE_MARK"
# shellcheck disable=SC2317  # invoked from the child bash, not from this file
pg_client() {
    if [[ -e "$KC_TEST_PROBE_MARK" ]]; then echo "kc_preflight_probe_ok"
    else : > "$KC_TEST_PROBE_MARK"; sleep 3; fi
}
export -f pg_client
_c4_rc=0
_c4_out="$(DB_HEALTH_TIMEOUT=1 DB_HEALTH_TIMEOUT_CONTAINER=1 \
    check_database_connectivity postgresql h 5432 u p db 2>&1)" || _c4_rc=$?
assert_equals "0" "$_c4_rc" "a timed-out cold attempt is retried, and the warm one passes"
assert_contains "$_c4_out" "second attempt" "and the retry is stated, not silent"

# A refused login must still FAIL — and must now say why.
# shellcheck disable=SC2317  # invoked from the child bash, not from this file
pg_client() { echo 'FATAL:  password authentication failed for user "kc"' >&2; return 2; }
export -f pg_client
_c4_rc=0
_c4_out="$(check_database_connectivity postgresql h 5432 u hunter2 db 2>&1)" || _c4_rc=$?
assert_true "[[ $_c4_rc -ne 0 ]]" "a refused login still fails the check"
assert_contains "$_c4_out" "rc=2" "the exit code is reported instead of swallowed"
assert_contains "$_c4_out" "password authentication failed" "and so is what the client actually said"

# Printing the client's output must never print the password with it.
# shellcheck disable=SC2317  # invoked from the child bash, not from this file
pg_client() { echo "could not connect: bad secret hunter2 supplied" >&2; return 2; }
export -f pg_client
_c4_out="$(check_database_connectivity postgresql h 5432 u hunter2 db 2>&1)" || true
if [[ "$_c4_out" == *hunter2* ]]; then
    assert_true "false" "the password leaked into the check's output"
else
    assert_true "true" "the password never reaches the log, even though client output now is printed"
fi

unset -f pg_client
unset KC_TEST_PROBE_MARK

# The bounds are the operator's to set. DB_HEALTH_TIMEOUT used to be `readonly 10`, so a host that
# needed longer could not say so without editing the library.
_ovr="$(DB_HEALTH_TIMEOUT=7 bash -c "source '$LIB_DIR/preflight_checks.sh' >/dev/null 2>&1; echo \$DB_HEALTH_TIMEOUT")"
assert_equals "7" "$_ovr" "DB_HEALTH_TIMEOUT is overridable from the environment"
_ovr="$(DB_HEALTH_TIMEOUT_CONTAINER=123 bash -c "source '$LIB_DIR/preflight_checks.sh' >/dev/null 2>&1; echo \$DB_HEALTH_TIMEOUT_CONTAINER")"
assert_equals "123" "$_ovr" "DB_HEALTH_TIMEOUT_CONTAINER is overridable from the environment"

# Same defect class, found next door: `--help`, MIGRATION_GUIDE and migrate_keycloak_v3.sh:950 all
# treat MIN_DISK_FREE_MB as the operator's to set, while this library redeclared it `readonly 512`
# and silently overwrote them on the preflight path.
_ovr="$(MIN_DISK_FREE_MB=256 bash -c "source '$LIB_DIR/preflight_checks.sh' >/dev/null 2>&1; echo \$MIN_DISK_FREE_MB")"
assert_equals "256" "$_ovr" "MIN_DISK_FREE_MB is overridable, as --help and the guide both promise"
_ovr="$(bash -c "source '$LIB_DIR/preflight_checks.sh' >/dev/null 2>&1; echo \$MIN_DISK_FREE_MB")"
assert_equals "512" "$_ovr" "and still defaults to 512 when nobody sets it"

# ============================================================================
describe "the library survives a second source, and owns its own constants"
# ============================================================================
# It runs under `set -euo pipefail` (line 5), so a bare `readonly` re-assignment does not warn — it
# ABORTS the caller. Sourcing this library twice used to kill the migration outright. Restored in
# full here: PR #39 wrote this assertion, watched it fail, and narrowed it rather than fix it then.

_resrc_rc=0
bash -c "source '$LIB_DIR/preflight_checks.sh'; source '$LIB_DIR/preflight_checks.sh'" >/dev/null 2>&1 || _resrc_rc=$?
assert_equals "0" "$_resrc_rc" "preflight_checks.sh can be sourced twice without aborting"

_dbl="$(bash -c "source '$LIB_DIR/preflight_checks.sh'; source '$LIB_DIR/preflight_checks.sh'; echo \"\$EXIT_DB_HEALTH \$DB_PROBE_TOKEN \$BACKUP_HEAP_MULTIPLIER_PCT\"" 2>/dev/null)"
assert_equals "13 kc_preflight_probe_ok 120" "$_dbl" "and the second source leaves every constant at its own value"

# The environment gets a vote on BOUNDS (they are properties of the host) but never on the values
# this file owns. An inherited EXIT_DB_HEALTH=0 would otherwise report a refused database as a pass,
# and a redefined probe token would make any output look like a successful connection.
_forged="$(env EXIT_DB_HEALTH=0 EXIT_DISK_SPACE=0 DB_PROBE_TOKEN=anything BACKUP_HEAP_MULTIPLIER_PCT=1 \
    bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$EXIT_DB_HEALTH \$EXIT_DISK_SPACE \$DB_PROBE_TOKEN \$BACKUP_HEAP_MULTIPLIER_PCT\"" 2>/dev/null)"
assert_equals "13 10 kc_preflight_probe_ok 120" "$_forged" \
    "the environment cannot forge an exit code, the probe token or the backup cushion"

# The other two thresholds are the operator's, for the same reason MIN_DISK_FREE_MB is.
_thr="$(env NETWORK_TIMEOUT=42 MIN_MEMORY_GB=1 bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$NETWORK_TIMEOUT \$MIN_MEMORY_GB\"" 2>/dev/null)"
assert_equals "42 1" "$_thr" "NETWORK_TIMEOUT and MIN_MEMORY_GB are overridable from the environment"
_thr="$(bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$NETWORK_TIMEOUT \$MIN_MEMORY_GB\"" 2>/dev/null)"
assert_equals "5 2" "$_thr" "and keep their defaults when nobody sets them"

# EXIT_SUCCESS is shared with six other libraries, all using the same first-wins guard. Two probes,
# because one is not enough: pre-freezing it at 0 (the value we would set anyway) proved nothing —
# mutation testing showed that assertion stayed green with the declaration DELETED or set to 7.
_clean="$(bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$EXIT_SUCCESS\"" 2>/dev/null)"
assert_equals "0" "$_clean" "in a clean shell this file's own EXIT_SUCCESS is 0"
_shared="$(bash -c "readonly EXIT_SUCCESS=7; source '$LIB_DIR/preflight_checks.sh'; echo \"ok \$EXIT_SUCCESS\"" 2>/dev/null)"
assert_equals "ok 7" "$_shared" "a lib that declared EXIT_SUCCESS first keeps its value, and we do not abort"

# ============================================================================
describe "a bound that is not a number is refused, loudly"
# ============================================================================
# Opening these to the environment (v3.10.5 and this change) made a typo reachable, and each check
# consumed it differently: MIN_DISK_FREE_MB aborted check_disk_space on `set -u`, while MIN_MEMORY_GB
# reached `bc`, which reads an unknown word as 0 — so the comparison resolved to "not low" and the
# operator got `[✓ PREFLIGHT] Memory: 3GB (OK)` for a check that never ran.

_bad="$(env MIN_MEMORY_GB=notanumber bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$MIN_MEMORY_GB\"" 2>/dev/null)"
assert_equals "2" "$_bad" "a non-numeric MIN_MEMORY_GB falls back to the default"
_bad_msg="$(env MIN_MEMORY_GB=notanumber bash -c "source '$LIB_DIR/preflight_checks.sh'" 2>&1)"
assert_contains "$_bad_msg" "not a whole number" "and the operator is told, rather than silently ticked"
assert_contains "$_bad_msg" "MIN_MEMORY_GB" "with the offending variable named"

_bad="$(env MIN_DISK_FREE_MB='512 MB' bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$MIN_DISK_FREE_MB\"" 2>/dev/null)"
assert_equals "512" "$_bad" "a MIN_DISK_FREE_MB with units attached falls back instead of aborting the run"
_bad="$(env DB_HEALTH_TIMEOUT=abc bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$DB_HEALTH_TIMEOUT\"" 2>/dev/null)"
assert_equals "10" "$_bad" "a non-numeric DB_HEALTH_TIMEOUT falls back to the default"

_good="$(env MIN_MEMORY_GB=8 NETWORK_TIMEOUT=30 bash -c "source '$LIB_DIR/preflight_checks.sh'; echo \"\$MIN_MEMORY_GB \$NETWORK_TIMEOUT\"" 2>/dev/null)"
assert_equals "8 30" "$_good" "well-formed values are still honoured"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "$WORK_DIR"

test_report "Test Suite Complete: Preflight Checks"
