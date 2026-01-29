#!/usr/bin/env bash
# Profile Manager for Keycloak Migration v3.0
# Handles loading and saving YAML configuration profiles

set -euo pipefail

# Profile directory
PROFILE_DIR="${PROFILE_DIR:-./profiles}"

# ============================================================================
# Profile Discovery
# ============================================================================

profile_list() {
    # List all available profiles
    if [[ ! -d "$PROFILE_DIR" ]]; then
        echo "No profiles directory found at: $PROFILE_DIR" >&2
        return 1
    fi

    find "$PROFILE_DIR" -name "*.yaml" -o -name "*.yml" | sort
}

profile_exists() {
    local profile_name="$1"
    local profile_file="$PROFILE_DIR/${profile_name}.yaml"

    [[ -f "$profile_file" ]] || [[ -f "${PROFILE_DIR}/${profile_name}.yml" ]]
}

# ============================================================================
# YAML Parsing Helper
# ============================================================================

parse_yaml_value() {
    # Extract value for a given key from YAML file
    # Usage: parse_yaml_value "key_name" "file_path"
    local key="$1"
    local file="$2"
    grep "^\s*${key}:" "$file" | head -1 | sed 's/#.*//' | sed 's/.*:\s*//' | xargs
}

parse_yaml_section_value() {
    # Extract value for a key within a specific YAML section
    # Usage: parse_yaml_section_value "section" "key" "file_path"
    local section="$1"
    local key="$2"
    local file="$3"
    # Extract lines between section header and next top-level key, then grep for key
    sed -n "/^${section}:/,/^[a-z]/p" "$file" | grep "^\s*${key}:" | head -1 | sed 's/#.*//' | sed 's/.*:\s*//' | xargs
}

# ============================================================================
# Profile Loading (YAML parsing)
# ============================================================================

