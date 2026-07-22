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
# THREE WAYS TO CONFIGURE IT — pick one, they do not have to be combined:
#
#   1. Flags          everything on the command line (below)
#   2. --env-file F   a file of KEY=VALUE lines, so the password and the rest are not in your
#                     shell history. Must be mode 0600 or stricter.
#   3. --wizard       interactive: asks the questions, writes profiles/<name>.yaml, migrates
#   ...and --profile NAME reuses a profile written earlier by any of the three.
#
# Usage:
#   migrate_oneshot.sh [--target 25|26] [--os astra|redos] [--go]
#                      [--db-host H] [--db-port P] [--db-name N] [--db-user U]
#                      [--source pull|bundle|preloaded] [--image-ns REF]
#                      [--image-ref-template 'registry/img:{version}']
#                      [--bundle FILE] [--network NET] [--current VER]
#                      [--work-dir DIR] [--skip-preflight] [--apply-indexes]
#                      [--env-file FILE] [--wizard] [--profile NAME]
#                      [--profile-name NAME] [--gen-profile-only] [--yes] [-h]
#
# IMAGES — three sources, and none of them has to be our bundle:
#   --source pull      pull from a registry. Your OWN registry works: point --image-ns at it.
#   --source bundle    load from an offline tar.xz (air-gap). Needs --bundle FILE.
#   --source preloaded the images are ALREADY in the local container runtime; use them as they are.
#
#   Image names default to <image-ns>:<os>-<version>, e.g. registry.corp/kc:astra-26.6.3.
#   If your images are not named that way, describe them instead:
#       --image-ref-template 'registry.corp.local/keycloak:{version}'
#   {version} is replaced per hop (24.0.5, 26.6.3, ...). Anything the runtime can pull works.
#
# DISK: the preflight measures what the backups will need (table data x hop count) instead of
#       demanding a fixed amount. Point --work-dir at a roomy filesystem for large databases.
#       A caller-supplied work dir is NEVER deleted.
#
# Examples:
#   # Safe plan for Path B (target 26): 16.1.1 -> 24.0.5 -> 26.6.3. Mutates nothing.
#   scripts/migrate_oneshot.sh --target 26 --os astra --dry-run
#
#   # Live, from YOUR company registry (images named <ns>:<os>-<version>):
#   export PROFILE_DB_PASSWORD=...
#   scripts/migrate_oneshot.sh --target 26 --source pull \
#       --image-ns registry.corp.local/keycloak/kc-migration --db-host db --go
#
#   # Live, from YOUR company registry with YOUR OWN naming scheme:
#   scripts/migrate_oneshot.sh --target 26 --source pull \
#       --image-ref-template 'registry.corp.local/keycloak:{version}' --db-host db --go
#
#   # Air-gap (load from our bundle) + roomy work dir:
#   scripts/migrate_oneshot.sh --target 26 --source bundle --bundle dist/kc-astra-bundle.tar.xz \
#       --work-dir /var/lib/kcwork --go
#
#   # No flags at all: keep the settings (and the password) in a 0600 file.
#   scripts/migrate_oneshot.sh --env-file /etc/kc-migration.env --go
#
#   # No flags and no file: be asked.
#   scripts/migrate_oneshot.sh --wizard

set -euo pipefail

ONESHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ONESHOT_DIR/.." && pwd)"

