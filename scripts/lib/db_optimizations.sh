#!/usr/bin/env bash
# Database-Specific Optimizations (v3.4)
# Performance tuning for PostgreSQL, MySQL/MariaDB, CockroachDB

set -euo pipefail

# ============================================================================
# PostgreSQL Optimizations
# ============================================================================

pg_auto_tune_parallel_jobs() {
    # Auto-tune parallel jobs based on available CPU cores
    # Usage: pg_auto_tune_parallel_jobs
    # Returns: optimal number of parallel jobs

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "1")

    local db_size_gb
    db_size_gb=$(pg_get_database_size_gb)

    # Formula: min(cpu_cores, max(1, db_size_gb / 2))
    # Small DB (< 2GB): 1 job
    # Medium DB (2-10GB): 2-5 jobs
    # Large DB (> 10GB): use all available cores (up to CPU limit)

    local optimal_jobs
    if (( $(echo "$db_size_gb < 2" | bc -l) )); then
        optimal_jobs=1
    elif (( $(echo "$db_size_gb < 10" | bc -l) )); then
        optimal_jobs=$(( db_size_gb / 2 ))
    else
        optimal_jobs=$cpu_cores
    fi

    # Cap at CPU cores
    if [[ $optimal_jobs -gt $cpu_cores ]]; then
        optimal_jobs=$cpu_cores
    fi

    # Minimum 1 job
    if [[ $optimal_jobs -lt 1 ]]; then
        optimal_jobs=1
    fi

    echo "$optimal_jobs"
}

pg_get_database_size_gb() {
    # Get database size in GB
    # Usage: pg_get_database_size_gb
    # Returns: size in GB (float)

    local db_name="${PROFILE_DB_NAME:-keycloak}"
    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-5432}"
    local user="${PROFILE_DB_USER:-keycloak}"
    local pass="${PROFILE_DB_PASSWORD:-}"

    local size_bytes
    size_bytes=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -tAc \
        "SELECT pg_database_size('$db_name');" 2>/dev/null || echo "0")

    # Convert bytes to GB
    local size_gb
    size_gb=$(echo "scale=2; $size_bytes / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")

    echo "$size_gb"
}

pg_vacuum_analyze() {
    # Run VACUUM ANALYZE after migration
    # Usage: pg_vacuum_analyze
    # Optimizes query planner statistics and reclaims space

    local db_name="${PROFILE_DB_NAME:-keycloak}"
    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-5432}"
    local user="${PROFILE_DB_USER:-keycloak}"
    local pass="${PROFILE_DB_PASSWORD:-}"

    log_section "PostgreSQL Optimization — VACUUM ANALYZE"

    log_info "Running VACUUM ANALYZE on database: $db_name"
    log_info "This will optimize query planner statistics and reclaim disk space"

    local start_time=$(date +%s)

    # Run VACUUM ANALYZE (may take time on large databases)
    PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -c \
        "VACUUM ANALYZE;" 2>&1 | tee -a "$LOG_FILE" || {
        log_warn "VACUUM ANALYZE failed (non-critical, continuing)"
        return 0
    }

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "VACUUM ANALYZE completed in ${duration}s"
}

