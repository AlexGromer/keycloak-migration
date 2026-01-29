#!/usr/bin/env bash
#
# Keycloak Migration Configuration Wizard v3.0
# Interactive setup for multi-environment migrations with auto-discovery
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Source libraries
source "$LIB_DIR/database_adapter.sh"
source "$LIB_DIR/deployment_adapter.sh"
source "$LIB_DIR/profile_manager.sh"
source "$LIB_DIR/keycloak_discovery.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Profile directory
PROFILE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/profiles"
mkdir -p "$PROFILE_DIR"

# Non-interactive mode (for CI/CD, Ansible, automation)
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}═══ $1 ═══${NC}\n"; }

#######################################
# Utility functions
#######################################
ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice=""

    # Non-interactive: return first option (default)
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo "${options[0]}"
        return 0
    fi

    echo -e "${MAGENTA}${prompt}${NC}"

    local i=1
    for opt in "${options[@]}"; do
        echo "  $i) $opt"
        i=$((i + 1))
    done

    while true; do
        read -r -p "Your choice [1]: " choice
        choice=${choice:-1}

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#options[@]} ]]; then
            echo "${options[$((choice-1))]}"
            return 0
        else
            echo -e "${RED}Invalid choice. Please enter 1-${#options[@]}.${NC}"
        fi
    done
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"

    # Non-interactive: use default
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ "$default" =~ ^[Yy]$ ]]
        return $?
    fi

    local choices="[Y/n]"
    [[ "$default" == "n" ]] && choices="[y/N]"

    read -r -p "${prompt} ${choices}: " answer
    answer=${answer:-$default}

    [[ "$answer" =~ ^[Yy]$ ]]
}

ask_text() {
    local prompt="$1"
    local default="$2"

    # Non-interactive: use default
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo "$default"
        return 0
    fi

    read -r -p "${prompt} [$default]: " answer
    echo "${answer:-$default}"
}

#######################################
# Banner
#######################################
print_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
┌─────────────────────────────────────────────────────────────────┐
│   Keycloak Migration Configuration Wizard v3.0                  │
│   Universal Migration Tool for All Environments                 │
└─────────────────────────────────────────────────────────────────┘
EOF
    echo -e "${NC}"
}

#######################################
# Step 0: Auto-Discovery (Optional)
#######################################
step_auto_discovery() {
    log_section "[0/8] Auto-Discovery"

    echo "Would you like to auto-discover existing Keycloak installation?"
    echo "This will scan your environment for Keycloak instances."
    echo ""

    if ask_yes_no "Run auto-discovery?" "y"; then
        echo ""
        kc_auto_discover_profile || {
            log_warn "Auto-discovery failed or no installations found"
            echo "Proceeding with manual configuration..."
        }
    else
        log_info "Skipping auto-discovery, proceeding with manual configuration"
    fi
}

#######################################
# Step 1: Database Type
#######################################
step_database_type() {
    log_section "[1/8] Database Type"

    # Auto-detect if not already set
    if [[ -z "${PROFILE_DB_TYPE:-}" ]]; then
        echo "Detecting available databases..."
        local detected=$(db_detect_type)

        if [[ "$detected" != "unknown" ]]; then
            log_success "Detected: ${DB_ADAPTERS[$detected]}"
            echo ""
            if ask_yes_no "Use detected database ($detected)?" "y"; then
                PROFILE_DB_TYPE="$detected"
                return 0
            fi
        fi
    else
        log_info "Database type already set from auto-discovery: $PROFILE_DB_TYPE"
        if ask_yes_no "Keep this database type?" "y"; then
            return 0
        fi
    fi

    echo ""
    local choice=$(ask_choice "Select database type:" \
        "PostgreSQL (recommended)" \
        "MySQL" \
        "MariaDB" \
        "Oracle (basic support)" \
        "Microsoft SQL Server (basic support)")

    case "$choice" in
        "PostgreSQL"*) PROFILE_DB_TYPE="postgresql" ;;
        "MySQL") PROFILE_DB_TYPE="mysql" ;;
        "MariaDB") PROFILE_DB_TYPE="mariadb" ;;
        "Oracle"*) PROFILE_DB_TYPE="oracle" ;;
        *"SQL Server"*) PROFILE_DB_TYPE="mssql" ;;
    esac

    log_success "Database type: $PROFILE_DB_TYPE"
}

