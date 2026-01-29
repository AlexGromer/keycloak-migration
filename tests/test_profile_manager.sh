#!/usr/bin/env bash
# Tests: Profile Manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Override PROFILE_DIR for tests
export PROFILE_DIR="$PROJECT_ROOT/profiles"

# Source module under test (disable set -e temporarily for sourcing)
source "$PROJECT_ROOT/scripts/lib/profile_manager.sh"

# ============================================================================
describe "parse_yaml_value()"
# ============================================================================

assert_equals "standalone-postgresql" \
    "$(parse_yaml_value "name" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse profile name"

assert_equals "postgresql" \
    "$(parse_yaml_value "type" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse database type"

assert_equals "localhost" \
    "$(parse_yaml_value "host" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse host (with inline comment)"

assert_equals "5432" \
    "$(parse_yaml_value "port" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse port (with inline comment)"

# "name" appears multiple times — parse_yaml_value returns first match (profile.name)
# Use parse_yaml_section_value for section-specific keys
assert_equals "keycloak" \
    "$(parse_yaml_section_value "database" "name" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse database name (section-aware)"

assert_equals "standalone" \
    "$(parse_yaml_value "deployment_mode" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse deployment mode"

assert_equals "download" \
    "$(parse_yaml_value "distribution_mode" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse distribution mode (with inline comment)"

assert_equals "16.1.1" \
    "$(parse_yaml_value "current_version" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse current version"

assert_equals "26.0.7" \
    "$(parse_yaml_value "target_version" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse target version"

assert_equals "inplace" \
    "$(parse_yaml_value "strategy" "$PROFILE_DIR/standalone-postgresql.yaml")" \
    "parse migration strategy (with inline comment)"

# ============================================================================
describe "profile_load()"
# ============================================================================

# Load standalone-postgresql profile
profile_load "standalone-postgresql" >/dev/null 2>&1

assert_equals "postgresql" "$PROFILE_DB_TYPE" "PROFILE_DB_TYPE set correctly"
assert_equals "standalone" "$PROFILE_DB_LOCATION" "PROFILE_DB_LOCATION set correctly"
assert_equals "localhost" "$PROFILE_DB_HOST" "PROFILE_DB_HOST set correctly"
assert_equals "5432" "$PROFILE_DB_PORT" "PROFILE_DB_PORT set correctly"
assert_equals "keycloak" "$PROFILE_DB_NAME" "PROFILE_DB_NAME set correctly"
assert_equals "keycloak" "$PROFILE_DB_USER" "PROFILE_DB_USER set correctly"
assert_equals "standalone" "$PROFILE_KC_DEPLOYMENT_MODE" "PROFILE_KC_DEPLOYMENT_MODE set correctly"
assert_equals "download" "$PROFILE_KC_DISTRIBUTION_MODE" "PROFILE_KC_DISTRIBUTION_MODE set correctly"
assert_equals "16.1.1" "$PROFILE_KC_CURRENT_VERSION" "PROFILE_KC_CURRENT_VERSION set correctly"
assert_equals "26.0.7" "$PROFILE_KC_TARGET_VERSION" "PROFILE_KC_TARGET_VERSION set correctly"
assert_equals "inplace" "$PROFILE_MIGRATION_STRATEGY" "PROFILE_MIGRATION_STRATEGY set correctly"
assert_equals "4" "$PROFILE_MIGRATION_PARALLEL_JOBS" "PROFILE_MIGRATION_PARALLEL_JOBS set correctly"
assert_equals "900" "$PROFILE_MIGRATION_TIMEOUT" "PROFILE_MIGRATION_TIMEOUT set correctly"
assert_equals "true" "$PROFILE_MIGRATION_RUN_TESTS" "PROFILE_MIGRATION_RUN_TESTS set correctly"
assert_equals "true" "$PROFILE_MIGRATION_BACKUP" "PROFILE_MIGRATION_BACKUP set correctly"

# ============================================================================
describe "profile_load() — MySQL profile"
# ============================================================================

profile_load "standalone-mysql" >/dev/null 2>&1

assert_equals "mysql" "$PROFILE_DB_TYPE" "MySQL profile: DB type"
assert_equals "standalone" "$PROFILE_KC_DEPLOYMENT_MODE" "MySQL profile: deployment mode"

# ============================================================================
describe "profile_exists()"
# ============================================================================

assert_true "profile_exists standalone-postgresql" "standalone-postgresql exists"
assert_true "profile_exists standalone-mysql" "standalone-mysql exists"
assert_true "profile_exists docker-compose-dev" "docker-compose-dev exists"
assert_true "profile_exists kubernetes-cluster-production" "kubernetes-cluster-production exists"
assert_false "profile_exists nonexistent-profile" "nonexistent profile returns false"