pg_connection_pool_recommendation() {
    # Recommend connection pool settings based on workload
    # Usage: pg_connection_pool_recommendation
    # Returns: recommended max_connections and shared_buffers

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "1")

    local ram_gb
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')

    log_section "PostgreSQL Configuration Recommendations"

    # max_connections: formula: (cpu_cores * 2) + effective_spindle_count
    # For SSDs: effective_spindle_count = 200
    # For HDDs: effective_spindle_count = 2 per disk
    local max_connections=$(( cpu_cores * 2 + 200 ))

    # shared_buffers: 25% of RAM (recommended starting point)
    local shared_buffers_mb=$(( ram_gb * 1024 / 4 ))

    # work_mem: (RAM - shared_buffers) / max_connections
    local work_mem_mb=$(( (ram_gb * 1024 - shared_buffers_mb) / max_connections ))

    # maintenance_work_mem: RAM / 16 (for VACUUM, CREATE INDEX)
    local maintenance_work_mem_mb=$(( ram_gb * 1024 / 16 ))

    # Cap values for sanity
    if [[ $max_connections -gt 1000 ]]; then
        max_connections=1000
    fi

    if [[ $shared_buffers_mb -gt 8192 ]]; then
        shared_buffers_mb=8192  # 8GB max recommended
    fi

    if [[ $work_mem_mb -lt 4 ]]; then
        work_mem_mb=4  # 4MB minimum
    fi

    if [[ $maintenance_work_mem_mb -gt 2048 ]]; then
        maintenance_work_mem_mb=2048  # 2GB max
    fi

    log_info "System: ${cpu_cores} CPU cores, ${ram_gb}GB RAM"
    log_info ""
    log_info "Recommended postgresql.conf settings:"
    log_info "  max_connections = $max_connections"
    log_info "  shared_buffers = ${shared_buffers_mb}MB"
    log_info "  work_mem = ${work_mem_mb}MB"
    log_info "  maintenance_work_mem = ${maintenance_work_mem_mb}MB"
    log_info "  effective_cache_size = $(( ram_gb * 1024 * 3 / 4 ))MB  # 75% of RAM"
    log_info ""
    log_info "For connection pooling (PgBouncer):"
    log_info "  pool_mode = transaction"
    log_info "  max_client_conn = $(( max_connections * 5 ))"
    log_info "  default_pool_size = $max_connections"
    log_info ""
}

pg_estimate_backup_time() {
    # Estimate backup time based on database size
    # Usage: pg_estimate_backup_time
    # Returns: estimated duration in seconds

    local db_size_gb
    db_size_gb=$(pg_get_database_size_gb)

    # Typical backup speed: 100-200 MB/s on SSD, 30-50 MB/s on HDD
    # Conservative estimate: 50 MB/s (middle ground)
    local backup_speed_mb=50

    local backup_time_sec
    backup_time_sec=$(echo "scale=0; ($db_size_gb * 1024) / $backup_speed_mb" | bc -l)

    log_info "Database size: ${db_size_gb}GB"
    log_info "Estimated backup time: $(( backup_time_sec / 60 )) minutes (at ${backup_speed_mb}MB/s)"

    echo "$backup_time_sec"
}

pg_verify_backup() {
    # Verify PostgreSQL backup integrity
    # Usage: pg_verify_backup <backup_file>
    # Returns: 0 if valid, 1 if corrupted

    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    log_info "Verifying backup integrity: $backup_file"

    # Check if file is a valid pg_dump custom format
    if ! pg_restore --list "$backup_file" &>/dev/null; then
        log_error "Backup file is corrupted or invalid format"
        return 1
    fi

    local table_count
    table_count=$(pg_restore --list "$backup_file" 2>/dev/null | grep -c "TABLE DATA" || echo "0")

    if [[ $table_count -eq 0 ]]; then
        log_warn "Backup contains no tables (empty or corrupted)"
        return 1
    fi

    log_success "Backup verified: $table_count tables found"
    return 0
}

# ============================================================================
# MySQL/MariaDB Optimizations
# ============================================================================

mysql_get_engine_type() {
    # Detect primary storage engine (InnoDB vs MyISAM)
    # Usage: mysql_get_engine_type
    # Returns: innodb, myisam, or mixed

    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-3306}"
    local user="${PROFILE_DB_USER:-keycloak}"
    local pass="${PROFILE_DB_PASSWORD:-}"
    local db_name="${PROFILE_DB_NAME:-keycloak}"

    local engine_stats
    engine_stats=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" -sse \
        "SELECT ENGINE, COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db_name' GROUP BY ENGINE;" \
        2>/dev/null || echo "")

    local innodb_count=$(echo "$engine_stats" | grep "InnoDB" | awk '{print $2}' || echo "0")
    local myisam_count=$(echo "$engine_stats" | grep "MyISAM" | awk '{print $2}' || echo "0")

    if [[ $innodb_count -gt 0 && $myisam_count -eq 0 ]]; then
        echo "innodb"
    elif [[ $myisam_count -gt 0 && $innodb_count -eq 0 ]]; then
        echo "myisam"
    else
        echo "mixed"
    fi
}