#######################################
# Step 2: Database Location
#######################################
step_database_location() {
    log_section "[2/8] Database Location"

    if [[ -n "${PROFILE_DB_HOST:-}" ]]; then
        log_info "Database location already set from auto-discovery: $PROFILE_DB_HOST:${PROFILE_DB_PORT}"
        if ask_yes_no "Keep this database location?" "y"; then
            return 0
        fi
    fi

    echo ""
    local choice=$(ask_choice "Where is the database running?" \
        "Standalone (localhost)" \
        "Docker container" \
        "Kubernetes service" \
        "External (RDS, Cloud SQL, etc.)" \
        "Database cluster (Patroni, PgPool, etc.)")

    case "$choice" in
        "Standalone"*)
            PROFILE_DB_LOCATION="standalone"
            PROFILE_DB_HOST="localhost"
            PROFILE_DB_PORT="${DB_DEFAULT_PORTS[$PROFILE_DB_TYPE]}"
            ;;
        "Docker"*)
            PROFILE_DB_LOCATION="docker"
            PROFILE_DB_HOST=$(ask_text "Container name" "postgres")
            PROFILE_DB_PORT="${DB_DEFAULT_PORTS[$PROFILE_DB_TYPE]}"
            ;;
        "Kubernetes"*)
            PROFILE_DB_LOCATION="kubernetes"
            PROFILE_DB_HOST=$(ask_text "Service name (FQDN)" "postgres-postgresql.database.svc.cluster.local")
            PROFILE_DB_PORT="${DB_DEFAULT_PORTS[$PROFILE_DB_TYPE]}"
            ;;
        "External"*)
            PROFILE_DB_LOCATION="external"
            PROFILE_DB_HOST=$(ask_text "Hostname or IP" "")
            PROFILE_DB_PORT=$(ask_text "Port" "${DB_DEFAULT_PORTS[$PROFILE_DB_TYPE]}")
            ;;
        "Database cluster"*)
            PROFILE_DB_LOCATION="cluster"
            PROFILE_DB_HOST=$(ask_text "VIP or load balancer" "")
            PROFILE_DB_PORT=$(ask_text "Port" "${DB_DEFAULT_PORTS[$PROFILE_DB_TYPE]}")
            ;;
    esac

    PROFILE_DB_NAME=$(ask_text "Database name" "keycloak")
    PROFILE_DB_USER=$(ask_text "Database user" "keycloak")
    PROFILE_DB_CREDENTIALS_SOURCE=$(ask_choice "Password source?" \
        "Environment variable" \
        "File (.pgpass, .my.cnf)" \
        "Kubernetes secret" \
        "Vault") || echo "env"

    case "$PROFILE_DB_CREDENTIALS_SOURCE" in
        "Environment"*) PROFILE_DB_CREDENTIALS_SOURCE="env" ;;
        "File"*) PROFILE_DB_CREDENTIALS_SOURCE="file" ;;
        "Kubernetes"*) PROFILE_DB_CREDENTIALS_SOURCE="secret" ;;
        "Vault") PROFILE_DB_CREDENTIALS_SOURCE="vault" ;;
    esac

    log_success "Database: $PROFILE_DB_TYPE @ $PROFILE_DB_HOST:$PROFILE_DB_PORT/$PROFILE_DB_NAME"
}

