#!/usr/bin/env bash
# Kubernetes Secrets Integration (v3.6)
# Read secrets from Kubernetes cluster (in-cluster or external)

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly K8S_SECRETS_VERSION="3.6.0"

# Kubernetes configuration
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
K8S_CONTEXT="${K8S_CONTEXT:-}"  # Empty = current context
K8S_IN_CLUSTER="${K8S_IN_CLUSTER:-auto}"  # auto, true, false

# ServiceAccount paths (in-cluster)
readonly K8S_SA_TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
readonly K8S_SA_CA_PATH="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
readonly K8S_SA_NAMESPACE_PATH="/var/run/secrets/kubernetes.io/serviceaccount/namespace"

# Kubernetes API
K8S_API_SERVER="${K8S_API_SERVER:-https://kubernetes.default.svc}"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_K8S_NOT_CONFIGURED=50
readonly EXIT_K8S_SECRET_NOT_FOUND=51
readonly EXIT_K8S_API_ERROR=52

# ============================================================================
# LOGGING
# ============================================================================

k8s_log_info() {
    echo "[K8S INFO] $1"
}

k8s_log_warn() {
    echo "[⚠ K8S WARNING] $1" >&2
}

k8s_log_error() {
    echo "[✗ K8S ERROR] $1" >&2
}

k8s_log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG K8S] $1" >&2
    fi
}

# ============================================================================
# ENVIRONMENT DETECTION
# ============================================================================

# Detect if running inside Kubernetes pod
is_running_in_cluster() {
    [[ -f "$K8S_SA_TOKEN_PATH" ]] && [[ -f "$K8S_SA_CA_PATH" ]]
}

# Detect kubectl availability
check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        k8s_log_error "kubectl not found - install from https://kubernetes.io/docs/tasks/tools/"
        return 1
    fi

    local version
    version=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null)
    k8s_log_debug "kubectl: $version"
    return 0
}

# Auto-detect cluster access method
detect_cluster_access() {
    if [[ "$K8S_IN_CLUSTER" == "true" ]] || { [[ "$K8S_IN_CLUSTER" == "auto" ]] && is_running_in_cluster; }; then
        echo "in-cluster"
    else
        echo "kubectl"
    fi
}

# ============================================================================
# KUBECTL-BASED ACCESS
# ============================================================================

# Read secret value using kubectl
k8s_kubectl_read_secret() {
    local secret_name="$1"
    local key="$2"
    local namespace="${3:-$K8S_NAMESPACE}"
    local context_arg=""

    if [[ -n "$K8S_CONTEXT" ]]; then
        context_arg="--context=$K8S_CONTEXT"
    fi

    k8s_log_debug "Reading secret via kubectl: $namespace/$secret_name/$key"

    # Get secret data
    local value
    if ! value=$(kubectl get secret "$secret_name" \
        -n "$namespace" \
        $context_arg \
        -o jsonpath="{.data.${key}}" 2>&1); then
        k8s_log_error "Failed to read secret: $value"
        return $EXIT_K8S_SECRET_NOT_FOUND
    fi

    if [[ -z "$value" ]]; then
        k8s_log_error "Secret key not found: $namespace/$secret_name/$key"
        return $EXIT_K8S_SECRET_NOT_FOUND
    fi

    # Decode base64
    echo "$value" | base64 -d
}

# List all keys in secret using kubectl
k8s_kubectl_list_keys() {
    local secret_name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"
    local context_arg=""

    if [[ -n "$K8S_CONTEXT" ]]; then
        context_arg="--context=$K8S_CONTEXT"
    fi

    k8s_log_debug "Listing secret keys via kubectl: $namespace/$secret_name"

    kubectl get secret "$secret_name" \
        -n "$namespace" \
        $context_arg \
        -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]'
}

# Get entire secret as JSON using kubectl
k8s_kubectl_get_secret_json() {
    local secret_name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"
    local context_arg=""

    if [[ -n "$K8S_CONTEXT" ]]; then
        context_arg="--context=$K8S_CONTEXT"
    fi

    k8s_log_debug "Getting secret JSON via kubectl: $namespace/$secret_name"

    local data
    data=$(kubectl get secret "$secret_name" \
        -n "$namespace" \
        $context_arg \
        -o jsonpath='{.data}' 2>/dev/null)

    # Decode all base64 values
    echo "$data" | jq -r 'to_entries | map({key: .key, value: (.value | @base64d)}) | from_entries'
}

# List all secrets in namespace using kubectl
k8s_kubectl_list_secrets() {
    local namespace="${1:-$K8S_NAMESPACE}"
    local context_arg=""

    if [[ -n "$K8S_CONTEXT" ]]; then
        context_arg="--context=$K8S_CONTEXT"
    fi

    kubectl get secrets -n "$namespace" $context_arg -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n'
}

