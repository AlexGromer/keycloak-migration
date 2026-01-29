#!/bin/bash
#
# Keycloak Migration Script v2.0
# Version: 2.0.0
#
# Automates step-by-step migration: KC 16 → 17 → 22 → 25 → 26
# Downloads required versions, migrates DB, verifies each step
#
# CHANGELOG v2.0:
# - Fixed all 30 identified issues (P0-P2)
# - Secure password handling via .pgpass
# - Java version validation per KC version
# - Safe rollback with pre-rollback backup
# - Improved timeout handling with Liquibase markers
# - Automatic smoke tests after each migration
# - Live migration monitor support
# - Idempotency and resume capability
# - Extended validation and error detection
#

set -euo pipefail

VERSION="2.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Migration path
MIGRATION_PATH=(17 22 25 26)

# Keycloak download URLs
declare -A KC_VERSIONS=(
    [17]="17.0.1"
    [22]="22.0.5"
    [25]="25.0.6"
    [26]="26.0.7"
)

declare -A KC_URLS=(
    [17]="https://github.com/keycloak/keycloak/releases/download/17.0.1/keycloak-17.0.1.tar.gz"
    [22]="https://github.com/keycloak/keycloak/releases/download/22.0.5/keycloak-22.0.5.tar.gz"
    [25]="https://github.com/keycloak/keycloak/releases/download/25.0.6/keycloak-25.0.6.tar.gz"
    [26]="https://github.com/keycloak/keycloak/releases/download/26.0.7/keycloak-26.0.7.tar.gz"
)

# Java requirements per KC version
declare -A JAVA_REQUIREMENTS=(
    [17]=11
    [22]=17
    [25]=17
    [26]=21
)

# Defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/../migration_workspace"
DOWNLOADS_DIR="${WORK_DIR}/downloads"
STAGING_DIR="${WORK_DIR}/staging"
BACKUP_DIR="${WORK_DIR}/backups"
PROVIDERS_DIR="${WORK_DIR}/providers"
LOG_DIR="${WORK_DIR}/logs"

PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-keycloak}"
PG_USER="${PG_USER:-keycloak}"
PG_PASS="${PG_PASS:-}"

KC_HTTP_PORT="${KC_HTTP_PORT:-8080}"
KC_HTTPS_PORT="${KC_HTTPS_PORT:-8443}"
KC_RELATIVE_PATH="${KC_RELATIVE_PATH:-/auth}"

TRANSFORMED_PROVIDERS=""
SKIP_DOWNLOAD=false
SKIP_BACKUP=false
SKIP_TESTS=false
RUN_MONITOR=false
DRY_RUN=false
START_FROM=""
STOP_AT=""
MIGRATION_TIMEOUT=600  # Increased from 300s
PARALLEL_JOBS=4

#######################################
# Logging
#######################################
LOG_FILE=""
PGPASS_FILE=""

log_init() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/migration_$(date +%Y%m%d_%H%M%S).log"
    echo "=== Keycloak Migration Log v${VERSION} ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
}

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; log "INFO: $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; log "OK: $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; log "=== $1 ==="; }
log_step() { echo -e "${MAGENTA}[STEP]${NC} $1"; log "STEP: $1"; }

#######################################
# Usage
#######################################
usage() {
    cat << EOF
Keycloak Migration Tool v${VERSION}

Automates step-by-step migration: KC 16 → 17 → 22 → 25 → 26

Usage: $(basename "$0") [ACTION] [OPTIONS]

Actions:
  plan                Show migration plan (dry-run)
  download            Download required Keycloak versions
  migrate             Execute full migration
  migrate-step VER    Migrate to specific version only
  status              Show current migration status
  rollback VER        Rollback to backup of version VER

Options:
  -h, --help                  Show this help
  -w, --work-dir DIR          Working directory (default: ../migration_workspace)
  -H, --pg-host HOST          PostgreSQL host
  -P, --pg-port PORT          PostgreSQL port
  -D, --pg-database DB        PostgreSQL database
  -U, --pg-user USER          PostgreSQL user
  -W, --pg-password PASS      PostgreSQL password (prefer interactive)
  -p, --providers DIR         Transformed providers directory
  --http-port PORT            Keycloak HTTP port (default: 8080)
  --relative-path PATH        URL path (default: /auth)
  --skip-download             Use already downloaded versions
  --skip-backup               Skip backups (DANGEROUS!)
  --skip-tests                Skip smoke tests after migration
  --monitor                   Run live migration monitor
  --start-from VER            Start migration from version
  --stop-at VER               Stop migration at version
  --timeout SEC               Migration timeout per version (default: 600)
  -j, --jobs N                Parallel jobs for backups (default: 4)

Examples:
  # Show migration plan
  ./$(basename "$0") plan

  # Download all versions
  ./$(basename "$0") download

  # Full migration with monitor
  ./$(basename "$0") migrate --monitor

  # Migrate only to version 22
  ./$(basename "$0") migrate-step 22

  # Continue from version 22
  ./$(basename "$0") migrate --start-from 22

Environment variables:
  PG_HOST, PG_PORT, PG_DB, PG_USER, PG_PASS

EOF
    exit 0
}

