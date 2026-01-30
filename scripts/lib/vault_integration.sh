#!/usr/bin/env bash
# HashiCorp Vault Integration (v3.6)
# Production-grade Vault client with token renewal, KV v2 support, approle auth

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly VAULT_INTEGRATION_VERSION="3.6.0"

# Vault configuration (override with environment variables)
VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
VAULT_ROLE_ID="${VAULT_ROLE_ID:-}"
VAULT_SECRET_ID="${VAULT_SECRET_ID:-}"

# KV engine settings
VAULT_KV_VERSION="${VAULT_KV_VERSION:-2}"  # KV v1 or v2
VAULT_MOUNT_PATH="${VAULT_MOUNT_PATH:-secret}"

# Token renewal
VAULT_TOKEN_RENEW_THRESHOLD="${VAULT_TOKEN_RENEW_THRESHOLD:-300}"  # Renew if TTL < 5 min

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_VAULT_NOT_CONFIGURED=40
readonly EXIT_VAULT_AUTH_FAILED=41
readonly EXIT_VAULT_READ_FAILED=42
readonly EXIT_VAULT_WRITE_FAILED=43

# ============================================================================
# LOGGING
# ============================================================================

vault_log_info() {
    echo "[VAULT INFO] $1"
}

vault_log_warn() {
    echo "[⚠ VAULT WARNING] $1" >&2
}

vault_log_error() {
    echo "[✗ VAULT ERROR] $1" >&2
}

vault_log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG VAULT] $1" >&2
    fi
}

# ============================================================================
# VAULT CLIENT CHECKS
# ============================================================================

# Check if vault CLI is available
check_vault_cli() {
    if ! command -v vault >/dev/null 2>&1; then
        vault_log_error "vault CLI not found - install from https://www.vaultproject.io/downloads"
        return 1
    fi

    local version
    version=$(vault version | head -1)
    vault_log_debug "Vault CLI: $version"
    return 0
}

# Check Vault configuration
check_vault_config() {
    if [[ -z "$VAULT_ADDR" ]]; then
        vault_log_error "VAULT_ADDR not set"
        return $EXIT_VAULT_NOT_CONFIGURED
    fi

    if [[ -z "$VAULT_TOKEN" ]] && [[ -z "$VAULT_ROLE_ID" ]]; then
        vault_log_error "Neither VAULT_TOKEN nor VAULT_ROLE_ID set"
        return $EXIT_VAULT_NOT_CONFIGURED
    fi

    vault_log_debug "Vault configured: $VAULT_ADDR"
    return 0
}

# ============================================================================
# AUTHENTICATION
# ============================================================================

# Login with AppRole (role_id + secret_id)
vault_login_approle() {
    local role_id="${1:-$VAULT_ROLE_ID}"
    local secret_id="${2:-$VAULT_SECRET_ID}"

    if [[ -z "$role_id" ]] || [[ -z "$secret_id" ]]; then
        vault_log_error "AppRole credentials not provided"
        return $EXIT_VAULT_AUTH_FAILED
    fi

    vault_log_info "Authenticating with AppRole..."

    local response
    if ! response=$(vault write -format=json auth/approle/login \
        role_id="$role_id" \
        secret_id="$secret_id" 2>&1); then
        vault_log_error "AppRole login failed: $response"
        return $EXIT_VAULT_AUTH_FAILED
    fi

    # Extract token
    VAULT_TOKEN=$(echo "$response" | jq -r '.auth.client_token')

    if [[ -z "$VAULT_TOKEN" || "$VAULT_TOKEN" == "null" ]]; then
        vault_log_error "Failed to extract token from AppRole response"
        return $EXIT_VAULT_AUTH_FAILED
    fi

    export VAULT_TOKEN
    vault_log_info "AppRole login successful"
    return 0
}

