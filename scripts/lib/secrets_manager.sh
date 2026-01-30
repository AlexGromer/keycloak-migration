#!/usr/bin/env bash
# Secrets Manager — Universal Interface (v3.6)
# Abstraction layer for HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, Kubernetes Secrets

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly SECRETS_MANAGER_VERSION="3.6.0"

# Supported backends
readonly BACKEND_VAULT="vault"
readonly BACKEND_AWS="aws"
readonly BACKEND_AZURE="azure"
readonly BACKEND_K8S="k8s"
readonly BACKEND_ENV="env"         # Environment variables (dev/testing only)
readonly BACKEND_FILE="file"       # File-based (dev/testing only)

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_BACKEND_NOT_CONFIGURED=30
readonly EXIT_SECRET_NOT_FOUND=31
readonly EXIT_BACKEND_ERROR=32
readonly EXIT_INVALID_BACKEND=33

# Default backend (override with SECRETS_BACKEND env var)
SECRETS_BACKEND="${SECRETS_BACKEND:-$BACKEND_ENV}"

# ============================================================================
# LOGGING
# ============================================================================

sm_log_info() {
    echo "[SM INFO] $1"
}

sm_log_warn() {
    echo "[⚠ SM WARNING] $1" >&2
}

sm_log_error() {
    echo "[✗ SM ERROR] $1" >&2
}

sm_log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG SM] $1" >&2
    fi
}

# ============================================================================
# BACKEND DETECTION & CONFIGURATION
# ============================================================================

# Detect available secrets backend
detect_secrets_backend() {
    sm_log_debug "Detecting secrets backend..."

    # Priority order: Vault > K8s > AWS > Azure > File > Env

    # 1. HashiCorp Vault
    if [[ -n "${VAULT_ADDR:-}" ]] && [[ -n "${VAULT_TOKEN:-}" ]]; then
        echo "$BACKEND_VAULT"
        return 0
    fi

    # 2. Kubernetes Secrets (check if running in pod)
    if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
        echo "$BACKEND_K8S"
        return 0
    fi

    # 3. AWS Secrets Manager
    if command -v aws >/dev/null 2>&1; then
        # Check if AWS credentials configured
        if aws sts get-caller-identity >/dev/null 2>&1; then
            echo "$BACKEND_AWS"
            return 0
        fi
    fi

    # 4. Azure Key Vault
    if command -v az >/dev/null 2>&1; then
        # Check if Azure CLI logged in
        if az account show >/dev/null 2>&1; then
            echo "$BACKEND_AZURE"
            return 0
        fi
    fi

    # 5. File-based (dev/testing)
    if [[ -n "${SECRETS_FILE:-}" ]] && [[ -f "${SECRETS_FILE}" ]]; then
        echo "$BACKEND_FILE"
        return 0
    fi

    # 6. Environment variables (fallback)
    echo "$BACKEND_ENV"
    return 0
}

# Get current secrets backend
get_secrets_backend() {
    echo "${SECRETS_BACKEND}"
}

# Set secrets backend
set_secrets_backend() {
    local backend="$1"

    case "$backend" in
        "$BACKEND_VAULT"|"$BACKEND_AWS"|"$BACKEND_AZURE"|"$BACKEND_K8S"|"$BACKEND_ENV"|"$BACKEND_FILE")
            SECRETS_BACKEND="$backend"
            sm_log_info "Secrets backend set to: $backend"
            ;;
        *)
            sm_log_error "Invalid backend: $backend"
            return $EXIT_INVALID_BACKEND
            ;;
    esac
}

# ============================================================================
# UNIVERSAL SECRETS INTERFACE
# ============================================================================

