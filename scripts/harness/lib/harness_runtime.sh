#!/usr/bin/env bash
# harness_runtime.sh — dry-run/live execution chokepoint + lifecycle helpers for
# the v3.7 container-hop migration test harness.
#
# Every engine / DB / network effect goes through _step, so the DEFAULT dry-run
# prints the exact command (secrets pre-masked as ***) and mutates NOTHING; the
# live path (--go) executes the same command. This single chokepoint is what makes
# the harness provably non-mutating in dry-run.

# Include guard
[[ -n "${_HARNESS_RUNTIME_SH:-}" ]] && return 0
_HARNESS_RUNTIME_SH=1

# Logging fallbacks (so the lib is independently sourceable/testable).
declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# ----------------------------------------------------------------------------
# _step "<emit line, secrets already masked as ***>" -- <live-cmd...>
#   dry-run -> print "DRY-RUN: <emit>" and return 0 (live-cmd is NEVER invoked)
#   live    -> log the masked emit line, then execute live-cmd and propagate rc
# ----------------------------------------------------------------------------
_step() {
    local emit="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    if [[ "${HARNESS_DRY_RUN:-true}" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "$emit"
        return 0
    fi
    log_info "RUN: $emit"
    "$@"
}

# ----------------------------------------------------------------------------
# Network + PostgreSQL lifecycle (a fresh, throwaway PG on a user-defined bridge
# so the base KC16 and the Quarkus hops resolve the DB by container name).
# ----------------------------------------------------------------------------
harness_net_up() {
    local net="${HARNESS_NET:-kc-harness-net}"
    _step "cr network create $net" -- cr network create "$net"
}

harness_pg_up() {
    local net="${HARNESS_NET:-kc-harness-net}"
    local pg="${HARNESS_PG_NAME:-kc-harness-pg}"
    local img="${HARNESS_PG_IMAGE:-postgres:16}"
    _step "cr run -d --name $pg --network $net -e POSTGRES_DB=keycloak -e POSTGRES_USER=keycloak -e POSTGRES_PASSWORD=*** $img" -- \
        cr run -d --name "$pg" --network "$net" \
            -e POSTGRES_DB=keycloak -e POSTGRES_USER=keycloak \
            -e POSTGRES_PASSWORD="${HARNESS_DB_PASSWORD:-}" "$img"
    _step "wait: pg_isready -h $pg (fresh clean database)" -- harness_wait_pg
}

# Boot base Keycloak 16.x (WildFly env scheme) to initialise the base schema
# incl. the MIGRATION_MODEL table, then stop it. NOTE: KC16 is WildFly, so it
# uses DB_VENDOR/DB_ADDR + KEYCLOAK_USER — NOT the Quarkus KC_DB_URL that the
# hops use (deployment_adapter.sh:532-539).
harness_boot_base16() {
    local net="${HARNESS_NET:-kc-harness-net}"
    local pg="${HARNESS_PG_NAME:-kc-harness-pg}"
    local kc="${HARNESS_KC16_NAME:-kc-harness-16}"
    local img="${HARNESS_KC16_IMAGE:-quay.io/keycloak/keycloak:16.1.1}"
    local admin="${HARNESS_KC_ADMIN:-admin}"

    # Pin JGroups to loopback. The WildFly-based KC16 images boot in an HA profile whose JGroups
    # subsystem binds a UDP socket to the private interface; left to auto-detect it picks the
    # container's bridge/gateway address (e.g. 172.x.0.1) and fails with "not a valid address on any
    # local network interface". That failure cascades — dozens of services stay down and Keycloak
    # never reaches its Liquibase step, so the schema is never created and the seeder finds an empty
    # database. Loopback is always a valid bind here, and this container talks to Postgres over the
    # bridge, not JGroups. Overridable for images that need different opts.
    local jopts="${HARNESS_KC16_JAVA_OPTS:--Djboss.bind.address.private=127.0.0.1 -Djgroups.bind_addr=127.0.0.1}"

    _step "cr run -d --name $kc --network $net -e DB_VENDOR=postgres -e DB_ADDR=$pg -e DB_DATABASE=keycloak -e DB_USER=keycloak -e DB_PASSWORD=*** -e KEYCLOAK_USER=$admin -e KEYCLOAK_PASSWORD=*** -e JAVA_OPTS_APPEND='$jopts' $img" -- \
        cr run -d --name "$kc" --network "$net" \
            -e DB_VENDOR=postgres -e DB_ADDR="$pg" -e DB_DATABASE=keycloak \
            -e DB_USER=keycloak -e DB_PASSWORD="${HARNESS_DB_PASSWORD:-}" \
            -e KEYCLOAK_USER="$admin" -e KEYCLOAK_PASSWORD="${HARNESS_KC_ADMIN_PASSWORD:-}" \
            -e JAVA_OPTS_APPEND="$jopts" "$img"
    _step "wait: KC16 schema init (log 'Admin console listening' / Liquibase update) on $kc" -- harness_wait_kc16
}

harness_teardown() {
    local net="${HARNESS_NET:-kc-harness-net}"
    local pg="${HARNESS_PG_NAME:-kc-harness-pg}"
    local kc="${HARNESS_KC16_NAME:-kc-harness-16}"
    _step "cr stop/rm $kc $pg ; cr network rm $net" -- harness_teardown_live
}

# ----------------------------------------------------------------------------
# Live-only waiters / teardown (invoked only on the --go path; in dry-run they
# are emitted by _step and never executed).
# ----------------------------------------------------------------------------
harness_wait_pg() {
    local pg="${HARNESS_PG_NAME:-kc-harness-pg}" i
    for ((i = 0; i < 30; i++)); do
        cr exec "$pg" pg_isready -U keycloak >/dev/null 2>&1 && { log_success "PostgreSQL ready"; return 0; }
        sleep 2
    done
    log_error "PostgreSQL did not become ready"; return 1
}

harness_wait_kc16() {
    local kc="${HARNESS_KC16_NAME:-kc-harness-16}" i
    for ((i = 0; i < 60; i++)); do
        if cr logs "$kc" 2>&1 | grep -qiE 'Admin console listening|Keycloak .* started|update.* was executed successfully'; then
            log_success "KC16 base schema initialised"
            cr stop "$kc" >/dev/null 2>&1 || true
            return 0
        fi
        sleep 2
    done
    log_error "KC16 did not finish schema init in time"; return 1
}

harness_teardown_live() {
    local net="${HARNESS_NET:-kc-harness-net}"
    local pg="${HARNESS_PG_NAME:-kc-harness-pg}"
    local kc="${HARNESS_KC16_NAME:-kc-harness-16}"
    cr stop "$kc" "$pg" >/dev/null 2>&1 || true
    cr rm "$kc" "$pg" >/dev/null 2>&1 || true
    cr network rm "$net" >/dev/null 2>&1 || true
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f _step harness_net_up harness_pg_up harness_boot_base16 harness_teardown
    export -f harness_wait_pg harness_wait_kc16 harness_teardown_live
fi
