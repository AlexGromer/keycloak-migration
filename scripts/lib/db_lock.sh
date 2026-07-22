#!/usr/bin/env bash
# db_lock.sh — one migration per database, enforced BY the database (ADR-011).
#
# The per-workspace file lock ($WORK_DIR/migration.lock) only catches a second run started from the
# SAME work dir. Two runs with different work dirs — or on two different hosts — pointed at the same
# database sail past it and migrate the same schema concurrently, which corrupts it. The only thing
# that actually knows "who is migrating this database" is the database.
#
# A PostgreSQL SESSION-level advisory lock is exactly the right primitive:
#   - keyed to the database (hashtext of its name), scoped to the cluster you connect TO, so two
#     different databases never block each other and the same database always does;
#   - held for the whole migration by ONE persistent connection (a bash coproc);
#   - AUTO-RELEASED when that connection drops — so a crashed or killed migration frees the lock
#     without leaving a stale lock file behind, unlike the file lock.
#
# pg_TRY_advisory_lock (not the blocking pg_advisory_lock): a second run is refused immediately with
# a clear message naming the database, never left waiting.

[[ -n "${_DB_LOCK_SH:-}" ]] && return 0
_DB_LOCK_SH=1

declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# pg_client_available / cr / cr_detect live in container_runtime.sh (include-guarded; safe to re-source).
if ! declare -F pg_client_available >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/container_runtime.sh" 2>/dev/null || true
fi

# State of the held lock. The coproc's write fd keeps the connection — and thus the lock — alive.
_KC_DBLOCK_HELD="false"
_KC_DBLOCK_PID=""
# Non-empty when the lock connection runs inside a container (autonomous / no host psql); it is the
# container name that release force-removes to drop the connection (ADR-012 full parity).
_KC_DBLOCK_CONTAINER=""

# A human label for the database, for messages. NOT the lock key.
_kc_db_label() {
    printf '%s@%s:%s/%s' \
        "${PROFILE_DB_USER:-keycloak}" \
        "${PROFILE_DB_HOST:-localhost}" \
        "${PROFILE_DB_PORT:-5432}" \
        "${PROFILE_DB_NAME:-keycloak}"
}

# A container-name-safe, per-database token so parallel runs against DIFFERENT databases get
# DIFFERENT lock containers (and thus never collide on the name).
_kc_db_lock_token() {
    printf '%s' "${PROFILE_DB_NAME:-keycloak}" | tr -c 'a-zA-Z0-9_.-' '_' | cut -c1-40
}