# ============================================================================
# IN-CLUSTER API ACCESS (ServiceAccount)
# ============================================================================

# Read ServiceAccount token
k8s_get_sa_token() {
    if [[ ! -f "$K8S_SA_TOKEN_PATH" ]]; then
        k8s_log_error "ServiceAccount token not found: $K8S_SA_TOKEN_PATH"
        return 1
    fi

    cat "$K8S_SA_TOKEN_PATH"
}

# Get current namespace from ServiceAccount
k8s_get_sa_namespace() {
    if [[ -f "$K8S_SA_NAMESPACE_PATH" ]]; then
        cat "$K8S_SA_NAMESPACE_PATH"
    else
        echo "default"
    fi
}

# Call Kubernetes API directly using ServiceAccount
k8s_api_call() {
    local method="$1"      # GET, POST, PUT, DELETE
    local api_path="$2"    # e.g., /api/v1/namespaces/default/secrets/my-secret
    local data="${3:-}"    # JSON data for POST/PUT

    local token
    token=$(k8s_get_sa_token)

    local curl_args=(
        -X "$method"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        --cacert "$K8S_SA_CA_PATH"
        -s
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local url="${K8S_API_SERVER}${api_path}"

    k8s_log_debug "API call: $method $url"

    local response
    if ! response=$(curl "${curl_args[@]}" "$url" 2>&1); then
        k8s_log_error "API call failed: $response"
        return $EXIT_K8S_API_ERROR
    fi

    # Check for API errors
    local kind
    kind=$(echo "$response" | jq -r '.kind' 2>/dev/null || echo "")

    if [[ "$kind" == "Status" ]]; then
        local status reason message
        status=$(echo "$response" | jq -r '.status')
        reason=$(echo "$response" | jq -r '.reason')
        message=$(echo "$response" | jq -r '.message')

        if [[ "$status" != "Success" ]]; then
            k8s_log_error "API error: $reason - $message"
            return $EXIT_K8S_API_ERROR
        fi
    fi

    echo "$response"
}

# Read secret value using Kubernetes API
k8s_api_read_secret() {
    local secret_name="$1"
    local key="$2"
    local namespace="${3:-$(k8s_get_sa_namespace)}"

    k8s_log_debug "Reading secret via API: $namespace/$secret_name/$key"

    local api_path="/api/v1/namespaces/${namespace}/secrets/${secret_name}"

    local response
    if ! response=$(k8s_api_call "GET" "$api_path"); then
        return $EXIT_K8S_SECRET_NOT_FOUND
    fi

    # Extract and decode value
    local value
    value=$(echo "$response" | jq -r ".data.${key}")

    if [[ -z "$value" || "$value" == "null" ]]; then
        k8s_log_error "Secret key not found: $namespace/$secret_name/$key"
        return $EXIT_K8S_SECRET_NOT_FOUND
    fi

    echo "$value" | base64 -d
}

# List all keys in secret using API
k8s_api_list_keys() {
    local secret_name="$1"
    local namespace="${2:-$(k8s_get_sa_namespace)}"

    k8s_log_debug "Listing secret keys via API: $namespace/$secret_name"

    local api_path="/api/v1/namespaces/${namespace}/secrets/${secret_name}"

    local response
    if ! response=$(k8s_api_call "GET" "$api_path"); then
        return $EXIT_K8S_SECRET_NOT_FOUND
    fi

    echo "$response" | jq -r '.data | keys[]'
}

# Get entire secret as JSON using API
k8s_api_get_secret_json() {
    local secret_name="$1"
    local namespace="${2:-$(k8s_get_sa_namespace)}"

    k8s_log_debug "Getting secret JSON via API: $namespace/$secret_name"

    local api_path="/api/v1/namespaces/${namespace}/secrets/${secret_name}"

    local response
    if ! response=$(k8s_api_call "GET" "$api_path"); then
        return $EXIT_K8S_SECRET_NOT_FOUND
    fi

    local data
    data=$(echo "$response" | jq -r '.data')

    # Decode all base64 values
    echo "$data" | jq -r 'to_entries | map({key: .key, value: (.value | @base64d)}) | from_entries'
}

# List all secrets in namespace using API
k8s_api_list_secrets() {
    local namespace="${1:-$(k8s_get_sa_namespace)}"

    k8s_log_debug "Listing secrets via API: $namespace"

    local api_path="/api/v1/namespaces/${namespace}/secrets"

    local response
    if ! response=$(k8s_api_call "GET" "$api_path"); then
        return $EXIT_K8S_API_ERROR
    fi

    echo "$response" | jq -r '.items[].metadata.name'
}

# ============================================================================
# UNIFIED INTERFACE (AUTO-DETECT METHOD)
# ============================================================================

# Read secret value (auto-detect access method)
k8s_read_secret() {
    local secret_name="$1"
    local key="$2"
    local namespace="${3:-$K8S_NAMESPACE}"

    local access_method
    access_method=$(detect_cluster_access)

    k8s_log_debug "Access method: $access_method"

    case "$access_method" in
        "in-cluster")
            k8s_api_read_secret "$secret_name" "$key" "$namespace"
            ;;
        "kubectl")
            if ! check_kubectl; then
                return $EXIT_K8S_NOT_CONFIGURED
            fi
            k8s_kubectl_read_secret "$secret_name" "$key" "$namespace"
            ;;
        *)
            k8s_log_error "Unknown access method: $access_method"
            return $EXIT_K8S_NOT_CONFIGURED
            ;;
    esac
}

