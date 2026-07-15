#!/usr/bin/env bash
#
# Keycloak Migration Script v3.0
# Universal migration tool for all environments
#
# Features:
# - Multi-DBMS support (PostgreSQL, MySQL, MariaDB, Oracle, MSSQL)
# - Multi-environment (Standalone, Docker, Kubernetes, Deckhouse)
# - Profile-based configuration
# - Auto-discovery of existing installations
# - All v2.0 fixes included (30 improvements)
#

set -euo pipefail

# Script metadata
# The single source of truth for the tool's version. The release workflow refuses to publish a tag
# that disagrees with this line — the versions in this repo had drifted to four different answers
# (code 3.0.0, README 3.8, Dockerfile 3.0.0, CHANGELOG 3.9.1) with no 3.9 tag existing at all.
VERSION="3.9.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC2034  # PROJECT_ROOT kept for external/sourced use
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source libraries
# v3.7: container runtime abstraction (podman/docker) — source FIRST (other libs use `cr`)
[[ -f "$LIB_DIR/container_runtime.sh" ]] && source "$LIB_DIR/container_runtime.sh"
source "$LIB_DIR/database_adapter.sh"
source "$LIB_DIR/deployment_adapter.sh"
source "$LIB_DIR/profile_manager.sh"
source "$LIB_DIR/keycloak_discovery.sh"
source "$LIB_DIR/distribution_handler.sh"
source "$LIB_DIR/audit_logger.sh"
source "$LIB_DIR/prometheus_exporter.sh"
source "$LIB_DIR/multi_tenant.sh"

# Source v3.5 production safety features
[[ -f "$LIB_DIR/preflight_checks.sh" ]] && source "$LIB_DIR/preflight_checks.sh"
[[ -f "$LIB_DIR/rate_limiter.sh" ]] && source "$LIB_DIR/rate_limiter.sh"
[[ -f "$LIB_DIR/backup_rotation.sh" ]] && source "$LIB_DIR/backup_rotation.sh"

# Source v3.6 security hardening features
[[ -f "$LIB_DIR/security_checks.sh" ]] && source "$LIB_DIR/security_checks.sh"
[[ -f "$LIB_DIR/input_validator.sh" ]] && source "$LIB_DIR/input_validator.sh"
[[ -f "$LIB_DIR/secrets_manager.sh" ]] && source "$LIB_DIR/secrets_manager.sh"
[[ -f "$LIB_DIR/audit_logger_v2.sh" ]] && source "$LIB_DIR/audit_logger_v2.sh"

# v3.7: container-hop migration model verification (Layer 2 — MIGRATION_MODEL)
[[ -f "$LIB_DIR/migration_verify.sh" ]] && source "$LIB_DIR/migration_verify.sh"

# v3.9.2: data-integrity gate (Layer 3). L1/L2 prove the migration RAN; they say nothing about
# whether the realms, users and clients are still there afterwards. Depends on migration_verify.sh
# for _mv_psql, so it must be sourced after it.
[[ -f "$LIB_DIR/data_integrity.sh" ]] && source "$LIB_DIR/data_integrity.sh"

# ============================================================================
# CONFIGURATION DEFAULTS
# ============================================================================

# Workspace
WORK_DIR="${WORK_DIR:-./migration_workspace}"
mkdir -p "$WORK_DIR"
STATE_FILE="$WORK_DIR/migration_state.env"
LOG_FILE="$WORK_DIR/migration_$(date +%Y%m%d_%H%M%S).log"

# Migration hops per target MAJOR (Keycloak).
# The detected source (e.g. 16.x) is the START, never re-booted — only these
# intermediate/target versions are booted as real containers so Keycloak runs
# both Liquibase (Layer 1) and RealmMigration (Layer 2) on startup.
# Verified safe (migrations are cumulative): 16 -> 24.0.5 -> 26.6.3 / 16 -> 25.0.6.
declare -A MIGRATION_HOPS=(
    [26]="24.0.5 26.6.3"
    [25]="25.0.6"
)
# Full target version per target MAJOR (last hop of each path).
declare -A MIGRATION_TARGET_FULL=(
    [26]="26.6.3"
    [25]="25.0.6"
)
# Default target major (overridable via env/profile).
DEFAULT_TARGET_MAJOR="${DEFAULT_TARGET_MAJOR:-26}"
# Patch releases that must NEVER be booted (known migration-breaking bugs):
#   26.6.0/26.6.1 -> exit-after-migration (#48438) + custom-browser-flow corruption (#47908).
FORBIDDEN_VERSIONS="${FORBIDDEN_VERSIONS:-26.6.0 26.6.1}"
# Target majors that are EOL (warn but allow).
EOL_TARGET_MAJORS="${EOL_TARGET_MAJORS:-25}"
# Minimum PostgreSQL major required by target major 26 (26.6 dropped PG13).
MIN_PG_FOR_26="${MIN_PG_FOR_26:-14}"

# Java requirements per Keycloak version
declare -A JAVA_REQUIREMENTS=(
    [16]="11"
    [17]="11"
    [18]="11"
    [19]="11"
    [20]="11"
    [21]="11"
    [22]="17"
    [23]="17"
    [24]="17"
    [25]="17"
    [26]="21"
)

# Default configuration (can be overridden by profile)
PROFILE_NAME="${PROFILE_NAME:-}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_TESTS="${SKIP_TESTS:-false}"
ENABLE_MONITOR="${ENABLE_MONITOR:-false}"
# v3.9: non-interactive confirmation. --yes/-y sets this; env ASSUME_DEFAULTS also honored.
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
# v3.9.1: static analysis of THIS TOOL's own source — irrelevant to a migration, so OFF by
# default. Enable with --security-scan or ENABLE_SECURITY_SCAN=true.
ENABLE_SECURITY_SCAN="${ENABLE_SECURITY_SCAN:-false}"
# v3.9.1: --no-resume ignores checkpoints from a previous (possibly failed) attempt.
NO_RESUME="${NO_RESUME:-false}"
# v3.9.1 (ADR-008): --force-unlock releases a stale Liquibase changelog lock left by a crash.
FORCE_UNLOCK="${FORCE_UNLOCK:-false}"
# v3.9.1: --kill-stale terminates competing/hung migration processes instead of refusing to run.
KILL_STALE="${KILL_STALE:-false}"

# Migration settings
TIMEOUT_BUILD="${TIMEOUT_BUILD:-600}"
TIMEOUT_MIGRATE="${TIMEOUT_MIGRATE:-900}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-5}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-10}"

# ============================================================================
# COLORS AND LOGGING
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
# shellcheck disable=SC2034  # MAGENTA part of color palette, reserved for future use
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

log_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg" | tee -a "$LOG_FILE"
}

log_success() {
    local msg="$1"
    echo -e "${GREEN}[✓]${NC} $msg" | tee -a "$LOG_FILE"
}

log_warn() {
    local msg="$1"
    echo -e "${YELLOW}[!]${NC} $msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="$1"
    echo -e "${RED}[✗]${NC} $msg" | tee -a "$LOG_FILE"
}

log_section() {
    local msg="$1"
    echo -e "\n${CYAN}${BOLD}═══ $msg ═══${NC}\n" | tee -a "$LOG_FILE"
}

# v3.9: confirmation prompt that auto-answers in non-interactive contexts.
#   _confirm "Question?" "Y"|"N"   — the 2nd arg is the default AND the auto-answer.
# Auto-answers (no prompt) when --yes (AUTO_CONFIRM), ASSUME_DEFAULTS=true, or stdin is
# not a TTY. Returns 0 = yes, 1 = no. Interactive behaviour (a TTY, no flags) is unchanged.
# v3.9.1: Ctrl-C must abort cleanly. There was NO signal trap at all, so an interrupt during
# wait_for_migration's poll loop did not stop the run and left the transient container behind.
# ============================================================================
# v3.9.1: SINGLE-INSTANCE GUARD.
# Two migrations running against the same workspace fight over the transient container name
# (kc-migrate-<version>): one run's cleanup removes the container the OTHER run just started.
# That is exactly how a "hung" run from a previous attempt silently murdered a healthy container
# in the middle of Liquibase — the DB migration had already succeeded, but the container vanished
# and the live run reported failure.
# ============================================================================
MIGRATION_LOCK_FILE="${MIGRATION_LOCK_FILE:-$WORK_DIR/migration.lock}"
_KC_LOCK_HELD="false"

_kc_acquire_lock() {
    if [[ -f "$MIGRATION_LOCK_FILE" ]]; then
        local old_pid
        old_pid="$(tr -d '[:space:]' < "$MIGRATION_LOCK_FILE" 2>/dev/null || true)"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log_error "Another migration is ALREADY RUNNING (PID $old_pid)."
            log_error "  lock: $MIGRATION_LOCK_FILE"
            log_error "Two runs would fight over the kc-migrate-<version> container name and kill"
            log_error "each other's containers mid-migration. Stop the other run first:"
            log_error "    kill $old_pid"
            return 1
        fi
        log_warn "Stale lock from a dead process (PID ${old_pid:-?}) — reclaiming it"
    fi
    printf '%s' "$$" > "$MIGRATION_LOCK_FILE" 2>/dev/null || true
    _KC_LOCK_HELD="true"
    return 0
}

_kc_release_lock() {
    [[ "${_KC_LOCK_HELD:-false}" == "true" ]] || return 0
    rm -f "$MIGRATION_LOCK_FILE" 2>/dev/null || true
    _KC_LOCK_HELD="false"
}

# True only while WE hold the user's Keycloak down: set after Step 2's stop, cleared by Step 5's
# start. Never set in `run` mode — there is no long-lived service there, only a transient container.
_KC_SERVICE_STOPPED_BY_US="false"

_kc_on_interrupt() {
    trap - INT TERM
    echo "" >&2
    log_warn "Interrupted — aborting migration."
    _kc_release_lock

    local mode="${PROFILE_KC_DEPLOYMENT_MODE:-}"

    if [[ "$mode" == "run" ]] && declare -F kc_run_stop_container >/dev/null 2>&1; then
        local cname="${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${KC_HOP_VERSION:-${PROFILE_KC_TARGET_VERSION:-}}}"
        log_warn "Stopping transient migration container: $cname"
        kc_run_stop_container "$cname" 2>/dev/null || true
    fi

    # Every other mode stops the user's REAL Keycloak at Step 2 and restarts it at Step 5. A
    # Ctrl-C in that window used to just exit — leaving `systemctl stop keycloak` un-done, or a
    # `kubectl scale --replicas=0` un-done, i.e. production scaled to zero and nobody putting it
    # back. Whatever else has gone wrong, we do not walk away from a service we took down.
    if [[ "${_KC_SERVICE_STOPPED_BY_US:-false}" == "true" ]] && declare -F kc_service_start >/dev/null 2>&1; then
        log_warn "Keycloak was stopped by this run ($mode) — bringing it back up."
        # shellcheck disable=SC2119 # optional args: service identity comes from the profile
        if kc_service_start 2>/dev/null; then
            log_success "Keycloak restarted."
        else
            log_error "COULD NOT RESTART KEYCLOAK — it is still DOWN. Start it by hand:"
            case "$mode" in
                standalone)     log_error "    systemctl start ${PROFILE_KC_SERVICE_NAME:-keycloak}" ;;
                docker|podman)  log_error "    docker start ${PROFILE_KC_CONTAINER_NAME:-keycloak}" ;;
                docker-compose) log_error "    docker compose -f ${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml} up -d" ;;
                kubernetes)     log_error "    kubectl scale deployment/${PROFILE_K8S_DEPLOYMENT:-keycloak} --replicas=${PROFILE_K8S_REPLICAS:-1} -n ${PROFILE_K8S_NAMESPACE:-keycloak}" ;;
                deckhouse)      log_error "    kubectl patch moduleconfig keycloak --type=merge -p '{\"spec\":{\"enabled\":true}}'" ;;
            esac
        fi
    fi

    log_warn "The database may be MID-MIGRATION. Check before retrying:"
    log_warn "  SELECT version FROM MIGRATION_MODEL ORDER BY update_time DESC LIMIT 1;"
    exit 130
}