# kc_db_lock_acquire — take the advisory lock for the whole run, or refuse if another run holds it.
#   0 = we hold it (or the lock is unavailable and we degraded to the file lock)
#   1 = ANOTHER migration owns this database — the caller must abort
kc_db_lock_acquire() {
    [[ "$_KC_DBLOCK_HELD" == "true" ]] && return 0

    # ADR-012 full parity: hold the DB-level advisory lock even WITHOUT a host psql, by running the
    # persistent connection inside the pg-client container. Choose the transport once.
    local _lock_mode=""
    if command -v psql >/dev/null 2>&1; then
        _lock_mode="host"
    elif declare -F pg_client_available >/dev/null 2>&1 && pg_client_available psql; then
        _lock_mode="container"
    else
        log_warn "psql not found (host or container image) — cannot take the database-level lock."
        log_warn "  Falling back to the per-workspace file lock ONLY. Two runs against this database"
        log_warn "  from different work dirs (or hosts) would not be detected. Install"
        log_warn "  postgresql-client, or provide the '${PROFILE_PG_CLIENT_IMAGE:-postgres:16}' image, to close that gap."
        return 0
    fi

    # A persistent connection. The lock lives exactly as long as this psql stays connected, which is
    # why it is a coproc held open for the run — not a one-shot query that would release instantly.
    if [[ "$_lock_mode" == "host" ]]; then
        # `exec` so the coproc process BECOMES psql, with no bash wrapper around it. That wrapper was
        # two separate problems: it kept our own argv (so the competing-process scan flagged it until
        # we switched to pgid exclusion), and killing it left psql orphaned to die later on EOF. As a
        # bare psql, _KC_DBLOCK_PID is the connection itself — kill it and the lock drops at once.
        coproc _KC_DBLOCK_CP { \
            PGPASSWORD="${PROFILE_DB_PASSWORD:-}" exec psql \
                -h "${PROFILE_DB_HOST:-localhost}" \
                -p "${PROFILE_DB_PORT:-5432}" \
                -U "${PROFILE_DB_USER:-keycloak}" \
                -d "${PROFILE_DB_NAME:-keycloak}" \
                -Atq 2>/dev/null; }
    else
        # Containerized connection: psql runs inside PROFILE_PG_CLIENT_IMAGE over the host network,
        # holding the session for the whole run. Release force-removes this named container, dropping
        # the connection so Postgres auto-releases the advisory lock. A per-database name keeps
        # parallel runs against DIFFERENT databases from colliding on it. `exec` the resolved engine
        # so the coproc pid is the engine client itself.
        #
        # KNOWN LIMITATION (v3.9.7, accepted — live-validated on docker): under CONCURRENT acquisition
        # (a 2nd run against the SAME database while the first still holds the lock), `docker run -i`
        # does not reliably forward psql's answer back through the coproc pipe, so the 2nd acquire can
        # stall until the read timeout and then fail CLOSED. It still REFUSES the 2nd run (correctness
        # holds — the database's advisory lock is the arbiter), it is just not prompt. Single-run
        # acquire / hold / crash-release / normal-release are all unaffected and proven. Concurrent
        # migrations against one database should not happen in practice; re-validate on podman/conmon,
        # whose attach model differs, before relying on prompt concurrent-refusal there.
        cr_detect >/dev/null 2>&1 || true
        _KC_DBLOCK_CONTAINER="kc-dblock-$$-$(_kc_db_lock_token)"
        # Clear any leftover container of this EXACT name from a crashed same-PID run (safe: a live
        # run cannot share our PID). If a daemon-orphaned one still held the advisory lock, removing
        # it drops that connection so Postgres releases the lock and this run can proceed.
        cr rm -f "$_KC_DBLOCK_CONTAINER" >/dev/null 2>&1 || true
        coproc _KC_DBLOCK_CP { \
            exec "${CONTAINER_RUNTIME:-docker}" run --rm -i \
                --name "$_KC_DBLOCK_CONTAINER" \
                --network="${PROFILE_PG_CLIENT_NETWORK:-host}" \
                -e PGPASSWORD="${PROFILE_DB_PASSWORD:-}" \
                "${PROFILE_PG_CLIENT_IMAGE:-postgres:16}" \
                psql -h "${PROFILE_DB_HOST:-localhost}" \
                    -p "${PROFILE_DB_PORT:-5432}" \
                    -U "${PROFILE_DB_USER:-keycloak}" \
                    -d "${PROFILE_DB_NAME:-keycloak}" \
                    -Atq 2>/dev/null; }
    fi
    _KC_DBLOCK_PID="${_KC_DBLOCK_CP_PID:-}"

    # The write fd of the coproc, in a plain variable so the redirect is unambiguous.
    local wfd="${_KC_DBLOCK_CP[1]}" rfd="${_KC_DBLOCK_CP[0]}"
    if [[ -z "$wfd" || -z "$rfd" ]]; then
        log_warn "Could not open a connection to take the lock — file lock only."
        _kc_db_lock_release
        return 0
    fi

    # ::text so the answer is the unambiguous 'true' / 'false', never a locale-dependent 't'/'f'.
    local q="SELECT pg_try_advisory_lock(hashtext('kc-migrate:' || current_database()))::text;"
    if ! printf '%s\n' "$q" >&"$wfd"; then
        log_warn "Could not send the lock request (psql did not start) — file lock only."
        _kc_db_lock_release
        return 0
    fi

    # The container transport must start the engine and connect before the first answer, so give it
    # noticeably longer than the host path.
    local got="" _lock_read_to=15
    [[ "$_lock_mode" == "container" ]] && _lock_read_to=40
    read -r -t "$_lock_read_to" got <&"$rfd" || true

    case "$got" in
        true)
            _KC_DBLOCK_HELD="true"
            log_success "Database lock acquired: $(_kc_db_label) (advisory lock held for this run)"
            return 0
            ;;
        false)
            # Someone else holds it. Drop our connection and tell the caller to abort.
            _kc_db_lock_release
            log_error "Database $(_kc_db_label) is ALREADY being migrated by another process."
            log_error "  Two migrations against one database corrupt its schema. Refusing to start."
            log_error "  Wait for the other run to finish, or confirm it is dead and retry."
            if [[ "$_lock_mode" == "container" ]]; then
                log_error "  If a previous run CRASHED, a stale lock container may still hold the lock:"
                log_error "    check:  ${CONTAINER_RUNTIME:-docker} ps --filter name=kc-dblock-"
                log_error "    clear:  ${CONTAINER_RUNTIME:-docker} rm -f <name>   (ONLY if no migration is running)"
            fi
            return 1
            ;;
        *)
            _kc_db_lock_release
            if [[ "$_lock_mode" == "container" ]]; then
                # The DB is reachable via the container client; an empty answer means the lock
                # container was too slow to respond within ${_lock_read_to}s, NOT that the DB is down.
                # We cannot prove the lock is free, so fail CLOSED rather than risk a concurrent run.
                log_error "Could not obtain the database lock via the container client within ${_lock_read_to}s."
                log_error "  Refusing to start rather than risk a concurrent migration against $(_kc_db_label)."
                log_error "  Retry (a warm image starts faster), or pre-pull '${PROFILE_PG_CLIENT_IMAGE:-postgres:16}'."
                return 1
            fi
            # Host path: empty usually means the DB is unreachable — don't hard-block on the lock, the
            # very next step (reconcile/backup) needs the DB too and will fail with a clear error.
            log_warn "Could not evaluate the database lock (DB unreachable?) — file lock only."
            return 0
            ;;
    esac
}

# kc_db_lock_release — drop the connection; PostgreSQL auto-releases the advisory lock. Idempotent.
kc_db_lock_release() { _kc_db_lock_release; }
_kc_db_lock_release() {
    if [[ -z "$_KC_DBLOCK_PID" && -z "$_KC_DBLOCK_CONTAINER" ]]; then
        _KC_DBLOCK_HELD="false"; return 0
    fi
    local pid="$_KC_DBLOCK_PID" container="$_KC_DBLOCK_CONTAINER"
    _KC_DBLOCK_PID=""
    _KC_DBLOCK_CONTAINER=""
    _KC_DBLOCK_HELD="false"
    # Killing the client closes its connection, and Postgres frees any advisory lock it held.
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        # Reap it so it never lingers as a zombie. `wait` succeeds because the coproc is a direct
        # child; the redirect swallows the "terminated" status.
        wait "$pid" 2>/dev/null || true
    fi
    # Containerized transport: killing the engine client can leave the --rm container (and its live
    # DB connection) running detached; force-remove it so the connection drops and the advisory lock
    # is released at once.
    if [[ -n "$container" ]] && declare -F cr >/dev/null 2>&1; then
        cr rm -f "$container" >/dev/null 2>&1 || true
    fi
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f kc_db_lock_acquire kc_db_lock_release _kc_db_lock_release _kc_db_label _kc_db_lock_token
fi
