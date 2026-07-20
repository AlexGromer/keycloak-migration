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

describe "REGRESSION: a DRY RUN must mutate nothing, and a RUNNING container is untouchable"
# An earlier version of the leftover-cleanup ran `docker rm -f` on ANY kc-migrate-* container —
# even from a --dry-run process, and even when the container was RUNNING. A test-suite dry run
# therefore destroyed a live migration container mid-Liquibase on a real host. Both guards below
# must hold forever.
MV="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"
assert_true "grep -q 'A DRY RUN MUST MUTATE NOTHING' '$MV'" \
    "dry-run guard present in the leftover cleanup"
assert_true "grep -q 'A migration container is RUNNING' '$MV'" \
    "running containers are refused, never removed"
assert_true "grep -q 'DRY-RUN: would remove the stopped leftovers' '$MV'" \
    "dry-run only REPORTS what it would remove"
# The stale-lock release is an UPDATE — it must also be blocked in dry-run.
assert_true "grep -q 'DRY-RUN: would NOT release the lock' '$MV'" \
    "dry-run never releases the Liquibase lock"

describe "REGRESSION: single-instance lock prevents two runs killing each other"
assert_true "declare -F _kc_acquire_lock"  "_kc_acquire_lock defined"
assert_true "declare -F _kc_release_lock"  "_kc_release_lock defined"
_lockdir="$(mktemp -d)"
printf '%s' "$$" > "$_lockdir/migration.lock"          # a definitely-alive PID
assert_false "MIGRATION_LOCK_FILE='$_lockdir/migration.lock' _kc_acquire_lock >/dev/null 2>&1" \
    "refuses to start while another migration holds the lock"
printf '%s' "999999" > "$_lockdir/migration.lock"      # a definitely-dead PID
assert_true "MIGRATION_LOCK_FILE='$_lockdir/migration.lock' _kc_acquire_lock >/dev/null 2>&1" \
    "reclaims a stale lock from a dead process"
rm -rf "$_lockdir"

describe "REGRESSION: the EXIT trap removes a transient container left by a FAILED hop"
# A hop that fails at wait/L2/L3/health returns before the normal end-of-hop stop, so the transient
# kc-migrate-<v>-<token> container used to keep running (only the happy path and Ctrl-C removed it).
# The EXIT handler now cleans up whatever _KC_ACTIVE_RUN_CONTAINER still names.
assert_true "declare -F _kc_release_all_locks" "_kc_release_all_locks defined"
_stopped=""
# shellcheck disable=SC2329  # invoked indirectly by _kc_release_all_locks
kc_run_stop_container() { _stopped="$1"; }   # stub: record what would be removed
export MIGRATION_LOCK_FILE="$(mktemp -u)"    # a lock path that does not exist -> release is a no-op
_KC_ACTIVE_RUN_CONTAINER="kc-migrate-26.6.3-deadbeef"
_kc_release_all_locks
assert_equals "kc-migrate-26.6.3-deadbeef" "$_stopped" \
    "the EXIT handler stops the still-live transient container"
assert_empty "${_KC_ACTIVE_RUN_CONTAINER}" \
    "and clears the tracker so it is not stopped twice"
unset -f kc_run_stop_container

describe "REGRESSION: competing-process detection has no FALSE POSITIVES"
# The old scan was `pgrep -f 'migrate_..._v3\.sh|migrate_oneshot\.sh'` plus a PPID-ancestry walk.
# It flagged a lone run as its own competitor and REFUSED TO START, because:
#   (a) pgrep -f matched any command line MENTIONING the script — the launching `zsh -c '...'`
#       wrapper, a `grep`, an editor — not only real invocations, and
#   (b) the ancestry walk broke when the launcher was reparented to init (detached shell/pipeline),
#       so the real launcher was never excluded, and
#   (c) the scan runs inside a `$(...)` subshell whose argv is the script's own — a pid that is NOT
#       $$ — so it detected ITSELF.
# A lone invocation must report zero competitors.
assert_true "declare -F kc_find_other_migration_procs" "detector defined"
assert_true "declare -F _kc_proc_runs_migration"       "argv-precise matcher defined"

