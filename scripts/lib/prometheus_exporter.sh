#!/usr/bin/env bash
# Prometheus Metrics Exporter for Keycloak Migration
# Exports migration metrics in Prometheus text format
#
# Usage:
#   source prometheus_exporter.sh
#   prom_start_exporter 9090
#   prom_update_metric "migration_progress" 0.67
#   prom_stop_exporter

set -euo pipefail

# Metrics file (shared state)
PROM_METRICS_FILE="${PROM_METRICS_FILE:-/tmp/keycloak_migration_metrics.prom}"
PROM_EXPORTER_PID=""

# ============================================================================
# Metrics Management
# ============================================================================

prom_init_metrics() {
    # Initialize metrics file with HELP and TYPE declarations
    cat > "$PROM_METRICS_FILE" <<'EOF'
# HELP keycloak_migration_progress Migration progress as percentage (0.0 to 1.0)
# TYPE keycloak_migration_progress gauge
keycloak_migration_progress{profile="",from_version="",to_version="",status=""} 0

# HELP keycloak_migration_checkpoint_status Current checkpoint status (0=pending, 1=in_progress, 2=completed, 3=failed)
# TYPE keycloak_migration_checkpoint_status gauge
keycloak_migration_checkpoint_status{checkpoint="backup_done"} 0
keycloak_migration_checkpoint_status{checkpoint="stopped"} 0
keycloak_migration_checkpoint_status{checkpoint="downloaded"} 0
keycloak_migration_checkpoint_status{checkpoint="built"} 0
keycloak_migration_checkpoint_status{checkpoint="started"} 0
keycloak_migration_checkpoint_status{checkpoint="migrated"} 0
keycloak_migration_checkpoint_status{checkpoint="health_ok"} 0
keycloak_migration_checkpoint_status{checkpoint="tests_ok"} 0

# HELP keycloak_migration_duration_seconds Total migration duration in seconds
# TYPE keycloak_migration_duration_seconds counter
keycloak_migration_duration_seconds{profile=""} 0

# HELP keycloak_migration_errors_total Total number of errors encountered
# TYPE keycloak_migration_errors_total counter
keycloak_migration_errors_total{profile="",error_type=""} 0

# HELP keycloak_migration_database_size_bytes Database size in bytes
# TYPE keycloak_migration_database_size_bytes gauge
keycloak_migration_database_size_bytes{database="",version=""} 0

# HELP keycloak_migration_java_heap_bytes Java heap memory usage in bytes
# TYPE keycloak_migration_java_heap_bytes gauge
keycloak_migration_java_heap_bytes{version=""} 0

# HELP keycloak_migration_last_success_timestamp Unix timestamp of last successful migration
# TYPE keycloak_migration_last_success_timestamp gauge
keycloak_migration_last_success_timestamp{profile=""} 0
EOF

    log_info "Prometheus metrics initialized: $PROM_METRICS_FILE"
}

prom_update_metric() {
    # Update a metric value
    local metric_name="$1"
    local value="$2"
    local labels="${3:-}"

    if [[ ! -f "$PROM_METRICS_FILE" ]]; then
        prom_init_metrics
    fi

    # Update metric (simple sed replacement)
    if [[ -n "$labels" ]]; then
        # With labels
        sed -i "s|^${metric_name}{${labels}}.*|${metric_name}{${labels}} ${value}|" "$PROM_METRICS_FILE"
    else
        # Without labels (update first occurrence)
        sed -i "0,/^${metric_name}{/s|^${metric_name}{.*|${metric_name} ${value}|" "$PROM_METRICS_FILE"
    fi
}

prom_set_progress() {
    # Set migration progress (0.0 to 1.0)
    local progress="$1"
    local profile="${PROFILE_NAME:-unknown}"
    local from_version="${PROFILE_KC_CURRENT_VERSION:-unknown}"
    local to_version="${PROFILE_KC_TARGET_VERSION:-unknown}"
    local status="${2:-in_progress}"

    # Multi-instance support: add tenant or node labels
    local tenant="${TENANT_NAME:-}"
    local node="${NODE_NAME:-}"

    local labels="profile=\"${profile}\",from_version=\"${from_version}\",to_version=\"${to_version}\",status=\"${status}\""
    if [[ -n "$tenant" ]]; then
        labels="${labels},tenant=\"${tenant}\""
    fi
    if [[ -n "$node" ]]; then
        labels="${labels},node=\"${node}\""
    fi

    prom_update_metric "keycloak_migration_progress" "$progress" "$labels"
}