# Two flags must take effect BEFORE anything else reads the environment:
#   --env-file  it SUPPLIES the environment (including PROFILE_DB_PASSWORD)
#   --work-dir  migrate_keycloak_v3.sh mkdir's WORK_DIR at source time
# So pre-scan for both.
_os_args=("$@")
_ONESHOT_ENV_FILE=""
for ((_i = 0; _i < ${#_os_args[@]}; _i++)); do
    case "${_os_args[_i]}" in
        --work-dir)
            ONESHOT_WORK_DIR="${_os_args[_i+1]:-}"
            [[ -n "$ONESHOT_WORK_DIR" ]] || { echo "ERROR: --work-dir requires a path" >&2; exit 2; }
            ;;
        --env-file)
            _ONESHOT_ENV_FILE="${_os_args[_i+1]:-}"
            [[ -n "$_ONESHOT_ENV_FILE" ]] || { echo "ERROR: --env-file requires a path" >&2; exit 2; }
            ;;
    esac
done

# Load the env file. Its whole point is to keep the database password out of your shell history and
# out of the process table — so refuse to read one the rest of the machine can read too.
if [[ -n "$_ONESHOT_ENV_FILE" ]]; then
    if [[ ! -f "$_ONESHOT_ENV_FILE" ]]; then
        echo "ERROR: --env-file not found: $_ONESHOT_ENV_FILE" >&2; exit 2
    fi
    _os_mode="$(stat -c '%a' "$_ONESHOT_ENV_FILE" 2>/dev/null || echo '')"
    if [[ -n "$_os_mode" && "${_os_mode: -2}" != "00" ]]; then
        echo "ERROR: $_ONESHOT_ENV_FILE is mode ${_os_mode} — it holds a database password." >&2
        echo "       chmod 600 '$_ONESHOT_ENV_FILE'" >&2
        exit 2
    fi
    # set -a: every assignment in the file becomes an exported variable, so PROFILE_DB_PASSWORD and
    # friends reach the migration and the psql/pg_dump calls underneath it.
    set -a
    # shellcheck source=/dev/null
    source "$_ONESHOT_ENV_FILE"
    set +a
    echo "[INFO] Loaded environment from $_ONESHOT_ENV_FILE"
fi

# SAFETY: only a scratch dir THIS SCRIPT creates is ever removed. A caller-supplied work dir
# (--work-dir or ONESHOT_WORK_DIR) is NEVER deleted — it may hold DB backups from a previous
# run, or be a real data directory. (Regression guard: an earlier version rm -rf'd it.)
if [[ -n "${ONESHOT_WORK_DIR:-}" ]]; then
    ONESHOT_WORK_DIR_OWNED="false"
    mkdir -p "$ONESHOT_WORK_DIR"
else
    ONESHOT_WORK_DIR="$(mktemp -d)"
    ONESHOT_WORK_DIR_OWNED="true"
fi
export WORK_DIR="$ONESHOT_WORK_DIR"
trap '[[ "${ONESHOT_WORK_DIR_OWNED:-false}" == "true" ]] && rm -rf "$ONESHOT_WORK_DIR" 2>/dev/null; true' EXIT

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
# Every default reads from the environment first, so an --env-file can drive the whole run without
# a single flag. Flags still win — they are parsed after this.
OS="${KC_OS:-astra}"
TARGET="${KC_TARGET:-$DEFAULT_TARGET_MAJOR}"   # 26 by default (from migrate_keycloak_v3.sh)
CURRENT="${KC_CURRENT:-16.1.1}"
SRC="${KC_SOURCE:-pull}"                       # pull | bundle | preloaded
IMAGE_NS="${KC_IMAGE_NS:-ghcr.io/alexgromer/keycloak-migration}"
# An explicit ref template overrides the <ns>:<os>-<version> convention entirely — this is how a
# company points the tool at images it already has, under whatever names it already uses.
IMAGE_REF_TEMPLATE="${KC_IMAGE_REF_TEMPLATE:-}"
BUNDLE="${KC_BUNDLE:-}"
NETWORK="${KC_NETWORK:-}"
DB_HOST="${KC_DB_HOST:-localhost}"
DB_PORT="${KC_DB_PORT:-5432}"
DB_NAME="${KC_DB_NAME:-keycloak}"
DB_USER="${KC_DB_USER:-keycloak}"
PROFILE_NAME_OPT="${KC_PROFILE_NAME:-}"
USE_PROFILE=""                     # --profile NAME: reuse an existing profile, generate nothing
RUN_WIZARD="false"                 # --wizard: ask, write a profile, then migrate with it
GEN_ONLY="false"
ONESHOT_DRY="true"                 # default dry-run; --go flips to live
SKIP_PREFLIGHT_PASS="false"        # --skip-preflight -> passed through to migrate
NO_RESUME_PASS="false"             # --no-resume      -> passed through to migrate
FORCE_UNLOCK_PASS="false"          # --force-unlock   -> passed through to migrate
KILL_STALE_PASS="false"            # --kill-stale     -> passed through to migrate
APPLY_INDEXES_PASS="false"         # --apply-indexes  -> passed through to migrate

oneshot_usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'; }

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
        --image-ref-template) IMAGE_REF_TEMPLATE="${2:-}"; shift 2 ;;
        --bundle)           BUNDLE="${2:-}"; shift 2 ;;
        --network)          NETWORK="${2:-}"; shift 2 ;;
        --db-host)          DB_HOST="${2:-}"; shift 2 ;;
        --db-port)          DB_PORT="${2:-}"; shift 2 ;;
        --db-name)          DB_NAME="${2:-}"; shift 2 ;;
        --db-user)          DB_USER="${2:-}"; shift 2 ;;
        --profile-name)     PROFILE_NAME_OPT="${2:-}"; shift 2 ;;
        --profile)          USE_PROFILE="${2:-}"; shift 2 ;;
        --wizard)           RUN_WIZARD="true"; shift ;;
        --work-dir)         shift 2 ;;   # already consumed by the pre-scan above
        --env-file)         shift 2 ;;   # already consumed by the pre-scan above
        --skip-preflight)   SKIP_PREFLIGHT_PASS="true"; shift ;;
        --no-resume)        NO_RESUME_PASS="true"; shift ;;
        --force-unlock)     FORCE_UNLOCK_PASS="true"; shift ;;
        --kill-stale)       KILL_STALE_PASS="true"; shift ;;
        --apply-indexes)    APPLY_INDEXES_PASS="true"; shift ;;
        --gen-profile-only) GEN_ONLY="true"; shift ;;
        --dry-run)          ONESHOT_DRY="true"; shift ;;
        --go)               ONESHOT_DRY="false"; shift ;;
        --yes|-y)           shift ;;   # accepted: oneshot is always non-interactive
        -h|--help)          oneshot_usage; exit 0 ;;
        *) log_error "unknown argument: $1"; oneshot_usage; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------