_confirm() {
    local prompt="$1" def="${2:-N}" ans
    if [[ "${AUTO_CONFIRM:-false}" == "true" || "${ASSUME_DEFAULTS:-false}" == "true" || ! -t 0 ]]; then
        log_info "$prompt — auto-answer '${def}' (non-interactive)"
        [[ "$def" =~ ^[Yy]$ ]]
        return
    fi
    local hint="[y/N]"; [[ "$def" =~ ^[Yy]$ ]] && hint="[Y/n]"
    read -r -p "$prompt $hint: " ans
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ============================================================================
# VERSION AUTO-DETECTION
# ============================================================================

kc_detect_version() {
    # Auto-detect current Keycloak version from multiple sources
    local version=""

    # Method 1: Check Keycloak home directory for version.txt
    if [[ -n "${PROFILE_KC_HOME:-}" && -f "${PROFILE_KC_HOME}/version.txt" ]]; then
        # shellcheck disable=SC2002 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
        version=$(cat "${PROFILE_KC_HOME}/version.txt" | grep -oP '\d+\.\d+\.\d+' | head -1)
    fi

    # Method 2: Check JAR manifest
    if [[ -z "$version" && -n "${PROFILE_KC_HOME:-}" ]]; then
        local jar_file
        jar_file=$(find "${PROFILE_KC_HOME}/lib" -name "keycloak-server-spi-*.jar" 2>/dev/null | head -1)
        if [[ -n "$jar_file" ]]; then
            version=$(unzip -p "$jar_file" META-INF/MANIFEST.MF 2>/dev/null | \
                grep "Implementation-Version" | cut -d' ' -f2 | tr -d '\r\n' | grep -oP '\d+\.\d+\.\d+')
        fi
    fi

    # Method 3: Query database for DATABASECHANGELOG
    if [[ -z "$version" && -n "${PROFILE_DB_TYPE:-}" ]]; then
        case "${PROFILE_DB_TYPE}" in
            postgresql|cockroachdb)
                if command -v psql &>/dev/null; then
                    version=$(PGPASSWORD="${PROFILE_DB_PASSWORD}" psql \
                        -h "${PROFILE_DB_HOST}" -p "${PROFILE_DB_PORT}" \
                        -U "${PROFILE_DB_USER}" -d "${PROFILE_DB_NAME}" \
                        -tAc "SELECT id FROM DATABASECHANGELOG ORDER BY DATEEXECUTED DESC LIMIT 1;" 2>/dev/null | \
                        grep -oP '\d+\.\d+\.\d+' | head -1)
                fi
                ;;
            mysql|mariadb)
                if command -v mysql &>/dev/null; then
                    version=$(mysql -h "${PROFILE_DB_HOST}" -P "${PROFILE_DB_PORT}" \
                        -u "${PROFILE_DB_USER}" -p"${PROFILE_DB_PASSWORD}" "${PROFILE_DB_NAME}" \
                        -N -e "SELECT id FROM DATABASECHANGELOG ORDER BY DATEEXECUTED DESC LIMIT 1;" 2>/dev/null | \
                        grep -oP '\d+\.\d+\.\d+' | head -1)
                fi
                ;;
        esac
    fi

    # Method 4: Check container image tag (compose / single container), any registry
    if [[ -z "$version" && "${PROFILE_KC_DEPLOYMENT_MODE:-}" =~ ^(docker-compose|docker|podman|run)$ ]]; then
        local compose_file="${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"
        if [[ -f "$compose_file" ]]; then
            version=$(grep -A5 "keycloak" "$compose_file" | grep "image:" | \
                grep -oP 'keycloak[^:[:space:]]*:\K[0-9][0-9.]*' | head -1)
        fi
    fi

    # Method 5: Kubernetes deployment
    if [[ -z "$version" && "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "kubernetes" ]]; then
        local namespace="${PROFILE_KC_NAMESPACE:-keycloak}"
        local deployment="${PROFILE_KC_DEPLOYMENT:-keycloak}"
        if command -v kubectl &>/dev/null; then
            version=$(kubectl get deployment "$deployment" -n "$namespace" \
                -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | \
                grep -oP ':\K[\d\.]+')
        fi
    fi

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    else
        log_warn "Could not auto-detect Keycloak version"
        return 1
    fi
}

# Return 0 if version $1 <= version $2 (semantic version order).
_ver_le() {
    [[ "$1" == "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# Echo the space-separated list of container hops to BOOT to reach a target major,
# from the detected current version. The current version is the START and is never
# re-booted; any hop at or below it is skipped (already migrated).
kc_build_migration_path() {
    local current="$1" target_major="$2"
    local hops="${MIGRATION_HOPS[$target_major]:-}"
    if [[ -z "$hops" ]]; then
        echo "ERROR: no migration hops defined for target major '$target_major'" >&2
        return 1
    fi
    local out=() hop
    for hop in $hops; do
        _ver_le "$hop" "$current" && continue
        out+=("$hop")
    done
    if [[ ${#out[@]} -eq 0 ]]; then
        echo "ERROR: current version $current is already at/beyond target major '$target_major'" >&2
        return 1
    fi
    echo "${out[*]}"
}

# major.minor of a version string: 26.6.3 -> 26.6
_kc_major_minor() { local v="$1"; printf '%s' "${v%.*}"; }

# ============================================================================
# STALE / COMPETING MIGRATION PROCESSES
#
# Two migration processes fight over the transient container name (kc-migrate-<version>): one
# run's cleanup removes the container the OTHER run just started, killing a healthy migration
# mid-Liquibase. This is not hypothetical — it happened on a live run, and the culprit was a
# leftover process from an earlier (hung) attempt. Detect them before doing anything.
# ============================================================================

# PIDs of this process and all of its ancestors — never treat ourselves as a stale process.
_kc_self_and_ancestors() {
    local p="$$"
    while [[ -n "$p" && "$p" != "0" && "$p" != "1" ]]; do
        printf '%s\n' "$p"
        p="$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || true)"
    done
}

# kc_find_other_migration_procs — echo the PID of every OTHER migrate/oneshot process.
# Returns 1 when there are none.
kc_find_other_migration_procs() {
    command -v pgrep >/dev/null 2>&1 || return 1
    local mine pids=() p
    mine="$(_kc_self_and_ancestors)"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        grep -qx "$p" <<< "$mine" && continue     # ourselves / our launcher
        pids+=("$p")
    done < <(pgrep -f 'migrate_keycloak_v3\.sh|migrate_oneshot\.sh' 2>/dev/null || true)
    [[ ${#pids[@]} -gt 0 ]] || return 1
    printf '%s\n' "${pids[@]}"
}

# kc_kill_stale_processes <pid>... — SIGTERM, then SIGKILL whatever survives.
kc_kill_stale_processes() {
    local p
    for p in "$@"; do
        log_warn "Terminating competing migration process PID $p"
        kill -TERM "$p" 2>/dev/null || true
    done
    sleep 3
    for p in "$@"; do
        if kill -0 "$p" 2>/dev/null; then
            log_warn "PID $p ignored SIGTERM — sending SIGKILL"
            kill -KILL "$p" 2>/dev/null || true
        fi
    done
}

# ============================================================================
# ADR-008 — STATE RECONCILIATION: the state is a FACT, not a journal.
#
# Checkpoints and the profile's `current_version` are CLAIMS about the past. Trusting them caused
# real damage: a stale checkpoint made the tool "skip the start" of a container that no longer
# existed, and the profile's claim would have re-run hops the database had already passed.
#
# Before deciding anything we now read the ACTUAL state:
#   1. which Keycloak version really migrated this database (MIGRATION_MODEL),
#   2. whether a crashed migration left a Liquibase lock held (DATABASECHANGELOGLOCK),
#   3. which transient migration containers really exist.
#
# Returns: 0 = proceed, 1 = abort, 2 = nothing to do (already at target).
# ============================================================================
kc_reconcile_state() {
    local target_major="$1"

    log_section "State Reconciliation (reading the ACTUAL state — ADR-008)"

    # --- 0. Competing / stale migration processes ---
    # They would remove the kc-migrate-<version> container this run creates (same name) and kill a
    # healthy migration mid-Liquibase. Catch them first.
    local others
    if others="$(kc_find_other_migration_procs)"; then
        log_error "Other migration processes are running. They fight over the kc-migrate-<version>"
        log_error "container name and will destroy each other's containers mid-migration:"
        local _p
        while IFS= read -r _p; do
            [[ -n "$_p" ]] && ps -o pid=,etimes=,args= -p "$_p" 2>/dev/null | sed 's/^/    pid=/' || true
        done <<< "$others"

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_warn "DRY-RUN: reporting only (a dry run neither blocks nor kills anything)"
        elif [[ "${KILL_STALE:-false}" == "true" ]]; then
            # shellcheck disable=SC2086  # intentional word-split of the PID list
            kc_kill_stale_processes $others
            log_success "Competing processes terminated"
        else
            log_error "Stop them first, or re-run with --kill-stale:"
            log_error "    pkill -f migrate_keycloak_v3 ; pkill -f migrate_oneshot"
            return 1
        fi
    else
        log_success "No competing migration processes"
    fi

    # --- 1. Ground truth: which version last migrated THIS database? ---
    local db_version=""
    if declare -F kc_db_model_version >/dev/null 2>&1; then
        db_version="$(kc_db_model_version || true)"
    fi

    if [[ -n "$db_version" ]]; then
        log_success "Database (MIGRATION_MODEL) is at: $db_version"
        local claimed="${PROFILE_KC_CURRENT_VERSION:-}"
        if [[ -n "$claimed" && "$(_kc_major_minor "$claimed")" != "$(_kc_major_minor "$db_version")" ]]; then
            log_warn "Profile claims current_version=${claimed}, but the DATABASE says ${db_version}."
            log_warn "The database is the fact — recomputing the hop chain from ${db_version}."
        fi
        export PROFILE_KC_CURRENT_VERSION="$db_version"
    else
        log_warn "Cannot read MIGRATION_MODEL (DB not initialised by Keycloak, or unreachable)."
        log_warn "Falling back to the profile's claim: current_version=${PROFILE_KC_CURRENT_VERSION:-<unset>}"
    fi

    # --- 2. Stale Liquibase lock: a crashed migration blocks every later Keycloak ---
    if declare -F kc_db_changelog_locked >/dev/null 2>&1; then
        local locked
        if locked="$(kc_db_changelog_locked)"; then
            log_error "Liquibase changelog lock is HELD (a previous migration crashed mid-flight):"
            printf '%s\n' "$locked" | sed 's/^/    id|lockedby|since = /'
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                log_info "DRY-RUN: would NOT release the lock (a dry run mutates nothing)"
                return 1
            elif [[ "${FORCE_UNLOCK:-false}" == "true" ]]; then
                log_warn "--force-unlock: releasing the stale lock"
                if kc_db_clear_changelog_lock; then
                    log_success "Changelog lock released"
                else
                    log_error "Failed to release the changelog lock"
                    return 1
                fi
            else
                log_error "Keycloak would block on this lock. Release it, then retry:"
                log_error "  UPDATE databasechangeloglock SET locked=false, lockedby=null, lockgranted=null;"
                log_error "  ...or re-run with --force-unlock"
                return 1
            fi
        else
            log_success "Liquibase changelog lock: free"
        fi
    fi

    # --- 3. Existing transient migration containers ---
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "run" ]] && declare -F cr >/dev/null 2>&1; then
        local leftovers
        leftovers="$(cr ps -a --filter "name=kc-migrate-" --format '{{.Names}} {{.Status}}' 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
        if [[ -n "$leftovers" ]]; then
            log_warn "Existing migration containers:"
            printf '%s\n' "$leftovers" | sed 's/^/    /'

            # NEVER touch a RUNNING kc-migrate-* container. It belongs to a migration that is in
            # flight, and removing it kills a healthy migration in the middle of Liquibase. This
            # is not hypothetical: an earlier version of this cleanup did exactly that to a live
            # run (even from a --dry-run process), which is why the guard exists.
            local running
            running="$(cr ps --filter "name=kc-migrate-" --format '{{.Names}}' 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
            if [[ -n "$running" ]]; then
                log_error "A migration container is RUNNING — another migration is in flight:"
                printf '%s\n' "$running" | sed 's/^/    /'
                log_error "Refusing to touch it. Stop that migration first, or remove the container"
                log_error "yourself once you are sure it is dead."
                return 1
            fi

            # A DRY RUN MUST MUTATE NOTHING.
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                log_info "DRY-RUN: would remove the stopped leftovers listed above (nothing changed)"
            else
                local _line
                while IFS= read -r _line; do
                    [[ -n "$_line" ]] && cr rm -f "${_line%% *}" >/dev/null 2>&1 || true
                done <<< "$leftovers"
                log_success "Removed the stopped leftovers (they would clash on name)"
            fi
        else
            log_success "No leftover migration containers"
        fi
    fi

    # --- 4. Already at the target? Then there is nothing to do. ---
    local target_full="${MIGRATION_TARGET_FULL[$target_major]:-}"
    if [[ -n "$db_version" && -n "$target_full" ]]; then
        if [[ "$(_kc_major_minor "$db_version")" == "$(_kc_major_minor "$target_full")" ]]; then
            log_success "Database is ALREADY at the target (${db_version}) — nothing to migrate."
            return 2
        fi
    fi

    return 0
}

# Gate: target major 26 (26.6) requires PostgreSQL >= MIN_PG_FOR_26 (PG13 dropped).
check_db_version_for_target() {
    local target_major="$1"
    [[ "$target_major" != "26" ]] && return 0
    case "${PROFILE_DB_TYPE:-}" in postgresql|postgres|cockroachdb) ;; *) return 0 ;; esac
    command -v psql &>/dev/null || { log_warn "psql not found; cannot verify PG >= $MIN_PG_FOR_26 for target 26.x"; return 0; }
    local pgver
    pgver=$(PGPASSWORD="${PROFILE_DB_PASSWORD:-}" psql -h "${PROFILE_DB_HOST}" -p "${PROFILE_DB_PORT}" \
        -U "${PROFILE_DB_USER}" -d "${PROFILE_DB_NAME}" -tAc "SHOW server_version_num;" 2>/dev/null | tr -d ' ')
    if [[ -z "$pgver" || ! "$pgver" =~ ^[0-9]+$ ]]; then
        log_warn "Could not determine PostgreSQL version; ensure PG >= $MIN_PG_FOR_26 before target 26.x"
        return 0
    fi
    local pg_major=$(( pgver / 10000 ))
    if [[ "$pg_major" -lt "$MIN_PG_FOR_26" ]]; then
        log_error "Target major 26 requires PostgreSQL >= $MIN_PG_FOR_26, found $pg_major — upgrade PostgreSQL first"
        return 1
    fi
    log_success "PostgreSQL $pg_major satisfies >= $MIN_PG_FOR_26 for target 26.x"
    return 0
}

# Select the target version. Returns the FULL target version (e.g. 26.6.3) on stdout;
# all UI goes to stderr so command substitution captures only the version.
# Honors TARGET_MAJOR env / non-interactive default (DEFAULT_TARGET_MAJOR).
kc_select_target_version() {
    local current_version="${1:-}"
    if [[ -z "$current_version" ]]; then
        echo "ERROR: Current version not specified" >&2
        return 1
    fi

    # Available target majors, newest first.
    local majors=() m
    for m in "${!MIGRATION_TARGET_FULL[@]}"; do majors+=("$m"); done
    IFS=$'\n' read -r -d '' -a majors < <(printf '%s\n' "${majors[@]}" | sort -rn && printf '\0')

    local chosen_major="${TARGET_MAJOR:-}"
    if [[ -z "$chosen_major" ]] && { [[ ! -t 0 ]] || [[ "${ASSUME_DEFAULTS:-false}" == "true" ]] || [[ "${AUTO_CONFIRM:-false}" == "true" ]]; }; then
        chosen_major="$DEFAULT_TARGET_MAJOR"
        echo "Non-interactive: defaulting target major to $chosen_major" >&2
    fi

    if [[ -z "$chosen_major" ]]; then
        {
            echo ""
            echo "Current version: $current_version"
            echo "Available target majors:"
            local i=1
            for m in "${majors[@]}"; do
                local full="${MIGRATION_TARGET_FULL[$m]}" tag=""
                [[ "$m" == "$DEFAULT_TARGET_MAJOR" ]] && tag=" (recommended, default)"
                [[ " $EOL_TARGET_MAJORS " == *" $m "* ]] && tag="$tag [EOL - unsupported]"
                printf "  [%d] major %s -> %s%s\n" "$i" "$m" "$full" "$tag"
                i=$((i + 1))
            done
        } >&2
        local choice
        read -rp "Select target major [default $DEFAULT_TARGET_MAJOR]: " choice
        if [[ -z "$choice" ]]; then
            chosen_major="$DEFAULT_TARGET_MAJOR"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#majors[@]} ]]; then
            chosen_major="${majors[$((choice - 1))]}"
        else
            chosen_major="$choice"
        fi
    fi

    local target_full="${MIGRATION_TARGET_FULL[$chosen_major]:-}"
    if [[ -z "$target_full" ]]; then
        echo "ERROR: no target defined for major '$chosen_major'" >&2
        return 1
    fi

    local fv
    for fv in $FORBIDDEN_VERSIONS; do
        if [[ "$target_full" == "$fv" ]]; then
            echo "ERROR: target $target_full is a forbidden (migration-breaking) release" >&2
            return 1
        fi
    done

    if [[ " $EOL_TARGET_MAJORS " == *" $chosen_major "* ]]; then
        echo "WARNING: target major $chosen_major ($target_full) is EOL/unsupported - proceed only if required" >&2
    fi

    echo "$target_full"
    return 0
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

update_state() {
    local key="$1"
    local value="$2"

    mkdir -p "$WORK_DIR"

    if [[ -f "$STATE_FILE" ]]; then
        # Update existing key or append
        if grep -q "^${key}=" "$STATE_FILE"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
        else
            echo "${key}=${value}" >> "$STATE_FILE"
        fi
    else
        echo "${key}=${value}" > "$STATE_FILE"
    fi
}

# Checkpoint names for intra-step granularity:
#   backup_done → stopped → downloaded → built → started → migrated → health_ok → tests_ok
set_checkpoint() {
    local version="$1"
    local checkpoint="$2"
    update_state "CHECKPOINT_${version//\./_}" "$checkpoint"
    update_state "LAST_CHECKPOINT" "${version}:${checkpoint}"
    log_info "Checkpoint: ${version} → ${checkpoint}"

    # Update Prometheus metrics if monitoring enabled
    if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
        prom_set_checkpoint "$checkpoint" 2  # 2 = completed
    fi
}

get_checkpoint() {
    local version="$1"
    local key="CHECKPOINT_${version//\./_}"
    if [[ -f "$STATE_FILE" ]]; then
        grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo ""
    fi
}

# clear_checkpoint <version>
#   Forget everything we recorded about this hop.
#
#   A rollback restores the database to BEFORE the hop, but the checkpoints describing that hop
#   used to survive it. On the next run should_skip_to would then read CHECKPOINT_26_6_3=migrated
#   and skip backup/stop/start — asserting a migration that the restore had just undone, against
#   a database that no longer had it. The state file must not outlive the state it describes.
clear_checkpoint() {
    local version="$1"
    local key="CHECKPOINT_${version//\./_}"

    [[ -f "$STATE_FILE" ]] || return 0

    local tmp="${STATE_FILE}.tmp.$$"
    grep -v -e "^${key}=" -e "^LAST_CHECKPOINT=${version}:" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE"

    # The in-memory copy comes from `source`ing the state file — stale exported values would
    # otherwise outlive the line we just deleted.
    unset "$key" LAST_CHECKPOINT
    log_info "Checkpoints cleared for $version"
}

# kc_backup_dir — the one directory per-hop backups live in. Creates it.
#
#   Hop backups were written flat into $WORK_DIR while rotation swept $WORK_DIR/backups. Two
#   different directories: rotation reported "Found 0 backup(s)" on every run and never deleted
#   anything. A four-hop migration of a large database left four dumps on disk forever.
#
#   They now share this one path. Safety backups (safety_before_rollback_*.dump) stay OUT of it,
#   in $WORK_DIR: rotation globs *.dump and would happily prune the emergency copy taken moments
#   before a restore.
kc_backup_dir() {
    local dir="${WORK_DIR}/backups"
    mkdir -p "$dir" 2>/dev/null || true
    printf '%s' "$dir"
}

should_skip_to() {
    # Returns 0 (true) if we should skip to this phase (already done)
    local current_checkpoint="$1"
    local target_checkpoint="$2"

    local -a checkpoint_order=(backup_done stopped downloaded built started migrated health_ok tests_ok)

    local current_idx=-1
    local target_idx=-1
    local i=0
    for cp in "${checkpoint_order[@]}"; do
        [[ "$cp" == "$current_checkpoint" ]] && current_idx=$i
        [[ "$cp" == "$target_checkpoint" ]] && target_idx=$i
        i=$((i + 1))
    done

    [[ $current_idx -ge $target_idx ]]
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090  # STATE_FILE path is dynamic at runtime
        source "$STATE_FILE"
        log_info "State loaded from: $STATE_FILE"
    fi
}

check_resume() {
    if [[ -f "$STATE_FILE" ]]; then
        local resume_safe="${RESUME_SAFE:-false}"
        local last_step="${LAST_SUCCESSFUL_STEP:-}"

        if [[ "$resume_safe" == "true" && -n "$last_step" ]]; then
            log_warn "Detected interrupted migration"
            log_info "Last successful step: $last_step"
            echo ""
            if _confirm "Resume from last successful step?" "N"; then
                log_info "Resuming migration from step: $last_step"
                return 0
            else
                log_info "Starting fresh migration"
                rm -f "$STATE_FILE"
                return 1
            fi
        fi
    fi
    return 1
}

# ============================================================================
# PRE-FLIGHT CHECKS (integrated, v3-aware)
# ============================================================================

PREFLIGHT_MARKER="$WORK_DIR/.preflight_passed"

run_preflight_checks() {
    if [[ -f "$PREFLIGHT_MARKER" ]]; then
        log_info "Pre-flight checks already passed (marker: $PREFLIGHT_MARKER)"
        return 0
    fi

    log_section "Pre-Flight Checks"

    local errors=0

    # 1. Free space on the WORK_DIR filesystem (default 15 GB; override with MIN_DISK_GB).
    #    This space is for the pre-hop DB dumps (backup ~ DB size x3) — NOT for container
    #    images (those live in the container-runtime store).
    local target_path="$WORK_DIR"
    [[ ! -d "$target_path" ]] && target_path="$(dirname "$target_path")"
    local available_gb=$(df -BG "$target_path" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")
    local required_gb="${MIN_DISK_GB:-15}"

    if [[ "${available_gb:-0}" -ge "$required_gb" ]]; then
        log_success "Disk space: ${available_gb}GB available on ${target_path} (need ${required_gb}GB)"
    else
        log_error "Disk space: ${available_gb}GB < ${required_gb}GB required on ${target_path} (WORK_DIR)"
        log_info "  Space is for pre-hop DB dumps (backup ~ DB size x3), not for images."
        log_info "  Point WORK_DIR at a filesystem with more free space:"
        log_info "    export WORK_DIR=/path/on/bigger/fs             # migrate_keycloak_v3.sh"
        log_info "    scripts/migrate_oneshot.sh --work-dir /path/on/bigger/fs"
        log_info "  Or adjust: export MIN_DISK_GB=<N>   |   skip checks: --skip-preflight"
        errors=$((errors + 1))
    fi

    # 2. Required tools
    local required_tools=("curl" "tar")
    # Add DB-specific tools
    case "${PROFILE_DB_TYPE:-}" in
        postgresql) required_tools+=("psql" "pg_dump") ;;
        mysql|mariadb) required_tools+=("mysql" "mysqldump") ;;
    esac
    # Add deployment-specific tools
    case "${PROFILE_KC_DEPLOYMENT_MODE:-}" in
        kubernetes|deckhouse) required_tools+=("kubectl") ;;
    esac
    # Container modes: a runtime (podman OR docker) is validated via cr_available below
    case "${PROFILE_KC_DEPLOYMENT_MODE:-}" in
        docker|podman|run|docker-compose)
            if declare -F cr_available >/dev/null 2>&1 && cr_available; then
                log_success "Container runtime available: ${CONTAINER_RUNTIME:-?}"
            else
                log_error "No container runtime (podman/docker) found for mode '${PROFILE_KC_DEPLOYMENT_MODE}'"
                errors=$((errors + 1))
            fi
            ;;
    esac
    if [[ "${PROFILE_KC_DISTRIBUTION_MODE:-}" == "helm" ]]; then
        required_tools+=("helm")
    fi

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            log_success "Tool available: $tool"
        else
            log_error "Tool missing: $tool"
            errors=$((errors + 1))
        fi
    done

    # 3. Java check (standalone only — container/K8s images carry their own JDK)
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "standalone" ]]; then
        local current="${PROFILE_KC_CURRENT_VERSION}"
        local target_major
        target_major=$(echo "${PROFILE_KC_TARGET_VERSION}" | cut -d. -f1)
        local max_needed=11 _hops _hop
        _hops=$(kc_build_migration_path "$current" "$target_major" 2>/dev/null) || _hops=""
        for _hop in $_hops; do
            local major req
            major=$(echo "$_hop" | cut -d. -f1)
            req="${JAVA_REQUIREMENTS[$major]:-11}"
            [[ "$req" -gt "$max_needed" ]] && max_needed="$req"
        done

        if command -v java &>/dev/null; then
            local current_java
            current_java=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
            [[ "$current_java" == "1" ]] && current_java=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f2)
            if [[ "$current_java" -ge "$max_needed" ]]; then
                log_success "Java $current_java (need >= $max_needed)"
            else
                log_error "Java $current_java insufficient — migration path requires Java >= $max_needed"
                errors=$((errors + 1))
            fi
        else
            log_error "Java not found"
            errors=$((errors + 1))
        fi
    else
        log_info "Java check skipped (mode '${PROFILE_KC_DEPLOYMENT_MODE:-unknown}' — JDK lives in the container image)"
    fi

    # 4. Network check (for download mode only)
    if [[ "${PROFILE_KC_DISTRIBUTION_MODE:-download}" == "download" && "${AIRGAP_MODE:-false}" != "true" ]]; then
        if curl -sf --max-time 10 https://github.com &>/dev/null; then
            log_success "Network: GitHub reachable"
        else
            log_error "Network: Cannot reach GitHub (required for download mode)"
            log_info "Use distribution_mode: predownloaded or set AIRGAP_MODE=true"
            errors=$((errors + 1))
        fi
    fi

    # 5. Database connectivity (standalone only — K8s has its own networking)
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "standalone" ]]; then
        # Same precedence as db_backup_keycloak/db_restore_keycloak: PROFILE_DB_PASSWORD first.
        local db_pass="${PROFILE_DB_PASSWORD:-${PGPASSWORD:-${DB_PASSWORD:-}}}"
        if [[ -n "$db_pass" ]]; then
            if db_test_connection "${PROFILE_DB_TYPE}" "${PROFILE_DB_HOST}" \
                "${PROFILE_DB_PORT}" "${PROFILE_DB_NAME}" "${PROFILE_DB_USER}" "$db_pass"; then
                log_success "Database: ${PROFILE_DB_TYPE} @ ${PROFILE_DB_HOST}:${PROFILE_DB_PORT} — connected"
            else
                log_error "Database: Cannot connect to ${PROFILE_DB_TYPE} @ ${PROFILE_DB_HOST}:${PROFILE_DB_PORT}"
                errors=$((errors + 1))
            fi
        else
            log_warn "Database: No password set (PGPASSWORD/DB_PASSWORD), skipping connection test"
        fi
    fi

    # 6. Memory check
    local total_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    if [[ "$total_mem" -ge 4 ]]; then
        log_success "Memory: ${total_mem}GB"
    else
        log_warn "Memory: ${total_mem}GB (recommend 4GB+, migration may be slow)"
    fi

    # Result
    if [[ $errors -gt 0 ]]; then
        log_error "Pre-flight failed: $errors critical issue(s)"
        log_info "Fix the issues above and retry."
        return 1
    fi

    mkdir -p "$WORK_DIR"
    touch "$PREFLIGHT_MARKER"
    log_success "All pre-flight checks passed"
    return 0
}

