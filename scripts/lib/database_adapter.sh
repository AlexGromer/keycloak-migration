#!/usr/bin/env bash
# Database Adapter Interface for Keycloak Migration v3.0
# Provides unified interface for multiple DBMS types

set -euo pipefail

# Database type registry
declare -A DB_ADAPTERS=(
    [postgresql]="PostgreSQL"
    [mysql]="MySQL"
    [mariadb]="MariaDB"
    [oracle]="Oracle"
    [mssql]="Microsoft SQL Server"
    [cockroachdb]="CockroachDB"
    [h2]="H2 Database (dev only)"
)

# JDBC driver URLs
declare -A JDBC_PREFIXES=(
    [postgresql]="jdbc:postgresql://"
    [mysql]="jdbc:mysql://"
    [mariadb]="jdbc:mariadb://"
    [oracle]="jdbc:oracle:thin:@"
    [mssql]="jdbc:sqlserver://"
    [cockroachdb]="jdbc:postgresql://"
    [h2]="jdbc:h2:"
)

# Default ports
declare -A DB_DEFAULT_PORTS=(
    [postgresql]="5432"
    [mysql]="3306"
    [mariadb]="3306"
    [oracle]="1521"
    [mssql]="1433"
    [cockroachdb]="26257"
    [h2]="9092"
)

# ============================================================================
# Auto-detection
# ============================================================================

db_detect_type() {
    # Detect database type from JDBC URL or CLI tools
    local jdbc_url="${1:-}"

    if [[ -n "$jdbc_url" ]]; then
        # Detect from JDBC URL
        case "$jdbc_url" in
            jdbc:postgresql://*:26257*) echo "cockroachdb"; return 0 ;;
            jdbc:postgresql:*) echo "postgresql"; return 0 ;;
            jdbc:mysql:*) echo "mysql"; return 0 ;;
            jdbc:mariadb:*) echo "mariadb"; return 0 ;;
            jdbc:oracle:*) echo "oracle"; return 0 ;;
            jdbc:sqlserver:*) echo "mssql"; return 0 ;;
            jdbc:h2:*) echo "h2"; return 0 ;;
            *) echo "unknown"; return 1 ;;
        esac
    fi

    # Detect from available CLI tools
    if command -v cockroach &>/dev/null; then
        echo "cockroachdb"
        return 0
    elif command -v psql &>/dev/null; then
        echo "postgresql"
        return 0
    elif command -v mysql &>/dev/null; then
        # Distinguish MySQL vs MariaDB
        if mysql --version 2>&1 | grep -qi "mariadb"; then
            echo "mariadb"
        else
            echo "mysql"
        fi
        return 0
    elif command -v sqlplus &>/dev/null; then
        echo "oracle"
        return 0
    elif command -v sqlcmd &>/dev/null; then
        echo "mssql"
        return 0
    fi

    echo "unknown"
    return 1
}

db_validate_type() {
    local db_type="$1"

    if [[ -n "${DB_ADAPTERS[$db_type]:-}" ]]; then
        return 0
    else
        echo "ERROR: Unsupported database type: $db_type" >&2
        echo "Supported: ${!DB_ADAPTERS[*]}" >&2
        return 1
    fi
}

# ============================================================================
# Connection Management
# ============================================================================

db_build_jdbc_url() {
    local db_type="$1"
    local host="$2"
    local port="${3:-${DB_DEFAULT_PORTS[$db_type]}}"
    local db_name="$4"

    # Warning for H2 (dev only)
    if [[ "$db_type" == "h2" ]]; then
        echo "⚠️  WARNING: H2 database is for development only, NOT recommended for production" >&2
    fi

    case "$db_type" in
        postgresql|mysql|mariadb)
            echo "${JDBC_PREFIXES[$db_type]}${host}:${port}/${db_name}"
            ;;
        cockroachdb)
            # CockroachDB uses PostgreSQL wire protocol
            echo "${JDBC_PREFIXES[$db_type]}${host}:${port}/${db_name}?sslmode=require"
            ;;
        oracle)
            echo "${JDBC_PREFIXES[$db_type]}${host}:${port}:${db_name}"
            ;;
        mssql)
            echo "${JDBC_PREFIXES[$db_type]}${host}:${port};databaseName=${db_name}"
            ;;
        h2)
            # H2 can be file-based or TCP
            if [[ "$host" == "file" ]]; then
                echo "${JDBC_PREFIXES[$db_type]}file:${db_name}"
            else
                echo "${JDBC_PREFIXES[$db_type]}tcp://${host}:${port}/${db_name}"
            fi
            ;;
        *)
            echo "ERROR: Unknown database type: $db_type" >&2
            return 1
            ;;
    esac
}

