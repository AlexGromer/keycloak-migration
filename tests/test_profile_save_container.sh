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

test_report