# ============================================================================
# PROFILE LOADING
# ============================================================================

load_profile_or_discover() {
    local profile="${1:-}"

    if [[ -n "$profile" ]]; then
        log_section "Loading Profile: $profile"
        profile_load "$profile" || {
            log_error "Failed to load profile: $profile"
            exit 1
        }
        profile_summary "$profile"
    else
        log_section "Auto-Discovery Mode"
        log_info "No profile specified, attempting auto-discovery..."
        echo ""

        if kc_auto_discover_profile; then
            log_success "Auto-discovery complete"
            echo ""
            if _confirm "Use auto-discovered configuration?" "Y"; then
                log_info "Using auto-discovered configuration"
            else
                log_error "Auto-discovery rejected. Please specify a profile with --profile"
                exit 1
            fi
        else
            log_error "Auto-discovery failed. Please specify a profile with --profile"
            exit 1
        fi
    fi

    # Validate required variables
    validate_profile_variables
}

validate_profile_variables() {
    local errors=0

    # Database
    if [[ -z "${PROFILE_DB_TYPE:-}" ]]; then
        log_error "Database type not set"
        errors=$((errors + 1))
    fi

    # Deployment
    if [[ -z "${PROFILE_KC_DEPLOYMENT_MODE:-}" ]]; then
        log_error "Deployment mode not set"
        errors=$((errors + 1))
    fi

    # Versions - Auto-detect if not set
    if [[ -z "${PROFILE_KC_CURRENT_VERSION:-}" ]]; then
        log_info "Current version not specified, attempting auto-detection..."
        if PROFILE_KC_CURRENT_VERSION=$(kc_detect_version); then
            export PROFILE_KC_CURRENT_VERSION
            log_success "Auto-detected current version: $PROFILE_KC_CURRENT_VERSION"
        else
            log_error "Current Keycloak version not set and auto-detection failed"
            errors=$((errors + 1))
        fi
    fi

    if [[ -z "${PROFILE_KC_TARGET_VERSION:-}" ]]; then
        if [[ -n "${PROFILE_KC_CURRENT_VERSION:-}" ]]; then
            log_info "Target version not specified, launching interactive selection..."
            if PROFILE_KC_TARGET_VERSION=$(kc_select_target_version "$PROFILE_KC_CURRENT_VERSION"); then
                export PROFILE_KC_TARGET_VERSION
                log_success "Selected target version: $PROFILE_KC_TARGET_VERSION"
            else
                log_error "Target version selection failed"
                errors=$((errors + 1))
            fi
        else
            log_error "Target Keycloak version not set (current version unknown)"
            errors=$((errors + 1))
        fi
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Profile validation failed: $errors errors"
        exit 1
    fi

    log_success "Profile validated"
}