prom_set_checkpoint() {
    # Set checkpoint status
    # Status: 0=pending, 1=in_progress, 2=completed, 3=failed
    local checkpoint="$1"
    local status="$2"  # 0-3

    local labels="checkpoint=\"${checkpoint}\""
    prom_update_metric "keycloak_migration_checkpoint_status" "$status" "$labels"
}

prom_increment_errors() {
    # Increment error counter
    local error_type="${1:-unknown}"
    local profile="${PROFILE_NAME:-unknown}"

    # Get current value
    local current_value
    current_value=$(grep "keycloak_migration_errors_total{profile=\"${profile}\",error_type=\"${error_type}\"}" "$PROM_METRICS_FILE" 2>/dev/null | awk '{print $NF}' || echo "0")
    local new_value=$((current_value + 1))

    local labels="profile=\"${profile}\",error_type=\"${error_type}\""
    prom_update_metric "keycloak_migration_errors_total" "$new_value" "$labels"
}

prom_set_duration() {
    # Set migration duration
    local duration_seconds="$1"
    local profile="${PROFILE_NAME:-unknown}"

    local labels="profile=\"${profile}\""
    prom_update_metric "keycloak_migration_duration_seconds" "$duration_seconds" "$labels"
}

prom_set_success_timestamp() {
    # Set last success timestamp
    local timestamp
    timestamp=$(date +%s)
    local profile="${PROFILE_NAME:-unknown}"

    local labels="profile=\"${profile}\""
    prom_update_metric "keycloak_migration_last_success_timestamp" "$timestamp" "$labels"
}

# ============================================================================
# HTTP Server (Simple nc-based exporter)
# ============================================================================

prom_start_exporter() {
    # Start simple HTTP server to expose metrics
    local port="${1:-9090}"

    prom_init_metrics

    log_info "Starting Prometheus exporter on port $port..."

    # Simple HTTP server using netcat
    (
        while true; do
            {
                echo "HTTP/1.1 200 OK"
                echo "Content-Type: text/plain; version=0.0.4"
                echo ""
                cat "$PROM_METRICS_FILE"
            } | nc -l -p "$port" -q 1 2>/dev/null || sleep 1
        done
    ) &

    PROM_EXPORTER_PID=$!
    export PROM_EXPORTER_PID

    log_success "Prometheus exporter running (PID: $PROM_EXPORTER_PID)"
    log_info "Metrics available at: http://localhost:${port}/metrics"
}

prom_stop_exporter() {
    # Stop HTTP server
    if [[ -n "${PROM_EXPORTER_PID:-}" ]]; then
        log_info "Stopping Prometheus exporter (PID: $PROM_EXPORTER_PID)..."
        kill "$PROM_EXPORTER_PID" 2>/dev/null || true
        PROM_EXPORTER_PID=""
        log_success "Exporter stopped"
    fi
}

# ============================================================================
# Integration Helpers
# ============================================================================

prom_track_migration() {
    # Wrapper to track migration steps
    # Usage: prom_track_migration "checkpoint_name" command args...

    local checkpoint="$1"
    shift
    local command=("$@")

    # Mark as in-progress
    prom_set_checkpoint "$checkpoint" 1

    # Execute command
    local start_time
    start_time=$(date +%s)

    if "${command[@]}"; then
        # Success
        prom_set_checkpoint "$checkpoint" 2
        local duration=$(($(date +%s) - start_time))
        log_info "Checkpoint $checkpoint completed in ${duration}s"
        return 0
    else
        # Failure
        prom_set_checkpoint "$checkpoint" 3
        prom_increment_errors "$checkpoint"
        log_error "Checkpoint $checkpoint failed"
        return 1
    fi
}

# ============================================================================
# Cleanup on Exit
# ============================================================================

prom_cleanup() {
    prom_stop_exporter
    rm -f "$PROM_METRICS_FILE"
}

trap prom_cleanup EXIT INT TERM