profile_load() {
    local profile_name="$1"
    local profile_file="$PROFILE_DIR/${profile_name}.yaml"

    [[ -f "$profile_file" ]] || profile_file="${PROFILE_DIR}/${profile_name}.yml"

    if [[ ! -f "$profile_file" ]]; then
        echo "ERROR: Profile not found: $profile_name" >&2
        echo "Available profiles:" >&2
        profile_list >&2
        return 1
    fi

    # Export profile file path for multi-instance handlers
    export PROFILE_FILE="$profile_file"

    # Parse YAML using simple grep/sed (no external dependencies)
    # Export variables with PROFILE_ prefix
    # Strip comments (everything after #) before parsing

    # Database settings (take first occurrence of each key)
    export PROFILE_DB_TYPE=$(parse_yaml_value "type" "$profile_file")
    export PROFILE_DB_LOCATION=$(parse_yaml_value "location" "$profile_file")
    export PROFILE_DB_HOST=$(parse_yaml_value "host" "$profile_file")
    export PROFILE_DB_PORT=$(parse_yaml_value "port" "$profile_file")
    export PROFILE_DB_NAME=$(parse_yaml_section_value "database" "name" "$profile_file")
    export PROFILE_DB_USER=$(parse_yaml_value "user" "$profile_file")
    export PROFILE_DB_CREDENTIALS_SOURCE=$(parse_yaml_value "credentials_source" "$profile_file")

    # Keycloak settings
    export PROFILE_KC_DEPLOYMENT_MODE=$(parse_yaml_value "deployment_mode" "$profile_file")
    export PROFILE_KC_DISTRIBUTION_MODE=$(parse_yaml_value "distribution_mode" "$profile_file")
    export PROFILE_KC_CLUSTER_MODE=$(parse_yaml_value "cluster_mode" "$profile_file")
    export PROFILE_KC_CURRENT_VERSION=$(parse_yaml_value "current_version" "$profile_file")
    export PROFILE_KC_TARGET_VERSION=$(parse_yaml_value "target_version" "$profile_file")
    export PROFILE_KC_HOME_DIR=$(parse_yaml_value "home_dir" "$profile_file")
    export PROFILE_KC_SERVICE_NAME=$(parse_yaml_value "service_name" "$profile_file")

    # Kubernetes settings (if applicable)
    export PROFILE_K8S_NAMESPACE=$(parse_yaml_value "namespace" "$profile_file")
    export PROFILE_K8S_DEPLOYMENT=$(parse_yaml_value "deployment" "$profile_file")
    export PROFILE_K8S_SERVICE=$(parse_yaml_value "service" "$profile_file")
    export PROFILE_K8S_REPLICAS=$(parse_yaml_value "replicas" "$profile_file")

    # Container settings (if applicable)
    export PROFILE_CONTAINER_REGISTRY=$(parse_yaml_value "registry" "$profile_file")
    export PROFILE_CONTAINER_IMAGE=$(parse_yaml_value "image" "$profile_file")
    export PROFILE_CONTAINER_PULL_POLICY=$(parse_yaml_value "pull_policy" "$profile_file")

    # Docker Compose settings (if applicable)
    export PROFILE_KC_COMPOSE_FILE=$(parse_yaml_section_value "docker_compose" "compose_file" "$profile_file")
    export PROFILE_KC_COMPOSE_SERVICE=$(parse_yaml_section_value "docker_compose" "service_name" "$profile_file")
    export PROFILE_KC_CONTAINER_NAME=$(parse_yaml_value "container_name" "$profile_file")

    # Migration settings
    export PROFILE_MIGRATION_STRATEGY=$(parse_yaml_value "strategy" "$profile_file")
    export PROFILE_MIGRATION_PARALLEL_JOBS=$(parse_yaml_value "parallel_jobs" "$profile_file")
    export PROFILE_MIGRATION_TIMEOUT=$(parse_yaml_value "timeout_per_version" "$profile_file")
    export PROFILE_MIGRATION_RUN_TESTS=$(parse_yaml_value "run_smoke_tests" "$profile_file")
    export PROFILE_MIGRATION_BACKUP=$(parse_yaml_value "backup_before_step" "$profile_file")

    # Multi-instance settings (v3.2)
    export PROFILE_MODE=$(parse_yaml_section_value "profile" "mode" "$profile_file")

    # Rollout settings
    export PROFILE_ROLLOUT_TYPE=$(parse_yaml_section_value "rollout" "type" "$profile_file")
    export PROFILE_ROLLOUT_MAX_CONCURRENT=$(parse_yaml_section_value "rollout" "max_concurrent" "$profile_file")
    export PROFILE_ROLLOUT_NODES_AT_ONCE=$(parse_yaml_section_value "rollout" "nodes_at_once" "$profile_file")
    export PROFILE_ROLLOUT_DRAIN_TIMEOUT=$(parse_yaml_section_value "rollout" "drain_timeout" "$profile_file")

    # Cluster load balancer settings
    export PROFILE_LB_TYPE=$(parse_yaml_section_value "cluster.load_balancer" "type" "$profile_file")
    export PROFILE_LB_HOST=$(parse_yaml_section_value "cluster.load_balancer" "host" "$profile_file")
    export PROFILE_LB_ADMIN_SOCKET=$(parse_yaml_section_value "cluster.load_balancer" "admin_socket" "$profile_file")
    export PROFILE_LB_BACKEND=$(parse_yaml_section_value "cluster.load_balancer" "backend_name" "$profile_file")

    echo "Profile loaded: $profile_name"
}

# ============================================================================
# Profile Saving (YAML generation)
# ============================================================================

