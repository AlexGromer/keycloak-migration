#!/usr/bin/env bash
# Preflight Checks — Production Safety (v3.5)
# Comprehensive pre-migration validation

set -euo pipefail

# ============================================================================
# PREFLIGHT CHECK CATEGORIES
# ============================================================================

# 1. System Resources (disk, memory, network)
# 2. Database Health (connectivity, version, replication)
# 3. Keycloak Health (status, connectivity, admin API)
# 4. Backup Verification (space, permissions, integrity)
# 5. Dependencies (Java, tools, libraries)
# 6. Configuration Validation (profiles, credentials)

# ============================================================================
# CONSTANTS
# ============================================================================

readonly MIN_DISK_SPACE_GB=10        # Minimum free disk space (GB)
readonly MIN_MEMORY_GB=2             # Minimum free memory (GB)
readonly MIN_BACKUP_SPACE_MULTIPLIER=3  # Backup space = DB size × 3
readonly NETWORK_TIMEOUT=5           # Network connectivity timeout (seconds)
readonly DB_HEALTH_TIMEOUT=10        # Database health check timeout (seconds)

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_DISK_SPACE=10
readonly EXIT_MEMORY=11
readonly EXIT_NETWORK=12
readonly EXIT_DB_HEALTH=13
readonly EXIT_KEYCLOAK_HEALTH=14
readonly EXIT_DEPENDENCIES=15
readonly EXIT_CONFIG=16

# ============================================================================
# LOGGING
# ============================================================================

preflight_log_info() {
    echo "[PREFLIGHT INFO] $1"
}

preflight_log_success() {
    echo "[✓ PREFLIGHT] $1"
}

preflight_log_warn() {
    echo "[⚠ PREFLIGHT WARNING] $1" >&2
}

preflight_log_error() {
    echo "[✗ PREFLIGHT ERROR] $1" >&2
}

preflight_log_section() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

# ============================================================================
# 1. SYSTEM RESOURCE CHECKS
# ============================================================================

check_disk_space() {
    preflight_log_section "1. DISK SPACE CHECK"

    local backup_dir="${1:-/tmp}"
    local required_space_gb="${2:-$MIN_DISK_SPACE_GB}"

    preflight_log_info "Checking disk space on: $backup_dir"
    preflight_log_info "Required: ${required_space_gb}GB minimum"

    # Get available space in GB
    local available_space_gb
    available_space_gb=$(df -BG "$backup_dir" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')

    preflight_log_info "Available space: ${available_space_gb}GB"

    if (( available_space_gb < required_space_gb )); then
        preflight_log_error "Insufficient disk space: ${available_space_gb}GB < ${required_space_gb}GB"
        preflight_log_error "Free up space or specify different backup location"
        return $EXIT_DISK_SPACE
    fi

    preflight_log_success "Disk space: ${available_space_gb}GB (OK)"
    return 0
}

check_memory() {
    preflight_log_section "2. MEMORY CHECK"

    local required_memory_gb="${1:-$MIN_MEMORY_GB}"

    preflight_log_info "Required free memory: ${required_memory_gb}GB minimum"

    # Get available memory in GB
    local available_memory_gb
    available_memory_gb=$(free -g | awk '/^Mem:/ {print $7}')

    # Fallback if 'free -g' returns 0 (small systems)
    if [[ "$available_memory_gb" == "0" ]]; then
        available_memory_gb=$(free -m | awk '/^Mem:/ {printf "%.1f", $7/1024}')
    fi

    preflight_log_info "Available memory: ${available_memory_gb}GB"

    if (( $(echo "$available_memory_gb < $required_memory_gb" | bc -l 2>/dev/null || echo "0") )); then
        preflight_log_warn "Low memory: ${available_memory_gb}GB < ${required_memory_gb}GB"
        preflight_log_warn "Migration may be slower or fail under load"
        # Warning only, not fatal
    else
        preflight_log_success "Memory: ${available_memory_gb}GB (OK)"
    fi

    return 0
}

check_network_connectivity() {
    preflight_log_section "3. NETWORK CONNECTIVITY CHECK"

    local host="${1}"
    local port="${2}"

    preflight_log_info "Testing connectivity to: $host:$port"

    # Test using timeout and nc (netcat) or bash built-in
    if command -v nc >/dev/null 2>&1; then
        if timeout "$NETWORK_TIMEOUT" nc -zv "$host" "$port" 2>&1 | grep -q "succeeded\|open"; then
            preflight_log_success "Network: $host:$port (reachable)"
            return 0
        fi
    else
        # Fallback: bash TCP test
        if timeout "$NETWORK_TIMEOUT" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
            preflight_log_success "Network: $host:$port (reachable)"
            return 0
        fi
    fi

    preflight_log_error "Network: $host:$port (UNREACHABLE)"
    preflight_log_error "Check firewall, network configuration, or hostname resolution"
    return $EXIT_NETWORK
}

# ============================================================================
# 2. DATABASE HEALTH CHECKS
# ============================================================================

check_database_connectivity() {
    preflight_log_section "4. DATABASE CONNECTIVITY CHECK"

    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"

    preflight_log_info "Database: $db_type at $host:$port/$db_name"
    preflight_log_info "User: $user"

    case "$db_type" in
        postgresql)
            if PGPASSWORD="$pass" timeout "$DB_HEALTH_TIMEOUT" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
                preflight_log_success "PostgreSQL: Connected"
                return 0
            else
                preflight_log_error "PostgreSQL: Connection failed"
                return $EXIT_DB_HEALTH
            fi
            ;;
        mysql|mariadb)
            if timeout "$DB_HEALTH_TIMEOUT" mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" -e "SELECT 1;" >/dev/null 2>&1; then
                preflight_log_success "MySQL/MariaDB: Connected"
                return 0
            else
                preflight_log_error "MySQL/MariaDB: Connection failed"
                return $EXIT_DB_HEALTH
            fi
            ;;
        cockroachdb)
            if PGPASSWORD="$pass" timeout "$DB_HEALTH_TIMEOUT" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
                preflight_log_success "CockroachDB: Connected"
                return 0
            else
                preflight_log_error "CockroachDB: Connection failed"
                return $EXIT_DB_HEALTH
            fi
            ;;
        *)
            preflight_log_warn "Database type '$db_type' not supported for health check"
            return 0
            ;;
    esac
}

