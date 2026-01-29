#!/usr/bin/env bash
# Blue-Green Migration Strategy (v3.3)
# Zero-downtime deployment with instant traffic switch

set -euo pipefail

# ============================================================================
# Blue-Green Migration — Main Executor
# ============================================================================

bluegreen_execute_migration() {
    # Execute blue-green migration from profile
    # Usage: bluegreen_execute_migration
    log_section "Blue-Green Migration Strategy"

    # Parse blue-green configuration
    local old_environment
    old_environment=$(yq eval '.blue_green.old_environment' "$PROFILE_FILE" 2>/dev/null || echo "blue")

    local new_environment
    new_environment=$(yq eval '.blue_green.new_environment' "$PROFILE_FILE" 2>/dev/null || echo "green")

    local traffic_router_type
    traffic_router_type=$(yq eval '.blue_green.traffic_router.type' "$PROFILE_FILE" 2>/dev/null || echo "istio")

    log_info "Blue-Green environments: OLD=$old_environment, NEW=$new_environment"
    log_info "Traffic router: $traffic_router_type"

    # Step 1: Deploy new environment
    log_info "Step 1/5: Deploying new environment ($new_environment)..."
    bluegreen_deploy_new_environment "$new_environment"

    # Step 2: Wait for readiness
    log_info "Step 2/5: Waiting for new environment to be ready..."
    bluegreen_wait_ready "$new_environment"

    # Step 3: Validation (smoke tests on new environment)
    log_info "Step 3/5: Validating new environment..."
    if ! bluegreen_validate_new_environment "$new_environment"; then
        log_error "New environment validation failed"
        if [[ "${BLUE_GREEN_AUTO_CLEANUP:-true}" == "true" ]]; then
            log_warn "Auto-cleanup enabled, destroying new environment..."
            bluegreen_cleanup_environment "$new_environment"
        fi
        return 1
    fi

    # Step 4: Traffic switch (0% → 100%)
    log_info "Step 4/5: Switching traffic from $old_environment to $new_environment..."
    bluegreen_switch_traffic "$old_environment" "$new_environment" "$traffic_router_type"

    # Step 5: Cleanup old environment (optional)
    if [[ "${BLUE_GREEN_KEEP_OLD:-false}" == "false" ]]; then
        log_info "Step 5/5: Cleaning up old environment ($old_environment)..."
        sleep "${BLUE_GREEN_CLEANUP_DELAY:-300}"  # Wait 5 min before cleanup
        bluegreen_cleanup_environment "$old_environment"
    else
        log_info "Step 5/5: Keeping old environment for manual verification"
    fi

    log_success "Blue-Green migration completed successfully"
}

# ============================================================================
# Environment Deployment
# ============================================================================

bluegreen_deploy_new_environment() {
    # Deploy new environment (green)
    # Usage: bluegreen_deploy_new_environment <environment_name>
    local env_name="$1"

    local namespace
    namespace=$(yq eval '.blue_green.deployment.namespace' "$PROFILE_FILE" 2>/dev/null || echo "default")

    local deployment_type
    deployment_type=$(yq eval '.blue_green.deployment.type' "$PROFILE_FILE" 2>/dev/null || echo "kubernetes")

    local target_version
    target_version=$(yq eval '.migration.target_version' "$PROFILE_FILE" 2>/dev/null || echo "26.0.7")

    log_info "Deploying $env_name environment in $namespace (type: $deployment_type, version: $target_version)"

    case "$deployment_type" in
        kubernetes)
            bluegreen_deploy_k8s "$env_name" "$namespace" "$target_version"
            ;;
        docker-compose)
            bluegreen_deploy_compose "$env_name" "$target_version"
            ;;
        bare-metal)
            bluegreen_deploy_baremetal "$env_name" "$target_version"
            ;;
        *)
            log_error "Unknown deployment type: $deployment_type"
            return 1
            ;;
    esac
}

