#!/usr/bin/env bash
#
# migrate_oneshot.sh — one-command Keycloak container-hop migration (v3.9).
#
# Wraps migrate_keycloak_v3.sh end-to-end:
#   1) acquire the per-hop sovereign images (pull / load-from-bundle / preloaded),
#   2) generate a run+container profile,
#   3) run the FULL migration non-interactively (migrate --yes).
#
# Relies on two v3.9 enablers so NO image re-tag is needed:
#   - PROFILE_CONTAINER_IMAGE_REF env precedence in profile_load (profile_manager.sh):
#     the <os>-<version> tag (e.g. astra-26.6.3) is used directly.
#   - migrate_keycloak_v3.sh --yes (non-interactive, fail-closed otherwise).
#
# DEFAULT = DRY-RUN: prints every acquire/migrate command, MUTATES NOTHING.
# Live execution requires --go AND PROFILE_DB_PASSWORD in the environment.
#
# Usage:
#   migrate_oneshot.sh [--target 25|26] [--os astra|redos] [--go]
#                      [--db-host H] [--db-port P] [--db-name N] [--db-user U]
#                      [--source pull|bundle|preloaded] [--image-ns REF]
#                      [--bundle FILE] [--network NET] [--current VER]
#                      [--profile-name NAME] [--gen-profile-only] [--yes] [-h]
#
# Examples:
#   # Safe plan for Path B (target 26): 16.1.1 -> 24.0.5 -> 26.6.3
#   scripts/migrate_oneshot.sh --target 26 --os astra --dry-run
#   # Live Path A (target 25) from a private GHCR pull:
#   export PROFILE_DB_PASSWORD=...; \
#   scripts/migrate_oneshot.sh --target 25 --os astra --db-host db --go
#   # Air-gap (load from bundle) then migrate:
#   scripts/migrate_oneshot.sh --target 26 --source bundle --bundle dist/kc-astra-bundle.tar.xz --go

set -euo pipefail

ONESHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ONESHOT_DIR/.." && pwd)"

# Contain source-time writes of migrate_keycloak_v3.sh (it mkdir's WORK_DIR at source time).
ONESHOT_WORK_DIR="${ONESHOT_WORK_DIR:-$(mktemp -d)}"
export WORK_DIR="$ONESHOT_WORK_DIR"
# Best-effort cleanup of the scratch dir on non-exec exits (gen-profile-only / validation
# errors). The live/dry-run paths end in `exec`, which intentionally keeps WORK_DIR (the live
# migrate writes backups/logs there); those temp dirs live under $TMPDIR and are OS-reclaimed.
trap 'rm -rf "$ONESHOT_WORK_DIR" 2>/dev/null || true' EXIT

# Profiles live in the repo by default (overridable for tests).
export PROFILE_DIR="${PROFILE_DIR:-$PROJECT_ROOT/profiles}"

# Reuse the migration tool's functions (its main() is guarded -> sourcing is side-effect free
# beyond WORK_DIR creation). Gives: MIGRATION_HOPS, MIGRATION_TARGET_FULL,
# kc_build_migration_path, dist_image_ref, profile_save, cr/cr_detect, log_*.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh"

# ----------------------------------------------------------------------------
# Defaults (overridable via flags)
# ----------------------------------------------------------------------------
OS="astra"
TARGET="$DEFAULT_TARGET_MAJOR"     # 26 by default (from migrate_keycloak_v3.sh)
CURRENT="16.1.1"
SRC="pull"                         # pull | bundle | preloaded
IMAGE_NS="ghcr.io/alexgromer/keycloak-migration"
BUNDLE=""
NETWORK=""
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="keycloak"
DB_USER="keycloak"
PROFILE_NAME_OPT=""
GEN_ONLY="false"
ONESHOT_DRY="true"                 # default dry-run; --go flips to live

oneshot_usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'; }