# --wizard: ask the questions instead of taking flags, then migrate with the answers.
#
# config_wizard.sh has always existed — 8 steps with auto-discovery — and was wired to nothing.
# It writes profiles/<name>.yaml; from there this is just the --profile path below.
# ----------------------------------------------------------------------------
if [[ "$RUN_WIZARD" == "true" ]]; then
    WIZARD="$PROJECT_ROOT/scripts/config_wizard.sh"
    [[ -x "$WIZARD" ]] || { log_error "config_wizard.sh not found or not executable: $WIZARD"; exit 1; }

    WIZ_NAME="${PROFILE_NAME_OPT:-oneshot-wizard}"
    log_info "Starting the configuration wizard (profile: $WIZ_NAME)"
    bash "$WIZARD" --profile-name "$WIZ_NAME" || { log_error "Wizard cancelled"; exit 1; }

    USE_PROFILE="$WIZ_NAME"
    log_success "Profile written: ${PROFILE_DIR}/${WIZ_NAME}.yaml"
fi

# ----------------------------------------------------------------------------
# --profile: a profile already describes this migration. Hand straight over to the migration and
# generate nothing.
#
# Image acquisition is the profile's own business (its `acquisition:` field — pull / load /
# preloaded / build — is honoured per hop by distribution_handler). Re-deriving it from flags here
# would give two sources of truth for the same decision.
# ----------------------------------------------------------------------------
if [[ -n "$USE_PROFILE" ]]; then
    PROFILE_PATH="${PROFILE_DIR}/${USE_PROFILE}.yaml"
    [[ -f "$PROFILE_PATH" ]] || { log_error "profile not found: $PROFILE_PATH"; exit 2; }

    log_section "One-shot: existing profile '${USE_PROFILE}'"
    log_info "Profile: $PROFILE_PATH"
    log_info "Images:  governed by the profile's own 'acquisition' setting"

    if [[ "$ONESHOT_DRY" != "true" && -z "${PROFILE_DB_PASSWORD:-}" ]]; then
        log_error "live (--go) requires PROFILE_DB_PASSWORD in the environment"
        log_error "  export PROFILE_DB_PASSWORD=...   or put it in an --env-file (mode 0600)"
        exit 1
    fi

    PROF_ARGS=(migrate --profile "$USE_PROFILE" --yes)
    [[ "$ONESHOT_DRY" == "true" ]]           && PROF_ARGS+=(--dry-run)
    [[ "$SKIP_PREFLIGHT_PASS" == "true" ]]   && PROF_ARGS+=(--skip-preflight)
    [[ "$NO_RESUME_PASS" == "true" ]]        && PROF_ARGS+=(--no-resume)
    [[ "$FORCE_UNLOCK_PASS" == "true" ]]     && PROF_ARGS+=(--force-unlock)
    [[ "$KILL_STALE_PASS" == "true" ]]       && PROF_ARGS+=(--kill-stale)
    [[ "$APPLY_INDEXES_PASS" == "true" ]]    && PROF_ARGS+=(--apply-indexes)

    log_info "Handing off: migrate_keycloak_v3.sh ${PROF_ARGS[*]}"
    exec bash "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" "${PROF_ARGS[@]}"
