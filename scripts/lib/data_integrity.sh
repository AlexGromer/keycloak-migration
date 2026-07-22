#!/usr/bin/env bash
# data_integrity.sh — does the DATA survive the hop?
#
# L1 (DATABASECHANGELOG) proves the schema changesets ran. L2 (MIGRATION_MODEL) proves the realm
# migration ran. Neither says a single word about whether your realms, users and clients are still
# there afterwards. A migration can report complete success on an emptied database.
#
# So: count the rows that matter BEFORE the first hop, re-count after each one, and compare.
#
#   realm         ==  baseline    a migration never removes a realm
#   user_entity   ==  baseline    nor a user
#   client        >=  baseline    but it DOES add default clients (account-console, admin-cli, ...)
#   keycloak_role >=  baseline    and default roles, for the same reason
#
# Cheap enough to run on every hop: four COUNT(*) queries, no admin credentials, works with
# Keycloak shut down. Promoted from scripts/harness/lib/harness_integrity.sh, where this logic
# already guarded the synthetic runs but never the real ones.
#
# Reuses _mv_psql (migration_verify.sh) as the host-side psql primitive.

# ----------------------------------------------------------------------------
# Include guard
# ----------------------------------------------------------------------------
[[ -n "${_DATA_INTEGRITY_SH:-}" ]] && return 0
_DATA_INTEGRITY_SH=1

declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# pg_client / pg_client_available live in container_runtime.sh (include-guarded; safe to re-source).
if ! declare -F pg_client >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/container_runtime.sh" 2>/dev/null || true
fi

# The tables we assert on, and the policy for each.
#   eq  — the count must not change at all
#   gte — the count may grow (the migration adds defaults) but must never shrink
_DI_TABLES=(realm user_entity client keycloak_role)
_DI_POLICY=(eq   eq          gte    gte)

_di_baseline_file() { printf '%s' "${WORK_DIR:-.}/data_baseline.env"; }

# _di_count <table> — echo COUNT(*), or nothing when the table/DB is unreachable.
_di_count() {
    local table="$1" n
    n="$(_mv_psql "SELECT COUNT(*) FROM ${table};" || true)"
    n="$(printf '%s' "$n" | tr -cd '0-9')"
    printf '%s' "$n"
}

# ----------------------------------------------------------------------------
# _kc_integrity_eval <table> <policy> <baseline> <current>
#   Pure policy decision — no database. Returns 0 when the invariant holds.
#   Unit-tested directly; keep it free of I/O.
# ----------------------------------------------------------------------------
_kc_integrity_eval() {
    local table="$1" policy="$2" base="$3" cur="$4"

    case "$policy" in
        eq)
            if [[ "$cur" -ne "$base" ]]; then
                log_error "integrity: ${table} count changed ${base} -> ${cur} (must be unchanged)"
                return 1
            fi
            log_success "integrity: ${table} ${cur} == baseline ${base}"
            ;;
        gte)
            if [[ "$cur" -lt "$base" ]]; then
                log_error "integrity: ${table} count DROPPED ${base} -> ${cur} (must never shrink)"
                return 1
            fi
            log_success "integrity: ${table} ${cur} >= baseline ${base}"
            ;;
        *)
            log_error "integrity: unknown policy '${policy}' for ${table}"
            return 1
            ;;
    esac
    return 0
}