# Get secret value by key
# Usage: get_secret "db_password"
# Returns: secret value (stdout)
get_secret() {
    local secret_key="$1"
    local backend="${2:-$SECRETS_BACKEND}"

    sm_log_debug "Retrieving secret: $secret_key (backend: $backend)"

    case "$backend" in
        "$BACKEND_VAULT")
            get_secret_vault "$secret_key"
            ;;
        "$BACKEND_AWS")
            get_secret_aws "$secret_key"
            ;;
        "$BACKEND_AZURE")
            get_secret_azure "$secret_key"
            ;;
        "$BACKEND_K8S")
            get_secret_k8s "$secret_key"
            ;;
        "$BACKEND_ENV")
            get_secret_env "$secret_key"
            ;;
        "$BACKEND_FILE")
            get_secret_file "$secret_key"
            ;;
        *)
            sm_log_error "Unknown backend: $backend"
            return $EXIT_INVALID_BACKEND
            ;;
    esac
}

# Set secret value by key
# Usage: set_secret "db_password" "secret_value"
set_secret() {
    local secret_key="$1"
    local secret_value="$2"
    local backend="${3:-$SECRETS_BACKEND}"

    sm_log_debug "Storing secret: $secret_key (backend: $backend)"

    case "$backend" in
        "$BACKEND_VAULT")
            set_secret_vault "$secret_key" "$secret_value"
            ;;
        "$BACKEND_AWS")
            set_secret_aws "$secret_key" "$secret_value"
            ;;
        "$BACKEND_AZURE")
            set_secret_azure "$secret_key" "$secret_value"
            ;;
        "$BACKEND_K8S")
            sm_log_error "K8s secrets are read-only in this implementation"
            return $EXIT_BACKEND_ERROR
            ;;
        "$BACKEND_ENV")
            sm_log_error "Env backend is read-only"
            return $EXIT_BACKEND_ERROR
            ;;
        "$BACKEND_FILE")
            set_secret_file "$secret_key" "$secret_value"
            ;;
        *)
            sm_log_error "Unknown backend: $backend"
            return $EXIT_INVALID_BACKEND
            ;;
    esac
}

# Delete secret by key
delete_secret() {
    local secret_key="$1"
    local backend="${2:-$SECRETS_BACKEND}"

    sm_log_debug "Deleting secret: $secret_key (backend: $backend)"

    case "$backend" in
        "$BACKEND_VAULT")
            delete_secret_vault "$secret_key"
            ;;
        "$BACKEND_AWS")
            delete_secret_aws "$secret_key"
            ;;
        "$BACKEND_AZURE")
            delete_secret_azure "$secret_key"
            ;;
        "$BACKEND_FILE")
            delete_secret_file "$secret_key"
            ;;
        *)
            sm_log_error "Delete not supported for backend: $backend"
            return $EXIT_BACKEND_ERROR
            ;;
    esac
}

# List all secret keys
list_secrets() {
    local backend="${1:-$SECRETS_BACKEND}"

    sm_log_debug "Listing secrets (backend: $backend)"

    case "$backend" in
        "$BACKEND_VAULT")
            list_secrets_vault
            ;;
        "$BACKEND_AWS")
            list_secrets_aws
            ;;
        "$BACKEND_AZURE")
            list_secrets_azure
            ;;
        "$BACKEND_K8S")
            list_secrets_k8s
            ;;
        "$BACKEND_FILE")
            list_secrets_file
            ;;
        *)
            sm_log_error "List not supported for backend: $backend"
            return $EXIT_BACKEND_ERROR
            ;;
    esac
}

# ============================================================================
# ENVIRONMENT VARIABLES BACKEND (Dev/Testing)
# ============================================================================

