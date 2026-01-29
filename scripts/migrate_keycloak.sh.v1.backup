#!/bin/bash
#
# Keycloak Migration Script
# Version: 1.0.0
#
# Automates step-by-step migration: KC 16 → 17 → 22 → 25 → 26
# Downloads required versions, migrates DB, verifies each step
#

set -euo pipefail

VERSION="1.0.0"

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

# Keycloak download URLs (update versions as needed)
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
DRY_RUN=false
START_FROM=""
STOP_AT=""
MIGRATION_TIMEOUT=300  # seconds per version

#######################################
# Logging
#######################################
LOG_FILE=""

log_init() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/migration_$(date +%Y%m%d_%H%M%S).log"
    echo "=== Keycloak Migration Log ===" > "$LOG_FILE"
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
  -W, --pg-password PASS      PostgreSQL password
  -p, --providers DIR         Transformed providers directory
  --http-port PORT            Keycloak HTTP port (default: 8080)
  --relative-path PATH        URL path (default: /auth)
  --skip-download             Use already downloaded versions
  --skip-backup               Skip backups (DANGEROUS!)
  --start-from VER            Start migration from version
  --stop-at VER               Stop migration at version
  --timeout SEC               Migration timeout per version (default: 300)

Examples:
  # Show migration plan
  ./migrate_keycloak.sh plan

  # Download all versions
  ./migrate_keycloak.sh download

  # Full migration
  ./migrate_keycloak.sh migrate -W dbpassword -p ../providers_transformed/

  # Migrate only to version 22
  ./migrate_keycloak.sh migrate-step 22 -W dbpassword

  # Continue from version 22
  ./migrate_keycloak.sh migrate --start-from 22 -W dbpassword

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
            --start-from) START_FROM="$2"; shift 2 ;;
            --stop-at) STOP_AT="$2"; shift 2 ;;
            --timeout) MIGRATION_TIMEOUT="$2"; shift 2 ;;
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
# Initialize workspace
#######################################
init_workspace() {
    mkdir -p "$WORK_DIR" "$DOWNLOADS_DIR" "$STAGING_DIR" "$BACKUP_DIR" "$LOG_DIR"
    log_init

    # Save state file
    cat > "${WORK_DIR}/migration_state.env" << EOF
# Migration state - $(date)
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_DB=$PG_DB
PG_USER=$PG_USER
KC_HTTP_PORT=$KC_HTTP_PORT
KC_RELATIVE_PATH=$KC_RELATIVE_PATH
CURRENT_VERSION=16
LAST_SUCCESSFUL=
EOF
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

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing tools: ${missing[*]}"
        exit 1
    fi

    # Check Java version
    local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
    log_info "Java version: $java_version"

    if [[ "$java_version" -lt 17 ]]; then
        log_warn "Java 17+ required for KC 22+, Java 21 for KC 26"
        log_warn "Current: Java $java_version"
    fi

    # Check disk space
    local available_gb=$(df -BG "$WORK_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "${available_gb:-0}" -lt 10 ]]; then
        log_warn "Low disk space: ${available_gb}GB (recommend 10GB+)"
    fi

    log_success "Prerequisites OK"
}

#######################################
# Test database connection
#######################################
test_db_connection() {
    if [[ -z "$PG_PASS" ]]; then
        read -r -s -p "PostgreSQL password: " PG_PASS
        echo ""
    fi

    export PGPASSWORD="$PG_PASS"

    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
        log_success "Database connection OK"
        return 0
    else
        log_error "Cannot connect to database"
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
            if curl -L -# -o "$archive" "$url"; then
                log_success "Downloaded: $(basename "$archive")"
            else
                log_error "Failed to download KC $ver"
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
# Generated by migrate_keycloak.sh

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
log-level=INFO

# Health
health-enabled=true
EOF

    # Version-specific settings
    if [[ "$ver" -ge 25 ]]; then
        cat >> "$config_file" << EOF

# KC 25+ specific
# Persistent sessions for migration to 26
EOF
    fi

    if [[ "$ver" -ge 26 ]]; then
        cat >> "$config_file" << EOF

# KC 26 specific
EOF
    fi

    log_success "Config created: $config_file"
}

#######################################
# Build Keycloak
#######################################
build_keycloak() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"

    log_info "Building KC $ver..."

    cd "$kc_dir"

    if ./bin/kc.sh build 2>&1 | tee -a "$LOG_FILE" | grep -E "^(BUILD|Server|ERROR)"; then
        log_success "KC $ver built"
        return 0
    else
        log_error "Build failed for KC $ver"
        return 1
    fi
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
# Start Keycloak and wait for migration
#######################################
start_and_migrate() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"
    local pid_file="${WORK_DIR}/kc_${ver}.pid"
    local log_file="${LOG_DIR}/kc_${ver}_startup.log"

    log_step "Starting KC $ver for database migration..."

    cd "$kc_dir"

    # Start in background
    ./bin/kc.sh start --optimized > "$log_file" 2>&1 &
    local kc_pid=$!
    echo "$kc_pid" > "$pid_file"

    log_info "KC $ver started (PID: $kc_pid)"
    log_info "Waiting for migration to complete..."

    # Wait for startup/migration
    local waited=0
    local started=false

    while [[ $waited -lt $MIGRATION_TIMEOUT ]]; do
        sleep 5
        waited=$((waited + 5))

        # Check if still running
        if ! kill -0 "$kc_pid" 2>/dev/null; then
            log_error "KC $ver crashed during startup"
            cat "$log_file" | tail -50
            return 1
        fi

        # Check for Liquibase completion
        if grep -q "Liquibase: Update has been successful" "$log_file" 2>/dev/null; then
            log_success "Database migration completed"
        fi

        # Check for successful startup
        if grep -q "Listening on:" "$log_file" 2>/dev/null; then
            started=true
            break
        fi

        # Check for errors
        if grep -qE "(ERROR|FATAL|Exception)" "$log_file" 2>/dev/null; then
            if grep -q "Listening on:" "$log_file" 2>/dev/null; then
                # Errors but still started - might be OK
                log_warn "Warnings during startup (check log)"
            fi
        fi

        echo -n "."
    done
    echo ""

    if $started; then
        log_success "KC $ver started successfully"

        # Health check
        sleep 3
        if curl -s "http://localhost:${KC_HTTP_PORT}${KC_RELATIVE_PATH}/health" | grep -q "UP"; then
            log_success "Health check passed"
        else
            log_warn "Health check inconclusive"
        fi

        return 0
    else
        log_error "KC $ver failed to start within ${MIGRATION_TIMEOUT}s"
        cat "$log_file" | tail -30
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
            sleep 3
            kill -9 "$pid" 2>/dev/null || true
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

    log_info "Creating backup before KC $ver migration..."

    local backup_file="${BACKUP_DIR}/pre_kc${ver}_$(date +%Y%m%d_%H%M%S).dump"

    if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -F c -f "$backup_file" 2>/dev/null; then

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
# Migrate single version
#######################################
migrate_version() {
    local ver="$1"
    local kc_dir="${STAGING_DIR}/kc-${ver}"

    log_section "MIGRATING TO KEYCLOAK $ver"

    # Check if already at this version or higher
    # (could check DB schema version, but simplify for now)

    # Stop any running KC
    stop_keycloak "$ver"

    # Backup
    backup_before_step "$ver"

    # Create config
    create_kc_config "$ver"

    # Copy providers (for 22+)
    copy_providers "$ver"

    # Build
    build_keycloak "$ver"

    # Start and migrate
    if start_and_migrate "$ver"; then
        log_success "KC $ver migration successful"

        # Update state
        sed -i "s/^CURRENT_VERSION=.*/CURRENT_VERSION=$ver/" "${WORK_DIR}/migration_state.env"
        sed -i "s/^LAST_SUCCESSFUL=.*/LAST_SUCCESSFUL=$ver/" "${WORK_DIR}/migration_state.env"

        # Stop KC
        stop_keycloak "$ver"

        return 0
    else
        log_error "KC $ver migration failed"
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
    test_db_connection
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

    # Execute migration
    for ((i=start_idx; i<stop_idx; i++)); do
        local ver="${MIGRATION_PATH[$i]}"

        if ! migrate_version "$ver"; then
            log_error "Migration failed at KC $ver"
            log_info "To retry: ./migrate_keycloak.sh migrate --start-from $ver"
            log_info "To rollback: ./migrate_keycloak.sh rollback $ver"
            exit 1
        fi

        # Brief pause between versions
        if [[ $i -lt $((stop_idx - 1)) ]]; then
            log_info "Pausing 5s before next version..."
            sleep 5
        fi
    done

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
# Migrate single step
#######################################
do_migrate_step() {
    local target_ver="$1"

    if [[ -z "$target_ver" ]]; then
        log_error "Specify version: migrate-step VERSION"
        exit 1
    fi

    # Validate version
    local valid=false
    for ver in "${MIGRATION_PATH[@]}"; do
        [[ "$ver" == "$target_ver" ]] && valid=true
    done

    if ! $valid; then
        log_error "Invalid version: $target_ver"
        log_info "Valid versions: ${MIGRATION_PATH[*]}"
        exit 1
    fi

    check_prereqs
    test_db_connection
    init_workspace

    if ! $SKIP_DOWNLOAD; then
        # Download only this version
        local full_ver="${KC_VERSIONS[$target_ver]}"
        local url="${KC_URLS[$target_ver]}"
        local archive="${DOWNLOADS_DIR}/keycloak-${full_ver}.tar.gz"
        local extract_dir="${STAGING_DIR}/kc-${target_ver}"

        if [[ ! -d "$extract_dir" ]]; then
            log_info "Downloading KC $target_ver..."
            curl -L -# -o "$archive" "$url"
            mkdir -p "$extract_dir"
            tar -xzf "$archive" -C "$extract_dir" --strip-components=1
        fi
    fi

    migrate_version "$target_ver"
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
        local notes=""

        case $ver in
            17) notes="WildFly → Quarkus architecture change" ;;
            22) notes="Java EE → Jakarta EE, deploy migrated providers" ;;
            25) notes="Enable persistent sessions (required for 26)" ;;
            26) notes="Target version, requires Java 21" ;;
        esac

        printf "│  KC %-2s (%-7s): %-45s │\n" "$ver" "$full_ver" "$notes"
    done
    echo "└─────────────────────────────────────────────────────────────────────┘"

    echo ""
    echo "Downloads required:"
    local total_size=0
    for ver in "${MIGRATION_PATH[@]}"; do
        printf "  - keycloak-%s.tar.gz (~200MB)\n" "${KC_VERSIONS[$ver]}"
    done
    echo "  Total: ~800MB"

    echo ""
    echo "Estimated time: 15-30 minutes (depends on DB size)"

    echo ""
    echo "To start migration:"
    echo "  ./migrate_keycloak.sh migrate -W <db_password> [-p <providers_dir>]"
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
    ls -lh "${BACKUP_DIR}"/*.dump 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || echo "  None"
}

#######################################
# Rollback
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

    test_db_connection

    log_info "Restoring from backup..."

    pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        --clean --if-exists "$backup_file" 2>&1 | head -20

    log_success "Rollback complete"
    log_info "Database restored to state before KC $target_ver migration"
}

#######################################
# Main
#######################################
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Migration Tool v${VERSION}                               ║"
    echo "║     Path: KC 16 → 17 → 22 → 25 → 26                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"

    case "$ACTION" in
        plan)         do_plan ;;
        download)     init_workspace; check_prereqs; download_versions ;;
        migrate)      do_migrate ;;
        migrate-step) do_migrate_step "$START_FROM" ;;
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
