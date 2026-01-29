#!/bin/bash
#
# Keycloak Backup Script
# Version: 1.0.0
#
# Creates full PostgreSQL backup + optional realm export
# Supports restore for rollback
#

set -euo pipefail

VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Defaults
ACTION="backup"
BACKUP_DIR=""
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-keycloak}"
PG_USER="${PG_USER:-keycloak}"
PG_PASS="${PG_PASS:-}"
KEYCLOAK_HOME="${KEYCLOAK_HOME:-}"
KEYCLOAK_URL="${KEYCLOAK_URL:-}"
COMPRESS=true
VERIFY=true
EXPORT_REALMS=false
RESTORE_FILE=""
PARALLEL_JOBS=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }

#######################################
# Usage
#######################################
usage() {
    cat << EOF
Keycloak Backup & Restore Tool v${VERSION}

Usage: $(basename "$0") [ACTION] [OPTIONS]

Actions:
  backup              Create backup (default)
  restore             Restore from backup
  verify              Verify backup integrity
  list                List available backups

Options:
  -h, --help              Show this help
  -d, --backup-dir DIR    Backup directory (default: ../backups/)
  -H, --pg-host HOST      PostgreSQL host (default: localhost)
  -P, --pg-port PORT      PostgreSQL port (default: 5432)
  -D, --pg-database DB    PostgreSQL database (default: keycloak)
  -U, --pg-user USER      PostgreSQL user (default: keycloak)
  -W, --pg-password PASS  PostgreSQL password
  -k, --keycloak-home DIR Keycloak installation (for realm export)
  --keycloak-url URL      Keycloak URL (for realm export via API)
  --export-realms         Also export realms to JSON
  --no-compress           Don't compress backup
  --no-verify             Skip backup verification
  --restore-file FILE     File to restore from
  -j, --jobs N            Parallel jobs for pg_dump (default: 4)

Examples:
  # Simple backup
  ./backup_keycloak.sh backup -W mypassword

  # Backup with realm export
  ./backup_keycloak.sh backup -W mypassword --export-realms -k /opt/keycloak

  # Restore from backup
  ./backup_keycloak.sh restore --restore-file backups/keycloak_20260128_120000.dump

  # List backups
  ./backup_keycloak.sh list

  # Verify backup
  ./backup_keycloak.sh verify --restore-file backups/keycloak_20260128_120000.dump

EOF
    exit 0
}

#######################################
# Parse arguments
#######################################
parse_args() {
    # First arg might be action
    if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
        ACTION="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -d|--backup-dir) BACKUP_DIR="$2"; shift 2 ;;
            -H|--pg-host) PG_HOST="$2"; shift 2 ;;
            -P|--pg-port) PG_PORT="$2"; shift 2 ;;
            -D|--pg-database) PG_DB="$2"; shift 2 ;;
            -U|--pg-user) PG_USER="$2"; shift 2 ;;
            -W|--pg-password) PG_PASS="$2"; shift 2 ;;
            -k|--keycloak-home) KEYCLOAK_HOME="$2"; shift 2 ;;
            --keycloak-url) KEYCLOAK_URL="$2"; shift 2 ;;
            --export-realms) EXPORT_REALMS=true; shift ;;
            --no-compress) COMPRESS=false; shift ;;
            --no-verify) VERIFY=false; shift ;;
            --restore-file) RESTORE_FILE="$2"; shift 2 ;;
            -j|--jobs) PARALLEL_JOBS="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Set default backup dir
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="${SCRIPT_DIR}/../backups"
    fi

    mkdir -p "$BACKUP_DIR"
}

