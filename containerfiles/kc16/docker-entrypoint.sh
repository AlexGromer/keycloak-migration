#!/usr/bin/env bash
# docker-entrypoint.sh — WildFly Keycloak 16.1.1 entrypoint SCAFFOLD (Phase A).
#
# Minimal, honest scaffold: creates the admin user (if requested) and boots WildFly
# standalone. The official keycloak-containers:16.1.1 entrypoint additionally wires a
# PostgreSQL JDBC module + datasource via jboss-cli; that datasource wiring is a
# Phase-B hardening item (do it here or bake it into the image at build time). KC16
# also reads DB_VENDOR/DB_ADDR/DB_DATABASE/DB_USER/DB_PASSWORD for the H2->postgres
# switch — wire those into a CLI step when hardening.
set -eo pipefail

KEYCLOAK_DIR="${JBOSS_HOME:-/opt/jboss/keycloak}"

# Create the initial admin user once (idempotent best-effort).
if [[ -n "${KEYCLOAK_USER:-}" && -n "${KEYCLOAK_PASSWORD:-}" ]]; then
    "${KEYCLOAK_DIR}/bin/add-user-keycloak.sh" \
        --user "${KEYCLOAK_USER}" --password "${KEYCLOAK_PASSWORD}" 2>/dev/null || true
fi

# TODO(Phase B): configure the postgres datasource from DB_* via jboss-cli before start
# (module add org.postgresql + /subsystem=datasources ... ), matching the migration
# tool's expectation that KC16 runs Liquibase against the target PostgreSQL on boot.

exec "${KEYCLOAK_DIR}/bin/standalone.sh" "$@"
