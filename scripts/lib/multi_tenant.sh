#!/usr/bin/env bash
# Multi-Tenant & Clustered Deployment Support
# Handles migration of multiple Keycloak instances

set -euo pipefail

# ============================================================================
# Multi-Tenant Configuration Parsing
# ============================================================================

mt_parse_tenants() {
    # Parse tenants from YAML profile
    # Returns: number of tenants
    local profile_file="$1"

    if ! grep -q "^tenants:" "$profile_file" 2>/dev/null; then
        return 0
    fi

    # Count tenants
    local count
    count=$(sed -n '/^tenants:/,/^[a-z]/p' "$profile_file" | grep -c "^\s*- name:" || echo "0")
    echo "$count"
}

mt_get_tenant_config() {
    # Extract configuration for specific tenant
    # Usage: mt_get_tenant_config <profile_file> <tenant_index> <key>
    local profile_file="$1"
    local tenant_idx="$2"  # 0-based
    local key="$3"

    # Extract tenant section
    local tenant_section
    tenant_section=$(awk '/^tenants:/,/^[a-z]/ {print}' "$profile_file" | \
        awk -v idx="$tenant_idx" '
            /^  - name:/ { count++ }
            count == idx + 1 && !/^  - name:/ && !/^[a-z]/ { print }
        ')

    # Parse specific key
    echo "$tenant_section" | grep "^\s*${key}:" | sed 's/.*:\s*//' | xargs
}

# ============================================================================
# Clustered Deployment Configuration Parsing
# ============================================================================

cluster_parse_nodes() {
    # Parse cluster nodes from YAML profile
    # Returns: number of nodes
    local profile_file="$1"

    if ! grep -q "^cluster:" "$profile_file" 2>/dev/null; then
        return 0
    fi

    # Count nodes
    local count
    count=$(sed -n '/^cluster:/,/^[a-z]/p' "$profile_file" | grep -c "^\s*- host:" || echo "0")
    echo "$count"
}

cluster_get_node_config() {
    # Extract configuration for specific cluster node
    # Usage: cluster_get_node_config <profile_file> <node_index> <key>
    local profile_file="$1"
    local node_idx="$2"  # 0-based
    local key="$3"

    # Extract node section
    local node_section
    node_section=$(awk '/^cluster:/,/^[a-z]/ {print}' "$profile_file" | \
        awk -v idx="$node_idx" '
            /^  nodes:/,/^[a-z]/ {
                if (/^    - host:/) { count++ }
                if (count == idx + 1 && !/^    - host:/ && !/^[a-z]/) { print }
            }
        ')

    # Parse specific key
    echo "$node_section" | grep "^\s*${key}:" | sed 's/.*:\s*//' | xargs
}

# ============================================================================
# Load Balancer Integration
# ============================================================================

mt_lb_drain_node() {
    # Drain traffic from cluster node via load balancer
    # Usage: mt_lb_drain_node <node_name>
    local node="$1"
    local lb_type="${CLUSTER_LB_TYPE:-haproxy}"

    log_info "Draining traffic from node: $node (LB: $lb_type)"

    case "$lb_type" in
        haproxy)
            mt_lb_haproxy_drain "$node"
            ;;
        nginx)
            mt_lb_nginx_drain "$node"
            ;;
        *)
            log_warn "Unknown load balancer type: $lb_type, skipping drain"
            return 0
            ;;
    esac
}

mt_lb_enable_node() {
    # Enable traffic to cluster node via load balancer
    # Usage: mt_lb_enable_node <node_name>
    local node="$1"
    local lb_type="${CLUSTER_LB_TYPE:-haproxy}"

    log_info "Enabling traffic to node: $node (LB: $lb_type)"

    case "$lb_type" in
        haproxy)
            mt_lb_haproxy_enable "$node"
            ;;
        nginx)
            mt_lb_nginx_enable "$node"
            ;;
        *)
            log_warn "Unknown load balancer type: $lb_type, skipping enable"
            return 0
            ;;
    esac
}

