#!/usr/bin/env bash
# Tests: F1 — env precedence in profile_load for ':'-bearing container fields.
# A value pre-set in the environment (image_ref / image_tar / base_image) must SURVIVE
# profile_load (the flat YAML parser cannot represent ':' refs). Empty env => YAML as before.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT
export PROFILE_DIR="$TMPD"

cat > "$TMPD/envtest.yaml" <<'YAML'
profile:
  name: envtest
database:
  type: postgresql
  host: localhost
  port: 5432
  name: keycloak
  user: keycloak
keycloak:
  deployment_mode: run
  distribution_mode: container
  current_version: 16.1.1
  target_version: 26.6.3
  container:
    acquisition: preloaded
YAML

source "$PROJECT_ROOT/scripts/lib/profile_manager.sh"

describe "F1: backward compatible when env is unset"
unset PROFILE_CONTAINER_IMAGE_REF PROFILE_CONTAINER_IMAGE_TAR PROFILE_CONTAINER_BASE_IMAGE
profile_load envtest >/dev/null 2>&1
assert_empty   "${PROFILE_CONTAINER_IMAGE_REF:-}"   "no env + no YAML image_ref -> empty (back-compat)"
assert_equals  "preloaded" "${PROFILE_CONTAINER_ACQUISITION:-}" "acquisition still read from YAML"

describe "F1: env value wins over (absent) YAML"
export PROFILE_CONTAINER_IMAGE_REF="ghcr.io/alexgromer/keycloak-migration:astra-{version}"
export PROFILE_CONTAINER_IMAGE_TAR="/media/kc-astra-26.6.3.tar"
export PROFILE_CONTAINER_BASE_IMAGE="registry.astralinux.ru/library/astra/ubi18:1.8"
profile_load envtest >/dev/null 2>&1
assert_equals "ghcr.io/alexgromer/keycloak-migration:astra-{version}" \
    "${PROFILE_CONTAINER_IMAGE_REF:-}" "env image_ref survives profile_load (no re-tag needed)"
assert_equals "/media/kc-astra-26.6.3.tar" \
    "${PROFILE_CONTAINER_IMAGE_TAR:-}" "env image_tar survives profile_load"
assert_equals "registry.astralinux.ru/library/astra/ubi18:1.8" \
    "${PROFILE_CONTAINER_BASE_IMAGE:-}" "env base_image survives profile_load"

describe "REGRESSION: --apply-indexes (env PROFILE_APPLY_SKIPPED_INDEXES=true) survives profile_load"
# Bug: profile_load UNCONDITIONALLY set PROFILE_APPLY_SKIPPED_INDEXES from the YAML, clobbering the
# `--apply-indexes` flag (which exports =true BEFORE profile_load runs). Skipped indexes were then
# captured but NEVER applied despite the flag. Env must win — same precedence as image_ref above.
unset PROFILE_APPLY_SKIPPED_INDEXES
profile_load envtest >/dev/null 2>&1
assert_equals "false" "${PROFILE_APPLY_SKIPPED_INDEXES:-}" \
    "no env + no YAML -> false (back-compat)"
export PROFILE_APPLY_SKIPPED_INDEXES=true
profile_load envtest >/dev/null 2>&1
assert_equals "true" "${PROFILE_APPLY_SKIPPED_INDEXES:-}" \
    "env =true (from --apply-indexes) survives profile_load (was clobbered to false)"

test_report
