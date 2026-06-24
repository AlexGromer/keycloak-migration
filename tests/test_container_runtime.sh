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
test_report