bluegreen_deploy_k8s() {
    # Deploy Kubernetes environment
    # Usage: bluegreen_deploy_k8s <env_name> <namespace> <version>
    local env_name="$1"
    local namespace="$2"
    local version="$3"

    local deployment_manifest
    deployment_manifest=$(yq eval ".blue_green.deployment.${env_name}_manifest" "$PROFILE_FILE" 2>/dev/null)

    if [[ -n "$deployment_manifest" && -f "$deployment_manifest" ]]; then
        log_info "Applying manifest: $deployment_manifest"
        kubectl apply -f "$deployment_manifest" -n "$namespace" || {
            log_error "Failed to apply manifest"
            return 1
        }
    else
        # Generate deployment from template
        log_info "Generating deployment for $env_name environment"

        local deployment_name="keycloak-${env_name}"
        local replicas
        replicas=$(yq eval '.blue_green.deployment.replicas' "$PROFILE_FILE" 2>/dev/null || echo "3")

        kubectl create deployment "$deployment_name" \
            --image="quay.io/keycloak/keycloak:$version" \
            --replicas="$replicas" \
            -n "$namespace" \
            --dry-run=client -o yaml | \
        kubectl apply -f - -n "$namespace" || {
            log_error "Failed to create deployment"
            return 1
        }

        # Add environment label
        kubectl label deployment "$deployment_name" \
            environment="$env_name" \
            -n "$namespace" --overwrite
    fi

    log_success "Deployment $env_name created in namespace $namespace"
}

bluegreen_deploy_compose() {
    # Deploy Docker Compose environment
    # Usage: bluegreen_deploy_compose <env_name> <version>
    local env_name="$1"
    local version="$2"

    local compose_file
    compose_file=$(yq eval ".blue_green.deployment.${env_name}_compose_file" "$PROFILE_FILE" 2>/dev/null)

    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi

    # Set environment variable for version
    export KEYCLOAK_VERSION="$version"
    export ENVIRONMENT="$env_name"

    log_info "Starting Docker Compose stack: $compose_file"
    docker-compose -f "$compose_file" -p "keycloak-${env_name}" up -d || {
        log_error "Failed to start compose stack"
        return 1
    }

    log_success "Compose stack $env_name started"
}

bluegreen_deploy_baremetal() {
    # Deploy bare-metal environment
    # Usage: bluegreen_deploy_baremetal <env_name> <version>
    local env_name="$1"
    local version="$2"

    # Get server list for this environment
    local servers_count
    servers_count=$(yq eval ".blue_green.deployment.${env_name}_servers | length" "$PROFILE_FILE" 2>/dev/null || echo "0")

    if [[ "$servers_count" -eq 0 ]]; then
        log_error "No servers defined for environment: $env_name"
        return 1
    fi

    log_info "Deploying to $servers_count server(s) for $env_name environment"

    for ((i=0; i<servers_count; i++)); do
        local server_host
        server_host=$(yq eval ".blue_green.deployment.${env_name}_servers[$i].host" "$PROFILE_FILE" 2>/dev/null)

        local ssh_user
        ssh_user=$(yq eval ".blue_green.deployment.${env_name}_servers[$i].ssh_user" "$PROFILE_FILE" 2>/dev/null || echo "keycloak")

        log_info "Deploying to $server_host (user: $ssh_user)..."

        # SSH and deploy (simplified - real implementation would use Ansible/scripts)
        ssh "${ssh_user}@${server_host}" "sudo systemctl stop keycloak-${env_name}; \
            cd /opt/keycloak-${env_name}; \
            wget -O keycloak.tar.gz https://github.com/keycloak/keycloak/releases/download/${version}/keycloak-${version}.tar.gz; \
            tar xzf keycloak.tar.gz --strip-components=1; \
            sudo systemctl start keycloak-${env_name}" || {
            log_error "Failed to deploy to $server_host"
            return 1
        }
    done

    log_success "Bare-metal deployment $env_name completed"
}

# ============================================================================
# Readiness Checks
# ============================================================================

bluegreen_wait_ready() {
    # Wait for new environment to be ready
    # Usage: bluegreen_wait_ready <env_name>
    local env_name="$1"

    local timeout
    timeout=$(yq eval '.blue_green.readiness_timeout' "$PROFILE_FILE" 2>/dev/null || echo "600")

    local deployment_type
    deployment_type=$(yq eval '.blue_green.deployment.type' "$PROFILE_FILE" 2>/dev/null || echo "kubernetes")

    log_info "Waiting for $env_name to be ready (timeout: ${timeout}s)..."

    case "$deployment_type" in
        kubernetes)
            bluegreen_wait_k8s_ready "$env_name" "$timeout"
            ;;
        docker-compose)
            bluegreen_wait_compose_ready "$env_name" "$timeout"
            ;;
        bare-metal)
            bluegreen_wait_baremetal_ready "$env_name" "$timeout"
            ;;
    esac
}