#######################################
# Check prerequisites
#######################################
check_prereqs() {
    local missing=()

    command -v pg_dump >/dev/null 2>&1 || missing+=("pg_dump")
    command -v pg_restore >/dev/null 2>&1 || missing+=("pg_restore")
    command -v psql >/dev/null 2>&1 || missing+=("psql")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: apt install postgresql-client"
        exit 1
    fi

    # Check disk space (need at least 2x database size)
    local available_gb=$(df -BG "$BACKUP_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "$available_gb" -lt 5 ]]; then
        log_warn "Low disk space: ${available_gb}GB available in $BACKUP_DIR"
    fi
}

#######################################
# Test PostgreSQL connection
#######################################
test_connection() {
    log_info "Testing PostgreSQL connection..."

    if [[ -z "$PG_PASS" ]]; then
        read -r -s -p "PostgreSQL password for $PG_USER: " PG_PASS
        echo ""
    fi

    export PGPASSWORD="$PG_PASS"

    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
        log_success "PostgreSQL connection OK"
    else
        log_error "Cannot connect to PostgreSQL"
        log_info "Check: host=$PG_HOST port=$PG_PORT db=$PG_DB user=$PG_USER"
        exit 1
    fi
}

#######################################
# Get database info
#######################################
get_db_info() {
    log_info "Gathering database info..."

    local db_size=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT pg_size_pretty(pg_database_size('$PG_DB'));" | tr -d ' ')

    local table_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d ' ')

    local user_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT COUNT(*) FROM user_entity;" 2>/dev/null | tr -d ' ' || echo "N/A")

    local realm_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT COUNT(*) FROM realm;" 2>/dev/null | tr -d ' ' || echo "N/A")

    echo ""
    echo "┌─────────────────────────────────────┐"
    echo "│        DATABASE INFO                │"
    echo "├─────────────────────────────────────┤"
    echo "│  Host:     $PG_HOST:$PG_PORT"
    echo "│  Database: $PG_DB"
    echo "│  Size:     $db_size"
    echo "│  Tables:   $table_count"
    echo "│  Users:    $user_count"
    echo "│  Realms:   $realm_count"
    echo "└─────────────────────────────────────┘"
    echo ""

    DB_SIZE="$db_size"
}

#######################################
# Create backup
#######################################
do_backup() {
    log_section "CREATING BACKUP"

    test_connection
    get_db_info

    local backup_name="keycloak_${PG_DB}_${TIMESTAMP}"
    local dump_file="${BACKUP_DIR}/${backup_name}.dump"
    local sql_file="${BACKUP_DIR}/${backup_name}.sql"
    local meta_file="${BACKUP_DIR}/${backup_name}.meta"

    # Create metadata file
    cat > "$meta_file" << EOF
# Keycloak Backup Metadata
backup_date=$(date -Iseconds)
backup_tool=backup_keycloak.sh v${VERSION}
pg_host=$PG_HOST
pg_port=$PG_PORT
pg_database=$PG_DB
pg_user=$PG_USER
db_size=$DB_SIZE
keycloak_home=$KEYCLOAK_HOME
EOF

    # Main backup (custom format for parallel restore)
    log_info "Creating PostgreSQL dump (custom format)..."
    local start_time=$(date +%s)

    if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -F c \
        -j "$PARALLEL_JOBS" \
        -f "$dump_file" \
        --verbose 2>&1 | grep -E "^pg_dump:"; then
        :
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ -f "$dump_file" ]]; then
        local dump_size=$(du -h "$dump_file" | cut -f1)
        log_success "Dump created: $dump_file ($dump_size) in ${duration}s"
        echo "dump_file=$dump_file" >> "$meta_file"
        echo "dump_size=$dump_size" >> "$meta_file"
        echo "dump_duration=${duration}s" >> "$meta_file"
    else
        log_error "Dump failed!"
        exit 1
    fi

    # Also create plain SQL backup (for manual review/partial restore)
    log_info "Creating plain SQL backup..."
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -F p \
        -f "$sql_file" 2>/dev/null

    if [[ -f "$sql_file" ]]; then
        local sql_size=$(du -h "$sql_file" | cut -f1)
        log_success "SQL backup: $sql_file ($sql_size)"
        echo "sql_file=$sql_file" >> "$meta_file"
    fi

    # Compress if requested
    if $COMPRESS; then
        log_info "Compressing backups..."

        if command -v pigz >/dev/null 2>&1; then
            # Parallel gzip
            pigz -k "$sql_file"
        else
            gzip -k "$sql_file"
        fi

        if [[ -f "${sql_file}.gz" ]]; then
            local gz_size=$(du -h "${sql_file}.gz" | cut -f1)
            log_success "Compressed: ${sql_file}.gz ($gz_size)"
            rm -f "$sql_file"  # Remove uncompressed
        fi
    fi

    # Verify backup
    if $VERIFY; then
        log_info "Verifying backup integrity..."

        local toc_count=$(pg_restore -l "$dump_file" 2>/dev/null | wc -l)

        if [[ "$toc_count" -gt 10 ]]; then
            log_success "Backup verified: $toc_count objects in TOC"
            echo "verified=true" >> "$meta_file"
            echo "toc_objects=$toc_count" >> "$meta_file"
        else
            log_warn "Backup may be incomplete: only $toc_count objects"
            echo "verified=warning" >> "$meta_file"
        fi
    fi

    # Export realms if requested
    if $EXPORT_REALMS; then
        export_realms "${BACKUP_DIR}/${backup_name}_realms"
    fi

    # Summary
    log_section "BACKUP COMPLETE"

    echo "Files created:"
    ls -lh "${BACKUP_DIR}/${backup_name}"* 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'

    echo ""
    echo "Metadata: $meta_file"
    echo ""
    echo "To restore:"
    echo "  ./backup_keycloak.sh restore --restore-file $dump_file"
}

