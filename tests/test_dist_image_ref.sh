#!/usr/bin/env bash
# Tests: Distribution image-reference resolution (dist_image_ref)
# Written against the frozen contract; gracefully skips until dist_image_ref()
# is added to scripts/lib/distribution_handler.sh (owned by another teammate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_framework.sh"

# Neutralize any container-runtime sourcing side effects.
export CONTAINER_RUNTIME=echo

CR_LIB="$PROJECT_ROOT/scripts/lib/container_runtime.sh"
DIST_LIB="$PROJECT_ROOT/scripts/lib/distribution_handler.sh"

# shellcheck source=/dev/null
[[ -f "$CR_LIB" ]] && source "$CR_LIB"
# shellcheck source=/dev/null
source "$DIST_LIB"

# ============================================================================
describe "dist_image_ref()"
# ============================================================================

if ! declare -F dist_image_ref >/dev/null 2>&1; then
    skip_test "dist_image_ref() not defined yet (owned by another teammate)"
else
    assert_equals "quay.io/keycloak/keycloak:26.6.3" \
        "$(unset PROFILE_CONTAINER_REGISTRY PROFILE_CONTAINER_IMAGE PROFILE_CONTAINER_IMAGE_REF; dist_image_ref 26.6.3)" \
        "default -> quay.io/keycloak/keycloak:26.6.3"

    assert_contains \
        "$(unset PROFILE_CONTAINER_IMAGE_REF; export PROFILE_CONTAINER_REGISTRY=registry.bank.local; dist_image_ref 26.6.3)" \
        "registry.bank.local" \
        "PROFILE_CONTAINER_REGISTRY overrides the registry"

    assert_equals "corp/kc:26.6.3" \
        "$(export PROFILE_CONTAINER_IMAGE_REF='corp/kc:{version}'; dist_image_ref 26.6.3)" \
        "PROFILE_CONTAINER_IMAGE_REF template -> corp/kc:26.6.3"
fi

# ============================================================================
test_report