mysql_innodb_buffer_pool_recommendation() {
    # Recommend InnoDB buffer pool size
    # Usage: mysql_innodb_buffer_pool_recommendation
    # Returns: recommended size in MB

    local ram_gb
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')

    log_section "MySQL/MariaDB InnoDB Configuration Recommendations"

    # InnoDB buffer pool: 70-80% of RAM for dedicated DB server
    # 50-60% for shared server
    local dedicated_buffer_mb=$(( ram_gb * 1024 * 75 / 100 ))
    local shared_buffer_mb=$(( ram_gb * 1024 * 55 / 100 ))

    log_info "System RAM: ${ram_gb}GB"
    log_info ""
    log_info "Recommended my.cnf settings:"
    log_info ""
    log_info "For dedicated database server:"
    log_info "  innodb_buffer_pool_size = ${dedicated_buffer_mb}M  # 75% of RAM"
    log_info "  innodb_buffer_pool_instances = $(( dedicated_buffer_mb / 1024 ))  # 1 per GB"
    log_info ""
    log_info "For shared server (app + DB):"
    log_info "  innodb_buffer_pool_size = ${shared_buffer_mb}M  # 55% of RAM"
    log_info "  innodb_buffer_pool_instances = $(( shared_buffer_mb / 1024 ))"
    log_info ""
    log_info "Other InnoDB settings:"
    log_info "  innodb_log_file_size = 512M"
    log_info "  innodb_flush_log_at_trx_commit = 2  # Better performance, slight risk"
    log_info "  innodb_flush_method = O_DIRECT"
    log_info "  innodb_file_per_table = 1"
    log_info ""
}

mysql_binary_log_management() {
    # Manage binary logs during migration
    # Usage: mysql_binary_log_management <action>
    # Actions: disable, enable, purge

    local action="${1:-status}"
    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-3306}"
    local user="${PROFILE_DB_USER:-keycloak}"
    local pass="${PROFILE_DB_PASSWORD:-}"

    case "$action" in
        status)
            log_info "Checking binary log status..."
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" -sse \
                "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null || echo "Unknown"
            ;;

        purge)
            log_info "Purging old binary logs..."
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e \
                "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 7 DAY);" 2>&1 | tee -a "$LOG_FILE" || {
                log_warn "Binary log purge failed (may not have permission)"
            }
            ;;

        disable)
            log_warn "Binary log disable requires server restart (skip for now)"
            log_info "To disable: set 'skip-log-bin' in my.cnf and restart MySQL"
            ;;

        enable)
            log_warn "Binary log enable requires server restart (skip for now)"
            log_info "To enable: remove 'skip-log-bin' from my.cnf and restart MySQL"
            ;;

        *)
            log_error "Unknown action: $action"
            return 1
            ;;
    esac
}

mysql_use_xtrabackup() {
    # Check if Percona XtraBackup is available and use it
    # Usage: mysql_use_xtrabackup <backup_dir>
    # Returns: 0 if successful, 1 if not available

    local backup_dir="$1"

    if ! command -v xtrabackup &>/dev/null; then
        log_warn "Percona XtraBackup not found, falling back to mysqldump"
        return 1
    fi

    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-3306}"
    local user="${PROFILE_DB_USER:-keycloak}"
    local pass="${PROFILE_DB_PASSWORD:-}"

    log_info "Using Percona XtraBackup for hot backup"

    mkdir -p "$backup_dir"

    xtrabackup --backup \
        --host="$host" \
        --port="$port" \
        --user="$user" \
        --password="$pass" \
        --target-dir="$backup_dir" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "XtraBackup failed"
        return 1
    }

    # Prepare backup
    log_info "Preparing XtraBackup..."
    xtrabackup --prepare --target-dir="$backup_dir" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "XtraBackup prepare failed"
        return 1
    }

    log_success "XtraBackup completed: $backup_dir"
    return 0
}

# ============================================================================
# CockroachDB Optimizations
# ============================================================================

cockroach_get_cluster_info() {
    # Get CockroachDB cluster information
    # Usage: cockroach_get_cluster_info
    # Returns: node count, region info

    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-26257}"
    local user="${PROFILE_DB_USER:-root}"
    local db_name="${PROFILE_DB_NAME:-keycloak}"

    log_section "CockroachDB Cluster Information"

    # Get node count
    local node_count
    node_count=$(cockroach sql --host="$host:$port" --user="$user" --database="$db_name" \
        --execute="SELECT count(*) FROM crdb_internal.gossip_nodes;" --format=tsv 2>/dev/null || echo "unknown")

    # Get regions
    local regions
    regions=$(cockroach sql --host="$host:$port" --user="$user" --database="$db_name" \
        --execute="SELECT DISTINCT region FROM crdb_internal.regions;" --format=tsv 2>/dev/null || echo "unknown")

    log_info "Cluster nodes: $node_count"
    log_info "Regions: $regions"

    echo "nodes:$node_count,regions:$regions"
}

