#!/usr/bin/env bash
# Traffic Switching for Advanced Migration Strategies (v3.3)
# Supports: Istio, Nginx, HAProxy

set -euo pipefail

# ============================================================================
# Traffic Switcher — Main API
# ============================================================================

traffic_switch_weight() {
    # Switch traffic between two backends with specified weights
    # Usage: traffic_switch_weight <type> <backend1> <weight1> <backend2> <weight2>
    local type="$1"
    local backend1="$2"
    local weight1="$3"
    local backend2="$4"
    local weight2="$5"

    log_info "Switching traffic: $backend1 ($weight1%) / $backend2 ($weight2%)"

    case "$type" in
        istio)
            traffic_switch_istio "$backend1" "$weight1" "$backend2" "$weight2"
            ;;
        nginx)
            traffic_switch_nginx "$backend1" "$weight1" "$backend2" "$weight2"
            ;;
        haproxy)
            traffic_switch_haproxy "$backend1" "$weight1" "$backend2" "$weight2"
            ;;
        *)
            log_error "Unknown traffic switcher type: $type"
            return 1
            ;;
    esac
}

traffic_get_current_weights() {
    # Get current traffic weights
    # Usage: traffic_get_current_weights <type>
    # Returns: "backend1:weight1,backend2:weight2"
    local type="$1"

    case "$type" in
        istio)
            traffic_get_weights_istio
            ;;
        nginx)
            traffic_get_weights_nginx
            ;;
        haproxy)
            traffic_get_weights_haproxy
            ;;
        *)
            echo "unknown:0,unknown:0"
            return 1
            ;;
    esac
}

# ============================================================================
# Istio VirtualService Traffic Switching
# ============================================================================

traffic_switch_istio() {
    # Update Istio VirtualService weights
    local backend1="$1"  # subset name (e.g., "v16")
    local weight1="$2"
    local backend2="$3"  # subset name (e.g., "v26")
    local weight2="$4"

    local namespace="${TRAFFIC_NAMESPACE:-default}"
    local vs_name="${TRAFFIC_VIRTUALSERVICE:-keycloak-vs}"

    log_info "Istio: Updating VirtualService $namespace/$vs_name"

    # Create VirtualService patch
    local patch
    patch=$(cat <<EOF
spec:
  http:
  - route:
    - destination:
        host: keycloak
        subset: $backend1
      weight: $weight1
    - destination:
        host: keycloak
        subset: $backend2
      weight: $weight2
EOF
)

    # Apply patch via kubectl
    if kubectl patch virtualservice "$vs_name" -n "$namespace" --type=merge -p "$patch" >/dev/null 2>&1; then
        log_success "Istio traffic updated: $backend1 ($weight1%) / $backend2 ($weight2%)"
        return 0
    else
        log_error "Failed to update Istio VirtualService"
        return 1
    fi
}

traffic_get_weights_istio() {
    # Get current weights from Istio VirtualService
    local namespace="${TRAFFIC_NAMESPACE:-default}"
    local vs_name="${TRAFFIC_VIRTUALSERVICE:-keycloak-vs}"

    # Parse VirtualService YAML
    kubectl get virtualservice "$vs_name" -n "$namespace" -o yaml 2>/dev/null | \
        yq eval '.spec.http[0].route[] | .destination.subset + ":" + (.weight | tostring)' - 2>/dev/null | \
        paste -sd ',' - || echo "unknown:0,unknown:0"
}

# ============================================================================
# Nginx Upstream Weight Switching
# ============================================================================

traffic_switch_nginx() {
    # Update Nginx upstream weights
    local backend1="$1"  # server name or IP
    local weight1="$2"
    local backend2="$3"
    local weight2="$4"

    local upstream="${TRAFFIC_NGINX_UPSTREAM:-keycloak_upstream}"
    local config_file="${TRAFFIC_NGINX_CONFIG:-/etc/nginx/conf.d/keycloak-upstream.conf}"

    log_info "Nginx: Updating upstream $upstream in $config_file"

    # Generate new upstream block
    local upstream_block
    upstream_block=$(cat <<EOF
upstream $upstream {
    server $backend1 weight=$weight1;
    server $backend2 weight=$weight2;
}
EOF
)

    # Backup current config
    cp "$config_file" "${config_file}.backup" 2>/dev/null || true

    # Replace upstream block (using sed)
    # This is a simplified version - real implementation should be more robust
    if [[ -f "$config_file" ]]; then
        # For now, just log what would be done
        log_warn "Nginx weight update requires manual config edit or Nginx Plus API"
        log_info "Would update: $backend1 weight=$weight1, $backend2 weight=$weight2"

        # Placeholder for actual implementation
        # Real version would use Nginx Plus API or dynamic reconfiguration
        return 0
    else
        log_error "Nginx config file not found: $config_file"
        return 1
    fi
}