get_secret_env() {
    local secret_key="$1"

    # Convert key to uppercase and replace - with _
    local env_var
    env_var=$(echo "$secret_key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    if [[ -z "${!env_var:-}" ]]; then
        sm_log_error "Secret not found in environment: $env_var"
        return $EXIT_SECRET_NOT_FOUND
    fi

    echo "${!env_var}"
}

# ============================================================================
# FILE-BASED BACKEND (Dev/Testing)
# ============================================================================

get_secret_file() {
    local secret_key="$1"
    local secrets_file="${SECRETS_FILE:-/etc/keycloak-migration/secrets}"

    if [[ ! -f "$secrets_file" ]]; then
        sm_log_error "Secrets file not found: $secrets_file"
        return $EXIT_BACKEND_NOT_CONFIGURED
    fi

    # File format: key=value (one per line)
    local value
    value=$(grep "^${secret_key}=" "$secrets_file" | cut -d= -f2-)

    if [[ -z "$value" ]]; then
        sm_log_error "Secret not found in file: $secret_key"
        return $EXIT_SECRET_NOT_FOUND
    fi

    echo "$value"
}

set_secret_file() {
    local secret_key="$1"
    local secret_value="$2"
    local secrets_file="${SECRETS_FILE:-/etc/keycloak-migration/secrets}"

    # Create directory if needed
    mkdir -p "$(dirname "$secrets_file")"

    # Update or append
    if grep -q "^${secret_key}=" "$secrets_file" 2>/dev/null; then
        # Update existing
        sed -i "s|^${secret_key}=.*|${secret_key}=${secret_value}|" "$secrets_file"
    else
        # Append new
        echo "${secret_key}=${secret_value}" >> "$secrets_file"
    fi

    # Set restrictive permissions
    chmod 600 "$secrets_file"

    sm_log_info "Secret stored in file: $secret_key"
}

delete_secret_file() {
    local secret_key="$1"
    local secrets_file="${SECRETS_FILE:-/etc/keycloak-migration/secrets}"

    if [[ ! -f "$secrets_file" ]]; then
        return 0  # Already deleted
    fi

    sed -i "/^${secret_key}=/d" "$secrets_file"
    sm_log_info "Secret deleted from file: $secret_key"
}

list_secrets_file() {
    local secrets_file="${SECRETS_FILE:-/etc/keycloak-migration/secrets}"

    if [[ ! -f "$secrets_file" ]]; then
        return 0
    fi

    # Extract keys only
    grep -E '^[^#]' "$secrets_file" | cut -d= -f1
}

# ============================================================================
# HASHICORP VAULT BACKEND
# ============================================================================

get_secret_vault() {
    local secret_key="$1"
    local vault_path="${VAULT_PATH:-secret/keycloak-migration}"

    if [[ -z "${VAULT_ADDR:-}" ]] || [[ -z "${VAULT_TOKEN:-}" ]]; then
        sm_log_error "Vault not configured (VAULT_ADDR and VAULT_TOKEN required)"
        return $EXIT_BACKEND_NOT_CONFIGURED
    fi

    # Source vault_integration.sh if available
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh"
        vault_read_secret "$vault_path" "$secret_key"
    else
        # Fallback: direct vault CLI call
        if ! command -v vault >/dev/null 2>&1; then
            sm_log_error "vault CLI not found"
            return $EXIT_BACKEND_ERROR
        fi

        local value
        value=$(vault kv get -field="$secret_key" "$vault_path" 2>/dev/null)

        if [[ -z "$value" ]]; then
            sm_log_error "Secret not found in Vault: $secret_key"
            return $EXIT_SECRET_NOT_FOUND
        fi

        echo "$value"
    fi
}

set_secret_vault() {
    local secret_key="$1"
    local secret_value="$2"
    local vault_path="${VAULT_PATH:-secret/keycloak-migration}"

    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh"
        vault_write_secret "$vault_path" "$secret_key" "$secret_value"
    else
        # Fallback: direct vault CLI call
        vault kv put "$vault_path" "$secret_key=$secret_value"
        sm_log_info "Secret stored in Vault: $secret_key"
    fi
}

delete_secret_vault() {
    local secret_key="$1"
    local vault_path="${VAULT_PATH:-secret/keycloak-migration}"

    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh"
        vault_delete_secret "$vault_path" "$secret_key"
    else
        vault kv delete "$vault_path/$secret_key"
        sm_log_info "Secret deleted from Vault: $secret_key"
    fi
}

list_secrets_vault() {
    local vault_path="${VAULT_PATH:-secret/keycloak-migration}"

    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vault_integration.sh"
        vault_list_secrets "$vault_path"
    else
        vault kv list "$vault_path" 2>/dev/null || echo ""
    fi
}

# ============================================================================
# KUBERNETES SECRETS BACKEND
# ============================================================================

get_secret_k8s() {
    local secret_key="$1"
    local secret_name="${K8S_SECRET_NAME:-keycloak-migration}"
    local namespace="${K8S_NAMESPACE:-default}"

    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/k8s_secrets.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/k8s_secrets.sh"
        k8s_read_secret "$secret_name" "$secret_key" "$namespace"
    else
        # Fallback: direct kubectl call
        if ! command -v kubectl >/dev/null 2>&1; then
            sm_log_error "kubectl not found"
            return $EXIT_BACKEND_ERROR
        fi

        local value
        value=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.${secret_key}}" 2>/dev/null | base64 -d)

        if [[ -z "$value" ]]; then
            sm_log_error "Secret not found in K8s: $secret_key"
            return $EXIT_SECRET_NOT_FOUND
        fi

        echo "$value"
    fi
}

