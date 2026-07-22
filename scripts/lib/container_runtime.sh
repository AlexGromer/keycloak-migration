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

# cr_is_rootless — 0 only when the engine is POSITIVELY rootless (docker SecurityOptions carries
# name=rootless; podman Host.Security.Rootless==true). Anything undetectable is treated as NOT
# rootless (fail-safe: keeps the rootful/host-network path byte-identical). Cached after first probe.
_KC_ROOTLESS=""
cr_is_rootless() {
    case "$_KC_ROOTLESS" in yes) return 0 ;; no) return 1 ;; esac
    local rl=no
    case "${CONTAINER_RUNTIME:-}" in
        docker) cr info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=rootless' && rl=yes ;;
        podman) [[ "$(cr info -f '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" ]] && rl=yes ;;
    esac
    _KC_ROOTLESS="$rl"
    [[ "$rl" == yes ]]
}

# _cr_is_loopback — 0 if the host is a loopback name/address (the case that needs a rootless-docker
# rewrite, because a rootless dockerd's --network=host loopback is NOT the machine's loopback).
_cr_is_loopback() { case "${1:-}" in localhost|127.*|::1) return 0 ;; *) return 1 ;; esac; }

# Is a pg_dump using the DIRECTORY format (-Fd / --format=directory / -F d)? Directory dumps write
# many files and cannot be streamed — they keep the bind-mount path.
_pg_dump_is_dir() {
    local a prev=""
    for a in "$@"; do
        case "$a" in
            -Fd|-Fdirectory|--format=d|--format=directory) return 0 ;;
            -F) prev="-F"; continue ;;
            d|directory) [[ "$prev" == "-F" ]] && return 0 ;;
        esac
        prev=""
    done
    return 1
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

    local -a args=("$@") pgopts=()
    local pgpass="${PGPASSWORD:-${PROFILE_DB_PASSWORD:-}}"
    local image="${PROFILE_PG_CLIENT_IMAGE:-postgres:16}"
    # Forward PGOPTIONS so a non-public schema (search_path) reaches the container psql as it does a host one.
    [[ -n "${PGOPTIONS:-}" ]] && pgopts=(-e PGOPTIONS="$PGOPTIONS")

    # Network. Default host networking so the container reaches a host-local DB. Under ROOTLESS DOCKER
    # --network=host is the rootless daemon's own namespace (NOT the machine's), so rewrite a loopback
    # `-h` to host.docker.internal on the bridge. Rootless podman / rootful are untouched.
    local -a netargs=(--network="${PROFILE_PG_CLIENT_NETWORK:-host}")
    if [[ "${PROFILE_PG_CLIENT_NETWORK:-host}" == "host" && "${CONTAINER_RUNTIME:-}" == "docker" ]] && cr_is_rootless; then
        local _i
        for ((_i = 0; _i < ${#args[@]}; _i++)); do
            if [[ "${args[_i]}" == "-h" ]] && _cr_is_loopback "${args[_i+1]:-}"; then
                args[_i+1]="host.docker.internal"
                netargs=(--network=bridge --add-host "host.docker.internal:host-gateway")
                log_info "rootless docker: DB loopback rewritten to host.docker.internal (host-gateway)"
            fi
        done
    fi

    # STREAM instead of bind-mounting for single-file archives. The container touches only its std
    # streams; the FILE is opened by THIS shell (the caller), so it is caller-owned and needs no
    # --user / --userns tricks. This is what lets a non-root (uid 1000) container do dumps/restores
    # under ROOTLESS DOCKER, where a bind-mounted write would land as an unwritable subuid. Directory
    # dumps (-Fd) and directory restores fall through to the mount path below.
    if [[ "$tool" == "pg_dump" ]] && ! _pg_dump_is_dir "${args[@]}"; then
        local of="" _i; local -a a2=()
        for ((_i = 0; _i < ${#args[@]}; _i++)); do
            case "${args[_i]}" in
                -f|--file) of="${args[_i+1]:-}"; _i=$((_i + 1)) ;;
                --file=*)  of="${args[_i]#--file=}" ;;
                *)         a2+=("${args[_i]}") ;;
            esac
        done
        if [[ -n "$of" ]]; then
            cr run --rm "${netargs[@]}" -e HOME=/tmp -e PGPASSWORD="$pgpass" "${pgopts[@]}" \
                "$image" pg_dump "${a2[@]}" > "$of"
            return $?
        fi
    fi
    if [[ "$tool" == "pg_restore" ]]; then
        local last="${args[$((${#args[@]} - 1))]:-}"
        if [[ -n "$last" && "$last" != -* && -f "$last" ]]; then   # a single-file archive, not a dir
            cr run --rm -i "${netargs[@]}" -e HOME=/tmp -e PGPASSWORD="$pgpass" "${pgopts[@]}" \
                "$image" pg_restore "${args[@]:0:$((${#args[@]} - 1))}" < "$last"
            return $?
        fi
    fi
    if [[ "$tool" == "psql" ]]; then   # psql -f SCRIPT: read the input file via stdin, no mount
        local sf="" _i; local -a a2=()
        for ((_i = 0; _i < ${#args[@]}; _i++)); do
            case "${args[_i]}" in
                -f|--file) sf="${args[_i+1]:-}"; _i=$((_i + 1)) ;;
                --file=*)  sf="${args[_i]#--file=}" ;;
                *)         a2+=("${args[_i]}") ;;
            esac
        done
        if [[ -n "$sf" && -f "$sf" ]]; then
            cr run --rm -i "${netargs[@]}" -e HOME=/tmp -e PGPASSWORD="$pgpass" "${pgopts[@]}" \
                "$image" psql "${a2[@]}" < "$sf"
            return $?
        fi
    fi

    # MOUNT path — directory dumps/restores, or anything else that must touch PG_CLIENT_MOUNT files.
    local -a mounts=() userns=()
    [[ -n "${PG_CLIENT_MOUNT:-}" ]] && mounts=(-v "$PG_CLIENT_MOUNT:$PG_CLIENT_MOUNT:z")
    #  - rootful: --user <caller> (files caller-owned).
    #  - rootless podman + mount: --userns=keep-id (non-root container writes caller-owned).
    #  - rootless docker + a directory dump: uid 1000 maps to an unwritable subuid — make the work-dir
    #    writable by that subuid, or use podman (docs/ROOTLESS.md). Single-file ops streamed above.
    if _pg_client_rootful; then
        userns=(--user "$(id -u):$(id -g)")
    elif [[ -n "${PG_CLIENT_MOUNT:-}" && "${CONTAINER_RUNTIME:-}" == "podman" ]] && cr_is_rootless; then
        userns=(--userns=keep-id)
    fi
    cr run --rm -i "${netargs[@]}" \
        "${userns[@]}" -e HOME=/tmp \
        -e PGPASSWORD="$pgpass" \
        "${pgopts[@]}" \
        "${mounts[@]}" \
        "$image" "$tool" "${args[@]}"
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
    export -f cr_is_rootless
    export -f _cr_is_loopback
    export -f _pg_dump_is_dir
fi