db_test_connection() {
    local db_type="$1"
    local host="$2"
    local port="$3"
    local db_name="$4"
    local user="$5"
    local pass="$6"

    case "$db_type" in
        postgresql)
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" \
                -c "SELECT 1;" &>/dev/null
            ;;
        cockroachdb)
            # CockroachDB uses PostgreSQL protocol
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" \
                -c "SELECT 1;" &>/dev/null
            ;;
        mysql|mariadb)
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" \
                -e "SELECT 1;" &>/dev/null
            ;;
        oracle)
            echo "SELECT 1 FROM DUAL;" | \
                sqlplus -S "${user}/${pass}@${host}:${port}/${db_name}" &>/dev/null
            ;;
        mssql)
            sqlcmd -S "${host},${port}" -U "$user" -P "$pass" -d "$db_name" \
                -Q "SELECT 1;" &>/dev/null
            ;;
        h2)
            # H2 testing requires Java, skip for now
            echo "⚠️  H2 connection test skipped (requires Java)" >&2
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# Backup Operations
# ============================================================================

db_backup() {
    local db_type="$1"
    local host="$2"
    local port="$3"
    local db_name="$4"
    local user="$5"
    local pass="$6"
    local backup_file="$7"
    local parallel_jobs="${8:-auto}"

    case "$db_type" in
        postgresql)
            # Source optimizations library
            if [[ -f "$LIB_DIR/db_optimizations.sh" ]]; then
                source "$LIB_DIR/db_optimizations.sh"
            fi

            # Auto-tune parallel jobs if not specified
            if [[ "$parallel_jobs" == "auto" ]]; then
                parallel_jobs=$(pg_auto_tune_parallel_jobs 2>/dev/null || echo "1")
                log_info "Auto-tuned parallel jobs: $parallel_jobs (based on CPU cores and DB size)"
            fi

            # Estimate backup time
            if command -v pg_estimate_backup_time &>/dev/null; then
                pg_estimate_backup_time 2>/dev/null || true
            fi

            # Use pg_dump with custom format
            local pg_version=$(psql --version | grep -oP '\d+' | head -1)
            local dump_opts="-h $host -p $port -U $user -d $db_name -F c -f $backup_file"

            # Add parallel jobs if PostgreSQL >= 9.3
            if [[ "$pg_version" -ge 9 && "$parallel_jobs" -gt 1 ]]; then
                dump_opts="$dump_opts -j $parallel_jobs"
                log_info "Using parallel backup with $parallel_jobs jobs"
            fi

            PGPASSWORD="$pass" pg_dump $dump_opts

            # Verify backup integrity
            if command -v pg_verify_backup &>/dev/null; then
                pg_verify_backup "$backup_file" 2>/dev/null || log_warn "Backup verification skipped"
            fi
            ;;

        mysql)
            # Source optimizations library
            if [[ -f "$LIB_DIR/db_optimizations.sh" ]]; then
                source "$LIB_DIR/db_optimizations.sh"
            fi

            # Try Percona XtraBackup first (hot backup, faster)
            if command -v xtrabackup &>/dev/null; then
                log_info "Using Percona XtraBackup for hot backup"
                mysql_use_xtrabackup "$backup_file" 2>/dev/null && return 0 || {
                    log_warn "XtraBackup failed, falling back to mysqldump"
                }
            fi

            # Fallback to mysqldump
            log_info "Using mysqldump (cold backup)"
            mysqldump -h "$host" -P "$port" -u "$user" -p"$pass" \
                --single-transaction --routines --triggers --events \
                "$db_name" > "$backup_file"

            # Show InnoDB recommendations
            if command -v mysql_innodb_buffer_pool_recommendation &>/dev/null; then
                mysql_innodb_buffer_pool_recommendation 2>/dev/null || true
            fi
            ;;

        mariadb)
            # Source optimizations library
            if [[ -f "$LIB_DIR/db_optimizations.sh" ]]; then
                source "$LIB_DIR/db_optimizations.sh"
            fi

            # MariaDB supports mariabackup for hot backup
            if command -v mariabackup &>/dev/null; then
                log_info "Using MariaDB mariabackup for hot backup"
                mariabackup --backup --target-dir="$backup_file" \
                    --host="$host" --port="$port" --user="$user" --password="$pass" \
                    --databases="$db_name"
            else
                # Fallback to mysqldump
                log_info "Using mysqldump (cold backup)"
                mysqldump -h "$host" -P "$port" -u "$user" -p"$pass" \
                    --single-transaction --routines --triggers --events \
                    "$db_name" > "$backup_file"
            fi

            # Show InnoDB recommendations
            if command -v mysql_innodb_buffer_pool_recommendation &>/dev/null; then
                mysql_innodb_buffer_pool_recommendation 2>/dev/null || true
            fi
            ;;

        oracle)
            # Use expdp (Data Pump Export)
            local dump_dir="BACKUP_DIR"
            local dump_file=$(basename "$backup_file")

            expdp "${user}/${pass}@${host}:${port}/${db_name}" \
                directory="$dump_dir" dumpfile="$dump_file" \
                schemas="$user" logfile="export.log"
            ;;

        mssql)
            # Use sqlcmd for backup
            sqlcmd -S "${host},${port}" -U "$user" -P "$pass" -d "$db_name" \
                -Q "BACKUP DATABASE [$db_name] TO DISK = N'$backup_file' WITH FORMAT;"
            ;;

        cockroachdb)
            # Source optimizations library
            if [[ -f "$LIB_DIR/db_optimizations.sh" ]]; then
                source "$LIB_DIR/db_optimizations.sh"
            fi

            # Show cluster info
            if command -v cockroach_get_cluster_info &>/dev/null; then
                cockroach_get_cluster_info 2>/dev/null || true
            fi

            # Try native CockroachDB backup first (zone-aware, recommended for multi-region)
            if command -v cockroach &>/dev/null && [[ "$backup_file" == nodelocal://* || "$backup_file" == s3://* ]]; then
                log_info "Using CockroachDB native backup (zone-aware)"
                cockroach_zone_aware_backup "$backup_file" 2>/dev/null && return 0 || {
                    log_warn "Native backup failed, falling back to pg_dump"
                }
            fi

            # Fallback: CockroachDB uses pg_dump (PostgreSQL compatible)
            log_info "Using pg_dump for CockroachDB backup"
            PGPASSWORD="$pass" pg_dump -h "$host" -p "$port" -U "$user" -d "$db_name" \
                -F c -f "$backup_file"
            ;;

        h2)
            echo "⚠️  H2 backup: copy .mv.db file manually from Keycloak data directory" >&2
            echo "   Location typically: KEYCLOAK_HOME/data/h2/" >&2
            echo "   Use BACKUP TO 'backup.zip' in H2 console for online backup" >&2
            return 1
            ;;

        *)
            echo "ERROR: Backup not implemented for $db_type" >&2
            return 1
            ;;
    esac
}

