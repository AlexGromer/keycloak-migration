#!/usr/bin/env bash
# Preflight Checks — Production Safety (v3.5)
# Comprehensive pre-migration validation

set -euo pipefail

# pg_client / pg_client_available live in container_runtime.sh (include-guarded; safe to re-source).
if ! declare -F pg_client >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/container_runtime.sh" 2>/dev/null || true
fi

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

# A floor, not a budget. The real backup requirement is COMPUTED from the database (see
# check_backup_space); this only reserves room for logs, the state file and psql temp files.
#
# It used to be `MIN_DISK_SPACE_GB=10`, checked BEFORE the database size was even known — so a host
# with 8 GB free refused to migrate a 50 MB database. An arbitrary number cannot know what your
# migration needs; measuring it can.
readonly MIN_DISK_FREE_MB=512        # Floor: logs, state, temp (NOT the backup — that is computed)
readonly MIN_MEMORY_GB=2             # Minimum free memory (GB)

# What actually lands in a pg_dump, per GB of heap.
#
# The old multiplier was `db_size × 3`, where db_size = pg_database_size() — which INCLUDES indexes.
# pg_dump does not dump indexes; it dumps CREATE INDEX statements (a few KB) and the heap, then
# gzips it. For a 200 GB database with 80 GB of indexes that demanded 600 GB for a dump that would
# have been ~30 GB — refusing a migration there was room for. We now size from the heap alone and
# keep a modest cushion for the incompressible worst case.
readonly BACKUP_HEAP_MULTIPLIER_PCT=120   # required = heap × 1.2 (uncompressed worst case + slack)

readonly NETWORK_TIMEOUT=5           # Network connectivity timeout (seconds)
readonly DB_HEALTH_TIMEOUT=10        # Database health check timeout (seconds)

