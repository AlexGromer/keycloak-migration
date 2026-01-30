#!/usr/bin/env bash
# Audit Logger v2 — Enhanced with HMAC Signatures (v3.6)
# Tamper-proof structured logging with cryptographic signatures

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly AUDIT_LOGGER_VERSION="3.6.0"

# Log levels
readonly LEVEL_TRACE=0
readonly LEVEL_DEBUG=1
readonly LEVEL_INFO=2
readonly LEVEL_WARN=3
readonly LEVEL_ERROR=4
readonly LEVEL_CRITICAL=5

# HMAC settings
HMAC_ALGORITHM="${HMAC_ALGORITHM:-sha256}"  # sha256, sha512
HMAC_SECRET_KEY="${HMAC_SECRET_KEY:-}"

# Default log file
AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-/var/log/keycloak-migration/audit.log}"

# Structured logging format
AUDIT_LOG_FORMAT="${AUDIT_LOG_FORMAT:-json}"  # json, logfmt, plain

# Minimum log level (logs below this are discarded)
AUDIT_MIN_LEVEL="${AUDIT_MIN_LEVEL:-$LEVEL_INFO}"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_HMAC_VERIFICATION_FAILED=60
readonly EXIT_LOG_WRITE_FAILED=61

# ============================================================================
# LOGGING
# ============================================================================

audit_log_internal() {
    local level="$1"
    local message="$2"

    echo "[AUDIT $level] $message" >&2
}

# ============================================================================
# HMAC SIGNATURE GENERATION
# ============================================================================

# Generate HMAC signature for log entry
generate_hmac() {
    local payload="$1"
    local secret="${2:-$HMAC_SECRET_KEY}"
    local algorithm="${3:-$HMAC_ALGORITHM}"

    if [[ -z "$secret" ]]; then
        # No HMAC secret configured - return empty signature
        echo ""
        return 0
    fi

    # Generate HMAC using openssl
    echo -n "$payload" | openssl dgst "-${algorithm}" -hmac "$secret" | awk '{print $2}'
}

# Verify HMAC signature for log entry
verify_hmac() {
    local payload="$1"
    local signature="$2"
    local secret="${3:-$HMAC_SECRET_KEY}"
    local algorithm="${4:-$HMAC_ALGORITHM}"

    if [[ -z "$secret" ]]; then
        audit_log_internal "WARN" "HMAC verification skipped (no secret)"
        return 0
    fi

    local expected_signature
    expected_signature=$(generate_hmac "$payload" "$secret" "$algorithm")

    if [[ "$signature" == "$expected_signature" ]]; then
        return 0
    else
        audit_log_internal "ERROR" "HMAC verification FAILED"
        return $EXIT_HMAC_VERIFICATION_FAILED
    fi
}

# ============================================================================
# STRUCTURED LOG ENTRY CREATION
# ============================================================================

# Create structured log entry
create_log_entry() {
    local level="$1"
    local message="$2"
    local component="${3:-migration}"
    local action="${4:-}"
    local user="${5:-${USER:-unknown}}"
    local metadata="${6:-{}}"

    # Timestamp (ISO 8601 with milliseconds)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Build base payload (without signature)
    local payload
    payload=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg level "$level" \
        --arg message "$message" \
        --arg component "$component" \
        --arg action "$action" \
        --arg user "$user" \
        --argjson metadata "$metadata" \
        '{
            timestamp: $timestamp,
            level: $level,
            message: $message,
            component: $component,
            action: $action,
            user: $user,
            metadata: $metadata,
            version: "v3.6"
        }')

    # Generate HMAC signature (if secret configured)
    local signature=""
    if [[ -n "$HMAC_SECRET_KEY" ]]; then
        signature=$(generate_hmac "$payload" "$HMAC_SECRET_KEY" "$HMAC_ALGORITHM")
    fi

    # Add signature to payload
    local final_entry
    final_entry=$(echo "$payload" | jq --arg sig "$signature" '.signature = $sig')

    echo "$final_entry"
}

# ============================================================================
# LOG WRITING
# ============================================================================

# Write log entry to file
write_log_entry() {
    local entry="$1"
    local log_file="${2:-$AUDIT_LOG_FILE}"
    local format="${3:-$AUDIT_LOG_FORMAT}"

    # Create log directory if needed
    local log_dir
    log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir"

    # Convert to desired format
    local formatted_entry
    case "$format" in
        "json")
            formatted_entry="$entry"
            ;;
        "logfmt")
            # Convert JSON to logfmt (key=value pairs)
            formatted_entry=$(echo "$entry" | jq -r 'to_entries | map("\(.key)=\"\(.value)\"") | join(" ")')
            ;;
        "plain")
            # Plain text format
            local timestamp level message
            timestamp=$(echo "$entry" | jq -r '.timestamp')
            level=$(echo "$entry" | jq -r '.level')
            message=$(echo "$entry" | jq -r '.message')
            formatted_entry="[$timestamp] [$level] $message"
            ;;
        *)
            formatted_entry="$entry"
            ;;
    esac

    # Append to log file
    if ! echo "$formatted_entry" >> "$log_file"; then
        audit_log_internal "ERROR" "Failed to write to log file: $log_file"
        return $EXIT_LOG_WRITE_FAILED
    fi

    # Set restrictive permissions
    chmod 600 "$log_file"

    return 0
}