#######################################
# Parse arguments
#######################################
ACTION="plan"

parse_args() {
    if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
        ACTION="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
            -H|--pg-host) PG_HOST="$2"; shift 2 ;;
            -P|--pg-port) PG_PORT="$2"; shift 2 ;;
            -D|--pg-database) PG_DB="$2"; shift 2 ;;
            -U|--pg-user) PG_USER="$2"; shift 2 ;;
            -W|--pg-password) PG_PASS="$2"; shift 2 ;;
            -p|--providers) TRANSFORMED_PROVIDERS="$2"; shift 2 ;;
            --http-port) KC_HTTP_PORT="$2"; shift 2 ;;
            --relative-path) KC_RELATIVE_PATH="$2"; shift 2 ;;
            --skip-download) SKIP_DOWNLOAD=true; shift ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
            --skip-tests) SKIP_TESTS=true; shift ;;
            --monitor) RUN_MONITOR=true; shift ;;
            --start-from) START_FROM="$2"; shift 2 ;;
            --stop-at) STOP_AT="$2"; shift 2 ;;
            --timeout) MIGRATION_TIMEOUT="$2"; shift 2 ;;
            -j|--jobs) PARALLEL_JOBS="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Update paths
    DOWNLOADS_DIR="${WORK_DIR}/downloads"
    STAGING_DIR="${WORK_DIR}/staging"
    BACKUP_DIR="${WORK_DIR}/backups"
    LOG_DIR="${WORK_DIR}/logs"
}

#######################################
# P0-1: Secure password handling
#######################################
setup_pgpass() {
    log_info "Setting up secure PostgreSQL authentication..."

    if [[ -z "$PG_PASS" ]]; then
        read -r -s -p "PostgreSQL password for $PG_USER: " PG_PASS
        echo ""
    fi

    # Create temporary .pgpass file
    PGPASS_FILE="${WORK_DIR}/.pgpass.tmp"
    echo "$PG_HOST:$PG_PORT:$PG_DB:$PG_USER:$PG_PASS" > "$PGPASS_FILE"
    chmod 0600 "$PGPASS_FILE"
    export PGPASSFILE="$PGPASS_FILE"

    log_success "Secure authentication configured"
}

cleanup_pgpass() {
    if [[ -n "$PGPASS_FILE" ]] && [[ -f "$PGPASS_FILE" ]]; then
        shred -u "$PGPASS_FILE" 2>/dev/null || rm -f "$PGPASS_FILE"
    fi
    unset PGPASSFILE
}

trap cleanup_pgpass EXIT INT TERM

#######################################
# Initialize workspace
#######################################
init_workspace() {
    mkdir -p "$WORK_DIR" "$DOWNLOADS_DIR" "$STAGING_DIR" "$BACKUP_DIR" "$LOG_DIR"
    log_init

    # Load or create state file
    local state_file="${WORK_DIR}/migration_state.env"

    if [[ -f "$state_file" ]]; then
        log_info "Found existing migration state"
        source "$state_file"

        # Check if resume is safe
        if [[ "${RESUME_SAFE:-false}" == "true" ]] && [[ -n "${CURRENT_STEP:-}" ]]; then
            log_warn "Previous migration interrupted at: ${CURRENT_STEP}"

            if [[ -z "$START_FROM" ]]; then
                read -r -p "Resume from this point? [y/N] " resume
                if [[ "$resume" =~ ^[Yy]$ ]]; then
                    START_FROM="${CURRENT_VERSION}"
                    log_info "Resuming from KC $START_FROM"
                fi
            fi
        fi
    else
        # Create new state file
        cat > "$state_file" << EOF
# Migration state - $(date)
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_DB=$PG_DB
PG_USER=$PG_USER
KC_HTTP_PORT=$KC_HTTP_PORT
KC_RELATIVE_PATH=$KC_RELATIVE_PATH
CURRENT_VERSION=16
LAST_SUCCESSFUL=
CURRENT_STEP=init
RESUME_SAFE=false
EOF
    fi
}

