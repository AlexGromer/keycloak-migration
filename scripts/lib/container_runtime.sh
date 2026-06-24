#!/usr/bin/env bash
# container_runtime.sh — Single container-engine abstraction for the Keycloak
# migration tool. Migration boots a real Keycloak container of each hop version;
# the engine may be podman OR docker (and compose may be v2, v1 or podman-compose).
# This library hides that difference behind one accessor so the rest of the code
# never hard-codes `docker`.
#
# Exports (frozen contract — other libs depend on these EXACT names/signatures):
#   cr <args...>     Run the resolved engine:  cr pull|run|stop|rm|exec|logs|ps|
#                    inspect|load|save|"image inspect"|build  → "$CONTAINER_RUNTIME" "$@"
#   cr_compose       Echo the compose command words: "docker compose" (v2) |
#                    "docker-compose" (v1) | "podman-compose". Autodetected once.
#                    Callers use it unquoted: `$(cr_compose) up -d`.
#   cr_detect        Resolve & export CONTAINER_RUNTIME. Precedence:
#                    existing $CONTAINER_RUNTIME → $PROFILE_CONTAINER_RUNTIME →
#                    podman → docker. Idempotent.
#   cr_available     Return 0 if a usable runtime exists, else 1.
#
# Reads (optional PROFILE_* parsed elsewhere): PROFILE_CONTAINER_RUNTIME.

# Include guard
[[ -n "${_CONTAINER_RUNTIME_SH:-}" ]] && return 0
_CONTAINER_RUNTIME_SH=1

# ----------------------------------------------------------------------------
# Logging fallbacks — these are normally provided by the orchestrator. Define
# no-op-ish shims so this lib is independently sourceable and testable.
# ----------------------------------------------------------------------------
declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# ----------------------------------------------------------------------------
# cr_detect — resolve the container engine once, idempotently.
# ----------------------------------------------------------------------------
cr_detect() {
    if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
        if [[ -n "${PROFILE_CONTAINER_RUNTIME:-}" ]]; then
            CONTAINER_RUNTIME="$PROFILE_CONTAINER_RUNTIME"
        elif command -v podman >/dev/null 2>&1; then
            CONTAINER_RUNTIME="podman"
        elif command -v docker >/dev/null 2>&1; then
            CONTAINER_RUNTIME="docker"
        fi
    fi

    if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
        export CONTAINER_RUNTIME
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# cr_available — is a usable runtime present?
# ----------------------------------------------------------------------------
cr_available() {
    cr_detect >/dev/null 2>&1 || return 1
    [[ -n "${CONTAINER_RUNTIME:-}" ]] && command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# cr — the single engine accessor. Ensures detection happened, then dispatches.
# Behaviourally equivalent to: "$CONTAINER_RUNTIME" "$@"
# ----------------------------------------------------------------------------
cr() {
    [[ -n "${CONTAINER_RUNTIME:-}" ]] || cr_detect || {
        log_error "No container runtime (podman/docker) found"
        return 127
    }
    "$CONTAINER_RUNTIME" "$@"
}

# ----------------------------------------------------------------------------
# cr_compose — resolve the compose command words once and cache them.
# Keyed off CONTAINER_RUNTIME: podman prefers podman-compose, otherwise prefer
# Docker Compose v2 ("docker compose") then v1 ("docker-compose").
# ----------------------------------------------------------------------------
cr_compose() {
    if [[ -n "${_CR_COMPOSE_CMD:-}" ]]; then
        printf '%s\n' "$_CR_COMPOSE_CMD"
        return 0
    fi

    local rt="${CONTAINER_RUNTIME:-}"
    [[ -n "$rt" ]] || { cr_detect >/dev/null 2>&1 && rt="${CONTAINER_RUNTIME:-}"; }

    local cmd=""
    if [[ "$rt" == "podman" ]]; then
        if command -v podman-compose >/dev/null 2>&1; then
            cmd="podman-compose"
        elif docker compose version >/dev/null 2>&1; then
            cmd="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            cmd="docker-compose"
        fi
    else
        if docker compose version >/dev/null 2>&1; then
            cmd="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            cmd="docker-compose"
        elif command -v podman-compose >/dev/null 2>&1; then
            cmd="podman-compose"
        fi
    fi

    # Always return something usable so callers can compose a command line.
    [[ -n "$cmd" ]] || cmd="docker compose"

    _CR_COMPOSE_CMD="$cmd"
    printf '%s\n' "$_CR_COMPOSE_CMD"
}

# Resolve the engine once at source time (non-fatal if none is present yet).
cr_detect >/dev/null 2>&1 || true

# Make functions available to subshells when sourced.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f cr
    export -f cr_compose
    export -f cr_detect
    export -f cr_available
fi
