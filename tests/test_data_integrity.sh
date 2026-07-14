#!/usr/bin/env bash
# Tests: Layer 3 — does the DATA survive the hop?
#
# L1 (DATABASECHANGELOG) proves the changesets ran. L2 (MIGRATION_MODEL) proves the realm migration
# ran. Neither says a word about whether your realms, users and clients are still there afterwards:
# a hop that emptied user_entity passed every check the tool had and reported complete success.
#
# The policy already existed — in the HARNESS, guarding the synthetic runs only. These tests cover
# its promotion to scripts/lib/data_integrity.sh and its wiring into the real migration path.
#
# shellcheck disable=SC2016  # Single-quoted needles are LITERALS: these assertions grep the source
# for exact code text. Expanding them would search for the value instead of the code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

WORK_DIR="$(mktemp -d)"
export WORK_DIR
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

MAIN="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"

# shellcheck source=/dev/null
source "$MAIN"

# ---------------------------------------------------------------------------
describe "the integrity policy: what may change, and what may not"
# A migration ADDS default clients (account-console, admin-cli, security-admin-console) and default
# roles. It never removes a realm or a user. Hence: eq for realm/user_entity, gte for client/role.

assert_true  "_kc_integrity_eval realm eq 3 3 >/dev/null 2>&1" \
    "realm unchanged -> holds"
assert_false "_kc_integrity_eval realm eq 3 2 >/dev/null 2>&1" \
    "a realm VANISHED -> violation"
assert_false "_kc_integrity_eval realm eq 3 4 >/dev/null 2>&1" \
    "a realm APPEARED -> also a violation (a migration does not invent realms)"

assert_true  "_kc_integrity_eval user_entity eq 150 150 >/dev/null 2>&1" \
    "users unchanged -> holds"
assert_false "_kc_integrity_eval user_entity eq 150 149 >/dev/null 2>&1" \
    "ONE user lost -> violation (this is the case that must never pass silently)"

assert_true  "_kc_integrity_eval client gte 30 33 >/dev/null 2>&1" \
    "clients grew -> holds (the migration adds its defaults)"
assert_true  "_kc_integrity_eval client gte 30 30 >/dev/null 2>&1" \
    "clients unchanged -> holds"
assert_false "_kc_integrity_eval client gte 30 29 >/dev/null 2>&1" \
    "clients SHRANK -> violation"

assert_true  "_kc_integrity_eval keycloak_role gte 41 44 >/dev/null 2>&1" \
    "roles grew -> holds"
assert_false "_kc_integrity_eval keycloak_role gte 41 38 >/dev/null 2>&1" \
    "roles shrank -> violation"

assert_false "_kc_integrity_eval realm bogus 3 3 >/dev/null 2>&1" \
    "an unknown policy fails closed rather than passing"

# ---------------------------------------------------------------------------
describe "the baseline is taken once, from the state we started in"
# Re-baselining per hop would forgive cumulative loss: hop 2 could delete what hop 1 left behind
# and still 'match its baseline'. So the baseline file is written once and never overwritten.
baseline="$WORK_DIR/data_baseline.env"

printf 'DI_ENABLED=true\nDI_BASE_realm=2\nDI_BASE_user_entity=3\nDI_BASE_client=14\nDI_BASE_keycloak_role=41\n' \
    > "$baseline"

DRY_RUN=false kc_data_baseline >/dev/null 2>&1
assert_contains "$(cat "$baseline")" "DI_BASE_realm=2" \
    "an existing baseline is NOT overwritten by a later hop"

# A database Keycloak has never touched has no realm table. That is 'nothing to protect yet',
# not a failure — record it and no-op, rather than asserting 0 == 0 and calling it verified.
rm -f "$baseline"
# shellcheck disable=SC2329  # invoked indirectly — kc_data_baseline calls it through _di_count
_mv_psql() { printf ''; }   # simulate: no reachable DB / no realm table
DRY_RUN=false kc_data_baseline >/dev/null 2>&1
assert_contains "$(cat "$baseline")" "DI_ENABLED=false" \
    "an uninitialised database disables the checks instead of faking them"
assert_true "DRY_RUN=false kc_data_verify 26.6.3 >/dev/null 2>&1" \
    "and verification then no-ops rather than failing"
unset -f _mv_psql

# A dry run captures nothing and asserts nothing.
rm -f "$baseline"
assert_true "DRY_RUN=true kc_data_baseline >/dev/null 2>&1" "dry-run baseline is a no-op"
assert_true "[[ ! -f '$baseline' ]]" "dry-run writes no baseline file"

# ---------------------------------------------------------------------------
describe "Layer 3 is wired into the real migration, not just the harness"
# The whole point of the promotion: this policy used to guard synthetic runs ONLY.

