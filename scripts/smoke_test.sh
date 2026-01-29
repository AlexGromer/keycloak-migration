#!/bin/bash
#
# Smoke Tests for Keycloak Migration
# Runs after each migration step to verify functionality
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
KC_URL="${KC_URL:-http://localhost:8080/auth}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
TIMEOUT=10

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=7

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; ((TESTS_PASSED++)); }
log_error() { echo -e "${RED}[✗]${NC} $1"; ((TESTS_FAILED++)); }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }

#######################################
# Test helpers
#######################################
http_get() {
    local url="$1"
    local auth="${2:-}"
    local max_time="${3:-$TIMEOUT}"

    local args=(
        -sf
        --max-time "$max_time"
        -w "\n%{http_code}"
    )

    if [[ -n "$auth" ]]; then
        args+=(-H "Authorization: Bearer $auth")
    fi

    curl "${args[@]}" "$url" 2>/dev/null
}

http_post() {
    local url="$1"
    local data="$2"
    local max_time="${3:-$TIMEOUT}"

    curl -sf --max-time "$max_time" \
        -X POST "$url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "$data" \
        2>/dev/null
}

#######################################
# Tests
#######################################
test_health_endpoint() {
    log_info "[1/$TESTS_TOTAL] Testing health endpoint..."

    local response=$(http_get "${KC_URL}/health" "" 5)
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [[ "$status" == "200" ]] && echo "$body" | grep -q "UP"; then
        log_success "Health endpoint OK"
        return 0
    else
        log_error "Health endpoint FAILED (HTTP $status)"
        echo "Response: $body" | head -5
        return 1
    fi
}

test_master_realm() {
    log_info "[2/$TESTS_TOTAL] Testing master realm accessibility..."

    local response=$(http_get "${KC_URL}/realms/master")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [[ "$status" == "200" ]] && echo "$body" | grep -q '"realm":"master"'; then
        log_success "Master realm accessible"
        return 0
    else
        log_error "Master realm FAILED (HTTP $status)"
        return 1
    fi
}

