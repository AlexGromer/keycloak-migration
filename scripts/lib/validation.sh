#!/usr/bin/env bash
# Metrics Validation Engine for Canary & Blue-Green (v3.3)
# Validates error rates, latency, health endpoints

set -euo pipefail

# ============================================================================
# Health Check Validation
# ============================================================================

validate_health_endpoint() {
    # Check if health endpoint returns 200 OK
    # Usage: validate_health_endpoint <url> <timeout> <retries>
    local url="$1"
    local timeout="${2:-10}"
    local retries="${3:-3}"

    log_info "Health check: $url"

    local attempt=1
    while [[ $attempt -le $retries ]]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log_success "Health check passed (HTTP $http_code)"
            return 0
        else
            log_warn "Health check attempt $attempt/$retries failed (HTTP $http_code)"
            sleep 5
            attempt=$((attempt + 1))
        fi
    done

    log_error "Health check failed after $retries attempts"
    return 1
}

# ============================================================================
# Prometheus Metrics Validation
# ============================================================================

validate_error_rate() {
    # Check if error rate is below threshold
    # Usage: validate_error_rate <prometheus_url> <threshold> <duration>
    local prom_url="$1"
    local threshold="$2"      # e.g., 0.01 for 1%
    local duration="${3:-5m}" # Time window for query

    log_info "Validating error rate (threshold: $(echo "$threshold * 100" | bc -l)%, window: $duration)"

    # PromQL query: error rate
    # sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
    local query
    query="sum(rate(http_requests_total{status=~\"5..\"}[$duration])) / sum(rate(http_requests_total[$duration]))"

    local error_rate
    error_rate=$(prom_query_instant "$prom_url" "$query")

    if [[ -z "$error_rate" || "$error_rate" == "null" ]]; then
        log_warn "No error rate data available (insufficient requests?)"
        return 0  # Pass if no data
    fi

    # Compare error_rate with threshold
    if awk "BEGIN {exit !($error_rate <= $threshold)}"; then
        log_success "Error rate OK: ${error_rate} <= ${threshold}"
        return 0
    else
        log_error "Error rate EXCEEDED: ${error_rate} > ${threshold}"
        return 1
    fi
}

validate_latency_p99() {
    # Check if p99 latency is below threshold
    # Usage: validate_latency_p99 <prometheus_url> <threshold_ms> <duration>
    local prom_url="$1"
    local threshold_ms="$2"   # e.g., 500 for 500ms
    local duration="${3:-5m}"

    log_info "Validating p99 latency (threshold: ${threshold_ms}ms, window: $duration)"

    # PromQL query: p99 latency
    # histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
    local query
    query="histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[$duration])) by (le)) * 1000"

    local p99_latency
    p99_latency=$(prom_query_instant "$prom_url" "$query")

    if [[ -z "$p99_latency" || "$p99_latency" == "null" ]]; then
        log_warn "No latency data available"
        return 0
    fi

    # Convert to integer for comparison
    local p99_int
    p99_int=$(printf "%.0f" "$p99_latency")

    if [[ $p99_int -le $threshold_ms ]]; then
        log_success "p99 latency OK: ${p99_int}ms <= ${threshold_ms}ms"
        return 0
    else
        log_error "p99 latency EXCEEDED: ${p99_int}ms > ${threshold_ms}ms"
        return 1
    fi
}

validate_min_requests() {
    # Check if minimum number of requests have been made
    # Usage: validate_min_requests <prometheus_url> <min_requests> <duration>
    local prom_url="$1"
    local min_requests="$2"
    local duration="${3:-5m}"

    log_info "Validating minimum requests (threshold: $min_requests, window: $duration)"

    # PromQL query: total request count
    # sum(increase(http_requests_total[5m]))
    local query
    query="sum(increase(http_requests_total[$duration]))"

    local request_count
    request_count=$(prom_query_instant "$prom_url" "$query")

    if [[ -z "$request_count" || "$request_count" == "null" ]]; then
        log_warn "No request data available"
        return 1  # Fail if no requests
    fi

    # Convert to integer
    local count_int
    count_int=$(printf "%.0f" "$request_count")

    if [[ $count_int -ge $min_requests ]]; then
        log_success "Request count OK: $count_int >= $min_requests"
        return 0
    else
        log_warn "Insufficient requests: $count_int < $min_requests (need more data)"
        return 1
    fi
}

# ============================================================================
# Prometheus Query Helper
# ============================================================================

prom_query_instant() {
    # Execute instant Prometheus query and return result
    # Usage: prom_query_instant <prometheus_url> <query>
    local prom_url="$1"
    local query="$2"

    # URL-encode query
    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "$query")

    # Query Prometheus
    local response
    response=$(curl -s -G --data-urlencode "query=$query" "${prom_url}/api/v1/query" 2>/dev/null)

    # Extract value from JSON response
    # {"status":"success","data":{"resultType":"vector","result":[{"value":[timestamp,value]}]}}
    local value
    value=$(echo "$response" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "null")

    echo "$value"
}

# ============================================================================
# Composite Validation
# ============================================================================

validate_all_metrics() {
    # Run all validations in sequence
    # Usage: validate_all_metrics <config_map>
    # config_map: associative array with validation parameters
    local prom_url="${VALIDATION_PROMETHEUS_URL:-http://localhost:9090}"
    local error_threshold="${VALIDATION_ERROR_RATE_THRESHOLD:-0.01}"
    local latency_threshold="${VALIDATION_LATENCY_P99_THRESHOLD:-500}"
    local min_requests="${VALIDATION_MIN_REQUESTS:-100}"
    local duration="${VALIDATION_DURATION:-5m}"

    log_section "Validation — Metrics Check"

    local failed=0

    # 1. Check minimum requests
    if ! validate_min_requests "$prom_url" "$min_requests" "$duration"; then
        log_warn "Skipping further validation (insufficient data)"
        return 1
    fi

    # 2. Check error rate
    if ! validate_error_rate "$prom_url" "$error_threshold" "$duration"; then
        failed=$((failed + 1))
    fi

    # 3. Check latency
    if ! validate_latency_p99 "$prom_url" "$latency_threshold" "$duration"; then
        failed=$((failed + 1))
    fi

    if [[ $failed -eq 0 ]]; then
        log_success "All metrics validation passed"
        return 0
    else
        log_error "$failed validation(s) failed"
        return 1
    fi
}

validate_with_health_check() {
    # Combined validation: health check + metrics
    # Usage: validate_with_health_check <health_url>
    local health_url="$1"

    # 1. Health check
    if ! validate_health_endpoint "$health_url"; then
        log_error "Health check failed, skipping metrics validation"
        return 1
    fi

    # 2. Metrics validation
    validate_all_metrics
}

# ============================================================================
# Observation Period
# ============================================================================

validate_observe_period() {
    # Continuously validate metrics during observation period
    # Usage: validate_observe_period <duration_seconds> <check_interval>
    local duration="$1"
    local interval="${2:-30}"  # Check every 30s

    log_info "Starting observation period (${duration}s, check interval: ${interval}s)"

    local elapsed=0
    local failures=0

    while [[ $elapsed -lt $duration ]]; do
        log_info "Observation check at ${elapsed}s / ${duration}s"

        if ! validate_all_metrics; then
            failures=$((failures + 1))
            log_warn "Validation failure count: $failures"

            # Auto-rollback if too many failures
            if [[ $failures -ge 3 ]]; then
                log_error "Too many validation failures ($failures), triggering rollback"
                return 1
            fi
        else
            # Reset failure counter on success
            failures=0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_success "Observation period completed successfully"
    return 0
}
