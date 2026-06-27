#!/usr/bin/env bash
# Tests: F3b — config_wizard --non-interactive generates a run+container profile (env-driven).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

describe "F3b: wizard non-interactive run+container profile"
PROFILE_DIR="$TMPD" NON_INTERACTIVE=true \
  PROFILE_DB_TYPE=postgresql PROFILE_DB_HOST=db PROFILE_DB_PORT=5432 PROFILE_DB_NAME=keycloak \
  PROFILE_DB_USER=keycloak PROFILE_DB_LOCATION=standalone PROFILE_DB_CREDENTIALS_SOURCE=env \
  PROFILE_KC_DEPLOYMENT_MODE=run PROFILE_KC_DISTRIBUTION_MODE=container PROFILE_KC_CLUSTER_MODE=standalone \
  PROFILE_CONTAINER_ACQUISITION=preloaded PROFILE_CONTAINER_REGISTRY=ghcr.io/alexgromer \
  PROFILE_CONTAINER_IMAGE=keycloak-migration \
  PROFILE_KC_CURRENT_VERSION=16.1.1 PROFILE_KC_TARGET_VERSION=26.6.3 \
  PROFILE_MIGRATION_STRATEGY=inplace \
  bash "$PROJECT_ROOT/scripts/config_wizard.sh" --non-interactive --profile-name wizrun </dev/null >/dev/null 2>&1 || true

f="$TMPD/wizrun.yaml"
assert_file_exists "$f" "wizard generated profile in PROFILE_DIR"
content="$(<"$f")"
assert_contains "$content" "deployment_mode: run"           "deployment_mode = run"
assert_contains "$content" "distribution_mode: container"   "distribution_mode = container"
assert_contains "$content" "acquisition: preloaded"         "acquisition preset honored"
assert_contains "$content" "target_version: 26.6.3"         "target_version = 26.6.3 (Path B default)"

test_report