cockroach_drain_node() {
    # Drain a CockroachDB node before migration
    # Usage: cockroach_drain_node <node_id>
    # Gracefully transfers leases and ranges

    local node_id="$1"
    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-26257}"

    log_info "Draining CockroachDB node $node_id..."

    cockroach node drain "$node_id" --host="$host:$port" 2>&1 | tee -a "$LOG_FILE" || {
        log_warn "Node drain failed (may already be drained)"
    }

    log_success "Node $node_id drained"
}

cockroach_zone_aware_backup() {
    # Create zone-aware backup for multi-region CockroachDB
    # Usage: cockroach_zone_aware_backup <backup_location>
    # Uses CockroachDB's native backup with locality awareness

    local backup_location="$1"
    local host="${PROFILE_DB_HOST:-localhost}"
    local port="${PROFILE_DB_PORT:-26257}"
    local user="${PROFILE_DB_USER:-root}"
    local db_name="${PROFILE_DB_NAME:-keycloak}"

    log_info "Creating zone-aware backup to: $backup_location"

    # Use CockroachDB native BACKUP command
    cockroach sql --host="$host:$port" --user="$user" --database="$db_name" \
        --execute="BACKUP DATABASE $db_name TO '$backup_location' WITH revision_history;" \
        2>&1 | tee -a "$LOG_FILE" || {
        log_error "Zone-aware backup failed"
        return 1
    }

    log_success "Zone-aware backup completed"
}

# ============================================================================
# General Optimization Helpers
# ============================================================================

db_estimate_migration_time() {
    # Estimate total migration time based on database size and operations
    # Usage: db_estimate_migration_time
    # Returns: estimated duration in seconds

    local db_type="${PROFILE_DB_TYPE:-postgresql}"
    local db_size_gb=0

    case "$db_type" in
        postgresql|cockroachdb)
            db_size_gb=$(pg_get_database_size_gb)
            ;;
        mysql|mariadb)
            # Simplified: assume 1GB for now (TODO: implement MySQL size query)
            db_size_gb=1
            ;;
    esac

    # Migration time estimate:
    # - Backup: db_size_gb / 0.05 (50MB/s)
    # - Keycloak startup: 60-120s per version
    # - Database migration: db_size_gb * 2 (varies by schema changes)
    # - Restore (if needed): db_size_gb / 0.05

    local backup_time=$(echo "scale=0; ($db_size_gb * 1024) / 50" | bc -l)
    local startup_time=120  # 2 minutes per Keycloak version
    local schema_migration_time=$(echo "scale=0; $db_size_gb * 2 * 60" | bc -l)  # 2 min per GB

    local total_time=$(( backup_time + startup_time + schema_migration_time ))

    log_info "Estimated migration time breakdown:"
    log_info "  Backup: $(( backup_time / 60 )) minutes"
    log_info "  Keycloak startup: $(( startup_time / 60 )) minutes"
    log_info "  Schema migration: $(( schema_migration_time / 60 )) minutes"
    log_info "  Total: $(( total_time / 60 )) minutes"

    echo "$total_time"
}

db_run_optimizations() {
    # Run database-specific optimizations after migration
    # Usage: db_run_optimizations
    # Automatically detects database type and runs appropriate optimizations

    local db_type="${PROFILE_DB_TYPE:-postgresql}"

    log_section "Post-Migration Database Optimizations"

    case "$db_type" in
        postgresql)
            pg_vacuum_analyze
            pg_connection_pool_recommendation
            ;;

        mysql|mariadb)
            mysql_innodb_buffer_pool_recommendation
            mysql_binary_log_management purge
            ;;

        cockroachdb)
            cockroach_get_cluster_info
            ;;

        *)
            log_info "No specific optimizations for $db_type"
            ;;
    esac
}
