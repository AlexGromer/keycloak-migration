#!/usr/bin/env bash
# run_migration_harness.sh — Phase 1 test harness for the v3.7 container-hop migration.
#
# Spins a FRESH clean PostgreSQL -> boots base Keycloak 16.x to init the schema ->
# seeds RANDOM realms/users/clients -> runs the FULL hop chain (16.1.1 -> 24.0.5 ->
# 26.6.3) -> after each hop verifies L1 (Liquibase), L2 (MIGRATION_MODEL) and data
# integrity (row counts survive). Base image = sovereign OS (Astra SE / RedOS),
# with override of both base and final images.
#
# DEFAULT = dry-run: prints every build/run/L1/L2/integrity command, MUTATES NOTHING.
# Live execution requires the explicit --go flag (Phase 2) plus DB/admin secrets.
#
# Usage:
#   run_migration_harness.sh [--dry-run|--go] [--profile NAME]
#                            [--os-base-image IMG] [--image-ref TPL] [--final-ref REF]
#                            [--preset astra|redos] [--pg-image IMG]
#                            [--realms N] [--users N] [--clients N]

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_LIB="$HARNESS_DIR/lib"
PROJECT_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
LIB_DIR="$SCRIPTS_DIR/lib"

# Contain all source-time writes: migrate_keycloak_v3.sh does `mkdir -p WORK_DIR`
# at source time — point it at scratch so sourcing never touches the project tree.
HARNESS_WORK_DIR="${HARNESS_WORK_DIR:-$(mktemp -d)}"
export HARNESS_WORK_DIR
export WORK_DIR="$HARNESS_WORK_DIR"

# Reuse the migration tool's functions (main is guarded -> no side effects):
#   kc_build_migration_path, MIGRATION_HOPS, wait_for_migration, dist_image_ref,
#   kc_run_migrating_container, kc_run_stop_container, kc_verify_migration_model.
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/migrate_keycloak_v3.sh"
# img_build is not sourced by v3 — pull it in explicitly (include-guarded).
# shellcheck source=/dev/null
source "$LIB_DIR/image_builder.sh"
# Harness libs.
# shellcheck source=/dev/null
source "$HARNESS_LIB/harness_runtime.sh"
# shellcheck source=/dev/null
source "$HARNESS_LIB/harness_seed.sh"
# shellcheck source=/dev/null
source "$HARNESS_LIB/harness_integrity.sh"

# Harness defaults (override via env).
HARNESS_NET="${HARNESS_NET:-kc-harness-net}"
HARNESS_PG_NAME="${HARNESS_PG_NAME:-kc-harness-pg}"
HARNESS_PG_IMAGE="${HARNESS_PG_IMAGE:-postgres:16}"
HARNESS_KC16_NAME="${HARNESS_KC16_NAME:-kc-harness-16}"
HARNESS_KC16_IMAGE="${HARNESS_KC16_IMAGE:-quay.io/keycloak/keycloak:16.1.1}"
HARNESS_KC_ADMIN="${HARNESS_KC_ADMIN:-admin}"
# Secrets — empty by default; required only for live (--go). Never hard-coded.
HARNESS_DB_PASSWORD="${HARNESS_DB_PASSWORD:-}"
HARNESS_KC_ADMIN_PASSWORD="${HARNESS_KC_ADMIN_PASSWORD:-}"
export HARNESS_NET HARNESS_PG_NAME HARNESS_PG_IMAGE HARNESS_KC16_NAME \
       HARNESS_KC16_IMAGE HARNESS_KC_ADMIN HARNESS_DB_PASSWORD HARNESS_KC_ADMIN_PASSWORD

