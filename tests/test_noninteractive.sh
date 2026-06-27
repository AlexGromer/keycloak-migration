#!/usr/bin/env bash
# Tests: F4 — non-interactive confirmation (--yes / ASSUME_DEFAULTS / _confirm) + fail-closed gate.
# Note: the live fail-closed gate is integration-tested on a real host (it sits behind the v3.5
# production preflight which requires >=10GB disk); here we cover the deterministic surfaces.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

export WORK_DIR="$(mktemp -d)"     # contain migrate's source-time mkdir
TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD" "$WORK_DIR"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"

describe "F4: _confirm auto-answers in non-interactive contexts"
_rc() { AUTO_CONFIRM="$1" ASSUME_DEFAULTS="$2" _confirm "q?" "$3" </dev/null >/dev/null 2>&1; }
assert_true  "_rc true false Y"  "AUTO_CONFIRM + default Y -> yes"
assert_false "_rc true false N"  "AUTO_CONFIRM + default N -> no"
assert_true  "_rc false true Y"  "ASSUME_DEFAULTS + default Y -> yes"
assert_false "_rc false true N"  "ASSUME_DEFAULTS + default N -> no"
assert_true  "_rc false false Y" "non-tty (</dev/null) + default Y -> yes"
assert_false "_rc false false N" "non-tty (</dev/null) + default N -> no"

describe "F4: dry-run is non-interactive (no prompt, no hang)"
cat > "$TMPD/ni.yaml" <<'YAML'
profile:
  name: ni
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
migration:
  backup_before_step: false
YAML
set +e
out="$(PROFILE_DIR="$TMPD" WORK_DIR="$TMPD/wd" CONTAINER_RUNTIME=docker timeout 60 \
    bash "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" migrate --profile ni --dry-run --skip-preflight </dev/null 2>&1)"
rc=$?
set -e
assert_equals  "0" "$rc" "migrate --dry-run exits 0 without a TTY (no hang)"
assert_contains "$out" "DRY RUN mode" "dry-run prints plan, makes no changes"

describe "F4: --yes flag and fail-closed gate are wired"
# grep the file directly (assert_contains' echo mangles backslash escapes like \033).
MV="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"
assert_true "bash '$MV' --help 2>&1 | grep -q 'yes, -y'" "usage documents --yes"
assert_true "grep -q 'Refusing to proceed non-interactively' '$MV'" "fail-closed gate present (live path)"
assert_true "grep -q 'AUTO_CONFIRM=true' '$MV'" "--yes sets AUTO_CONFIRM in the arg parser"

test_report