profile_save() {
    local profile_name="$1"
    local profile_file="$PROFILE_DIR/${profile_name}.yaml"

    # Create profiles directory if not exists
    mkdir -p "$PROFILE_DIR"

    # Generate YAML profile
    cat > "$profile_file" << EOF
# Keycloak Migration Profile v3.0
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

profile:
  name: $profile_name
  environment: ${PROFILE_KC_DEPLOYMENT_MODE:-standalone}

database:
  type: ${PROFILE_DB_TYPE:-postgresql}
  location: ${PROFILE_DB_LOCATION:-standalone}
  host: ${PROFILE_DB_HOST:-localhost}
  port: ${PROFILE_DB_PORT:-5432}
  name: ${PROFILE_DB_NAME:-keycloak}
  user: ${PROFILE_DB_USER:-keycloak}
  credentials_source: ${PROFILE_DB_CREDENTIALS_SOURCE:-env}

keycloak:
  deployment_mode: ${PROFILE_KC_DEPLOYMENT_MODE:-standalone}
  distribution_mode: ${PROFILE_KC_DISTRIBUTION_MODE:-download}
  cluster_mode: ${PROFILE_KC_CLUSTER_MODE:-standalone}

  current_version: ${PROFILE_KC_CURRENT_VERSION:-16.1.1}
  target_version: ${PROFILE_KC_TARGET_VERSION:-26.0.7}

EOF

    # Add Kubernetes settings if applicable
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
        cat >> "$profile_file" << EOF
  kubernetes:
    namespace: ${PROFILE_K8S_NAMESPACE:-keycloak}
    deployment: ${PROFILE_K8S_DEPLOYMENT:-keycloak}
    service: ${PROFILE_K8S_SERVICE:-keycloak-http}
    replicas: ${PROFILE_K8S_REPLICAS:-1}

EOF
    fi

    # Add docker-compose settings if applicable
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" == "docker-compose" ]]; then
        cat >> "$profile_file" << EOF
  docker_compose:
    compose_file: ${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}
    service_name: ${PROFILE_KC_COMPOSE_SERVICE:-keycloak}

EOF
    fi

    # Add container settings if applicable
    if [[ "${PROFILE_KC_DISTRIBUTION_MODE}" == "container" ]]; then
        cat >> "$profile_file" << EOF
  container:
    registry: ${PROFILE_CONTAINER_REGISTRY:-docker.io}
    image: ${PROFILE_CONTAINER_IMAGE:-keycloak/keycloak}
    pull_policy: ${PROFILE_CONTAINER_PULL_POLICY:-IfNotPresent}

EOF
    fi

    # Add migration settings
    cat >> "$profile_file" << EOF
migration:
  strategy: ${PROFILE_MIGRATION_STRATEGY:-inplace}
  parallel_jobs: ${PROFILE_MIGRATION_PARALLEL_JOBS:-4}
  timeout_per_version: ${PROFILE_MIGRATION_TIMEOUT:-900}
  run_smoke_tests: ${PROFILE_MIGRATION_RUN_TESTS:-true}
  backup_before_step: ${PROFILE_MIGRATION_BACKUP:-true}
EOF

    echo "Profile saved: $profile_file"
}

# ============================================================================
# Profile Validation
# ============================================================================

profile_validate() {
    local profile_name="$1"

    # Load profile first
    profile_load "$profile_name" || return 1

    local errors=0

    # Validate database type
    if [[ -z "${PROFILE_DB_TYPE}" ]]; then
        echo "ERROR: Database type not specified" >&2
        errors=$((errors + 1))
    fi

    # Validate deployment mode
    if [[ -z "${PROFILE_KC_DEPLOYMENT_MODE}" ]]; then
        echo "ERROR: Deployment mode not specified" >&2
        errors=$((errors + 1))
    fi

    # Validate versions
    if [[ -z "${PROFILE_KC_CURRENT_VERSION}" || -z "${PROFILE_KC_TARGET_VERSION}" ]]; then
        echo "ERROR: Keycloak versions not specified" >&2
        errors=$((errors + 1))
    fi

    # Validate Kubernetes settings if K8s mode
    if [[ "${PROFILE_KC_DEPLOYMENT_MODE}" =~ ^(kubernetes|deckhouse)$ ]]; then
        if [[ -z "${PROFILE_K8S_NAMESPACE}" ]]; then
            echo "ERROR: Kubernetes namespace not specified" >&2
            errors=$((errors + 1))
        fi
    fi

    if [[ $errors -gt 0 ]]; then
        echo "Profile validation failed: $errors errors" >&2
        return 1
    fi

    echo "Profile validation passed: $profile_name"
    return 0
}

# ============================================================================
# Profile Summary
# ============================================================================

