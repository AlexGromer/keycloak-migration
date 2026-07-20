#!/usr/bin/env bash
# Migration Verification for Keycloak Migration v3.0
# Layer 2 confirmation + skipped-index handling.
#
# Model:
#   A Keycloak hop runs TWO migration layers inside the booting container:
#     Layer 1 — Liquibase schema changesets   (tracked in DATABASECHANGELOG)
#     Layer 2 — RealmMigration / model update (tracked in MIGRATION_MODEL)
#   "Container exited" != "migration done". A hop is only CONFIRMED when the
#   MIGRATION_MODEL table reports the expected model version. We compare on
#   MAJOR.MINOR because the stored value may carry a different patch level
#   (e.g. stored "26.6.10" vs hop "26.6.3").
#
#   Large tables (>300k rows) cause Keycloak to SKIP CREATE INDEX during
#   startup and log the DDL instead. We capture that DDL so it can be applied
#   out-of-band (optionally CONCURRENTLY) without blocking the migration.

# ----------------------------------------------------------------------------
# Include guard
# ----------------------------------------------------------------------------
[[ -n "${_MIGRATION_VERIFY_SH:-}" ]] && return 0
_MIGRATION_VERIFY_SH=1

# ----------------------------------------------------------------------------
# Logging fallbacks (when sourced standalone / under test without main script)
# ----------------------------------------------------------------------------
declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

# Extract MAJOR.MINOR from a version string. "26.6.3" -> "26.6", "26" -> "26".
_mv_major_minor() {
    local v="$1" mm
    mm="$(printf '%s' "$v" | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)"
    printf '%s' "$mm"
}

# Run a query against the Keycloak DB and print -tA (tuples-only, unaligned)
# output. Mirrors the psql invocation from migrate_keycloak_v3.sh
# kc_detect_version() Method 3 (DATABASECHANGELOG lookup).
_mv_psql() {
    local sql="$1"
    PGPASSWORD="${PROFILE_DB_PASSWORD:-}" psql \
        -h "${PROFILE_DB_HOST:-localhost}" \
        -p "${PROFILE_DB_PORT:-5432}" \
        -U "${PROFILE_DB_USER:-keycloak}" \
        -d "${PROFILE_DB_NAME:-keycloak}" \
        -tAc "$sql" 2>/dev/null
}

# ============================================================================
# ADR-008 — STATE RECONCILIATION PRIMITIVES
# Read the ACTUAL state of the database. Checkpoints and the profile's `current_version` are
# CLAIMS about the past; these functions report FACTS.
# ============================================================================