# Exit codes (guarded to prevent collision when multiple libs are sourced)
[[ -v EXIT_SUCCESS ]] || readonly EXIT_SUCCESS=0
readonly EXIT_DISK_SPACE=10
# shellcheck disable=SC2034  # exit-code constant, part of public set (may be used by sourcing scripts)
readonly EXIT_MEMORY=11
readonly EXIT_NETWORK=12
readonly EXIT_DB_HEALTH=13
# shellcheck disable=SC2034  # exit-code constant, part of public set (may be used by sourcing scripts)
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
    preflight_log_section "1. DISK SPACE FLOOR"

    local backup_dir="${1:-/tmp}"
    local required_mb="${2:-$MIN_DISK_FREE_MB}"

    # This is the FLOOR only — room for logs, the state file and temp. The backup requirement is
    # measured from the database in check_backup_space, which runs after we know how big it is.
    preflight_log_info "Checking working space on: $backup_dir"
    preflight_log_info "Floor: ${required_mb}MB (logs/state/temp — the backup is sized separately)"

    local available_mb
    available_mb=$(df -BM "$backup_dir" 2>/dev/null | awk 'NR==2 { gsub(/M/, "", $4); print $4 + 0 }')
    : "${available_mb:=0}"

    preflight_log_info "Available space: ${available_mb}MB"

    if (( available_mb < required_mb )); then
        preflight_log_error "Insufficient working space: ${available_mb}MB < ${required_mb}MB"
        preflight_log_error "Free up space or point --work-dir at a roomier filesystem"
        return $EXIT_DISK_SPACE
    fi

    preflight_log_success "Working space: ${available_mb}MB (OK)"
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

    # Probe with bash's own TCP redirection FIRST — it is implementation-independent.
    # NEVER parse nc's output: the wording differs per flavour (netcat-openbsd prints
    # "succeeded", ncat/nmap prints "Connected to", netcat-traditional prints nothing), which
    # produced FALSE "UNREACHABLE" verdicts on hosts where nc is ncat — even though psql
    # connected to the very same host:port.
    if timeout "$NETWORK_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
        preflight_log_success "Network: $host:$port (reachable)"
        return 0
    fi

    # Fallback: nc, judged by its EXIT CODE only (never by its message).
    if command -v nc >/dev/null 2>&1 &&
       timeout "$NETWORK_TIMEOUT" nc -z "$host" "$port" >/dev/null 2>&1; then
        preflight_log_success "Network: $host:$port (reachable)"
        return 0
    fi

    # AUTONOMOUS path: with no host psql, the migration reaches the database through the pg-client
    # CONTAINER, which may sit on a container network the host cannot TCP-probe (e.g. a DB addressed by
    # container name on a rootless-docker bridge). A host-level probe failure is then NOT authoritative
    # — the real gate is the pg_client-based database-connectivity check that runs next. So warn and
    # defer instead of failing. (When host psql IS present the DB is reached from the host, and this
    # stays a hard failure.)
    if ! command -v psql >/dev/null 2>&1 \
       && declare -F pg_client_available >/dev/null 2>&1 && pg_client_available psql; then
        preflight_log_warn "Network: host cannot TCP-probe $host:$port, but a container pg-client is present"
        preflight_log_warn "  deferring reachability to the database connectivity check (autonomous path)"
        return 0
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
            # shellcheck disable=SC2016  # $1-$4 are the inner bash -c positional args (timeout cannot exec a bash function, so pg_client is invoked from a child bash)
            if PGPASSWORD="$pass" timeout "$DB_HEALTH_TIMEOUT" bash -c 'pg_client psql -h "$1" -p "$2" -U "$3" -d "$4" -c "SELECT 1;"' _ "$host" "$port" "$user" "$db_name" >/dev/null 2>&1; then
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
            # shellcheck disable=SC2016  # $1-$4 are the inner bash -c positional args (timeout cannot exec a bash function, so pg_client is invoked from a child bash)
            if PGPASSWORD="$pass" timeout "$DB_HEALTH_TIMEOUT" bash -c 'pg_client psql -h "$1" -p "$2" -U "$3" -d "$4" -c "SELECT 1;"' _ "$host" "$port" "$user" "$db_name" >/dev/null 2>&1; then
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
            version=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT version();" 2>/dev/null | head -1)
            preflight_log_info "PostgreSQL Version: $version"
            ;;
        mysql|mariadb)
            version=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" -e "SELECT VERSION();" -s -N 2>/dev/null)
            preflight_log_info "MySQL/MariaDB Version: $version"
            ;;
        cockroachdb)
            version=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT version();" 2>/dev/null | head -1)
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
            size_bytes=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' ')
            ;;
        mysql|mariadb)
            size_bytes=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" -e "SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema = '$db_name';" -s -N 2>/dev/null)
            ;;
        cockroachdb)
            size_bytes=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' ')
            ;;
        *)
            preflight_log_warn "Database type '$db_type' not supported for size check"
            return 0
            ;;
    esac

    if [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]; then
        size_gb=$(echo "scale=2; $size_bytes / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
        preflight_log_info "Database size: ${size_gb}GB (on disk, indexes included)"
        preflight_log_success "Database size check: OK"

        # Export for backup space calculation
        export PREFLIGHT_DB_SIZE_GB="$size_gb"
    else
        preflight_log_warn "Could not retrieve database size"
        export PREFLIGHT_DB_SIZE_GB="10"  # Default fallback
    fi

    # What will actually land in the dump — a different number, and the one that matters.
    #
    # pg_database_size() counts indexes; pg_dump does not dump them (it dumps the CREATE INDEX
    # statements, which are kilobytes). Sizing a backup from pg_database_size overstates it by
    # however much of the database is index — commonly 30-50% for Keycloak.
    export PREFLIGHT_DUMP_HEAP_MB=""
    if [[ "$db_type" == "postgresql" || "$db_type" == "cockroachdb" ]]; then
        local heap_bytes
        heap_bytes=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -tAc "
            SELECT COALESCE(sum(pg_relation_size(c.oid)), 0)
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r','p')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null | tr -cd '0-9')

        if [[ -n "$heap_bytes" ]]; then
            PREFLIGHT_DUMP_HEAP_MB=$(awk -v b="$heap_bytes" 'BEGIN { printf "%d", (b / 1048576) + 0.5 }')
            export PREFLIGHT_DUMP_HEAP_MB
            preflight_log_info "Table data (what pg_dump actually writes): ${PREFLIGHT_DUMP_HEAP_MB}MB"
        else
            preflight_log_warn "Could not measure table data — backup sizing falls back to total DB size"
        fi

        check_large_tables "$host" "$port" "$user" "$pass" "$db_name"
    fi

    return 0
}