# Renew token if TTL is low
vault_renew_token() {
    local threshold="${1:-$VAULT_TOKEN_RENEW_THRESHOLD}"

    if [[ -z "$VAULT_TOKEN" ]]; then
        vault_log_warn "No token to renew"
        return 0
    fi

    # Get token info
    local token_info
    if ! token_info=$(vault token lookup -format=json 2>&1); then
        vault_log_warn "Failed to lookup token: $token_info"
        return 0
    fi

    # Extract TTL
    local ttl
    ttl=$(echo "$token_info" | jq -r '.data.ttl')

    if [[ "$ttl" == "null" ]] || [[ "$ttl" == "0" ]]; then
        vault_log_debug "Token has no TTL (root token or renewable)"
        return 0
    fi

    vault_log_debug "Token TTL: ${ttl}s (threshold: ${threshold}s)"

    # Renew if below threshold
    if (( ttl < threshold )); then
        vault_log_info "Renewing token (TTL: ${ttl}s)"

        if ! vault token renew >/dev/null 2>&1; then
            vault_log_warn "Token renewal failed - may need re-authentication"
            return 1
        fi

        vault_log_info "Token renewed successfully"
    fi

    return 0
}

# ============================================================================
# KV OPERATIONS
# ============================================================================

# Build KV path based on version
build_kv_path() {
    local path="$1"

    if [[ "$VAULT_KV_VERSION" == "2" ]]; then
        # KV v2: mount/data/path
        echo "${VAULT_MOUNT_PATH}/data/${path}"
    else
        # KV v1: mount/path
        echo "${VAULT_MOUNT_PATH}/${path}"
    fi
}

# Build metadata path (KV v2 only)
build_kv_metadata_path() {
    local path="$1"
    echo "${VAULT_MOUNT_PATH}/metadata/${path}"
}

# Read secret from Vault KV
vault_read_secret() {
    local path="$1"
    local field="${2:-}"

    if ! check_vault_cli || ! check_vault_config; then
        return $EXIT_VAULT_NOT_CONFIGURED
    fi

    # Renew token if needed
    vault_renew_token >/dev/null 2>&1 || true

    local kv_path
    kv_path=$(build_kv_path "$path")

    vault_log_debug "Reading secret: $kv_path (field: ${field:-all})"

    local response
    if ! response=$(vault kv get -format=json "$path" 2>&1); then
        vault_log_error "Failed to read secret: $response"
        return $EXIT_VAULT_READ_FAILED
    fi

    # Extract data (KV v2 has .data.data, KV v1 has .data)
    local data
    if [[ "$VAULT_KV_VERSION" == "2" ]]; then
        data=$(echo "$response" | jq -r '.data.data')
    else
        data=$(echo "$response" | jq -r '.data')
    fi

    if [[ "$data" == "null" ]]; then
        vault_log_error "Secret not found: $path"
        return $EXIT_VAULT_READ_FAILED
    fi

    # Return specific field or entire secret
    if [[ -n "$field" ]]; then
        local value
        value=$(echo "$data" | jq -r ".${field}")

        if [[ "$value" == "null" ]]; then
            vault_log_error "Field not found: $field"
            return $EXIT_VAULT_READ_FAILED
        fi

        echo "$value"
    else
        echo "$data"
    fi
}

# Write secret to Vault KV
vault_write_secret() {
    local path="$1"
    shift
    local key_values=("$@")  # Format: key1=value1 key2=value2

    if ! check_vault_cli || ! check_vault_config; then
        return $EXIT_VAULT_NOT_CONFIGURED
    fi

    vault_renew_token >/dev/null 2>&1 || true

    vault_log_debug "Writing secret: $path"

    # Write to KV
    if ! vault kv put "$path" "${key_values[@]}" >/dev/null 2>&1; then
        vault_log_error "Failed to write secret: $path"
        return $EXIT_VAULT_WRITE_FAILED
    fi

    vault_log_info "Secret written successfully: $path"
    return 0
}

# Update specific field in secret (KV v2 only)
vault_patch_secret() {
    local path="$1"
    local field="$2"
    local value="$3"

    if [[ "$VAULT_KV_VERSION" != "2" ]]; then
        vault_log_error "Patch only supported in KV v2"
        return 1
    fi

    vault_log_debug "Patching secret: $path.$field"

    # Use KV v2 patch
    if ! vault kv patch "$path" "${field}=${value}" >/dev/null 2>&1; then
        vault_log_error "Failed to patch secret: $path"
        return $EXIT_VAULT_WRITE_FAILED
    fi

    vault_log_info "Secret patched successfully: $path.$field"
    return 0
}

