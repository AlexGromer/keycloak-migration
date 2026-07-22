#!/usr/bin/env bash
# build_matrix.sh — build / save / publish the Keycloak × sovereign-OS image matrix.
#
# Matrix: { 16.1.1 (WildFly, JDK11), 24.0.5, 25.0.6, 26.6.3 (Quarkus, JDK21) }
#       × { astra, redos } = up to 8 images.
#
# DEFAULT = DRY-RUN: prints the exact build/save/checksum/publish plan and MUTATES
# NOTHING. --build executes; --publish additionally pushes to GHCR. Per-cell USE_IMAGE_*
# overrides (config) switch a cell from build-from-base to consuming a pre-built/branded
# image. Images, bases and registry are configured in config/images.conf (KEY=value).
#
# Usage:
#   build_matrix.sh [--build] [--publish] [--pgclient] [--config FILE]
#                   [--os astra,redos] [--versions 16.1.1,24.0.5,25.0.6,26.6.3]
#                   [--astra-base REF] [--astra-base-kc16 REF]
#                   [--redos-base REF] [--redos-base-kc16 REF]
#                   [--ghcr-image ghcr.io/owner/repo] [--out-dir dist] [-h|--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# cr() + log_* fallbacks (container_runtime defines them; include-guarded, safe).
# shellcheck source=/dev/null
[[ -f "$LIB_DIR/container_runtime.sh" ]] && source "$LIB_DIR/container_runtime.sh"
declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# Defaults (ambient env wins over these; config file + CLI win over env).
# EXECUTE = run for real (default: dry-run plan). PUBLISH = include the GHCR push step.
# --build/--go executes; --publish adds push to the plan; --build --publish actually pushes.
EXECUTE=false
PUBLISH=false
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config/images.conf}"
VERSIONS_CSV="${VERSIONS_CSV:-16.1.1,24.0.5,25.0.6,26.6.3}"
OSES_CSV="${OSES_CSV:-astra,redos}"
OUT_DIR="${OUT_DIR:-dist}"
GHCR_IMAGE="${GHCR_IMAGE:-ghcr.io/${GITHUB_REPOSITORY:-AlexGromer/keycloak-migration}}"
ASTRA_BASE="${ASTRA_BASE:-registry.astralinux.ru/library/astra/ubi18:1.8}"
ASTRA_BASE_KC16="${ASTRA_BASE_KC16:-registry.astralinux.ru/library/astra/ubi17:1.7}"
REDOS_BASE="${REDOS_BASE:-registry.red-soft.ru/ubi8/ubi}"
REDOS_BASE_KC16="${REDOS_BASE_KC16:-registry.red-soft.ru/ubi8/ubi}"
# Build JDK per OS for the Quarkus hops (sovereign bases differ: Astra ubi18/Debian12
# ships openjdk-17 not 21; RED OS ubi8 has 17/21). KC16 (WildFly) needs JDK 11.
ASTRA_JDK="${ASTRA_JDK:-21}"
REDOS_JDK="${REDOS_JDK:-21}"
JDK_KC16="${JDK_KC16:-11}"
# pg-client image (ADR-013): postgresql-client major baked in (must be >= DB server major).
PG_CLIENT_MAJOR="${PG_CLIENT_MAJOR:-17}"
BUILD_PGCLIENT=false

_bm_usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# _bm_run <gate-value> "<emit, secrets masked ***>" -- <live-cmd...>
#   gate != "true" -> print "DRY-RUN: <emit>" and return 0 (live-cmd NEVER runs)
#   gate == "true" -> log the emit, then execute live-cmd
_bm_run() {
    local gate="$1"; shift
    local emit="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    if [[ "$gate" != "true" ]]; then
        printf 'DRY-RUN: %s\n' "$emit"
        return 0
    fi
    log_info "RUN: $emit"
    "$@"
}

# Resolve the sovereign base ref for a cell (KC16 vs Quarkus per OS).
_bm_base_ref() {
    local os="$1" version="$2" ref=""
    case "$os" in
        astra) if [[ "$version" == 16.* ]]; then ref="$ASTRA_BASE_KC16"; else ref="$ASTRA_BASE"; fi ;;
        redos) if [[ "$version" == 16.* ]]; then ref="$REDOS_BASE_KC16"; else ref="$REDOS_BASE"; fi ;;
        *) log_error "unknown OS: $os (expected astra|redos)"; return 1 ;;
    esac
    printf '%s' "$ref"
}

