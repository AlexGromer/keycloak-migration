#!/usr/bin/env bash
# Tests: ADR-009 — health is DIAGNOSTIC, L2 (MIGRATION_MODEL) is the gate.
#
# The bug these lock down: in every deployment mode except `run`, a health probe that could not
# reach /health "failed", and a failed health check rolled the migration back — restoring a
# database over a hop that had ALREADY passed the authoritative L2 gate. The probe 404'd on every
# supported hop (KC 24+ serves /health only with KC_HEALTH_ENABLED=true; KC>=25 moved it to port
# 9000), and _confirm's "Y" default auto-answers YES in any non-TTY, which is how CI, cron and
# --yes all run. Silent, unattended destruction of a successful migration.
#
# shellcheck disable=SC2016  # Single-quoted needles are LITERALS on purpose: these assertions grep
# the source for the exact text '$WORK_DIR/...', '$target_version' etc. Expanding them here would
# search for the wrong thing — the value instead of the code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

WORK_DIR="$(mktemp -d)"
export WORK_DIR
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"

# ---------------------------------------------------------------------------
describe "ADR-009: health endpoint follows the Keycloak version"
# KC >= 25 serves health on the MANAGEMENT port (9000) at /health/ready. Probing :8080/health on
# a KC 26 — the old hardcoded default — is guaranteed to 404. That 404 was read as "unhealthy".
assert_equals "http://localhost:9000/health/ready" "$(kc_health_endpoint 26.6.3)" \
    "KC 26.6.3 -> management port 9000"
assert_equals "http://localhost:9000/health/ready" "$(kc_health_endpoint 25.0.6)" \
    "KC 25.0.6 -> management port 9000 (the version health moved)"
assert_equals "http://localhost:8080/health" "$(kc_health_endpoint 24.0.5)" \
    "KC 24.0.5 -> HTTP port 8080"
assert_equals "http://localhost:8080/health" "$(kc_health_endpoint 16.1.1)" \
    "KC 16.1.1 -> HTTP port 8080"
assert_equals "http://localhost:8080/health" "$(kc_health_endpoint '')" \
    "unknown version degrades to the 8080 default rather than erroring"

# ---------------------------------------------------------------------------
describe "ADR-009: a 404 is 'health is switched off', not 'migration failed'"
# The whole point: these three outcomes must be distinguishable. Collapsing them into pass/fail
# is what let a configuration fact masquerade as a migration failure.
assert_equals "0" "$HEALTH_OK"          "HEALTH_OK = 0"
assert_equals "1" "$HEALTH_UNCONFIRMED" "HEALTH_UNCONFIRMED = 1"
assert_equals "2" "$HEALTH_NOT_SERVED"  "HEALTH_NOT_SERVED = 2 (distinct from failure)"

# run mode: transient container, nothing to serve. Reports NOT_SERVED — never OK, never a failure.
PROFILE_KC_DEPLOYMENT_MODE="run" \
    assert_exit_code 2 "health_check 26.6.3" \
    "run mode reports HEALTH_NOT_SERVED (transient container, no service)"

# ---------------------------------------------------------------------------
describe "ADR-009: health failure never reaches the rollback path"
# migrate_to_version must call health_check with `|| true` and must NOT call _kc_offer_rollback
# anywhere near it. Verified structurally: the Step 7 block is the one that used to roll back.
step7_file="$WORK_DIR/step7.txt"
sed -n '/# Step 7: Health check/,/^    # Step 8/p' \
    "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" > "$step7_file"
step7="$(cat "$step7_file")"

assert_contains "$step7" 'health_check "$target_version" || true' \
    "Step 7 tolerates a failed probe"
assert_equals "0" "$(grep -cF 'cmd_rollback_auto' "$step7_file" || true)" \
    "Step 7 contains NO rollback call"
assert_equals "0" "$(grep -cF '_kc_offer_rollback' "$step7_file" || true)" \
    "Step 7 does not offer a rollback either"