# Dry/live execution chokepoint (secrets must be pre-masked by the caller).
_os_run() {
    local emit="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    if [[ "$ONESHOT_DRY" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "$emit"
        return 0
    fi
    log_info "RUN: $emit"
    "$@"
}

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)           TARGET="${2:-}"; shift 2 ;;
        --os)               OS="${2:-}"; shift 2 ;;
        --current)          CURRENT="${2:-}"; shift 2 ;;
        --source)           SRC="${2:-}"; shift 2 ;;
        --image-ns)         IMAGE_NS="${2:-}"; shift 2 ;;
        --bundle)           BUNDLE="${2:-}"; shift 2 ;;
        --network)          NETWORK="${2:-}"; shift 2 ;;
        --db-host)          DB_HOST="${2:-}"; shift 2 ;;
        --db-port)          DB_PORT="${2:-}"; shift 2 ;;
        --db-name)          DB_NAME="${2:-}"; shift 2 ;;
        --db-user)          DB_USER="${2:-}"; shift 2 ;;
        --profile-name)     PROFILE_NAME_OPT="${2:-}"; shift 2 ;;
        --gen-profile-only) GEN_ONLY="true"; shift ;;
        --dry-run)          ONESHOT_DRY="true"; shift ;;
        --go)               ONESHOT_DRY="false"; shift ;;
        --yes|-y)           shift ;;   # accepted: oneshot is always non-interactive
        -h|--help)          oneshot_usage; exit 0 ;;
        *) log_error "unknown argument: $1"; oneshot_usage; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------
# Validate inputs
# ----------------------------------------------------------------------------
case "$OS" in astra|redos) ;; *) log_error "--os must be astra|redos (got '$OS')"; exit 2 ;; esac
case "$SRC" in pull|bundle|preloaded) ;; *) log_error "--source must be pull|bundle|preloaded (got '$SRC')"; exit 2 ;; esac
if [[ -z "$TARGET" ]]; then
    log_error "--target is required (25 or 26)"; exit 2
fi
if [[ -z "${MIGRATION_HOPS[$TARGET]:-}" ]]; then
    log_error "--target must be one of: ${!MIGRATION_HOPS[*]} (got '$TARGET')"; exit 2
fi
if [[ "$SRC" == "bundle" && -z "$BUNDLE" ]]; then
    log_error "--source bundle requires --bundle <path-to-kc-${OS}-bundle.tar.xz>"; exit 2
fi

# Build the hop chain via the tool's own resolver (single source of truth).
HOPS="$(kc_build_migration_path "$CURRENT" "$TARGET")"
TARGET_FULL="${MIGRATION_TARGET_FULL[$TARGET]}"
# shellcheck disable=SC2206  # intentional word-split of the space-separated hop list
HOP_ARR=($HOPS)

# The image ref template (env wins over YAML in profile_load -> no re-tag needed).
export PROFILE_CONTAINER_IMAGE_REF="${IMAGE_NS}:${OS}-{version}"
# Runtime: honor an explicit CONTAINER_RUNTIME; else autodetect (podman->docker).
cr_detect >/dev/null 2>&1 || true

PROFILE_NAME="${PROFILE_NAME_OPT:-oneshot-${OS}-${TARGET}}"

# Keep dry-run from writing into the repo's profiles/: use a temp profile dir unless the
# caller explicitly overrode PROFILE_DIR.
if [[ "$ONESHOT_DRY" == "true" && "$PROFILE_DIR" == "$PROJECT_ROOT/profiles" ]]; then
    export PROFILE_DIR="$ONESHOT_WORK_DIR/profiles"
    mkdir -p "$PROFILE_DIR"
fi

echo "=============================================================="
echo " Keycloak one-shot container-hop migration"
echo "   mode        : $([[ "$ONESHOT_DRY" == "true" ]] && echo DRY-RUN || echo LIVE)"
echo "   runtime     : ${CONTAINER_RUNTIME:-<autodetect>}"
echo "   os / target : ${OS} / ${TARGET} (full ${TARGET_FULL})"
echo "   chain       : ${CURRENT} -> ${HOPS// / -> }"
echo "   image ref   : ${PROFILE_CONTAINER_IMAGE_REF}"
echo "   acquisition : ${SRC}"
echo "   database    : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "   profile     : ${PROFILE_NAME} (in ${PROFILE_DIR})"
echo "=============================================================="