bluegreen_wait_k8s_ready() {
    # Wait for Kubernetes deployment to be ready
    local env_name="$1"
    local timeout="$2"

    local namespace
    namespace=$(yq eval '.blue_green.deployment.namespace' "$PROFILE_FILE" 2>/dev/null || echo "default")

    local deployment_name="keycloak-${env_name}"

    kubectl rollout status deployment/"$deployment_name" \
        -n "$namespace" \
        --timeout="${timeout}s" || {
        log_error "Deployment $deployment_name did not become ready within ${timeout}s"
        return 1
    }

    log_success "Deployment $deployment_name is ready"
}

bluegreen_wait_compose_ready() {
    # Wait for Docker Compose services to be healthy
    local env_name="$1"
    local timeout="$2"

    local elapsed=0
    local project="keycloak-${env_name}"

    while [[ $elapsed -lt $timeout ]]; do
        local healthy
        healthy=$(docker-compose -p "$project" ps --format json 2>/dev/null | \
            jq -r '.[] | select(.Health == "healthy") | .Name' | wc -l)

        if [[ "$healthy" -gt 0 ]]; then
            log_success "Compose stack $env_name is healthy"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "Compose stack $env_name did not become healthy within ${timeout}s"
    return 1
}

bluegreen_wait_baremetal_ready() {
    # Wait for bare-metal servers to respond
    local env_name="$1"
    local timeout="$2"

    local servers_count
    servers_count=$(yq eval ".blue_green.deployment.${env_name}_servers | length" "$PROFILE_FILE" 2>/dev/null || echo "0")

    local health_endpoint
    health_endpoint=$(yq eval '.blue_green.health_endpoint' "$PROFILE_FILE" 2>/dev/null || echo "/health/ready")

    for ((i=0; i<servers_count; i++)); do
        local server_host
        server_host=$(yq eval ".blue_green.deployment.${env_name}_servers[$i].host" "$PROFILE_FILE" 2>/dev/null)

        local port
        port=$(yq eval ".blue_green.deployment.${env_name}_servers[$i].port" "$PROFILE_FILE" 2>/dev/null || echo "8080")

        local url="http://${server_host}:${port}${health_endpoint}"

        log_info "Checking readiness: $url"

        # Source validation library if available
        if [[ -f "$LIB_DIR/validation.sh" ]]; then
            source "$LIB_DIR/validation.sh"
            validate_health_endpoint "$url" 10 "$((timeout / 10))" || return 1
        else
            # Fallback simple check
            local retries=$((timeout / 5))
            local attempt=1
            while [[ $attempt -le $retries ]]; do
                if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
                    log_success "Server $server_host is ready"
                    break
                fi
                sleep 5
                attempt=$((attempt + 1))
            done

            if [[ $attempt -gt $retries ]]; then
                log_error "Server $server_host did not become ready"
                return 1
            fi
        fi
    done

    log_success "All servers in $env_name are ready"
}

# ============================================================================
# Validation
# ============================================================================

bluegreen_validate_new_environment() {
    # Validate new environment (smoke tests)
    # Usage: bluegreen_validate_new_environment <env_name>
    local env_name="$1"

    log_section "Validation — New Environment"

    # Health check
    local health_url
    health_url=$(bluegreen_get_environment_url "$env_name")

    if [[ -f "$LIB_DIR/validation.sh" ]]; then
        source "$LIB_DIR/validation.sh"
        validate_health_endpoint "$health_url" 10 3 || return 1
    fi

    # Optional: Run smoke tests
    local smoke_tests_enabled
    smoke_tests_enabled=$(yq eval '.blue_green.validation.smoke_tests' "$PROFILE_FILE" 2>/dev/null || echo "false")

    if [[ "$smoke_tests_enabled" == "true" ]]; then
        log_info "Running smoke tests..."
        bluegreen_run_smoke_tests "$env_name" || return 1
    fi

    log_success "New environment validation passed"
}

bluegreen_get_environment_url() {
    # Get environment base URL for validation
    # Usage: bluegreen_get_environment_url <env_name>
    local env_name="$1"

    local deployment_type
    deployment_type=$(yq eval '.blue_green.deployment.type' "$PROFILE_FILE" 2>/dev/null || echo "kubernetes")

    case "$deployment_type" in
        kubernetes)
            # Use service endpoint
            local namespace
            namespace=$(yq eval '.blue_green.deployment.namespace' "$PROFILE_FILE" 2>/dev/null || echo "default")
            echo "http://keycloak-${env_name}.${namespace}.svc.cluster.local:8080/health/ready"
            ;;
        docker-compose)
            # Use localhost
            echo "http://localhost:8080/health/ready"
            ;;
        bare-metal)
            # Use first server
            local server_host
            server_host=$(yq eval ".blue_green.deployment.${env_name}_servers[0].host" "$PROFILE_FILE" 2>/dev/null)
            local port
            port=$(yq eval ".blue_green.deployment.${env_name}_servers[0].port" "$PROFILE_FILE" 2>/dev/null || echo "8080")
            echo "http://${server_host}:${port}/health/ready"
            ;;
    esac
}