# The L2 gate is the only place a rollback may be offered.
step6b="$(sed -n '/# Step 6b: AUTHORITATIVE Layer 2 gate/,/# Step 6c/p' "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh")"
assert_contains "$step6b" "_kc_offer_rollback" \
    "the L2 gate — and only it — offers the rollback"

# ---------------------------------------------------------------------------
describe "ADR-009: the rollback prompt defaults to NO"
# _confirm auto-answers its DEFAULT when stdin is not a TTY (CI, cron, pipe) and under --yes /
# ASSUME_DEFAULTS. migrate_oneshot always passes --yes. A "Y" default here therefore meant:
# restore a production database, unattended, with nobody present to see the question.
offer="$(sed -n '/^_kc_offer_rollback()/,/^}/p' "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh")"
assert_contains "$offer" '_confirm "Restore the pre-${version} backup?" "N"' \
    "the prompt defaults to N"
assert_true "[[ '$offer' != *'\"Y\"'* ]]" \
    "no 'Y' default survives anywhere in the rollback offer"

# And prove the mechanism, not just the string: _confirm with default N, non-interactive, says no.
assert_false "AUTO_CONFIRM=true _confirm 'destroy the database?' 'N'" \
    "_confirm default N under --yes answers NO"
assert_true  "AUTO_CONFIRM=true _confirm 'proceed?' 'Y'" \
    "_confirm default Y under --yes answers YES (this is why the default matters)"

# ---------------------------------------------------------------------------
describe "checkpoints do not survive the rollback that undoes them"
# A rollback restores the DB to BEFORE the hop. A checkpoint still claiming CHECKPOINT_26_6_3=
# migrated would make the next run skip straight past the migration it now has to redo.
STATE_FILE="$WORK_DIR/state.env"
export STATE_FILE
: > "$STATE_FILE"

set_checkpoint "26.6.3" "migrated" >/dev/null
assert_equals "migrated" "$(get_checkpoint 26.6.3)" "checkpoint recorded"

clear_checkpoint "26.6.3" >/dev/null
assert_empty "$(get_checkpoint 26.6.3)" "checkpoint cleared"
assert_true "[[ -f '$STATE_FILE' ]]" "the state file itself survives (other hops keep theirs)"

# Clearing one hop must not touch another.
set_checkpoint "24.0.5" "migrated" >/dev/null
set_checkpoint "26.6.3" "migrated" >/dev/null
clear_checkpoint "26.6.3" >/dev/null
assert_equals "migrated" "$(get_checkpoint 24.0.5)" "24.0.5's checkpoint is untouched"
assert_empty  "$(get_checkpoint 26.6.3)"            "26.6.3's checkpoint is gone"

# cmd_rollback_auto must derive the hop from the backup name and clear exactly that hop.
rollback_src="$(sed -n '/^cmd_rollback_auto()/,/^}/p' "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh")"
assert_contains "$rollback_src" "clear_checkpoint" \
    "cmd_rollback_auto clears the checkpoints of the hop it undoes"

# ---------------------------------------------------------------------------
describe "backups are written where rotation actually looks"
# They were not: hop backups landed flat in \$WORK_DIR while rotation swept \$WORK_DIR/backups.
# Rotation reported "Found 0 backup(s)" on every single run and never deleted anything.
assert_equals "${WORK_DIR}/backups" "$(kc_backup_dir)" "kc_backup_dir is \$WORK_DIR/backups"
assert_true "[[ -d '${WORK_DIR}/backups' ]]" "kc_backup_dir creates the directory"

# Grep the file rather than interpolate its text into an assertion: the framework eval()s the
# expression it is given, and the source contains apostrophes and newlines that would break it.
MAIN="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"

assert_equals "0" "$(grep -cF '$WORK_DIR/backup_before_' "$MAIN" || true)" \
    "no hop backup is written flat into \$WORK_DIR any more"
# Exactly one: the definition inside kc_backup_dir itself. Every caller — the two rotation sites
# included — goes through the helper instead of spelling the path out again.
assert_equals "1" "$(grep -cF '${WORK_DIR}/backups' "$MAIN" || true)" \
    "the backups directory is named in exactly one place: kc_backup_dir"
