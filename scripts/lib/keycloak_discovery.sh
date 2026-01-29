#!/usr/bin/env bash
# Keycloak Discovery Module for v3.0
# Auto-detects existing Keycloak installations across different deployment modes

set -euo pipefail

# Source deployment adapter for detection functions
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR}"

if [[ -f "$LIB_DIR/deployment_adapter.sh" ]]; then
    source "$LIB_DIR/deployment_adapter.sh"
fi

if [[ -f "$LIB_DIR/database_adapter.sh" ]]; then
    source "$LIB_DIR/database_adapter.sh"
fi

# ============================================================================
# Keycloak Discovery by Deployment Mode
# ============================================================================

kc_discover_standalone() {
    # Discover Keycloak in standalone mode (filesystem/systemd)

    local discoveries=()

    # Check common installation paths
    local common_paths=(
        "/opt/keycloak"
        "/usr/local/keycloak"
        "/opt/keycloak-*"
        "/var/lib/keycloak"
        "$HOME/keycloak"
    )

    for path_pattern in "${common_paths[@]}"; do
        for path in $path_pattern; do
            if [[ -d "$path" && -x "$path/bin/kc.sh" ]]; then
                local version=$(kc_get_version "standalone" "$path" 2>/dev/null || echo "unknown")
                discoveries+=("$path|$version|standalone")
            elif [[ -d "$path" && -x "$path/bin/standalone.sh" ]]; then
                # Old WildFly-based Keycloak (pre-17)
                local version=$(kc_get_version "standalone" "$path" 2>/dev/null || echo "16.x-or-older")
                discoveries+=("$path|$version|standalone")
            fi
        done
    done

    # Check systemd services
    if command -v systemctl &>/dev/null; then
        local services=$(systemctl list-units --type=service --all | grep -i keycloak | awk '{print $1}' || true)
        for service in $services; do
            # Try to extract path from service file
            local service_file=$(systemctl show -p FragmentPath "$service" | cut -d= -f2)
            if [[ -f "$service_file" ]]; then
                local exec_start=$(grep "^ExecStart=" "$service_file" | head -1 | cut -d= -f2)
                local kc_path=$(echo "$exec_start" | grep -oP '(/[^ ]+/keycloak[^ ]*)')
                if [[ -n "$kc_path" && -d "$kc_path" ]]; then
                    local version=$(kc_get_version "standalone" "$kc_path" 2>/dev/null || echo "unknown")
                    discoveries+=("$kc_path|$version|systemd:$service")
                fi
            fi
        done
    fi

    # Return unique discoveries
    printf '%s\n' "${discoveries[@]}" | sort -u
}

kc_discover_docker() {
    # Discover Keycloak in Docker containers

    if ! docker ps &>/dev/null; then
        return 0
    fi

    local discoveries=()

    # Find running containers with Keycloak
    local containers=$(docker ps --format '{{.Names}}' | grep -i keycloak || true)

    for container in $containers; do
        # Check if it's actually Keycloak
        if docker exec "$container" test -f /opt/keycloak/bin/kc.sh 2>/dev/null || \
           docker exec "$container" test -f /opt/keycloak/bin/standalone.sh 2>/dev/null; then
            local version=$(kc_get_version "docker" "$container" 2>/dev/null || echo "unknown")
            local image=$(docker inspect "$container" --format '{{.Config.Image}}')
            discoveries+=("$container|$version|docker:$image")
        fi
    done

    # Also check stopped containers
    local stopped=$(docker ps -a --filter "status=exited" --format '{{.Names}}' | grep -i keycloak || true)
    for container in $stopped; do
        if docker inspect "$container" --format '{{.Config.Image}}' | grep -qi keycloak; then
            local image=$(docker inspect "$container" --format '{{.Config.Image}}')
            discoveries+=("$container|stopped|docker:$image")
        fi
    done

    printf '%s\n' "${discoveries[@]}" | sort -u
}