# ============================================================================
# HIGH-LEVEL LOGGING FUNCTIONS
# ============================================================================

# Generic audit log function
audit_log() {
    local level_num="$1"
    local level_name="$2"
    local message="$3"
    local component="${4:-migration}"
    local action="${5:-}"
    local metadata="${6:-{}}"

    # Check if level meets minimum threshold
    if (( level_num < AUDIT_MIN_LEVEL )); then
        return 0  # Skip logging
    fi

    # Create log entry
    local entry
    entry=$(create_log_entry "$level_name" "$message" "$component" "$action" "${USER:-unknown}" "$metadata")

    # Write to log file
    write_log_entry "$entry" "$AUDIT_LOG_FILE" "$AUDIT_LOG_FORMAT"
}

# Convenience functions for each log level
audit_trace() {
    audit_log "$LEVEL_TRACE" "TRACE" "$@"
}

audit_debug() {
    audit_log "$LEVEL_DEBUG" "DEBUG" "$@"
}

audit_info() {
    audit_log "$LEVEL_INFO" "INFO" "$@"
}

audit_warn() {
    audit_log "$LEVEL_WARN" "WARN" "$@"
}

audit_error() {
    audit_log "$LEVEL_ERROR" "ERROR" "$@"
}

audit_critical() {
    audit_log "$LEVEL_CRITICAL" "CRITICAL" "$@"
}

# ============================================================================
# SPECIALIZED AUDIT FUNCTIONS
# ============================================================================

# Log migration start
audit_migration_start() {
    local source_db="$1"
    local target_db="$2"
    local profile="${3:-default}"

    local metadata
    metadata=$(jq -n \
        --arg source "$source_db" \
        --arg target "$target_db" \
        --arg profile "$profile" \
        '{source_db: $source, target_db: $target, profile: $profile}')

    audit_info "Migration started" "migration" "migration_start" "$metadata"
}

# Log migration complete
audit_migration_complete() {
    local duration="$1"
    local realms_count="$2"
    local users_count="$3"
    local status="${4:-success}"

    local metadata
    metadata=$(jq -n \
        --arg duration "$duration" \
        --arg realms "$realms_count" \
        --arg users "$users_count" \
        --arg status "$status" \
        '{duration_seconds: $duration, realms_migrated: $realms, users_migrated: $users, status: $status}')

    if [[ "$status" == "success" ]]; then
        audit_info "Migration completed successfully" "migration" "migration_complete" "$metadata"
    else
        audit_error "Migration failed" "migration" "migration_failed" "$metadata"
    fi
}

# Log security event (vault access, secrets read)
audit_security_event() {
    local event_type="$1"  # vault_read, secret_access, auth_attempt
    local resource="$2"
    local result="${3:-success}"  # success, denied, failed
    local details="${4:-{}}"

    local metadata
    metadata=$(jq -n \
        --arg type "$event_type" \
        --arg resource "$resource" \
        --arg result "$result" \
        --argjson details "$details" \
        '{event_type: $type, resource: $resource, result: $result, details: $details}')

    if [[ "$result" == "denied" ]] || [[ "$result" == "failed" ]]; then
        audit_warn "Security event: $event_type ($result)" "security" "$event_type" "$metadata"
    else
        audit_info "Security event: $event_type" "security" "$event_type" "$metadata"
    fi
}

# Log database operation
audit_db_operation() {
    local operation="$1"  # query, backup, restore, schema_change
    local database="$2"
    local table="${3:-}"
    local rows_affected="${4:-0}"

    local metadata
    metadata=$(jq -n \
        --arg op "$operation" \
        --arg db "$database" \
        --arg tbl "$table" \
        --arg rows "$rows_affected" \
        '{operation: $op, database: $db, table: $tbl, rows_affected: $rows}')

    audit_info "Database operation: $operation" "database" "$operation" "$metadata"
}

# Log configuration change
audit_config_change() {
    local setting="$1"
    local old_value="$2"
    local new_value="$3"
    local reason="${4:-}"

    local metadata
    metadata=$(jq -n \
        --arg setting "$setting" \
        --arg old "$old_value" \
        --arg new "$new_value" \
        --arg reason "$reason" \
        '{setting: $setting, old_value: $old, new_value: $new, reason: $reason}')

    audit_info "Configuration changed: $setting" "config" "config_change" "$metadata"
}

# Log authentication event
audit_auth_event() {
    local auth_type="$1"   # login, logout, token_refresh
    local username="$2"
    local result="${3:-success}"  # success, failed, denied
    local ip_address="${4:-unknown}"

    local metadata
    metadata=$(jq -n \
        --arg type "$auth_type" \
        --arg user "$username" \
        --arg result "$result" \
        --arg ip "$ip_address" \
        '{auth_type: $type, username: $user, result: $result, ip_address: $ip}')

    if [[ "$result" == "failed" ]] || [[ "$result" == "denied" ]]; then
        audit_warn "Authentication $auth_type failed for $username" "auth" "$auth_type" "$metadata"
    else
        audit_info "Authentication $auth_type for $username" "auth" "$auth_type" "$metadata"
    fi
}