profile_summary() {
    local profile_name="$1"

    profile_load "$profile_name" || return 1

    cat << EOF
┌─────────────────────────────────────────────────────────────────┐
│ Profile: $profile_name
├─────────────────────────────────────────────────────────────────┤
│ Database:        ${PROFILE_DB_TYPE} (${PROFILE_DB_LOCATION})
│ Host:            ${PROFILE_DB_HOST}:${PROFILE_DB_PORT}
│ Database Name:   ${PROFILE_DB_NAME}
├─────────────────────────────────────────────────────────────────┤
│ Deployment:      ${PROFILE_KC_DEPLOYMENT_MODE}
│ Distribution:    ${PROFILE_KC_DISTRIBUTION_MODE}
│ Cluster Mode:    ${PROFILE_KC_CLUSTER_MODE}
├─────────────────────────────────────────────────────────────────┤
│ Current Version: ${PROFILE_KC_CURRENT_VERSION}
│ Target Version:  ${PROFILE_KC_TARGET_VERSION}
├─────────────────────────────────────────────────────────────────┤
│ Migration:       ${PROFILE_MIGRATION_STRATEGY}
│ Parallel Jobs:   ${PROFILE_MIGRATION_PARALLEL_JOBS}
│ Timeout/version: ${PROFILE_MIGRATION_TIMEOUT}s
│ Smoke Tests:     ${PROFILE_MIGRATION_RUN_TESTS}
│ Backups:         ${PROFILE_MIGRATION_BACKUP}
└─────────────────────────────────────────────────────────────────┘
EOF
}

# ============================================================================
# Profile Templates
# ============================================================================

profile_create_template() {
    local template_type="${1:-standalone}"

    case "$template_type" in
        standalone)
            export PROFILE_DB_TYPE="postgresql"
            export PROFILE_DB_LOCATION="standalone"
            export PROFILE_DB_HOST="localhost"
            export PROFILE_DB_PORT="5432"
            export PROFILE_DB_NAME="keycloak"
            export PROFILE_DB_USER="keycloak"
            export PROFILE_DB_CREDENTIALS_SOURCE="env"
            export PROFILE_KC_DEPLOYMENT_MODE="standalone"
            export PROFILE_KC_DISTRIBUTION_MODE="download"
            export PROFILE_KC_CLUSTER_MODE="standalone"
            export PROFILE_MIGRATION_STRATEGY="inplace"
            ;;

        kubernetes)
            export PROFILE_DB_TYPE="postgresql"
            export PROFILE_DB_LOCATION="kubernetes"
            export PROFILE_DB_HOST="postgres-postgresql.database.svc.cluster.local"
            export PROFILE_DB_PORT="5432"
            export PROFILE_DB_NAME="keycloak"
            export PROFILE_DB_USER="keycloak"
            export PROFILE_DB_CREDENTIALS_SOURCE="secret"
            export PROFILE_KC_DEPLOYMENT_MODE="kubernetes"
            export PROFILE_KC_DISTRIBUTION_MODE="container"
            export PROFILE_KC_CLUSTER_MODE="infinispan"
            export PROFILE_K8S_NAMESPACE="keycloak"
            export PROFILE_K8S_DEPLOYMENT="keycloak"
            export PROFILE_K8S_SERVICE="keycloak-http"
            export PROFILE_K8S_REPLICAS="3"
            export PROFILE_CONTAINER_REGISTRY="docker.io"
            export PROFILE_CONTAINER_IMAGE="keycloak/keycloak"
            export PROFILE_CONTAINER_PULL_POLICY="IfNotPresent"
            export PROFILE_MIGRATION_STRATEGY="rolling_update"
            ;;

        docker)
            export PROFILE_DB_TYPE="postgresql"
            export PROFILE_DB_LOCATION="docker"
            export PROFILE_DB_HOST="postgres"
            export PROFILE_DB_PORT="5432"
            export PROFILE_DB_NAME="keycloak"
            export PROFILE_DB_USER="keycloak"
            export PROFILE_DB_CREDENTIALS_SOURCE="env"
            export PROFILE_KC_DEPLOYMENT_MODE="docker-compose"
            export PROFILE_KC_DISTRIBUTION_MODE="container"
            export PROFILE_KC_CLUSTER_MODE="standalone"
            export PROFILE_MIGRATION_STRATEGY="inplace"
            ;;

        *)
            echo "ERROR: Unknown template type: $template_type" >&2
            echo "Available: standalone, kubernetes, docker" >&2
            return 1
            ;;
    esac

    # Common settings
    export PROFILE_KC_CURRENT_VERSION="16.1.1"
    export PROFILE_KC_TARGET_VERSION="26.0.7"
    export PROFILE_MIGRATION_PARALLEL_JOBS="4"
    export PROFILE_MIGRATION_TIMEOUT="900"
    export PROFILE_MIGRATION_RUN_TESTS="true"
    export PROFILE_MIGRATION_BACKUP="true"

    echo "Template created: $template_type"
}
