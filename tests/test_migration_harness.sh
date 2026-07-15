#!/usr/bin/env bash
# Tests: Migration Test Harness (Phase 1 — dry-run plan + non-mutation)
#
# shellcheck disable=SC2030,SC2031  # PROFILE_* is set inside ( ) / $( ) subshells ON PURPOSE, to
#                                     isolate each case — the "change might be lost" is the intent.
# shellcheck disable=SC2329          # cr()/img_* stubs are invoked indirectly (command subst,
#                                     sourced functions); shellcheck cannot see the call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_framework.sh"

# Isolate any source-time / runtime writes into scratch.
HARNESS_WORK_DIR="$(mktemp -d)"
export HARNESS_WORK_DIR
export HARNESS_DRY_RUN="true"

# Source the harness (its main is guarded -> not executed on source). This also
# sources migrate_keycloak_v3.sh + libs, exposing kc_build_migration_path,
# dist_image_ref and the harness functions.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/harness/run_migration_harness.sh"

# Record-and-fail stubs for the real mutating engines, defined AFTER sourcing so
# they shadow the library `cr` / psql. If the dry-run ever invokes a real engine,
# the call is recorded here and the non-mutation assertion fails.
CALL_LOG="$HARNESS_WORK_DIR/calls.log"
: > "$CALL_LOG"
cr()      { echo "cr $*"      >> "$CALL_LOG"; }
psql()    { echo "psql $*"    >> "$CALL_LOG"; }
pg_dump() { echo "pg_dump $*" >> "$CALL_LOG"; }
docker()  { echo "docker $*"  >> "$CALL_LOG"; }
podman()  { echo "podman $*"  >> "$CALL_LOG"; }

# ============================================================================
describe "hop path (reused from migrate_keycloak_v3.sh)"
# ============================================================================
assert_equals "24.0.5 26.6.3" "$(kc_build_migration_path 16.1.1 26)" \
    "clean-base 16.1.1 -> target 26 yields both hops"

# ============================================================================
describe "image ref override (dist_image_ref)"
# ============================================================================
( export PROFILE_CONTAINER_IMAGE_REF="custom/kc:{version}"
  assert_equals "custom/kc:26.6.3" "$(dist_image_ref 26.6.3)" \
    "final image ref honours {version} substitution" )

# ============================================================================
describe "img_build reuses a present image instead of rebuilding from base"
# ============================================================================
# Phase-1 rebuilt every hop FROM the sovereign base OS. That base is licensed and often absent, so a
# live run against images that were already built and loaded died at the build step. With
# IMG_SKIP_IF_PRESENT=true, a present image is reused. Asserts run in the PARENT shell (a `( )`
# subshell would swallow their tally) so the stub is defined here and cleared afterwards.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/distribution_handler.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/image_builder.sh"

_ib_saved_ref="${PROFILE_CONTAINER_IMAGE_REF:-}"
export PROFILE_CONTAINER_IMAGE_REF="reuse-test/kc:{version}"
_IB_PRESENT="true"   # flips the stubbed `cr image inspect` result

# Stub the runtime: image presence is _IB_PRESENT; a real `cr build` prints BUILD-RAN so a test can
# see whether it happened.
cr() {
    if [[ "$1" == "image" && "$2" == "inspect" ]]; then
        [[ "$_IB_PRESENT" == "true" ]] && return 0 || return 1
    fi
    [[ "$1" == "build" ]] && echo "BUILD-RAN"
    return 0
}

_IB_PRESENT="true"
out="$(IMG_SKIP_IF_PRESENT=true img_build 26.6.3 some/base:latest 21 2>&1)"
assert_contains "$out" "Reusing image already present" \
    "a present image is reused when IMG_SKIP_IF_PRESENT=true"
assert_true "[[ '$out' != *BUILD-RAN* ]]" \
    "and cr build is NOT invoked"

_IB_PRESENT="false"
out="$(IMG_SKIP_IF_PRESENT=true img_build 26.6.3 some/base:latest 21 2>&1)"
assert_contains "$out" "BUILD-RAN" \
    "an ABSENT image still builds — the skip is reuse, not refuse"

_IB_PRESENT="true"
out="$(IMG_SKIP_IF_PRESENT=false img_build 26.6.3 some/base:latest 21 2>&1)"
assert_contains "$out" "BUILD-RAN" \
    "without the flag, a present image is rebuilt — existing callers are unaffected"

unset -f cr
export PROFILE_CONTAINER_IMAGE_REF="$_ib_saved_ref"

# ============================================================================
describe "data-integrity policy (_harness_integrity_eval)"
# ============================================================================
assert_true  "_harness_integrity_eval 3 3 150 150 30 33 >/dev/null 2>&1" \
    "equal realms/users + grown clients PASSES"
assert_false "_harness_integrity_eval 3 2 150 150 30 30 >/dev/null 2>&1" \
    "realm loss FAILS"
assert_false "_harness_integrity_eval 3 3 150 149 30 30 >/dev/null 2>&1" \
    "user loss FAILS"
assert_false "_harness_integrity_eval 3 3 150 150 30 29 >/dev/null 2>&1" \
    "client drop FAILS"

# ============================================================================
describe "dry-run plan (full chain, mutates nothing)"
# ============================================================================
PLAN_RC=0
PLAN="$(harness_main --dry-run --profile test-harness-sovereign 2>&1)" || PLAN_RC=$?

assert_equals "0" "$PLAN_RC" "harness dry-run exits 0"
assert_contains "$PLAN" "DRY-RUN: cr network create"        "plan: bridge network"
assert_contains "$PLAN" "POSTGRES_PASSWORD=\*\*\*"           "plan: fresh PG (password masked)"
assert_contains "$PLAN" "DB_VENDOR=postgres"                 "plan: KC16 WildFly base boot"
assert_contains "$PLAN" "create realms"                      "plan: kcadm random seed"
assert_contains "$PLAN" "baseline COUNT"                     "plan: data-integrity baseline"
assert_contains "$PLAN" "img_build 24.0.5"                   "plan: build hop 24.0.5"
assert_contains "$PLAN" "img_build 26.6.3"                   "plan: build hop 26.6.3"
assert_contains "$PLAN" "KC_DB_URL=jdbc:postgresql://"       "plan: Quarkus run line"
assert_contains "$PLAN" "localhost/kc-harness:26.6.3"        "plan: final image ref {version}-substituted"
assert_contains "$PLAN" "wait_for_migration 26.6.3"          "plan: L1 wait"
assert_contains "$PLAN" "MIGRATION_MODEL"                    "plan: L2 verify"
assert_contains "$PLAN" "integrity check after 26.6.3"       "plan: per-hop integrity"

# ============================================================================
describe "non-mutation guarantee"
# ============================================================================
assert_true  "[[ ! -s '$CALL_LOG' ]]" \
    "dry-run invoked ZERO real cr/psql/pg_dump/docker/podman calls"
assert_false "echo \"\$PLAN\" | grep -qE 'KC_DB_PASSWORD=[^*]'" \
    "no unmasked DB password leaks into the plan"

# ============================================================================
rm -rf "$HARNESS_WORK_DIR"
test_report