# ----------------------------------------------------------------------------
# kc_data_baseline
#   Snapshot the counts BEFORE any hop runs. Written to $WORK_DIR/data_baseline.env so it survives
#   a resume — the whole point is to compare against the state we started from, not against the
#   state after the hop that lost the data.
#
#   A database Keycloak has never initialised has no `realm` table. That is not a failure; it means
#   there is nothing to protect yet. Records DI_ENABLED=false and every later check no-ops.
# ----------------------------------------------------------------------------
kc_data_baseline() {
    local file
    file="$(_di_baseline_file)"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "DRY-RUN: would capture data baseline (COUNT(*) on ${_DI_TABLES[*]})"
        return 0
    fi

    # Don't overwrite a baseline from an earlier run of this same migration: after hop 1 the counts
    # already include the clients hop 1 added, and re-baselining there would forgive a hop-2 loss.
    if [[ -f "$file" ]]; then
        log_info "Data baseline already captured: $file"
        return 0
    fi

    if ! pg_client_available psql; then
        log_warn "psql not available — data-integrity checks DISABLED for this run"
        printf 'DI_ENABLED=false\n' > "$file"
        return 0
    fi

    local probe
    probe="$(_di_count realm)"
    if [[ -z "$probe" ]]; then
        log_warn "No 'realm' table (database not initialised by Keycloak) — integrity checks DISABLED"
        printf 'DI_ENABLED=false\n' > "$file"
        return 0
    fi

    local t n i=0
    {
        printf 'DI_ENABLED=true\n'
        for t in "${_DI_TABLES[@]}"; do
            n="$(_di_count "$t")"
            printf 'DI_BASE_%s=%s\n' "$t" "${n:-0}"
        done
    } > "$file"

    local summary=""
    for t in "${_DI_TABLES[@]}"; do
        n="$(grep "^DI_BASE_${t}=" "$file" | cut -d= -f2)"
        summary+="${t}=${n} "
        i=$((i + 1))
    done
    log_success "Data baseline captured: ${summary% }"
}

# ----------------------------------------------------------------------------
# kc_data_verify <version>
#   Re-count after a hop and apply the policy. Non-zero when an invariant is broken.
# ----------------------------------------------------------------------------
kc_data_verify() {
    local version="${1:-}"
    local file
    file="$(_di_baseline_file)"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "DRY-RUN: would verify data integrity after $version"
        return 0
    fi

    if [[ ! -f "$file" ]]; then
        log_warn "No data baseline (${file}) — cannot verify integrity of hop $version"
        return 0
    fi

    # shellcheck source=/dev/null
    source "$file"

    if [[ "${DI_ENABLED:-false}" != "true" ]]; then
        log_info "Data-integrity checks disabled for this run — skipping"
        return 0
    fi

    log_info "Verifying data integrity after $version"

    local rc=0 i t policy base cur base_var
    for i in "${!_DI_TABLES[@]}"; do
        t="${_DI_TABLES[$i]}"
        policy="${_DI_POLICY[$i]}"
        base_var="DI_BASE_${t}"
        base="${!base_var:-0}"
        cur="$(_di_count "$t")"

        if [[ -z "$cur" ]]; then
            log_error "integrity: could not count ${t} after $version (database unreachable?)"
            rc=1
            continue
        fi

        _kc_integrity_eval "$t" "$policy" "$base" "$cur" || rc=1
    done

    if [[ "$rc" -ne 0 ]]; then
        log_error "DATA INTEGRITY VIOLATED after hop $version — rows the migration must have"
        log_error "preserved are missing. The schema migrated; the data did not survive it."
        return 1
    fi

    log_success "Data integrity holds after $version"
    return 0
}

# ----------------------------------------------------------------------------
# BACKUP RESTORE TEST
#
# `pg_restore --list | grep -c "TABLE DATA"` — what the tool calls "verifying" a backup — proves
# only that the dump's table of contents is READABLE. It says nothing about whether the dump will
# restore, and nothing about what is inside it. A backup you have never restored is a hope.
#
# So actually restore it, into a scratch database, and count the rows. Opt-in
# (PROFILE_VERIFY_BACKUP_RESTORE=true) because it costs a full restore's time and disk — but for a
# production migration it is the difference between having a rollback and believing you have one.
# ----------------------------------------------------------------------------

# _di_psql_maintenance <sql> — run SQL against the maintenance DB ('postgres'), not the Keycloak
# one. CREATE/DROP DATABASE cannot run from inside the database being created or dropped.
_di_psql_maintenance() {
    PGPASSWORD="${PROFILE_DB_PASSWORD:-}" pg_client psql \
        -h "${PROFILE_DB_HOST:-localhost}" \
        -p "${PROFILE_DB_PORT:-5432}" \
        -U "${PROFILE_DB_USER:-keycloak}" \
        -d "${PROFILE_MAINTENANCE_DB:-postgres}" \
        -v ON_ERROR_STOP=1 -tAc "$1" 2>&1
}

