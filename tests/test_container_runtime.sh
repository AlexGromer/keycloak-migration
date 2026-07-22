#!/usr/bin/env bash
# Tests: Container Runtime abstraction (cr / cr_detect / cr_available)
# Written against the frozen contract; gracefully skips until
# scripts/lib/container_runtime.sh lands (owned by another teammate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_framework.sh"

LIB="$PROJECT_ROOT/scripts/lib/container_runtime.sh"

# ============================================================================
describe "container_runtime.sh"
# ============================================================================

if [[ ! -f "$LIB" ]]; then
    skip_test "container_runtime.sh not present yet (owned by another teammate)"
else
    # Stub the runtime so detection/auto-run never shells out to a real engine.
    export CONTAINER_RUNTIME=echo
    # shellcheck source=/dev/null
    source "$LIB"

    if ! declare -F cr >/dev/null 2>&1; then
        skip_test "cr() not defined by container_runtime.sh (contract pending)"
    else
        assert_equals "pull X" "$(cr pull X)" \
            "cr forwards args to \$CONTAINER_RUNTIME (echo stub)"

        assert_true "cr_available" \
            "cr_available returns 0 when CONTAINER_RUNTIME is set"

        # cr_detect resolves & exports CONTAINER_RUNTIME (returns 0/1); it does
        # not print the engine name. "Env override wins" => the pre-set value
        # survives detection.
        assert_true "cr_detect" \
            "cr_detect resolves a runtime and returns 0"

        assert_equals "echo" "${CONTAINER_RUNTIME:-}" \
            "cr_detect honors the CONTAINER_RUNTIME env override (precedence wins)"
    fi
fi

# ============================================================================
describe "rootless detection + rootless-docker loopback rewrite (hermetic)"
# ============================================================================
if [[ -f "$LIB" ]]; then
    # shellcheck source=/dev/null
    source "$LIB"

    assert_true  "_cr_is_loopback 127.0.0.1"      "127.0.0.1 is loopback"
    assert_true  "_cr_is_loopback localhost"      "localhost is loopback"
    assert_false "_cr_is_loopback db.corp.local"  "a real host is not loopback"

    # cr_is_rootless reads the engine's own report (mock cr info).
    cr() { case "$1" in info) echo 'name=seccomp name=rootless' ;; *) echo "$@" ;; esac; }
    export CONTAINER_RUNTIME=docker; _KC_ROOTLESS=""
    assert_true  "cr_is_rootless" "docker SecurityOptions name=rootless -> rootless"
    cr() { case "$1" in info) echo 'name=seccomp' ;; *) echo "$@" ;; esac; }
    _KC_ROOTLESS=""
    assert_false "cr_is_rootless" "docker without name=rootless -> not rootless"

    # pg_client under rootless docker rewrites a loopback -h; a real host is untouched.
    cr() { case "$1" in info) echo 'name=rootless' ;; run) printf 'RUN %s\n' "$*" ;; *) echo "$@" ;; esac; }
    _KC_ROOTLESS=""; _PG_CLIENT_ROOTFUL=""
    rw="$(pg_client __no_such_pg_tool__ -h 127.0.0.1 -U u -d db 2>&1)"
    assert_contains "$rw" "host.docker.internal" "rootless docker: loopback -h -> host.docker.internal"
    # needles starting with '--' must use grep -q -- (assert_contains would feed them to grep as options)
    assert_true "printf '%s' \"\$rw\" | grep -q -- '--add-host host.docker.internal:host-gateway'" "and --add-host host-gateway is added"
    assert_true "! printf '%s' \"\$rw\" | grep -q -- '--network=host'" "and --network=host is dropped"

    _KC_ROOTLESS=""; _PG_CLIENT_ROOTFUL=""
    rm2="$(pg_client __no_such_pg_tool__ -h db.corp -U u -d db 2>&1)"
    assert_true "printf '%s' \"\$rm2\" | grep -q -- '--network=host'" "a non-loopback host keeps --network=host"
    assert_true "! printf '%s' \"\$rm2\" | grep -q host.docker.internal" "and is not rewritten"

    # _pg_dump_is_dir decides the streaming vs bind-mount split: single-file formats (-Fc / -Fp / -Ft /
    # default) stream via stdin/stdout (no mount, no --user — works for a non-root container under
    # rootless docker); the directory format (-Fd) can't stream and keeps the mount path. The live
    # dump/restore round-trip is validated on rootless podman AND rootless docker (see docs/ROOTLESS.md).
    assert_true  "_pg_dump_is_dir -h db -Fd -f /x"          "-Fd is directory format (mount path)"
    assert_true  "_pg_dump_is_dir --format=directory -f /x" "--format=directory is directory"
    assert_true  "_pg_dump_is_dir -F d -f /x"               "-F d is directory"
    assert_false "_pg_dump_is_dir -h db -Fc -f /x"          "-Fc is single-file (streams)"
    assert_false "_pg_dump_is_dir -h db -f /x"              "default format is single-file (streams)"
else
    skip_test "container_runtime.sh not present"
fi

# ============================================================================
test_report
