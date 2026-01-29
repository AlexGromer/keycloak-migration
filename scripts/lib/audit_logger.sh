#!/usr/bin/env bash
# Audit Logger for Keycloak Migration v3.0
# Structured JSON logging for all migration operations

set -euo pipefail

AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-./migration_audit.jsonl}"
AUDIT_ENABLED="${AUDIT_ENABLED:-true}"

# ============================================================================
# Core Logging
# ============================================================================

audit_log() {
    [[ "$AUDIT_ENABLED" != "true" ]] && return 0

    local level="$1"
    local event="$2"
    local message="$3"
    shift 3
    # Remaining args: key=value pairs for extra fields

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "unknown")
    local user
    user=$(whoami 2>/dev/null || echo "unknown")

    # Build extra fields JSON
    local extra=""
    while [[ $# -gt 0 ]]; do
        local kv="$1"; shift
        local k="${kv%%=*}"
        local v="${kv#*=}"
        # Escape double quotes in value
        v="${v//\"/\\\"}"
        extra="${extra},\"${k}\":\"${v}\""
    done

    # Write JSON line
    local json="{\"ts\":\"${timestamp}\",\"level\":\"${level}\",\"event\":\"${event}\",\"msg\":\"${message}\",\"host\":\"${hostname}\",\"user\":\"${user}\"${extra}}"

    mkdir -p "$(dirname "$AUDIT_LOG_FILE")"
    echo "$json" >> "$AUDIT_LOG_FILE"
}

# ============================================================================
# Convenience Functions
# ============================================================================

audit_info() {
    audit_log "INFO" "$@"
}

audit_warn() {
    audit_log "WARN" "$@"
}

audit_error() {
    audit_log "ERROR" "$@"
}

audit_migration_start() {
    local profile="$1"
    local from_version="$2"
    local to_version="$3"
    audit_log "INFO" "migration_start" "Migration started" \
        "profile=${profile}" \
        "from_version=${from_version}" \
        "to_version=${to_version}"
}

audit_migration_step() {
    local version="$1"
    local status="$2"
    local duration="${3:-}"
    audit_log "INFO" "migration_step" "Step ${status}: ${version}" \
        "version=${version}" \
        "status=${status}" \
        "duration_s=${duration}"
}

audit_backup() {
    local version="$1"
    local path="$2"
    local size="${3:-}"
    audit_log "INFO" "backup_created" "Backup for ${version}" \
        "version=${version}" \
        "backup_path=${path}" \
        "size_bytes=${size}"
}

audit_rollback() {
    local version="$1"
    local reason="$2"
    audit_log "WARN" "rollback" "Rollback triggered for ${version}" \
        "version=${version}" \
        "reason=${reason}"
}

audit_health_check() {
    local version="$1"
    local status="$2"
    local endpoint="${3:-}"
    audit_log "INFO" "health_check" "Health check ${status}" \
        "version=${version}" \
        "status=${status}" \
        "endpoint=${endpoint}"
}

audit_migration_end() {
    local profile="$1"
    local status="$2"
    local total_duration="${3:-}"
    audit_log "INFO" "migration_end" "Migration ${status}" \
        "profile=${profile}" \
        "status=${status}" \
        "total_duration_s=${total_duration}"
}

# ============================================================================
# Export Functions
# ============================================================================

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f audit_log
    export -f audit_info
    export -f audit_warn
    export -f audit_error
    export -f audit_migration_start
    export -f audit_migration_step
    export -f audit_backup
    export -f audit_rollback
    export -f audit_health_check
    export -f audit_migration_end
fi