list_secrets_k8s() {
    local secret_name="${K8S_SECRET_NAME:-keycloak-migration}"
    local namespace="${K8S_NAMESPACE:-default}"

    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/k8s_secrets.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/k8s_secrets.sh"
        k8s_list_secret_keys "$secret_name" "$namespace"
    else
        kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]'
    fi
}

# ============================================================================
# AWS SECRETS MANAGER BACKEND
# ============================================================================

get_secret_aws() {
    local secret_key="$1"
    local secret_name="${AWS_SECRET_NAME:-keycloak-migration}"

    if ! command -v aws >/dev/null 2>&1; then
        sm_log_error "AWS CLI not found"
        return $EXIT_BACKEND_ERROR
    fi

    local value
    value=$(aws secretsmanager get-secret-value --secret-id "$secret_name" --query "SecretString" --output text 2>/dev/null | jq -r ".${secret_key}")

    if [[ -z "$value" || "$value" == "null" ]]; then
        sm_log_error "Secret not found in AWS: $secret_key"
        return $EXIT_SECRET_NOT_FOUND
    fi

    echo "$value"
}

set_secret_aws() {
    local secret_key="$1"
    local secret_value="$2"
    local secret_name="${AWS_SECRET_NAME:-keycloak-migration}"

    # Get current secret JSON
    local current_json
    current_json=$(aws secretsmanager get-secret-value --secret-id "$secret_name" --query "SecretString" --output text 2>/dev/null || echo "{}")

    # Update JSON
    local updated_json
    updated_json=$(echo "$current_json" | jq --arg key "$secret_key" --arg value "$secret_value" '.[$key] = $value')

    # Update secret
    aws secretsmanager update-secret --secret-id "$secret_name" --secret-string "$updated_json"

    sm_log_info "Secret stored in AWS: $secret_key"
}

delete_secret_aws() {
    local secret_key="$1"
    local secret_name="${AWS_SECRET_NAME:-keycloak-migration}"

    # Get current secret JSON
    local current_json
    current_json=$(aws secretsmanager get-secret-value --secret-id "$secret_name" --query "SecretString" --output text 2>/dev/null || echo "{}")

    # Remove key from JSON
    local updated_json
    updated_json=$(echo "$current_json" | jq --arg key "$secret_key" 'del(.[$key])')

    # Update secret
    aws secretsmanager update-secret --secret-id "$secret_name" --secret-string "$updated_json"

    sm_log_info "Secret deleted from AWS: $secret_key"
}

list_secrets_aws() {
    local secret_name="${AWS_SECRET_NAME:-keycloak-migration}"

    aws secretsmanager get-secret-value --secret-id "$secret_name" --query "SecretString" --output text 2>/dev/null | jq -r 'keys[]'
}

# ============================================================================
# AZURE KEY VAULT BACKEND
# ============================================================================

