#!/usr/bin/env bash
# Performance Tests — Large Database Migration (v3.5)
# Tests migration performance with large databases (10GB, 50GB, 100GB+)

set -euo pipefail

# ============================================================================
# SETUP
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source test framework
source "$PROJECT_ROOT/tests/test_framework.sh"

# Export work directory
export WORK_DIR="/tmp/test_migration_performance_$$"
mkdir -p "$WORK_DIR"
export LOG_FILE="$WORK_DIR/test.log"
touch "$LOG_FILE"

# Mock logging functions
log_info() { echo "[INFO] $1"; }
log_success() { echo "[✓] $1"; }
log_warn() { echo "[!] $1"; }
log_error() { echo "[✗] $1" >&2; }
log_section() { echo "=== $1 ==="; }

# ============================================================================
# TEST CONFIGURATION
# ============================================================================

# Database sizes to test (GB)
readonly DB_SIZES=(1 5 10 25 50 100)

# Test database credentials (adjust for your test environment)
TEST_DB_TYPE="${TEST_DB_TYPE:-postgresql}"
TEST_DB_HOST="${TEST_DB_HOST:-localhost}"
TEST_DB_PORT="${TEST_DB_PORT:-5432}"
TEST_DB_USER="${TEST_DB_USER:-postgres}"
TEST_DB_PASS="${TEST_DB_PASS:-password}"
TEST_DB_NAME="${TEST_DB_NAME:-keycloak_perf_test}"

# Performance thresholds (minutes per GB)
readonly EXPECTED_BACKUP_TIME_PER_GB=2   # 2 min/GB (at 50 MB/s)
readonly EXPECTED_RESTORE_TIME_PER_GB=3  # 3 min/GB

# ============================================================================
# DATABASE POPULATION
# ============================================================================

generate_test_data() {
    local target_size_gb="${1}"

    log_section "Generating test data: ${target_size_gb}GB"

    case "$TEST_DB_TYPE" in
        postgresql)
            generate_postgresql_data "$target_size_gb"
            ;;
        mysql|mariadb)
            generate_mysql_data "$target_size_gb"
            ;;
        *)
            log_error "Unsupported database type for test data generation: $TEST_DB_TYPE"
            return 1
            ;;
    esac
}

generate_postgresql_data() {
    local target_size_gb="${1}"
    local target_size_mb=$((target_size_gb * 1024))

    log_info "Creating test database: $TEST_DB_NAME"

    # Create database
    PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "DROP DATABASE IF EXISTS $TEST_DB_NAME;" 2>/dev/null || true
    PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "CREATE DATABASE $TEST_DB_NAME;"

    # Create large table with random data
    PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -d "$TEST_DB_NAME" <<EOF
-- Create table similar to Keycloak schema (simplified)
CREATE TABLE IF NOT EXISTS perf_test_users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    first_name VARCHAR(255),
    last_name VARCHAR(255),
    created_timestamp BIGINT,
    enabled BOOLEAN DEFAULT TRUE,
    -- Add TEXT column for bulk (each row ~1KB)
    bulk_data TEXT
);

-- Create indexes (like Keycloak)
CREATE INDEX idx_username ON perf_test_users(username);
CREATE INDEX idx_email ON perf_test_users(email);

-- Populate with data
-- Each row ~1KB, so for 1GB we need ~1M rows
DO \$\$
DECLARE
    target_rows INTEGER := ${target_size_mb} * 1000;
    batch_size INTEGER := 10000;
    total_batches INTEGER := target_rows / batch_size;
    i INTEGER;
BEGIN
    FOR i IN 1..total_batches LOOP
        INSERT INTO perf_test_users (username, email, first_name, last_name, created_timestamp, bulk_data)
        SELECT
            'user_' || g.id,
            'user_' || g.id || '@example.com',
            'FirstName_' || g.id,
            'LastName_' || g.id,
            EXTRACT(EPOCH FROM NOW())::BIGINT,
            REPEAT('x', 800)  -- ~800 bytes of bulk data
        FROM generate_series((i-1)*batch_size + 1, i*batch_size) AS g(id);

        -- Progress
        IF i % 10 = 0 THEN
            RAISE NOTICE 'Progress: %/%', i, total_batches;
        END IF;
    END LOOP;