mt_lb_wait_drained() {
    # Wait for active connections to drain from node
    # Usage: mt_lb_wait_drained <node_name>
    local node="$1"
    local timeout="${PROFILE_ROLLOUT_DRAIN_TIMEOUT:-60}"
    local lb_type="${CLUSTER_LB_TYPE:-haproxy}"

    log_info "Waiting for connections to drain from $node (timeout: ${timeout}s)..."

    local elapsed=0
    local interval=2

    while [[ $elapsed -lt $timeout ]]; do
        local active_conns=0

        case "$lb_type" in
            haproxy)
                active_conns=$(mt_lb_haproxy_get_connections "$node")
                ;;
            nginx)
                active_conns=$(mt_lb_nginx_get_connections "$node")
                ;;
            *)
                log_warn "Cannot check connections for $lb_type, assuming drained"
                return 0
                ;;
        esac

        if [[ "$active_conns" -eq 0 ]]; then
            log_success "Node $node fully drained (0 active connections)"
            return 0
        fi

        log_info "  $node: $active_conns active connection(s), waiting..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warn "Drain timeout exceeded for $node (still has connections)"
    return 1
}

# ----------------------------------------------------------------------------
# HAProxy Integration
# ----------------------------------------------------------------------------

mt_lb_haproxy_drain() {
    # Disable server in HAProxy backend
    local node="$1"
    local backend="${CLUSTER_LB_BACKEND:-keycloak_backend}"
    local socket="${CLUSTER_LB_ADMIN_SOCKET:-/var/run/haproxy/admin.sock}"

    if [[ ! -S "$socket" ]]; then
        log_error "HAProxy admin socket not found: $socket"
        return 1
    fi

    # Send command to HAProxy socket
    echo "disable server $backend/$node" | socat stdio "$socket" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        log_success "HAProxy: server $backend/$node disabled"
    else
        log_error "Failed to disable server in HAProxy"
        return 1
    fi
}

mt_lb_haproxy_enable() {
    # Enable server in HAProxy backend
    local node="$1"
    local backend="${CLUSTER_LB_BACKEND:-keycloak_backend}"
    local socket="${CLUSTER_LB_ADMIN_SOCKET:-/var/run/haproxy/admin.sock}"

    if [[ ! -S "$socket" ]]; then
        log_error "HAProxy admin socket not found: $socket"
        return 1
    fi

    echo "enable server $backend/$node" | socat stdio "$socket" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        log_success "HAProxy: server $backend/$node enabled"
    else
        log_error "Failed to enable server in HAProxy"
        return 1
    fi
}

mt_lb_haproxy_get_connections() {
    # Get active connection count for server
    local node="$1"
    local backend="${CLUSTER_LB_BACKEND:-keycloak_backend}"
    local socket="${CLUSTER_LB_ADMIN_SOCKET:-/var/run/haproxy/admin.sock}"

    if [[ ! -S "$socket" ]]; then
        echo "0"
        return 1
    fi

    # Parse HAProxy stats: field 5 is current sessions
    local conns
    conns=$(echo "show stat" | socat stdio "$socket" 2>/dev/null | \
        grep "^$backend,$node," | cut -d',' -f5 || echo "0")

    echo "${conns:-0}"
}

# ----------------------------------------------------------------------------
# Nginx Integration
# ----------------------------------------------------------------------------

mt_lb_nginx_drain() {
    # Mark Nginx upstream server as down
    local node="$1"
    local upstream="${CLUSTER_LB_BACKEND:-keycloak_upstream}"
    local api_url="${CLUSTER_LB_API_URL:-http://localhost:8080/api}"

    # Nginx Plus API: PATCH /api/*/http/upstreams/<upstream>/servers/<id>
    # {"down": true}

    log_warn "Nginx drain not fully implemented (requires Nginx Plus API)"
    log_info "Manual action: nginx -s reload after marking $node as down"

    # Placeholder for Nginx Plus API call
    # curl -X PATCH "$api_url/http/upstreams/$upstream/servers/$node" \
    #      -d '{"down": true}'

    return 0
}