# ============================================================================
describe "profile_list()"
# ============================================================================

profile_list_output=$(profile_list)
assert_contains "$profile_list_output" "standalone-postgresql" "profile_list includes standalone-postgresql"
assert_contains "$profile_list_output" "standalone-mysql" "profile_list includes standalone-mysql"
assert_contains "$profile_list_output" "docker-compose-dev" "profile_list includes docker-compose-dev"
assert_contains "$profile_list_output" "kubernetes-cluster-production" "profile_list includes kubernetes-cluster-production"

# ============================================================================
describe "profile_save() and round-trip"
# ============================================================================

# Set variables and save to temp profile
export PROFILE_DB_TYPE="mariadb"
export PROFILE_DB_LOCATION="docker"
export PROFILE_DB_HOST="db.example.com"
export PROFILE_DB_PORT="3307"
export PROFILE_DB_NAME="kc_test"
export PROFILE_DB_USER="admin"
export PROFILE_DB_CREDENTIALS_SOURCE="vault"
export PROFILE_KC_DEPLOYMENT_MODE="standalone"
export PROFILE_KC_DISTRIBUTION_MODE="predownloaded"
export PROFILE_KC_CLUSTER_MODE="standalone"
export PROFILE_KC_CURRENT_VERSION="17.0.1"
export PROFILE_KC_TARGET_VERSION="25.0.6"
export PROFILE_MIGRATION_STRATEGY="inplace"
export PROFILE_MIGRATION_PARALLEL_JOBS="2"
export PROFILE_MIGRATION_TIMEOUT="600"
export PROFILE_MIGRATION_RUN_TESTS="false"
export PROFILE_MIGRATION_BACKUP="true"

profile_save "test-roundtrip" >/dev/null

assert_file_exists "$PROFILE_DIR/test-roundtrip.yaml" "saved profile file exists"

# Reload and verify round-trip
profile_load "test-roundtrip" >/dev/null 2>&1

assert_equals "mariadb" "$PROFILE_DB_TYPE" "round-trip: DB type"
assert_equals "db.example.com" "$PROFILE_DB_HOST" "round-trip: host"
assert_equals "3307" "$PROFILE_DB_PORT" "round-trip: port"
assert_equals "kc_test" "$PROFILE_DB_NAME" "round-trip: DB name"
assert_equals "predownloaded" "$PROFILE_KC_DISTRIBUTION_MODE" "round-trip: distribution mode"
assert_equals "17.0.1" "$PROFILE_KC_CURRENT_VERSION" "round-trip: current version"
assert_equals "25.0.6" "$PROFILE_KC_TARGET_VERSION" "round-trip: target version"
assert_equals "2" "$PROFILE_MIGRATION_PARALLEL_JOBS" "round-trip: parallel jobs"
assert_equals "600" "$PROFILE_MIGRATION_TIMEOUT" "round-trip: timeout"

# Cleanup
rm -f "$PROFILE_DIR/test-roundtrip.yaml"

# ============================================================================
describe "profile_create_template()"
# ============================================================================

profile_create_template "standalone" >/dev/null
assert_equals "postgresql" "$PROFILE_DB_TYPE" "template standalone: DB type"
assert_equals "standalone" "$PROFILE_KC_DEPLOYMENT_MODE" "template standalone: deployment mode"
assert_equals "download" "$PROFILE_KC_DISTRIBUTION_MODE" "template standalone: distribution mode"

profile_create_template "kubernetes" >/dev/null
assert_equals "postgresql" "$PROFILE_DB_TYPE" "template k8s: DB type"
assert_equals "kubernetes" "$PROFILE_KC_DEPLOYMENT_MODE" "template k8s: deployment mode"
assert_equals "container" "$PROFILE_KC_DISTRIBUTION_MODE" "template k8s: distribution mode"
assert_equals "infinispan" "$PROFILE_KC_CLUSTER_MODE" "template k8s: cluster mode"
assert_equals "rolling_update" "$PROFILE_MIGRATION_STRATEGY" "template k8s: strategy"
assert_equals "3" "${PROFILE_K8S_REPLICAS}" "template k8s: replicas"

profile_create_template "docker" >/dev/null
assert_equals "docker-compose" "$PROFILE_KC_DEPLOYMENT_MODE" "template docker: deployment mode"
assert_equals "container" "$PROFILE_KC_DISTRIBUTION_MODE" "template docker: distribution mode"

# ============================================================================
# Report
# ============================================================================

test_report