#######################################
# Step 3: Keycloak Deployment Mode
#######################################
step_deployment_mode() {
    log_section "[3/8] Keycloak Deployment Mode"

    # Auto-detect if not already set
    if [[ -z "${PROFILE_KC_DEPLOYMENT_MODE:-}" ]]; then
        echo "Detecting deployment mode..."
        local detected=$(deploy_detect_mode)
        log_success "Detected: ${DEPLOY_MODES[$detected]}"
        echo ""
        if ask_yes_no "Use detected deployment mode ($detected)?" "y"; then
            PROFILE_KC_DEPLOYMENT_MODE="$detected"
            return 0
        fi
    else
        log_info "Deployment mode already set from auto-discovery: $PROFILE_KC_DEPLOYMENT_MODE"
        if ask_yes_no "Keep this deployment mode?" "y"; then
            return 0
        fi
    fi

    echo ""
    local choice=$(ask_choice "How is Keycloak deployed?" \
        "Standalone (systemd/filesystem)" \
        "Docker (single container)" \
        "Docker Compose (multi-service stack)" \
        "Kubernetes (native)" \
        "Deckhouse (K8s + Deckhouse modules)")

    case "$choice" in
        "Standalone"*) PROFILE_KC_DEPLOYMENT_MODE="standalone" ;;
        "Docker (single"*) PROFILE_KC_DEPLOYMENT_MODE="docker" ;;
        "Docker Compose"*) PROFILE_KC_DEPLOYMENT_MODE="docker-compose" ;;
        "Kubernetes"*) PROFILE_KC_DEPLOYMENT_MODE="kubernetes" ;;
        "Deckhouse"*) PROFILE_KC_DEPLOYMENT_MODE="deckhouse" ;;
    esac

    log_success "Deployment mode: $PROFILE_KC_DEPLOYMENT_MODE"
}

#######################################
# Step 4: Keycloak Distribution
#######################################
step_distribution_mode() {
    log_section "[4/8] Keycloak Distribution"

    echo ""
    local choice=$(ask_choice "How to obtain Keycloak distributions?" \
        "Download from GitHub (always latest)" \
        "Use pre-downloaded archives (faster, offline)" \
        "Container images (docker.io/keycloak)" \
        "Helm charts (for Kubernetes)")

    case "$choice" in
        "Download"*) PROFILE_KC_DISTRIBUTION_MODE="download" ;;
        "Use pre-downloaded"*) PROFILE_KC_DISTRIBUTION_MODE="predownloaded" ;;
        "Container"*) PROFILE_KC_DISTRIBUTION_MODE="container" ;;
        "Helm"*) PROFILE_KC_DISTRIBUTION_MODE="helm" ;;
    esac

    # Container-specific settings
    if [[ "$PROFILE_KC_DISTRIBUTION_MODE" == "container" ]]; then
        PROFILE_CONTAINER_REGISTRY=$(ask_text "Container registry" "docker.io")
        PROFILE_CONTAINER_IMAGE=$(ask_text "Image name" "keycloak/keycloak")
        PROFILE_CONTAINER_PULL_POLICY=$(ask_choice "Image pull policy?" \
            "IfNotPresent (default)" \
            "Always (always pull latest)" \
            "Never (use local only)") || echo "IfNotPresent"

        case "$PROFILE_CONTAINER_PULL_POLICY" in
            "IfNotPresent"*) PROFILE_CONTAINER_PULL_POLICY="IfNotPresent" ;;
            "Always"*) PROFILE_CONTAINER_PULL_POLICY="Always" ;;
            "Never"*) PROFILE_CONTAINER_PULL_POLICY="Never" ;;
        esac
    fi

    log_success "Distribution mode: $PROFILE_KC_DISTRIBUTION_MODE"
}

#######################################
# Step 5: Cluster Mode
#######################################
step_cluster_mode() {
    log_section "[5/8] Keycloak Cluster Mode"

    echo ""
    local choice=$(ask_choice "Keycloak cluster configuration?" \
        "Standalone (single instance)" \
        "Cluster with Infinispan (embedded cache)" \
        "Cluster with external cache (Redis/Hazelcast)")

    case "$choice" in
        "Standalone"*) PROFILE_KC_CLUSTER_MODE="standalone" ;;
        *"Infinispan"*) PROFILE_KC_CLUSTER_MODE="infinispan" ;;
        *"external"*) PROFILE_KC_CLUSTER_MODE="external" ;;
    esac

    # Kubernetes-specific: ask for replicas
    if [[ "$PROFILE_KC_DEPLOYMENT_MODE" =~ ^(kubernetes|deckhouse)$ ]]; then
        if [[ -z "${PROFILE_K8S_NAMESPACE:-}" ]]; then
            PROFILE_K8S_NAMESPACE=$(ask_text "Kubernetes namespace" "keycloak")
            PROFILE_K8S_DEPLOYMENT=$(ask_text "Deployment name" "keycloak")
            PROFILE_K8S_SERVICE=$(ask_text "Service name" "keycloak-http")
        fi

        if [[ "$PROFILE_KC_CLUSTER_MODE" != "standalone" ]]; then
            PROFILE_K8S_REPLICAS=$(ask_text "Number of replicas" "3")
        else
            PROFILE_K8S_REPLICAS="1"
        fi
    fi

    log_success "Cluster mode: $PROFILE_KC_CLUSTER_MODE"
}