#######################################
# Export realms
#######################################
export_realms() {
    local output_dir="$1"
    mkdir -p "$output_dir"

    log_info "Exporting realms..."

    if [[ -n "$KEYCLOAK_HOME" ]] && [[ -d "$KEYCLOAK_HOME" ]]; then
        # Export via standalone.sh (KC must be stopped, then started with export flags)
        log_warn "Realm export via CLI requires KC restart"
        log_info "Manual export command:"
        echo ""
        echo "  cd $KEYCLOAK_HOME"
        echo "  ./bin/standalone.sh \\"
        echo "    -Dkeycloak.migration.action=export \\"
        echo "    -Dkeycloak.migration.provider=dir \\"
        echo "    -Dkeycloak.migration.dir=$output_dir \\"
        echo "    -Dkeycloak.migration.usersExportStrategy=DIFFERENT_FILES"
        echo ""

    elif [[ -n "$KEYCLOAK_URL" ]]; then
        # Export via Admin API
        log_info "Exporting via Admin API: $KEYCLOAK_URL"

        # Get token (requires admin credentials)
        read -r -p "Admin username: " admin_user
        read -r -s -p "Admin password: " admin_pass
        echo ""

        local token=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            -d "username=$admin_user" \
            -d "password=$admin_pass" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

        if [[ -z "$token" ]]; then
            log_error "Failed to get admin token"
            return 1
        fi

        # Get list of realms
        local realms=$(curl -s "${KEYCLOAK_URL}/admin/realms" \
            -H "Authorization: Bearer $token" | grep -o '"realm":"[^"]*' | cut -d'"' -f4)

        for realm in $realms; do
            log_info "Exporting realm: $realm"

            curl -s "${KEYCLOAK_URL}/admin/realms/$realm" \
                -H "Authorization: Bearer $token" \
                > "${output_dir}/${realm}.json"

            if [[ -s "${output_dir}/${realm}.json" ]]; then
                log_success "Exported: ${realm}.json"
            fi
        done
    else
        log_warn "No KEYCLOAK_HOME or KEYCLOAK_URL provided, skipping realm export"
        log_info "Add --keycloak-home or --keycloak-url to enable"
    fi
}