# check_large_tables — warn about tables Keycloak will REFUSE to index during the migration.
#
# Above roughly 300k rows Keycloak skips CREATE INDEX at startup rather than block the boot, and
# logs the DDL instead. The migration then succeeds — with indexes missing. Nothing goes bang; the
# database is simply slow afterwards, and the cause is a log line nobody read.
#
# The tool already captures that DDL (kc_check_skipped_indexes) but only APPLIES it when
# PROFILE_APPLY_SKIPPED_INDEXES=true, which nothing sets. So say it BEFORE the migration, while
# turning it on is still a decision rather than an incident.
check_large_tables() {
    local host="$1" port="$2" user="$3" pass="$4" db_name="$5"
    local threshold="${KC_INDEX_SKIP_ROW_THRESHOLD:-300000}"

    local rows
    rows=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -tAc "
        SELECT c.relname || ' (' || c.reltuples::bigint || ' rows)'
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND c.reltuples > ${threshold}
        ORDER BY c.reltuples DESC
        LIMIT 10;" 2>/dev/null)

    [[ -n "$rows" ]] || return 0

    preflight_log_warn "Tables above Keycloak's ${threshold}-row index threshold:"
    printf '%s\n' "$rows" | while IFS= read -r line; do
        [[ -n "$line" ]] && preflight_log_warn "    ${line}"
    done
    preflight_log_warn "Keycloak will SKIP creating indexes on these and log the DDL instead."
    preflight_log_warn "The migration will succeed; the database will be slow, with indexes missing."

    if [[ "${PROFILE_APPLY_SKIPPED_INDEXES:-false}" == "true" ]]; then
        preflight_log_info "--apply-indexes is ON: the skipped indexes will be created CONCURRENTLY."
    else
        preflight_log_warn "Pass --apply-indexes (or PROFILE_APPLY_SKIPPED_INDEXES=true) to create"
        preflight_log_warn "them CONCURRENTLY after each hop. Otherwise apply the generated"
        preflight_log_warn "skipped_indexes_<version>.sql by hand."
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
            is_replica=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')

            if [[ "$is_replica" == "t" ]]; then
                preflight_log_warn "Database is a READ REPLICA"
                preflight_log_warn "Migration should be performed on PRIMARY instance"

                # Check replication lag
                replication_lag=$(PGPASSWORD="$pass" pg_client psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" 2>/dev/null | tr -d ' ')

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

    # One backup is taken BEFORE EACH HOP, and they all stay on disk. 16 -> 24 -> 25 -> 26 is three
    # backups, not one. This factor did not exist before: the check sized for a single dump and the
    # migration then wrote three, filling the disk mid-run on exactly the large databases where the
    # check mattered.
    local hops="${PREFLIGHT_HOP_COUNT:-1}"
    [[ "$hops" =~ ^[0-9]+$ ]] && (( hops >= 1 )) || hops=1

    # Size from the heap — the bytes pg_dump actually writes. Fall back to pg_database_size (indexes
    # and all) only when the heap could not be measured; overestimating beats guessing low here.
    local base_mb source_desc
    if [[ -n "${PREFLIGHT_DUMP_HEAP_MB:-}" ]]; then
        base_mb="$PREFLIGHT_DUMP_HEAP_MB"
        source_desc="table data"
    else
        base_mb=$(awk -v g="${PREFLIGHT_DB_SIZE_GB:-0}" 'BEGIN { printf "%d", (g * 1024) + 0.5 }' 2>/dev/null || echo 0)
        source_desc="total DB size (heap unavailable — conservative)"
    fi

    # awk does the float math; bash arithmetic is integer-only and chokes on values like ".01".
    local required_mb available_mb
    required_mb=$(awk -v b="${base_mb:-0}" -v p="$BACKUP_HEAP_MULTIPLIER_PCT" -v h="$hops" \
        'BEGIN { printf "%d", ((b * p / 100) * h) + 0.5 }' 2>/dev/null || echo 1)
    (( required_mb < 1 )) && required_mb=1

    available_mb=$(df -BM "$backup_dir" 2>/dev/null | awk 'NR==2 { gsub(/M/, "", $4); print $4 + 0 }')
    : "${available_mb:=0}"

    preflight_log_info "Backup basis: ${base_mb}MB (${source_desc})"
    preflight_log_info "Hops in this migration: ${hops} (one backup each, all retained)"
    preflight_log_info "Required: ${required_mb}MB  = ${base_mb}MB x ${BACKUP_HEAP_MULTIPLIER_PCT}% x ${hops}"
    preflight_log_info "Available: ${available_mb}MB in ${backup_dir}"

    if (( available_mb < required_mb )); then
        preflight_log_error "Insufficient backup space: ${available_mb}MB < ${required_mb}MB"
        preflight_log_error "Free space, point --work-dir elsewhere, or lower the backup retention."
        return $EXIT_DISK_SPACE
    fi

    preflight_log_success "Backup space: ${available_mb}MB available, ${required_mb}MB needed (OK)"
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
            # psql/pg_dump/pg_restore: a host binary OR the pg-client container image satisfies each.
            local _pgtool
            for _pgtool in psql pg_dump pg_restore; do
                if pg_client_available "$_pgtool"; then
                    preflight_log_success "Dependency: $_pgtool (host or ${PROFILE_PG_CLIENT_IMAGE:-postgres:16} image)"
                else
                    preflight_log_error "Dependency: $_pgtool (MISSING: no host binary and no ${PROFILE_PG_CLIENT_IMAGE:-postgres:16} image)"
                    missing_deps+=("$_pgtool")
                fi
            done
            ;;
        mysql)
            required_tools+=("mysql" "mysqldump")
            ;;
        mariadb)
            required_tools+=("mysql" "mysqldump" "mariabackup")
            ;;
        cockroachdb)
            required_tools+=("cockroach")
            if pg_client_available psql; then
                preflight_log_success "Dependency: psql (host or ${PROFILE_PG_CLIENT_IMAGE:-postgres:16} image)"
            else
                preflight_log_error "Dependency: psql (MISSING: no host binary and no ${PROFILE_PG_CLIENT_IMAGE:-postgres:16} image)"
                missing_deps+=("psql")
            fi
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
        # yq flavor-agnostic: 'yq eval .' (mikefarah/Go-yq) OR 'yq .' (Go-yq v4 / kislyuk python-yq)
        if yq eval '.' "$profile_file" >/dev/null 2>&1 || yq '.' "$profile_file" >/dev/null 2>&1; then
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
    # The FLOOR only (logs/state/temp). The backup requirement is measured from the database in
    # check_backup_space below — which is why the database must be sized before it, not after.
    if check_disk_space "$backup_dir" "$MIN_DISK_FREE_MB"; then
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
        # shellcheck disable=SC2015  # intentional A && B || C tally; preserving existing behavior
        check_keycloak_status "$kc_url" && ((passed_checks++)) || ((warnings++))
        # shellcheck disable=SC2015  # intentional A && B || C tally; preserving existing behavior
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

    # shellcheck disable=SC2015  # intentional A && B || C tally; preserving existing behavior
    check_java_version && ((passed_checks++)) || ((warnings++))

    # 6. Configuration
    if check_profile_syntax "$profile_file"; then
        ((passed_checks++))
    else
        ((failed_checks++))
        failure_reasons+=("Profile syntax")
    fi

    # shellcheck disable=SC2015  # intentional A && B || C tally; preserving existing behavior
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