# kc_db_model_version
#   Echo the version Keycloak last wrote to MIGRATION_MODEL — the ground truth for "where is this
#   database, really". Returns 1 (echoing nothing) when the table/rows are absent (the DB was never
#   initialised by Keycloak) or the database is unreachable.
kc_db_model_version() {
    command -v psql >/dev/null 2>&1 || return 1
    local raw
    raw="$(_mv_psql "SELECT version FROM MIGRATION_MODEL ORDER BY update_time DESC LIMIT 1;" || true)"
    [[ -n "$raw" ]] || raw="$(_mv_psql "SELECT version FROM MIGRATION_MODEL LIMIT 1;" || true)"
    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

# kc_db_changelog_locked
#   Liquibase sets LOCKED=true while migrating and clears it when done. A migration that crashed
#   mid-flight leaves the lock HELD — and every later Keycloak then blocks on it. Keycloak uses
#   SEVERAL lock ids (1, 1000, 1001, …), so all rows are checked.
#   Echoes "id|lockedby|lockgranted" per held lock; returns 1 when nothing is locked.
kc_db_changelog_locked() {
    command -v psql >/dev/null 2>&1 || return 1
    local rows
    rows="$(_mv_psql "SELECT id || '|' || COALESCE(lockedby,'?') || '|' || COALESCE(lockgranted::text,'?') FROM databasechangeloglock WHERE locked;" || true)"
    rows="$(printf '%s\n' "$rows" | sed '/^[[:space:]]*$/d')"
    [[ -n "$rows" ]] || return 1
    printf '%s\n' "$rows"
}

# kc_db_clear_changelog_lock — release a stale Liquibase lock (explicit opt-in only).
kc_db_clear_changelog_lock() {
    _mv_psql "UPDATE databasechangeloglock SET locked=false, lockedby=null, lockgranted=null WHERE locked;" >/dev/null 2>&1
}

# Rewrite a "CREATE INDEX ..." statement into the idempotent, non-blocking
# "CREATE INDEX CONCURRENTLY IF NOT EXISTS ..." variant (case-insensitive).
# IF NOT EXISTS makes a re-apply (or an index Keycloak already created) a no-op
# instead of a "relation already exists" error. Non-matching statements pass
# through unchanged.
_mv_to_concurrent() {
    local stmt="$1" upper rest
    upper="$(printf '%s' "$stmt" | tr '[:lower:]' '[:upper:]')"
    case "$upper" in
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS "*)
            printf '%s' "$stmt"
            ;;
        "CREATE INDEX CONCURRENTLY "*)
            rest="${stmt#[Cc][Rr][Ee][Aa][Tt][Ee] [Ii][Nn][Dd][Ee][Xx] [Cc][Oo][Nn][Cc][Uu][Rr][Rr][Ee][Nn][Tt][Ll][Yy] }"
            printf 'CREATE INDEX CONCURRENTLY IF NOT EXISTS %s' "$rest"
            ;;
        "CREATE INDEX IF NOT EXISTS "*)
            rest="${stmt#[Cc][Rr][Ee][Aa][Tt][Ee] [Ii][Nn][Dd][Ee][Xx] [Ii][Ff] [Nn][Oo][Tt] [Ee][Xx][Ii][Ss][Tt][Ss] }"
            printf 'CREATE INDEX CONCURRENTLY IF NOT EXISTS %s' "$rest"
            ;;
        "CREATE INDEX "*)
            rest="${stmt#[Cc][Rr][Ee][Aa][Tt][Ee] [Ii][Nn][Dd][Ee][Xx] }"
            printf 'CREATE INDEX CONCURRENTLY IF NOT EXISTS %s' "$rest"
            ;;
        *)
            printf '%s' "$stmt"
            ;;
    esac
}

# Apply captured CREATE INDEX statements CONCURRENTLY (autocommit, so the
# CONCURRENTLY form is allowed). Returns non-zero if any statement fails.
_mv_apply_skipped_indexes() {
    local -a statements=("$@")
    local stmt concurrent rc=0

    if ! command -v psql >/dev/null 2>&1; then
        log_error "psql not available; cannot apply skipped indexes"
        return 1
    fi

    for stmt in "${statements[@]}"; do
        concurrent="$(_mv_to_concurrent "$stmt")"
        log_info "Applying index: $concurrent"
        if ! PGPASSWORD="${PROFILE_DB_PASSWORD:-}" psql \
                -h "${PROFILE_DB_HOST:-localhost}" \
                -p "${PROFILE_DB_PORT:-5432}" \
                -U "${PROFILE_DB_USER:-keycloak}" \
                -d "${PROFILE_DB_NAME:-keycloak}" \
                -v ON_ERROR_STOP=1 -c "$concurrent"; then
            log_error "Failed to apply index: $concurrent"
            rc=1
        fi
    done
    return "$rc"
}

# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------

# kc_verify_migration_model <expected_version>
#   Confirm Layer 2 success: query MIGRATION_MODEL for the latest model version
#   and compare it (MAJOR.MINOR) against the expected hop version.
#   Returns 0 on match, non-zero (1) otherwise; logs the raw stored value.
kc_verify_migration_model() {
    local expected_version="${1:-}"

    if [[ -z "$expected_version" ]]; then
        log_error "kc_verify_migration_model: expected version not provided"
        return 1
    fi

    if ! command -v psql >/dev/null 2>&1; then
        log_error "kc_verify_migration_model: psql not available; cannot reach DB"
        return 1
    fi

    local raw
    # Keycloak's MIGRATION_MODEL has columns (id, version, update_time).
    raw="$(_mv_psql "SELECT version FROM MIGRATION_MODEL ORDER BY update_time DESC LIMIT 1;")"
    # Fallback for schemas where update_time ordering is unavailable.
    if [[ -z "$raw" ]]; then
        raw="$(_mv_psql "SELECT version FROM MIGRATION_MODEL LIMIT 1;")"
    fi

    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"

    if [[ -z "$raw" ]]; then
        log_error "MIGRATION_MODEL returned no rows (DB empty or unreachable); Layer 2 NOT confirmed"
        return 1
    fi

    local expected_mm stored_mm
    expected_mm="$(_mv_major_minor "$expected_version")"
    stored_mm="$(_mv_major_minor "$raw")"

    if [[ -n "$expected_mm" && "$stored_mm" == "$expected_mm" ]]; then
        log_success "MIGRATION_MODEL confirms version '$raw' (matches expected '$expected_version' on $expected_mm)"
        return 0
    fi

    log_error "MIGRATION_MODEL version mismatch: stored='$raw' (major.minor='$stored_mm') expected='$expected_version' (major.minor='$expected_mm')"
    return 1
}