# Log error with stack trace
audit_error_with_trace() {
    local error_message="$1"
    local error_code="${2:-1}"
    local stack_trace="${3:-}"

    local metadata
    metadata=$(jq -n \
        --arg code "$error_code" \
        --arg trace "$stack_trace" \
        '{error_code: $code, stack_trace: $trace}')

    audit_error "Error occurred: $error_message" "error" "error_occurred" "$metadata"
}

# ============================================================================
# LOG VERIFICATION
# ============================================================================

# Verify integrity of all log entries
verify_log_integrity() {
    local log_file="${1:-$AUDIT_LOG_FILE}"

    if [[ ! -f "$log_file" ]]; then
        audit_log_internal "ERROR" "Log file not found: $log_file"
        return 1
    fi

    audit_log_internal "INFO" "Verifying log integrity: $log_file"

    local total_entries=0
    local valid_entries=0
    local invalid_entries=0

    while IFS= read -r line; do
        ((total_entries++))

        # Parse JSON entry
        local signature payload
        signature=$(echo "$line" | jq -r '.signature')

        if [[ -z "$signature" || "$signature" == "null" ]]; then
            # No signature - skip verification
            ((valid_entries++))
            continue
        fi

        # Remove signature from payload for verification
        payload=$(echo "$line" | jq 'del(.signature)')

        # Verify HMAC
        if verify_hmac "$payload" "$signature"; then
            ((valid_entries++))
        else
            ((invalid_entries++))
            audit_log_internal "WARN" "Invalid signature on line $total_entries"
            echo "$line" | jq -C '.'
        fi
    done < "$log_file"

    audit_log_internal "INFO" "Verification complete: $total_entries total, $valid_entries valid, $invalid_entries invalid"

    if (( invalid_entries > 0 )); then
        audit_log_internal "CRITICAL" "Log integrity compromised - $invalid_entries entries with invalid signatures"
        return $EXIT_HMAC_VERIFICATION_FAILED
    fi

    audit_log_internal "INFO" "Log integrity: OK"
    return 0
}

# ============================================================================
# LOG ROTATION
# ============================================================================

# Rotate log file (create backup with timestamp)
rotate_log_file() {
    local log_file="${1:-$AUDIT_LOG_FILE}"
    local keep_count="${2:-10}"

    if [[ ! -f "$log_file" ]]; then
        return 0  # Nothing to rotate
    fi

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    local rotated_file="${log_file}.${timestamp}"

    audit_log_internal "INFO" "Rotating log: $log_file → $rotated_file"

    # Copy current log to rotated file
    cp "$log_file" "$rotated_file"

    # Truncate current log
    > "$log_file"

    # Cleanup old rotated logs (keep last N)
    local log_dir
    log_dir=$(dirname "$log_file")
    local log_name
    log_name=$(basename "$log_file")

    find "$log_dir" -name "${log_name}.*" -type f | \
        sort -r | \
        tail -n +$((keep_count + 1)) | \
        xargs -r rm -f

    audit_log_internal "INFO" "Log rotation complete (keeping last $keep_count rotations)"
}

# ============================================================================
# QUERY FUNCTIONS
# ============================================================================

# Query logs by level
query_logs_by_level() {
    local level="$1"
    local log_file="${2:-$AUDIT_LOG_FILE}"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    jq -r "select(.level == \"$level\")" "$log_file"
}

# Query logs by component
query_logs_by_component() {
    local component="$1"
    local log_file="${2:-$AUDIT_LOG_FILE}"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    jq -r "select(.component == \"$component\")" "$log_file"
}

# Query logs by action
query_logs_by_action() {
    local action="$1"
    local log_file="${2:-$AUDIT_LOG_FILE}"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    jq -r "select(.action == \"$action\")" "$log_file"
}

# Query logs by time range
query_logs_by_time_range() {
    local start_time="$1"  # ISO 8601 format
    local end_time="$2"    # ISO 8601 format
    local log_file="${3:-$AUDIT_LOG_FILE}"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    jq -r --arg start "$start_time" --arg end "$end_time" \
        'select(.timestamp >= $start and .timestamp <= $end)' "$log_file"
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f generate_hmac
export -f verify_hmac

export -f create_log_entry
export -f write_log_entry

export -f audit_log
export -f audit_trace
export -f audit_debug
export -f audit_info
export -f audit_warn
export -f audit_error
export -f audit_critical

export -f audit_migration_start
export -f audit_migration_complete
export -f audit_security_event
export -f audit_db_operation
export -f audit_config_change
export -f audit_auth_event
export -f audit_error_with_trace

export -f verify_log_integrity
export -f rotate_log_file

export -f query_logs_by_level
export -f query_logs_by_component
export -f query_logs_by_action
export -f query_logs_by_time_range