#######################################
# Step 6: Migration Strategy
#######################################
step_migration_strategy() {
    log_section "[6/8] Migration Strategy"

    echo ""
    if [[ "$PROFILE_KC_DEPLOYMENT_MODE" =~ ^(kubernetes|deckhouse)$ ]] && [[ "${PROFILE_K8S_REPLICAS:-1}" -gt 1 ]]; then
        log_info "Detected multi-node Kubernetes cluster"
        local choice=$(ask_choice "Migration strategy (recommended: Rolling Update)?" \
            "Rolling update (zero-downtime, one pod at a time)" \
            "Blue-green deployment (new deployment alongside old)" \
            "In-place (stop → migrate → start)")

        case "$choice" in
            "Rolling"*) PROFILE_MIGRATION_STRATEGY="rolling_update" ;;
            "Blue-green"*) PROFILE_MIGRATION_STRATEGY="blue_green" ;;
            "In-place"*) PROFILE_MIGRATION_STRATEGY="inplace" ;;
        esac
    else
        local choice=$(ask_choice "Migration strategy?" \
            "In-place (stop → migrate → start)" \
            "Blue-green (if supported)")

        case "$choice" in
            "In-place"*) PROFILE_MIGRATION_STRATEGY="inplace" ;;
            "Blue-green"*) PROFILE_MIGRATION_STRATEGY="blue_green" ;;
        esac
    fi

    log_success "Migration strategy: $PROFILE_MIGRATION_STRATEGY"
}

#######################################
# Step 7: Versions
#######################################
step_versions() {
    log_section "[7/8] Keycloak Versions"

    if [[ -n "${PROFILE_KC_CURRENT_VERSION:-}" ]]; then
        log_info "Current version detected: $PROFILE_KC_CURRENT_VERSION"
        if ask_yes_no "Is this correct?" "y"; then
            :
        else
            PROFILE_KC_CURRENT_VERSION=$(ask_text "Current Keycloak version" "16.1.1")
        fi
    else
        PROFILE_KC_CURRENT_VERSION=$(ask_text "Current Keycloak version" "16.1.1")
    fi

    PROFILE_KC_TARGET_VERSION=$(ask_text "Target Keycloak version" "26.0.7")

    log_success "Migration: $PROFILE_KC_CURRENT_VERSION → $PROFILE_KC_TARGET_VERSION"
}

#######################################
# Step 8: Additional Options
#######################################
step_additional_options() {
    log_section "[8/8] Additional Options"

    echo ""
    PROFILE_MIGRATION_RUN_TESTS=$(ask_yes_no "Run smoke tests after each version?" "y" && echo "true" || echo "false")
    PROFILE_MIGRATION_BACKUP=$(ask_yes_no "Create backups before each step?" "y" && echo "true" || echo "false")

    PROFILE_MIGRATION_PARALLEL_JOBS=$(ask_text "Parallel jobs for backup (1-8)" "4")
    PROFILE_MIGRATION_TIMEOUT=$(ask_text "Timeout per version (seconds)" "900")

    log_success "Options configured"
}