db_restore() {
    local db_type="$1"
    local host="$2"
    local port="$3"
    local db_name="$4"
    local user="$5"
    local pass="$6"
    local backup_file="$7"
    local parallel_jobs="${8:-auto}"

    case "$db_type" in
        postgresql)
            # Source optimizations library
            if [[ -f "$LIB_DIR/db_optimizations.sh" ]]; then
                source "$LIB_DIR/db_optimizations.sh"
            fi

            # Auto-tune parallel jobs if not specified
            if [[ "$parallel_jobs" == "auto" ]]; then
                parallel_jobs=$(pg_auto_tune_parallel_jobs 2>/dev/null || echo "1")
                log_info "Auto-tuned parallel jobs: $parallel_jobs (based on CPU cores)"
            fi

            # Terminate active connections first
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db_name' AND pid <> pg_backend_pid();"

            # Restore with pg_restore
            local pg_version=$(psql --version | grep -oP '\d+' | head -1)
            local restore_opts="-h $host -p $port -U $user -d $db_name --clean"

            if [[ "$pg_version" -ge 9 && "$parallel_jobs" -gt 1 ]]; then
                restore_opts="$restore_opts -j $parallel_jobs"
                log_info "Using parallel restore with $parallel_jobs jobs"
            fi

            PGPASSWORD="$pass" pg_restore $restore_opts "$backup_file"

            # Run VACUUM ANALYZE after restore
            log_info "Running post-restore optimizations..."
            if command -v pg_vacuum_analyze &>/dev/null; then
                pg_vacuum_analyze 2>/dev/null || log_warn "VACUUM ANALYZE skipped"
            fi
            ;;

        mysql|mariadb)
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" < "$backup_file"
            ;;

        oracle)
            local dump_dir="BACKUP_DIR"
            local dump_file=$(basename "$backup_file")

            impdp "${user}/${pass}@${host}:${port}/${db_name}" \
                directory="$dump_dir" dumpfile="$dump_file" \
                schemas="$user" logfile="import.log"
            ;;

        mssql)
            sqlcmd -S "${host},${port}" -U "$user" -P "$pass" \
                -Q "RESTORE DATABASE [$db_name] FROM DISK = N'$backup_file' WITH REPLACE;"
            ;;

        cockroachdb)
            # CockroachDB uses pg_restore (PostgreSQL compatible)
            PGPASSWORD="$pass" pg_restore -h "$host" -p "$port" -U "$user" -d "$db_name" \
                --clean "$backup_file"
            ;;

        h2)
            echo "⚠️  H2 restore: copy .mv.db file manually to Keycloak data directory" >&2
            echo "   Stop Keycloak before restoring H2 database" >&2
            return 1
            ;;

        *)
            echo "ERROR: Restore not implemented for $db_type" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Database Information
