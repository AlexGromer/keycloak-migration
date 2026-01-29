#!/usr/bin/env bash
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
# Report
# ============================================================================

test_report