# ============================================================================
# JAVA VERSION VALIDATION
# ============================================================================

check_java_for_version() {
    local kc_version="$1"
    # Container/K8s images carry their own JDK — only validate the host JVM for standalone.
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" != "standalone" ]]; then
        return 0
    fi
    local major_version=$(echo "$kc_version" | cut -d. -f1)
    local required_java="${JAVA_REQUIREMENTS[$major_version]:-11}"

    log_info "Checking Java for Keycloak $kc_version (requires Java $required_java+)"

    # Get current Java version
    if ! command -v java &>/dev/null; then
        log_error "Java not found. Please install Java $required_java or higher."
        return 1
    fi

    local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)

    # Handle Java version format (e.g., "1.8" -> "8", "11" -> "11")
    if [[ "$java_version" == "1" ]]; then
        java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f2)
    fi

    if [[ "$java_version" -lt "$required_java" ]]; then
        log_error "Keycloak $kc_version requires Java $required_java+, but Java $java_version is installed"
        log_error "Please install Java $required_java or higher"
        if [[ -d "/usr/lib/jvm" ]]; then
            local alt
            alt=$(find /usr/lib/jvm -maxdepth 1 -name "java-${required_java}-*" -type d 2>/dev/null | head -1)
            if [[ -n "$alt" ]]; then
                log_info "Hint: set JAVA_HOME=$alt before running migration"
            fi
        fi
        return 1
    fi

    log_success "Java $java_version detected (sufficient for Keycloak $kc_version)"
    return 0
}

# ============================================================================
# DATABASE OPERATIONS (via adapter)
# ============================================================================

db_backup_keycloak() {
    local backup_file="$1"
    local description="${2:-backup}"

    log_section "Database Backup: $description"

    local db_type="${PROFILE_DB_TYPE}"
    local host="${PROFILE_DB_HOST}"
    local port="${PROFILE_DB_PORT}"
    local db_name="${PROFILE_DB_NAME}"
    local user="${PROFILE_DB_USER}"
    # The rest of the tool (kc_run_migrating_container, _mv_psql, the PG-version gate) reads
    # PROFILE_DB_PASSWORD — the backup MUST honour it too. It used to read only PGPASSWORD /
    # DB_PASSWORD, so the password arrived EMPTY and pg_dump fell back to its interactive
    # "Password:" prompt, hanging a non-interactive (--yes) migration forever.
    local pass="${PROFILE_DB_PASSWORD:-${PGPASSWORD:-${DB_PASSWORD:-}}}"
    local parallel_jobs="${PROFILE_MIGRATION_PARALLEL_JOBS:-4}"

    log_info "Database: $db_type @ $host:$port/$db_name"
    log_info "Backup file: $backup_file"
    log_info "Parallel jobs: $parallel_jobs"

    # Fail fast instead of blocking on a password prompt nobody can answer.
    if [[ "$db_type" == "postgresql" && -z "$pass" ]]; then
        log_error "Database password is not set — pg_dump would prompt interactively and hang."
        log_error "  export PROFILE_DB_PASSWORD='<db-password>'    (PGPASSWORD also accepted)"
        return 1
    fi

    # Create backup using adapter
    if db_backup "$db_type" "$host" "$port" "$db_name" "$user" "$pass" "$backup_file" "$parallel_jobs"; then
        log_success "Backup created: $backup_file"

        # Calculate size
        local size=$(du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Backup size: $size"

        # The adapter's "verification" is `pg_restore --list | grep -c "TABLE DATA"` — it proves the
        # dump's table of contents parses, and nothing more. Opt in to PROVING it restores
        # (PROFILE_VERIFY_BACKUP_RESTORE=true) before betting a production migration on it.
        if declare -F kc_backup_restore_test >/dev/null 2>&1; then
            kc_backup_restore_test "$backup_file" || {
                log_error "Refusing to migrate behind a backup that will not restore."
                return 1
            }
        fi

        return 0
    else
        log_error "Backup failed"
        return 1
    fi
}

db_restore_keycloak() {
    local backup_file="$1"
    local description="${2:-restore}"

    log_section "Database Restore: $description"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    local db_type="${PROFILE_DB_TYPE}"
    local host="${PROFILE_DB_HOST}"
    local port="${PROFILE_DB_PORT}"
    local db_name="${PROFILE_DB_NAME}"
    local user="${PROFILE_DB_USER}"
    # Same bug as db_backup_keycloak: without PROFILE_DB_PASSWORD, pg_restore would prompt for a
    # password — and this is the ROLLBACK path, so a failed hop would hang instead of restoring.
    local pass="${PROFILE_DB_PASSWORD:-${PGPASSWORD:-${DB_PASSWORD:-}}}"
    local parallel_jobs="${PROFILE_MIGRATION_PARALLEL_JOBS:-4}"

    log_info "Database: $db_type @ $host:$port/$db_name"
    log_info "Backup file: $backup_file"
    log_info "Parallel jobs: $parallel_jobs"

    if [[ "$db_type" == "postgresql" && -z "$pass" ]]; then
        log_error "Database password is not set — pg_restore would prompt interactively and hang."
        log_error "  export PROFILE_DB_PASSWORD='<db-password>'    (PGPASSWORD also accepted)"
        return 1
    fi

    # Restore using adapter
    if db_restore "$db_type" "$host" "$port" "$db_name" "$user" "$pass" "$backup_file" "$parallel_jobs"; then
        log_success "Restore completed from: $backup_file"
        return 0
    else
        log_error "Restore failed"
        return 1
    fi
}

# ============================================================================
# KEYCLOAK SERVICE OPERATIONS (via adapter)
# ============================================================================

# shellcheck disable=SC2120 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
kc_service_start() {
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"
    local version="${1:-${KC_HOP_VERSION:-${PROFILE_KC_TARGET_VERSION:-}}}"

    log_info "Starting Keycloak ($mode mode)"

    case "$mode" in
        standalone)
            kc_start "$mode" "${PROFILE_KC_SERVICE_NAME:-keycloak}"
            ;;
        docker|podman)
            kc_start "$mode" "${PROFILE_KC_CONTAINER_NAME:-keycloak}"
            ;;
        run)
            # Transient migrating container of this hop version (boots → migrates)
            kc_run_migrating_container "$version"
            ;;
        docker-compose)
            kc_start "$mode" "${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"
            ;;
        kubernetes|deckhouse)
            kc_start "$mode" \
                "${PROFILE_K8S_NAMESPACE:-keycloak}" \
                "${PROFILE_K8S_DEPLOYMENT:-keycloak}" \
                "${PROFILE_K8S_REPLICAS:-1}"
            ;;
        *)
            log_error "Unknown deployment mode: $mode"
            return 1
            ;;
    esac
}

# shellcheck disable=SC2120 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
kc_service_stop() {
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"
    local version="${1:-${KC_HOP_VERSION:-${PROFILE_KC_TARGET_VERSION:-}}}"

    log_info "Stopping Keycloak ($mode mode)"

    case "$mode" in
        standalone)
            kc_stop "$mode" "${PROFILE_KC_SERVICE_NAME:-keycloak}"
            ;;
        docker|podman)
            kc_stop "$mode" "${PROFILE_KC_CONTAINER_NAME:-keycloak}"
            ;;
        run)
            kc_run_stop_container "${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${version}}"
            ;;
        docker-compose)
            kc_stop "$mode" "${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"
            ;;
        kubernetes|deckhouse)
            kc_stop "$mode" \
                "${PROFILE_K8S_NAMESPACE:-keycloak}" \
                "${PROFILE_K8S_DEPLOYMENT:-keycloak}"
            ;;
        *)
            log_error "Unknown deployment mode: $mode"
            return 1
            ;;
    esac
}

kc_service_status() {
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"

    case "$mode" in
        standalone)
            kc_status "$mode" "${PROFILE_KC_SERVICE_NAME:-keycloak}"
            ;;
        docker|podman)
            kc_status "$mode" "${PROFILE_KC_CONTAINER_NAME:-keycloak}"
            ;;
        run)
            kc_status "$mode" "${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${KC_HOP_VERSION:-${PROFILE_KC_TARGET_VERSION:-}}}"
            ;;
        docker-compose)
            kc_status "$mode" "${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"
            ;;
        kubernetes|deckhouse)
            kc_status "$mode" "${PROFILE_K8S_NAMESPACE:-keycloak}"
            ;;
        *)
            log_error "Unknown deployment mode: $mode"
            return 1
            ;;
    esac
}

# ============================================================================
# KEYCLOAK HEALTH CHECK — DIAGNOSTIC ONLY (ADR-009)
#
# A health probe answers "is this deployment's HTTP surface reachable and configured to expose
# /health". That is a DIFFERENT question from "did the migration apply", which only the database
# can answer (L2 / MIGRATION_MODEL — ADR-005). A probe cannot un-migrate a database, and a failed
# probe must never be allowed to destroy a migration that L2 has already confirmed.
# ============================================================================

# Health outcome codes. Deliberately NOT 0/1: callers must be forced to distinguish "Keycloak is
# up but health is switched off" from "Keycloak did not answer at all".
# Plain assignments, not `readonly`: the test suite sources this file, and a second source of a
# readonly would abort the shell.
HEALTH_OK=0            # 200 — ready
HEALTH_UNCONFIRMED=1   # answered, but never became ready within the retry budget
HEALTH_NOT_SERVED=2    # 404 / not applicable — health is not exposed. Not a failure.

# kc_health_endpoint <version> — the health URL this Keycloak version actually serves.
#   KC >= 25 moved health to the MANAGEMENT interface: port 9000, path /health/ready.
#   KC 17-24 serve /health on the HTTP port (8080).
# Both only do so when KC_HEALTH_ENABLED=true. Probing :8080/health on a KC 26 is guaranteed to
# 404 — which is exactly what the old default did, on every supported hop.
kc_health_endpoint() {
    local version="${1:-}" major
    major="${version%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || major=0

    if [[ "$major" -ge 25 ]]; then
        printf 'http://localhost:9000/health/ready'
    else
        printf 'http://localhost:8080/health'
    fi
}

# health_check [version] [endpoint]
#   Returns HEALTH_OK / HEALTH_UNCONFIRMED / HEALTH_NOT_SERVED. NEVER gates a hop — see the
#   Step 7 comment in migrate_to_version. For a real post-migration acceptance test (boots the
#   target image with health enabled and exercises the Admin API), use the `verify` subcommand.
# shellcheck disable=SC2120 # optional args: callers may rely on the profile defaults
health_check() {
    local version="${1:-${PROFILE_KC_TARGET_VERSION:-}}"
    local endpoint="${2:-$(kc_health_endpoint "$version")}"
    local max_attempts="${HEALTH_CHECK_RETRIES}"
    local interval="${HEALTH_CHECK_INTERVAL}"
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"

    # In `run` mode the container is a TRANSIENT migration boot that we stop immediately after the
    # hop. There is no service to health-check, and nothing downstream depends on the answer.
    if [[ "$mode" == "run" ]]; then
        log_info "Health check skipped (run mode: transient migration container, nothing to serve)"
        return "$HEALTH_NOT_SERVED"
    fi

    log_info "Health check: $endpoint (max $max_attempts attempts, ${interval}s interval)"

    local attempt=1 code="000"
    while [[ $attempt -le $max_attempts ]]; do
        code=$(kc_health_probe "$mode" "$endpoint" \
            "${PROFILE_KC_CONTAINER_NAME:-keycloak}" \
            "${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}")

        case "$code" in
            200)
                log_success "Health check passed (HTTP 200)"
                return "$HEALTH_OK"
                ;;
            404)
                log_info "Health endpoint answered HTTP 404 — Keycloak is UP but does not expose health."
                log_info "  Keycloak serves it only with KC_HEALTH_ENABLED=true (KC>=25: port 9000)."
                log_info "  This says nothing about the migration — L2/MIGRATION_MODEL is the gate."
                return "$HEALTH_NOT_SERVED"
                ;;
        esac

        if [[ $attempt -lt $max_attempts ]]; then
            log_info "Attempt $attempt/$max_attempts: HTTP $code — retrying in ${interval}s..."
            sleep "$interval"
        fi
        ((attempt++))
    done

    log_warn "Health check did not confirm readiness after $max_attempts attempts (last: HTTP $code)"
    log_warn "  Run '$0 verify --profile <name>' for a real acceptance test against the target image."
    return "$HEALTH_UNCONFIRMED"
}

# ============================================================================
# KEYCLOAK BUILD
# ============================================================================

