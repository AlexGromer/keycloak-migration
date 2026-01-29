#!/bin/bash
#
# Pre-flight Checks for Keycloak Migration
# Validates environment before starting migration
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
KEYCLOAK_HOME="${KEYCLOAK_HOME:-}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-keycloak}"
PG_USER="${PG_USER:-keycloak}"
PG_PASS="${PG_PASS:-}"
WORK_DIR="${WORK_DIR:-../migration_workspace}"

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; ((CHECKS_PASSED++)); }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; ((CHECKS_WARNING++)); }
log_error() { echo -e "${RED}[✗]${NC} $1"; ((CHECKS_FAILED++)); }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }

#######################################
# Checks
#######################################
check_command() {
    local cmd="$1"
    local package="${2:-$1}"

    if command -v "$cmd" >/dev/null 2>&1; then
        local version=$($cmd --version 2>&1 | head -1 || echo "unknown")
        log_success "$cmd available ($version)"
        return 0
    else
        log_error "$cmd not found (install: $package)"
        return 1
    fi
}

check_java_versions() {
    log_section "JAVA VERSIONS"

    local java_found=false

    # Check default java
    if command -v java >/dev/null 2>&1; then
        local default_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
        log_info "Default Java: $default_version"
        java_found=true
    fi

    # Check for multiple Java versions
    for ver in 11 17 21; do
        if command -v java-$ver >/dev/null 2>&1 || [[ -d "/usr/lib/jvm/java-${ver}-openjdk-amd64" ]]; then
            log_success "Java $ver available"
            java_found=true
        else
            log_warn "Java $ver not found (required for KC ${ver}+)"
        fi
    done

    if ! $java_found; then
        log_error "No Java installation found"
        return 1
    fi

    # Check if Java 21 is available (required for KC 26)
    if command -v java-21 >/dev/null 2>&1 || [[ -d "/usr/lib/jvm/java-21-openjdk-amd64" ]]; then
        log_success "Java 21 available (required for KC 26)"
        return 0
    else
        log_error "Java 21 not found — REQUIRED for KC 26"
        echo "  Install: sudo apt install openjdk-21-jdk"
        return 1
    fi
}

check_postgresql_connection() {
    log_section "POSTGRESQL CONNECTION"

    if [[ -z "$PG_PASS" ]]; then
        read -r -s -p "PostgreSQL password for $PG_USER: " PG_PASS
        echo ""
    fi

    export PGPASSWORD="$PG_PASS"

    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
        log_success "PostgreSQL connection OK"

        # Get PostgreSQL version
        local pg_version=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
            "SHOW server_version;" 2>/dev/null | awk '{print $1}' | cut -d. -f1)

        if [[ -n "$pg_version" ]]; then
            log_info "PostgreSQL version: $pg_version"

            if [[ "$pg_version" -ge 12 ]]; then
                log_success "PostgreSQL version OK (12+)"
            else
                log_warn "PostgreSQL $pg_version is old (recommend 12+)"
            fi
        fi

        # Get database size
        local db_size=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
            "SELECT pg_size_pretty(pg_database_size('$PG_DB'));" 2>/dev/null | tr -d ' ')

        if [[ -n "$db_size" ]]; then
            log_info "Database size: $db_size"
        fi

        return 0
    else
        log_error "Cannot connect to PostgreSQL"
        log_info "Check: host=$PG_HOST port=$PG_PORT db=$PG_DB user=$PG_USER"
        return 1
    fi
}

check_disk_space() {
    log_section "DISK SPACE"

    local required_gb=15
    local target_path="$WORK_DIR"

    [[ ! -d "$target_path" ]] && target_path="$(dirname "$target_path")"

    local available_gb=$(df -BG "$target_path" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")

    log_info "Working directory: $target_path"
    log_info "Available space: ${available_gb}GB"
    log_info "Required space: ${required_gb}GB"

    if [[ "${available_gb:-0}" -ge "$required_gb" ]]; then
        log_success "Disk space OK (${available_gb}GB available)"
        return 0
    else
        log_error "Insufficient disk space: ${available_gb}GB < ${required_gb}GB"
        echo "  Need: 4×800MB (KC downloads) + 3GB (backups) + 5GB (buffer)"
        return 1
    fi
}

check_memory() {
    log_section "SYSTEM MEMORY"

    local total_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    local available_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $7}' || echo "0")

    log_info "Total memory: ${total_mem}GB"
    log_info "Available memory: ${available_mem}GB"

    if [[ "$total_mem" -ge 8 ]]; then
        log_success "Memory OK (${total_mem}GB total)"
        return 0
    elif [[ "$total_mem" -ge 4 ]]; then
        log_warn "Low memory: ${total_mem}GB (recommend 8GB+)"
        log_info "Migration may be slow or fail with OOM"
        return 0
    else
        log_error "Insufficient memory: ${total_mem}GB (minimum 4GB)"
        return 1
    fi
}

