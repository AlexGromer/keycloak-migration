#!/usr/bin/env bash
# Tests: Deployment Adapter
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/scripts/lib/deployment_adapter.sh"

# ============================================================================
describe "deploy_validate_mode()"
# ============================================================================

assert_true "deploy_validate_mode standalone" "standalone is valid"
assert_true "deploy_validate_mode docker" "docker is valid"
assert_true "deploy_validate_mode docker-compose" "docker-compose is valid"
assert_true "deploy_validate_mode kubernetes" "kubernetes is valid"
assert_true "deploy_validate_mode deckhouse" "deckhouse is valid"
assert_false "deploy_validate_mode podman 2>/dev/null" "podman is invalid"
assert_false "deploy_validate_mode nomad 2>/dev/null" "nomad is invalid"

# ============================================================================
describe "DEPLOY_MODES registry"
# ============================================================================

assert_not_empty "${DEPLOY_MODES[standalone]}" "standalone has description"
assert_not_empty "${DEPLOY_MODES[docker]}" "docker has description"
assert_not_empty "${DEPLOY_MODES[docker-compose]}" "docker-compose has description"
assert_not_empty "${DEPLOY_MODES[kubernetes]}" "kubernetes has description"
assert_not_empty "${DEPLOY_MODES[deckhouse]}" "deckhouse has description"

# ============================================================================
describe "kc_get_config_path()"
# ============================================================================

assert_equals "/opt/keycloak/conf/keycloak.conf" \
    "$(kc_get_config_path standalone /opt/keycloak)" \
    "standalone config path"

assert_equals "/opt/keycloak/conf/keycloak.conf" \
    "$(kc_get_config_path docker)" \
    "docker config path"

assert_equals "configmap/keycloak-config" \
    "$(kc_get_config_path kubernetes)" \
    "kubernetes config path"

# ============================================================================
describe "deploy_adapter_info()"
# ============================================================================

adapter_info=$(deploy_adapter_info)
assert_contains "$adapter_info" "Deployment Adapter v3.0" "adapter info header"
assert_contains "$adapter_info" "standalone" "adapter info lists standalone"
assert_contains "$adapter_info" "docker" "adapter info lists docker"
assert_contains "$adapter_info" "kubernetes" "adapter info lists kubernetes"
assert_contains "$adapter_info" "deckhouse" "adapter info lists deckhouse"

# ============================================================================
# Report
# ============================================================================

test_report