build_keycloak() {
    local version="$1"
    local kc_home="$2"
    local major_version=$(echo "$version" | cut -d. -f1)

    log_section "Build: Keycloak $version"

    # Check if build is needed (Quarkus-based KC >= 17)
    if [[ "$major_version" -lt 17 ]]; then
        log_info "Keycloak $version is WildFly-based, no build step needed"
        return 0
    fi

    log_info "Keycloak $version is Quarkus-based, running build..."

    # Clean build cache
    if [[ -d "$kc_home/data/tmp" ]]; then
        log_info "Cleaning build cache: $kc_home/data/tmp"
        rm -rf "$kc_home/data/tmp"
    fi

    # Build command (array — avoids splitting "kc.sh build" into a bogus single token)
    local build_cmd=("$kc_home/bin/kc.sh" build)
    local build_log="$WORK_DIR/build_${version}_$(date +%Y%m%d_%H%M%S).log"

    log_info "Running: ${build_cmd[*]}"
    log_info "Build log: $build_log"

    # Run build
    if "${build_cmd[@]}" > "$build_log" 2>&1; then
        log_success "Build completed"
    else
        log_error "Build failed (exit code: $?)"
        log_error "Check log: $build_log"

        # Show last 20 lines of build log
        log_warn "Last 20 lines of build log:"
        tail -20 "$build_log" | sed 's/^/  /'

        return 1
    fi

    # Validate build success
    if grep -q "BUILD SUCCESS\|Server configuration updated\|Updating the configuration" "$build_log"; then
        log_success "Build validation: SUCCESS markers found"
    else
        log_warn "Build validation: No success marker found in log"
        if ! _confirm "Build may have failed. Continue anyway?" "N"; then
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# MIGRATION WAIT LOGIC
# ============================================================================

wait_for_migration() {
    local version="$1"
    local timeout="${TIMEOUT_MIGRATE}"
    local start_time=$(date +%s)
    local elapsed=0
    local migration_complete=false

    log_section "Waiting for Database Migration"

    log_info "Monitoring Keycloak logs for Liquibase migration completion..."
    log_info "Timeout: ${timeout}s"

    # The transient run-mode container is named by PROFILE_KC_RUN_CONTAINER_NAME (default
    # kc-migrate-<version>) — NOT by PROFILE_KC_CONTAINER_NAME (the YAML `container_name`, used by
    # the docker/compose modes). Reading the wrong variable made kc_logs fall back to the literal
    # "keycloak", find no such container, return nothing — so the Liquibase marker was NEVER seen
    # and every run-mode migration spun until the 900s timeout. (The harness only hid this by
    # exporting both names.)
    local log_target="${PROFILE_KC_CONTAINER_NAME:-}"
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "run" ]]; then
        log_target="${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${version}}"
    fi
    log_info "Reading migration logs from: ${log_target:-<default>}"

    # Initial wait for startup
    sleep 10

    # Monitor logs
    while [[ $elapsed -lt $timeout ]]; do
        elapsed=$(($(date +%s) - start_time))

        # Fail fast if the transient container died / never existed, instead of waiting out the
        # full timeout on a container that is not running Liquibase at all.
        if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "run" ]]; then
            local cstate
            # NB: `docker inspect -f` on a MISSING container prints an empty line to stdout and
            # exits 1, so `$(... || echo missing)` yields $'\nmissing' — enumerating bad states
            # ("exited"/"dead"/"missing") silently never matched. Strip whitespace and simply
            # require "running": anything else (missing/exited/created/dead/paused) is a failure.
            # `|| true`: the script runs under `set -euo pipefail`, and a failing `cr inspect`
            # makes the whole pipeline non-zero — which would abort the run instead of reporting.
            cstate=$(cr inspect -f '{{.State.Status}}' "$log_target" 2>/dev/null | tr -d '[:space:]' || true)
            : "${cstate:=missing}"
            if [[ "$cstate" != "running" ]]; then
                log_error "Migration container '$log_target' is '${cstate}' — it is not running Liquibase."
                log_warn "Last 30 log lines:"
                kc_logs "${PROFILE_KC_DEPLOYMENT_MODE}" "false" "$log_target" 2>/dev/null \
                    | tail -30 | sed 's/^/  /' || true
                return 1
            fi
        fi

        # Check logs for migration markers
        local logs=$(kc_logs "${PROFILE_KC_DEPLOYMENT_MODE}" "false" \
            "$log_target" \
            "${PROFILE_KC_COMPOSE_FILE:-}" 2>/dev/null || echo "")

        # --- PRIMARY signal: the DATABASE itself (ADR-005 / ADR-008) ---
        # Waiting on a LOG LINE is fragile: the Liquibase wording differs between Keycloak
        # generations (KC16/WildFly vs KC24+/Quarkus) and may not even reach INFO level. On the
        # live run the container was up and had ALREADY migrated the database, yet this loop span
        # for the full 900s timeout because the expected string never appeared. MIGRATION_MODEL
        # advancing to this hop's major.minor is the FACT — poll that.
        if declare -F kc_db_model_version >/dev/null 2>&1; then
            local _dbv
            _dbv="$(kc_db_model_version || true)"
            if [[ -n "$_dbv" && "$(_kc_major_minor "$_dbv")" == "$(_kc_major_minor "$version")" ]]; then
                migration_complete=true
                MIGRATION_LOG_FILE="$WORK_DIR/kc_startup_${version}_$(date +%Y%m%d_%H%M%S).log"
                printf '%s\n' "$logs" > "$MIGRATION_LOG_FILE" 2>/dev/null || true
                log_success "Migration confirmed by the DATABASE: MIGRATION_MODEL=${_dbv} (${elapsed}s elapsed)"
                break
            fi
        fi

        # --- SECONDARY: the historical log marker (kept for setups without DB access) ---
        if echo "$logs" | grep -qi "Liquibase command 'update' was executed successfully\|Migration successful"; then
            migration_complete=true
            # Persist the startup log so skipped-index warnings can be recovered.
            MIGRATION_LOG_FILE="$WORK_DIR/kc_startup_${version}_$(date +%Y%m%d_%H%M%S).log"
            printf '%s\n' "$logs" > "$MIGRATION_LOG_FILE" 2>/dev/null || true
            log_success "Database schema migration completed (${elapsed}s elapsed)"
            break
        fi

        # Check for errors
        if echo "$logs" | grep -qi "Migration failed\|LiquibaseException\|ERROR.*migration"; then
            log_error "Migration error detected in logs"
            log_warn "Last 20 lines of log:"
            echo "$logs" | tail -20 | sed 's/^/  /'
            return 1
        fi

        # Progress indicator
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            echo -n "."
            log_info "Still waiting... ${elapsed}s elapsed (timeout: ${timeout}s)"
        fi

        sleep 5
    done

    echo "" # Newline after dots

    if ! $migration_complete; then
        log_error "Migration did not complete within timeout (${timeout}s)"
        log_warn "This may indicate:"
        log_warn "  - Large database requiring more time"
        log_warn "  - Migration stuck or failed"
        log_warn "  - Keycloak startup issues"
        # Fail-closed: do not blindly proceed. Layer 2 (MIGRATION_MODEL) would fail anyway.
        if [[ "${FORCE_MIGRATION:-false}" == "true" ]]; then
            log_warn "FORCE_MIGRATION=true — continuing despite timeout (NOT recommended)"
        else
            log_error "Aborting (set FORCE_MIGRATION=true to override)"
            return 1
        fi
    fi

    # Additional wait for Keycloak to be fully ready
    log_info "Waiting for Keycloak to be fully ready..."
    sleep 10

    return 0
}

# ============================================================================
# MIGRATION STRATEGIES
# ============================================================================

