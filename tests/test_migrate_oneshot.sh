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
# DIAGNOSTIC: this assertion failed ONCE inside a full-suite run and never reproduced (standalone 3/3
# correct, clean re-run green). If it ever fails again, leave evidence instead of a mystery.
if ! printf '%s' "$content" | grep -q 'deployment_mode: run'; then
    echo "    --- generated profile (flake evidence) ---" >&2
    sed -n '1,25p' "$f" | sed 's/^/    /' >&2
    echo "    --- oneshot output ---" >&2
    printf '%s\n' "$gen" | tail -15 | sed 's/^/    /' >&2
fi
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

describe "F2: pg-client image — the SOVEREIGN per-OS client is the default (air-gap regression)"
# REGRESSION (found on a customer's air-gapped node): oneshot sources migrate_keycloak_v3.sh, which
# pulls in container_runtime.sh, which defaults PROFILE_PG_CLIENT_IMAGE to postgres:16. The
# "did the caller pin one?" probe used to run AFTER that source, so every run looked pinned — the
# sovereign default never applied and `--source bundle` never repointed at the client it had just
# loaded. Preflight then failed with "no postgres:16 image" while the sovereign client sat loaded
# and unused. The pin must therefore be captured BEFORE that source.
src_line="$(grep -n 'source .*scripts/migrate_keycloak_v3.sh' "$ONESHOT" | head -1 | cut -d: -f1)"
pin_line="$(grep -n '^_PG_CLIENT_IMAGE_EXPLICIT=' "$ONESHOT" | head -1 | cut -d: -f1)"
assert_true "[ -n '$pin_line' ] && [ -n '$src_line' ] && [ '$pin_line' -lt '$src_line' ]" \
    "the pg-client pin is captured BEFORE the source that defaults it to postgres:16"

pgc_out="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db --dry-run </dev/null 2>&1 || true)"
assert_contains "$pgc_out" "pg-client   : ghcr.io/alexgromer/keycloak-migration:astra-pgclient-17" \
    "unpinned -> the sovereign per-OS client, not postgres:16"
pgc_redos="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 25 --os redos --db-host db --dry-run </dev/null 2>&1 || true)"
assert_contains "$pgc_redos" "redos-pgclient-17" "the default follows --os"
pgc_major="$(KC_PG_CLIENT_MAJOR=18 PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db --dry-run </dev/null 2>&1 || true)"
assert_contains "$pgc_major" "astra-pgclient-18" "KC_PG_CLIENT_MAJOR selects the client major"
pgc_pin="$(PROFILE_PG_CLIENT_IMAGE=postgres:16 PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db --dry-run </dev/null 2>&1 || true)"
assert_contains "$pgc_pin" "pg-client   : postgres:16 (pinned)" "an explicit pin still wins, and says so"

# The profile (and its pg-client sidecar) is written BEFORE acquisition, so the sidecar must be
# refreshed AFTER it — otherwise a bundle carrying a non-default major (kc-<os>-pgclient-19.tar), or
# the postgres:16 fallback, leaves `verify --profile` pointing at an image this node never received.
acq_line="$(grep -n '^acquire_images$' "$ONESHOT" | tail -1 | cut -d: -f1)"
sid_line="$(grep -n 'PROFILE_NAME}.pg-client' "$ONESHOT" | tail -1 | cut -d: -f1)"
assert_true "[ -n '$acq_line' ] && [ -n '$sid_line' ] && [ '$sid_line' -gt '$acq_line' ]" \
    "the pg-client sidecar is refreshed AFTER acquisition (records what the run actually resolved)"

describe "F2: --profile does not hand the child the source-time postgres:16 (air-gap re-run)"
# Sourcing migrate_keycloak_v3.sh EXPORTS PROFILE_PG_CLIENT_IMAGE=postgres:16 (container_runtime.sh).
# The --profile / --wizard branch execs before the sovereign-default block, so the child used to
# inherit that value, recompute "the caller pinned an image", and SKIP restoring the profile's
# .pg-client sidecar — the original air-gap failure, on the documented re-run path.
# A shim `bash` intercepts the exec and reports what the child was handed.
SHIM="$TMPD/shim"; mkdir -p "$SHIM"
# NOTE: no [brackets] in the marker — assert_contains greps as a REGEX, and [..] would be a char class.
# shellcheck disable=SC2016  # intentional: ${...} must reach the shim UNEXPANDED, it expands there
printf '#!/bin/sh\necho "CHILD-PGCLIENT=${PROFILE_PG_CLIENT_IMAGE-NONE}"\nexit 0\n' > "$SHIM/bash"
chmod +x "$SHIM/bash"
printf 'profile:\n  name: reuse\n' > "$TMPD/reuse.yaml"
# NOTE: the outer interpreter is called by ABSOLUTE path, so only the script's own `exec bash` is shimmed.
child_unpinned="$(PATH="$SHIM:$PATH" PROFILE_DIR="$TMPD" timeout 60 /bin/bash "$ONESHOT" --profile reuse --dry-run </dev/null 2>&1 || true)"
assert_contains "$child_unpinned" "CHILD-PGCLIENT=NONE" \
    "unpinned: the child is NOT handed postgres:16, so it can restore the profile's sovereign client"