check_database_version() {
    preflight_log_section "5. DATABASE VERSION CHECK"

    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"

    local version=""

    case "$db_type" in
        postgresql)
            version=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT version();" 2>/dev/null | head -1)
            preflight_log_info "PostgreSQL Version: $version"
            ;;
        mysql|mariadb)
            version=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" -e "SELECT VERSION();" -s -N 2>/dev/null)
            preflight_log_info "MySQL/MariaDB Version: $version"
            ;;
        cockroachdb)
            version=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT version();" 2>/dev/null | head -1)
            preflight_log_info "CockroachDB Version: $version"
            ;;
        *)
            preflight_log_warn "Database type '$db_type' not supported for version check"
            return 0
            ;;
    esac

    if [[ -z "$version" ]]; then
        preflight_log_warn "Could not retrieve database version"
    else
        preflight_log_success "Database version: OK"
    fi

    return 0
}

check_database_size() {
    preflight_log_section "6. DATABASE SIZE CHECK"

    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"

    local size_bytes=0
    local size_gb=0

    case "$db_type" in
        postgresql)
            size_bytes=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' ')
            ;;
        mysql|mariadb)
            size_bytes=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" -e "SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema = '$db_name';" -s -N 2>/dev/null)
            ;;
        cockroachdb)
            size_bytes=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' ')
            ;;
        *)
            preflight_log_warn "Database type '$db_type' not supported for size check"
            return 0
            ;;
    esac

    if [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]; then
        size_gb=$(echo "scale=2; $size_bytes / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
        preflight_log_info "Database size: ${size_gb}GB"
        preflight_log_success "Database size check: OK"

        # Export for backup space calculation
        export PREFLIGHT_DB_SIZE_GB="$size_gb"
    else
        preflight_log_warn "Could not retrieve database size"
        export PREFLIGHT_DB_SIZE_GB="10"  # Default fallback
    fi

    return 0
}

