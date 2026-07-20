#!/usr/bin/env bash
# Tests: Migration Verification (Layer 2 — MIGRATION_MODEL)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/migration_verify.sh"

# ----------------------------------------------------------------------------
# psql stub: echo a fixed MIGRATION_MODEL version regardless of the query.
# Overriding psql as a shell function satisfies `command -v psql` and the
# `_mv_psql` invocation inside migration_verify.sh.
# ----------------------------------------------------------------------------
psql() { echo "26.6.3"; }

# ============================================================================
describe "kc_verify_migration_model()"
# ============================================================================

assert_true  "kc_verify_migration_model 26.6.3" \
    "exact version match returns 0"

assert_true  "kc_verify_migration_model 26.6.10" \
    "patch-level difference still matches on major.minor"

assert_false "kc_verify_migration_model 25.0.0 2>/dev/null" \
    "major.minor mismatch returns non-zero"

assert_false "kc_verify_migration_model '' 2>/dev/null" \
    "missing expected version returns non-zero"

# ============================================================================
describe "kc_check_skipped_indexes()"
# ============================================================================

assert_false "kc_check_skipped_indexes '' 2>/dev/null" \
    "missing log file argument returns non-zero"

assert_false "kc_check_skipped_indexes /nonexistent/kc.log 2>/dev/null" \
    "nonexistent log file returns non-zero"

# Build a fake KC startup log with a deferred (skipped) index DDL.
WORK_DIR="$(mktemp -d)"
export WORK_DIR
fake_log="$WORK_DIR/kc_startup.log"
{
    echo "INFO  [io.quarkus] Keycloak 26.6.3 started"
    echo "WARN  [org.keycloak] The index IDX_USER_ATTR was not created on table USER_ATTRIBUTE because it has more than 300000 records. CREATE INDEX IDX_USER_ATTR ON USER_ATTRIBUTE (NAME);"
} >"$fake_log"

assert_true "kc_check_skipped_indexes '$fake_log' 26.6.3" \
    "scanning a log with a skipped index returns 0"

assert_file_exists "$WORK_DIR/skipped_indexes_26.6.3.sql" \
    "skipped-index SQL file is written"

assert_contains "$(cat "$WORK_DIR/skipped_indexes_26.6.3.sql")" \
    "CREATE INDEX IDX_USER_ATTR" \
    "captured DDL contains the deferred CREATE INDEX"

# Dedup: Keycloak logs each skipped index from TWO subsystems
# (CustomCreateIndexChange during migration + DatabaseIndexChecker at startup),
# so the same CREATE INDEX must be captured only once.
dup_log="$WORK_DIR/kc_startup_dup.log"
{
    echo "WARN [CustomCreateIndexChange] Following index should be created: CREATE INDEX IDX_DUP ON public.USER_ENTITY(REALM_ID, CREATED_TIMESTAMP);"
    echo "WARN [DatabaseIndexChecker] Missing database index IDX_DUP on table USER_ENTITY. Create the index manually: CREATE INDEX IDX_DUP ON public.USER_ENTITY(REALM_ID, CREATED_TIMESTAMP);"
} >"$dup_log"
kc_check_skipped_indexes "$dup_log" dup >/dev/null 2>&1
assert_equals "1" "$(grep -c 'CREATE INDEX IDX_DUP' "$WORK_DIR/skipped_indexes_dup.sql")" \
    "the same skipped index logged twice (two KC subsystems) is captured once"

# _mv_to_concurrent rewrites to the idempotent, non-blocking form.
assert_equals "CREATE INDEX CONCURRENTLY IF NOT EXISTS IDX_X ON T (A);" \
    "$(_mv_to_concurrent 'CREATE INDEX IDX_X ON T (A);')" \
    "plain CREATE INDEX becomes CONCURRENTLY IF NOT EXISTS"
assert_equals "CREATE INDEX CONCURRENTLY IF NOT EXISTS IDX_X ON T (A);" \
    "$(_mv_to_concurrent 'CREATE INDEX CONCURRENTLY IF NOT EXISTS IDX_X ON T (A);')" \
    "already-idempotent statement is left unchanged"

rm -rf "$WORK_DIR"

# ============================================================================
test_report