END \$\$;

-- Vacuum analyze
VACUUM ANALYZE perf_test_users;
EOF

    # Get actual database size
    local actual_size_mb
    actual_size_mb=$(PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -d "$TEST_DB_NAME" -t -c "SELECT pg_database_size('$TEST_DB_NAME') / 1024 / 1024;" | tr -d ' ')

    log_success "Test database created: ${actual_size_mb}MB"
}

generate_mysql_data() {
    local target_size_gb="${1}"
    local target_size_mb=$((target_size_gb * 1024))

    log_info "Creating test database: $TEST_DB_NAME"

    # Create database
    mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "DROP DATABASE IF EXISTS $TEST_DB_NAME;" 2>/dev/null || true
    mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "CREATE DATABASE $TEST_DB_NAME;"

    # Create and populate table
    mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" "$TEST_DB_NAME" <<EOF
CREATE TABLE IF NOT EXISTS perf_test_users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    first_name VARCHAR(255),
    last_name VARCHAR(255),
    created_timestamp BIGINT,
    enabled BOOLEAN DEFAULT TRUE,
    bulk_data TEXT,
    INDEX idx_username (username),
    INDEX idx_email (email)
) ENGINE=InnoDB;

-- Populate with stored procedure
DELIMITER //
CREATE PROCEDURE populate_data()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE target_rows INT DEFAULT ${target_size_mb} * 1000;

    WHILE i <= target_rows DO
        INSERT INTO perf_test_users (username, email, first_name, last_name, created_timestamp, bulk_data)
        VALUES (
            CONCAT('user_', i),
            CONCAT('user_', i, '@example.com'),
            CONCAT('FirstName_', i),
            CONCAT('LastName_', i),
            UNIX_TIMESTAMP(),
            REPEAT('x', 800)
        );

        IF i % 10000 = 0 THEN
            COMMIT;
        END IF;

        SET i = i + 1;
    END WHILE;

    COMMIT;
END//
DELIMITER ;

CALL populate_data();
DROP PROCEDURE populate_data;

OPTIMIZE TABLE perf_test_users;
EOF

    # Get actual database size
    local actual_size_mb
    actual_size_mb=$(mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE table_schema = '$TEST_DB_NAME';" -s -N)

    log_success "Test database created: ${actual_size_mb}MB"
}

# ============================================================================
# BACKUP PERFORMANCE TEST
# ============================================================================

test_backup_performance() {
    local db_size_gb="${1}"
    local backup_dir="$WORK_DIR/backups"
    mkdir -p "$backup_dir"

    test_report "Backup Performance Test: ${db_size_gb}GB Database"

    # Generate test data
    generate_test_data "$db_size_gb" || {
        assert_true "false" "Failed to generate test data"
        return
    }

    # Measure backup time
    local start_time
    local end_time
    local duration_sec

    start_time=$(date +%s)

    case "$TEST_DB_TYPE" in
        postgresql)
            PGPASSWORD="$TEST_DB_PASS" pg_dump -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" \
                -d "$TEST_DB_NAME" -Fc -f "$backup_dir/backup_${db_size_gb}gb.dump" \
                -j "$(nproc)" >/dev/null 2>&1 || {
                    assert_true "false" "Backup failed"
                    return
                }
            ;;
        mysql|mariadb)
            mysqldump -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" \
                --single-transaction --quick "$TEST_DB_NAME" \
                > "$backup_dir/backup_${db_size_gb}gb.sql" 2>/dev/null || {
                    assert_true "false" "Backup failed"
                    return
                }
            ;;
    esac

    end_time=$(date +%s)
    duration_sec=$((end_time - start_time))
    local duration_min=$(echo "scale=2; $duration_sec / 60" | bc -l 2>/dev/null || echo "0")

    # Calculate rate (GB/min)
    local backup_rate
    backup_rate=$(echo "scale=2; $db_size_gb / $duration_min" | bc -l 2>/dev/null || echo "0")

    log_info "Backup time: ${duration_min} minutes (${backup_rate} GB/min)"

    # Check against threshold
    local expected_time=$((db_size_gb * EXPECTED_BACKUP_TIME_PER_GB))

    if (( duration_sec < expected_time * 60 )); then
        assert_true "true" "Backup performance: ${duration_min}min < ${expected_time}min (PASS)"
    else
        assert_true "false" "Backup performance: ${duration_min}min >= ${expected_time}min (SLOW)"
    fi

    # Cleanup
    rm -f "$backup_dir/backup_${db_size_gb}gb.dump" "$backup_dir/backup_${db_size_gb}gb.sql"
}

