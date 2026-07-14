#!/usr/bin/env bash
# Deployment Mode Adapter Interface for Keycloak Migration v3.0
# Provides unified interface for multiple deployment environments

set -euo pipefail

# Locate library directory (mirrors keycloak_discovery.sh)
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR}"

# Container runtime abstraction (podman/docker) — provides cr, cr_compose, cr_detect
if [[ -f "$LIB_DIR/container_runtime.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/container_runtime.sh"
fi

# Detect available container runtime (exports CONTAINER_RUNTIME); non-fatal if none
# shellcheck disable=SC2015 # auto: shellcheck 0.10 (CI) finding, behavior-preserving
declare -F cr_detect >/dev/null 2>&1 && cr_detect || true

# Deployment mode registry
declare -A DEPLOY_MODES=(
    [standalone]="Standalone (systemd/filesystem)"
    [docker]="Docker (single container)"
    [podman]="Podman single container"
    [docker-compose]="Docker Compose (multi-service stack)"
    [kubernetes]="Kubernetes (native)"
    [deckhouse]="Deckhouse (K8s + modules)"
    [run]="Single-host transient migrating container"
)

# ============================================================================
# Auto-detection
# ============================================================================

deploy_detect_mode() {
    # Detect deployment mode from environment

    # Check for Kubernetes
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null; then
        # Check for Deckhouse modules
        if kubectl get moduleconfig &>/dev/null 2>&1; then
            echo "deckhouse"
            return 0
        else
            echo "kubernetes"
            return 0
        fi
    fi

    # Check for Docker Compose
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        echo "docker-compose"
        return 0
    fi

    # Check for a container runtime (process running in a container)
    if cr ps &>/dev/null; then
        # Check if Keycloak is running in Docker
        if pgrep -f "keycloak" | xargs -I {} cat /proc/{}/cgroup 2>/dev/null | grep -q docker; then
            echo "docker"
            return 0
        fi
    fi

    # Default to standalone
    echo "standalone"
    return 0
}

deploy_validate_mode() {
    local mode="$1"

    if [[ -n "${DEPLOY_MODES[$mode]:-}" ]]; then
        return 0
    else
        echo "ERROR: Unsupported deployment mode: $mode" >&2
        echo "Supported: ${!DEPLOY_MODES[*]}" >&2
        return 1
    fi
}

# ============================================================================
# Service Control (Start/Stop/Status)
# ============================================================================

kc_start() {
    local mode="${1:-standalone}"
    shift
    local args=("$@")

    case "$mode" in
        standalone)
            local service_name="${args[0]:-keycloak}"
            systemctl start "$service_name"
            ;;

        docker|podman)
            local container_name="${args[0]:-keycloak}"
            cr start "$container_name"
            ;;

        docker-compose)
            local compose_file="${args[0]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" up -d
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            local deployment="${args[1]:-keycloak}"
            local replicas="${args[2]:-1}"
            kubectl scale deployment/"$deployment" --replicas="$replicas" -n "$namespace"
            ;;

        deckhouse)
            kubectl patch moduleconfig keycloak --type=merge \
                -p '{"spec":{"enabled":true}}'
            ;;

        *)
            echo "ERROR: Start not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

kc_stop() {
    local mode="${1:-standalone}"
    shift
    local args=("$@")

    case "$mode" in
        standalone)
            local service_name="${args[0]:-keycloak}"
            systemctl stop "$service_name"
            ;;

        docker|podman)
            local container_name="${args[0]:-keycloak}"
            cr stop "$container_name"
            ;;

        docker-compose)
            local compose_file="${args[0]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" down
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            local deployment="${args[1]:-keycloak}"
            kubectl scale deployment/"$deployment" --replicas=0 -n "$namespace"
            ;;

        deckhouse)
            kubectl patch moduleconfig keycloak --type=merge \
                -p '{"spec":{"enabled":false}}'
            ;;

        *)
            echo "ERROR: Stop not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

kc_status() {
    local mode="${1:-standalone}"
    shift
    local args=("$@")

    case "$mode" in
        standalone)
            local service_name="${args[0]:-keycloak}"
            systemctl status "$service_name" --no-pager
            ;;

        docker|podman)
            local container_name="${args[0]:-keycloak}"
            cr ps -f name="$container_name"
            ;;

        docker-compose)
            local compose_file="${args[0]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" ps
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            kubectl get pods -l app=keycloak -n "$namespace"
            ;;

        deckhouse)
            kubectl get moduleconfig keycloak -o jsonpath='{.status.state}'
            echo
            ;;

        *)
            echo "ERROR: Status not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

