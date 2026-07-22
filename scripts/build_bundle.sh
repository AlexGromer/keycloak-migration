#!/usr/bin/env bash
#
# build_bundle.sh — pack the per-hop image tarballs into the air-gap bundle.
#
# This step did not exist. `dist/kc-astra-bundle.tar.xz` — the thing every air-gapped migration
# consumes — was produced by hand, once, and its shape survived only in a sentence in
# docs/MIGRATION_GUIDE.md. An undocumented manual step between "build the images" and "hand the
# operator a file" is a step that will eventually be done differently.
#
# The bundle is a tar.xz of the individual `docker save` tarballs — NOT a single multi-image save.
# migrate_oneshot.sh --source bundle unpacks it and `cr load -i`s each one:
#
#     kc-astra-bundle.tar.xz
#       kc-astra-16.1.1.tar
#       kc-astra-24.0.5.tar
#       kc-astra-25.0.6.tar
#       kc-astra-26.6.3.tar
#
# Usage:
#   scripts/build_bundle.sh --os astra                       # dry-run: says what it would pack
#   scripts/build_bundle.sh --os astra --go                  # pack dist/kc-astra-bundle.tar.xz
#   scripts/build_bundle.sh --os redos --dist-dir /mnt/out --go
#   scripts/build_bundle.sh --os astra --versions 24.0.5,25.0.6,26.6.3 --go  # subset of hops
#
#   --versions CSV overrides the default hop set (16.1.1,24.0.5,25.0.6,26.6.3). Pass the SAME set
#   build_matrix built, or the "missing member" check refuses the bundle. The sovereign pg-client
#   tar (kc-<os>-pgclient-*.tar) is auto-included whenever present, independent of --versions.
#
# Produce the input tarballs first:
#   scripts/build_matrix.sh --build            # writes dist/kc-<os>-<version>.tar

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$BUNDLE_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/validation.sh" 2>/dev/null || true

log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
log_warn()    { echo -e "\033[1;33m[!]\033[0m $*"; }
log_error()   { echo -e "\033[0;31m[✗]\033[0m $*" >&2; }
log_success() { echo -e "\033[0;32m[✓]\033[0m $*"; }

OS="astra"
DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"
GO="false"

# Every version the tool can hop through, for either target. A bundle missing one is a migration
# that dies halfway.
VERSIONS=(16.1.1 24.0.5 25.0.6 26.6.3)

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)        OS="${2:-}"; shift 2 ;;
        --dist-dir)  DIST_DIR="${2:-}"; shift 2 ;;
        --versions)  IFS=',' read -r -a VERSIONS <<< "${2:-}"; shift 2 ;;
        --go)        GO="true"; shift ;;
        --dry-run)   GO="false"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) log_error "unknown argument: $1"; usage; exit 2 ;;
    esac
done

case "$OS" in astra|redos) ;; *) log_error "--os must be astra|redos (got '$OS')"; exit 2 ;; esac

BUNDLE="${DIST_DIR}/kc-${OS}-bundle.tar.xz"

# ----------------------------------------------------------------------------
# Every tarball must be present BEFORE we start packing. A bundle that is short one hop fails at
# the worst possible moment — mid-migration, on the operator's air-gapped host, with no registry to
# fall back on.
# ----------------------------------------------------------------------------
missing=()
members=()
for v in "${VERSIONS[@]}"; do
    tar_name="kc-${OS}-${v}.tar"
    if [[ -f "${DIST_DIR}/${tar_name}" ]]; then
        members+=("$tar_name")
    else
        missing+=("$tar_name")
    fi