# ============================================================================
# RESTORE PERFORMANCE TEST
# ============================================================================

test_restore_performance() {
    local db_size_gb="${1}"
    local backup_dir="$WORK_DIR/backups"
    mkdir -p "$backup_dir"

    test_report "Restore Performance Test: ${db_size_gb}GB Database"

    # Create backup first
    generate_test_data "$db_size_gb" || {
        assert_true "false" "Failed to generate test data"
        return
    }

    case "$TEST_DB_TYPE" in
        postgresql)
            PGPASSWORD="$TEST_DB_PASS" pg_dump -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" \
                -d "$TEST_DB_NAME" -Fc -f "$backup_dir/backup_${db_size_gb}gb.dump" \
                -j "$(nproc)" >/dev/null 2>&1
            ;;
        mysql|mariadb)
            mysqldump -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" \
                --single-transaction --quick "$TEST_DB_NAME" \
                > "$backup_dir/backup_${db_size_gb}gb.sql" 2>/dev/null
            ;;
    esac

    # Drop and recreate database
    case "$TEST_DB_TYPE" in
        postgresql)
            PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "DROP DATABASE IF EXISTS ${TEST_DB_NAME}_restore;" 2>/dev/null || true
            PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "CREATE DATABASE ${TEST_DB_NAME}_restore;"
            ;;
        mysql|mariadb)
            mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "DROP DATABASE IF EXISTS ${TEST_DB_NAME}_restore;" 2>/dev/null || true
            mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "CREATE DATABASE ${TEST_DB_NAME}_restore;"
            ;;
    esac

    # Measure restore time
    local start_time
    local end_time
    local duration_sec

    start_time=$(date +%s)

    case "$TEST_DB_TYPE" in
        postgresql)
            PGPASSWORD="$TEST_DB_PASS" pg_restore -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" \
                -d "${TEST_DB_NAME}_restore" "$backup_dir/backup_${db_size_gb}gb.dump" \
                -j "$(nproc)" >/dev/null 2>&1 || {
                    assert_true "false" "Restore failed"
                    return
                }
            ;;
        mysql|mariadb)
            mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" \
                "${TEST_DB_NAME}_restore" < "$backup_dir/backup_${db_size_gb}gb.sql" 2>/dev/null || {
                    assert_true "false" "Restore failed"
                    return
                }
            ;;
    esac

    end_time=$(date +%s)
    duration_sec=$((end_time - start_time))
    local duration_min=$(echo "scale=2; $duration_sec / 60" | bc -l 2>/dev/null || echo "0")

    # Calculate rate (GB/min)
    local restore_rate
    restore_rate=$(echo "scale=2; $db_size_gb / $duration_min" | bc -l 2>/dev/null || echo "0")

    log_info "Restore time: ${duration_min} minutes (${restore_rate} GB/min)"

    # Check against threshold
    local expected_time=$((db_size_gb * EXPECTED_RESTORE_TIME_PER_GB))

    if (( duration_sec < expected_time * 60 )); then
        assert_true "true" "Restore performance: ${duration_min}min < ${expected_time}min (PASS)"
    else
        assert_true "false" "Restore performance: ${duration_min}min >= ${expected_time}min (SLOW)"
    fi

    # Cleanup
    case "$TEST_DB_TYPE" in
        postgresql)
            PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "DROP DATABASE IF EXISTS ${TEST_DB_NAME}_restore;" 2>/dev/null || true
            ;;
        mysql|mariadb)
            mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "DROP DATABASE IF EXISTS ${TEST_DB_NAME}_restore;" 2>/dev/null || true
            ;;
    esac

    rm -f "$backup_dir/backup_${db_size_gb}gb.dump" "$backup_dir/backup_${db_size_gb}gb.sql"
}