migrate_rolling_update() {
    local target_version="$1"
    local step_num="$2"
    local total_steps="$3"

    log_section "Rolling Update: Step $step_num/$total_steps → Keycloak $target_version"

    # Only for Kubernetes/Deckhouse
    if [[ ! "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
        log_error "Rolling update only supported for Kubernetes/Deckhouse deployments"
        return 1
    fi

    local namespace="${PROFILE_K8S_NAMESPACE:-keycloak}"
    local deployment="${PROFILE_K8S_DEPLOYMENT:-keycloak}"
    local replicas="${PROFILE_K8S_REPLICAS:-1}"

    # Check Java compatibility
    check_java_for_version "$target_version" || return 1

    # Step 1: Backup before migration
    if [[ "${PROFILE_MIGRATION_BACKUP:-true}" == "true" ]]; then
        local backup_file="$(kc_backup_dir)/backup_before_${target_version}_$(date +%Y%m%d_%H%M%S).dump"
        db_backup_keycloak "$backup_file" "before $target_version" || return 1
        update_state "LAST_BACKUP" "$backup_file"
    fi

    # Step 2: Pull new container image
    if [[ "${PROFILE_KC_DISTRIBUTION_MODE}" == "container" ]]; then
        handle_distribution "$target_version" || return 1
    fi

    # Step 3: Update deployment image
    local registry="${PROFILE_CONTAINER_REGISTRY:-docker.io}"
    local image="${PROFILE_CONTAINER_IMAGE:-keycloak/keycloak}"
    local full_image="${registry}/${image}:${target_version}"

    log_info "Updating deployment to image: $full_image"

    kubectl set image deployment/"$deployment" \
        keycloak="$full_image" \
        -n "$namespace" || {
        log_error "Failed to update deployment image"
        return 1
    }

    # Step 4: Wait for rollout to complete
    log_info "Waiting for rollout (max ${TIMEOUT_MIGRATE}s)..."

    if kubectl rollout status deployment/"$deployment" \
        -n "$namespace" \
        --timeout="${TIMEOUT_MIGRATE}s"; then
        log_success "Rollout completed successfully"
    else
        log_error "Rollout failed or timed out"

        # Offer rollback
        if _confirm "Rollback to previous version?" "N"; then
            log_warn "Rolling back deployment..."
            kubectl rollout undo deployment/"$deployment" -n "$namespace"
            kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout=300s
            log_warn "Rollback completed"
        fi

        return 1
    fi

    # Step 5: Verify all pods are ready
    log_info "Verifying all $replicas pods are ready..."

    local ready_pods=$(kubectl get pods -l app=keycloak -n "$namespace" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | wc -w)

    if [[ "$ready_pods" -eq "$replicas" ]]; then
        log_success "All $replicas pods are ready"
    else
        log_warn "Only $ready_pods/$replicas pods are ready"
    fi

    # Step 6: Health check on each pod
    log_info "Running health checks on all pods..."

    local pods=$(kubectl get pods -l app=keycloak -n "$namespace" -o jsonpath='{.items[*].metadata.name}')
    local pod_num=1

    for pod in $pods; do
        log_info "Health check pod $pod_num/$replicas: $pod"

        # Health check via kubectl exec
        if kubectl exec "$pod" -n "$namespace" -- \
            curl -sf --max-time 10 http://localhost:8080/health >/dev/null 2>&1; then
            log_success "Pod $pod: Health check passed"
        else
            log_error "Pod $pod: Health check failed"
            return 1
        fi

        ((pod_num++))
    done

    # Step 7: Smoke tests (if enabled)
    if [[ "${PROFILE_MIGRATION_RUN_TESTS:-true}" == "true" && "$SKIP_TESTS" == "false" ]]; then
        # Get service endpoint for smoke tests
        local service_ip=$(kubectl get svc "${PROFILE_K8S_SERVICE:-keycloak-http}" \
            -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

        if [[ -z "$service_ip" ]]; then
            service_ip=$(kubectl get svc "${PROFILE_K8S_SERVICE:-keycloak-http}" \
                -n "$namespace" -o jsonpath='{.spec.clusterIP}')
        fi

        log_info "Running smoke tests against service: $service_ip"

        # Export for smoke test script
        export KC_URL="http://${service_ip}:8080"

        run_smoke_tests "$target_version" || {
            log_error "Smoke tests failed for version $target_version"
            return 1
        }
    fi

    # Mark step as successful
    update_state "LAST_SUCCESSFUL_STEP" "$target_version"
    update_state "RESUME_SAFE" "true"

    log_success "Rolling update to $target_version completed successfully"
    return 0
}

migrate_blue_green() {
    local target_version="$1"
    local step_num="$2"
    local total_steps="$3"

    log_section "Blue-Green Deployment: Step $step_num/$total_steps → Keycloak $target_version"

    # Only for Kubernetes/Deckhouse
    if [[ ! "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
        log_error "Blue-green deployment only supported for Kubernetes/Deckhouse"
        return 1
    fi

    local namespace="${PROFILE_K8S_NAMESPACE:-keycloak}"
    local deployment="${PROFILE_K8S_DEPLOYMENT:-keycloak}"
    local service="${PROFILE_K8S_SERVICE:-keycloak-http}"
    local replicas="${PROFILE_K8S_REPLICAS:-1}"

    # Check Java compatibility
    check_java_for_version "$target_version" || return 1

    # Step 1: Backup before migration
    if [[ "${PROFILE_MIGRATION_BACKUP:-true}" == "true" ]]; then
        local backup_file="$(kc_backup_dir)/backup_before_${target_version}_$(date +%Y%m%d_%H%M%S).dump"
        db_backup_keycloak "$backup_file" "before $target_version" || return 1
        update_state "LAST_BACKUP" "$backup_file"
    fi

    # Step 2: Pull new container image
    if [[ "${PROFILE_KC_DISTRIBUTION_MODE}" == "container" ]]; then
        handle_distribution "$target_version" || return 1
    fi

    # Step 3: Rename current deployment to "blue"
    log_info "Marking current deployment as 'blue'..."

    kubectl label deployment/"$deployment" version=blue -n "$namespace" --overwrite
    kubectl patch deployment/"$deployment" -n "$namespace" -p \
        '{"spec":{"selector":{"matchLabels":{"version":"blue"}},"template":{"metadata":{"labels":{"version":"blue"}}}}}'

    # Step 4: Create "green" deployment
    local registry="${PROFILE_CONTAINER_REGISTRY:-docker.io}"
    local image="${PROFILE_CONTAINER_IMAGE:-keycloak/keycloak}"
    local full_image="${registry}/${image}:${target_version}"

    log_info "Creating 'green' deployment with image: $full_image"

    # Get current deployment YAML and modify for green
    kubectl get deployment/"$deployment" -n "$namespace" -o yaml | \
        sed "s/name: ${deployment}/name: ${deployment}-green/" | \
        sed "s/version: blue/version: green/" | \
        sed "s|image: .*keycloak.*|image: $full_image|" | \
        kubectl apply -f - || {
        log_error "Failed to create green deployment"
        return 1
    }

    # Step 5: Wait for green deployment to be ready
    log_info "Waiting for green deployment to be ready..."

    if kubectl rollout status deployment/"${deployment}-green" \
        -n "$namespace" \
        --timeout="${TIMEOUT_MIGRATE}s"; then
        log_success "Green deployment is ready"
    else
        log_error "Green deployment failed to become ready"
        kubectl delete deployment/"${deployment}-green" -n "$namespace"
        return 1
    fi

    # Step 6: Run smoke tests on green deployment
    if [[ "${PROFILE_MIGRATION_RUN_TESTS:-true}" == "true" && "$SKIP_TESTS" == "false" ]]; then
        log_info "Running smoke tests on green deployment..."

        # Get a green pod
        local green_pod=$(kubectl get pods -l app=keycloak,version=green -n "$namespace" \
            -o jsonpath='{.items[0].metadata.name}')

        if [[ -z "$green_pod" ]]; then
            log_error "No green pods found"
            return 1
        fi

        # Port-forward to green pod for testing
        kubectl port-forward "$green_pod" 18080:8080 -n "$namespace" &
        local pf_pid=$!
        sleep 5

        export KC_URL="http://localhost:18080"

        if run_smoke_tests "$target_version"; then
            log_success "Green deployment smoke tests passed"
            kill $pf_pid 2>/dev/null || true
        else
            log_error "Green deployment smoke tests failed"
            kill $pf_pid 2>/dev/null || true

            if _confirm "Delete green deployment?" "Y"; then
                kubectl delete deployment/"${deployment}-green" -n "$namespace"
            fi

            return 1
        fi
    fi

    # Step 7: Switch service to green
    log_warn "Switching traffic from blue to green..."

    kubectl patch service/"$service" -n "$namespace" -p \
        '{"spec":{"selector":{"version":"green"}}}' || {
        log_error "Failed to switch service to green"
        return 1
    }

    log_success "Traffic switched to green deployment"
    log_info "Waiting 30s for connections to drain..."
    sleep 30

    # Step 8: Delete blue deployment
    if _confirm "Delete blue deployment (old version)?" "Y"; then
        log_info "Deleting blue deployment..."
        kubectl delete deployment/"$deployment" -n "$namespace"
        log_success "Blue deployment deleted"
    else
        log_warn "Blue deployment kept for manual cleanup"
    fi

    # Step 9: Rename green to primary
    log_info "Renaming green deployment to primary..."

    kubectl get deployment/"${deployment}-green" -n "$namespace" -o yaml | \
        sed "s/name: ${deployment}-green/name: ${deployment}/" | \
        sed "s/version: green/version: blue/" | \
        kubectl apply -f -

    kubectl delete deployment/"${deployment}-green" -n "$namespace"

    # Mark step as successful
    update_state "LAST_SUCCESSFUL_STEP" "$target_version"
    update_state "RESUME_SAFE" "true"

    log_success "Blue-green deployment to $target_version completed successfully"
    return 0
}

# ============================================================================
# MIGRATION STEP EXECUTION
# ============================================================================

migrate_to_version() {
    local target_version="$1"
    local step_num="$2"
    local total_steps="$3"

    # Expose the current hop version to the service dispatch (run/podman topology).
    export KC_HOP_VERSION="$target_version"

    log_section "Migration Step $step_num/$total_steps: Keycloak $target_version"

    # Check for existing checkpoint (resume support)
    local existing_cp=""
    if [[ "${NO_RESUME:-false}" == "true" ]]; then
        log_info "--no-resume: ignoring any checkpoint from a previous attempt"
    else
        existing_cp=$(get_checkpoint "$target_version")
    fi
    if [[ -n "$existing_cp" ]]; then
        log_warn "Resuming step for $target_version from checkpoint: $existing_cp"
    fi

    # Check Java compatibility
    check_java_for_version "$target_version" || return 1

    # Step 1: Backup before migration
    if [[ "${PROFILE_MIGRATION_BACKUP:-true}" == "true" ]]; then
        if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "backup_done"; then
            local backup_file="$(kc_backup_dir)/backup_before_${target_version}_$(date +%Y%m%d_%H%M%S).dump"
            db_backup_keycloak "$backup_file" "before $target_version" || return 1
            update_state "LAST_BACKUP" "$backup_file"
            set_checkpoint "$target_version" "backup_done"
        else
            log_info "Skipping backup (already done)"
        fi
    fi

    # Step 2: Stop Keycloak
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "stopped"; then
        # shellcheck disable=SC2119 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
        kc_service_stop || return 1
        # From here until Step 5 brings it back, the user's Keycloak is DOWN because we took it
        # down. If we die in this window the interrupt handler has to put it back — see
        # _kc_on_interrupt. In `run` mode there is no such service, so the flag stays false.
        [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" != "run" ]] && _KC_SERVICE_STOPPED_BY_US="true"
        set_checkpoint "$target_version" "stopped"
    else
        log_info "Skipping stop (already done)"
    fi

    # Step 3: Download/Install new version
    local install_path="${PROFILE_KC_HOME_DIR:-${EXTRACT_DIR}/keycloak-${target_version}}"

    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "downloaded"; then
        if [[ "${PROFILE_KC_DISTRIBUTION_MODE}" != "container" ]]; then
            handle_distribution "$target_version" "$install_path" || return 1
            if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" == "standalone" ]]; then
                export KC_HOME="$install_path"
            fi
        else
            handle_distribution "$target_version" || return 1
        fi
        set_checkpoint "$target_version" "downloaded"
    else
        log_info "Skipping download (already done)"
        if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" == "standalone" && "${PROFILE_KC_DISTRIBUTION_MODE}" != "container" ]]; then
            export KC_HOME="$install_path"
        fi
    fi

    # Step 4: Build Keycloak (for Quarkus-based KC >= 17)
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "built"; then
        if [[ "${PROFILE_KC_DISTRIBUTION_MODE}" != "container" ]]; then
            build_keycloak "$target_version" "$install_path" || return 1
        fi
        set_checkpoint "$target_version" "built"
    else
        log_info "Skipping build (already done)"
    fi

    # Step 5: Start Keycloak (triggers migration)
    local _skip_start="false"
    if [[ -n "$existing_cp" ]] && should_skip_to "$existing_cp" "started"; then
        _skip_start="true"
        # A checkpoint is a CLAIM, not a fact. In run mode the transient container may have died
        # or been removed since the checkpoint was written — which is exactly what a failed
        # attempt leaves behind. Trusting it blindly meant we "skipped the start" and then waited
        # out the full timeout for logs from a container that no longer existed. Verify.
        if [[ "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "run" ]]; then
            local _cname _cstate
            _cname="${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${target_version}}"
            _cstate=$(cr inspect -f '{{.State.Status}}' "$_cname" 2>/dev/null | tr -d '[:space:]' || true)
            : "${_cstate:=missing}"
            if [[ "$_cstate" != "running" ]]; then
                log_warn "Checkpoint claims '$target_version' was started, but container '$_cname' is '${_cstate}' — starting it again."
                cr rm -f "$_cname" >/dev/null 2>&1 || true
                _skip_start="false"
            fi
        fi
    fi

    if [[ "$_skip_start" == "true" ]]; then
        log_info "Skipping start (container verified running)"
    else
        # shellcheck disable=SC2119 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
        kc_service_start || return 1
        # Keycloak is back up — the interrupt handler no longer owes anyone a restart.
        _KC_SERVICE_STOPPED_BY_US="false"
        set_checkpoint "$target_version" "started"
    fi

    # Step 6: Wait for migration to complete
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "migrated"; then
        wait_for_migration "$target_version" || return 1

        # Step 6b: AUTHORITATIVE Layer 2 gate — MIGRATION_MODEL must advance to the hop
        # version. "Container started" != "realm migration applied".
        #
        # This is the ONE place a hop can be declared failed, and therefore the ONE place a
        # rollback may be offered. The database itself says whether the migration applied.
        if declare -F kc_verify_migration_model >/dev/null 2>&1; then
            kc_verify_migration_model "$target_version" || {
                log_error "MIGRATION_MODEL did not advance to $target_version — Layer 2 NOT confirmed"
                log_error "The hop did NOT apply. The database is where it was before this hop began."
                _kc_offer_rollback "$target_version"
                return 1
            }
        else
            log_warn "kc_verify_migration_model unavailable — Layer 2 not independently confirmed"
        fi

        # Step 6c: AUTHORITATIVE Layer 3 gate — the DATA must have survived the hop.
        #
        # L2 says the migration ran. It does not say your realms are still there. A hop that
        # emptied user_entity would pass every check above it and report complete success. Four
        # COUNT(*) queries close that hole: realm and user_entity must be unchanged, client and
        # keycloak_role may only grow (migrations add default clients/roles, never remove yours).
        if declare -F kc_data_verify >/dev/null 2>&1; then
            kc_data_verify "$target_version" || {
                _kc_offer_rollback "$target_version"
                return 1
            }
        fi

        # Step 6d: surface (and optionally apply) indexes skipped on large tables (>300k rows)
        if declare -F kc_check_skipped_indexes >/dev/null 2>&1 && [[ -n "${MIGRATION_LOG_FILE:-}" ]]; then
            kc_check_skipped_indexes "$MIGRATION_LOG_FILE" "$target_version" || true
        fi

        set_checkpoint "$target_version" "migrated"
    else
        log_info "Skipping migration wait (already migrated)"
    fi

    # Step 7: Health check — DIAGNOSTIC ONLY, never a gate (ADR-009).
    #
    # L2 (Step 6b) has already confirmed this hop against the DATABASE: MIGRATION_MODEL says the
    # realm migration ran. Whether an HTTP probe can reach /health is a fact about the deployment's
    # configuration, not about the migration.
    #
    # This block used to roll back on a failed probe. Since KC 24+ serves /health only with
    # KC_HEALTH_ENABLED=true — and KC>=25 moved it to port 9000 — the default probe 404'd on
    # EVERY supported hop. And _confirm auto-answers its default under --yes or any non-TTY
    # (CI, cron, pipe), where the default was "Y". So a 404 silently restored a backup over a
    # migration that had just SUCCEEDED. In `run` mode this was papered over with an early return;
    # the other five deployment modes carried the live defect.
    #
    # A failed probe now produces a warning and nothing else. `verify` is the real acceptance test.
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "health_ok"; then
        # shellcheck disable=SC2119 # optional args: version comes from the profile
        health_check "$target_version" || true
        set_checkpoint "$target_version" "health_ok"
    else
        log_info "Skipping health check (already passed)"
    fi

    # Step 8: Smoke tests (if enabled)
    if [[ "${PROFILE_MIGRATION_RUN_TESTS:-true}" == "true" && "$SKIP_TESTS" == "false" ]]; then
        if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "tests_ok"; then
            run_smoke_tests "$target_version" || {
                log_error "Smoke tests failed for version $target_version"
                return 1
            }
            set_checkpoint "$target_version" "tests_ok"
        else
            log_info "Skipping smoke tests (already passed)"
        fi
    fi

    # run topology: the transient migrating container has done its job — stop+remove it
    # before the next hop boots (single-instance migration; avoids DB lock contention).
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" == "run" ]] && declare -F kc_run_stop_container >/dev/null 2>&1; then
        kc_run_stop_container "${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${target_version}}" || true
    fi

    # Mark step as fully successful
    update_state "LAST_SUCCESSFUL_STEP" "$target_version"
    update_state "RESUME_SAFE" "true"

    log_success "Migration to $target_version completed successfully"
    return 0
}

run_smoke_tests() {
    local version="$1"

    log_section "Smoke Tests: Keycloak $version"

    local smoke_script="$SCRIPT_DIR/smoke_test.sh"

    if [[ ! -x "$smoke_script" ]]; then
        log_warn "Smoke test script not found or not executable: $smoke_script"
        return 0
    fi

    if "$smoke_script"; then
        log_success "Smoke tests passed for Keycloak $version"
        return 0
    else
        log_error "Smoke tests failed for Keycloak $version"

        if _confirm "Continue migration despite test failures?" "N"; then
            log_warn "Continuing migration (tests failed)"
            return 0
        else
            log_error "Migration aborted due to test failures"
            return 1
        fi
    fi
}

# ============================================================================
# MAIN MIGRATION WORKFLOW
# ============================================================================

execute_migration() {
    log_section "Starting Keycloak Migration v$VERSION"

    local current_version="${PROFILE_KC_CURRENT_VERSION}"
    local target_version="${PROFILE_KC_TARGET_VERSION}"

    log_info "Migration path: $current_version → $target_version"
    log_info "Deployment mode: ${PROFILE_KC_DEPLOYMENT_MODE}"
    log_info "Database: ${PROFILE_DB_TYPE} @ ${PROFILE_DB_HOST}:${PROFILE_DB_PORT}"
    log_info "Strategy: ${PROFILE_MIGRATION_STRATEGY:-inplace}"
    echo ""

    # Determine migration path (hops to boot; current is the start, never re-booted)
    local target_major
    target_major=$(echo "$target_version" | cut -d. -f1)

    if ! check_db_version_for_target "$target_major"; then
        exit 1
    fi

    # Single-instance guard: a leftover migration process from a previous attempt would remove the
    # kc-migrate-<version> container that THIS run creates (same name), killing a healthy migration.
    # A dry run takes no lock — it changes nothing and must never block a real migration.
    if [[ "${DRY_RUN:-false}" != "true" ]] && ! _kc_acquire_lock; then
        return 1
    fi

    # ADR-008: reconcile with REALITY before deciding anything. This may replace the profile's
    # claimed current_version with the version the database is actually at, so that already-applied
    # hops are skipped (kc_build_migration_path drops hops <= current) and a stale Liquibase lock or
    # leftover container is caught here instead of hanging the run later.
    local _rec_rc=0
    kc_reconcile_state "$target_major" || _rec_rc=$?
    case "$_rec_rc" in
        0) ;;
        2) log_success "Nothing to migrate — the database is already at the target."; return 0 ;;
        *) log_error "State reconciliation failed — aborting"; return 1 ;;
    esac
    current_version="${PROFILE_KC_CURRENT_VERSION}"
    log_info "Effective path (from ACTUAL db state): $current_version → $target_version"

    local migration_steps=()
    local _path
    if ! _path=$(kc_build_migration_path "$current_version" "$target_major"); then
        log_error "No migration path from $current_version to target major $target_major"
        exit 1
    fi
    read -r -a migration_steps <<< "$_path"

    if [[ ${#migration_steps[@]} -eq 0 ]]; then
        log_error "No migration path found from $current_version to $target_version"
        exit 1
    fi

    log_info "Migration will proceed through ${#migration_steps[@]} steps:"
    for step_version in "${migration_steps[@]}"; do
        echo "  → $step_version"
    done
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN mode - no actual changes will be made"
        return 0
    fi

    # v3.5: Run preflight checks before migration
    if declare -F run_all_preflight_checks >/dev/null 2>&1; then
        log_section "Preflight Checks (Production Safety v3.5)"

        # Determine backup directory
        local backup_dir="$(kc_backup_dir)"
        mkdir -p "$backup_dir"

        # One backup is taken before EACH hop and they all stay on disk. The space check has to know
        # how many there will be — sizing for one and then writing three is how a large migration
        # fills the disk halfway through.
        export PREFLIGHT_HOP_COUNT="${#migration_steps[@]}"

        # Get Keycloak URL if available
        local kc_url=""
        if [[ -n "${PROFILE_KC_URL:-}" ]]; then
            kc_url="$PROFILE_KC_URL"
        fi

        # Run all preflight checks
        if ! run_all_preflight_checks \
            "${PROFILE_FILE:-$WORK_DIR/profile.yaml}" \
            "$PROFILE_DB_TYPE" \
            "$PROFILE_DB_HOST" \
            "$PROFILE_DB_PORT" \
            "$PROFILE_DB_USER" \
            "$PROFILE_DB_PASSWORD" \
            "$PROFILE_DB_NAME" \
            "$backup_dir" \
            "$kc_url" \
            "${PROFILE_KC_ADMIN_USER:-admin}" \
            "${PROFILE_KC_ADMIN_PASSWORD:-}"; then

            log_error "Preflight checks FAILED — Cannot proceed with migration"
            log_error "Fix the issues above and retry"
            exit 1
        fi

        log_success "Preflight checks PASSED — Migration can proceed"
        echo ""
    else
        log_warn "Preflight checks not available (upgrade to v3.5 for production safety)"
    fi

    # v3.6 security scan = STATIC ANALYSIS OF THIS TOOL'S OWN SOURCE (ShellCheck + gitleaks over
    # scripts/). It says NOTHING about the user's database or environment, takes ~20s and floods
    # the migration log — so as of v3.9.1 it is OPT-IN: --security-scan / ENABLE_SECURITY_SCAN=true.
    if [[ "${ENABLE_SECURITY_SCAN:-false}" == "true" ]] &&
       declare -F run_comprehensive_security_scan >/dev/null 2>&1; then
        log_section "Security Scan (v3.6 Security Hardening)"

        # Run comprehensive security scan (ShellCheck, gitleaks, hardcoded secrets)
        # fail_on_critical=false to not block migration on warnings
        if ! run_comprehensive_security_scan "$SCRIPT_DIR/.." "false"; then
            log_warn "Security scan found issues (non-blocking)"
            log_warn "Review security scan output above"
        else
            log_success "Security scan PASSED"
        fi

        echo ""
    fi

    # Airgap: validate all artifacts available before starting
    if [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
        dist_validate_airgap "${migration_steps[@]}" || {
            log_error "Airgap validation failed — cannot proceed without required artifacts"
            exit 1
        }
    fi

    # Main confirmation gate (v3.9, fail-closed non-interactive policy):
    #   --yes / ASSUME_DEFAULTS -> proceed; no TTY and no flag -> refuse (never migrate a
    #   real DB silently); otherwise prompt interactively as before.
    if [[ "${AUTO_CONFIRM:-false}" == "true" || "${ASSUME_DEFAULTS:-false}" == "true" ]]; then
        log_info "Proceeding with migration (non-interactive: --yes/ASSUME_DEFAULTS)"
    elif [[ ! -t 0 ]]; then
        log_error "Refusing to proceed non-interactively without --yes (fail-closed)"
        audit_info "migration_cancelled" "Refused: non-interactive without --yes"
        exit 1
    else
        read -r -p "Proceed with migration? [y/N]: " proceed
        if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
            log_info "Migration cancelled by user"
            audit_info "migration_cancelled" "User cancelled migration"
            exit 0
        fi
    fi

    # Audit: migration start
    local migration_start_ts
    migration_start_ts=$(date +%s)
    # audit_migration_start(source, target, profile) — pass version transition + profile
    audit_migration_start "$current_version" "$target_version" "${PROFILE_NAME:-unknown}"

    # Layer 3 baseline — taken ONCE, here, while the database is still untouched.
    #
    # Every hop is then compared against the state we STARTED from, not against the state left by
    # the hop before it. Re-baselining per hop would forgive cumulative loss: hop 2 could delete
    # what hop 1 left and still "match its baseline".
    if declare -F kc_data_baseline >/dev/null 2>&1; then
        kc_data_baseline
    fi

    # Execute migration steps (strategy-dependent)
    local step_num=1
    local total_steps=${#migration_steps[@]}
    local strategy="${PROFILE_MIGRATION_STRATEGY:-inplace}"

    for step_version in "${migration_steps[@]}"; do
        # Select migration function based on strategy
        case "$strategy" in
            rolling_update)
                if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
                    migrate_rolling_update "$step_version" "$step_num" "$total_steps" || {
                        log_error "Rolling update failed at step $step_num (Keycloak $step_version)"
                        audit_migration_step "$step_version" "failed"
                        audit_migration_end "${PROFILE_NAME:-unknown}" "failed" "$(($(date +%s) - migration_start_ts))"
                        log_info "You can resume migration later with: $0 migrate --profile $PROFILE_NAME"
                        exit 1
                    }
                else
                    log_warn "Rolling update not supported for ${PROFILE_KC_DEPLOYMENT_MODE}, using in-place migration"
                    migrate_to_version "$step_version" "$step_num" "$total_steps" || {
                        log_error "Migration failed at step $step_num (Keycloak $step_version)"
                        exit 1
                    }
                fi
                ;;

            blue_green)
                if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
                    migrate_blue_green "$step_version" "$step_num" "$total_steps" || {
                        log_error "Blue-green deployment failed at step $step_num (Keycloak $step_version)"
                        log_info "You can resume migration later with: $0 migrate --profile $PROFILE_NAME"
                        exit 1
                    }
                else
                    log_warn "Blue-green deployment not supported for ${PROFILE_KC_DEPLOYMENT_MODE}, using in-place migration"
                    migrate_to_version "$step_version" "$step_num" "$total_steps" || {
                        log_error "Migration failed at step $step_num (Keycloak $step_version)"
                        exit 1
                    }
                fi
                ;;

            inplace|*)
                migrate_to_version "$step_version" "$step_num" "$total_steps" || {
                    log_error "Migration failed at step $step_num (Keycloak $step_version)"
                    log_info "You can resume migration later with: $0 migrate --profile $PROFILE_NAME"
                    exit 1
                }
                ;;
        esac

        # Update overall progress
        if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
            local progress=$(awk "BEGIN {printf \"%.2f\", $step_num / $total_steps}")
            prom_set_progress "$progress" "in_progress"
        fi

        step_num=$((step_num + 1))
    done

    # Set progress to 100%
    if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
        prom_set_progress 1.0 "completed"
        local duration=$(($(date +%s) - migration_start_ts))
        prom_set_duration "$duration"
        prom_set_success_timestamp
    fi

    log_section "Migration Complete!"
    log_success "Keycloak successfully migrated from $current_version to $target_version"

    # Run database-specific optimizations
    if [[ -f "$LIB_DIR/db_optimizations.sh" ]]; then
        source "$LIB_DIR/db_optimizations.sh"
        db_run_optimizations 2>/dev/null || log_warn "Post-migration optimizations skipped"
    fi

    # v3.5: Run backup rotation policy
    if declare -F auto_rotate_backups >/dev/null 2>&1; then
        log_section "Backup Rotation (Production Safety v3.5)"

        local backup_dir="$(kc_backup_dir)"

        # Use rotation policy from profile or default
        local rotation_policy="${PROFILE_BACKUP_ROTATION_POLICY:-keep_last_n}"
        local keep_count="${PROFILE_BACKUP_KEEP_COUNT:-5}"
        local max_age_days="${PROFILE_BACKUP_MAX_AGE_DAYS:-30}"
        local max_size_gb="${PROFILE_BACKUP_MAX_SIZE_GB:-100}"

        auto_rotate_backups "$backup_dir" "$rotation_policy" "$keep_count" "$max_age_days" "$max_size_gb"
        echo ""
    fi

    # Audit: migration end
    local migration_end_ts
    migration_end_ts=$(date +%s)
    local total_duration=$((migration_end_ts - migration_start_ts))
    audit_migration_end "${PROFILE_NAME:-unknown}" "success" "$total_duration"

    # Clean up state file
    update_state "RESUME_SAFE" "false"
}

# ============================================================================
# COMMAND: PLAN
# ============================================================================

cmd_plan() {
    local profile="${1:-}"

    load_profile_or_discover "$profile"

    log_section "Migration Plan"

    local current_version="${PROFILE_KC_CURRENT_VERSION}"
    local target_version="${PROFILE_KC_TARGET_VERSION}"

    echo "Current Version:  $current_version"
    echo "Target Version:   $target_version"
    echo ""
    echo "Migration Path:"

    echo "  ✓ $current_version (current)"
    local _tmajor _phop
    _tmajor=$(echo "$target_version" | cut -d. -f1)
    for _phop in $(kc_build_migration_path "$current_version" "$_tmajor" 2>/dev/null); do
        if [[ "$_phop" == "$target_version" ]]; then
            echo "  ✓ $_phop (target)"
        else
            echo "  → $_phop"
        fi
    done

    echo ""
    echo "Environment:"
    echo "  Deployment:  ${PROFILE_KC_DEPLOYMENT_MODE}"
    echo "  Database:    ${PROFILE_DB_TYPE} @ ${PROFILE_DB_HOST}:${PROFILE_DB_PORT}"
    echo "  Strategy:    ${PROFILE_MIGRATION_STRATEGY:-inplace}"
    echo ""
}

# ============================================================================
# MULTI-INSTANCE MIGRATION HANDLERS
# ============================================================================

mt_execute_multi_tenant() {
    # Execute multi-tenant migration from profile
    log_info "Processing multi-tenant migration profile..."

    # Parse rollout strategy
    local rollout_type="${PROFILE_ROLLOUT_TYPE:-parallel}"
    # shellcheck disable=SC2034  # max_concurrent reserved for rollout concurrency control
    local max_concurrent="${PROFILE_ROLLOUT_MAX_CONCURRENT:-3}"

    # Count tenants
    local tenant_count
    tenant_count=$(yq eval '.tenants | length' "$PROFILE_FILE" 2>/dev/null || echo "0")

    if [[ "$tenant_count" -eq 0 ]]; then
        log_error "No tenants defined in profile"
        return 1
    fi

    log_info "Found $tenant_count tenants, rollout: $rollout_type"

    # Execute based on rollout type
    if [[ "$rollout_type" == "parallel" ]]; then
        mt_execute_parallel "tenant" "$tenant_count" "$PROFILE_FILE"
    elif [[ "$rollout_type" == "sequential" ]]; then
        mt_execute_sequential "tenant" "$tenant_count" "$PROFILE_FILE"
    else
        log_error "Unknown rollout type: $rollout_type"
        return 1
    fi
}

mt_execute_clustered() {
    # Execute clustered deployment migration from profile
    log_info "Processing clustered deployment migration profile..."

    # Parse rollout strategy
    local rollout_type="${PROFILE_ROLLOUT_TYPE:-sequential}"  # Default: rolling update

    # Count nodes
    local node_count
    node_count=$(yq eval '.cluster.nodes | length' "$PROFILE_FILE" 2>/dev/null || echo "0")

    if [[ "$node_count" -eq 0 ]]; then
        log_error "No cluster nodes defined in profile"
        return 1
    fi

    log_info "Found $node_count cluster nodes, rollout: $rollout_type"

    # Load balancer integration (drain/enable)
    local lb_type="${PROFILE_LB_TYPE:-}"
    if [[ -n "$lb_type" ]]; then
        log_info "Load balancer integration: $lb_type"
        export CLUSTER_LB_TYPE="$lb_type"
        export CLUSTER_LB_HOST="${PROFILE_LB_HOST:-}"
        export CLUSTER_LB_ADMIN_SOCKET="${PROFILE_LB_ADMIN_SOCKET:-}"
        export CLUSTER_LB_BACKEND="${PROFILE_LB_BACKEND:-keycloak_backend}"
    fi

    # Execute based on rollout type
    if [[ "$rollout_type" == "parallel" ]]; then
        log_warn "Parallel rollout for clustered deployment may cause downtime"
        if ! _confirm "Continue with parallel migration?" "N"; then
            log_info "Migration cancelled"
            return 1
        fi
        mt_execute_parallel "node" "$node_count" "$PROFILE_FILE"
    else
        # Sequential (rolling update) - recommended
        mt_execute_sequential "node" "$node_count" "$PROFILE_FILE"
    fi
}

# ============================================================================
# COMMAND: MIGRATE
# ============================================================================

cmd_migrate() {
    local profile="${1:-}"

    # Initialize workspace
    mkdir -p "$WORK_DIR"

    # Start monitoring if enabled
    if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
        local monitor_port="${MONITORING_PORT:-9090}"
        log_info "Starting Prometheus exporter on port $monitor_port..."
        prom_start_exporter "$monitor_port"
        prom_set_progress 0.0 "starting"
    fi

    # Check for resume
    if ! check_resume; then
        load_profile_or_discover "$profile"
    fi

    # Detect migration mode (standard, multi-tenant, clustered, blue_green, canary)
    local migration_mode="${PROFILE_MODE:-standard}"

    if [[ "$migration_mode" == "multi-tenant" ]]; then
        log_section "Multi-Tenant Migration Mode"
        mt_execute_multi_tenant
        return $?
    elif [[ "$migration_mode" == "clustered" ]]; then
        log_section "Clustered Deployment Migration Mode"
        mt_execute_clustered
        return $?
    elif [[ "$migration_mode" == "blue_green" ]]; then
        log_section "Blue-Green Migration Mode"
        source "$LIB_DIR/blue_green.sh"
        bluegreen_execute_migration
        return $?
    elif [[ "$migration_mode" == "canary" ]]; then
        log_section "Canary Migration Mode"
        source "$LIB_DIR/canary.sh"
        canary_execute_migration
        return $?
    fi

    # Standard single-instance migration
    # Pre-flight checks (skip with --skip-preflight)
    if [[ "${SKIP_PREFLIGHT:-false}" != "true" ]]; then
        run_preflight_checks || exit 1
    fi

    # Execute migration
    execute_migration
}

# ============================================================================
# COMMAND: ROLLBACK
# ============================================================================

find_latest_backup() {
    # Auto-discover latest backup from WORK_DIR if state file is missing/corrupted
    local backup="${LAST_BACKUP:-}"

    if [[ -n "$backup" && -f "$backup" ]]; then
        echo "$backup"
        return 0
    fi

    # Fallback: search workspace for most recent .dump file
    log_warn "State file backup reference missing, searching workspace..."
    backup=$(find "$WORK_DIR" -name "backup_before_*.dump" -type f 2>/dev/null | sort -r | head -1)

    if [[ -n "$backup" ]]; then
        log_info "Found backup: $backup"
        echo "$backup"
        return 0
    fi

    return 1
}

# ============================================================================
# COMMAND: VERIFY — acceptance test of the migrated database against the TARGET image
# ============================================================================

# cmd_verify [version]
#   The migration leaves no running Keycloak: the transient container is removed after the last hop
#   (single-instance; it must not fight the next one for the Liquibase lock). So "is the result any
#   good" had no answer — you were left with a database and no way to exercise it.
#
#   This boots the SAME sovereign image that performed the migration against the migrated database,
#   with health enabled, exercises it, and removes the container again. Verifying against a stock
#   Keycloak of the same version would test a different artifact than the one you are about to run.
cmd_verify() {
    local version="${1:-${PROFILE_KC_TARGET_VERSION:-}}"

    if [[ -z "$version" ]]; then
        log_error "verify: no target version (pass one, or use --profile)"
        return 1
    fi

    log_section "Verify: Keycloak $version"

    # L2 first, and from the host: if the database does not claim this version, booting a container
    # to ask it the same question is a waste of two minutes.
    if declare -F kc_verify_migration_model >/dev/null 2>&1; then
        kc_verify_migration_model "$version" || {
            log_error "The database is NOT at $version — nothing to verify."
            return 1
        }
    fi

    # L3: the data. Free, needs no container and no admin credentials.
    if declare -F kc_data_verify >/dev/null 2>&1; then
        kc_data_verify "$version" || return 1
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "DRY-RUN: would boot kc-verify-${version}, probe health, run smoke tests, remove it"
        return 0
    fi

    local cname="kc-verify-${version}"
    kc_run_verify_container "$version" "$cname" || return 1

    # Whatever happens below, the container does not outlive this function.
    local rc=0
    # shellcheck disable=SC2064 # expand $cname now: it is what we must clean up
    trap "kc_run_stop_container '$cname' 2>/dev/null || true" RETURN

    # Readiness. Unlike the migrating boot, this container HAS health enabled, so a failure here
    # means something — it is not the ADR-009 false alarm.
    local endpoint attempt=1 code="000"
    endpoint="$(kc_health_endpoint "$version")"
    log_info "Waiting for readiness: $endpoint"

    while [[ $attempt -le ${VERIFY_READY_RETRIES:-60} ]]; do
        code=$(kc_health_probe "run" "$endpoint" "$cname")
        [[ "$code" == "200" ]] && break
        sleep "${VERIFY_READY_INTERVAL:-5}"
        ((attempt++))
    done

    if [[ "$code" != "200" ]]; then
        log_error "Keycloak $version did not become ready (last: HTTP $code). Container logs:"
        cr logs "$cname" 2>&1 | tail -40 | sed 's/^/  /' || true
        return 1
    fi
    log_success "Keycloak $version is READY (HTTP 200 on ${endpoint##*/})"

    # Admin API. This needs the realm's admin credentials, which the tool does not know and cannot
    # derive — KC_BOOTSTRAP_ADMIN_* only creates an admin on a database that has none, and a
    # migrated database has plenty. Without them, say what was NOT checked rather than implying it
    # passed.
    local admin_user="${PROFILE_KC_ADMIN_USER:-}"
    local admin_pass="${PROFILE_KC_ADMIN_PASSWORD:-}"

    if [[ -z "$admin_user" || -z "$admin_pass" ]]; then
        log_warn "No admin credentials — skipping the Admin API smoke tests."
        log_warn "  Verified: L2 (MIGRATION_MODEL), L3 (data integrity), and readiness."
        log_warn "  NOT verified: realms/clients/users over the Admin API, token issuance."
        log_warn "  Set PROFILE_KC_ADMIN_USER / PROFILE_KC_ADMIN_PASSWORD to include them."
        log_success "Verify PASSED (without Admin API coverage)"
        return 0
    fi

    local smoke="$SCRIPT_DIR/smoke_test.sh"
    if [[ ! -x "$smoke" ]]; then
        log_warn "smoke_test.sh not executable — skipping Admin API tests"
        return 0
    fi

    local base="http://localhost:${VERIFY_HTTP_PORT:-8080}"
    log_info "Running Admin API smoke tests against $base"
    if KC_URL="$base" ADMIN_USER="$admin_user" ADMIN_PASS="$admin_pass" "$smoke"; then
        log_success "Verify PASSED: $version is migrated, ready, and serving the Admin API"
    else
        log_error "Admin API smoke tests FAILED against $version"
        rc=1
    fi

    return "$rc"
}

# _kc_offer_rollback <version>
#   The ONLY path by which a failed hop may restore the database. Reached solely from the L2 gate
#   (Step 6b), i.e. only when the database itself says the migration did not apply.
#
#   The default is NO, deliberately. _confirm auto-answers its DEFAULT under --yes, under
#   ASSUME_DEFAULTS, and in any non-TTY (CI, cron, pipe) — and migrate_oneshot always passes
#   --yes. A "Y" default here therefore means: restore a database, unattended, without anyone
#   seeing the question. Restoring a database is not something to do by accident.
_kc_offer_rollback() {
    local version="$1"

    if [[ "${AUTO_ROLLBACK:-false}" == "true" ]]; then
        log_warn "AUTO_ROLLBACK=true — restoring the pre-${version} backup"
        cmd_rollback_auto
        return
    fi

    if _confirm "Restore the pre-${version} backup?" "N"; then
        cmd_rollback_auto
    else
        log_warn "Not rolling back. The pre-${version} backup is kept in ${WORK_DIR}."
        log_warn "  Restore it later with: $0 rollback --profile <name>"
    fi
}

cmd_rollback_auto() {
    # Non-interactive rollback (called from auto-rollback or --force)
    log_section "Auto-Rollback"

    load_state

    local last_backup
    last_backup=$(find_latest_backup) || {
        log_error "No backup found for rollback"
        return 1
    }

    log_warn "Restoring from: $last_backup"

    # The backup is named backup_before_<version>_<timestamp>.dump — the version it names is the
    # hop this restore undoes, and therefore the hop whose checkpoints must not survive it.
    local undone_version=""
    undone_version=$(basename "$last_backup" | sed -n 's/^backup_before_\(.*\)_[0-9]\{8\}_[0-9]\{6\}\.dump$/\1/p')

    # Safety backup before rollback
    local safety_backup="$WORK_DIR/safety_before_rollback_$(date +%Y%m%d_%H%M%S).dump"
    db_backup_keycloak "$safety_backup" "safety backup before rollback" || true

    # Stop → Restore → Start
    # shellcheck disable=SC2119 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
    kc_service_stop || true
    db_restore_keycloak "$last_backup" "rollback" || {
        log_error "Rollback restore failed!"
        return 1
    }
    # shellcheck disable=SC2119 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
    kc_service_start || true

    # The database is now BEFORE this hop. Any checkpoint claiming the hop was reached is a lie,
    # and a resume that believed it would skip straight past the migration it needs to redo.
    if [[ -n "$undone_version" ]]; then
        clear_checkpoint "$undone_version"
        update_state "RESUME_SAFE" "false"
    else
        log_warn "Could not derive the hop version from '$(basename "$last_backup")' — checkpoints"
        log_warn "  were NOT cleared. Re-run with --no-resume to avoid trusting stale state."
    fi

    log_success "Auto-rollback completed from: $last_backup"
    return 0
}

cmd_rollback() {
    log_section "Rollback"

    load_state

    local last_backup
    last_backup=$(find_latest_backup) || {
        log_error "No backup found to rollback to"
        log_info "Checked state file and workspace: $WORK_DIR"
        exit 1
    }

    log_warn "This will restore database from: $last_backup"

    if [[ "${ROLLBACK_FORCE:-false}" == "true" ]]; then
        log_warn "Force mode: skipping confirmation"
    elif ! _confirm "Proceed with rollback?" "N"; then
        log_info "Rollback cancelled"
        exit 0
    fi

    cmd_rollback_auto
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    cat << EOF
Keycloak Migration Script v$VERSION
Universal migration tool for all environments

USAGE:
    $0 <command> [options]

COMMANDS:
    plan                    Show migration plan without executing
    migrate                 Execute migration
    verify                  Acceptance-test the migrated database: boots the TARGET image against
                            it with health enabled, checks L2 + data integrity + readiness, runs the
                            Admin API smoke tests (needs PROFILE_KC_ADMIN_USER/PASSWORD), removes
                            the container. This is what to run after a migration completes.
    rollback                Rollback to last backup

OPTIONS:
    --profile <name>        Use specified profile from profiles/ directory
    --dry-run               Show what would be done without executing
    --skip-tests            Skip smoke tests after each migration step
    --yes, -y               Assume "yes" for confirmation prompts (non-interactive)
    --security-scan         Run ShellCheck/gitleaks over THIS TOOL's own source (off by default;
                            it analyses the tool, not your database)
    --no-resume             Ignore checkpoints from a previous (failed) attempt and redo each step
    --force-unlock          Release a stale Liquibase changelog lock left by a crashed migration
    --kill-stale            Terminate competing/hung migration processes instead of refusing to run
    --apply-indexes         Create the indexes Keycloak SKIPS on tables above ~300k rows (it logs
                            the DDL instead of blocking the boot, so the migration succeeds with
                            indexes missing). Applied CONCURRENTLY, so no table is locked.
    --monitor               Enable live migration monitor (if available)
    -h, --help              Show this help message

EXAMPLES:
    # Auto-discover and migrate
    $0 migrate

    # Use specific profile
    $0 migrate --profile kubernetes-cluster-production

    # Show migration plan
    $0 plan --profile standalone-postgresql

    # Dry run
    $0 migrate --profile docker-compose-dev --dry-run

    # Skip smoke tests
    $0 migrate --profile standalone-mysql --skip-tests

    # Non-interactive (CI/automation): assume yes, no prompts
    $0 migrate --profile standalone-postgresql --yes

PROFILES:
    Profiles are YAML files in the profiles/ directory.
    Create a profile using: ./scripts/config_wizard.sh

    Standard Examples:
    - standalone-postgresql.yaml
    - kubernetes-cluster-production.yaml
    - docker-compose-dev.yaml

    Advanced Strategies (v3.3):
    - blue-green-k8s-istio.yaml        # Zero-downtime deployment
    - canary-k8s-istio.yaml             # Progressive rollout (10% → 50% → 100%)

    Multi-Instance (v3.2):
    - multi-tenant-example.yaml         # Multiple isolated instances
    - clustered-bare-metal-example.yaml # HA cluster with load balancer

ENVIRONMENT VARIABLES:
    PGPASSWORD              PostgreSQL password (if using PostgreSQL)
    DB_PASSWORD             Database password (generic)
    WORK_DIR                Workspace directory (default: ./migration_workspace).
                            Preflight checks FREE SPACE on this path's filesystem.
    MIN_DISK_GB             Preflight free-space threshold on WORK_DIR's fs (default: 15).
                            Space is for pre-hop DB dumps, not for container images.
    ASSUME_DEFAULTS         If "true": run non-interactively with safe defaults (like --yes)

EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Installed here (not at source time) so sourcing the script for tests/wrappers is inert.
    trap _kc_on_interrupt INT TERM
    trap _kc_release_lock EXIT

    local command="${1:-}"
    shift || true

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                PROFILE_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --skip-preflight)
                SKIP_PREFLIGHT=true
                shift
                ;;
            --airgap)
                export AIRGAP_MODE=true
                shift
                ;;
            --auto-rollback)
                AUTO_ROLLBACK=true
                shift
                ;;
            --force)
                ROLLBACK_FORCE=true
                shift
                ;;
            --monitor)
                ENABLE_MONITOR=true
                shift
                ;;
            --yes|-y)
                AUTO_CONFIRM=true
                shift
                ;;
            --security-scan)
                ENABLE_SECURITY_SCAN=true
                shift
                ;;
            --no-resume)
                NO_RESUME=true
                shift
                ;;
            --force-unlock)
                FORCE_UNLOCK=true
                shift
                ;;
            --kill-stale)
                KILL_STALE=true
                shift
                ;;
            --apply-indexes)
                # Keycloak skips CREATE INDEX on tables above ~300k rows and only logs the DDL. The
                # migration then reports success with indexes missing. This creates them (CONCURRENTLY,
                # so it does not lock the table) after each hop.
                export PROFILE_APPLY_SKIPPED_INDEXES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done

    case "$command" in
        plan)
            cmd_plan "$PROFILE_NAME"
            ;;
        migrate)
            cmd_migrate "$PROFILE_NAME"
            ;;
        rollback)
            cmd_rollback
            ;;
        verify)
            cmd_verify
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown command: $command"
            echo ""
            usage
            exit 1
            ;;
    esac
}

# Run main only when executed directly (allows sourcing functions for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