fi

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

# How each hop's image is named. Env wins over YAML in profile_load, so no re-tagging is needed.
#
# By default: <image-ns>:<os>-<version>, our own convention (astra-26.6.3).
# With --image-ref-template: whatever the operator says. That is the escape hatch for a company
# whose registry already holds Keycloak images under its own naming — the tool should adapt to the
# estate, not demand the estate be renamed for it. {version} is substituted per hop by
# dist_image_ref (distribution_handler.sh).
if [[ -n "$IMAGE_REF_TEMPLATE" ]]; then
    case "$IMAGE_REF_TEMPLATE" in
        *"{version}"*) ;;
        *) log_error "--image-ref-template must contain the literal {version} placeholder"
           log_error "  e.g. --image-ref-template 'registry.corp.local/keycloak:{version}'"
           exit 2 ;;
    esac
    export PROFILE_CONTAINER_IMAGE_REF="$IMAGE_REF_TEMPLATE"
else
    export PROFILE_CONTAINER_IMAGE_REF="${IMAGE_NS}:${OS}-{version}"
fi

# pg-client image (v3.9.7 autonomy, ADR-013): default to the SOVEREIGN per-OS client image so a node
# with no host psql uses the shipped ALSE/RED OS client (astra-pgclient-<major> / redos-pgclient-<major>).
# An explicit PROFILE_PG_CLIENT_IMAGE env wins (e.g. upstream postgres:16). The client major
# (KC_PG_CLIENT_MAJOR, default 17) MUST be >= the DB server major — pg_dump refuses a newer server.
# Remember whether the caller PINNED an image: a --source bundle load discovers the shipped major
# from the bundle and (only if unpinned) repoints PROFILE_PG_CLIENT_IMAGE at exactly what it loaded,
# so a bundle built with a non-default pg_client_major still works without setting KC_PG_CLIENT_MAJOR.
_PG_CLIENT_IMAGE_EXPLICIT="${PROFILE_PG_CLIENT_IMAGE:+set}"
: "${PROFILE_PG_CLIENT_IMAGE:=${IMAGE_NS}:${OS}-pgclient-${KC_PG_CLIENT_MAJOR:-17}}"
export PROFILE_PG_CLIENT_IMAGE

# One place builds a concrete ref for a hop; acquisition and the migration must agree on it.
_os_image_ref() { printf '%s' "${PROFILE_CONTAINER_IMAGE_REF//\{version\}/$1}"; }
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
echo "   work dir    : ${ONESHOT_WORK_DIR} $([[ "$ONESHOT_WORK_DIR_OWNED" == "true" ]] && echo '(temp, auto-removed)' || echo '(yours — never deleted)')"
echo "   free space  : $(df -BG "$ONESHOT_WORK_DIR" 2>/dev/null | tail -1 | awk '{print $4}') (preflight MEASURES what the backups need)"
echo "   profile     : ${PROFILE_NAME} (in ${PROFILE_DIR})"
echo "=============================================================="

