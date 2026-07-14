#!/usr/bin/env bash
# Tests: ADR-008 — state reconciliation. The tool must decide from the ACTUAL state (database +
# containers), not from checkpoints / the profile's claimed current_version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

export WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"

describe "ADR-008: hops already applied by the DB are skipped"
# The payoff of reconciliation: feed the REAL db version into the path builder and the hops the
# database has already passed drop out — a restart does not redo them.
assert_equals "24.0.5 26.6.3" "$(kc_build_migration_path 16.1.1 26)" \
    "from a fresh 16.1.1 DB: both hops"
assert_equals "26.6.3" "$(kc_build_migration_path 24.0.5 26)" \
    "DB already at 24.0.5: only 26.6.3 remains (hop 1 skipped)"
assert_equals "25.0.6" "$(kc_build_migration_path 16.1.1 25)" \
    "target 25: single hop"
assert_false "kc_build_migration_path 26.6.3 26 2>/dev/null" \
    "DB already at target: no path (nothing to do)"

describe "ADR-008: major.minor comparison used for 'already at target'"
assert_equals "26.6" "$(_kc_major_minor 26.6.3)" "26.6.3 -> 26.6"
assert_equals "24.0" "$(_kc_major_minor 24.0.5)" "24.0.5 -> 24.0"
assert_equals "16.1" "$(_kc_major_minor 16.1.1)" "16.1.1 -> 16.1"

describe "ADR-008: reconciliation primitives exist and degrade gracefully"
assert_true  "declare -F kc_reconcile_state"        "kc_reconcile_state defined"
assert_true  "declare -F kc_db_model_version"       "kc_db_model_version defined"
assert_true  "declare -F kc_db_changelog_locked"    "kc_db_changelog_locked defined"
assert_true  "declare -F kc_db_clear_changelog_lock" "kc_db_clear_changelog_lock defined"

# With no reachable database, the version read must FAIL (not invent a version) so the caller
# falls back to the profile's claim instead of silently mis-computing the hop chain.
PROFILE_DB_HOST=127.0.0.1 PROFILE_DB_PORT=1 PROFILE_DB_NAME=nope PROFILE_DB_USER=nope \
    assert_false "kc_db_model_version" "unreachable DB: version read fails (does not fabricate)"

describe "ADR-008: --force-unlock and --no-resume are wired"
MV="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"
assert_true "bash '$MV' --help 2>&1 | grep -q 'force-unlock'" "usage documents --force-unlock"
assert_true "bash '$MV' --help 2>&1 | grep -q 'no-resume'"    "usage documents --no-resume"
assert_true "grep -q 'FORCE_UNLOCK=true' '$MV'"               "--force-unlock sets FORCE_UNLOCK"
assert_true "grep -q 'databasechangeloglock' '$PROJECT_ROOT/scripts/lib/migration_verify.sh'" \
    "Liquibase changelog lock is actually checked"

test_report