check_keycloak_home() {
    log_section "KEYCLOAK INSTALLATION"

    if [[ -z "$KEYCLOAK_HOME" ]]; then
        log_warn "KEYCLOAK_HOME not set"
        log_info "Discovery will require manual path input"
        return 0
    fi

    if [[ ! -d "$KEYCLOAK_HOME" ]]; then
        log_error "KEYCLOAK_HOME directory not found: $KEYCLOAK_HOME"
        return 1
    fi

    log_success "KEYCLOAK_HOME: $KEYCLOAK_HOME"

    # Check version
    if [[ -f "$KEYCLOAK_HOME/version.txt" ]]; then
        local kc_version=$(cat "$KEYCLOAK_HOME/version.txt")
        log_info "Keycloak version: $kc_version"

        if [[ "$kc_version" =~ ^16\. ]]; then
            log_success "KC version OK (16.x)"
        else
            log_warn "Unexpected KC version: $kc_version (expected 16.x)"
        fi
    else
        log_warn "Cannot detect KC version (version.txt missing)"
    fi

    # Check for WildFly (KC 16 should use WildFly)
    if [[ -d "$KEYCLOAK_HOME/standalone" ]]; then
        log_success "WildFly structure detected (KC 16 compatible)"
    else
        log_warn "WildFly structure not found (expected for KC 16)"
    fi

    return 0
}

check_required_tools() {
    log_section "REQUIRED TOOLS"

    check_command curl curl
    check_command tar tar
    check_command unzip unzip
    check_command psql postgresql-client
    check_command pg_dump postgresql-client
    check_command pg_restore postgresql-client
    check_command jq jq
}

check_optional_tools() {
    log_section "OPTIONAL TOOLS (for better performance)"

    if command -v pigz >/dev/null 2>&1; then
        log_success "pigz available (parallel gzip)"
    else
        log_info "pigz not found (optional, for faster compression)"
        log_info "  Install: sudo apt install pigz"
    fi

    if command -v pv >/dev/null 2>&1; then
        log_success "pv available (progress viewer)"
    else
        log_info "pv not found (optional, for progress bars)"
        log_info "  Install: sudo apt install pv"
    fi
}

check_network() {
    log_section "NETWORK CONNECTIVITY"

    # Check GitHub (for downloading KC versions)
    if curl -sf --max-time 10 https://github.com &>/dev/null; then
        log_success "GitHub accessible (for KC downloads)"
    else
        log_error "Cannot reach GitHub (required for downloading KC versions)"
        log_info "If using pre-downloaded versions, use --skip-download"
        return 1
    fi

    # Check Maven Central (for Eclipse Transformer)
    if curl -sf --max-time 10 https://repo1.maven.org &>/dev/null; then
        log_success "Maven Central accessible (for Eclipse Transformer)"
    else
        log_warn "Cannot reach Maven Central (optional, for provider transformation)"
    fi

    return 0
}

check_postgresql_permissions() {
    log_section "POSTGRESQL PERMISSIONS"

    if [[ -z "$PG_PASS" ]]; then
        log_info "Skipping permission check (no password provided)"
        return 0
    fi

    export PGPASSWORD="$PG_PASS"

    # Check if user has necessary privileges
    local has_create=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT has_database_privilege(current_user, '$PG_DB', 'CREATE');" 2>/dev/null | tr -d ' ')

    local has_pg_class=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c \
        "SELECT has_table_privilege(current_user, 'pg_class', 'SELECT');" 2>/dev/null | tr -d ' ')

    if [[ "$has_create" == "t" ]]; then
        log_success "User has CREATE privilege"
    else
        log_warn "User lacks CREATE privilege (may slow down migration)"
    fi

    if [[ "$has_pg_class" == "t" ]]; then
        log_success "User can access pg_class (efficient upgrades)"
    else
        log_warn "User cannot access pg_class (upgrades will be slower)"
    fi

    return 0
}

#######################################
# Summary
#######################################
print_summary() {
    log_section "PRE-FLIGHT CHECK SUMMARY"

    echo ""
    echo "Checks passed:   ${GREEN}$CHECKS_PASSED${NC}"
    echo "Checks warned:   ${YELLOW}$CHECKS_WARNING${NC}"
    echo "Checks failed:   ${RED}$CHECKS_FAILED${NC}"
    echo ""

    if [[ $CHECKS_FAILED -eq 0 ]] && [[ $CHECKS_WARNING -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ ALL CHECKS PASSED — READY FOR MIGRATION${NC}"
        echo ""
        return 0
    elif [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${YELLOW}${BOLD}! WARNINGS DETECTED — REVIEW BEFORE PROCEEDING${NC}"
        echo ""
        echo "Migration can proceed, but consider addressing warnings for better results."
        return 0
    else
        echo -e "${RED}${BOLD}✗ CRITICAL ISSUES DETECTED — FIX BEFORE MIGRATION${NC}"
        echo ""
        echo "Address all failed checks before starting migration."
        return 1
    fi
}

#######################################
# Main
#######################################
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Migration Pre-flight Checks                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_required_tools
    check_java_versions
    check_postgresql_connection
    check_disk_space
    check_memory
    check_keycloak_home
    check_optional_tools
    check_network
    check_postgresql_permissions

    print_summary
}

main "$@"