harness_usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ----------------------------------------------------------------------------
# Run one hop: build (FROM sovereign base) -> run (Quarkus) -> L1 -> L2 -> integrity -> stop
# ----------------------------------------------------------------------------
harness_run_hop() {
    local v="$1" is_last="${2:-false}"
    local cname="kc-migrate-${v}"
    # Per-hop run container name + work around the run-mode L1 log-name lookup
    # (wait_for_migration reads PROFILE_KC_CONTAINER_NAME; container is kc-migrate-<v>).
    export PROFILE_KC_RUN_CONTAINER_NAME="$cname"
    export PROFILE_KC_CONTAINER_NAME="$cname"

    local jdk=17
    [[ "$v" == 26* ]] && jdk=21

    # Optional: override JUST the final hop's image ref.
    local saved_ref="${PROFILE_CONTAINER_IMAGE_REF:-}"
    if [[ "$is_last" == "true" && -n "${HARNESS_FINAL_REF:-}" ]]; then
        export PROFILE_CONTAINER_IMAGE_REF="$HARNESS_FINAL_REF"
    fi

    local ref
    ref="$(dist_image_ref "$v")"

    echo ""
    log_info "==> HOP ${v}  (jdk=${jdk}, image=${ref}, container=${cname})"

    # Acquire: build FROM the sovereign base OS (only acquisition mode supported in Phase 1).
    _step "img_build $v ${PROFILE_CONTAINER_BASE_IMAGE:-<base>} jdk=$jdk  ->  cr build --build-arg KC_BASE_IMAGE=${PROFILE_CONTAINER_BASE_IMAGE:-<base>} --build-arg KC_VERSION=$v --build-arg JDK_VERSION=$jdk -t $ref -f containerfiles/Containerfile.kc ." -- \
        img_build "$v" "${PROFILE_CONTAINER_BASE_IMAGE:-}" "$jdk"

    # Run the transient migrating container (Quarkus env). This function self-emits
    # its own "DRY-RUN: cr run ..." line when DRY_RUN=true (deployment_adapter.sh:527).
    kc_run_migrating_container "$v" 2>&1

    # L1 — Liquibase schema applied.
    _step "wait_for_migration $v  (L1: Liquibase 'update' executed successfully on $cname)" -- \
        wait_for_migration "$v"

    # L2 — MIGRATION_MODEL model version advanced.
    _step "kc_verify_migration_model $v  (L2: SELECT version FROM MIGRATION_MODEL ORDER BY update_time DESC LIMIT 1; major.minor == $v)" -- \
        kc_verify_migration_model "$v"

    # Data integrity — row counts survive the hop.
    harness_integrity_check "$v"

    # Tear down the transient container before the next hop.
    _step "kc_run_stop_container $cname  (cr stop/rm)" -- kc_run_stop_container "$cname"

    export PROFILE_CONTAINER_IMAGE_REF="$saved_ref"
}