# Build JDK for a cell: KC16->JDK_KC16; else per-OS (ASTRA_JDK / REDOS_JDK).
_bm_jdk() {
    local os="$1" version="$2"
    if [[ "$version" == 16.* ]]; then printf '%s' "$JDK_KC16"; return; fi
    case "$os" in
        astra) printf '%s' "$ASTRA_JDK" ;;
        redos) printf '%s' "$REDOS_JDK" ;;
        *)     printf '%s' "21" ;;
    esac
}

# Per-cell branded/pre-built override: USE_IMAGE_<os>_<ver_underscored>.
_bm_use_image() {
    local os="$1" version="$2" key
    key="USE_IMAGE_${os}_${version//./_}"
    printf '%s' "${!key:-}"
}

# Migration-safety guard (ties to ADR-002 forbidden-version policy).
_bm_guard_version() {
    local v="$1"
    case "$v" in
        26.6.0|26.6.1) log_error "Keycloak $v is FORBIDDEN (migration-breaking #48438/#47908)"; return 1 ;;
        26.6.2)        log_warn  "Keycloak $v: migration-safety unconfirmed — prefer 26.6.3" ;;
    esac
    return 0
}

_bm_sha256() { sha256sum "$1" > "$1.sha256"; }

# Build/consume + checksum + publish one matrix cell.
_bm_cell() {
    local os="$1" version="$2"
    _bm_guard_version "$version" || return 1

    local ghcr_ref="${GHCR_IMAGE}:${os}-${version}"
    local tar="${OUT_DIR}/kc-${os}-${version}.tar"
    local use_ref
    use_ref="$(_bm_use_image "$os" "$version")"

    echo ""
    if [[ -n "$use_ref" ]]; then
        log_info "== CELL ${os}/${version}  mode=USE  branded=${use_ref}  ->  ${ghcr_ref}"
        _bm_run "$EXECUTE" "cr pull ${use_ref}"            -- cr pull "$use_ref"            || return 1
        _bm_run "$EXECUTE" "cr tag ${use_ref} ${ghcr_ref}" -- cr tag "$use_ref" "$ghcr_ref" || return 1
        _bm_run "$EXECUTE" "cr save -o ${tar} ${ghcr_ref}" -- cr save -o "$tar" "$ghcr_ref" || return 1
    else
        local cf="containerfiles/Containerfile.kc" jdk
        jdk="$(_bm_jdk "$os" "$version")"
        if [[ "$version" == 16.* ]]; then cf="containerfiles/Containerfile.kc16"; fi
        local base
        base="$(_bm_base_ref "$os" "$version")" || return 1
        log_info "== CELL ${os}/${version}  mode=BUILD  base=${base}  jdk=${jdk}  cf=${cf}  ->  ${ghcr_ref}"
        _bm_run "$EXECUTE" "build_kc_image.sh --version ${version} --base-image ${base} --jdk ${jdk} --containerfile ${cf} --save ${tar}  (PROFILE_CONTAINER_IMAGE_REF=${ghcr_ref})" -- \
            env PROFILE_CONTAINER_IMAGE_REF="$ghcr_ref" "$SCRIPT_DIR/build_kc_image.sh" \
                --version "$version" --base-image "$base" --jdk "$jdk" \
                --containerfile "$cf" --save "$tar" \
            || { log_error "build failed: ${os}/${version}"; return 1; }
    fi

    _bm_run "$EXECUTE" "sha256sum ${tar} > ${tar}.sha256" -- _bm_sha256 "$tar" || return 1
    if [[ "$PUBLISH" == "true" ]]; then
        _bm_run "$EXECUTE" "cr push ${ghcr_ref}" -- cr push "$ghcr_ref" || return 1
    fi
}

