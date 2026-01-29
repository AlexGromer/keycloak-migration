#!/usr/bin/env bash
# Deployment Mode Adapter Interface for Keycloak Migration v3.0
# Provides unified interface for multiple deployment environments

set -euo pipefail

# Deployment mode registry
declare -A DEPLOY_MODES=(
    [standalone]="Standalone (systemd/filesystem)"
    [docker]="Docker (single container)"
    [docker-compose]="Docker Compose (multi-service stack)"
    [kubernetes]="Kubernetes (native)"
    [deckhouse]="Deckhouse (K8s + modules)"
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

    # Check for Docker (process running in Docker)
    if docker ps &>/dev/null; then
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker start "$container_name"
            ;;

        docker-compose)
            local compose_file="${args[0]:-docker-compose.yml}"
            docker-compose -f "$compose_file" up -d
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker stop "$container_name"
            ;;

        docker-compose)
            local compose_file="${args[0]:-docker-compose.yml}"
            docker-compose -f "$compose_file" down
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker ps -f name="$container_name"
            ;;

        docker-compose)
            local compose_file="${args[0]:-docker-compose.yml}"
            docker-compose -f "$compose_file" ps
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

        docker)
            local container_name="${exec_args[0]:-keycloak}"
            docker exec "$container_name" bash -c "$cmd"
            ;;

        docker-compose)
            local service_name="${exec_args[0]:-keycloak}"
            local compose_file="${exec_args[1]:-docker-compose.yml}"
            docker-compose -f "$compose_file" exec "$service_name" bash -c "$cmd"
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker logs $log_opts "$container_name"
            ;;

        docker-compose)
            local service_name="${args[0]:-keycloak}"
            local compose_file="${args[1]:-docker-compose.yml}"
            docker-compose -f "$compose_file" logs $log_opts "$service_name"
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker exec "$container_name" curl -sf --max-time 10 "$endpoint" >/dev/null
            ;;

        docker-compose)
            local service_name="${args[0]:-keycloak}"
            local compose_file="${args[1]:-docker-compose.yml}"
            docker-compose -f "$compose_file" exec "$service_name" \
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

        docker|docker-compose)
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker exec "$container_name" \
                grep "^${config_key}=" "$config_path" | cut -d'=' -f2
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
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

        docker)
            local container_name="${args[0]:-keycloak}"
            docker exec "$container_name" /opt/keycloak/bin/kc.sh --version 2>/dev/null || \
                docker exec "$container_name" /opt/keycloak/bin/standalone.sh --version 2>/dev/null | \
                grep -oP 'Keycloak \K[\d.]+'
            ;;

        kubernetes)
            local namespace="${args[0]:-keycloak}"
            local pod=$(kubectl get pods -l app=keycloak -n "$namespace" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            [[ -z "$pod" ]] && return 1

            kubectl exec "$pod" -n "$namespace" -- \
                /opt/keycloak/bin/kc.sh --version 2>/dev/null | grep -oP '[\d.]+'
            ;;

        *)
            echo "ERROR: Version detection not implemented for mode: $mode" >&2
            return 1
            ;;
    esac
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
