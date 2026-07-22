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

# ----------------------------------------------------------------------------
# PostgreSQL client autonomy (v3.9.7).
# The migration reads/writes the database with psql/pg_dump/pg_restore. These used
# to have to be installed ON THE HOST. pg_client removes that requirement: when the
# tool is present on the host it runs there (unchanged fast path); otherwise it runs
# inside PROFILE_PG_CLIENT_IMAGE (default postgres:16) over the host network, so a
# node with only a container engine still migrates.
#
#   pg_client <tool> [args...]
#     stdin, stdout, stderr and the exit code pass through on BOTH paths.
#     PGPASSWORD is taken from the caller's environment (the usual inline
#     'PGPASSWORD="$pass" pg_client psql ...' prefix) or PROFILE_DB_PASSWORD, and
#     forwarded into the container.
#     For a call that reads or writes a HOST FILE (pg_dump -f, pg_restore FILE,
#     pg_restore --list FILE), the caller sets PG_CLIENT_MOUNT to the host DIRECTORY
#     to bind-mount at the same path inside the container; the file argument is then
#     unchanged and -Fd/-j parallel keep working on the mounted file. On the host
#     fast path PG_CLIENT_MOUNT is ignored.
#
#   pg_client_available [tool]   (default psql)
#     0 if <tool> is runnable either on the host OR via the container image. Used to
#     relax host-binary dependency gates without breaking autonomy.
#
# Reads (optional): PROFILE_PG_CLIENT_IMAGE, PROFILE_PG_CLIENT_NETWORK,
#                   PG_CLIENT_MOUNT, PGPASSWORD, PROFILE_DB_PASSWORD.
# ----------------------------------------------------------------------------
# Exported so a child shell (e.g. the `timeout bash -c '...pg_client...'` connectivity probe in
# preflight_checks.sh) inherits it; a non-exported shell var would be empty in that child and the
# container path would build `cr run ... "" psql` with an empty image.
export PROFILE_PG_CLIENT_IMAGE="${PROFILE_PG_CLIENT_IMAGE:-postgres:16}"

# _pg_client_rootful — 0 only when the engine is POSITIVELY rootful (bind-mount writes land as
# root, so --user maps them back to the caller). Rootless docker/podman map container-root to the
# caller already, and adding --user there maps to an unusable subuid; anything undetectable stays
# without --user (fail-safe: at worst a root-owned but readable dump). Cached after the first probe.
_pg_client_rootful() {
    case "${_PG_CLIENT_ROOTFUL:-}" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac
    local rootful=1 so
    case "${CONTAINER_RUNTIME:-}" in
        docker)
            if so="$(cr info -f '{{.SecurityOptions}}' 2>/dev/null)"; then
                printf '%s' "$so" | grep -q 'name=rootless' || rootful=0
            fi
            ;;
        podman)
            [[ "$(cr info -f '{{.Host.Security.Rootless}}' 2>/dev/null)" == "false" ]] && rootful=0
            ;;
    esac
    if [[ $rootful -eq 0 ]]; then _PG_CLIENT_ROOTFUL=yes; return 0; fi
    _PG_CLIENT_ROOTFUL=no; return 1
}

pg_client() {
    local tool="${1:?pg_client: a tool name (psql|pg_dump|pg_restore) is required}"
    shift
    # Host fast path — unchanged behaviour, keeps -Fd/-j parallelism.
    if command -v "$tool" >/dev/null 2>&1; then
        "$tool" "$@"
        return $?
    fi
    # Autonomous container path.
    if ! cr_available; then
        log_error "pg_client: '$tool' is not on the host and no container runtime (podman/docker) is available."
        log_error "  Install postgresql-client, or provide a container engine plus the '$PROFILE_PG_CLIENT_IMAGE' image."
        return 127
    fi
    local -a mounts=() userns=() pgopts=()
    # One host directory, quoted so paths with spaces are safe. The :z suffix relabels for SELinux
    # hosts (RHEL / RED OS) and is ignored where SELinux is absent.
    [[ -n "${PG_CLIENT_MOUNT:-}" ]] && mounts=(-v "$PG_CLIENT_MOUNT:$PG_CLIENT_MOUNT:z")
    # Map --user only on a positively rootful engine, so written dump files stay caller-owned.
    _pg_client_rootful && userns=(--user "$(id -u):$(id -g)")
    # Forward PGOPTIONS so a non-public schema (search_path, set once by the entrypoint) reaches the
    # containerised psql exactly as it reaches a host psql via the environment.
    [[ -n "${PGOPTIONS:-}" ]] && pgopts=(-e PGOPTIONS="$PGOPTIONS")
    cr run --rm -i --network="${PROFILE_PG_CLIENT_NETWORK:-host}" \
        "${userns[@]}" -e HOME=/tmp \
        -e PGPASSWORD="${PGPASSWORD:-${PROFILE_DB_PASSWORD:-}}" \
        "${pgopts[@]}" \
        "${mounts[@]}" \
        "${PROFILE_PG_CLIENT_IMAGE:-postgres:16}" "$tool" "$@"
}

pg_client_available() {
    local tool="${1:-psql}"
    command -v "$tool" >/dev/null 2>&1 && return 0
    cr_available || return 1
    cr image inspect "${PROFILE_PG_CLIENT_IMAGE:-postgres:16}" >/dev/null 2>&1
}

# Resolve the engine once at source time (non-fatal if none is present yet).
cr_detect >/dev/null 2>&1 || true

# Make functions available to subshells when sourced.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f cr
    export -f cr_compose
    export -f cr_detect
    export -f cr_available
    export -f pg_client
    export -f pg_client_available
    export -f _pg_client_rootful
fi