# List secret keys (auto-detect access method)
k8s_list_secret_keys() {
    local secret_name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"

    local access_method
    access_method=$(detect_cluster_access)

    case "$access_method" in
        "in-cluster")
            k8s_api_list_keys "$secret_name" "$namespace"
            ;;
        "kubectl")
            if ! check_kubectl; then
                return $EXIT_K8S_NOT_CONFIGURED
            fi
            k8s_kubectl_list_keys "$secret_name" "$namespace"
            ;;
    esac
}

# Get secret as JSON (auto-detect access method)
k8s_get_secret_json() {
    local secret_name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"

    local access_method
    access_method=$(detect_cluster_access)

    case "$access_method" in
        "in-cluster")
            k8s_api_get_secret_json "$secret_name" "$namespace"
            ;;
        "kubectl")
            if ! check_kubectl; then
                return $EXIT_K8S_NOT_CONFIGURED
            fi
            k8s_kubectl_get_secret_json "$secret_name" "$namespace"
            ;;
    esac
}

# List all secrets (auto-detect access method)
k8s_list_secrets() {
    local namespace="${1:-$K8S_NAMESPACE}"

    local access_method
    access_method=$(detect_cluster_access)

    case "$access_method" in
        "in-cluster")
            k8s_api_list_secrets "$namespace"
            ;;
        "kubectl")
            if ! check_kubectl; then
                return $EXIT_K8S_NOT_CONFIGURED
            fi
            k8s_kubectl_list_secrets "$namespace"
            ;;
    esac
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Load secret to environment variable
k8s_load_to_env() {
    local secret_name="$1"
    local key="$2"
    local env_var="${3:-}"
    local namespace="${4:-$K8S_NAMESPACE}"

    # If env_var not specified, use key name in uppercase
    if [[ -z "$env_var" ]]; then
        env_var=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    fi

    local value
    if ! value=$(k8s_read_secret "$secret_name" "$key" "$namespace"); then
        k8s_log_error "Failed to load $namespace/$secret_name/$key to $env_var"
        return 1
    fi

    export "$env_var=$value"
    k8s_log_info "Loaded $namespace/$secret_name/$key → $env_var"
}

# Load all keys from secret to environment
k8s_load_secret_to_env() {
    local secret_name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"
    local prefix="${3:-}"  # Optional env var prefix

    k8s_log_info "Loading all keys from $namespace/$secret_name to environment"

    local keys
    if ! keys=$(k8s_list_secret_keys "$secret_name" "$namespace"); then
        k8s_log_error "Failed to list keys in secret: $secret_name"
        return 1
    fi

    while IFS= read -r key; do
        if [[ -z "$key" ]]; then
            continue
        fi

        local env_var
        env_var="${prefix}$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

        k8s_load_to_env "$secret_name" "$key" "$env_var" "$namespace" || true
    done <<< "$keys"
}

# Check if secret exists
k8s_secret_exists() {
    local secret_name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"

    k8s_read_secret "$secret_name" "dummy-key" "$namespace" >/dev/null 2>&1
    local exit_code=$?

    # If error is "key not found", secret exists
    # If error is "secret not found", secret doesn't exist
    [[ $exit_code -eq 0 ]] || [[ $exit_code -eq $EXIT_K8S_SECRET_NOT_FOUND ]]
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f is_running_in_cluster
export -f check_kubectl
export -f detect_cluster_access

export -f k8s_read_secret
export -f k8s_list_secret_keys
export -f k8s_get_secret_json
export -f k8s_list_secrets

export -f k8s_load_to_env
export -f k8s_load_secret_to_env
export -f k8s_secret_exists

export -f k8s_log_info
export -f k8s_log_warn
export -f k8s_log_error
export -f k8s_log_debug