# kc_check_skipped_indexes <kc_logfile> [version]
#   Scan a Keycloak startup log for skipped-index warnings on large tables and
#   write the suggested CREATE INDEX statements to
#   ${WORK_DIR:-.}/skipped_indexes_<version>.sql.
#   Version is taken from the 2nd argument; if omitted it falls back to the
#   global ${PROFILE_KC_TARGET_VERSION} (then ${KC_TARGET_VERSION}, then
#   "unknown"). When PROFILE_APPLY_SKIPPED_INDEXES == true the statements are
#   applied via CREATE INDEX CONCURRENTLY.
kc_check_skipped_indexes() {
    local logfile="${1:-}"
    local version="${2:-${PROFILE_KC_TARGET_VERSION:-${KC_TARGET_VERSION:-unknown}}}"

    if [[ -z "$logfile" ]]; then
        log_error "kc_check_skipped_indexes: no log file provided"
        return 1
    fi
    if [[ ! -f "$logfile" ]]; then
        log_error "kc_check_skipped_indexes: log file not found: $logfile"
        return 1
    fi

    local out_dir="${WORK_DIR:-.}"
    local out_file="${out_dir}/skipped_indexes_${version}.sql"

    # Keycloak emits the deferred DDL on the same log line as the warning, e.g.
    #   "... index IDX_x was not created ... CREATE INDEX IDX_x ON tbl (...);"
    #   "... Adding the index IDX_x to ... concurrently ..."
    # Keycloak logs each skipped index from TWO subsystems — CustomCreateIndexChange
    # (during the migration) and DatabaseIndexChecker (at startup) — so the same
    # CREATE INDEX statement is emitted twice. Dedup on a normalised key (uppercased,
    # whitespace-collapsed, trailing ';' stripped) so we capture each index once and
    # --apply-indexes does not attempt to create it twice.
    local -a statements=()
    local -A _mv_seen=()
    local line sql key
    while IFS= read -r line; do
        sql="$(printf '%s\n' "$line" | grep -oiE 'CREATE INDEX[^;]*;?' | head -1)"
        [[ -n "$sql" ]] || continue
        key="$(printf '%s' "$sql" | tr '[:lower:]' '[:upper:]' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*;*[[:space:]]*$//')"
        [[ -n "${_mv_seen[$key]:-}" ]] && continue
        _mv_seen[$key]=1
        statements+=("$sql")
    done < <(grep -iE 'index .* was not created|Adding the index .* concurrently|CREATE INDEX' \
                 "$logfile" 2>/dev/null || true)

    if [[ ${#statements[@]} -eq 0 ]]; then
        log_info "No skipped indexes found in $logfile"
        return 0
    fi

    mkdir -p "$out_dir"
    {
        echo "-- Skipped indexes detected for Keycloak ${version}"
        echo "-- Source log: ${logfile}"
        echo "-- Generated:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for sql in "${statements[@]}"; do
            if [[ "$sql" == *";" ]]; then
                echo "$sql"
            else
                echo "${sql};"
            fi
        done
    } >"$out_file"

    log_warn "Captured ${#statements[@]} skipped-index statement(s) -> $out_file"

    if [[ "${PROFILE_APPLY_SKIPPED_INDEXES:-false}" == "true" ]]; then
        log_info "PROFILE_APPLY_SKIPPED_INDEXES=true: applying indexes CONCURRENTLY"
        _mv_apply_skipped_indexes "${statements[@]}"
        return $?
    fi

    log_info "Set PROFILE_APPLY_SKIPPED_INDEXES=true to apply ${out_file} automatically"
    return 0
}

# ----------------------------------------------------------------------------
# Export public functions when sourced
# ----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f kc_verify_migration_model
    export -f kc_check_skipped_indexes
    # ADR-008 state-reconciliation primitives
    export -f kc_db_model_version
    export -f kc_db_changelog_locked
    export -f kc_db_clear_changelog_lock
fi