check_database_replication() {
    preflight_log_section "7. DATABASE REPLICATION CHECK"

    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"

    local is_replica=false
    local replication_lag=""

    case "$db_type" in
        postgresql)
            # Check if this is a replica
            is_replica=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')

            if [[ "$is_replica" == "t" ]]; then
                preflight_log_warn "Database is a READ REPLICA"
                preflight_log_warn "Migration should be performed on PRIMARY instance"

                # Check replication lag
                replication_lag=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" 2>/dev/null | tr -d ' ')

                if [[ -n "$replication_lag" ]]; then
                    preflight_log_info "Replication lag: ${replication_lag}s"
                fi
            else
                preflight_log_success "Database is PRIMARY instance: OK"
            fi
            ;;
        mysql|mariadb)
            # Check slave status
            local slave_status
            slave_status=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "SHOW SLAVE STATUS\G" 2>/dev/null)

            if [[ -n "$slave_status" ]]; then
                preflight_log_warn "Database is a REPLICA"
                preflight_log_warn "Migration should be performed on PRIMARY instance"

                # Extract seconds behind master
                replication_lag=$(echo "$slave_status" | grep "Seconds_Behind_Master:" | awk '{print $2}')
                if [[ -n "$replication_lag" && "$replication_lag" != "NULL" ]]; then
                    preflight_log_info "Replication lag: ${replication_lag}s"
                fi
            else
                preflight_log_success "Database is PRIMARY instance: OK"
            fi
            ;;
        cockroachdb)
            # CockroachDB is distributed, check cluster health instead
            preflight_log_info "CockroachDB: Multi-region cluster (no single replica concept)"
            ;;
        *)
            preflight_log_warn "Database type '$db_type' not supported for replication check"
            return 0
            ;;
    esac

    return 0
}

# ============================================================================
# 3. KEYCLOAK HEALTH CHECKS
# ============================================================================

check_keycloak_status() {
    preflight_log_section "8. KEYCLOAK STATUS CHECK"

    local kc_url="${1}"

    preflight_log_info "Keycloak URL: $kc_url"

    # Try to reach Keycloak health endpoint
    if command -v curl >/dev/null 2>&1; then
        local health_url="${kc_url}/health"

        if curl -f -s -o /dev/null -w "%{http_code}" "$health_url" --max-time 10 | grep -q "200\|404"; then
            preflight_log_success "Keycloak: Reachable"
        else
            preflight_log_warn "Keycloak: Not reachable at $health_url"
            preflight_log_warn "This may be expected if Keycloak is stopped for migration"
        fi
    else
        preflight_log_warn "curl not found, skipping Keycloak health check"
    fi

    return 0
}

check_keycloak_admin_credentials() {
    preflight_log_section "9. KEYCLOAK ADMIN CREDENTIALS CHECK"

    local kc_url="${1}"
    local admin_user="${2}"
    local admin_pass="${3}"

    preflight_log_info "Testing admin credentials for: $admin_user"

    # Try to get admin token (only if Keycloak is running)
    if command -v curl >/dev/null 2>&1; then
        local token_url="${kc_url}/realms/master/protocol/openid-connect/token"

        local response
        response=$(curl -f -s -X POST "$token_url" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=$admin_user" \
            -d "password=$admin_pass" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            --max-time 10 2>/dev/null)

        if echo "$response" | grep -q "access_token"; then
            preflight_log_success "Admin credentials: Valid"
        else
            preflight_log_warn "Admin credentials: Could not verify"
            preflight_log_warn "This may be expected if Keycloak is stopped"
        fi
    else
        preflight_log_warn "curl not found, skipping admin credentials check"
    fi

    return 0
}

# ============================================================================
# 4. BACKUP VERIFICATION
# ============================================================================

check_backup_space() {
    preflight_log_section "10. BACKUP SPACE CHECK"

    local backup_dir="${1}"
    local db_size_gb="${PREFLIGHT_DB_SIZE_GB:-10}"

    # Calculate required backup space (DB size × 3 for safety)
    local required_space_gb
    required_space_gb=$(echo "scale=0; $db_size_gb * $MIN_BACKUP_SPACE_MULTIPLIER" | bc -l 2>/dev/null || echo "30")

    preflight_log_info "Database size: ${db_size_gb}GB"
    preflight_log_info "Required backup space: ${required_space_gb}GB (3x DB size)"

    # Check available space
    local available_space_gb
    available_space_gb=$(df -BG "$backup_dir" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')

    preflight_log_info "Available space: ${available_space_gb}GB"

    if (( available_space_gb < required_space_gb )); then
        preflight_log_error "Insufficient backup space: ${available_space_gb}GB < ${required_space_gb}GB"
        return $EXIT_DISK_SPACE
    fi

    preflight_log_success "Backup space: ${available_space_gb}GB (OK)"
    return 0
}

check_backup_permissions() {
    preflight_log_section "11. BACKUP DIRECTORY PERMISSIONS CHECK"

    local backup_dir="${1}"

    preflight_log_info "Backup directory: $backup_dir"

    # Create backup dir if not exists
    if [[ ! -d "$backup_dir" ]]; then
        if mkdir -p "$backup_dir" 2>/dev/null; then
            preflight_log_info "Created backup directory: $backup_dir"
        else
            preflight_log_error "Cannot create backup directory: $backup_dir"
            return $EXIT_CONFIG
        fi
    fi

    # Test write permissions
    local test_file="$backup_dir/.preflight_write_test_$$"
    if echo "test" > "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        preflight_log_success "Backup directory: Writable"
    else
        preflight_log_error "Backup directory: Not writable"
        preflight_log_error "Check permissions on: $backup_dir"
        return $EXIT_CONFIG
    fi

    return 0
}

# ============================================================================
# 5. DEPENDENCY CHECKS
# ============================================================================

check_dependencies() {
    preflight_log_section "12. DEPENDENCY CHECKS"

    local missing_deps=()

    # Required tools
    local required_tools=("bash" "curl" "grep" "awk" "sed")

    # Database-specific tools
    local db_type="${1:-}"
    case "$db_type" in
        postgresql)
            required_tools+=("psql" "pg_dump" "pg_restore")
            ;;
        mysql)
            required_tools+=("mysql" "mysqldump")
            ;;
        mariadb)
            required_tools+=("mysql" "mysqldump" "mariabackup")
            ;;
        cockroachdb)
            required_tools+=("cockroach" "psql")
            ;;
    esac

    # Check each tool
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            preflight_log_success "Dependency: $tool (found)"
        else
            preflight_log_error "Dependency: $tool (MISSING)"
            missing_deps+=("$tool")
        fi
    done

    # Optional but recommended tools
    local optional_tools=("jq" "yq" "bc" "nc")
    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            preflight_log_info "Optional: $tool (found)"
        else
            preflight_log_warn "Optional: $tool (not found, some features limited)"
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        preflight_log_error "Missing required dependencies: ${missing_deps[*]}"
        return $EXIT_DEPENDENCIES
    fi

    return 0
}