child_pinned="$(PROFILE_PG_CLIENT_IMAGE=myreg/pg:17 PATH="$SHIM:$PATH" PROFILE_DIR="$TMPD" timeout 60 /bin/bash "$ONESHOT" --profile reuse --dry-run </dev/null 2>&1 || true)"
assert_contains "$child_pinned" "CHILD-PGCLIENT=myreg/pg:17" \
    "a genuine caller pin is still handed through untouched"

describe "F2: --source bundle asserts the hop images it loaded are the ones this run will START"
# A bundle's tars carry the tags they were BUILT with. With a custom --image-ref-template (or an
# empty KC_IMAGE_NS) every load succeeds and the FIRST HOP then dies on a missing image — after the
# advisory lock and the first backup. --source preloaded always asserted this; --source bundle did not.
bundle_branch="$(sed -n '/^        bundle)/,/^        preloaded)/p' "$ONESHOT")"
assert_true "printf '%s' \"\$bundle_branch\" | grep -q 'cr image inspect'" \
    "the bundle branch verifies each hop ref resolves locally after loading"
assert_true "printf '%s' \"\$bundle_branch\" | grep -q 'image-ref-template'" \
    "and the failure names the setting that caused the mismatch"


describe "F2: --source pull also obtains the sovereign pg-client (nothing else pulls it)"
# `pull` is the DEFAULT acquisition. It pulled only the hop images, so on a node with no host psql the
# client the tool had just selected as its default was never obtained: the run silently degraded to
# postgres:16 or failed preflight.
pull_branch="$(sed -n '/^        pull)/,/^        bundle)/p' "$ONESHOT")"
assert_true "printf '%s' \"\$pull_branch\" | grep -q 'PROFILE_PG_CLIENT_IMAGE'" \
    "the pull branch pulls the pg-client image too"
assert_true "printf '%s' \"\$pull_branch\" | grep -q '_PG_CLIENT_IMAGE_EXPLICIT'" \
    "…only when the caller pinned nothing"

describe "F2: the preflight password has a default (set -u would abort a PGPASSWORD-only run)"
MIGRATE_V3="$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"
assert_true "grep -q 'PROFILE_DB_PASSWORD:-\${PGPASSWORD' '$MIGRATE_V3'" \
    "run_all_preflight_checks gets the same password precedence as every other consumer"


describe "F2: guardrails the audit's last batch added"
# 1) An image reference with no registry/namespace resolves as docker.io/library/<name>. Only the
#    presence of {version} used to be validated, so a tag-shaped template passed and the run died at
#    the first hop on a missing image — the failure a customer node was heading for.
noreg="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db \
    --image-ref-template 'astra-{version}' --dry-run </dev/null 2>&1 || true)"
assert_contains "$noreg" "carries no registry/namespace" "a tag-shaped image ref is called out"
assert_contains "$noreg" "Docker Hub"                    "…and the consequence is named"
full="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db \
    --image-ref-template 'registry.corp/keycloak:{version}' --dry-run </dev/null 2>&1 || true)"
assert_true "! printf '%s' \"\$full\" | grep -q 'carries no registry'" "a full reference passes quietly"

# 2) A bundle path with the DEFAULT source silently went to a registry instead.
: > "$TMPD/ignored.tar.xz"
ignb="$(PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host db \
    --bundle "$TMPD/ignored.tar.xz" --dry-run </dev/null 2>&1 || true)"
assert_contains "$ignb" "the bundle is NOT used" "a bundle that will not be used is announced"

# 3) --network wired ONLY the Keycloak container; the pg-client (which talks to the database) had no
#    flag at all, so a DB reachable only by container name was unreachable for every psql call.
PROFILE_DIR="$TMPD" timeout 60 bash "$ONESHOT" --target 26 --os astra --db-host kc-db \
    --network kc-net --profile-name nettest2 --gen-profile-only </dev/null >/dev/null 2>&1 || true
netprof="$(<"$TMPD/nettest2.yaml")"
assert_contains "$netprof" "run_network: kc-net"       "--network reaches the Keycloak container"
assert_contains "$netprof" "pg_client_network: kc-net" "…and the pg-client container too"

# 4) A trailing flag with no value used to abort SILENTLY: `shift 2` returns 1 with one arg left and
#    set -e killed the script before any message could be printed.
trail="$(timeout 30 bash "$ONESHOT" --target </dev/null 2>&1 || true)"
# NOTE: the needle must not start with '--' — assert_contains greps, and grep reads it as options.
assert_contains "$trail" "target is required" "a trailing flag reports the real problem, not silence"

# 5) The bundle repoint must use the tag the archive ACTUALLY carries, not one rebuilt from IMAGE_NS
#    (a bundle built into the operator's own registry carries a different namespace).
bundle_branch2="$(sed -n '/^        bundle)/,/^        preloaded)/p' "$ONESHOT")"
assert_true "printf '%s' \"\$bundle_branch2\" | grep -q 'Loaded image'" \
    "the loaded tag is parsed from the engine output"
assert_true "printf '%s' \"\$bundle_branch2\" | grep -q 'carries images for OS'" \
    "a bundle for the other OS is named as such, not left as a raw engine error"

test_report
