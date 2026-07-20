#!/usr/bin/env bash
# Tests: three ways to configure a migration, and three ways to get the images.
#
# Before this, migrate_oneshot.sh took flags and only flags. The database password had to be
# exported by hand into the shell (and thus into shell history); config_wizard.sh existed, was
# fully written, and was wired to nothing; and image names were locked to OUR convention
# (<ns>:<os>-<version>), so a company whose registry already held Keycloak images under its own
# naming could not point the tool at them.
#
# shellcheck disable=SC2016  # Single-quoted needles are LITERALS: these grep the source for exact
# code text ('{version}' etc). Expanding them would search for the value instead of the code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ONESHOT="$PROJECT_ROOT/scripts/migrate_oneshot.sh"

# Every invocation below is a DRY RUN against a throwaway work dir. Nothing is pulled, nothing is
# migrated, no container is touched.
run_oneshot() {
    ( cd "$PROJECT_ROOT" && PROFILE_DIR="$TMP/profiles" \
        timeout 120 bash "$ONESHOT" --work-dir "$TMP/work" "$@" 2>&1 ) || true
}

# ---------------------------------------------------------------------------
describe "--env-file: the password does not have to live in your shell history"

envf="$TMP/kc.env"
cat > "$envf" <<'EOF'
KC_TARGET=26
KC_OS=astra
KC_DB_HOST=db.corp.local
KC_DB_PORT=5433
KC_DB_NAME=kcprod
KC_DB_USER=kcadmin
PROFILE_DB_PASSWORD=s3cr3t-from-file
EOF
chmod 600 "$envf"

out="$(run_oneshot --env-file "$envf" --dry-run)"
assert_contains "$out" "Loaded environment from" "the env file is read"
assert_contains "$out" "kcadmin@db.corp.local:5433/kcprod" \
    "every database setting comes from the file — not one flag was passed"
assert_contains "$out" "26.6.3" "the target comes from the file too"

# The file holds a database password. If the rest of the machine can read it, that is the whole
# point defeated — refuse rather than quietly proceed.
chmod 644 "$envf"
out="$(run_oneshot --env-file "$envf" --dry-run)"
assert_contains "$out" "it holds a database password" \
    "a world-readable env file is REFUSED, not warned about"
chmod 600 "$envf"

out="$(run_oneshot --env-file "$TMP/nope.env" --dry-run)"
assert_contains "$out" "env-file not found" "a missing env file fails loudly"

# Flags still win over the file — the file supplies defaults, not commands.
out="$(run_oneshot --env-file "$envf" --db-host overridden.local --dry-run)"
assert_contains "$out" "overridden.local" "an explicit flag overrides the env file"

# ---------------------------------------------------------------------------
describe "--image-ref-template: images from YOUR registry, under YOUR names"
# The default is our convention, <ns>:<os>-<version>. A company that already has Keycloak images
# named some other way should not have to re-tag its registry to satisfy this tool.

out="$(run_oneshot --target 26 --source pull \
        --image-ns registry.corp.local/keycloak/kc --dry-run)"
assert_contains "$out" "registry.corp.local/keycloak/kc:astra-26.6.3" \
    "--image-ns points the default convention at a private registry"

out="$(run_oneshot --target 26 --source pull \
        --image-ref-template 'registry.corp.local/keycloak:{version}' --dry-run)"
assert_contains "$out" "registry.corp.local/keycloak:26.6.3" \
    "--image-ref-template drops our naming convention entirely"
assert_contains "$out" "registry.corp.local/keycloak:24.0.5" \
    "and {version} is substituted per HOP, not just for the target"

# Acquisition and the migration must resolve the SAME ref, or the tool pulls one image and runs
# another.
assert_contains "$out" "cr pull registry.corp.local/keycloak:24.0.5" \
    "the pull uses the template too — not a separately-built name"

out="$(run_oneshot --target 26 --source pull --image-ref-template 'registry/kc:latest' --dry-run)"
assert_contains "$out" "must contain the literal {version}" \
    "a template with no {version} is rejected — every hop would get the same image"

# ---------------------------------------------------------------------------
describe "--profile: reuse a configuration instead of re-deriving it"

mkdir -p "$TMP/profiles"
cat > "$TMP/profiles/corp.yaml" <<'EOF'
profile:
  name: corp
  environment: run
database:
  type: postgresql
  location: standalone
  host: 127.0.0.1
  port: 5432
  name: keycloak
  user: keycloak
  credentials_source: env
keycloak:
  deployment_mode: run
  distribution_mode: container
  cluster_mode: standalone
  current_version: 16.1.1
  target_version: 26.6.3
  container:
    registry: registry.corp.local
    image: keycloak
    pull_policy: IfNotPresent
    runtime: docker
    acquisition: pull
migration:
  strategy: inplace
  parallel_jobs: 1
  timeout_per_version: 900
  run_smoke_tests: false
  backup_before_step: true
EOF

out="$(run_oneshot --profile corp --dry-run)"
assert_contains "$out" "existing profile 'corp'" "an existing profile is used as-is"
assert_contains "$out" "migrate --profile corp --yes --dry-run" \
    "it hands straight over to the migration — nothing is regenerated"
assert_contains "$out" "governed by the profile's own 'acquisition'" \
    "image acquisition stays the profile's business — one source of truth, not two"

out="$(run_oneshot --profile does-not-exist --dry-run)"
assert_contains "$out" "profile not found" "a missing profile fails loudly"

# Live still requires the password. --profile must not become a way around that.
out="$( cd "$PROJECT_ROOT" && PROFILE_DIR="$TMP/profiles" PROFILE_DB_PASSWORD="" \
    timeout 60 bash "$ONESHOT" --work-dir "$TMP/work" --profile corp --go 2>&1 || true )"
assert_contains "$out" "requires PROFILE_DB_PASSWORD" \
    "--profile --go without a password is refused, like every other live path"

# ---------------------------------------------------------------------------
describe "--wizard: be asked, instead of remembering flags"
# config_wizard.sh was written long ago and called by nothing. It is now the third way in.
wiz_block="$(sed -n '/^if \[\[ "\$RUN_WIZARD" == "true" \]\]/,/^fi$/p' "$ONESHOT")"
assert_contains "$wiz_block" "config_wizard.sh" "--wizard invokes the existing wizard"
assert_contains "$wiz_block" 'USE_PROFILE="$WIZ_NAME"' \
    "and then migrates with the profile it wrote — the wizard is not a dead end"

# ---------------------------------------------------------------------------
describe "--apply-indexes reaches the migration"
# Keycloak SKIPS CREATE INDEX above ~300k rows and only logs the DDL; the migration then succeeds
# with indexes missing. oneshot never set the flag that applies them, so its default was 'silently
# degrade the database'.
out="$(run_oneshot --target 26 --apply-indexes --dry-run)"
assert_contains "$out" "yes --dry-run --skip-preflight --apply-indexes" "the flag is passed through to migrate_keycloak_v3.sh"

assert_equals "1" "$(grep -cF 'PROFILE_APPLY_SKIPPED_INDEXES=true' "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" || true)" \
    "and it sets the variable kc_check_skipped_indexes actually reads"

test_report