kc_restart() {
    local mode="$1"
    shift

    kc_stop "$mode" "$@"
    sleep 5
    kc_start "$mode" "$@"
}

# ============================================================================
# Command Execution
# ============================================================================

kc_exec() {
    local mode="${1:-standalone}"
    shift
    local args=("$@")

    # First arg after mode is the command, rest are container/namespace info
    local cmd="${args[0]}"
    local exec_args=("${args[@]:1}")

    case "$mode" in
        standalone)
            # Execute directly on host
            bash -c "$cmd"
            ;;

        docker|podman|run)
            local container_name="${exec_args[0]:-keycloak}"
            cr exec "$container_name" bash -c "$cmd"
            ;;

        docker-compose)
            local service_name="${exec_args[0]:-keycloak}"
            local compose_file="${exec_args[1]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" exec "$service_name" bash -c "$cmd"
            ;;

        kubernetes)
            local namespace="${exec_args[0]:-keycloak}"
            local deployment="${exec_args[1]:-keycloak}"
            kubectl exec deployment/"$deployment" -n "$namespace" -- bash -c "$cmd"
            ;;

        deckhouse)
            kubectl exec -n d8-keycloak deployment/keycloak -- bash -c "$cmd"
            ;;

        *)
            echo "ERROR: Exec not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Logs
# ============================================================================

kc_logs() {
    local mode="${1:-standalone}"
    local follow="${2:-false}"
    shift 2
    local args=("$@")

    local log_opts=""
    [[ "$follow" == "true" ]] && log_opts="-f"

    case "$mode" in
        standalone)
            local service_name="${args[0]:-keycloak}"
            journalctl -u "$service_name" $log_opts
            ;;

        docker|podman|run)
            local container_name="${args[0]:-keycloak}"
            # shellcheck disable=SC2086  # $log_opts is an intentional optional flag
            cr logs $log_opts "$container_name"
            ;;

        docker-compose)
            local service_name="${args[0]:-keycloak}"
            local compose_file="${args[1]:-docker-compose.yml}"
            # shellcheck disable=SC2046,SC2086  # cr_compose words + optional $log_opts
            $(cr_compose) -f "$compose_file" logs $log_opts "$service_name"
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            local deployment="${args[1]:-keycloak}"
            kubectl logs $log_opts deployment/"$deployment" -n "$namespace"
            ;;

        deckhouse)
            kubectl logs $log_opts -l app=keycloak -n d8-keycloak
            ;;

        *)
            echo "ERROR: Logs not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Health Checks
# ============================================================================

kc_health_check() {
    local mode="${1:-standalone}"
    local endpoint="${2:-http://localhost:8080/health}"
    shift 2
    local args=("$@")

    case "$mode" in
        standalone)
            curl -sf --max-time 10 "$endpoint" >/dev/null
            ;;

        docker|podman|run)
            local container_name="${args[0]:-keycloak}"
            cr exec "$container_name" curl -sf --max-time 10 "$endpoint" >/dev/null
            ;;

        docker-compose)
            local service_name="${args[0]:-keycloak}"
            local compose_file="${args[1]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" exec "$service_name" \
                curl -sf --max-time 10 "$endpoint" >/dev/null
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            local pod=$(kubectl get pods -l app=keycloak -n "$namespace" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            [[ -z "$pod" ]] && return 1

            kubectl exec "$pod" -n "$namespace" -- \
                curl -sf --max-time 10 "$endpoint" >/dev/null
            ;;

        deckhouse)
            local pod=$(kubectl get pods -l app=keycloak -n d8-keycloak \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            [[ -z "$pod" ]] && return 1

            kubectl exec "$pod" -n d8-keycloak -- \
                curl -sf --max-time 10 "$endpoint" >/dev/null
            ;;

        *)
            echo "ERROR: Health check not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Configuration Management
# ============================================================================

kc_get_config_path() {
    local mode="${1:-standalone}"
    shift
    local args=("$@")

    case "$mode" in
        standalone)
            local kc_home="${args[0]:-/opt/keycloak}"
            echo "$kc_home/conf/keycloak.conf"
            ;;

        docker|docker-compose|podman|run)
            echo "/opt/keycloak/conf/keycloak.conf"
            ;;

        kubernetes|deckhouse)
            # Config typically in ConfigMap
            echo "configmap/keycloak-config"
            ;;

        *)
            echo "ERROR: Config path not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