check_java_version() {
    preflight_log_section "13. JAVA VERSION CHECK"

    if ! command -v java >/dev/null 2>&1; then
        preflight_log_warn "Java not found in PATH"
        preflight_log_warn "Keycloak requires Java 11 or later"
        return 0
    fi

    local java_version
    java_version=$(java -version 2>&1 | head -1 | awk -F '"' '{print $2}')

    preflight_log_info "Java version: $java_version"

    # Extract major version
    local major_version
    major_version=$(echo "$java_version" | awk -F. '{print $1}')

    if [[ "$major_version" -lt 11 ]]; then
        preflight_log_warn "Java version $java_version < 11 (Keycloak requires Java 11+)"
    else
        preflight_log_success "Java version: OK"
    fi

    return 0
}

# ============================================================================
# 6. CONFIGURATION VALIDATION
# ============================================================================

check_profile_syntax() {
    preflight_log_section "14. PROFILE SYNTAX CHECK"

    local profile_file="${1}"

    if [[ ! -f "$profile_file" ]]; then
        preflight_log_error "Profile file not found: $profile_file"
        return $EXIT_CONFIG
    fi

    preflight_log_info "Profile: $profile_file"

    # YAML syntax check (if yq available)
    if command -v yq >/dev/null 2>&1; then
        if yq eval '.' "$profile_file" >/dev/null 2>&1; then
            preflight_log_success "Profile YAML syntax: Valid"
        else
            preflight_log_error "Profile YAML syntax: Invalid"
            return $EXIT_CONFIG
        fi
    else
        # Basic YAML check without yq
        if grep -q "^database:" "$profile_file" && grep -q "^keycloak:" "$profile_file"; then
            preflight_log_success "Profile structure: Valid"
        else
            preflight_log_warn "Profile structure: Could not fully validate (install yq for thorough check)"
        fi
    fi

    return 0
}

check_credentials() {
    preflight_log_section "15. CREDENTIALS CHECK"

    local db_user="${1}"
    local db_pass="${2}"
    local admin_user="${3}"
    local admin_pass="${4}"

    # Check for empty credentials
    if [[ -z "$db_user" ]]; then
        preflight_log_error "Database user is empty"
        return $EXIT_CONFIG
    fi

    if [[ -z "$db_pass" ]]; then
        preflight_log_warn "Database password is empty (may be expected for trusted auth)"
    fi

    if [[ -z "$admin_user" ]]; then
        preflight_log_warn "Keycloak admin user is empty"
    fi

    if [[ -z "$admin_pass" ]]; then
        preflight_log_warn "Keycloak admin password is empty"
    fi

    preflight_log_success "Credentials check: OK"
    return 0
}

