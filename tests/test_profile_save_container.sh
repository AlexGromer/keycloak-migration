#!/usr/bin/env bash
# Tests: F3a — profile_save emits acquisition / runtime / image_tar in the container block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT
export PROFILE_DIR="$TMPD"

source "$PROJECT_ROOT/scripts/lib/profile_manager.sh"

describe "F3a: profile_save writes acquisition/runtime/image_tar"
export PROFILE_DB_TYPE="postgresql" PROFILE_DB_HOST="db" PROFILE_DB_PORT="5432"
export PROFILE_DB_NAME="keycloak" PROFILE_DB_USER="keycloak"
export PROFILE_KC_DEPLOYMENT_MODE="run" PROFILE_KC_DISTRIBUTION_MODE="container"
export PROFILE_KC_CLUSTER_MODE="standalone"
export PROFILE_KC_CURRENT_VERSION="16.1.1" PROFILE_KC_TARGET_VERSION="26.6.3"
export PROFILE_CONTAINER_REGISTRY="ghcr.io/alexgromer" PROFILE_CONTAINER_IMAGE="keycloak-migration"
export PROFILE_CONTAINER_RUNTIME="docker" PROFILE_CONTAINER_ACQUISITION="preloaded"
export PROFILE_CONTAINER_IMAGE_TAR="/media/kc.tar"

profile_save "savetest" >/dev/null
f="$PROFILE_DIR/savetest.yaml"
assert_file_exists "$f" "profile saved"
content="$(<"$f")"
assert_contains "$content" "acquisition: preloaded" "container block has acquisition"
assert_contains "$content" "runtime: docker"        "container block has runtime"
assert_contains "$content" "image_tar: /media/kc.tar" "container block has image_tar"

describe "F3a: acquisition round-trips through profile_load"
unset PROFILE_CONTAINER_ACQUISITION
profile_load "savetest" >/dev/null 2>&1
assert_equals "preloaded" "${PROFILE_CONTAINER_ACQUISITION:-}" "acquisition reloaded from YAML"

describe "image_ref round-trips through a SIDECAR (flat YAML cannot hold the ':')"
# The sovereign tag ghcr.io/ns/img:astra-{version} carries ':' and '{}', which the flat YAML parser
# truncates. Without persistence, `verify --profile <name>` could not resolve the image and fell
# back to registry/image:version (no os-prefixed tag). profile_save now writes a sidecar.
export PROFILE_CONTAINER_IMAGE_REF='ghcr.io/alexgromer/keycloak-migration:astra-{version}'
profile_save "reftest" >/dev/null
assert_file_exists "$PROFILE_DIR/reftest.image-ref" "sidecar written next to the profile"
assert_equals 'ghcr.io/alexgromer/keycloak-migration:astra-{version}' \
    "$(cat "$PROFILE_DIR/reftest.image-ref")" "sidecar holds the ref verbatim (':' and {} intact)"

# The ref must NOT be smuggled into the flat YAML (it would corrupt the parser).
assert_true "! grep -q 'image_ref:' '$PROFILE_DIR/reftest.yaml'" \
    "the ':'-bearing ref is kept OUT of the flat YAML"

# profile_load restores it from the sidecar when the environment does not already carry it.
unset PROFILE_CONTAINER_IMAGE_REF
profile_load "reftest" >/dev/null 2>&1
assert_equals 'ghcr.io/alexgromer/keycloak-migration:astra-{version}' \
    "${PROFILE_CONTAINER_IMAGE_REF:-}" "profile_load reads the ref back from the sidecar"

# dist_image_ref then resolves the per-hop image without any env priming — the verify --profile fix.
source "$PROJECT_ROOT/scripts/lib/distribution_handler.sh"
assert_equals 'ghcr.io/alexgromer/keycloak-migration:astra-26.6.3' \
    "$(dist_image_ref 26.6.3)" "the sovereign image resolves from the profile alone"

# A pre-set environment value still WINS over the sidecar (CI / wrapper override).
PROFILE_CONTAINER_IMAGE_REF='override/img:{version}' profile_load "reftest" >/dev/null 2>&1 || true
export PROFILE_CONTAINER_IMAGE_REF='override/img:{version}'
profile_load "reftest" >/dev/null 2>&1
assert_equals 'override/img:{version}' "${PROFILE_CONTAINER_IMAGE_REF:-}" \
    "a pre-set env ref overrides the sidecar"

test_report