# Called here (inside the test's own bash, whose argv is the TEST script — not a migration script),
# there is no migration process at all, so it must find none.
assert_false "kc_find_other_migration_procs >/dev/null 2>&1" \
    "a lone run finds no competitor (was: flagged its own subshell/launcher and aborted)"

# Exclusion is by PROCESS GROUP now (not a $$/$BASHPID list): the DB-lock coproc is a bash wrapper
# that inherits our argv with a pid that is neither, and it re-broke the scan until we switched to
# pgid. The code must exclude by pgid, and must not call pgrep (comments about the old way are fine).
assert_true "grep -q 'my_pgid' '$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh'" \
    "the scan excludes our whole process group (pgid), not just individual pids"
assert_equals "0" \
    "$(grep -vE '^\s*#' "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" | grep -c 'pgrep' || true)" \
    "the substring-matching pgrep scan is gone from the code"

# A coproc in OUR process group, with our argv, must NOT be flagged — this is the exact shape of the
# DB-lock coproc that re-broke the scan on the live --go.
coproc _RC_CP { sleep 20; }
_cs_found0="$(kc_find_other_migration_procs 2>/dev/null || true)"
assert_true "[[ -z '$_cs_found0' ]]" \
    "a coproc in our process group (DB-lock shape) is NOT flagged"
kill "${_RC_CP_PID}" 2>/dev/null || true

describe "REGRESSION: but a REAL competing migration IS still detected"
# A REAL second run is a SEPARATE invocation with its OWN process group — simulate with setsid so it
# is not in ours. argv0 basenames to migrate_oneshot.sh (a symlink to sleep; no real migration runs).
# (A plain `&` job would share our pgid in a non-interactive shell and be correctly treated as ours.)
_cs_dir="$(mktemp -d)"
ln -sf /bin/sleep "$_cs_dir/migrate_oneshot.sh"
if command -v setsid >/dev/null 2>&1; then
    setsid "$_cs_dir/migrate_oneshot.sh" 20 &
    _cs_fake=$!
    sleep 0.3
    _cs_found="$(kc_find_other_migration_procs 2>/dev/null || true)"
    assert_true "grep -qx '$_cs_fake' <<< '$_cs_found'" \
        "a separate-pgid process running migrate_oneshot.sh is detected by pid"
    kill "$_cs_fake" 2>/dev/null || true
else
    skip_test "setsid unavailable — cannot simulate a separate-process-group run"
fi

# A mere MENTION (the script name only inside a -c blob) must never be flagged, own group or not.
setsid bash -c "sleep 20 # mentions migrate_keycloak_v3.sh in a comment only" &
_cs_mention=$!
sleep 0.3
_cs_found2="$(kc_find_other_migration_procs 2>/dev/null || true)"
assert_true "! grep -qx '$_cs_mention' <<< '$_cs_found2'" \
    "a process that only MENTIONS the script (not as an argv element) is NOT flagged"
kill "$_cs_mention" 2>/dev/null || true
rm -rf "$_cs_dir"

describe "ADR-008: --force-unlock and --no-resume are wired"
MV="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"
assert_true "bash '$MV' --help 2>&1 | grep -q 'force-unlock'" "usage documents --force-unlock"
assert_true "bash '$MV' --help 2>&1 | grep -q 'no-resume'"    "usage documents --no-resume"
assert_true "grep -q 'FORCE_UNLOCK=true' '$MV'"               "--force-unlock sets FORCE_UNLOCK"
assert_true "grep -q 'databasechangeloglock' '$PROJECT_ROOT/scripts/lib/migration_verify.sh'" \
    "Liquibase changelog lock is actually checked"

test_report