# ============================================================================
# MAIN PREFLIGHT ORCHESTRATOR
# ============================================================================

run_all_preflight_checks() {
    local profile_file="${1}"
    local db_type="${2}"
    local db_host="${3}"
    local db_port="${4}"
    local db_user="${5}"
    local db_pass="${6}"
    local db_name="${7}"
    local backup_dir="${8}"
    local kc_url="${9:-}"
    local admin_user="${10:-}"
    local admin_pass="${11:-}"

    preflight_log_section "PREFLIGHT CHECKS — PRODUCTION SAFETY v3.5"

    local total_checks=15
    local passed_checks=0
    local failed_checks=0
    local warnings=0

    # Track failures
    local failure_reasons=()

    # 1. System Resources
    if check_disk_space "$backup_dir" "$MIN_DISK_SPACE_GB"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Disk space")
    fi

    if check_memory "$MIN_MEMORY_GB"; then
        ((passed_checks++))
    else
        ((warnings++))
    fi

    if check_network_connectivity "$db_host" "$db_port"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Network connectivity")
    fi

    # 2. Database Health
    if check_database_connectivity "$db_type" "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Database connectivity")
    fi

    if check_database_version "$db_type" "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name"; then
        ((passed_checks++))
    else
        ((warnings++))
    fi

    if check_database_size "$db_type" "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name"; then
        ((passed_checks++))
    else
        ((warnings++))
    fi

    if check_database_replication "$db_type" "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name"; then
        ((passed_checks++))
    else
        ((warnings++))
    fi

    # 3. Keycloak Health (optional)
    if [[ -n "$kc_url" ]]; then
        check_keycloak_status "$kc_url" && ((passed_checks++)) || ((warnings++))
        check_keycloak_admin_credentials "$kc_url" "$admin_user" "$admin_pass" && ((passed_checks++)) || ((warnings++))
    else
        ((warnings++))
        ((warnings++))
    fi

    # 4. Backup Verification
    if check_backup_space "$backup_dir"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Backup space")
    fi

    if check_backup_permissions "$backup_dir"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Backup permissions")
    fi

    # 5. Dependencies
    if check_dependencies "$db_type"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Missing dependencies")
    fi

    check_java_version && ((passed_checks++)) || ((warnings++))

    # 6. Configuration
    if check_profile_syntax "$profile_file"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Profile syntax")
    fi

    check_credentials "$db_user" "$db_pass" "$admin_user" "$admin_pass" && ((passed_checks++)) || ((warnings++))

    # Summary
    preflight_log_section "PREFLIGHT SUMMARY"
    echo "Total checks: $total_checks"
    echo "Passed: $passed_checks"
    echo "Failed: $failed_checks"
    echo "Warnings: $warnings"
    echo ""

    if [[ $failed_checks -gt 0 ]]; then
        preflight_log_error "PREFLIGHT FAILED — Cannot proceed with migration"
        preflight_log_error "Failure reasons:"
        for reason in "${failure_reasons[@]}"; do
            preflight_log_error "  - $reason"
        done
        return 1
    elif [[ $warnings -gt 0 ]]; then
        preflight_log_warn "PREFLIGHT PASSED with $warnings warning(s)"
        preflight_log_warn "Migration can proceed, but review warnings"
        return 0
    else
        preflight_log_success "PREFLIGHT PASSED — All checks successful"
        return 0
    fi
}

# ============================================================================
# EXPORTS
# ============================================================================

# Export all functions for use in main migration script
export -f preflight_log_info
export -f preflight_log_success
export -f preflight_log_warn
export -f preflight_log_error
export -f preflight_log_section

export -f check_disk_space
export -f check_memory
export -f check_network_connectivity

export -f check_database_connectivity
export -f check_database_version
export -f check_database_size
export -f check_database_replication

export -f check_keycloak_status
export -f check_keycloak_admin_credentials

export -f check_backup_space
export -f check_backup_permissions

export -f check_dependencies
export -f check_java_version

export -f check_profile_syntax
export -f check_credentials

export -f run_all_preflight_checks