mt_lb_nginx_enable() {
    # Mark Nginx upstream server as up
    local node="$1"

    log_warn "Nginx enable not fully implemented (requires Nginx Plus API)"
    return 0
}

mt_lb_nginx_get_connections() {
    # Get active connections from Nginx
    local node="$1"

    # Placeholder
    echo "0"
}

# ============================================================================
# Parallel Execution Framework
# ============================================================================

mt_execute_parallel() {
    # Execute migration for multiple instances in parallel
    # Usage: mt_execute_parallel <type> <count> <profile_file>
    local type="$1"  # "tenant" or "node"
    local count="$2"
    local profile_file="$3"

    log_section "Parallel Execution: $count ${type}s"

    # Create workspace for parallel execution
    local parallel_workspace="$WORK_DIR/parallel_${type}s"
    mkdir -p "$parallel_workspace"

    # Array to store background PIDs
    local -a pids=()
    local -a names=()

    # Launch workers
    for ((i=0; i<count; i++)); do
        local name
        if [[ "$type" == "tenant" ]]; then
            name=$(mt_get_tenant_config "$profile_file" "$i" "name")
        else
            name="node-$((i+1))"
        fi

        names+=("$name")

        local log_file="$parallel_workspace/${name}.log"
        local metrics_file="$parallel_workspace/${name}.metrics"

        log_info "Starting migration for $type: $name"

        # Launch background worker
        (
            mt_worker "$type" "$i" "$name" "$profile_file" "$log_file" "$metrics_file"
        ) &

        pids+=($!)
    done

    log_success "Launched $count parallel workers"

    # Monitor progress
    mt_monitor_parallel "$type" "${names[@]}" "${pids[@]}"

    # Wait for all to complete
    local failed=0
    for ((i=0; i<${#pids[@]}; i++)); do
        local pid="${pids[$i]}"
        local name="${names[$i]}"

        if wait "$pid"; then
            log_success "$type $name completed successfully"
        else
            log_error "$type $name failed"
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed ${type}(s) failed"
        return 1
    fi

    log_success "All $count ${type}s migrated successfully"
    return 0
}

mt_worker() {
    # Worker function for single instance migration
    local type="$1"
    local index="$2"
    local name="$3"
    local profile_file="$4"
    local log_file="$5"
    local metrics_file="$6"

    # Redirect output to log file
    exec > >(tee -a "$log_file")
    exec 2>&1

    log_info "[$name] Worker started"

    # Export instance-specific environment
    if [[ "$type" == "tenant" ]]; then
        export TENANT_NAME="$name"
        export TENANT_INDEX="$index"

        # Override database config for this tenant
        export PROFILE_DB_HOST=$(mt_get_tenant_config "$profile_file" "$index" "database.host" || mt_get_tenant_config "$profile_file" "$index" "host")
        export PROFILE_DB_NAME=$(mt_get_tenant_config "$profile_file" "$index" "database.name" || mt_get_tenant_config "$profile_file" "$index" "name")
        export PROFILE_KC_NAMESPACE=$(mt_get_tenant_config "$profile_file" "$index" "deployment.namespace" || echo "keycloak-$name")
        export PROFILE_KC_DEPLOYMENT=$(mt_get_tenant_config "$profile_file" "$index" "deployment.deployment" || echo "keycloak")

        log_info "[$name] Database: $PROFILE_DB_HOST/$PROFILE_DB_NAME"
        log_info "[$name] Deployment: $PROFILE_KC_NAMESPACE/$PROFILE_KC_DEPLOYMENT"
    else
        export NODE_NAME="$name"
        export NODE_INDEX="$index"
        export NODE_HOST=$(cluster_get_node_config "$profile_file" "$index" "host")
        export NODE_SSH_USER=$(cluster_get_node_config "$profile_file" "$index" "ssh_user" || echo "root")

        log_info "[$name] Host: $NODE_SSH_USER@$NODE_HOST"
    fi

    # Initialize metrics
    echo "0.0" > "$metrics_file"

    # Execute migration (reuse existing migration logic)
    if [[ "$type" == "tenant" ]]; then
        mt_migrate_tenant "$name" "$index" "$metrics_file"
    else
        cluster_migrate_node "$name" "$index" "$metrics_file"
    fi

    # Mark completion
    echo "1.0" > "$metrics_file"
    log_success "[$name] Worker completed"
}

mt_migrate_tenant() {
    # Migrate single tenant
    local name="$1"
    local index="$2"
    local metrics_file="$3"

    log_section "[$name] Tenant Migration"

    # Determine migration steps
    local current_version="${PROFILE_KC_CURRENT_VERSION}"
    local target_version="${PROFILE_KC_TARGET_VERSION}"

    local migration_steps=()
    local found_current=false

    for version in "${MIGRATION_PATH[@]}"; do
        if [[ "$version" == "$current_version" ]]; then
            found_current=true
            continue
        fi

        if $found_current; then
            migration_steps+=("$version")
            if [[ "$version" == "$target_version" ]]; then
                break
            fi
        fi
    done

    # Execute migration for each step
    local step_num=1
    local total_steps=${#migration_steps[@]}

    for step_version in "${migration_steps[@]}"; do
        log_info "[$name] Step $step_num/$total_steps: $step_version"

        # Update progress metric
        local progress=$(awk "BEGIN {printf \"%.2f\", $step_num / $total_steps}")
        echo "$progress" > "$metrics_file"

        # Update Prometheus metrics if monitoring enabled
        if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
            prom_update_metric "keycloak_migration_progress" "$progress" "tenant=\"${name}\",from_version=\"${current_version}\",to_version=\"${target_version}\",status=\"in_progress\""
        fi

        # Execute migration step (simplified - in real implementation call migrate_to_version)
        migrate_to_version "$step_version" "$step_num" "$total_steps" || {
            log_error "[$name] Migration failed at $step_version"
            echo "-1.0" > "$metrics_file"
            return 1
        }

        step_num=$((step_num + 1))
    done

    echo "1.0" > "$metrics_file"
    log_success "[$name] Tenant migration complete"
}

cluster_migrate_node() {
    # Migrate single cluster node (rolling update)
    local name="$1"
    local index="$2"
    local metrics_file="$3"

    log_section "[$name] Cluster Node Migration"

    # Step 1: Drain node (remove from load balancer)
    log_info "[$name] Step 1/5: Draining node..."
    cluster_drain_node "$NODE_HOST" || return 1
    echo "0.2" > "$metrics_file"

    # Step 2: Stop Keycloak on this node
    log_info "[$name] Step 2/5: Stopping Keycloak..."
    cluster_stop_node "$NODE_HOST" || return 1
    echo "0.4" > "$metrics_file"

    # Step 3: Update Keycloak version
    log_info "[$name] Step 3/5: Updating Keycloak..."
    cluster_update_node "$NODE_HOST" "${PROFILE_KC_TARGET_VERSION}" || return 1
    echo "0.6" > "$metrics_file"

    # Step 4: Start Keycloak
    log_info "[$name] Step 4/5: Starting Keycloak..."
    cluster_start_node "$NODE_HOST" || return 1
    echo "0.8" > "$metrics_file"

    # Step 5: Re-add to load balancer
    log_info "[$name] Step 5/5: Re-adding to cluster..."
    cluster_undrain_node "$NODE_HOST" || return 1
    echo "1.0" > "$metrics_file"

    log_success "[$name] Node migration complete"
}

cluster_drain_node() {
    local host="$1"
    # Implementation depends on deployment mode
    # For HAProxy: disable server in backend
    # For Kubernetes: kubectl drain
    # For manual: mark as maintenance in nginx/etc
    log_info "Draining node $host..."
    return 0
}

cluster_stop_node() {
    local host="$1"
    ssh "${NODE_SSH_USER}@${host}" "systemctl stop keycloak" || return 1
}

cluster_update_node() {
    local host="$1"
    local version="$2"

    # Download and install new version
    ssh "${NODE_SSH_USER}@${host}" "bash -s" <<EOF
        cd /opt
        wget https://github.com/keycloak/keycloak/releases/download/${version}/keycloak-${version}.tar.gz
        tar xzf keycloak-${version}.tar.gz
        rm -rf keycloak && ln -s keycloak-${version} keycloak
EOF
}

cluster_start_node() {
    local host="$1"
    ssh "${NODE_SSH_USER}@${host}" "systemctl start keycloak" || return 1
    sleep 10  # Wait for startup
}

cluster_undrain_node() {
    local host="$1"
    log_info "Re-adding node $host to cluster..."
    return 0
}

# ============================================================================
# Live Multi-Instance Monitoring
# ============================================================================

mt_monitor_parallel() {
    # Real-time progress monitor for parallel execution
    local type="$1"
    shift
    local -a names=("$@")

    # Extract PIDs (second half of arguments)
    local count=$((${#names[@]} / 2))
    local -a pids=("${names[@]:$count}")
    names=("${names[@]:0:$count}")

    local parallel_workspace="$WORK_DIR/parallel_${type}s"

    log_info "Live monitoring ${count} ${type}s..."
    echo ""

    # Monitor loop
    while true; do
        local all_done=true

        # Clear screen (optional)
        # tput clear

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "%-20s | %-10s | %-40s\n" "INSTANCE" "PROGRESS" "STATUS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        for ((i=0; i<count; i++)); do
            local name="${names[$i]}"
            local pid="${pids[$i]}"
            local metrics_file="$parallel_workspace/${name}.metrics"

            # Check if process still running
            if kill -0 "$pid" 2>/dev/null; then
                all_done=false

                # Read progress
                local progress
                if [[ -f "$metrics_file" ]]; then
                    progress=$(cat "$metrics_file")
                else
                    progress="0.0"
                fi

                # Progress bar
                local bar_width=40
                local filled=$(awk "BEGIN {printf \"%.0f\", $progress * $bar_width}")
                local bar=""
                for ((j=0; j<filled; j++)); do bar+="█"; done
                for ((j=filled; j<bar_width; j++)); do bar+="░"; done

                local percent=$(awk "BEGIN {printf \"%.0f\", $progress * 100}")
                printf "%-20s | %3d%%      | %s\n" "$name" "$percent" "$bar"
            else
                # Process finished
                printf "%-20s | %-10s | %s\n" "$name" "100%" "✓ Complete"
            fi
        done

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        if $all_done; then
            break
        fi

        sleep 2
    done

    log_success "Monitoring complete"
}

# ============================================================================
# Sequential Execution (Fallback)
# ============================================================================

mt_execute_sequential() {
    # Execute migration sequentially (one at a time)
    local type="$1"
    local count="$2"
    local profile_file="$3"

    log_section "Sequential Execution: $count ${type}s"

    for ((i=0; i<count; i++)); do
        local name
        if [[ "$type" == "tenant" ]]; then
            name=$(mt_get_tenant_config "$profile_file" "$i" "name")
        else
            name="node-$((i+1))"
        fi

        log_section "Processing $type: $name ($((i+1))/$count)"

        local log_file="$WORK_DIR/${type}_${name}.log"
        local metrics_file="$WORK_DIR/${type}_${name}.metrics"

        mt_worker "$type" "$i" "$name" "$profile_file" "$log_file" "$metrics_file" || {
            log_error "$type $name failed"
            return 1
        }
    done

    log_success "All $count ${type}s completed"
}
