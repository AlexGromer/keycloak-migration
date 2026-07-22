#!/usr/bin/env bash
# shellcheck disable=SC2034
# (captured outputs like pub_out are used inside assert_true "... \$var ..." eval strings)
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

describe "F2: SAFETY — a caller-supplied work dir is NEVER deleted (rm -rf regression)"
WD="$TMPD/mywork"
mkdir -p "$WD"; touch "$WD/keepme"
# --help exits via the EXIT trap: must not wipe the caller's dir
ONESHOT_WORK_DIR="$WD" timeout 60 bash "$ONESHOT" --help >/dev/null 2>&1 || true
assert_file_exists "$WD/keepme" "ONESHOT_WORK_DIR survives --help"
# --work-dir flag + a non-exec exit path (gen-profile-only)
PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --work-dir "$WD" \
    --profile-name wdtest --gen-profile-only </dev/null >/dev/null 2>&1 || true
assert_file_exists "$WD/keepme" "--work-dir survives --gen-profile-only"
# an invalid-arg exit path must not wipe it either
PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 99 --work-dir "$WD" </dev/null >/dev/null 2>&1 || true
assert_file_exists "$WD/keepme" "--work-dir survives a validation error"
assert_exit_code 2 "bash '$ONESHOT' --target 26 --work-dir </dev/null" "--work-dir without a path -> exit 2"

describe "F2: --work-dir / --skip-preflight are accepted"
wd_out="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --work-dir "$WD" \
    --skip-preflight --dry-run </dev/null 2>&1 || true)"
assert_contains "$wd_out" "$WD" "banner shows the caller work dir"
assert_contains "$wd_out" "never deleted" "banner marks the work dir as not-deleted"

describe "F2: --gen-profile-only writes a run+container profile"
gen="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --profile-name genp --gen-profile-only </dev/null 2>&1 || true)"
f="$TMPD/genp.yaml"
assert_file_exists "$f" "gen-profile-only wrote a profile"
content="$(<"$f")"
assert_contains "$content" "deployment_mode: run"   "generated profile is run mode"
assert_contains "$content" "target_version: 26.6.3" "generated profile target 26.6.3"
assert_contains "$gen"     "Profile generated"      "gen-profile-only prints next steps"

describe "F2: --source bundle loads the sovereign pg-client image too (v3.9.7 autonomy)"
# The bundle carries kc-<os>-pgclient-<major>.tar; the acquire step must `cr load` it so a node with
# no host psql has exactly the image PROFILE_PG_CLIENT_IMAGE resolves to. Prove the dry-run plan says so.
FAKE_BUNDLE="$TMPD/kc-astra-bundle.tar.xz"
: > "$FAKE_BUNDLE"   # existence is all the dry-run plan needs — it does not extract in dry-run
bout="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db \
    --source bundle --bundle "$FAKE_BUNDLE" --dry-run </dev/null 2>&1 || true)"
assert_contains "$bout" "cr load -i"            "the bundle plan loads images"
assert_contains "$bout" "kc-astra-pgclient-"    "and it loads the sovereign pg-client image (discovered by glob)"

describe "F2: --db-url (DSN) parses into DB_* fields; discrete flags override"
dsn_out="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra \
    --db-url 'postgres://alice:secret@dbhost:6543/kkdb?currentSchema=kc' --dry-run </dev/null 2>&1 || true)"
assert_contains "$dsn_out" "alice@dbhost:6543/kkdb"      "DSN sets user/host/port/name"
assert_contains "$dsn_out" "(schema: kc)"               "DSN currentSchema sets the schema"
assert_contains "$dsn_out" "password taken from --db-url" "a password in the URL warns (ps/history leak)"
# discrete flags win over the DSN regardless of order
ovr_out="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra \
    --db-url 'postgres://alice@dbhost:6543/kkdb' --db-host OVERRIDE.example --db-port 5999 --dry-run </dev/null 2>&1 || true)"
assert_contains "$ovr_out" "alice@OVERRIDE.example:5999/kkdb" "discrete --db-host/--db-port override the DSN"
assert_exit_code 2 "bash '$ONESHOT' --db-url notaurl </dev/null" "a non-postgres:// --db-url is rejected"

describe "F2: --db-schema — non-public reaches the plan, public stays the clean default"
sch_out="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db \
    --db-schema kc --dry-run </dev/null 2>&1 || true)"
assert_contains "$sch_out" "(schema: kc)" "--db-schema is shown in the banner"
pub_out="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db \
    --dry-run </dev/null 2>&1 || true)"
assert_true "! printf '%s' \"\$pub_out\" | grep -q 'schema:'" "public schema keeps the banner clean (no annotation)"

test_report