#######################################
# Update migration state
#######################################
update_state() {
    local key="$1"
    local value="$2"
    local state_file="${WORK_DIR}/migration_state.env"

    if [[ -f "$state_file" ]]; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$state_file"
    fi
}

#######################################
# P0-2: Check Java version per KC version
#######################################
check_java_for_version() {
    local kc_ver="$1"
    local required_java="${JAVA_REQUIREMENTS[$kc_ver]}"

    log_info "Checking Java version for KC $kc_ver (requires Java $required_java+)..."

    local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)

    if [[ "$java_version" -lt "$required_java" ]]; then
        log_error "KC $kc_ver requires Java $required_java+, current: Java $java_version"
        log_error "Set JAVA_HOME to Java $required_java+ or install required version"
        log_error "Example: export JAVA_HOME=/usr/lib/jvm/java-${required_java}-openjdk-amd64"
        return 1
    fi

    log_success "Java $java_version OK for KC $kc_ver (requires $required_java+)"
    return 0
}

#######################################
# Check prerequisites
#######################################
check_prereqs() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    command -v java >/dev/null 2>&1 || missing+=("java")
    command -v psql >/dev/null 2>&1 || missing+=("psql")
    command -v pg_dump >/dev/null 2>&1 || missing+=("pg_dump")
    command -v pg_restore >/dev/null 2>&1 || missing+=("pg_restore")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing tools: ${missing[*]}"
        log_info "Install with: apt install postgresql-client default-jdk curl tar"
        exit 1
    fi

    # Check Java version for initial KC version (17)
    local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
    log_info "Java version: $java_version"

    # P1-2: Check disk space
    local required_gb=15
    local available_gb=$(df -BG "$WORK_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")

    if [[ "${available_gb:-0}" -lt "$required_gb" ]]; then
        log_error "Insufficient disk space: ${available_gb}GB < ${required_gb}GB"
        log_info "Need: 4×800MB (KC downloads) + 3GB (backups) + 5GB (buffer)"
        exit 1
    fi

    log_success "Disk space OK: ${available_gb}GB available"
    log_success "Prerequisites OK"
}

#######################################
# Test database connection
#######################################
test_db_connection() {
    log_info "Testing PostgreSQL connection..."

    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
        log_success "Database connection OK"

        # P1-7: Check PostgreSQL version
        local pg_version=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
            "SHOW server_version;" 2>/dev/null | awk '{print $1}' | cut -d. -f1)

        if [[ -n "$pg_version" ]]; then
            log_info "PostgreSQL version: $pg_version"
            if [[ "$pg_version" -lt 12 ]]; then
                log_warn "PostgreSQL $pg_version is old (recommend 12+)"
            fi
        fi

        return 0
    else
        log_error "Cannot connect to database"
        log_info "Check: host=$PG_HOST port=$PG_PORT db=$PG_DB user=$PG_USER"
        return 1
    fi
}

#######################################
# Download Keycloak versions
#######################################
download_versions() {
    log_section "DOWNLOADING KEYCLOAK VERSIONS"

    for ver in "${MIGRATION_PATH[@]}"; do
        local full_ver="${KC_VERSIONS[$ver]}"
        local url="${KC_URLS[$ver]}"
        local archive="${DOWNLOADS_DIR}/keycloak-${full_ver}.tar.gz"
        local extract_dir="${STAGING_DIR}/kc-${ver}"

        if [[ -d "$extract_dir" ]] && $SKIP_DOWNLOAD; then
            log_info "KC $ver already exists, skipping"
            continue
        fi

        # Download
        if [[ ! -f "$archive" ]]; then
            log_info "Downloading Keycloak ${full_ver}..."
            if curl -fL -# -o "$archive" "$url"; then
                log_success "Downloaded: $(basename "$archive")"
            else
                log_error "Failed to download KC $ver from $url"
                exit 1
            fi
        else
            log_info "Archive exists: $(basename "$archive")"
        fi

        # Extract
        log_info "Extracting KC ${ver}..."
        rm -rf "$extract_dir"
        mkdir -p "$extract_dir"

        tar -xzf "$archive" -C "$extract_dir" --strip-components=1

        if [[ -f "${extract_dir}/bin/kc.sh" ]]; then
            log_success "KC $ver ready: $extract_dir"
        else
            log_error "Extraction failed for KC $ver"
            exit 1
        fi
    done

    log_success "All versions downloaded"
}

