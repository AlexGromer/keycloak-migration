#!/usr/bin/env bash
# Tests: F2 — migrate_oneshot.sh arg-parsing, hop chain, dry-run plan, gen-profile-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT
ONESHOT="$PROJECT_ROOT/scripts/migrate_oneshot.sh"
export CONTAINER_RUNTIME=docker

describe "F2: dry-run plan — Path B (target 26)"
out26="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db --dry-run </dev/null 2>&1 || true)"
assert_contains "$out26" "16.1.1 -> 24.0.5 -> 26.6.3" "target 26 hop chain (2 hops)"
assert_contains "$out26" "ghcr.io/alexgromer/keycloak-migration:astra-24.0.5" "pulls astra-24.0.5 (no re-tag)"
assert_contains "$out26" "ghcr.io/alexgromer/keycloak-migration:astra-26.6.3" "pulls astra-26.6.3 (no re-tag)"

describe "F2: dry-run plan — Path A (target 25)"
out25="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 25 --os redos --dry-run </dev/null 2>&1 || true)"
assert_contains "$out25" "16.1.1 -> 25.0.6" "target 25 hop chain (1 hop)"
assert_contains "$out25" "keycloak-migration:redos-25.0.6" "pulls redos-25.0.6"

describe "F2: input validation"
assert_exit_code 2 "PROFILE_DIR='$TMPD' bash '$ONESHOT' --target 99 --os astra </dev/null" "invalid --target -> exit 2"
assert_exit_code 2 "PROFILE_DIR='$TMPD' bash '$ONESHOT' --target 26 --os bsd </dev/null" "invalid --os -> exit 2"

describe "F2: --gen-profile-only writes a run+container profile"
gen="$(PROFILE_DIR="$TMPD" bash "$ONESHOT" --target 26 --os astra --profile-name genp --gen-profile-only </dev/null 2>&1 || true)"
f="$TMPD/genp.yaml"
assert_file_exists "$f" "gen-profile-only wrote a profile"
content="$(<"$f")"
assert_contains "$content" "deployment_mode: run"   "generated profile is run mode"
assert_contains "$content" "target_version: 26.6.3" "generated profile target 26.6.3"
assert_contains "$gen"     "Profile generated"      "gen-profile-only prints next steps"

test_report