# Delete secret from Vault KV
vault_delete_secret() {
    local path="$1"
    local permanent="${2:-false}"  # true = destroy all versions (KV v2)

    if ! check_vault_cli || ! check_vault_config; then
        return $EXIT_VAULT_NOT_CONFIGURED
    fi

    vault_renew_token >/dev/null 2>&1 || true

    vault_log_debug "Deleting secret: $path (permanent: $permanent)"

    if [[ "$permanent" == "true" ]] && [[ "$VAULT_KV_VERSION" == "2" ]]; then
        # KV v2: Destroy all versions
        local metadata_path
        metadata_path=$(build_kv_metadata_path "$path")

        if ! vault delete "$metadata_path" >/dev/null 2>&1; then
            vault_log_error "Failed to destroy secret: $path"
            return $EXIT_VAULT_WRITE_FAILED
        fi

        vault_log_info "Secret destroyed (all versions): $path"
    else
        # KV v1 or soft delete (KV v2)
        if ! vault kv delete "$path" >/dev/null 2>&1; then
            vault_log_error "Failed to delete secret: $path"
            return $EXIT_VAULT_WRITE_FAILED
        fi

        vault_log_info "Secret deleted: $path"
    fi

    return 0
}

# List secrets in path
vault_list_secrets() {
    local path="${1:-}"

    if ! check_vault_cli || ! check_vault_config; then
        return $EXIT_VAULT_NOT_CONFIGURED
    fi

    vault_renew_token >/dev/null 2>&1 || true

    vault_log_debug "Listing secrets: $path"

    # Build list path (KV v2 uses /metadata/)
    local list_path="$path"
    if [[ "$VAULT_KV_VERSION" == "2" ]] && [[ -n "$path" ]]; then
        list_path="${VAULT_MOUNT_PATH}/metadata/${path}"
    elif [[ "$VAULT_KV_VERSION" == "2" ]]; then
        list_path="${VAULT_MOUNT_PATH}/metadata"
    fi

    local response
    if ! response=$(vault list -format=json "$list_path" 2>&1); then
        vault_log_warn "Failed to list secrets: $response"
        return 0  # Return empty list
    fi

    # Extract keys
    echo "$response" | jq -r '.[]'
}

# ============================================================================
# VERSIONING (KV v2 only)
# ============================================================================

# Get secret version history
vault_get_secret_versions() {
    local path="$1"

    if [[ "$VAULT_KV_VERSION" != "2" ]]; then
        vault_log_error "Versioning only available in KV v2"
        return 1
    fi

    local metadata_path
    metadata_path=$(build_kv_metadata_path "$path")

    vault read -format=json "$metadata_path" | jq -r '.data.versions'
}

# Restore previous version
vault_restore_secret_version() {
    local path="$1"
    local version="$2"

    if [[ "$VAULT_KV_VERSION" != "2" ]]; then
        vault_log_error "Versioning only available in KV v2"
        return 1
    fi

    vault_log_info "Restoring secret to version $version: $path"

    vault kv rollback -version="$version" "$path"
}

# ============================================================================
# DYNAMIC SECRETS
# ============================================================================

# Generate dynamic database credentials
vault_generate_db_creds() {
    local db_role="$1"
    local db_mount="${2:-database}"

    vault_log_info "Generating dynamic DB credentials for role: $db_role"

    local response
    if ! response=$(vault read -format=json "${db_mount}/creds/${db_role}" 2>&1); then
        vault_log_error "Failed to generate DB credentials: $response"
        return 1
    fi

    # Extract username and password
    local username password lease_id
    username=$(echo "$response" | jq -r '.data.username')
    password=$(echo "$response" | jq -r '.data.password')
    lease_id=$(echo "$response" | jq -r '.lease_id')

    vault_log_info "Generated credentials: user=$username, lease=$lease_id"

    # Return as JSON
    jq -n \
        --arg username "$username" \
        --arg password "$password" \
        --arg lease_id "$lease_id" \
        '{username: $username, password: $password, lease_id: $lease_id}'
}