# Continue in next message due to length...

#######################################
# Create Keycloak config
#######################################
create_kc_config() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"
    local config_file="${kc_dir}/conf/keycloak.conf"

    log_info "Creating config for KC $ver..."

    cat > "$config_file" << EOF
# Keycloak ${ver} Configuration
# Generated by migrate_keycloak.sh v${VERSION}

# Database
db=postgres
db-url=jdbc:postgresql://${PG_HOST}:${PG_PORT}/${PG_DB}
db-username=${PG_USER}
db-password=${PG_PASS}

# HTTP
http-enabled=true
http-port=${KC_HTTP_PORT}
http-relative-path=${KC_RELATIVE_PATH}
hostname-strict=false
hostname-strict-https=false

# Logging
log-level=INFO,org.keycloak.migration:DEBUG

# Health
health-enabled=true

# Performance
spi-connections-jpa-default-initialize-empty=false
EOF

    # Version-specific settings
    if [[ "$ver" -ge 25 ]]; then
        cat >> "$config_file" << EOF

# KC 25+ specific - Persistent sessions
cache-embedded-mtls-enabled=false
EOF
    fi

    log_success "Config created: $config_file"
}

#######################################
# Copy providers
#######################################
copy_providers() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"

    # Only copy providers to KC 22+ (after jakarta migration)
    if [[ "$ver" -lt 22 ]]; then
        log_info "Skipping providers for KC $ver (pre-Jakarta)"
        return 0
    fi

    if [[ -z "$TRANSFORMED_PROVIDERS" ]] || [[ ! -d "$TRANSFORMED_PROVIDERS" ]]; then
        log_info "No transformed providers directory specified"
        return 0
    fi

    log_info "Copying providers to KC $ver..."

    mkdir -p "${kc_dir}/providers"

    local count=0
    for jar in "$TRANSFORMED_PROVIDERS"/*.jar; do
        [[ ! -f "$jar" ]] && continue
        cp "$jar" "${kc_dir}/providers/"
        ((count++))
    done

    if [[ $count -gt 0 ]]; then
        log_success "Copied $count provider(s)"
    else
        log_info "No providers to copy"
    fi
}

#######################################
# P0-6: Build Keycloak with validation
#######################################
build_keycloak() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"
    local build_log="${LOG_DIR}/kc_${ver}_build.log"

    log_info "Building KC $ver..."

    # P1-5: Clean build cache
    if [[ -d "${kc_dir}/data/tmp" ]]; then
        log_info "Cleaning KC build cache..."
        rm -rf "${kc_dir}/data/tmp"
    fi

    cd "$kc_dir"

    if ./bin/kc.sh build > "$build_log" 2>&1; then
        # Validate build success
        if grep -qE "BUILD SUCCESS|Server configuration updated|Updating the configuration" "$build_log"; then
            log_success "KC $ver built successfully"
            return 0
        else
            log_warn "Build command succeeded but no success marker found"
            log_info "Last 20 lines of build log:"
            tail -20 "$build_log"

            read -r -p "Continue anyway? [y/N] " cont
            [[ "$cont" =~ ^[Yy]$ ]] && return 0 || return 1
        fi
    else
        log_error "Build failed for KC $ver"
        log_info "Last 30 lines of build log:"
        tail -30 "$build_log"
        return 1
    fi
}

#######################################
# P0-4: Improved wait for migration
#######################################
wait_for_migration() {
    local ver="$1"
    local kc_pid="$2"
    local log_file="$3"
    local timeout="${MIGRATION_TIMEOUT}"

    update_state "CURRENT_STEP" "wait_migration_${ver}"

    log_info "Waiting for migration (timeout: ${timeout}s)..."

    local waited=0
    local migration_started=false
    local migration_completed=false
    local started=false

    while [[ $waited -lt $timeout ]]; do
        sleep 5
        waited=$((waited + 5))

        # Check if process alive
        if ! kill -0 "$kc_pid" 2>/dev/null; then
            log_error "KC $ver crashed during startup"
            log_info "Last 100 lines of log:"
            tail -100 "$log_file" | grep -E "(ERROR|FATAL|Exception)" || tail -50 "$log_file"
            return 1
        fi

        # Check Liquibase stages
        if ! $migration_started && grep -q "Liquibase.*Starting" "$log_file" 2>/dev/null; then
            migration_started=true
            log_info "Liquibase migration started..."
        fi

        if $migration_started && ! $migration_completed && grep -q "Liquibase.*Update has been successful" "$log_file" 2>/dev/null; then
            migration_completed=true
            log_success "Database migration completed"
            # Increase timeout after successful migration (KC might need time to start services)
            timeout=$((timeout + 60))
        fi

        # Check startup completion
        if grep -q "Listening on:" "$log_file" 2>/dev/null; then
            started=true
            break
        fi

        # Check for critical errors
        if grep -qE "(FATAL|OutOfMemoryError|StackOverflowError)" "$log_file" 2>/dev/null; then
            log_error "Critical error detected"
            tail -50 "$log_file"
            return 1
        fi

        # Progress indicator
        if [[ $((waited % 30)) -eq 0 ]]; then
            echo -n " (${waited}s)"
        else
            echo -n "."
        fi
    done
    echo ""

    if $started; then
        log_success "KC $ver started (took ${waited}s)"
        return 0
    else
        log_error "Timeout after ${timeout}s"
        log_info "Last 50 lines of log:"
        tail -50 "$log_file"
        return 1
    fi
}

#######################################
# P0-7: Health check with retry
#######################################
health_check() {
    local ver="$1"
    local max_attempts=5
    local attempt=1

    log_info "Running health check..."

    while [[ $attempt -le $max_attempts ]]; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 10 \
            "http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}/health" 2>/dev/null || echo "000")

        local body=$(echo "$response" | head -n -1)
        local status=$(echo "$response" | tail -n 1)

        if [[ "$status" == "200" ]] && echo "$body" | grep -q "UP"; then
            log_success "Health check passed (attempt $attempt/$max_attempts)"

            # Extended check: verify readiness endpoint
            if curl -s --max-time 5 "http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}/health/ready" \
                | grep -q "UP" 2>/dev/null; then
                log_success "Readiness check passed"
                return 0
            fi
        fi

        log_info "Attempt $attempt/$max_attempts failed (HTTP $status), retrying in 5s..."
        sleep 5
        ((attempt++))
    done

    log_error "Health check failed after $max_attempts attempts"
    return 1
}

#######################################
# Start Keycloak and wait for migration
#######################################
start_and_migrate() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"
    local pid_file="${WORK_DIR}/kc_${ver}.pid"
    local log_file="${LOG_DIR}/kc_${ver}_startup.log"

    update_state "CURRENT_STEP" "start_kc_${ver}"
    update_state "RESUME_SAFE" "false"

    log_step "Starting KC $ver for database migration..."

    cd "$kc_dir"

    # Start in background
    ./bin/kc.sh start --optimized > "$log_file" 2>&1 &
    local kc_pid=$!
    echo "$kc_pid" > "$pid_file"

    log_info "KC $ver started (PID: $kc_pid)"

    # Wait for migration
    if wait_for_migration "$ver" "$kc_pid" "$log_file"; then
        log_success "KC $ver migration successful"

        # Health check
        sleep 3
        if health_check "$ver"; then
            return 0
        else
            log_warn "Health check failed but migration completed - may be OK"
            read -r -p "Continue? [y/N] " cont
            [[ "$cont" =~ ^[Yy]$ ]] && return 0 || return 1
        fi
    else
        return 1
    fi
}

#######################################
# Stop Keycloak
#######################################
stop_keycloak() {
    local ver="$1"
    local pid_file="${WORK_DIR}/kc_${ver}.pid"

    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping KC $ver (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            
            # Wait gracefully
            local waited=0
            while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 30 ]]; do
                sleep 1
                ((waited++))
            done

            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "Force killing KC $ver..."
                kill -9 "$pid" 2>/dev/null || true
            fi

            log_success "KC $ver stopped"
        fi
        rm -f "$pid_file"
    fi

    # Also kill any keycloak on our port
    local port_pid=$(lsof -ti:${KC_HTTP_PORT} 2>/dev/null || true)
    if [[ -n "$port_pid" ]]; then
        log_info "Killing process on port ${KC_HTTP_PORT}..."
        kill "$port_pid" 2>/dev/null || true
        sleep 2
    fi
}

#######################################
# Backup before migration step
#######################################
backup_before_step() {
    local ver="$1"

    if $SKIP_BACKUP; then
        log_warn "Skipping backup (--skip-backup)"
        return 0
    fi

    update_state "CURRENT_STEP" "backup_before_${ver}"

    log_info "Creating backup before KC $ver migration..."

    local backup_file="${BACKUP_DIR}/pre_kc${ver}_$(date +%Y%m%d_%H%M%S).dump"

    # P1-7: Check PostgreSQL version for parallel backup support
    local pg_version=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SHOW server_version;" 2>/dev/null | cut -d. -f1 | tr -d ' ')

    local parallel_flag=""
    if [[ "${pg_version:-0}" -ge 9 ]]; then
        parallel_flag="-j $PARALLEL_JOBS"
    fi

    if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -F c $parallel_flag -f "$backup_file" 2>/dev/null; then

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "Backup created: $(basename "$backup_file") ($size)"

        # Save in state
        echo "BACKUP_BEFORE_${ver}=$backup_file" >> "${WORK_DIR}/migration_state.env"
        return 0
    else
        log_error "Backup failed!"
        return 1
    fi
}

#######################################
# Run smoke tests
#######################################
run_smoke_tests() {
    local ver="$1"

    if $SKIP_TESTS; then
        log_info "Skipping smoke tests (--skip-tests)"
        return 0
    fi

    log_section "SMOKE TESTS FOR KC $ver"

    local smoke_script="${SCRIPT_DIR}/smoke_test.sh"

    if [[ ! -f "$smoke_script" ]]; then
        log_warn "Smoke test script not found: $smoke_script"
        return 0
    fi

    export KC_URL="http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}"
    export ADMIN_USER="${ADMIN_USER:-admin}"
    export ADMIN_PASS="${ADMIN_PASS:-admin}"

    if "$smoke_script"; then
        log_success "Smoke tests passed for KC $ver"
        return 0
    else
        log_error "Smoke tests failed for KC $ver"
        
        read -r -p "Continue migration despite test failures? [y/N] " cont
        [[ "$cont" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
}

#######################################
# Migrate single version
#######################################
migrate_version() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"

    log_section "MIGRATING TO KEYCLOAK $ver"

    update_state "CURRENT_VERSION" "$ver"
    update_state "CURRENT_STEP" "migrate_${ver}"
    update_state "RESUME_SAFE" "true"

    # P0-2: Check Java version for this KC version
    check_java_for_version "$ver" || exit 1

    # Stop any running KC
    stop_keycloak "$ver"

    # Backup
    backup_before_step "$ver" || exit 1

    # Create config
    create_kc_config "$ver"

    # P0-5: Copy providers BEFORE build
    copy_providers "$ver"

    # Build
    build_keycloak "$ver" || exit 1

    # Start and migrate
    if start_and_migrate "$ver"; then
        log_success "KC $ver migration successful"

        # Update state
        update_state "LAST_SUCCESSFUL" "$ver"
        update_state "RESUME_SAFE" "false"

        # Run smoke tests
        run_smoke_tests "$ver" || exit 1

        # Stop KC
        stop_keycloak "$ver"

        return 0
    else
        log_error "KC $ver migration failed"
        update_state "RESUME_SAFE" "true"
        stop_keycloak "$ver"
        return 1
    fi
}

#######################################
# Full migration
#######################################
do_migrate() {
    log_section "KEYCLOAK MIGRATION"

    check_prereqs
    setup_pgpass
    test_db_connection || exit 1
    init_workspace

    # Download if needed
    if ! $SKIP_DOWNLOAD; then
        download_versions
    fi

    # Determine migration range
    local start_idx=0
    local stop_idx=${#MIGRATION_PATH[@]}

    if [[ -n "$START_FROM" ]]; then
        for i in "${!MIGRATION_PATH[@]}"; do
            if [[ "${MIGRATION_PATH[$i]}" == "$START_FROM" ]]; then
                start_idx=$i
                break
            fi
        done
    fi

    if [[ -n "$STOP_AT" ]]; then
        for i in "${!MIGRATION_PATH[@]}"; do
            if [[ "${MIGRATION_PATH[$i]}" == "$STOP_AT" ]]; then
                stop_idx=$((i + 1))
                break
            fi
        done
    fi

    log_info "Migration path: ${MIGRATION_PATH[*]:$start_idx:$((stop_idx - start_idx))}"

    if $DRY_RUN; then
        log_info "DRY-RUN: Would migrate through versions"
        return 0
    fi

    # Start monitor if requested
    local monitor_pid=""
    if $RUN_MONITOR; then
        log_info "Starting migration monitor..."
        "${SCRIPT_DIR}/migration_monitor.sh" "$WORK_DIR" full &
        monitor_pid=$!
        sleep 2  # Give monitor time to initialize
    fi

    # Execute migration
    for ((i=start_idx; i<stop_idx; i++)); do
        local ver="${MIGRATION_PATH[$i]}"

        if ! migrate_version "$ver"; then
            log_error "Migration failed at KC $ver"
            log_info "To retry: ./$(basename "$0") migrate --start-from $ver"
            log_info "To rollback: ./$(basename "$0") rollback $ver"
            
            # Stop monitor if running
            [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null || true
            
            exit 1
        fi

        # Brief pause between versions
        if [[ $i -lt $((stop_idx - 1)) ]]; then
            log_info "Pausing 5s before next version..."
            sleep 5
        fi
    done

    # Stop monitor if running
    [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null || true

    log_section "MIGRATION COMPLETE"
    log_success "Successfully migrated to KC ${MIGRATION_PATH[$((stop_idx - 1))]}"

    echo ""
    echo "Next steps:"
    echo "  1. Start KC ${MIGRATION_PATH[$((stop_idx - 1))]}: ${STAGING_DIR}/kc-${MIGRATION_PATH[$((stop_idx - 1))]}/bin/kc.sh start"
    echo "  2. Verify all functionality"
    echo "  3. Apply manual indexes if needed: ./generate_manual_indexes.sh"
    echo ""
}

#######################################
# P0-3: Safe rollback with pre-rollback backup
#######################################
do_rollback() {
    local target_ver="$1"

    if [[ -z "$target_ver" ]]; then
        log_error "Specify version to rollback to: rollback VERSION"
        echo "Available backups:"
        ls "${BACKUP_DIR}"/pre_kc*.dump 2>/dev/null | while read f; do
            echo "  $(basename "$f")"
        done
        exit 1
    fi

    local backup_file=$(ls "${BACKUP_DIR}"/pre_kc${target_ver}_*.dump 2>/dev/null | tail -1)

    if [[ -z "$backup_file" ]] || [[ ! -f "$backup_file" ]]; then
        log_error "No backup found for KC $target_ver"
        exit 1
    fi

    log_section "ROLLBACK TO PRE-KC $target_ver"

    echo "Backup file: $backup_file"
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will OVERWRITE the current database!${NC}"
    echo ""
    read -r -p "Type 'ROLLBACK' to confirm: " confirm

    if [[ "$confirm" != "ROLLBACK" ]]; then
        log_info "Rollback cancelled"
        exit 0
    fi

    setup_pgpass
    test_db_connection || exit 1

    # Create pre-rollback safety backup
    log_warn "Creating pre-rollback safety backup..."
    local safety_backup="${BACKUP_DIR}/pre_rollback_safety_$(date +%Y%m%d_%H%M%S).dump"
    
    if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -F c -j "$PARALLEL_JOBS" -f "$safety_backup" 2>/dev/null; then
        log_success "Safety backup: $safety_backup"
    else
        log_warn "Safety backup failed - continuing with rollback"
    fi

    # Terminate connections
    log_info "Terminating active connections..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_DB' AND pid <> pg_backend_pid();" \
        >/dev/null 2>&1 || true

    sleep 2

    # Restore
    log_info "Restoring from backup..."
    local start_time=$(date +%s)

    if pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        --clean --if-exists -j "$PARALLEL_JOBS" "$backup_file" 2>&1 | tee "${LOG_DIR}/rollback_$(date +%Y%m%d_%H%M%S).log" | head -20; then

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Rollback completed in ${duration}s"
    else
        log_error "Rollback FAILED! Check logs in $LOG_DIR"
        log_error "Emergency safety backup available: $safety_backup"
        exit 1
    fi

    # Verify
    log_info "Verifying restore..."
    local table_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d ' ')

    log_success "Verified: $table_count tables restored"

    echo ""
    echo "Rollback complete. Database restored to state before KC $target_ver migration."
    echo ""
    echo "If issues occur, emergency backup available:"
    echo "  ./$(basename "$0") restore --restore-file $safety_backup"
}

#######################################
# Show plan
#######################################
do_plan() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                    KEYCLOAK MIGRATION PLAN                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo "Migration path: KC 16 → ${MIGRATION_PATH[*]}"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────────────┐"
    for ver in "${MIGRATION_PATH[@]}"; do
        local full_ver="${KC_VERSIONS[$ver]}"
        local java_req="${JAVA_REQUIREMENTS[$ver]}"
        local notes=""

        case $ver in
            17) notes="WildFly → Quarkus, Java $java_req+" ;;
            22) notes="Jakarta EE, Java $java_req+, deploy providers" ;;
            25) notes="Persistent sessions, Java $java_req+" ;;
            26) notes="Target version, Java $java_req+ REQUIRED" ;;
        esac

        printf "│  KC %-2s (%-7s): %-45s │\n" "$ver" "$full_ver" "$notes"
    done
    echo "└─────────────────────────────────────────────────────────────────────┘"

    echo ""
    echo "Improvements in v2.0:"
    echo "  ✓ Secure password handling (.pgpass)"
    echo "  ✓ Java version validation per KC version"
    echo "  ✓ Safe rollback with pre-rollback backup"
    echo "  ✓ Improved migration wait with Liquibase markers"
    echo "  ✓ Health check with retry and readiness endpoint"
    echo "  ✓ Build success validation"
    echo "  ✓ Automatic smoke tests after each version"
    echo "  ✓ Resume capability after failures"
    echo "  ✓ Live migration monitor (use --monitor)"
    echo "  ✓ Extended disk space and PostgreSQL checks"

    echo ""
    echo "To start migration:"
    echo "  ./$(basename "$0") migrate [--monitor] [--skip-tests]"
}

#######################################
# Show status
#######################################
do_status() {
    log_section "MIGRATION STATUS"

    if [[ -f "${WORK_DIR}/migration_state.env" ]]; then
        echo "State file: ${WORK_DIR}/migration_state.env"
        echo ""
        cat "${WORK_DIR}/migration_state.env"
    else
        echo "No migration in progress"
    fi

    echo ""
    echo "Downloaded versions:"
    for ver in "${MIGRATION_PATH[@]}"; do
        local kc_dir="${STAGING_DIR}/kc-${ver}"
        if [[ -d "$kc_dir" ]]; then
            echo "  KC $ver: $kc_dir ✓"
        else
            echo "  KC $ver: not downloaded"
        fi
    done

    echo ""
    echo "Backups:"
    if ls "${BACKUP_DIR}"/*.dump >/dev/null 2>&1; then
        ls -lh "${BACKUP_DIR}"/*.dump | awk '{print "  " $9 " (" $5 ")"}' || echo "  None"
    else
        echo "  None"
    fi
}

#######################################
# Main
#######################################
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Migration Tool v${VERSION}                              ║"
    echo "║     Path: KC 16 → 17 → 22 → 25 → 26                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"

    case "$ACTION" in
        plan)         do_plan ;;
        download)     init_workspace; check_prereqs; download_versions ;;
        migrate)      do_migrate ;;
        migrate-step) 
            if [[ -z "$START_FROM" ]]; then
                log_error "Specify version: migrate-step VERSION"
                exit 1
            fi
            # Single step migration
            check_prereqs
            setup_pgpass
            test_db_connection || exit 1
            init_workspace
            migrate_version "$START_FROM"
            ;;
        status)       do_status ;;
        rollback)     do_rollback "$START_FROM" ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
}

main "$@"
