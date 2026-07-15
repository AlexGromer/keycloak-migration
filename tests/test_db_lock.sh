#!/usr/bin/env bash
# Tests: ADR-011 — one migration per database (DB advisory lock) + per-database container isolation.
#
# The per-workspace file lock only catches a re-run from the same work dir. Two runs against the
# same database from different work dirs (or hosts) would migrate one schema concurrently and
# corrupt it. The database advisory lock closes that; unique per-database container names let runs
# against DIFFERENT databases proceed in parallel without colliding.
#
# The advisory-lock behaviour needs a real PostgreSQL. Point the test at one with
# KC_TESTDB_HOST/PORT/USER/PASS/NAME (defaults match the throwaway used in development); if none is
# reachable, those cases SKIP rather than fail — CI has no database.
#
# shellcheck disable=SC2030,SC2031  # PROFILE_* is set inside ( ) subshells ON PURPOSE, to isolate
#                                     each naming case; "the change might be lost" is exactly intended.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/container_runtime.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/deployment_adapter.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/db_lock.sh"

# ---------------------------------------------------------------------------
describe "per-database container names (isolation, not just detection)"
# Two migrations against DIFFERENT databases must get DIFFERENT transient container names, so one
# run's cleanup never removes the other's container.
(
    export PROFILE_KC_RUN_CONTAINER_NAME=""
    export PROFILE_DB_HOST=10.0.0.1 PROFILE_DB_PORT=5432 PROFILE_DB_NAME=keycloak
    name_a="$(kc_run_container_name 26.6.3)"
    export PROFILE_DB_HOST=10.0.0.2   # a different database host
    name_b="$(kc_run_container_name 26.6.3)"

    assert_true "[[ '$name_a' == kc-migrate-26.6.3-* ]]" \
        "name carries the version and a db token"
    assert_true "[[ '$name_a' != '$name_b' ]]" \
        "different databases -> different container names (parallel-safe)"

    # Same database -> same name (deterministic; the DB lock serialises those anyway).
    export PROFILE_DB_HOST=10.0.0.1
    name_a2="$(kc_run_container_name 26.6.3)"
    assert_equals "$name_a" "$name_a2" "same database -> same name, every time"

    # Still globbable by the leftover-container scan.
    assert_true "[[ '$name_a' == kc-migrate-* ]]" "still matches the kc-migrate-* cleanup glob"
)

# An explicit override wins (this is how the harness pins its own names).
(
    export PROFILE_KC_RUN_CONTAINER_NAME="my-fixed-name"
    export PROFILE_DB_HOST=10.0.0.1 PROFILE_DB_PORT=5432 PROFILE_DB_NAME=keycloak
    assert_equals "my-fixed-name" "$(kc_run_container_name 26.6.3)" \
        "PROFILE_KC_RUN_CONTAINER_NAME overrides the computed name"
)

# ---------------------------------------------------------------------------
describe "the DB lock degrades safely when it cannot run"
assert_true "declare -F kc_db_lock_acquire"  "kc_db_lock_acquire defined"
assert_true "declare -F kc_db_lock_release"  "kc_db_lock_release defined"

# No psql on PATH -> fall back to the file lock (return 0), never hard-block a migration. The empty
# PATH is scoped to the single function call, so the rest of the test (and rm) keep their tools.
_fakebin="$(mktemp -d)"
assert_true "PATH='$_fakebin' kc_db_lock_acquire >/dev/null 2>&1" \
    "with no psql, the lock degrades to the file lock (returns 0, does not block)"
rm -rf "$_fakebin"

# The EXIT/interrupt path releases BOTH locks.
assert_true "declare -F _kc_release_all_locks || grep -q '_kc_release_all_locks' '$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh'" \
    "a combined release frees the file lock and the DB lock together" 2>/dev/null || \
assert_true "grep -q 'kc_db_lock_release' '$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh'" \
    "the DB lock is released on exit"

# ---------------------------------------------------------------------------
describe "the DB advisory lock actually excludes a second run (needs a real PG)"
_H="${KC_TESTDB_HOST:-127.0.0.1}"; _P="${KC_TESTDB_PORT:-5434}"
_U="${KC_TESTDB_USER:-keycloak}"; _PW="${KC_TESTDB_PASS:-locktest}"; _N="${KC_TESTDB_NAME:-keycloak}"

if command -v psql >/dev/null 2>&1 && \
   PGPASSWORD="$_PW" psql -h "$_H" -p "$_P" -U "$_U" -d "$_N" -tAc "SELECT 1;" >/dev/null 2>&1; then

    export PROFILE_DB_HOST="$_H" PROFILE_DB_PORT="$_P" PROFILE_DB_USER="$_U" \
           PROFILE_DB_PASSWORD="$_PW" PROFILE_DB_NAME="$_N"

    # A "foreign" migration holds the lock via its own connection.
    coproc _FOREIGN { PGPASSWORD="$_PW" psql -h "$_H" -p "$_P" -U "$_U" -d "$_N" -Atq; }
    printf "SELECT pg_try_advisory_lock(hashtext('kc-migrate:'||current_database()))::text;\n" >&"${_FOREIGN[1]}"
    read -r -t 10 _fg <&"${_FOREIGN[0]}" || true
    assert_equals "true" "$_fg" "the foreign holder took the lock"

    # Our acquire must be REFUSED (return 1), not blocked, not falsely granted.
    assert_false "kc_db_lock_acquire >/dev/null 2>&1" \
        "a second run against the same DB is refused (return 1)"

    # Foreign releases (close its connection) -> the lock is free again (auto-release).
    kill "${_FOREIGN_PID}" 2>/dev/null || true
    sleep 1
    assert_true "kc_db_lock_acquire >/dev/null 2>&1" \
        "after the holder's connection drops, the lock is acquirable again (auto-release)"
    # And releasing ours frees it too.
    kc_db_lock_release
    assert_equals "false" "$_KC_DBLOCK_HELD" "release clears the held flag"
else
    skip_test "no reachable PostgreSQL (set KC_TESTDB_* to enable the advisory-lock cases)"
fi

test_report
