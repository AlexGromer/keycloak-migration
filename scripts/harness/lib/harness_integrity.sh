#!/usr/bin/env bash
# harness_integrity.sh — data-integrity gate for the migration harness.
#
# The migration tool verifies L1 (DATABASECHANGELOG) and L2 (MIGRATION_MODEL) but
# never checks that the actual DATA survives a hop. This captures a baseline of
# realm / user_entity / client COUNT(*) after seeding and, after each hop, asserts:
#   realm        == baseline   (no realm loss)
#   user_entity  == baseline   (no user loss)
#   client       >= baseline   (version migrations ADD default clients)
# Reuses _mv_psql (migration_verify.sh:46-54) as the host-side psql primitive.

# Include guard
[[ -n "${_HARNESS_INTEGRITY_SH:-}" ]] && return 0
_HARNESS_INTEGRITY_SH=1

declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# ----------------------------------------------------------------------------
# _harness_integrity_eval <base_realm> <cur_realm> <base_user> <cur_user> <base_client> <cur_client>
#   Pure policy evaluation (no DB) — returns 0 if integrity holds, 1 otherwise.
#   Logs a per-table delta. Unit-tested directly by tests/test_migration_harness.sh.
# ----------------------------------------------------------------------------
_harness_integrity_eval() {
    local br="$1" cr="$2" bu="$3" cu="$4" bc="$5" cc="$6" rc=0

    if [[ "$cr" -ne "$br" ]]; then
        log_error "integrity: realm count changed ${br} -> ${cr} (must be equal)"; rc=1
    else
        log_success "integrity: realm ${cr} == baseline ${br}"
    fi
    if [[ "$cu" -ne "$bu" ]]; then
        log_error "integrity: user_entity count changed ${bu} -> ${cu} (must be equal)"; rc=1
    else
        log_success "integrity: user_entity ${cu} == baseline ${bu}"
    fi
    if [[ "$cc" -lt "$bc" ]]; then
        log_error "integrity: client count dropped ${bc} -> ${cc} (must be >= baseline)"; rc=1
    else
        log_success "integrity: client ${cc} >= baseline ${bc}"
    fi
    return "$rc"
}

# Capture baseline counts into ${HARNESS_WORK_DIR}/baseline.env (live only).
harness_baseline() {
    if [[ "${HARNESS_DRY_RUN:-true}" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "baseline COUNT(*) realm,user_entity,client via psql -> baseline.env"
        return 0
    fi
    local r u c
    r="$(_mv_psql "SELECT COUNT(*) FROM realm;")"
    u="$(_mv_psql "SELECT COUNT(*) FROM user_entity;")"
    c="$(_mv_psql "SELECT COUNT(*) FROM client;")"
    {
        printf 'BASE_REALM=%s\n'  "${r:-0}"
        printf 'BASE_USER=%s\n'   "${u:-0}"
        printf 'BASE_CLIENT=%s\n' "${c:-0}"
    } > "${HARNESS_WORK_DIR:-.}/baseline.env"
    log_info "Baseline captured: realm=${r:-0} user_entity=${u:-0} client=${c:-0}"
}

# Re-count after hop <version> and apply the integrity policy (live only).
harness_integrity_check() {
    local version="$1"
    if [[ "${HARNESS_DRY_RUN:-true}" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "integrity check after $version: COUNT(*) realm,user_entity,client vs baseline (realm/user equal, client >=)"
        return 0
    fi
    local base_file="${HARNESS_WORK_DIR:-.}/baseline.env"
    if [[ ! -f "$base_file" ]]; then
        log_error "harness_integrity_check: baseline file missing ($base_file)"; return 1
    fi
    # shellcheck source=/dev/null
    source "$base_file"
    local r u c
    r="$(_mv_psql "SELECT COUNT(*) FROM realm;")"
    u="$(_mv_psql "SELECT COUNT(*) FROM user_entity;")"
    c="$(_mv_psql "SELECT COUNT(*) FROM client;")"
    log_info "Post-hop $version counts: realm=${r:-0} user_entity=${u:-0} client=${c:-0}"
    _harness_integrity_eval "${BASE_REALM:-0}" "${r:-0}" "${BASE_USER:-0}" "${u:-0}" "${BASE_CLIENT:-0}" "${c:-0}"
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f _harness_integrity_eval harness_baseline harness_integrity_check
fi