# _di_count_in <database> <table> — COUNT(*) against an arbitrary database.
_di_count_in() {
    local db="$1" table="$2" n
    n="$(PGPASSWORD="${PROFILE_DB_PASSWORD:-}" pg_client psql \
            -h "${PROFILE_DB_HOST:-localhost}" \
            -p "${PROFILE_DB_PORT:-5432}" \
            -U "${PROFILE_DB_USER:-keycloak}" \
            -d "$db" -tAc "SELECT COUNT(*) FROM ${table};" 2>/dev/null || true)"
    printf '%s' "$(printf '%s' "$n" | tr -cd '0-9')"
}

# kc_backup_restore_test <backup_file>
#   Restore the dump into a scratch database and prove the rows are in it. Returns non-zero if the
#   dump will not restore, or restores short.
kc_backup_restore_test() {
    local backup_file="${1:-}"

    [[ "${PROFILE_VERIFY_BACKUP_RESTORE:-false}" == "true" ]] || return 0

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "DRY-RUN: would restore $backup_file into a scratch DB and compare row counts"
        return 0
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "restore-test: backup not found: $backup_file"
        return 1
    fi
    if ! pg_client_available pg_restore || ! pg_client_available psql; then
        log_warn "restore-test: pg_restore/psql unavailable — SKIPPED (backup NOT proven restorable)"
        return 0
    fi

    local src_db="${PROFILE_DB_NAME:-keycloak}"
    # $$ keeps concurrent runs from colliding on the scratch name.
    local scratch="${src_db}_restoretest_$$"

    log_section "Backup Restore Test: $(basename "$backup_file")"
    log_info "Scratch database: $scratch"

    if ! _di_psql_maintenance "CREATE DATABASE \"${scratch}\";" >/dev/null; then
        log_error "restore-test: could not create scratch database '$scratch'"
        log_error "  The DB user needs CREATEDB, or set PROFILE_VERIFY_BACKUP_RESTORE=false."
        return 1
    fi

    # Drop the scratch DB no matter how we leave — a stray copy of production is not a souvenir.
    local rc=0
    # shellcheck disable=SC2064 # expand $scratch now
    trap "_di_psql_maintenance 'DROP DATABASE IF EXISTS \"${scratch}\";' >/dev/null 2>&1 || true" RETURN

    log_info "Restoring (this takes as long as a real restore would — that is the point)"
    if ! PG_CLIENT_MOUNT="$(dirname "$backup_file")" PGPASSWORD="${PROFILE_DB_PASSWORD:-}" pg_client pg_restore \
            -h "${PROFILE_DB_HOST:-localhost}" \
            -p "${PROFILE_DB_PORT:-5432}" \
            -U "${PROFILE_DB_USER:-keycloak}" \
            -d "$scratch" \
            --no-owner --no-privileges \
            "$backup_file" 2>&1 | grep -E "^pg_restore: error" | head -10; then
        : # grep found no errors — good
    fi

    # pg_restore exits non-zero on warnings too, so judge it by the DATA, not the exit code.
    local t base cur
    for t in "${_DI_TABLES[@]}"; do
        base="$(_di_count_in "$src_db"  "$t")"
        cur="$(_di_count_in  "$scratch" "$t")"

        if [[ -z "$cur" ]]; then
            log_error "restore-test: ${t} is MISSING from the restored database"
            rc=1
            continue
        fi
        if [[ "${cur:-0}" -ne "${base:-0}" ]]; then
            log_error "restore-test: ${t} restored ${cur}, source has ${base} — the backup is SHORT"
            rc=1
            continue
        fi
        log_success "restore-test: ${t} ${cur} == source ${base}"
    done

    if [[ "$rc" -ne 0 ]]; then
        log_error "THE BACKUP IS NOT RESTORABLE. Do not start a migration you cannot roll back."
        return 1
    fi

    log_success "Backup is RESTORABLE and complete: $(basename "$backup_file")"
    return 0
}

# ----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f _kc_integrity_eval kc_data_baseline kc_data_verify kc_backup_restore_test
fi