test_admin_login() {
    log_info "[3/$TESTS_TOTAL] Testing admin login..."

    local token=$(http_post "${KC_URL}/realms/master/protocol/openid-connect/token" \
        "grant_type=password&client_id=admin-cli&username=$ADMIN_USER&password=$ADMIN_PASS" 10 \
        | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

    if [[ -n "$token" ]] && [[ "${#token}" -gt 50 ]]; then
        log_success "Admin login OK (token length: ${#token})"
        echo "$token" > /tmp/kc_admin_token.tmp
        return 0
    else
        log_error "Admin login FAILED (no token received)"
        return 1
    fi
}

test_list_realms() {
    log_info "[4/$TESTS_TOTAL] Testing list realms..."

    local token=$(cat /tmp/kc_admin_token.tmp 2>/dev/null || echo "")
    if [[ -z "$token" ]]; then
        log_error "List realms SKIPPED (no admin token)"
        return 1
    fi

    local response=$(http_get "${KC_URL}/admin/realms" "$token")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [[ "$status" == "200" ]]; then
        local realms_count=$(echo "$body" | grep -o '"realm":"[^"]*' | wc -l)
        if [[ "$realms_count" -gt 0 ]]; then
            log_success "List realms OK ($realms_count found)"
            return 0
        else
            log_error "List realms FAILED (no realms found)"
            return 1
        fi
    else
        log_error "List realms FAILED (HTTP $status)"
        return 1
    fi
}

test_list_users() {
    log_info "[5/$TESTS_TOTAL] Testing list users..."

    local token=$(cat /tmp/kc_admin_token.tmp 2>/dev/null || echo "")
    if [[ -z "$token" ]]; then
        log_error "List users SKIPPED (no admin token)"
        return 1
    fi

    local response=$(http_get "${KC_URL}/admin/realms/master/users" "$token")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [[ "$status" == "200" ]]; then
        local users_count=$(echo "$body" | grep -o '"id":"[^"]*' | wc -l)
        if [[ "$users_count" -gt 0 ]]; then
            log_success "List users OK ($users_count found)"
            return 0
        else
            log_error "List users FAILED (no users found)"
            return 1
        fi
    else
        log_error "List users FAILED (HTTP $status)"
        return 1
    fi
}

test_list_clients() {
    log_info "[6/$TESTS_TOTAL] Testing list clients..."

    local token=$(cat /tmp/kc_admin_token.tmp 2>/dev/null || echo "")
    if [[ -z "$token" ]]; then
        log_error "List clients SKIPPED (no admin token)"
        return 1
    fi

    local response=$(http_get "${KC_URL}/admin/realms/master/clients" "$token")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [[ "$status" == "200" ]]; then
        local clients_count=$(echo "$body" | grep -o '"clientId":"[^"]*' | wc -l)
        if [[ "$clients_count" -gt 0 ]]; then
            log_success "List clients OK ($clients_count found)"
            return 0
        else
            log_error "List clients FAILED (no clients found)"
            return 1
        fi
    else
        log_error "List clients FAILED (HTTP $status)"
        return 1
    fi
}

test_providers_loaded() {
    log_info "[7/$TESTS_TOTAL] Testing providers loaded..."

    local token=$(cat /tmp/kc_admin_token.tmp 2>/dev/null || echo "")
    if [[ -z "$token" ]]; then
        log_error "Providers check SKIPPED (no admin token)"
        return 1
    fi

    local response=$(http_get "${KC_URL}/admin/serverinfo" "$token" 15)
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [[ "$status" == "200" ]] && echo "$body" | grep -q '"providers"'; then
        # Count some key provider categories
        local auth_providers=$(echo "$body" | grep -o '"authenticator"' | wc -l)
        log_success "Providers loaded (authenticator: $auth_providers+)"
        return 0
    else
        log_error "Providers check FAILED (HTTP $status)"
        return 1
    fi
}

#######################################
# Cleanup
#######################################
cleanup() {
    rm -f /tmp/kc_admin_token.tmp
}
trap cleanup EXIT

#######################################
# Main
#######################################
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Smoke Tests                                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "Testing: $KC_URL"
    log_info "Admin user: $ADMIN_USER"
    echo ""

    # Wait for KC to be ready
    log_info "Waiting for Keycloak to be ready..."
    local retry=0
    while [[ $retry -lt 30 ]]; do
        if curl -sf --max-time 5 "${KC_URL}/health" &>/dev/null; then
            log_success "Keycloak is ready"
            break
        fi
        sleep 2
        ((retry++))
    done

    if [[ $retry -ge 30 ]]; then
        log_error "Keycloak did not become ready in 60 seconds"
        exit 1
    fi

    # Run tests
    log_section "RUNNING TESTS"

    test_health_endpoint || true
    test_master_realm || true
    test_admin_login || true
    test_list_realms || true
    test_list_users || true
    test_list_clients || true
    test_providers_loaded || true

    # Summary
    log_section "TEST SUMMARY"

    echo ""
    echo "Tests passed: ${GREEN}$TESTS_PASSED${NC}/$TESTS_TOTAL"
    echo "Tests failed: ${RED}$TESTS_FAILED${NC}/$TESTS_TOTAL"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ ALL TESTS PASSED${NC}"
        echo ""
        echo "Keycloak migration verification: ${GREEN}SUCCESS${NC}"
        exit 0
    else
        echo -e "${RED}${BOLD}✗ SOME TESTS FAILED${NC}"
        echo ""
        echo "Keycloak migration verification: ${RED}FAILED${NC}"
        echo ""
        echo "Check:"
        echo "  - Keycloak logs"
        echo "  - Database state"
        echo "  - Network connectivity"
        exit 1
    fi
}

main "$@"