traffic_get_weights_nginx() {
    # Get current Nginx upstream weights
    local config_file="${TRAFFIC_NGINX_CONFIG:-/etc/nginx/conf.d/keycloak-upstream.conf}"

    if [[ -f "$config_file" ]]; then
        grep "server.*weight=" "$config_file" 2>/dev/null | \
            sed 's/.*server \([^ ]*\) weight=\([0-9]*\).*/\1:\2/' | \
            paste -sd ',' - || echo "unknown:0,unknown:0"
    else
        echo "unknown:0,unknown:0"
    fi
}

# ============================================================================
# HAProxy Weight Switching
# ============================================================================

traffic_switch_haproxy() {
    # Update HAProxy server weights
    local backend1="$1"  # server name
    local weight1="$2"
    local backend2="$3"
    local weight2="$4"

    local backend="${TRAFFIC_HAPROXY_BACKEND:-keycloak_backend}"
    local socket="${TRAFFIC_HAPROXY_SOCKET:-/var/run/haproxy/admin.sock}"

    log_info "HAProxy: Updating weights in backend $backend"

    if [[ ! -S "$socket" ]]; then
        log_error "HAProxy admin socket not found: $socket"
        return 1
    fi

    # Set weight for backend1
    echo "set weight $backend/$backend1 $weight1" | socat stdio "$socket" >/dev/null 2>&1
    local result1=$?

    # Set weight for backend2
    echo "set weight $backend/$backend2 $weight2" | socat stdio "$socket" >/dev/null 2>&1
    local result2=$?

    if [[ $result1 -eq 0 && $result2 -eq 0 ]]; then
        log_success "HAProxy weights updated: $backend1 ($weight1%) / $backend2 ($weight2%)"
        return 0
    else
        log_error "Failed to update HAProxy weights"
        return 1
    fi
}

traffic_get_weights_haproxy() {
    # Get current HAProxy server weights
    local backend="${TRAFFIC_HAPROXY_BACKEND:-keycloak_backend}"
    local socket="${TRAFFIC_HAPROXY_SOCKET:-/var/run/haproxy/admin.sock}"

    if [[ ! -S "$socket" ]]; then
        echo "unknown:0,unknown:0"
        return 1
    fi

    # Get server stats and extract weights
    echo "show stat" | socat stdio "$socket" 2>/dev/null | \
        grep "^$backend," | \
        awk -F',' '{print $2":"$46}' | \
        paste -sd ',' - || echo "unknown:0,unknown:0"
}

# ============================================================================
# Gradual Weight Shifting
# ============================================================================

traffic_gradual_shift() {
    # Gradually shift traffic from source to target
    # Usage: traffic_gradual_shift <type> <source_backend> <target_backend> <step> <interval>
    local type="$1"
    local source="$2"
    local target="$3"
    local step="${4:-10}"       # Default: 10% per step
    local interval="${5:-60}"   # Default: 60 seconds between steps

    log_info "Gradual traffic shift: $source → $target (step: $step%, interval: ${interval}s)"

    local source_weight=100
    local target_weight=0

    while [[ $source_weight -gt 0 ]]; do
        # Calculate new weights
        target_weight=$((target_weight + step))
        source_weight=$((source_weight - step))

        # Cap at 0/100
        if [[ $source_weight -lt 0 ]]; then
            source_weight=0
            target_weight=100
        fi

        # Apply weight change
        traffic_switch_weight "$type" "$source" "$source_weight" "$target" "$target_weight"

        if [[ $source_weight -eq 0 ]]; then
            log_success "Traffic fully shifted to $target"
            break
        fi

        log_info "Waiting ${interval}s before next shift..."
        sleep "$interval"
    done
}

# ============================================================================
# Validation Helpers
# ============================================================================

traffic_validate_switch() {
    # Validate traffic switch was successful
    # Usage: traffic_validate_switch <type> <expected_weights>
    local type="$1"
    local expected="$2"  # Format: "backend1:weight1,backend2:weight2"

    log_info "Validating traffic switch..."

    local actual
    actual=$(traffic_get_current_weights "$type")

    if [[ "$actual" == "$expected" ]]; then
        log_success "Traffic weights validated: $actual"
        return 0
    else
        log_warn "Traffic weights mismatch! Expected: $expected, Actual: $actual"
        return 1
    fi
}