done
kc_count=${#members[@]}   # the REQUIRED hop members; pg-client below is counted separately

# pg-client autonomy (v3.9.7, ADR-013): the sovereign PostgreSQL-client image travels INSIDE the
# bundle so an air-gapped node with no host psql can still run pg_dump/pg_restore/psql — from the
# container. Produced by `build_matrix.sh --pgclient` as kc-<os>-pgclient-<major>.tar (one per OS).
# OPTIONAL, unlike the hops: a node that has host psql, or an older bundle, is still valid — so a
# missing pg-client is a warning, not a failure. migrate_oneshot.sh --source bundle loads it if
# present (matching PROFILE_PG_CLIENT_IMAGE), else falls back to host psql.
shopt -s nullglob
pgclient_paths=("${DIST_DIR}"/kc-"${OS}"-pgclient-*.tar)
shopt -u nullglob
pgclient_members=()
for pt in "${pgclient_paths[@]}"; do
    bn="$(basename "$pt")"
    pgclient_members+=("$bn")
    members+=("$bn")
done

echo "=============================================================="
echo " Air-gap bundle: ${OS}"
echo "   mode      : $([[ "$GO" == "true" ]] && echo PACK || echo DRY-RUN)"
echo "   dist dir  : ${DIST_DIR}"
echo "   bundle    : ${BUNDLE}"
echo "   members   : ${kc_count}/${#VERSIONS[@]}"
if (( ${#pgclient_members[@]} > 0 )); then
    echo "   pg-client : ${pgclient_members[*]}"
else
    echo "   pg-client : none (autonomy relies on host psql on the target node)"
fi
echo "=============================================================="

if (( ${#pgclient_members[@]} == 0 )); then
    log_warn "No kc-${OS}-pgclient-*.tar in ${DIST_DIR} — the bundle will NOT carry the sovereign"
    log_warn "pg-client. A fully air-gapped node WITHOUT host psql then can't dump/restore."
    log_warn "Build it first:  scripts/build_matrix.sh --pgclient --os ${OS}"
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing image tarball(s) in ${DIST_DIR}:"
    for m in "${missing[@]}"; do log_error "    $m"; done
    log_error ""
    log_error "Build them first:  scripts/build_matrix.sh --build"
    exit 1
fi

for m in "${members[@]}"; do
    size="$(du -h "${DIST_DIR}/${m}" 2>/dev/null | cut -f1)"
    log_info "  ${m}  (${size})"
done

if [[ "$GO" != "true" ]]; then
    echo ""
    log_info "DRY-RUN: would run"
    log_info "    tar -cJf ${BUNDLE} -C ${DIST_DIR} ${members[*]}"
    log_info "    sha256sum $(basename "$BUNDLE") > $(basename "$BUNDLE").sha256"
    log_info "Re-run with --go to pack it."
    exit 0
fi

# ----------------------------------------------------------------------------
log_info "Packing (xz is slow on ~2GB of image layers — this takes a while)"

# -T0: all cores. The bundles run to 1.7 GiB and single-threaded xz on them is measured in tens of
# minutes.
XZ_OPT="${XZ_OPT:--T0}" tar -cJf "$BUNDLE" -C "$DIST_DIR" "${members[@]}"

( cd "$DIST_DIR" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

# Prove the archive is readable and holds exactly what we meant to put in it. An archive nobody has
# listed is an archive nobody knows the contents of.
log_info "Verifying the bundle lists all ${#members[@]} members"
listed="$(tar -tJf "$BUNDLE" | sed '/^$/d' | sort)"
expected="$(printf '%s\n' "${members[@]}" | sort)"

if [[ "$listed" != "$expected" ]]; then
    log_error "The bundle does not contain what it should."
    log_error "Expected:"; printf '    %s\n' "${members[@]}" >&2
    log_error "Found:";    printf '%s\n' "$listed" | sed 's/^/    /' >&2
    exit 1
fi

size="$(du -h "$BUNDLE" | cut -f1)"
log_success "Bundle: ${BUNDLE} (${size})"
log_success "Digest: $(cut -d' ' -f1 < "${BUNDLE}.sha256")"
echo ""
log_info "Consume it on the air-gapped host with:"
log_info "    scripts/migrate_oneshot.sh --target 26 --os ${OS} \\"
log_info "        --source bundle --bundle $(basename "$BUNDLE") --go"

# A GitHub Release asset is capped at 2 GiB. The bundles sit right under it, so say so rather than
# let a release fail on upload.
size_bytes="$(stat -c '%s' "$BUNDLE" 2>/dev/null || echo 0)"
if (( size_bytes > 1932735283 )); then   # 1.8 GiB
    echo ""
    log_warn "This bundle is $(( size_bytes / 1048576 ))MB — close to GitHub's 2GiB asset limit."
    log_warn "Deliver it out-of-band (object storage, physical media), not as a Release asset."
fi