bluegreen_run_smoke_tests() {
    # Run smoke tests on new environment
    # Usage: bluegreen_run_smoke_tests <env_name>
    local env_name="$1"

    local test_script
    test_script=$(yq eval '.blue_green.validation.smoke_test_script' "$PROFILE_FILE" 2>/dev/null)

    if [[ -n "$test_script" && -f "$test_script" ]]; then
        log_info "Executing smoke test script: $test_script"
        bash "$test_script" "$env_name" || {
            log_error "Smoke tests failed"
            return 1
        }
        log_success "Smoke tests passed"
    else
        log_warn "No smoke test script defined, skipping"
    fi

    return 0
}

# ============================================================================
# Traffic Switching
# ============================================================================

bluegreen_switch_traffic() {
    # Switch traffic from old to new environment (instant 100%)
    # Usage: bluegreen_switch_traffic <old_env> <new_env> <router_type>
    local old_env="$1"
    local new_env="$2"
    local router_type="$3"

    log_info "Switching traffic: $old_env (100% → 0%) / $new_env (0% → 100%)"

    # Source traffic switcher
    if [[ -f "$LIB_DIR/traffic_switcher.sh" ]]; then
        source "$LIB_DIR/traffic_switcher.sh"
    fi

    # Instant switch: 0% old, 100% new
    traffic_switch_weight "$router_type" "$old_env" 0 "$new_env" 100

    log_success "Traffic switched to $new_env"
}

# ============================================================================
# Cleanup
# ============================================================================

bluegreen_cleanup_environment() {
    # Cleanup old environment
    # Usage: bluegreen_cleanup_environment <env_name>
    local env_name="$1"

    log_info "Cleaning up environment: $env_name"

    local deployment_type
    deployment_type=$(yq eval '.blue_green.deployment.type' "$PROFILE_FILE" 2>/dev/null || echo "kubernetes")

    case "$deployment_type" in
        kubernetes)
            local namespace
            namespace=$(yq eval '.blue_green.deployment.namespace' "$PROFILE_FILE" 2>/dev/null || echo "default")
            kubectl delete deployment "keycloak-${env_name}" -n "$namespace" 2>/dev/null || true
            ;;
        docker-compose)
            docker-compose -p "keycloak-${env_name}" down -v 2>/dev/null || true
            ;;
        bare-metal)
            local servers_count
            servers_count=$(yq eval ".blue_green.deployment.${env_name}_servers | length" "$PROFILE_FILE" 2>/dev/null || echo "0")
            for ((i=0; i<servers_count; i++)); do
                local server_host
                server_host=$(yq eval ".blue_green.deployment.${env_name}_servers[$i].host" "$PROFILE_FILE" 2>/dev/null)
                local ssh_user
                ssh_user=$(yq eval ".blue_green.deployment.${env_name}_servers[$i].ssh_user" "$PROFILE_FILE" 2>/dev/null || echo "keycloak")
                ssh "${ssh_user}@${server_host}" "sudo systemctl stop keycloak-${env_name}" 2>/dev/null || true
            done
            ;;
    esac

    log_success "Environment $env_name cleaned up"
}

# ============================================================================
# Rollback
# ============================================================================

bluegreen_rollback() {
    # Rollback to old environment
    # Usage: bluegreen_rollback <old_env> <new_env> <router_type>
    local old_env="$1"
    local new_env="$2"
    local router_type="$3"

    log_section "Blue-Green Rollback"

    log_info "Rolling back to $old_env (reverting traffic)"

    # Source traffic switcher
    if [[ -f "$LIB_DIR/traffic_switcher.sh" ]]; then
        source "$LIB_DIR/traffic_switcher.sh"
    fi

    # Switch back: 100% old, 0% new
    traffic_switch_weight "$router_type" "$old_env" 100 "$new_env" 0

    log_success "Rollback complete — traffic restored to $old_env"

    # Optional: cleanup failed new environment
    if [[ "${BLUE_GREEN_AUTO_CLEANUP:-true}" == "true" ]]; then
        log_info "Cleaning up failed new environment..."
        bluegreen_cleanup_environment "$new_env"
    fi
}