#######################################
# Restore backup
#######################################
do_restore() {
    log_section "RESTORING BACKUP"

    if [[ -z "$RESTORE_FILE" ]]; then
        log_error "No restore file specified. Use --restore-file"
        exit 1
    fi

    if [[ ! -f "$RESTORE_FILE" ]]; then
        log_error "File not found: $RESTORE_FILE"
        exit 1
    fi

    test_connection
    get_db_info

    echo ""
    echo -e "${RED}${BOLD}WARNING: This will OVERWRITE the current database!${NC}"
    echo ""
    echo "  Database: $PG_DB @ $PG_HOST"
    echo "  Restore from: $RESTORE_FILE"
    echo ""
    read -r -p "Type 'YES' to confirm: " confirm

    if [[ "$confirm" != "YES" ]]; then
        log_info "Restore cancelled"
        exit 0
    fi

    # Create pre-restore backup
    log_info "Creating pre-restore backup..."
    local pre_restore="${BACKUP_DIR}/pre_restore_${TIMESTAMP}.dump"
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -F c -f "$pre_restore"
    log_success "Pre-restore backup: $pre_restore"

    # Drop and recreate database
    log_info "Preparing database..."

    # Terminate connections
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_DB' AND pid <> pg_backend_pid();" \
        >/dev/null 2>&1 || true

    # Restore
    log_info "Restoring from backup..."
    local start_time=$(date +%s)

    if pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        --clean \
        --if-exists \
        -j "$PARALLEL_JOBS" \
        "$RESTORE_FILE" 2>&1 | grep -E "^pg_restore:" | head -20; then
        :
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Restore completed in ${duration}s"

    # Verify
    log_info "Verifying restore..."
    local table_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d ' ')

    log_success "Verified: $table_count tables restored"

    echo ""
    echo "Restore complete. Start Keycloak to verify."
    echo "If issues, restore pre-restore backup:"
    echo "  ./backup_keycloak.sh restore --restore-file $pre_restore"
}

#######################################
# Verify backup
#######################################
do_verify() {
    log_section "VERIFYING BACKUP"

    if [[ -z "$RESTORE_FILE" ]]; then
        log_error "No file specified. Use --restore-file"
        exit 1
    fi

    if [[ ! -f "$RESTORE_FILE" ]]; then
        log_error "File not found: $RESTORE_FILE"
        exit 1
    fi

    log_info "File: $RESTORE_FILE"
    log_info "Size: $(du -h "$RESTORE_FILE" | cut -f1)"

    # Check format
    local file_type=$(file "$RESTORE_FILE" | cut -d: -f2)
    log_info "Type: $file_type"

    # List contents
    log_info "Checking TOC..."
    local toc=$(pg_restore -l "$RESTORE_FILE" 2>/dev/null)
    local toc_count=$(echo "$toc" | wc -l)

    echo ""
    echo "Objects in backup: $toc_count"
    echo ""
    echo "Tables:"
    echo "$toc" | grep "TABLE " | head -20 | awk '{print "  " $0}'
    echo ""

    if [[ "$toc_count" -gt 50 ]]; then
        log_success "Backup appears valid"
    else
        log_warn "Backup may be incomplete"
    fi
}

#######################################
# List backups
#######################################
do_list() {
    log_section "AVAILABLE BACKUPS"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "No backup directory: $BACKUP_DIR"
        exit 0
    fi

    echo "Directory: $BACKUP_DIR"
    echo ""

    local found=false

    for meta in "$BACKUP_DIR"/*.meta; do
        [[ ! -f "$meta" ]] && continue
        found=true

        local base=$(basename "$meta" .meta)
        local dump_file="${BACKUP_DIR}/${base}.dump"

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Backup: $base"

        if [[ -f "$meta" ]]; then
            grep -E "^(backup_date|db_size|dump_size|verified)=" "$meta" | while read -r line; do
                echo "  $line"
            done
        fi

        if [[ -f "$dump_file" ]]; then
            echo "  dump_file=$dump_file ($(du -h "$dump_file" | cut -f1))"
        fi

        echo ""
    done

    if [[ "$found" == "false" ]]; then
        log_info "No backups found"
    fi
}

#######################################
# Main
#######################################
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Backup & Restore Tool v${VERSION}                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"
    check_prereqs

    case "$ACTION" in
        backup)  do_backup ;;
        restore) do_restore ;;
        verify)  do_verify ;;
        list)    do_list ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
}

main "$@"
