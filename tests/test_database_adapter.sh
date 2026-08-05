#!/usr/bin/env bash
# shellcheck disable=SC2329
# (the pg_client / pg_verify_backup stubs ARE invoked — indirectly, by db_restore under test)
# Tests: Database Adapter
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/scripts/lib/database_adapter.sh"

# ============================================================================
describe "db_validate_type()"
# ============================================================================

assert_true "db_validate_type postgresql" "postgresql is valid"
assert_true "db_validate_type mysql" "mysql is valid"
assert_true "db_validate_type mariadb" "mariadb is valid"
assert_true "db_validate_type oracle" "oracle is valid"
assert_true "db_validate_type mssql" "mssql is valid"
assert_false "db_validate_type sqlite 2>/dev/null" "sqlite is invalid"
assert_false "db_validate_type nosql 2>/dev/null" "nosql is invalid"

# ============================================================================
describe "db_detect_type() — from JDBC URL"
# ============================================================================

assert_equals "postgresql" \
    "$(db_detect_type 'jdbc:postgresql://localhost:5432/keycloak')" \
    "detect PostgreSQL from JDBC URL"

assert_equals "mysql" \
    "$(db_detect_type 'jdbc:mysql://db.host:3306/keycloak')" \
    "detect MySQL from JDBC URL"

assert_equals "mariadb" \
    "$(db_detect_type 'jdbc:mariadb://maria:3306/kc')" \
    "detect MariaDB from JDBC URL"

assert_equals "oracle" \
    "$(db_detect_type 'jdbc:oracle:thin:@orahost:1521:ORCL')" \
    "detect Oracle from JDBC URL"

assert_equals "mssql" \
    "$(db_detect_type 'jdbc:sqlserver://sqlhost:1433;databaseName=keycloak')" \
    "detect MSSQL from JDBC URL"

# ============================================================================
describe "db_build_jdbc_url()"
# ============================================================================

assert_equals "jdbc:postgresql://dbhost:5432/keycloak" \
    "$(db_build_jdbc_url postgresql dbhost 5432 keycloak)" \
    "build PostgreSQL JDBC URL"

assert_equals "jdbc:mysql://myhost:3306/kcdb" \
    "$(db_build_jdbc_url mysql myhost 3306 kcdb)" \
    "build MySQL JDBC URL"

assert_equals "jdbc:mariadb://maria:3307/testdb" \
    "$(db_build_jdbc_url mariadb maria 3307 testdb)" \
    "build MariaDB JDBC URL"

assert_equals "jdbc:oracle:thin:@orahost:1521:ORCL" \
    "$(db_build_jdbc_url oracle orahost 1521 ORCL)" \
    "build Oracle JDBC URL"

assert_equals "jdbc:sqlserver://sqlhost:1433;databaseName=kcdb" \
    "$(db_build_jdbc_url mssql sqlhost 1433 kcdb)" \
    "build MSSQL JDBC URL"

# ============================================================================
describe "DB_DEFAULT_PORTS"
# ============================================================================

assert_equals "5432" "${DB_DEFAULT_PORTS[postgresql]}" "PostgreSQL default port"
assert_equals "3306" "${DB_DEFAULT_PORTS[mysql]}" "MySQL default port"
assert_equals "3306" "${DB_DEFAULT_PORTS[mariadb]}" "MariaDB default port"
assert_equals "1521" "${DB_DEFAULT_PORTS[oracle]}" "Oracle default port"
assert_equals "1433" "${DB_DEFAULT_PORTS[mssql]}" "MSSQL default port"

# ============================================================================
describe "JDBC_PREFIXES"
# ============================================================================

assert_equals "jdbc:postgresql://" "${JDBC_PREFIXES[postgresql]}" "PostgreSQL JDBC prefix"
assert_equals "jdbc:mysql://" "${JDBC_PREFIXES[mysql]}" "MySQL JDBC prefix"
assert_equals "jdbc:mariadb://" "${JDBC_PREFIXES[mariadb]}" "MariaDB JDBC prefix"
assert_equals "jdbc:oracle:thin:@" "${JDBC_PREFIXES[oracle]}" "Oracle JDBC prefix"
assert_equals "jdbc:sqlserver://" "${JDBC_PREFIXES[mssql]}" "MSSQL JDBC prefix"