# ----------------------------------------------------------------------------
# Acquire per-hop images (so migrate runs with acquisition=preloaded)
# ----------------------------------------------------------------------------
acquire_images() {
    local v ref
    case "$SRC" in
        pull)
            for v in "${HOP_ARR[@]}"; do
                ref="${IMAGE_NS}:${OS}-${v}"
                _os_run "cr pull ${ref}" -- cr pull "$ref"
            done
            ;;
        bundle)
            [[ -f "$BUNDLE" ]] || { log_error "bundle not found: $BUNDLE"; exit 1; }
            local xdir="${ONESHOT_WORK_DIR}/bundle"
            mkdir -p "$xdir"
            _os_run "tar -xJf ${BUNDLE} -C ${xdir}" -- tar -xJf "$BUNDLE" -C "$xdir"
            for v in "${HOP_ARR[@]}"; do
                local tar="${xdir}/kc-${OS}-${v}.tar"
                _os_run "cr load -i ${tar}" -- cr load -i "$tar"
            done
            # Clean the extracted tars (keep only loaded images).
            [[ "$ONESHOT_DRY" == "true" ]] || rm -rf "$xdir"
            ;;
        preloaded)
            for v in "${HOP_ARR[@]}"; do
                ref="${IMAGE_NS}:${OS}-${v}"
                if [[ "$ONESHOT_DRY" == "true" ]]; then
                    printf 'DRY-RUN: %s\n' "cr image inspect ${ref}  (assert present)"
                elif ! cr image inspect "$ref" >/dev/null 2>&1; then
                    log_error "preloaded: image not present locally: $ref"; exit 1
                fi
            done
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Generate the run+container profile (profile_save emits acquisition/runtime in v3.9)
# ----------------------------------------------------------------------------
generate_profile() {
    export PROFILE_DB_TYPE="postgresql"
    export PROFILE_DB_LOCATION="standalone"
    export PROFILE_DB_HOST="$DB_HOST"
    export PROFILE_DB_PORT="$DB_PORT"
    export PROFILE_DB_NAME="$DB_NAME"
    export PROFILE_DB_USER="$DB_USER"
    export PROFILE_DB_CREDENTIALS_SOURCE="env"
    export PROFILE_KC_DEPLOYMENT_MODE="run"
    export PROFILE_KC_DISTRIBUTION_MODE="container"
    export PROFILE_KC_CLUSTER_MODE="standalone"
    export PROFILE_KC_CURRENT_VERSION="$CURRENT"
    export PROFILE_KC_TARGET_VERSION="$TARGET_FULL"
    export PROFILE_KC_RUN_CONTAINER_NAME="kc-migrate"
    # registry/image are cosmetic here (PROFILE_CONTAINER_IMAGE_REF env wins), but keep tidy.
    export PROFILE_CONTAINER_REGISTRY="${IMAGE_NS%/*}"
    export PROFILE_CONTAINER_IMAGE="${IMAGE_NS##*/}"
    export PROFILE_CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
    export PROFILE_CONTAINER_ACQUISITION="preloaded"   # images pre-acquired above
    export PROFILE_MIGRATION_STRATEGY="inplace"
    export PROFILE_MIGRATION_PARALLEL_JOBS="1"
    export PROFILE_MIGRATION_TIMEOUT="900"
    export PROFILE_MIGRATION_RUN_TESTS="false"
    export PROFILE_MIGRATION_BACKUP="true"
    [[ -n "$NETWORK" ]] && export PROFILE_KC_RUN_NETWORK="$NETWORK"

    profile_save "$PROFILE_NAME" >/dev/null
    log_success "Profile written: ${PROFILE_DIR}/${PROFILE_NAME}.yaml"
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
generate_profile

if [[ "$GEN_ONLY" == "true" ]]; then
    echo ""
    log_info "Profile generated. To migrate later:"
    echo "  export CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-docker}"
    echo "  export PROFILE_CONTAINER_IMAGE_REF='${PROFILE_CONTAINER_IMAGE_REF}'"
    echo "  export PROFILE_DB_PASSWORD=<...>"
    echo "  scripts/migrate_keycloak_v3.sh migrate --profile ${PROFILE_NAME} --yes"
    exit 0
fi

# Live runs need the DB password in the environment.
if [[ "$ONESHOT_DRY" != "true" && -z "${PROFILE_DB_PASSWORD:-}" ]]; then
    log_error "live (--go) requires PROFILE_DB_PASSWORD in the environment"; exit 1
fi

acquire_images

# Hand off to the migration tool (non-interactive). PROFILE_CONTAINER_IMAGE_REF +
# PROFILE_DB_PASSWORD are already exported and survive profile_load (env precedence).
MIGRATE_ARGS=(migrate --profile "$PROFILE_NAME" --yes)
if [[ "$ONESHOT_DRY" == "true" ]]; then
    # dry-run is a PLAN: skip env preflight (disk/tools) so the plan prints on any host.
    MIGRATE_ARGS+=(--dry-run --skip-preflight)
fi

log_info "Handing off: migrate_keycloak_v3.sh ${MIGRATE_ARGS[*]}"
# Invoke via `bash` so it works regardless of the file's executable bit.
exec bash "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" "${MIGRATE_ARGS[@]}"