# Build the per-OS PostgreSQL CLIENT image for pg-client autonomy (ADR-013): FROM the OS ubi base +
# postgresql-client-<PG_CLIENT_MAJOR> (PGDG). One image per OS, not per KC version. Saved + checksummed
# like a cell; pushed under --publish.
_bm_pgclient() {
    local os="$1" base ghcr_ref tar
    case "$os" in
        astra) base="$ASTRA_BASE" ;;
        redos) base="$REDOS_BASE" ;;
        *) log_error "unknown OS: $os (expected astra|redos)"; return 1 ;;
    esac
    ghcr_ref="${GHCR_IMAGE}:${os}-pgclient-${PG_CLIENT_MAJOR}"
    tar="${OUT_DIR}/kc-${os}-pgclient-${PG_CLIENT_MAJOR}.tar"
    echo ""
    log_info "== PGCLIENT ${os}  base=${base}  pg=${PG_CLIENT_MAJOR}  ->  ${ghcr_ref}"
    _bm_run "$EXECUTE" "cr build --build-arg PGCLIENT_BASE_IMAGE=${base} --build-arg PG_MAJOR=${PG_CLIENT_MAJOR} -t ${ghcr_ref} -f containerfiles/Containerfile.pgclient ." -- \
        cr build --build-arg PGCLIENT_BASE_IMAGE="$base" --build-arg PG_MAJOR="$PG_CLIENT_MAJOR" \
            -t "$ghcr_ref" -f containerfiles/Containerfile.pgclient . \
        || { log_error "pgclient build failed: ${os}"; return 1; }
    _bm_run "$EXECUTE" "cr save -o ${tar} ${ghcr_ref}" -- cr save -o "$tar" "$ghcr_ref" || return 1
    _bm_run "$EXECUTE" "sha256sum ${tar} > ${tar}.sha256" -- _bm_sha256 "$tar" || return 1
    if [[ "$PUBLISH" == "true" ]]; then
        _bm_run "$EXECUTE" "cr push ${ghcr_ref}" -- cr push "$ghcr_ref" || return 1
    fi
}

build_matrix_main() {
    # Pre-scan for --config so the file loads before flag parsing (flags then win).
    local _a _i; local -a _argv=("$@")
    for ((_i = 0; _i < ${#_argv[@]}; _i++)); do
        if [[ "${_argv[_i]}" == "--config" ]]; then CONFIG_FILE="${_argv[_i+1]:-$CONFIG_FILE}"; fi
    done
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading config: $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build|--go)       EXECUTE=true; shift ;;
            --publish)          PUBLISH=true; shift ;;
            --config)           shift 2 ;;
            --os)               OSES_CSV="${2:-}"; shift 2 ;;
            --versions)         VERSIONS_CSV="${2:-}"; shift 2 ;;
            --astra-base)       ASTRA_BASE="${2:-}"; shift 2 ;;
            --astra-base-kc16)  ASTRA_BASE_KC16="${2:-}"; shift 2 ;;
            --redos-base)       REDOS_BASE="${2:-}"; shift 2 ;;
            --redos-base-kc16)  REDOS_BASE_KC16="${2:-}"; shift 2 ;;
            --pgclient)         BUILD_PGCLIENT=true; shift ;;
            --ghcr-image)       GHCR_IMAGE="${2:-}"; shift 2 ;;
            --out-dir)          OUT_DIR="${2:-}"; shift 2 ;;
            -h|--help)          _bm_usage; return 0 ;;
            *) log_error "unknown argument: $1"; _bm_usage; return 2 ;;
        esac
    done

    # OCI repository names must be lowercase (e.g. owner "AlexGromer" -> "alexgromer").
    GHCR_IMAGE="$(printf '%s' "$GHCR_IMAGE" | tr '[:upper:]' '[:lower:]')"

    local mode="DRY-RUN (plan only)"
    if [[ "$EXECUTE" == "true" && "$PUBLISH" == "true" ]]; then mode="LIVE BUILD + PUBLISH"
    elif [[ "$EXECUTE" == "true" ]]; then mode="LIVE BUILD"
    elif [[ "$PUBLISH" == "true" ]]; then mode="DRY-RUN (incl. publish)"
    fi

    local -a oses verarr
    IFS=',' read -r -a oses   <<< "$OSES_CSV"
    IFS=',' read -r -a verarr <<< "$VERSIONS_CSV"

    echo "=============================================================="
    echo " Keycloak × sovereign-OS image matrix"
    echo "   mode        : $mode"
    echo "   oses        : ${oses[*]}"
    echo "   versions    : ${verarr[*]}"
    echo "   ghcr image  : $GHCR_IMAGE"
    echo "   out dir     : $OUT_DIR"
    echo "   cells       : $(( ${#oses[@]} * ${#verarr[@]} ))"
    echo "=============================================================="

    if [[ "$EXECUTE" == "true" ]]; then
        mkdir -p "$OUT_DIR"
    fi

    local os version
    local -a failed=()
    for os in "${oses[@]}"; do
        for version in "${verarr[@]}"; do
            _bm_cell "$os" "$version" || failed+=("${os}/${version}")
        done
    done

    if [[ "$BUILD_PGCLIENT" == "true" ]]; then
        for os in "${oses[@]}"; do
            _bm_pgclient "$os" || failed+=("${os}/pgclient")
        done
    fi

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "matrix INCOMPLETE — failed cells: ${failed[*]}"
        return 1
    fi
    log_success "matrix complete (mode=$mode)"
}

# Run only when executed directly (allows sourcing for tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    build_matrix_main "$@"
fi
