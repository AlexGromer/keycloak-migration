#!/usr/bin/env bash
# harness_seed.sh — random synthetic seeder for the migration harness.
#
# Seeds realms/users/clients through the base KC16 container's Admin CLI (kcadm),
# so every row is written THROUGH Keycloak's own model (correct FKs, hashed
# credentials, realm defaults) and therefore survives the 16 -> 24 -> 26 hops —
# which is exactly the data whose survival the integrity gate measures. Raw SQL
# INSERTs are intentionally avoided (brittle across schema changes).
#
# Volume knobs: HARNESS_SEED_REALMS / HARNESS_SEED_USERS / HARNESS_SEED_CLIENTS.

# Include guard
[[ -n "${_HARNESS_SEED_SH:-}" ]] && return 0
_HARNESS_SEED_SH=1

declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# kcadm path inside the WildFly-based quay.io/keycloak/keycloak:16.1.1 image.
HARNESS_KCADM="${HARNESS_KCADM:-/opt/jboss/keycloak/bin/kcadm.sh}"

# harness_seed — create random realms/users/clients via kcadm against base KC16.
harness_seed() {
    local kc="${HARNESS_KC16_NAME:-kc-harness-16}"
    local admin="${HARNESS_KC_ADMIN:-admin}"
    local realms="${HARNESS_SEED_REALMS:-3}"
    local users="${HARNESS_SEED_USERS:-50}"
    local clients="${HARNESS_SEED_CLIENTS:-10}"

    log_info "Seeding random data: ${realms} realms x (${users} users + ${clients} clients) via kcadm"

    if [[ "${HARNESS_DRY_RUN:-true}" == "true" ]]; then
        # Print a readable SUMMARY of the plan instead of hundreds of create lines.
        printf 'DRY-RUN: %s\n' "cr exec $kc $HARNESS_KCADM config credentials --server http://localhost:8080/auth --realm master --user $admin --password ***"
        printf 'DRY-RUN: %s\n' "cr exec $kc $HARNESS_KCADM create realms -s realm=r-<rand> -s enabled=true   (x ${realms} realms)"
        printf 'DRY-RUN: %s\n' "cr exec $kc $HARNESS_KCADM create users -r <realm> -s username=u-<rand> -s enabled=true   (x ${users} per realm)"
        printf 'DRY-RUN: %s\n' "cr exec $kc $HARNESS_KCADM create clients -r <realm> -s clientId=c-<rand> -s enabled=true   (x ${clients} per realm)"
        return 0
    fi

    cr exec "$kc" "$HARNESS_KCADM" config credentials \
        --server http://localhost:8080/auth --realm master \
        --user "$admin" --password "${HARNESS_KC_ADMIN_PASSWORD:-}" || {
        log_error "kcadm authentication failed"; return 1
    }

    local i j realm
    for ((i = 1; i <= realms; i++)); do
        realm="r-${i}-${RANDOM}"
        cr exec "$kc" "$HARNESS_KCADM" create realms -s "realm=${realm}" -s enabled=true || {
            log_error "failed to create realm ${realm}"; return 1
        }
        for ((j = 1; j <= users; j++)); do
            cr exec "$kc" "$HARNESS_KCADM" create users -r "$realm" -s "username=u-${RANDOM}" -s enabled=true || true
        done
        for ((j = 1; j <= clients; j++)); do
            cr exec "$kc" "$HARNESS_KCADM" create clients -r "$realm" -s "clientId=c-${RANDOM}" -s enabled=true || true
        done
        log_info "seeded realm ${realm}: ${users} users, ${clients} clients"
    done
    log_success "seed complete: ${realms} realms"
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f harness_seed
fi