#######################################
# Configuration Summary
#######################################
show_summary() {
    log_section "Configuration Summary"

    cat << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Profile:           ${PROFILE_NAME}

  Database:          ${PROFILE_DB_TYPE} (${PROFILE_DB_LOCATION})
                     ${PROFILE_DB_HOST}:${PROFILE_DB_PORT}/${PROFILE_DB_NAME}

  Deployment:        ${PROFILE_KC_DEPLOYMENT_MODE}
  Distribution:      ${PROFILE_KC_DISTRIBUTION_MODE}
  Cluster Mode:      ${PROFILE_KC_CLUSTER_MODE}
EOF

    if [[ "$PROFILE_KC_DEPLOYMENT_MODE" =~ ^(kubernetes|deckhouse)$ ]]; then
        cat << EOF

  Kubernetes:        ${PROFILE_K8S_NAMESPACE}/${PROFILE_K8S_DEPLOYMENT}
                     Replicas: ${PROFILE_K8S_REPLICAS}
EOF
    fi

    cat << EOF

  Migration:         ${PROFILE_KC_CURRENT_VERSION} → ${PROFILE_KC_TARGET_VERSION}
  Strategy:          ${PROFILE_MIGRATION_STRATEGY}

  Options:
    Smoke Tests:     ${PROFILE_MIGRATION_RUN_TESTS}
    Backups:         ${PROFILE_MIGRATION_BACKUP}
    Parallel Jobs:   ${PROFILE_MIGRATION_PARALLEL_JOBS}
    Timeout:         ${PROFILE_MIGRATION_TIMEOUT}s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

#######################################
# Main Wizard Flow
#######################################
main() {
    # Parse CLI arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE="true"; shift ;;
            --profile-name) PROFILE_NAME_OVERRIDE="$2"; shift 2 ;;
            --help)
                echo "Usage: config_wizard.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --non-interactive   Run with defaults/env vars (no prompts)"
                echo "  --profile-name NAME Override generated profile name"
                echo ""
                echo "Non-interactive env vars (set before running):"
                echo "  PROFILE_DB_TYPE, PROFILE_DB_HOST, PROFILE_DB_PORT, PROFILE_DB_NAME"
                echo "  PROFILE_DB_USER, PROFILE_DB_LOCATION, PROFILE_DB_CREDENTIALS_SOURCE"
                echo "  PROFILE_KC_DEPLOYMENT_MODE, PROFILE_KC_DISTRIBUTION_MODE"
                echo "  PROFILE_KC_CLUSTER_MODE, PROFILE_KC_CURRENT_VERSION"
                echo "  PROFILE_KC_TARGET_VERSION, PROFILE_MIGRATION_STRATEGY"
                echo "  PROFILE_MIGRATION_RUN_TESTS, PROFILE_MIGRATION_BACKUP"
                echo "  PROFILE_MIGRATION_PARALLEL_JOBS, PROFILE_MIGRATION_TIMEOUT"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Non-interactive mode: using defaults and environment variables"
    fi

    print_banner

    # Step 0: Auto-discovery (optional — skip in non-interactive if vars already set)
    if [[ "$NON_INTERACTIVE" == "true" && -n "${PROFILE_DB_TYPE:-}" ]]; then
        log_info "Skipping auto-discovery (env vars already set)"
    else
        step_auto_discovery
    fi

    # Steps 1-8: Configuration
    step_database_type
    step_database_location
    step_deployment_mode
    step_distribution_mode
    step_cluster_mode
    step_migration_strategy
    step_versions
    step_additional_options

    # Generate profile name
    PROFILE_NAME="${PROFILE_NAME_OVERRIDE:-${PROFILE_KC_DEPLOYMENT_MODE}-${PROFILE_DB_TYPE}-${PROFILE_KC_CLUSTER_MODE}}"
    PROFILE_NAME=$(ask_text "Profile name" "$PROFILE_NAME")

    # Show summary
    show_summary

    echo ""
    if ask_yes_no "Save this profile?" "y"; then
        profile_save "$PROFILE_NAME"
        log_success "Profile saved to: $PROFILE_DIR/${PROFILE_NAME}.yaml"
    else
        log_warn "Profile not saved"
        exit 0
    fi

    echo ""
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Non-interactive mode: profile saved. Run migration with:"
        echo "  ./scripts/migrate_keycloak_v3.sh migrate --profile $PROFILE_NAME"
    elif ask_yes_no "Start migration now?" "n"; then
        log_info "Launching migration with profile: $PROFILE_NAME"
        exec "$SCRIPT_DIR/migrate_keycloak_v3.sh" migrate --profile "$PROFILE_NAME"
    else
        echo ""
        log_info "To run migration later, use:"
        echo ""
        echo "  ./scripts/migrate_keycloak_v3.sh migrate --profile $PROFILE_NAME"
        echo ""
    fi
}

# Run wizard
main "$@"