kc_read_config() {
    local mode="${1:-standalone}"
    local config_key="$2"
    shift 2
    local args=("$@")

    local config_path=$(kc_get_config_path "$mode" "${args[@]}")

    case "$mode" in
        standalone)
            grep "^${config_key}=" "$config_path" | cut -d'=' -f2
            ;;

        docker|podman|run)
            local container_name="${args[0]:-keycloak}"
            cr exec "$container_name" \
                grep "^${config_key}=" "$config_path" | cut -d'=' -f2
            ;;

        docker-compose)
            local svc="${args[0]:-keycloak}"
            local compose_file="${args[1]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" exec -T "$svc" \
                grep "^${config_key}=" "$config_path" | cut -d'=' -f2
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            kubectl get configmap keycloak-config -n "$namespace" \
                -o jsonpath="{.data.keycloak\.conf}" | \
                grep "^${config_key}=" | cut -d'=' -f2
            ;;

        deckhouse)
            local namespace="${args[0]:-d8-keycloak}"
            kubectl get configmap keycloak-config -n "$namespace" \
                -o jsonpath="{.data.keycloak\.conf}" | \
                grep "^${config_key}=" | cut -d'=' -f2
            ;;

        *)
            echo "ERROR: Read config not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Version Detection
# ============================================================================

kc_get_version() {
    local mode="${1:-standalone}"
    shift
    local args=("$@")

    case "$mode" in
        standalone)
            local kc_home="${args[0]:-/opt/keycloak}"
            "$kc_home/bin/kc.sh" --version 2>/dev/null || \
                "$kc_home/bin/standalone.sh" --version 2>/dev/null | grep -oP 'Keycloak \K[\d.]+'
            ;;

        docker|podman|run)
            local container_name="${args[0]:-keycloak}"
            cr exec "$container_name" /opt/keycloak/bin/kc.sh --version 2>/dev/null || \
                cr exec "$container_name" /opt/keycloak/bin/standalone.sh --version 2>/dev/null | \
                grep -oP 'Keycloak \K[\d.]+'
            ;;

        docker-compose)
            local svc="${args[0]:-keycloak}"
            local compose_file="${args[1]:-docker-compose.yml}"
            # shellcheck disable=SC2046  # cr_compose returns command words
            $(cr_compose) -f "$compose_file" exec -T "$svc" \
                /opt/keycloak/bin/kc.sh --version 2>/dev/null | grep -oP '[\d.]+'
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            local pod=$(kubectl get pods -l app=keycloak -n "$namespace" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            [[ -z "$pod" ]] && return 1

            kubectl exec "$pod" -n "$namespace" -- \
                /opt/keycloak/bin/kc.sh --version 2>/dev/null | grep -oP '[\d.]+'
            ;;

        deckhouse)
            local pod=$(kubectl get pods -l app=keycloak -n d8-keycloak \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            [[ -z "$pod" ]] && return 1

            kubectl exec "$pod" -n d8-keycloak -- \
                /opt/keycloak/bin/kc.sh --version 2>/dev/null | grep -oP '[\d.]+'
            ;;

        *)
            echo "ERROR: Version detection not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Transient Migrating Container (run mode)
# ============================================================================