# ============================================================================

db_get_version() {
    local db_type="$1"
    local host="$2"
    local port="$3"
    local db_name="$4"
    local user="$5"
    local pass="$6"

    case "$db_type" in
        postgresql)
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" \
                -t -c "SHOW server_version;" | xargs
            ;;
        mysql|mariadb)
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db_name" \
                -N -e "SELECT VERSION();"
            ;;
        oracle)
            echo "SELECT * FROM V\$VERSION WHERE ROWNUM = 1;" | \
                sqlplus -S "${user}/${pass}@${host}:${port}/${db_name}" | grep -v "^$"
            ;;
        mssql)
            sqlcmd -S "${host},${port}" -U "$user" -P "$pass" -d "$db_name" \
                -h -1 -Q "SELECT @@VERSION;"
            ;;
        *)
            echo "unknown"
            return 1
            ;;
    esac
}

db_get_size() {
    local db_type="$1"
    local host="$2"
    local port="$3"
    local db_name="$4"
    local user="$5"
    local pass="$6"

    case "$db_type" in
        postgresql)
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" \
                -t -c "SELECT pg_size_pretty(pg_database_size('$db_name'));" | xargs
            ;;
        mysql|mariadb)
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" information_schema \
                -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2)
                       FROM tables WHERE table_schema='$db_name';"
            ;;
        oracle)
            echo "SELECT SUM(bytes)/1024/1024 FROM dba_segments WHERE owner='$user';" | \
                sqlplus -S "${user}/${pass}@${host}:${port}/${db_name}" | grep -v "^$"
            ;;
        mssql)
            sqlcmd -S "${host},${port}" -U "$user" -P "$pass" -d "$db_name" \
                -h -1 -Q "EXEC sp_spaceused;"
            ;;
        *)
            echo "unknown"
            return 1
            ;;
    esac
}

# ============================================================================
# Export adapter info
# ============================================================================

db_adapter_info() {
    echo "Database Adapter v3.0"
    echo "Supported DBMS:"
    for db_type in "${!DB_ADAPTERS[@]}"; do
        echo "  - $db_type: ${DB_ADAPTERS[$db_type]}"
    done
}