# ----------------------------------------------------------------------------
# Acquire per-hop images (so migrate runs with acquisition=preloaded)
# ----------------------------------------------------------------------------
acquire_images() {
    # Refs come from _os_image_ref — the SAME template the migration will resolve. Building them
    # here by hand is how acquisition and migration end up pulling one image and running another.
    local v ref
    case "$SRC" in
        pull)
            for v in "${HOP_ARR[@]}"; do
                ref="$(_os_image_ref "$v")"
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
            # pg-client autonomy (v3.9.7, ADR-013/014): the bundle MAY carry the sovereign client
            # image (kc-<os>-pgclient-<major>.tar). The BUNDLE is the source of truth for which major
            # shipped, so DISCOVER it by glob rather than assume one — then point PROFILE_PG_CLIENT_IMAGE
            # at exactly the image we loaded (unless the caller pinned one). Best-effort: no client tar
            # (older bundle, or the node has host psql) is fine, and a present-but-unloadable tar
            # degrades to the host-psql fallback rather than aborting a migration whose hops loaded.
            if [[ "$ONESHOT_DRY" == "true" ]]; then
                printf 'DRY-RUN: %s\n' "cr load -i ${xdir}/kc-${OS}-pgclient-*.tar  (if the bundle carries it)"
            else
                shopt -s nullglob
                local pgtars=("${xdir}"/kc-"${OS}"-pgclient-*.tar)
                shopt -u nullglob
                if (( ${#pgtars[@]} > 0 )); then
                    local pgtar="${pgtars[0]}"
                    if _os_run "cr load -i ${pgtar}" -- cr load -i "$pgtar"; then
                        if [[ -z "$_PG_CLIENT_IMAGE_EXPLICIT" ]]; then
                            # Derive <major> from kc-<os>-pgclient-<major>.tar and reference exactly it
                            # (build tag == ${IMAGE_NS}:<os>-pgclient-<major>).
                            local _prefix="kc-${OS}-pgclient-" _bn _major
                            _bn="${pgtar##*/}"; _major="${_bn#"$_prefix"}"; _major="${_major%.tar}"
                            PROFILE_PG_CLIENT_IMAGE="${IMAGE_NS}:${OS}-pgclient-${_major}"
                            export PROFILE_PG_CLIENT_IMAGE
                            log_info "pg-client from bundle -> PROFILE_PG_CLIENT_IMAGE=${PROFILE_PG_CLIENT_IMAGE}"
                        fi
                    else
                        log_info "pg-client tar present but failed to load — autonomy falls back to host psql / an explicit PROFILE_PG_CLIENT_IMAGE"
                    fi
                else
                    log_info "bundle carries no kc-${OS}-pgclient-*.tar — pg-client autonomy will use host psql or an explicit PROFILE_PG_CLIENT_IMAGE"
                fi
            fi
            # Clean the extracted tars (keep only loaded images).
            [[ "$ONESHOT_DRY" == "true" ]] || rm -rf "$xdir"
            ;;
        preloaded)
            for v in "${HOP_ARR[@]}"; do
                ref="$(_os_image_ref "$v")"
                if [[ "$ONESHOT_DRY" == "true" ]]; then
                    printf 'DRY-RUN: %s\n' "cr image inspect ${ref}  (assert present)"
                elif ! cr image inspect "$ref" >/dev/null 2>&1; then
                    log_error "preloaded: image not present locally: $ref"
                    log_error "  Load or pull it first, or point --image-ref-template at the name"
                    log_error "  your images actually carry."
                    exit 1
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
    # Leave the run-container name unset so each hop gets its own `kc-migrate-<version>`
    # (deployment_adapter.sh:514) — easier to inspect, and it matches the harness and the docs.
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
elif [[ "$SKIP_PREFLIGHT_PASS" == "true" ]]; then
    MIGRATE_ARGS+=(--skip-preflight)
fi
[[ "$NO_RESUME_PASS" == "true" ]] && MIGRATE_ARGS+=(--no-resume)
[[ "$FORCE_UNLOCK_PASS" == "true" ]] && MIGRATE_ARGS+=(--force-unlock)
[[ "$KILL_STALE_PASS" == "true" ]] && MIGRATE_ARGS+=(--kill-stale)
[[ "$APPLY_INDEXES_PASS" == "true" ]] && MIGRATE_ARGS+=(--apply-indexes)

log_info "Handing off: migrate_keycloak_v3.sh ${MIGRATE_ARGS[*]}"
# Invoke via `bash` so it works regardless of the file's executable bit.
exec bash "$PROJECT_ROOT/scripts/migrate_keycloak_v3.sh" "${MIGRATE_ARGS[@]}"