kc_discover_docker_compose() {
    # Discover Keycloak in Docker Compose setups

    local discoveries=()

    # Find docker-compose files
    local compose_files=$(find . -maxdepth 3 -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null || true)

    for compose_file in $compose_files; do
        # Check if it contains Keycloak service
        if grep -qi "keycloak" "$compose_file"; then
            # Extract service names
            local services=$(grep -A1 "services:" "$compose_file" | grep -v "services:" | grep ":" | cut -d: -f1 | xargs)
            for service in $services; do
                if echo "$service" | grep -qi "keycloak"; then
                    # Try to get running version
                    local version="unknown"
                    if docker-compose -f "$compose_file" ps | grep -q "$service.*Up"; then
                        version=$(kc_get_version "docker-compose" "$service" "$compose_file" 2>/dev/null || echo "running")
                    fi
                    discoveries+=("$service|$version|docker-compose:$compose_file")
                fi
            done
        fi
    done

    printf '%s\n' "${discoveries[@]}" | sort -u
}

kc_discover_kubernetes() {
    # Discover Keycloak in Kubernetes

    if ! kubectl cluster-info &>/dev/null; then
        return 0
    fi

    local discoveries=()

    # Search in all namespaces
    local namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')

    for ns in $namespaces; do
        # Find deployments with "keycloak" in name
        local deployments=$(kubectl get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i keycloak || true)

        for deploy in $deployments; do
            local replicas=$(kubectl get deployment "$deploy" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            local version=$(kc_get_version "kubernetes" "$ns" "$deploy" 2>/dev/null || echo "unknown")
            local image=$(kubectl get deployment "$deploy" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
            discoveries+=("$ns/$deploy|$version|kubernetes:replicas=$replicas,image=$image")
        done

        # Also check StatefulSets
        local statefulsets=$(kubectl get statefulsets -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i keycloak || true)

        for sts in $statefulsets; do
            local replicas=$(kubectl get statefulset "$sts" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            local version=$(kc_get_version "kubernetes" "$ns" "$sts" 2>/dev/null || echo "unknown")
            discoveries+=("$ns/$sts|$version|kubernetes-sts:replicas=$replicas")
        done
    done

    printf '%s\n' "${discoveries[@]}" | sort -u
}

kc_discover_deckhouse() {
    # Discover Keycloak in Deckhouse

    if ! kubectl get moduleconfig &>/dev/null 2>&1; then
        return 0
    fi

    local discoveries=()

    # Check for Keycloak module
    local modules=$(kubectl get moduleconfig -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i keycloak || true)

    for module in $modules; do
        local enabled=$(kubectl get moduleconfig "$module" -o jsonpath='{.spec.enabled}' 2>/dev/null || echo "false")
        local state=$(kubectl get moduleconfig "$module" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
        local version=$(kc_get_version "deckhouse" 2>/dev/null || echo "unknown")
        discoveries+=("$module|$version|deckhouse:enabled=$enabled,state=$state")
    done

    printf '%s\n' "${discoveries[@]}" | sort -u
}

# ============================================================================
# Unified Discovery
# ============================================================================

kc_discover_all() {
    # Discover Keycloak in all possible deployment modes

    local all_discoveries=()

    echo "🔍 Searching for Keycloak installations..." >&2

    # Try all discovery methods
    echo "  → Checking standalone..." >&2
    local standalone=$(kc_discover_standalone)
    [[ -n "$standalone" ]] && all_discoveries+=("$standalone")

    echo "  → Checking Docker..." >&2
    local docker=$(kc_discover_docker)
    [[ -n "$docker" ]] && all_discoveries+=("$docker")

    echo "  → Checking Docker Compose..." >&2
    local compose=$(kc_discover_docker_compose)
    [[ -n "$compose" ]] && all_discoveries+=("$compose")

    echo "  → Checking Kubernetes..." >&2
    local k8s=$(kc_discover_kubernetes)
    [[ -n "$k8s" ]] && all_discoveries+=("$k8s")

    echo "  → Checking Deckhouse..." >&2
    local deckhouse=$(kc_discover_deckhouse)
    [[ -n "$deckhouse" ]] && all_discoveries+=("$deckhouse")

    # Return all unique discoveries
    if [[ ${#all_discoveries[@]} -eq 0 ]]; then
        echo "" >&2
        echo "❌ No Keycloak installations found" >&2
        return 1
    fi

    printf '%s\n' "${all_discoveries[@]}"
}

# ============================================================================
# Interactive Selection
# ============================================================================

kc_select_installation() {
    # Interactive selection from discovered installations

    local discoveries=$(kc_discover_all)

    if [[ -z "$discoveries" ]]; then
        echo "ERROR: No Keycloak installations found" >&2
        return 1
    fi

    local count=$(echo "$discoveries" | wc -l)

    if [[ $count -eq 1 ]]; then
        echo "" >&2
        echo "✅ Found 1 Keycloak installation:" >&2
        kc_display_discovery "$discoveries"
        echo "" >&2
        read -r -p "Use this installation? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            return 1
        fi
        echo "$discoveries"
        return 0
    fi

    # Multiple installations found
    echo "" >&2
    echo "✅ Found $count Keycloak installations:" >&2
    echo "" >&2

    local i=1
    while IFS= read -r discovery; do
        echo "  [$i] $(kc_format_discovery "$discovery")" >&2
        ((i++))
    done <<< "$discoveries"

    echo "" >&2
    read -r -p "Select installation [1-$count]: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "$count" ]]; then
        echo "ERROR: Invalid selection" >&2
        return 1
    fi

    echo "$discoveries" | sed -n "${selection}p"
}

kc_format_discovery() {
    # Format discovery for display
    local discovery="$1"

    IFS='|' read -r location version mode <<< "$discovery"

    echo "$mode → $location (version: $version)"
}

kc_display_discovery() {
    # Display discovery details
    local discovery="$1"

    IFS='|' read -r location version mode <<< "$discovery"

    echo "  Location: $location" >&2
    echo "  Version:  $version" >&2
    echo "  Mode:     $mode" >&2
}

# ============================================================================
# Parse Discovery to Profile
# ============================================================================

kc_discovery_to_profile() {
    # Convert discovery result to profile environment variables
    local discovery="$1"

    IFS='|' read -r location version mode <<< "$discovery"

    # Extract deployment mode
    local deploy_mode=$(echo "$mode" | cut -d: -f1)

    case "$deploy_mode" in
        standalone|systemd)
            export PROFILE_KC_DEPLOYMENT_MODE="standalone"
            export PROFILE_KC_HOME_DIR="$location"
            if [[ "$mode" == systemd:* ]]; then
                export PROFILE_KC_SERVICE_NAME=$(echo "$mode" | cut -d: -f2)
            else
                export PROFILE_KC_SERVICE_NAME="keycloak"
            fi
            ;;

        docker)
            export PROFILE_KC_DEPLOYMENT_MODE="docker"
            export PROFILE_KC_CONTAINER_NAME="$location"
            local image=$(echo "$mode" | cut -d: -f2)
            export PROFILE_CONTAINER_IMAGE="$image"
            ;;

        docker-compose)
            export PROFILE_KC_DEPLOYMENT_MODE="docker-compose"
            export PROFILE_KC_SERVICE_NAME="$location"
            local compose_file=$(echo "$mode" | cut -d: -f2)
            export PROFILE_KC_COMPOSE_FILE="$compose_file"
            ;;

        kubernetes|kubernetes-sts)
            export PROFILE_KC_DEPLOYMENT_MODE="kubernetes"
            local namespace=$(echo "$location" | cut -d/ -f1)
            local deployment=$(echo "$location" | cut -d/ -f2)
            export PROFILE_K8S_NAMESPACE="$namespace"
            export PROFILE_K8S_DEPLOYMENT="$deployment"

            # Extract replicas and image from mode
            if [[ "$mode" =~ replicas=([0-9]+) ]]; then
                export PROFILE_K8S_REPLICAS="${BASH_REMATCH[1]}"
            fi
            if [[ "$mode" =~ image=([^,]+) ]]; then
                export PROFILE_CONTAINER_IMAGE="${BASH_REMATCH[1]}"
            fi
            ;;

        deckhouse)
            export PROFILE_KC_DEPLOYMENT_MODE="deckhouse"
            export PROFILE_KC_MODULE_NAME="$location"
            ;;

        *)
            echo "ERROR: Unknown deployment mode: $deploy_mode" >&2
            return 1
            ;;
    esac

    # Set current version
    export PROFILE_KC_CURRENT_VERSION="$version"

    echo "✅ Profile populated from discovery:" >&2
    echo "  Deployment Mode: $PROFILE_KC_DEPLOYMENT_MODE" >&2
    echo "  Current Version: $PROFILE_KC_CURRENT_VERSION" >&2
}

# ============================================================================
# Database Discovery
# ============================================================================

kc_discover_database() {
    # Discover database connection from Keycloak configuration
    local deploy_mode="${1:-standalone}"
    shift
    local args=("$@")

    local config_path=$(kc_get_config_path "$deploy_mode" "${args[@]}")

    # Try to read database configuration
    local db_url=$(kc_read_config "$deploy_mode" "db-url" "${args[@]}" 2>/dev/null || echo "")

    if [[ -z "$db_url" ]]; then
        # Try old WildFly-based config (standalone.xml)
        echo "⚠️  Could not auto-detect database from config" >&2
        return 1
    fi

    # Parse JDBC URL
    local db_type=$(db_detect_type "$db_url")

    # Extract host, port, database name
    if [[ "$db_url" =~ jdbc:([^:]+)://([^:/]+):?([0-9]*)/([^?]+) ]]; then
        local host="${BASH_REMATCH[2]}"
        local port="${BASH_REMATCH[3]:-${DB_DEFAULT_PORTS[$db_type]}}"
        local db_name="${BASH_REMATCH[4]}"

        export PROFILE_DB_TYPE="$db_type"
        export PROFILE_DB_HOST="$host"
        export PROFILE_DB_PORT="$port"
        export PROFILE_DB_NAME="$db_name"

        # Try to read username
        local db_user=$(kc_read_config "$deploy_mode" "db-username" "${args[@]}" 2>/dev/null || echo "keycloak")
        export PROFILE_DB_USER="$db_user"

        echo "✅ Database auto-detected:" >&2
        echo "  Type: $db_type" >&2
        echo "  Host: $host:$port" >&2
        echo "  Database: $db_name" >&2
        echo "  User: $db_user" >&2

        return 0
    fi

    echo "⚠️  Could not parse database URL: $db_url" >&2
    return 1
}

# ============================================================================
# Full Auto-Discovery Workflow
# ============================================================================

kc_auto_discover_profile() {
    # Fully automatic profile creation from discovered Keycloak

    echo "═══════════════════════════════════════════════════════════" >&2
    echo "  Keycloak Auto-Discovery v3.0" >&2
    echo "═══════════════════════════════════════════════════════════" >&2
    echo "" >&2

    # Step 1: Find Keycloak installation
    local discovery=$(kc_select_installation)
    if [[ -z "$discovery" ]]; then
        return 1
    fi

    echo "" >&2
    echo "─────────────────────────────────────────────────────────────" >&2

    # Step 2: Convert to profile
    kc_discovery_to_profile "$discovery"

    echo "" >&2
    echo "─────────────────────────────────────────────────────────────" >&2

    # Step 3: Try to discover database
    local deploy_mode="$PROFILE_KC_DEPLOYMENT_MODE"
    case "$deploy_mode" in
        standalone)
            kc_discover_database "standalone" "${PROFILE_KC_HOME_DIR}"
            ;;
        docker)
            kc_discover_database "docker" "${PROFILE_KC_CONTAINER_NAME}"
            ;;
        kubernetes)
            kc_discover_database "kubernetes" "${PROFILE_K8S_NAMESPACE}" "${PROFILE_K8S_DEPLOYMENT}"
            ;;
    esac

    echo "" >&2
    echo "═══════════════════════════════════════════════════════════" >&2
    echo "✅ Auto-discovery complete!" >&2
    echo "═══════════════════════════════════════════════════════════" >&2
}