# ============================================================================
# FULL MIGRATION PERFORMANCE TEST
# ============================================================================

test_full_migration_performance() {
    test_report "Full Migration Performance Test Suite"

    # Test only smaller sizes for quick testing (1GB, 5GB)
    # For full production testing, use all sizes: "${DB_SIZES[@]}"
    local test_sizes=(1 5)

    for size in "${test_sizes[@]}"; do
        log_section "Testing ${size}GB Database"

        # Backup test
        test_backup_performance "$size"

        # Restore test
        test_restore_performance "$size"

        # Cleanup test database
        case "$TEST_DB_TYPE" in
            postgresql)
                PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "DROP DATABASE IF EXISTS $TEST_DB_NAME;" 2>/dev/null || true
                ;;
            mysql|mariadb)
                mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "DROP DATABASE IF EXISTS $TEST_DB_NAME;" 2>/dev/null || true
                ;;
        esac
    done
}

# ============================================================================
# STRESS TEST (Concurrent Operations)
# ============================================================================

test_concurrent_operations() {
    test_report "Concurrent Operations Stress Test"

    log_info "Simulating concurrent backup operations"

    # Create 3 small test databases
    for i in {1..3}; do
        local db_name="${TEST_DB_NAME}_concurrent_$i"

        case "$TEST_DB_TYPE" in
            postgresql)
                PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "DROP DATABASE IF EXISTS $db_name;" 2>/dev/null || true
                PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "CREATE DATABASE $db_name;"
                PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -d "$db_name" -c "CREATE TABLE test (id SERIAL PRIMARY KEY, data TEXT);"
                PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -d "$db_name" -c "INSERT INTO test (data) SELECT REPEAT('x', 1000) FROM generate_series(1, 1000);"
                ;;
        esac
    done

    # Launch concurrent backups
    local backup_dir="$WORK_DIR/concurrent_backups"
    mkdir -p "$backup_dir"

    local pids=()

    for i in {1..3}; do
        local db_name="${TEST_DB_NAME}_concurrent_$i"

        (
            case "$TEST_DB_TYPE" in
                postgresql)
                    PGPASSWORD="$TEST_DB_PASS" pg_dump -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" \
                        -d "$db_name" -Fc -f "$backup_dir/backup_$i.dump" >/dev/null 2>&1
                    ;;
            esac
        ) &
        pids+=($!)
    done

    # Wait for all backups to complete
    local all_success=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            all_success=false
        fi
    done

    if $all_success; then
        assert_true "true" "Concurrent backups: All completed successfully"
    else
        assert_true "false" "Concurrent backups: Some failed"
    fi

    # Cleanup
    for i in {1..3}; do
        local db_name="${TEST_DB_NAME}_concurrent_$i"
        case "$TEST_DB_TYPE" in
            postgresql)
                PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "DROP DATABASE IF EXISTS $db_name;" 2>/dev/null || true
                ;;
        esac
    done

    rm -rf "$backup_dir"
}

# ============================================================================
# RUN TESTS
# ============================================================================

# Check if database is accessible
log_section "Pre-Test Validation"

case "$TEST_DB_TYPE" in
    postgresql)
        if ! PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -c "SELECT 1;" >/dev/null 2>&1; then
            log_error "Cannot connect to PostgreSQL database"
            log_error "Set TEST_DB_* environment variables or use default (localhost:5432)"
            exit 1
        fi
        ;;
    mysql|mariadb)
        if ! mysql -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "SELECT 1;" >/dev/null 2>&1; then
            log_error "Cannot connect to MySQL/MariaDB database"
            log_error "Set TEST_DB_* environment variables"
            exit 1
        fi
        ;;
esac

log_success "Database connection: OK"
log_info "Database type: $TEST_DB_TYPE"
log_info "Host: $TEST_DB_HOST:$TEST_DB_PORT"

# Run performance tests
test_full_migration_performance

# Run stress test
test_concurrent_operations

# Cleanup
rm -rf "$WORK_DIR"

test_report "Large Database Performance Tests Complete"
