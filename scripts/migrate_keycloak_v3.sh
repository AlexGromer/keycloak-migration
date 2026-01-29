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
VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source libraries
source "$LIB_DIR/database_adapter.sh"
source "$LIB_DIR/deployment_adapter.sh"
source "$LIB_DIR/profile_manager.sh"
source "$LIB_DIR/keycloak_discovery.sh"
source "$LIB_DIR/distribution_handler.sh"
source "$LIB_DIR/audit_logger.sh"

# ============================================================================
# CONFIGURATION DEFAULTS
# ============================================================================

# Workspace
WORK_DIR="${WORK_DIR:-./migration_workspace}"
STATE_FILE="$WORK_DIR/migration_state.env"
LOG_FILE="$WORK_DIR/migration_$(date +%Y%m%d_%H%M%S).log"

# Migration path (Keycloak versions)
# Includes all supported starting versions and upgrade targets
declare -a MIGRATION_PATH=(
    "16.1.1"
    "17.0.1"
    "22.0.5"
    "25.0.6"
    "26.0.7"
)

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

# ============================================================================
# VERSION AUTO-DETECTION
# ============================================================================

kc_detect_version() {
    # Auto-detect current Keycloak version from multiple sources
    local version=""

    # Method 1: Check Keycloak home directory for version.txt
    if [[ -n "${PROFILE_KC_HOME:-}" && -f "${PROFILE_KC_HOME}/version.txt" ]]; then
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

    # Method 4: Check Docker image tag
    if [[ -z "$version" && "${PROFILE_KC_DEPLOYMENT_MODE:-}" == "docker_compose" ]]; then
        local compose_file="${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"
        if [[ -f "$compose_file" ]]; then
            version=$(grep -A5 "keycloak" "$compose_file" | grep "image:" | \
                grep -oP 'quay.io/keycloak/keycloak:\K[\d\.]+' | head -1)
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

kc_select_target_version() {
    # Interactive selection of target version
    local current_version="${1:-}"
    local current_idx=-1

    if [[ -z "$current_version" ]]; then
        echo "ERROR: Current version not specified" >&2
        return 1
    fi

    # Find current version index in migration path
    for i in "${!MIGRATION_PATH[@]}"; do
        if [[ "${MIGRATION_PATH[$i]}" == "$current_version" ]]; then
            current_idx=$i
            break
        fi
    done

    if [[ $current_idx -eq -1 ]]; then
        echo "ERROR: Current version $current_version not in migration path" >&2
        echo "Supported versions: ${MIGRATION_PATH[*]}" >&2
        return 1
    fi

    # Check if already at latest
    if [[ $current_idx -eq $((${#MIGRATION_PATH[@]} - 1)) ]]; then
        log_info "Already at latest version: $current_version"
        echo "$current_version"
        return 0
    fi

    # Offer target versions
    echo ""
    echo "Current version: $current_version"
    echo ""
    echo "Available target versions:"
    echo ""

    local options=()
    for ((i=current_idx+1; i<${#MIGRATION_PATH[@]}; i++)); do
        local version="${MIGRATION_PATH[$i]}"
        local java_major=$(echo "$version" | cut -d. -f1)
        local java_req="${JAVA_REQUIREMENTS[$java_major]:-unknown}"
        options+=("$version")
        printf "  [%d] %s (Java %s)\n" "$((i-current_idx))" "$version" "$java_req"
    done

    echo ""
    read -rp "Select target version [1-${#options[@]}] or 'latest': " choice

    if [[ "$choice" == "latest" || "$choice" == "l" ]]; then
        echo "${options[-1]}"
        return 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 && $choice -le ${#options[@]} ]]; then
        echo "${options[$((choice-1))]}"
        return 0
    else
        echo "ERROR: Invalid choice: $choice" >&2
        return 1
    fi
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
}

get_checkpoint() {
    local version="$1"
    local key="CHECKPOINT_${version//\./_}"
    if [[ -f "$STATE_FILE" ]]; then
        grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo ""
    fi
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
            read -r -p "Resume from last successful step? [y/N]: " resume
            if [[ "$resume" =~ ^[Yy]$ ]]; then
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

    # 1. Disk space (15 GB minimum)
    local target_path="$WORK_DIR"
    [[ ! -d "$target_path" ]] && target_path="$(dirname "$target_path")"
    local available_gb=$(df -BG "$target_path" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")
    local required_gb=15

    if [[ "${available_gb:-0}" -ge "$required_gb" ]]; then
        log_success "Disk space: ${available_gb}GB available (need ${required_gb}GB)"
    else
        log_error "Disk space: ${available_gb}GB < ${required_gb}GB required"
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
        docker) required_tools+=("docker") ;;
        docker-compose) required_tools+=("docker" "docker-compose") ;;
        kubernetes|deckhouse) required_tools+=("kubectl") ;;
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

    # 3. Java check for ALL versions in migration path
    local current="${PROFILE_KC_CURRENT_VERSION}"
    local target="${PROFILE_KC_TARGET_VERSION}"
    local found_current=false
    local java_versions_needed=()

    for version in "${MIGRATION_PATH[@]}"; do
        if [[ "$version" == "$current" ]]; then
            found_current=true
            continue
        fi
        if $found_current; then
            local major=$(echo "$version" | cut -d. -f1)
            local req="${JAVA_REQUIREMENTS[$major]:-11}"
            # Add to list if not already there
            if [[ ! " ${java_versions_needed[*]:-} " =~ " ${req} " ]]; then
                java_versions_needed+=("$req")
            fi
            [[ "$version" == "$target" ]] && break
        fi
    done

    if command -v java &>/dev/null; then
        local current_java=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
        [[ "$current_java" == "1" ]] && current_java=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f2)

        local max_needed=11
        for v in "${java_versions_needed[@]}"; do
            [[ "$v" -gt "$max_needed" ]] && max_needed="$v"
        done

        if [[ "$current_java" -ge "$max_needed" ]]; then
            log_success "Java $current_java (need ${java_versions_needed[*]})"
        else
            log_error "Java $current_java insufficient — migration path requires: ${java_versions_needed[*]}"
            errors=$((errors + 1))
        fi
    else
        log_error "Java not found"
        errors=$((errors + 1))
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
        local db_pass="${PGPASSWORD:-${DB_PASSWORD:-}}"
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
            read -r -p "Use auto-discovered configuration? [Y/n]: " confirm
            if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
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
    local pass="${PGPASSWORD:-${DB_PASSWORD:-}}"
    local parallel_jobs="${PROFILE_MIGRATION_PARALLEL_JOBS:-4}"

    log_info "Database: $db_type @ $host:$port/$db_name"
    log_info "Backup file: $backup_file"
    log_info "Parallel jobs: $parallel_jobs"

    # Create backup using adapter
    if db_backup "$db_type" "$host" "$port" "$db_name" "$user" "$pass" "$backup_file" "$parallel_jobs"; then
        log_success "Backup created: $backup_file"

        # Calculate size
        local size=$(du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Backup size: $size"

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
    local pass="${PGPASSWORD:-${DB_PASSWORD:-}}"
    local parallel_jobs="${PROFILE_MIGRATION_PARALLEL_JOBS:-4}"

    log_info "Database: $db_type @ $host:$port/$db_name"
    log_info "Backup file: $backup_file"
    log_info "Parallel jobs: $parallel_jobs"

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

kc_service_start() {
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"

    log_info "Starting Keycloak ($mode mode)"

    case "$mode" in
        standalone)
            kc_start "$mode" "${PROFILE_KC_SERVICE_NAME:-keycloak}"
            ;;
        docker)
            kc_start "$mode" "${PROFILE_KC_CONTAINER_NAME:-keycloak}"
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

kc_service_stop() {
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"

    log_info "Stopping Keycloak ($mode mode)"

    case "$mode" in
        standalone)
            kc_stop "$mode" "${PROFILE_KC_SERVICE_NAME:-keycloak}"
            ;;
        docker)
            kc_stop "$mode" "${PROFILE_KC_CONTAINER_NAME:-keycloak}"
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
        docker)
            kc_status "$mode" "${PROFILE_KC_CONTAINER_NAME:-keycloak}"
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
# KEYCLOAK HEALTH CHECK
# ============================================================================

health_check() {
    local endpoint="${1:-http://localhost:8080/health}"
    local max_attempts="${HEALTH_CHECK_RETRIES}"
    local interval="${HEALTH_CHECK_INTERVAL}"
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"

    log_info "Health check: $endpoint (max $max_attempts attempts, ${interval}s interval)"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts..."

        if kc_health_check "$mode" "$endpoint" \
            "${PROFILE_KC_CONTAINER_NAME:-keycloak}" \
            "${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"; then
            log_success "Health check passed"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Health check failed, retrying in ${interval}s..."
            sleep "$interval"
        fi

        ((attempt++))
    done

    log_error "Health check failed after $max_attempts attempts"
    return 1
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

    # Build command
    local build_cmd="$kc_home/bin/kc.sh build"
    local build_log="$WORK_DIR/build_${version}_$(date +%Y%m%d_%H%M%S).log"

    log_info "Running: $build_cmd"
    log_info "Build log: $build_log"

    # Run build
    if "$build_cmd" > "$build_log" 2>&1; then
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
        read -r -p "Build may have failed. Continue anyway? [y/N]: " continue_build
        if [[ ! "$continue_build" =~ ^[Yy]$ ]]; then
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

    # Initial wait for startup
    sleep 10

    # Monitor logs
    while [[ $elapsed -lt $timeout ]]; do
        elapsed=$(($(date +%s) - start_time))

        # Check logs for migration markers
        local logs=$(kc_logs "${PROFILE_KC_DEPLOYMENT_MODE}" "false" \
            "${PROFILE_KC_CONTAINER_NAME:-}" \
            "${PROFILE_KC_COMPOSE_FILE:-}" 2>/dev/null || echo "")

        # Check for migration complete markers
        if echo "$logs" | grep -qi "Liquibase command 'update' was executed successfully\|Migration successful\|Keycloak.*started"; then
            migration_complete=true
            log_success "Database migration completed (${elapsed}s elapsed)"
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
        echo ""
        read -r -p "Continue anyway? [y/N]: " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
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
        local backup_file="$WORK_DIR/backup_before_${target_version}_$(date +%Y%m%d_%H%M%S).dump"
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
        read -r -p "Rollback to previous version? [y/N]: " do_rollback
        if [[ "$do_rollback" =~ ^[Yy]$ ]]; then
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
        local backup_file="$WORK_DIR/backup_before_${target_version}_$(date +%Y%m%d_%H%M%S).dump"
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

            read -r -p "Delete green deployment? [Y/n]: " delete_green
            if [[ ! "$delete_green" =~ ^[Nn]$ ]]; then
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
    read -r -p "Delete blue deployment (old version)? [Y/n]: " delete_blue

    if [[ ! "$delete_blue" =~ ^[Nn]$ ]]; then
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

    log_section "Migration Step $step_num/$total_steps: Keycloak $target_version"

    # Check for existing checkpoint (resume support)
    local existing_cp=$(get_checkpoint "$target_version")
    if [[ -n "$existing_cp" ]]; then
        log_warn "Resuming step for $target_version from checkpoint: $existing_cp"
    fi

    # Check Java compatibility
    check_java_for_version "$target_version" || return 1

    # Step 1: Backup before migration
    if [[ "${PROFILE_MIGRATION_BACKUP:-true}" == "true" ]]; then
        if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "backup_done"; then
            local backup_file="$WORK_DIR/backup_before_${target_version}_$(date +%Y%m%d_%H%M%S).dump"
            db_backup_keycloak "$backup_file" "before $target_version" || return 1
            update_state "LAST_BACKUP" "$backup_file"
            set_checkpoint "$target_version" "backup_done"
        else
            log_info "Skipping backup (already done)"
        fi
    fi

    # Step 2: Stop Keycloak
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "stopped"; then
        kc_service_stop || return 1
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
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "started"; then
        kc_service_start || return 1
        set_checkpoint "$target_version" "started"
    else
        log_info "Skipping start (already running)"
    fi

    # Step 6: Wait for migration to complete
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "migrated"; then
        wait_for_migration "$target_version" || return 1
        set_checkpoint "$target_version" "migrated"
    else
        log_info "Skipping migration wait (already migrated)"
    fi

    # Step 7: Health check (with auto-rollback on failure)
    if [[ -z "$existing_cp" ]] || ! should_skip_to "$existing_cp" "health_ok"; then
        if ! health_check; then
            log_error "Health check failed after migration to $target_version"
            if [[ "${AUTO_ROLLBACK:-false}" == "true" ]]; then
                log_warn "Auto-rollback enabled — rolling back..."
                cmd_rollback_auto
                return 1
            else
                read -r -p "Rollback to last backup? [Y/n]: " do_rollback
                if [[ ! "$do_rollback" =~ ^[Nn]$ ]]; then
                    cmd_rollback_auto
                fi
                return 1
            fi
        fi
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

        read -r -p "Continue migration despite test failures? [y/N]: " continue_migration
        if [[ "$continue_migration" =~ ^[Yy]$ ]]; then
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

    # Determine migration path
    local migration_steps=()
    local found_current=false

    for version in "${MIGRATION_PATH[@]}"; do
        if [[ "$version" == "$current_version" ]]; then
            found_current=true
            continue
        fi

        if $found_current; then
            migration_steps+=("$version")

            # Stop if we reached target
            if [[ "$version" == "$target_version" ]]; then
                break
            fi
        fi
    done

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

    # Airgap: validate all artifacts available before starting
    if [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
        dist_validate_airgap "${migration_steps[@]}" || {
            log_error "Airgap validation failed — cannot proceed without required artifacts"
            exit 1
        }
    fi

    read -r -p "Proceed with migration? [y/N]: " proceed
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled by user"
        audit_info "migration_cancelled" "User cancelled migration"
        exit 0
    fi

    # Audit: migration start
    local migration_start_ts
    migration_start_ts=$(date +%s)
    audit_migration_start "${PROFILE_NAME:-unknown}" "$current_version" "$target_version"

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

        step_num=$((step_num + 1))
    done

    log_section "Migration Complete!"
    log_success "Keycloak successfully migrated from $current_version to $target_version"

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

    local found_current=false
    for version in "${MIGRATION_PATH[@]}"; do
        if [[ "$version" == "$current_version" ]]; then
            found_current=true
            echo "  ✓ $version (current)"
            continue
        fi

        if $found_current; then
            echo "  → $version"

            if [[ "$version" == "$target_version" ]]; then
                echo "  ✓ $version (target)"
                break
            fi
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
# COMMAND: MIGRATE
# ============================================================================

cmd_migrate() {
    local profile="${1:-}"

    # Initialize workspace
    mkdir -p "$WORK_DIR"

    # Check for resume
    if ! check_resume; then
        load_profile_or_discover "$profile"
    fi

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

    # Safety backup before rollback
    local safety_backup="$WORK_DIR/safety_before_rollback_$(date +%Y%m%d_%H%M%S).dump"
    db_backup_keycloak "$safety_backup" "safety backup before rollback" || true

    # Stop → Restore → Start
    kc_service_stop || true
    db_restore_keycloak "$last_backup" "rollback" || {
        log_error "Rollback restore failed!"
        return 1
    }
    kc_service_start || true

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
    else
        read -r -p "Proceed with rollback? [y/N]: " proceed
        if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
            log_info "Rollback cancelled"
            exit 0
        fi
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
    rollback                Rollback to last backup

OPTIONS:
    --profile <name>        Use specified profile from profiles/ directory
    --dry-run               Show what would be done without executing
    --skip-tests            Skip smoke tests after each migration step
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

PROFILES:
    Profiles are YAML files in the profiles/ directory.
    Create a profile using: ./scripts/config_wizard.sh

    Examples:
    - standalone-postgresql.yaml
    - kubernetes-cluster-production.yaml
    - docker-compose-dev.yaml

ENVIRONMENT VARIABLES:
    PGPASSWORD              PostgreSQL password (if using PostgreSQL)
    DB_PASSWORD             Database password (generic)
    WORK_DIR                Workspace directory (default: ./migration_workspace)

EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
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

# Run main
main "$@"
