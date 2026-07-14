#!/usr/bin/env bash
# harness_integrity.sh — thin shim over scripts/lib/data_integrity.sh.
#
# This logic used to live here, and here ONLY: the synthetic harness runs were guarded against
# data loss while the real migrations were not. It has been promoted to scripts/lib/data_integrity.sh
# and is now enforced on every hop of every migration (Layer 3, migrate_keycloak_v3.sh Step 6c).
#
# What remains here is the harness's own vocabulary — HARNESS_DRY_RUN, HARNESS_WORK_DIR — mapped
# onto the shared module, so the harness and its tests keep working unchanged.

# Include guard
[[ -n "${_HARNESS_INTEGRITY_SH:-}" ]] && return 0
_HARNESS_INTEGRITY_SH=1

declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# The shared module. run_migration_harness.sh sources migrate_keycloak_v3.sh (which sources it)
# before us, so this is normally a no-op include-guard hit — but keep it standalone-safe.
if ! declare -F kc_data_verify >/dev/null 2>&1; then
    _hi_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
    # shellcheck source=/dev/null
    [[ -f "$_hi_dir/data_integrity.sh" ]] && source "$_hi_dir/data_integrity.sh"
    unset _hi_dir
fi

# ----------------------------------------------------------------------------
# _harness_integrity_eval <base_realm> <cur_realm> <base_user> <cur_user> <base_client> <cur_client>
#   Pure policy evaluation (no DB) — returns 0 if integrity holds, 1 otherwise.
#   Kept for tests/test_migration_harness.sh, which asserts the policy directly. Delegates to the
#   shared per-table evaluator so the harness and the real migration can never drift apart.
# ----------------------------------------------------------------------------
_harness_integrity_eval() {
    local br="$1" cr="$2" bu="$3" cu="$4" bc="$5" cc="$6" rc=0

    _kc_integrity_eval realm       eq  "$br" "$cr" || rc=1
    _kc_integrity_eval user_entity eq  "$bu" "$cu" || rc=1
    _kc_integrity_eval client      gte "$bc" "$cc" || rc=1

    return "$rc"
}

# Capture the baseline. The harness runs with its own dry-run flag and work dir; map both onto the
# shared module's DRY_RUN / WORK_DIR before delegating.
harness_baseline() {
    if [[ "${HARNESS_DRY_RUN:-true}" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "baseline COUNT(*) realm,user_entity,client,keycloak_role -> data_baseline.env"
        return 0
    fi
    DRY_RUN=false WORK_DIR="${HARNESS_WORK_DIR:-.}" kc_data_baseline
}

# Re-count after hop <version> and apply the integrity policy (live only).
harness_integrity_check() {
    local version="$1"
    if [[ "${HARNESS_DRY_RUN:-true}" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "integrity check after $version: realm/user_entity unchanged, client/keycloak_role >= baseline"
        return 0
    fi
    DRY_RUN=false WORK_DIR="${HARNESS_WORK_DIR:-.}" kc_data_verify "$version"
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f _harness_integrity_eval harness_baseline harness_integrity_check
fi