kc_run_migrating_container() {
    # Boot a transient Keycloak container of <version> against the configured
    # PostgreSQL. Keycloak runs Liquibase + RealmMigration on startup.
    # Network: host networking by default so the container reaches a host-local
    # database; override with PROFILE_KC_RUN_NETWORK (e.g. a user-defined bridge).
    # Usage: kc_run_migrating_container <version>
    local version="$1"
    local container_name="${PROFILE_KC_RUN_CONTAINER_NAME:-kc-migrate-${version}}"
    local network_opt="--network=${PROFILE_KC_RUN_NETWORK:-host}"

    local db_host="${PROFILE_DB_HOST:-localhost}"
    local db_port="${PROFILE_DB_PORT:-5432}"
    local db_name="${PROFILE_DB_NAME:-keycloak}"
    local db_user="${PROFILE_DB_USER:-keycloak}"
    local db_pass="${PROFILE_DB_PASSWORD:-${KC_DB_PASSWORD:-}}"
    local jdbc_url="jdbc:postgresql://${db_host}:${db_port}/${db_name}"

    local image_ref
    image_ref=$(dist_image_ref "$version")

    # Keycloak 24+ in PRODUCTION mode (`start --optimized`) refuses to boot with only the DB
    # settings. Observed on a live run (KC 24.0.5 exited 1 immediately, so Liquibase never ran):
    #   ERROR: Strict hostname resolution configured but no hostname setting provided
    #   ERROR: Failed to start quarkus
    # and, with no HTTPS key material, it also demands http be explicitly enabled.
    #
    # This container is a TRANSIENT MIGRATION boot — nobody connects to it; we only need Keycloak
    # to run Liquibase (L1) + RealmMigration (L2) and exit. So relax both. Override per profile
    # with PROFILE_KC_RUN_HOSTNAME_STRICT / PROFILE_KC_RUN_HTTP_ENABLED / PROFILE_KC_RUN_HOSTNAME.
    local hostname_strict="${PROFILE_KC_RUN_HOSTNAME_STRICT:-false}"
    local http_enabled="${PROFILE_KC_RUN_HTTP_ENABLED:-true}"

    local -a run_env=(
        -e KC_DB=postgres
        -e KC_DB_URL="$jdbc_url"
        -e KC_DB_USERNAME="$db_user"
        -e KC_DB_PASSWORD="$db_pass"
        -e KC_HOSTNAME_STRICT="$hostname_strict"
        -e KC_HTTP_ENABLED="$http_enabled"
    )
    [[ -n "${PROFILE_KC_RUN_HOSTNAME:-}" ]] && run_env+=(-e KC_HOSTNAME="${PROFILE_KC_RUN_HOSTNAME}")

    if [[ "${DRY_RUN:-false}" == "true" || "${KC_VERBOSE:-false}" == "true" ]]; then
        echo "DRY-RUN: cr run -d --name $container_name $network_opt -e KC_DB=postgres -e KC_DB_URL=$jdbc_url -e KC_DB_USERNAME=$db_user -e KC_DB_PASSWORD=*** -e KC_HOSTNAME_STRICT=$hostname_strict -e KC_HTTP_ENABLED=$http_enabled $image_ref start --optimized" >&2
        [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    fi

    cr run -d --name "$container_name" \
        "$network_opt" \
        "${run_env[@]}" \
        "$image_ref" \
        start --optimized || {
        log_error "Failed to start migration container '$container_name'"
        return 1
    }

    # Verify the boot actually TOOK, right now. A mis-configured Keycloak exits within a second or
    # two, and a container that is already gone cannot be diagnosed afterwards — so capture the
    # state and the logs immediately, while they still exist.
    sleep 3
    local st
    st=$(cr inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null | tr -d '[:space:]' || true)
    : "${st:=missing}"
    if [[ "$st" != "running" ]]; then
        local rc_exit
        rc_exit=$(cr inspect -f '{{.State.ExitCode}}' "$container_name" 2>/dev/null | tr -d '[:space:]' || true)
        log_error "Migration container '$container_name' is '${st}' 3s after start (exit=${rc_exit:-?})"
        log_warn "Container logs:"
        if ! cr logs "$container_name" 2>&1 | tail -40 | sed 's/^/  /'; then
            log_warn "  (no logs — the container is already gone)"
        fi
        return 1
    fi
    log_success "Migration container '$container_name' is running"
}

kc_run_stop_container() {
    # Stop and remove a transient migrating container (errors ignored).
    # Usage: kc_run_stop_container [container_name]
    local container_name="${1:-${PROFILE_KC_RUN_CONTAINER_NAME:-keycloak}}"
    cr stop "$container_name" 2>/dev/null || true
    cr rm "$container_name" 2>/dev/null || true
}

# ============================================================================
# Rolling Update (Kubernetes specific)
# ============================================================================

kc_rolling_update() {
    local namespace="${1:-keycloak}"
    local deployment="${2:-keycloak}"
    local new_image="$3"
    local timeout="${4:-600}"

    # Only for Kubernetes modes
    kubectl set image deployment/"$deployment" \
        keycloak="$new_image" \
        -n "$namespace"

    kubectl rollout status deployment/"$deployment" \
        -n "$namespace" \
        --timeout="${timeout}s"
}

kc_rollback() {
    local namespace="${1:-keycloak}"
    local deployment="${2:-keycloak}"

    kubectl rollout undo deployment/"$deployment" -n "$namespace"
}

# ============================================================================
# Export adapter info
# ============================================================================

deploy_adapter_info() {
    echo "Deployment Adapter v3.0"
    echo "Supported deployment modes:"
    for mode in "${!DEPLOY_MODES[@]}"; do
        echo "  - $mode: ${DEPLOY_MODES[$mode]}"
    done
}
