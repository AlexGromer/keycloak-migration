#!/usr/bin/env bash
# Tests: scripts/build_bundle.sh — the air-gap bundle.
#
# This step never existed as code. dist/kc-<os>-bundle.tar.xz — the file every air-gapped migration
# consumes — was packed by hand, once, and its shape survived only in a sentence of prose. The
# structure asserted here was verified against the real hand-made bundle:
#
#     $ tar -tJf dist/kc-astra-bundle.tar.xz
#     kc-astra-16.1.1.tar
#     kc-astra-24.0.5.tar
#     kc-astra-25.0.6.tar
#     kc-astra-26.6.3.tar
#
# Flat, one `docker save` tarball per hop — NOT a single multi-image save. migrate_oneshot.sh
# --source bundle unpacks it and `cr load -i`s each member by that exact name, so the naming is a
# contract, not a convention.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BUILD="$PROJECT_ROOT/scripts/build_bundle.sh"
VERSIONS=(16.1.1 24.0.5 25.0.6 26.6.3)

# ---------------------------------------------------------------------------
describe "a bundle that is short one hop is refused, not shipped"
# A missing member fails at the worst possible moment: mid-migration, on an air-gapped host, with no
# registry to fall back on. Catch it here instead.

mkdir -p "$TMP/dist"
printf 'not-a-real-image' > "$TMP/dist/kc-astra-16.1.1.tar"
printf 'not-a-real-image' > "$TMP/dist/kc-astra-24.0.5.tar"
# 25.0.6 and 26.6.3 deliberately absent.

out="$(bash "$BUILD" --os astra --dist-dir "$TMP/dist" 2>&1 || true)"
assert_contains "$out" "Missing image tarball" "an incomplete set is refused"
assert_contains "$out" "kc-astra-26.6.3.tar"   "and the missing member is named"
assert_contains "$out" "build_matrix.sh"       "with the command that produces it"

rc=0
bash "$BUILD" --os astra --dist-dir "$TMP/dist" >/dev/null 2>&1 || rc=$?
assert_true "[[ $rc -ne 0 ]]" "and it exits non-zero"

# ---------------------------------------------------------------------------
describe "dry-run is the default and packs nothing"
for v in "${VERSIONS[@]}"; do
    printf 'fake-image-layer-%s' "$v" > "$TMP/dist/kc-astra-${v}.tar"
done

out="$(bash "$BUILD" --os astra --dist-dir "$TMP/dist" 2>&1)"
assert_contains "$out" "DRY-RUN"        "no --go means dry-run"
assert_contains "$out" "members   : 4/4" "it found every hop"
assert_true "[[ ! -f '$TMP/dist/kc-astra-bundle.tar.xz' ]]" \
    "and wrote no bundle"

# ---------------------------------------------------------------------------
describe "--go packs exactly the four hop tarballs, flat"
out="$(bash "$BUILD" --os astra --dist-dir "$TMP/dist" --go 2>&1)"
bundle="$TMP/dist/kc-astra-bundle.tar.xz"

assert_true "[[ -f '$bundle' ]]" "the bundle exists"
assert_true "[[ -f '${bundle}.sha256' ]]" "with a checksum beside it"

listed="$(tar -tJf "$bundle" | sed '/^$/d' | sort | tr '\n' ' ')"
assert_equals "kc-astra-16.1.1.tar kc-astra-24.0.5.tar kc-astra-25.0.6.tar kc-astra-26.6.3.tar " \
    "$listed" \
    "the members are the four hop tarballs, at the archive root (this is what oneshot expects)"

# The checksum must be OF the bundle, not of something else in the directory.
if ( cd "$TMP/dist" && sha256sum -c "kc-astra-bundle.tar.xz.sha256" >/dev/null 2>&1 ); then
    assert_true "true"  "the recorded checksum verifies"
else
    assert_true "false" "the recorded checksum verifies"
fi

assert_contains "$out" "Verifying the bundle lists all 4 members" \
    "it lists the archive back before declaring success — an archive nobody read is an archive nobody knows"

# ---------------------------------------------------------------------------
describe "the round trip: what oneshot --source bundle will actually do to it"
# It unpacks the bundle and loads each member by name. Prove the names survive.
mkdir -p "$TMP/unpack"
tar -xJf "$bundle" -C "$TMP/unpack"
for v in "${VERSIONS[@]}"; do
    assert_true "[[ -f '$TMP/unpack/kc-astra-${v}.tar' ]]" \
        "after extraction, kc-astra-${v}.tar is where 'cr load -i' will look for it"
done

# ---------------------------------------------------------------------------
describe "redos is a first-class OS, not an afterthought"
for v in "${VERSIONS[@]}"; do
    printf 'fake-image-layer-%s' "$v" > "$TMP/dist/kc-redos-${v}.tar"
done
bash "$BUILD" --os redos --dist-dir "$TMP/dist" --go >/dev/null 2>&1
assert_true "[[ -f '$TMP/dist/kc-redos-bundle.tar.xz' ]]" "a redos bundle builds too"

out="$(bash "$BUILD" --os windows --dist-dir "$TMP/dist" 2>&1 || true)"
assert_contains "$out" "must be astra|redos" "an unknown OS is rejected"

# ---------------------------------------------------------------------------
describe "the sovereign pg-client image rides INSIDE the bundle (v3.9.7 autonomy)"
# An air-gapped node with no host psql runs pg_dump/pg_restore/psql from this image — it must travel
# in the bundle or the offline node has no way to get it. migrate_oneshot loads it by this exact name.
PGC="$TMP/pgc"
mkdir -p "$PGC"
for v in "${VERSIONS[@]}"; do
    printf 'fake-image-layer-%s' "$v" > "$PGC/kc-astra-${v}.tar"
done
printf 'fake-pgclient-image' > "$PGC/kc-astra-pgclient-17.tar"

out="$(bash "$BUILD" --os astra --dist-dir "$PGC" --go 2>&1)"
assert_contains "$out" "pg-client : kc-astra-pgclient-17.tar" "the banner reports the bundled pg-client"
assert_contains "$out" "members   : 4/4" "the hop count still reads 4/4 (pg-client is counted apart)"

pgc_bundle="$PGC/kc-astra-bundle.tar.xz"
listed="$(tar -tJf "$pgc_bundle" | sed '/^$/d' | sort | tr '\n' ' ')"
assert_equals "kc-astra-16.1.1.tar kc-astra-24.0.5.tar kc-astra-25.0.6.tar kc-astra-26.6.3.tar kc-astra-pgclient-17.tar " \
    "$listed" \
    "the bundle carries the four hops AND the pg-client image, flat at the archive root"

# ---------------------------------------------------------------------------
describe "a bundle without pg-client still builds, and says so (host-psql node / older delivery)"
# Its absence is a warning, not a stop: a node that already has host psql is valid.
NOPGC="$TMP/nopgc"
mkdir -p "$NOPGC"
for v in "${VERSIONS[@]}"; do
    printf 'fake-image-layer-%s' "$v" > "$NOPGC/kc-astra-${v}.tar"
done
out="$(bash "$BUILD" --os astra --dist-dir "$NOPGC" --go 2>&1)"
assert_contains "$out" "pg-client : none" "no pg-client tar -> the banner says none"
assert_contains "$out" "the bundle will NOT carry the sovereign" "and it warns the air-gap node may lack a client"
assert_true "[[ -f '$NOPGC/kc-astra-bundle.tar.xz' ]]" "but the bundle is still produced"

test_report