get_secret_azure() {
    local secret_key="$1"
    local vault_name="${AZURE_VAULT_NAME}"

    if [[ -z "$vault_name" ]]; then
        sm_log_error "AZURE_VAULT_NAME not configured"
        return $EXIT_BACKEND_NOT_CONFIGURED
    fi

    if ! command -v az >/dev/null 2>&1; then
        sm_log_error "Azure CLI not found"
        return $EXIT_BACKEND_ERROR
    fi

    local value
    value=$(az keyvault secret show --vault-name "$vault_name" --name "$secret_key" --query "value" -o tsv 2>/dev/null)

    if [[ -z "$value" ]]; then
        sm_log_error "Secret not found in Azure: $secret_key"
        return $EXIT_SECRET_NOT_FOUND
    fi

    echo "$value"
}

set_secret_azure() {
    local secret_key="$1"
    local secret_value="$2"
    local vault_name="${AZURE_VAULT_NAME}"

    az keyvault secret set --vault-name "$vault_name" --name "$secret_key" --value "$secret_value" >/dev/null

    sm_log_info "Secret stored in Azure: $secret_key"
}

delete_secret_azure() {
    local secret_key="$1"
    local vault_name="${AZURE_VAULT_NAME}"

    az keyvault secret delete --vault-name "$vault_name" --name "$secret_key" >/dev/null

    sm_log_info "Secret deleted from Azure: $secret_key"
}

list_secrets_azure() {
    local vault_name="${AZURE_VAULT_NAME}"

    az keyvault secret list --vault-name "$vault_name" --query "[].name" -o tsv
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Load secrets into environment variables
# Usage: load_secrets_to_env "db_password" "keycloak_admin_password"
load_secrets_to_env() {
    local secret_keys=("$@")

    for key in "${secret_keys[@]}"; do
        local value
        if value=$(get_secret "$key"); then
            # Convert key to uppercase env var name
            local env_var
            env_var=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

            export "$env_var=$value"
            sm_log_info "Loaded secret to environment: $env_var"
        else
            sm_log_warn "Failed to load secret: $key"
        fi
    done
}

# Test secrets backend connectivity
test_secrets_backend() {
    local backend="${1:-$SECRETS_BACKEND}"

    sm_log_info "Testing secrets backend: $backend"

    case "$backend" in
        "$BACKEND_VAULT")
            if [[ -z "${VAULT_ADDR:-}" ]] || [[ -z "${VAULT_TOKEN:-}" ]]; then
                sm_log_error "Vault not configured"
                return 1
            fi
            if ! command -v vault >/dev/null 2>&1; then
                sm_log_error "vault CLI not found"
                return 1
            fi
            sm_log_info "Vault: OK"
            ;;
        "$BACKEND_AWS")
            if ! command -v aws >/dev/null 2>&1; then
                sm_log_error "AWS CLI not found"
                return 1
            fi
            if ! aws sts get-caller-identity >/dev/null 2>&1; then
                sm_log_error "AWS credentials not configured"
                return 1
            fi
            sm_log_info "AWS: OK"
            ;;
        "$BACKEND_AZURE")
            if ! command -v az >/dev/null 2>&1; then
                sm_log_error "Azure CLI not found"
                return 1
            fi
            if ! az account show >/dev/null 2>&1; then
                sm_log_error "Azure not logged in"
                return 1
            fi
            sm_log_info "Azure: OK"
            ;;
        "$BACKEND_K8S")
            if ! command -v kubectl >/dev/null 2>&1; then
                sm_log_error "kubectl not found"
                return 1
            fi
            sm_log_info "Kubernetes: OK"
            ;;
        "$BACKEND_ENV")
            sm_log_info "Environment: OK (always available)"
            ;;
        "$BACKEND_FILE")
            if [[ -z "${SECRETS_FILE:-}" ]]; then
                sm_log_warn "SECRETS_FILE not set (will use default)"
            fi
            sm_log_info "File: OK"
            ;;
    esac

    return 0
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f detect_secrets_backend
export -f get_secrets_backend
export -f set_secrets_backend

export -f get_secret
export -f set_secret
export -f delete_secret
export -f list_secrets

export -f load_secrets_to_env
export -f test_secrets_backend

export -f sm_log_info
export -f sm_log_warn
export -f sm_log_error
export -f sm_log_debug