harness_main() {
    local profile="test-harness-sovereign"
    local opt_base="" opt_image_ref="" opt_final_ref="" preset=""
    HARNESS_DRY_RUN="true"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)        HARNESS_DRY_RUN="true"; shift ;;
            --go)             HARNESS_DRY_RUN="false"; shift ;;
            --profile)        profile="${2:-}"; shift 2 ;;
            --os-base-image)  opt_base="${2:-}"; shift 2 ;;
            --image-ref)      opt_image_ref="${2:-}"; shift 2 ;;
            --final-ref)      opt_final_ref="${2:-}"; shift 2 ;;
            --preset)         preset="${2:-}"; shift 2 ;;
            --pg-image)       HARNESS_PG_IMAGE="${2:-}"; shift 2 ;;
            --realms)         HARNESS_SEED_REALMS="${2:-}"; shift 2 ;;
            --users)          HARNESS_SEED_USERS="${2:-}"; shift 2 ;;
            --clients)        HARNESS_SEED_CLIENTS="${2:-}"; shift 2 ;;
            -h|--help)        harness_usage; return 0 ;;
            *) log_error "unknown argument: $1"; harness_usage; return 2 ;;
        esac
    done

    export HARNESS_DRY_RUN
    # Drive the reused functions' own DRY_RUN guard from our mode.
    export DRY_RUN="$HARNESS_DRY_RUN"

    # Load the profile, then apply CLI overrides AFTER load so they win.
    if ! profile_load "$profile"; then
        log_error "failed to load profile '$profile'"; return 1
    fi

    # Preset placeholders (real official refs supplied via --os-base-image or Phase-2 research).
    case "$preset" in
        astra) : "${opt_base:=registry.astralinux.example/astra/se:latest}" ;;
        redos) : "${opt_base:=registry.red-soft.example/redos:latest}" ;;
        "")    ;;
        *) log_error "unknown --preset '$preset' (expected astra|redos)"; return 2 ;;
    esac

    [[ -n "$opt_base" ]]      && export PROFILE_CONTAINER_BASE_IMAGE="$opt_base"
    [[ -n "$opt_image_ref" ]] && export PROFILE_CONTAINER_IMAGE_REF="$opt_image_ref"
    [[ -n "$opt_final_ref" ]] && export HARNESS_FINAL_REF="$opt_final_ref"

    # base_image / image_ref carry ':' (registry refs) which the flat YAML parser
    # cannot represent, so they live here as env defaults (CLI overrides win).
    # NB: assign image_ref explicitly (single-quoted) — a literal '}' inside a
    # ${var:=...} default would prematurely close the expansion.
    [[ -n "${PROFILE_CONTAINER_BASE_IMAGE:-}" ]] || PROFILE_CONTAINER_BASE_IMAGE='registry.local/redos:latest'  # PLACEHOLDER
    [[ -n "${PROFILE_CONTAINER_IMAGE_REF:-}" ]]  || PROFILE_CONTAINER_IMAGE_REF='localhost/kc-harness:{version}'
    export PROFILE_CONTAINER_BASE_IMAGE PROFILE_CONTAINER_IMAGE_REF

    # Force a clean-base -> full-chain run (else current-version auto-detect skips hops).
    local current="${PROFILE_KC_CURRENT_VERSION:-16.1.1}"
    local target_major="${TARGET_MAJOR:-26}"
    export PROFILE_KC_CURRENT_VERSION="$current"
    export TARGET_MAJOR="$target_major"
    export PROFILE_KC_DEPLOYMENT_MODE="run"
    export PROFILE_KC_DISTRIBUTION_MODE="container"
    export PROFILE_CONTAINER_ACQUISITION="build"

    # Point every component at the throwaway PG on the shared bridge.
    export PROFILE_DB_TYPE="postgresql"
    export PROFILE_DB_HOST="$HARNESS_PG_NAME"
    export PROFILE_DB_PORT="5432"
    export PROFILE_DB_NAME="keycloak"
    export PROFILE_DB_USER="keycloak"
    export PROFILE_DB_PASSWORD="$HARNESS_DB_PASSWORD"
    export PROFILE_KC_RUN_NETWORK="$HARNESS_NET"

    # Live runs need real secrets.
    if [[ "$HARNESS_DRY_RUN" != "true" ]]; then
        if [[ -z "$HARNESS_DB_PASSWORD" || -z "$HARNESS_KC_ADMIN_PASSWORD" ]]; then
            log_error "live (--go) requires HARNESS_DB_PASSWORD and HARNESS_KC_ADMIN_PASSWORD in the environment"
            return 1
        fi
    fi

    local hops
    if ! hops="$(kc_build_migration_path "$current" "$target_major")"; then
        log_error "could not build migration path from $current to major $target_major"; return 1
    fi

    echo "=============================================================="
    echo " Keycloak container-hop migration harness"
    echo "   mode          : $([[ "$HARNESS_DRY_RUN" == "true" ]] && echo DRY-RUN || echo LIVE)"
    echo "   profile       : $profile"
    echo "   base image    : ${PROFILE_CONTAINER_BASE_IMAGE:-<unset>}"
    echo "   final ref tpl : ${PROFILE_CONTAINER_IMAGE_REF:-<unset>}"
    echo "   start version : $current"
    echo "   target major  : $target_major"
    echo "   hop chain     : $current -> ${hops// / -> }"
    echo "   seed          : ${HARNESS_SEED_REALMS:-3} realms x (${HARNESS_SEED_USERS:-50} users + ${HARNESS_SEED_CLIENTS:-10} clients)"
    echo "=============================================================="

    harness_net_up
    harness_pg_up
    harness_boot_base16
    harness_seed
    harness_baseline

    # shellcheck disable=SC2206  # word-split the space-separated hop list intentionally
    local hop_arr=($hops)
    local n="${#hop_arr[@]}" idx=0 v is_last
    for v in "${hop_arr[@]}"; do
        idx=$((idx + 1))
        is_last="false"; [[ "$idx" -eq "$n" ]] && is_last="true"
        harness_run_hop "$v" "$is_last"
    done

    echo ""
    harness_teardown
    echo ""
    log_success "harness complete (mode=$([[ "$HARNESS_DRY_RUN" == "true" ]] && echo DRY-RUN || echo LIVE))"
}

# Run only when executed directly (allows sourcing for tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    harness_main "$@"
fi