# Revoke dynamic secret lease
vault_revoke_lease() {
    local lease_id="$1"

    vault_log_info "Revoking lease: $lease_id"

    if ! vault lease revoke "$lease_id" >/dev/null 2>&1; then
        vault_log_error "Failed to revoke lease: $lease_id"
        return 1
    fi

    vault_log_info "Lease revoked successfully"
    return 0
}

# ============================================================================
# ENCRYPTION AS A SERVICE
# ============================================================================

# Encrypt plaintext using Vault Transit engine
vault_encrypt() {
    local plaintext="$1"
    local key_name="${2:-keycloak-migration}"
    local transit_mount="${3:-transit}"

    vault_log_debug "Encrypting data with key: $key_name"

    local response
    if ! response=$(vault write -format=json \
        "${transit_mount}/encrypt/${key_name}" \
        plaintext="$(echo -n "$plaintext" | base64)" 2>&1); then
        vault_log_error "Encryption failed: $response"
        return 1
    fi

    # Extract ciphertext
    echo "$response" | jq -r '.data.ciphertext'
}

# Decrypt ciphertext using Vault Transit engine
vault_decrypt() {
    local ciphertext="$1"
    local key_name="${2:-keycloak-migration}"
    local transit_mount="${3:-transit}"

    vault_log_debug "Decrypting data with key: $key_name"

    local response
    if ! response=$(vault write -format=json \
        "${transit_mount}/decrypt/${key_name}" \
        ciphertext="$ciphertext" 2>&1); then
        vault_log_error "Decryption failed: $response"
        return 1
    fi

    # Extract and decode plaintext
    echo "$response" | jq -r '.data.plaintext' | base64 -d
}

# ============================================================================
# HEALTH CHECKS
# ============================================================================

# Check Vault server health
vault_health_check() {
    vault_log_info "Checking Vault health..."

    local health
    if ! health=$(vault status -format=json 2>&1); then
        vault_log_error "Vault health check failed: $health"
        return 1
    fi

    local sealed initialized
    sealed=$(echo "$health" | jq -r '.sealed')
    initialized=$(echo "$health" | jq -r '.initialized')

    if [[ "$sealed" == "true" ]]; then
        vault_log_error "Vault is SEALED"
        return 1
    fi

    if [[ "$initialized" != "true" ]]; then
        vault_log_error "Vault is NOT initialized"
        return 1
    fi

    vault_log_info "Vault health: OK (unsealed, initialized)"
    return 0
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Read secret and load to environment variable
vault_load_to_env() {
    local path="$1"
    local field="$2"
    local env_var="${3:-}"

    # If env_var not specified, use field name in uppercase
    if [[ -z "$env_var" ]]; then
        env_var=$(echo "$field" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    fi

    local value
    if ! value=$(vault_read_secret "$path" "$field"); then
        vault_log_error "Failed to load $path.$field to $env_var"
        return 1
    fi

    export "$env_var=$value"
    vault_log_info "Loaded $path.$field → $env_var"
}

# Batch read multiple secrets
vault_read_secrets_batch() {
    local path="$1"
    shift
    local fields=("$@")

    local result="{}"

    for field in "${fields[@]}"; do
        local value
        if value=$(vault_read_secret "$path" "$field"); then
            result=$(echo "$result" | jq --arg key "$field" --arg value "$value" '.[$key] = $value')
        fi
    done

    echo "$result"
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f check_vault_cli
export -f check_vault_config

export -f vault_login_approle
export -f vault_renew_token

export -f vault_read_secret
export -f vault_write_secret
export -f vault_patch_secret
export -f vault_delete_secret
export -f vault_list_secrets

export -f vault_get_secret_versions
export -f vault_restore_secret_version

export -f vault_generate_db_creds
export -f vault_revoke_lease

export -f vault_encrypt
export -f vault_decrypt

export -f vault_health_check
export -f vault_load_to_env
export -f vault_read_secrets_batch

export -f vault_log_info
export -f vault_log_warn
export -f vault_log_error
export -f vault_log_debug
