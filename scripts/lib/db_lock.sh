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

# State of the held lock. The coproc's write fd keeps the connection — and thus the lock — alive.
_KC_DBLOCK_HELD="false"
_KC_DBLOCK_PID=""

# A human label for the database, for messages. NOT the lock key.
_kc_db_label() {
    printf '%s@%s:%s/%s' \
        "${PROFILE_DB_USER:-keycloak}" \
        "${PROFILE_DB_HOST:-localhost}" \
        "${PROFILE_DB_PORT:-5432}" \
        "${PROFILE_DB_NAME:-keycloak}"
}

# kc_db_lock_acquire — take the advisory lock for the whole run, or refuse if another run holds it.
#   0 = we hold it (or the lock is unavailable and we degraded to the file lock)
#   1 = ANOTHER migration owns this database — the caller must abort
kc_db_lock_acquire() {
    [[ "$_KC_DBLOCK_HELD" == "true" ]] && return 0

    if ! command -v psql >/dev/null 2>&1; then
        log_warn "psql not found — cannot take the database-level lock."
        log_warn "  Falling back to the per-workspace file lock ONLY. Two runs against this database"
        log_warn "  from different work dirs (or hosts) would not be detected. Install"
        log_warn "  postgresql-client to close that gap."
        return 0
    fi

    # A persistent connection. The lock lives exactly as long as this psql stays connected, which is
    # why it is a coproc held open for the run — not a one-shot query that would release instantly.
    #
    # `exec` so the coproc process BECOMES psql, with no bash wrapper around it. That wrapper was two
    # separate problems: it kept our own argv (so the competing-process scan flagged it until we
    # switched to pgid exclusion), and killing it left psql orphaned to die later on EOF. As a bare
    # psql, _KC_DBLOCK_PID is the connection itself — kill it and the lock drops at once.
    coproc _KC_DBLOCK_CP { \
        PGPASSWORD="${PROFILE_DB_PASSWORD:-}" exec psql \
            -h "${PROFILE_DB_HOST:-localhost}" \
            -p "${PROFILE_DB_PORT:-5432}" \
            -U "${PROFILE_DB_USER:-keycloak}" \
            -d "${PROFILE_DB_NAME:-keycloak}" \
            -Atq 2>/dev/null; }
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

    local got=""
    read -r -t 15 got <&"$rfd" || true

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
            return 1
            ;;
        *)
            # Empty/garbage: couldn't reach the DB to even ask. Don't hard-block on the lock itself —
            # the very next step (reconcile/backup) needs the DB too and will fail with a clear error.
            log_warn "Could not evaluate the database lock (DB unreachable?) — file lock only."
            _kc_db_lock_release
            return 0
            ;;
    esac
}

# kc_db_lock_release — drop the connection; PostgreSQL auto-releases the advisory lock. Idempotent.
kc_db_lock_release() { _kc_db_lock_release; }
_kc_db_lock_release() {
    [[ -n "$_KC_DBLOCK_PID" ]] || { _KC_DBLOCK_HELD="false"; return 0; }
    local pid="$_KC_DBLOCK_PID"
    _KC_DBLOCK_PID=""
    _KC_DBLOCK_HELD="false"
    # Killing psql closes its connection, and Postgres frees any advisory lock that connection held.
    kill "$pid" 2>/dev/null || true
    # Reap it so it never lingers as a zombie. `wait` succeeds because the coproc is a direct child;
    # the redirect swallows the "terminated" status. Without this, a killed coproc sits defunct
    # until the shell exits.
    wait "$pid" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f kc_db_lock_acquire kc_db_lock_release _kc_db_lock_release _kc_db_label
fi