# ============================================================================
describe "db_adapter_info()"
# ============================================================================

adapter_info=$(db_adapter_info)
assert_contains "$adapter_info" "Database Adapter v3.0" "adapter info header"
assert_contains "$adapter_info" "postgresql" "adapter info lists postgresql"
assert_contains "$adapter_info" "mysql" "adapter info lists mysql"
assert_contains "$adapter_info" "oracle" "adapter info lists oracle"
assert_contains "$adapter_info" "mssql" "adapter info lists mssql"

# ============================================================================
describe "db_build_jdbc_url() with default port"
# ============================================================================

assert_equals "jdbc:postgresql://localhost:5432/mydb" \
    "$(db_build_jdbc_url postgresql localhost '' mydb)" \
    "PostgreSQL with default port fallback"

assert_equals "jdbc:mysql://localhost:3306/mydb" \
    "$(db_build_jdbc_url mysql localhost '' mydb)" \
    "MySQL with default port fallback"

# ============================================================================
describe "db_restore FAILS when pg_restore fails (the rollback path must not lie)"
# ============================================================================
# db_restore is always called from an `if` (db_restore_keycloak), which disables errexit inside it.
# The pg_restore call used to be a bare statement, so its failure was swallowed and the VACUUM block
# that follows supplied the return value: a restore that never happened was reported as a completed
# rollback. Stub pg_client so pg_restore fails and nothing else does.
_dbr_tmp="$(mktemp -d)"
: > "$_dbr_tmp/backup.dump"
pg_client() {
    case "$1" in
        psql)      [[ "$2" == "--version" ]] && { echo "psql (PostgreSQL) 16.1"; return 0; }; return 0 ;;
        pg_restore) return 1 ;;   # the restore fails
        *)         return 0 ;;
    esac
}
pg_verify_backup() { return 0; }
assert_false "db_restore postgresql localhost 5432 kc kcuser pw '$_dbr_tmp/backup.dump' 1 >/dev/null 2>&1" \
    "a failed pg_restore makes db_restore return non-zero"

# …but the NOISE a rollback provokes by design must NOT be called a failure. A live 16 -> 24 -> 26
# rollback emitted 32 such errors (objects the newer schema had already dropped, and a SET a
# pg_dump 17 emits that a 16 server rejects) while restoring the data perfectly.
pg_client() {
    case "$1" in
        psql)       [[ "$2" == "--version" ]] && { echo "psql (PostgreSQL) 16.1"; return 0; }; return 0 ;;
        pg_restore) echo 'pg_restore: error: could not execute query: ERROR:  relation "public.client_session" does not exist' >&2
                    echo 'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"' >&2
                    return 1 ;;
        *)          return 0 ;;
    esac
}
assert_true "db_restore postgresql localhost 5432 kc kcuser pw '$_dbr_tmp/backup.dump' 1 >/dev/null 2>&1" \
    "ignorable pg_restore errors (missing objects / newer-client SET) are NOT a failed rollback"

# A hard error mixed in with the noise still fails.
pg_client() {
    case "$1" in
        psql)       [[ "$2" == "--version" ]] && { echo "psql (PostgreSQL) 16.1"; return 0; }; return 0 ;;
        pg_restore) echo 'pg_restore: error: could not execute query: ERROR:  relation "x" does not exist' >&2
                    echo 'pg_restore: error: connection to server failed: FATAL: password authentication failed' >&2
                    return 1 ;;
        *)          return 0 ;;
    esac
}
assert_false "db_restore postgresql localhost 5432 kc kcuser pw '$_dbr_tmp/backup.dump' 1 >/dev/null 2>&1" \
    "a REAL error among the noise still fails the restore"

pg_client() {
    case "$1" in
        psql)      [[ "$2" == "--version" ]] && { echo "psql (PostgreSQL) 16.1"; return 0; }; return 0 ;;
        *)         return 0 ;;
    esac
}
assert_true "db_restore postgresql localhost 5432 kc kcuser pw '$_dbr_tmp/backup.dump' 1 >/dev/null 2>&1" \
    "a successful pg_restore still returns zero"
unset -f pg_client pg_verify_backup
rm -rf "$_dbr_tmp"

# ============================================================================
# Report
# ============================================================================

test_report