assert_equals "1" "$(grep -cF 'source "$LIB_DIR/data_integrity.sh"' "$MAIN" || true)" \
    "the migration script sources the Layer 3 module"

# Baseline before the hops; verification after the L2 gate. Exactly one CALL site (the other hit is
# the `declare -F` availability guard around it).
assert_equals "1" "$(grep -cE '^ +kc_data_baseline$' "$MAIN" || true)" \
    "the baseline is captured at exactly one place, before any hop runs"

step6c="$(sed -n '/# Step 6c: AUTHORITATIVE Layer 3 gate/,/# Step 6d/p' "$MAIN")"
assert_contains "$step6c" "kc_data_verify" \
    "every hop is verified against the baseline"
assert_contains "$step6c" "_kc_offer_rollback" \
    "a data-integrity violation offers the rollback (it is a real failure, unlike a health 404)"

# ---------------------------------------------------------------------------
describe "the harness delegates instead of keeping its own copy"
# Two implementations of the same policy would drift, and the one guarding production would be the
# one nobody looked at.
harness_lib="$PROJECT_ROOT/scripts/harness/lib/harness_integrity.sh"
assert_contains "$(cat "$harness_lib")" "_kc_integrity_eval" \
    "the harness calls the shared evaluator"
assert_equals "0" "$(grep -c 'SELECT COUNT' "$harness_lib" || true)" \
    "the harness no longer carries its own SQL"

# ---------------------------------------------------------------------------
describe "backup restore test: proving a backup, not hoping"
# pg_restore --list | grep -c "TABLE DATA" proves the dump's TOC parses. It does not prove the dump
# restores, and says nothing about what is in it.

assert_true "declare -F kc_backup_restore_test" "kc_backup_restore_test exists"

# Opt-in: it costs a full restore's time and disk.
assert_true "PROFILE_VERIFY_BACKUP_RESTORE=false kc_backup_restore_test /nonexistent >/dev/null 2>&1" \
    "off by default — does not touch a thing"
assert_false "PROFILE_VERIFY_BACKUP_RESTORE=true DRY_RUN=false kc_backup_restore_test /nonexistent/x.dump >/dev/null 2>&1" \
    "when enabled, a missing backup file is a failure"
assert_true "PROFILE_VERIFY_BACKUP_RESTORE=true DRY_RUN=true kc_backup_restore_test /nonexistent/x.dump >/dev/null 2>&1" \
    "a dry run restores nothing"

di_src="$PROJECT_ROOT/scripts/lib/data_integrity.sh"
assert_contains "$(cat "$di_src")" "DROP DATABASE IF EXISTS" \
    "the scratch database is dropped — a stray copy of production is not a souvenir"
assert_contains "$(cat "$di_src")" "the backup is SHORT" \
    "row counts are compared against the source, not just 'did pg_restore exit 0'"

# A backup that will not restore must stop the migration before it starts.
assert_equals "1" "$(grep -cF 'Refusing to migrate behind a backup that will not restore' "$MAIN" || true)" \
    "a failed restore-test aborts the migration"

# ---------------------------------------------------------------------------
describe "verify: the acceptance test the tool never had"
# The migration leaves NO running Keycloak (the transient container is removed after the last hop),
# so 'is the result any good' previously had no answer.

assert_true "declare -F cmd_verify"               "the verify subcommand exists"
assert_true "declare -F kc_run_verify_container"  "it boots a container of its own"

verify_src="$(sed -n '/^cmd_verify()/,/^}/p' "$MAIN")"
assert_contains "$verify_src" "kc_verify_migration_model" "verify checks L2 (from the host, first)"
assert_contains "$verify_src" "kc_data_verify"            "verify checks L3 (data integrity)"
assert_contains "$verify_src" "smoke_test.sh"             "verify exercises the Admin API"
assert_contains "$verify_src" "kc_run_stop_container"     "verify removes its container afterwards"

# Without admin credentials the Admin API cannot be exercised. Say what was NOT checked rather than
# implying it passed — KC_BOOTSTRAP_ADMIN_* only creates an admin on a database that has none, and
# a migrated database has plenty.
assert_contains "$verify_src" "NOT verified" \
    "missing admin credentials are reported honestly, not silently skipped"

# The container it boots is the one that DID the migration, with health actually switched on —
# unlike the migrating boot, whose missing KC_HEALTH_ENABLED is the root of ADR-009.
adapter_src="$(sed -n '/^kc_run_verify_container()/,/^}/p' "$PROJECT_ROOT/scripts/lib/deployment_adapter.sh")"
assert_contains "$adapter_src" "KC_HEALTH_ENABLED=true" \
    "the verify container serves health (the migrating one never did)"
assert_contains "$adapter_src" "dist_image_ref" \
    "it boots the SAME sovereign image that performed the migration"

test_report