assert_equals "3" "$(grep -cF '$(kc_backup_dir)/backup_before_' "$MAIN" || true)" \
    "all three backup write sites go through kc_backup_dir"

# Safety backups must stay OUT of the rotated directory: rotation globs *.dump and would prune
# the emergency copy taken moments before a restore.
assert_equals "1" "$(grep -cF '$WORK_DIR/safety_before_rollback_' "$MAIN" || true)" \
    "safety backups stay in \$WORK_DIR, outside the rotated directory"

# ---------------------------------------------------------------------------
describe "an interrupt puts back the Keycloak we took down"
# Non-run modes stop the user's REAL Keycloak at Step 2 and restart it at Step 5. A Ctrl-C in that
# window used to just exit: `systemctl stop keycloak` left un-done, or `kubectl scale --replicas=0`
# left un-done — production scaled to zero with nobody putting it back.
assert_equals "false" "$_KC_SERVICE_STOPPED_BY_US" \
    "the flag starts false (we have taken nothing down yet)"

interrupt_src="$(sed -n '/^_kc_on_interrupt()/,/^}/p' "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh")"
assert_contains "$interrupt_src" '_KC_SERVICE_STOPPED_BY_US' \
    "the interrupt handler consults the flag"
assert_contains "$interrupt_src" "kc_service_start" \
    "the interrupt handler restarts the service it stopped"
assert_contains "$interrupt_src" "COULD NOT RESTART KEYCLOAK" \
    "and if the restart fails, it says so loudly rather than exiting quietly"

# The flag must be raised at the stop and lowered at the start — not left dangling.
assert_equals "1" "$(grep -cF '_KC_SERVICE_STOPPED_BY_US="true"' "$MAIN" || true)" \
    "raised after Step 2 stops the service"
# Twice: the initial declaration, and Step 5 lowering it once Keycloak is back up.
assert_equals "2" "$(grep -cF '_KC_SERVICE_STOPPED_BY_US="false"' "$MAIN" || true)" \
    "lowered once Step 5 has it back up (plus the initial declaration)"

# ---------------------------------------------------------------------------
describe "docker/podman update never destroys what it cannot rebuild"
# It did: on insufficient inspect data the code stopped and REMOVED the user's Keycloak, logged
# "please update your run command manually" over the wreckage, and returned 0.
dist_src="$(sed -n '/        docker|podman)/,/        docker-compose)/p' "$PROJECT_ROOT/scripts/lib/distribution_handler.sh")"

assert_contains "$dist_src" "Recreating it would destroy a container we cannot rebuild — refusing" \
    "refuses before mutating when the config cannot be read"
assert_contains "$dist_src" 'DRY_RUN' \
    "a dry run does not recreate anything"

# Fail-closed ordering: the refusal must come BEFORE the first destructive call.
refuse_line="$(printf '%s\n' "$dist_src" | grep -n 'no env captured' | head -1 | cut -d: -f1)"
stop_line="$(printf '%s\n'  "$dist_src" | grep -n 'cr stop'          | head -1 | cut -d: -f1)"
assert_true "[[ ${refuse_line:-9999} -lt ${stop_line:-0} ]]" \
    "the refusal is checked BEFORE the first 'cr stop' (fail-closed, not fail-after-destroying)"

# The run-mode container name must not leak into docker/podman mode and get the wrong container
# recreated — and destroyed. Comments may NAME the variable (they explain the bug); only real
# code must not read it. Strip comment lines before looking.
run_leak="$(printf '%s\n' "$dist_src" | grep -v '^[[:space:]]*#' | grep -c 'PROFILE_KC_RUN_CONTAINER_NAME' || true)"
assert_equals "0" "$run_leak" \
    "docker/podman mode does not read the transient run-mode container name"

# Ports and networks must be carried over, or the replacement comes up unreachable.
assert_contains "$dist_src" "port_args" "published ports are captured"
assert_contains "$dist_src" "nets"      "networks are captured"

test_report
