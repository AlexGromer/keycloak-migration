#!/usr/bin/env bash
# Rate Limiter — Database Operation Throttling (v3.5)
# Prevents overwhelming production databases during migration

set -euo pipefail

# ============================================================================
# RATE LIMITING STRATEGIES
# ============================================================================

# 1. Fixed Rate: N operations per second (simple, predictable)
# 2. Token Bucket: Burst allowed, smoothed over time (flexible)
# 3. Adaptive: Monitors DB load, adjusts rate dynamically (intelligent)
# 4. Circuit Breaker: Stops on consecutive failures (protection)

# ============================================================================
# CONSTANTS
# ============================================================================

# Default limits
readonly DEFAULT_OPS_PER_SECOND=10
readonly DEFAULT_BURST_SIZE=20
readonly DEFAULT_MAX_RETRIES=3
readonly DEFAULT_BACKOFF_MULTIPLIER=2
readonly DEFAULT_CIRCUIT_THRESHOLD=5  # Failures before circuit opens

# State files (for persistent rate tracking)
readonly STATE_DIR="${WORK_DIR:-/tmp}/rate_limiter"
readonly TOKEN_BUCKET_FILE="$STATE_DIR/token_bucket.state"
readonly CIRCUIT_STATE_FILE="$STATE_DIR/circuit_breaker.state"

# ============================================================================
# INITIALIZATION
# ============================================================================

rate_limiter_init() {
    mkdir -p "$STATE_DIR"

    # Initialize token bucket state
    if [[ ! -f "$TOKEN_BUCKET_FILE" ]]; then
        echo "$(date +%s.%N) $DEFAULT_BURST_SIZE" > "$TOKEN_BUCKET_FILE"
    fi

    # Initialize circuit breaker state
    if [[ ! -f "$CIRCUIT_STATE_FILE" ]]; then
        echo "CLOSED 0 $(date +%s)" > "$CIRCUIT_STATE_FILE"
    fi
}

# ============================================================================
# 1. FIXED RATE LIMITER
# ============================================================================

rate_limit_fixed() {
    local ops_per_second="${1:-$DEFAULT_OPS_PER_SECOND}"

    # Calculate sleep duration (1 / ops_per_second)
    local sleep_duration
    sleep_duration=$(echo "scale=3; 1 / $ops_per_second" | bc -l 2>/dev/null || echo "0.1")

    sleep "$sleep_duration"
}

# ============================================================================
# 2. TOKEN BUCKET RATE LIMITER
# ============================================================================

rate_limit_token_bucket() {
    local tokens_required="${1:-1}"
    local max_tokens="${2:-$DEFAULT_BURST_SIZE}"
    local refill_rate="${3:-$DEFAULT_OPS_PER_SECOND}"

    # Read current state (last_update_time, current_tokens)
    local state
    state=$(cat "$TOKEN_BUCKET_FILE" 2>/dev/null || echo "$(date +%s.%N) $max_tokens")

    local last_update
    local current_tokens
    last_update=$(echo "$state" | awk '{print $1}')
    current_tokens=$(echo "$state" | awk '{print $2}')

    # Calculate elapsed time
    local now
    now=$(date +%s.%N)
    local elapsed
    elapsed=$(echo "$now - $last_update" | bc -l 2>/dev/null || echo "0")

    # Refill tokens based on elapsed time
    local new_tokens
    new_tokens=$(echo "$current_tokens + ($elapsed * $refill_rate)" | bc -l 2>/dev/null || echo "$current_tokens")

    # Cap at max_tokens
    if (( $(echo "$new_tokens > $max_tokens" | bc -l 2>/dev/null || echo "0") )); then
        new_tokens=$max_tokens
    fi

    # Check if enough tokens available
    if (( $(echo "$new_tokens >= $tokens_required" | bc -l 2>/dev/null || echo "0") )); then
        # Consume tokens
        new_tokens=$(echo "$new_tokens - $tokens_required" | bc -l)
        echo "$now $new_tokens" > "$TOKEN_BUCKET_FILE"
        return 0
    else
        # Wait until enough tokens available
        local wait_time
        wait_time=$(echo "($tokens_required - $new_tokens) / $refill_rate" | bc -l 2>/dev/null || echo "0.1")

        sleep "$wait_time"

        # After waiting, consume tokens
        new_tokens=$(echo "$new_tokens + ($wait_time * $refill_rate) - $tokens_required" | bc -l)
        echo "$now $new_tokens" > "$TOKEN_BUCKET_FILE"
        return 0
    fi
}

# ============================================================================
# 3. ADAPTIVE RATE LIMITER
# ============================================================================

get_database_load() {
    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"

    local load_percentage=0

    case "$db_type" in
        postgresql)
            # Get active connections / max connections
            local active
            local max
            active=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" 2>/dev/null | tr -d ' ')
            max=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SHOW max_connections;" 2>/dev/null | tr -d ' ')

            if [[ -n "$active" && -n "$max" && "$max" -gt 0 ]]; then
                load_percentage=$(echo "scale=0; ($active * 100) / $max" | bc -l 2>/dev/null || echo "0")
            fi
            ;;
        mysql|mariadb)
            # Get threads_running / max_connections
            local threads
            local max
            threads=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "SHOW STATUS LIKE 'Threads_running';" -s -N 2>/dev/null | awk '{print $2}')
            max=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "SHOW VARIABLES LIKE 'max_connections';" -s -N 2>/dev/null | awk '{print $2}')

            if [[ -n "$threads" && -n "$max" && "$max" -gt 0 ]]; then
                load_percentage=$(echo "scale=0; ($threads * 100) / $max" | bc -l 2>/dev/null || echo "0")
            fi
            ;;
        cockroachdb)
            # Get active SQL connections
            local active
            active=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT count(*) FROM crdb_internal.node_sessions WHERE status = 'active';" 2>/dev/null | tr -d ' ')

            # Estimate load (no max_connections in CockroachDB)
            if [[ -n "$active" ]]; then
                load_percentage=$(echo "scale=0; $active * 5" | bc -l 2>/dev/null || echo "0")  # Rough estimate
                # Cap at 100%
                [[ $load_percentage -gt 100 ]] && load_percentage=100
            fi
            ;;
        *)
            load_percentage=50  # Default fallback
            ;;
    esac

    echo "$load_percentage"
}

rate_limit_adaptive() {
    local db_type="${1}"
    local db_host="${2}"
    local db_port="${3}"
    local db_user="${4}"
    local db_pass="${5}"
    local db_name="${6}"
    local base_ops_per_second="${7:-$DEFAULT_OPS_PER_SECOND}"

    # Get current database load
    local load_percentage
    load_percentage=$(get_database_load "$db_type" "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name")

    # Adjust rate based on load:
    # Load < 30%: Full speed
    # Load 30-60%: Reduce to 70%
    # Load 60-80%: Reduce to 40%
    # Load > 80%: Reduce to 20%

    local adjusted_rate="$base_ops_per_second"

    if (( load_percentage < 30 )); then
        adjusted_rate="$base_ops_per_second"
    elif (( load_percentage < 60 )); then
        adjusted_rate=$(echo "scale=2; $base_ops_per_second * 0.7" | bc -l 2>/dev/null || echo "$base_ops_per_second")
    elif (( load_percentage < 80 )); then
        adjusted_rate=$(echo "scale=2; $base_ops_per_second * 0.4" | bc -l 2>/dev/null || echo "$base_ops_per_second")
    else
        adjusted_rate=$(echo "scale=2; $base_ops_per_second * 0.2" | bc -l 2>/dev/null || echo "$base_ops_per_second")
    fi

    # Log adjustment
    if [[ "$adjusted_rate" != "$base_ops_per_second" ]]; then
        echo "[RATE LIMITER] DB load: ${load_percentage}%, rate adjusted: $base_ops_per_second → ${adjusted_rate} ops/sec"
    fi

    # Apply fixed rate with adjusted value
    rate_limit_fixed "$adjusted_rate"
}

# ============================================================================
# 4. CIRCUIT BREAKER
# ============================================================================

circuit_breaker_check() {
    # Read circuit state (state, failure_count, last_failure_time)
    local circuit_state
    circuit_state=$(cat "$CIRCUIT_STATE_FILE" 2>/dev/null || echo "CLOSED 0 $(date +%s)")

    local state
    local failure_count
    local last_failure_time
    state=$(echo "$circuit_state" | awk '{print $1}')
    failure_count=$(echo "$circuit_state" | awk '{print $2}')
    last_failure_time=$(echo "$circuit_state" | awk '{print $3}')

    local now
    now=$(date +%s)

    # If OPEN, check if timeout expired (30 seconds)
    if [[ "$state" == "OPEN" ]]; then
        local elapsed=$((now - last_failure_time))

        if (( elapsed > 30 )); then
            # Try HALF_OPEN
            echo "HALF_OPEN $failure_count $now" > "$CIRCUIT_STATE_FILE"
            echo "[CIRCUIT BREAKER] State: HALF_OPEN (retrying)"
            return 0
        else
            echo "[CIRCUIT BREAKER] State: OPEN (blocking operations for $((30 - elapsed))s)"
            return 1
        fi
    fi

    # CLOSED or HALF_OPEN: allow operation
    return 0
}

circuit_breaker_success() {
    # Reset circuit breaker on success
    echo "CLOSED 0 $(date +%s)" > "$CIRCUIT_STATE_FILE"
}

circuit_breaker_failure() {
    # Read current state
    local circuit_state
    circuit_state=$(cat "$CIRCUIT_STATE_FILE" 2>/dev/null || echo "CLOSED 0 $(date +%s)")

    local state
    local failure_count
    state=$(echo "$circuit_state" | awk '{print $1}')
    failure_count=$(echo "$circuit_state" | awk '{print $2}')

    # Increment failure count
    ((failure_count++))

    local now
    now=$(date +%s)

    # If failures exceed threshold, OPEN circuit
    if (( failure_count >= DEFAULT_CIRCUIT_THRESHOLD )); then
        echo "OPEN $failure_count $now" > "$CIRCUIT_STATE_FILE"
        echo "[CIRCUIT BREAKER] State: OPEN (too many failures: $failure_count)"
    else
        echo "$state $failure_count $now" > "$CIRCUIT_STATE_FILE"
        echo "[CIRCUIT BREAKER] Failure count: $failure_count/$DEFAULT_CIRCUIT_THRESHOLD"
    fi
}

# ============================================================================
# 5. EXPONENTIAL BACKOFF
# ============================================================================

exponential_backoff() {
    local attempt="${1}"
    local base_delay="${2:-1}"
    local multiplier="${3:-$DEFAULT_BACKOFF_MULTIPLIER}"
    local max_delay="${4:-60}"

    # Calculate delay: base_delay * (multiplier ^ attempt)
    local delay
    delay=$(echo "scale=2; $base_delay * ($multiplier ^ $attempt)" | bc -l 2>/dev/null || echo "$base_delay")

    # Cap at max_delay
    if (( $(echo "$delay > $max_delay" | bc -l 2>/dev/null || echo "0") )); then
        delay=$max_delay
    fi

    echo "[BACKOFF] Attempt $attempt: sleeping ${delay}s"
    sleep "$delay"
}

# ============================================================================
# 6. RATE-LIMITED OPERATION WRAPPER
# ============================================================================

rate_limited_execute() {
    local operation="${1}"
    local rate_strategy="${2:-fixed}"  # fixed | token_bucket | adaptive
    local ops_per_second="${3:-$DEFAULT_OPS_PER_SECOND}"
    shift 3

    # Additional args for adaptive rate limiter
    local db_type="${1:-}"
    local db_host="${2:-}"
    local db_port="${3:-}"
    local db_user="${4:-}"
    local db_pass="${5:-}"
    local db_name="${6:-}"

    # Check circuit breaker
    if ! circuit_breaker_check; then
        echo "[RATE LIMITER ERROR] Circuit breaker OPEN, blocking operation"
        return 1
    fi

    # Apply rate limiting strategy
    case "$rate_strategy" in
        fixed)
            rate_limit_fixed "$ops_per_second"
            ;;
        token_bucket)
            rate_limit_token_bucket 1 "$DEFAULT_BURST_SIZE" "$ops_per_second"
            ;;
        adaptive)
            if [[ -z "$db_type" ]]; then
                echo "[RATE LIMITER WARNING] Adaptive strategy requires DB connection info, falling back to fixed"
                rate_limit_fixed "$ops_per_second"
            else
                rate_limit_adaptive "$db_type" "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" "$ops_per_second"
            fi
            ;;
        *)
            echo "[RATE LIMITER WARNING] Unknown strategy '$rate_strategy', using fixed"
            rate_limit_fixed "$ops_per_second"
            ;;
    esac

    # Execute operation with retry logic
    local attempt=0
    local max_retries="$DEFAULT_MAX_RETRIES"

    while (( attempt < max_retries )); do
        if eval "$operation"; then
            # Success
            circuit_breaker_success
            return 0
        else
            # Failure
            ((attempt++))
            circuit_breaker_failure

            if (( attempt < max_retries )); then
                echo "[RATE LIMITER] Operation failed (attempt $attempt/$max_retries), retrying with backoff"
                exponential_backoff "$attempt"
            else
                echo "[RATE LIMITER ERROR] Operation failed after $max_retries attempts"
                return 1
            fi
        fi
    done

    return 1
}

# ============================================================================
# 7. BATCH OPERATION WITH RATE LIMITING
# ============================================================================

rate_limited_batch() {
    local batch_size="${1}"
    local rate_strategy="${2:-fixed}"
    local ops_per_second="${3:-$DEFAULT_OPS_PER_SECOND}"
    shift 3

    local items=("$@")
    local total_items="${#items[@]}"
    local processed=0

    echo "[RATE LIMITER] Processing $total_items items in batches of $batch_size"
    echo "[RATE LIMITER] Strategy: $rate_strategy, Rate: $ops_per_second ops/sec"

    for ((i = 0; i < total_items; i += batch_size)); do
        local batch=("${items[@]:i:batch_size}")

        echo "[RATE LIMITER] Batch $((i / batch_size + 1)): processing ${#batch[@]} items"

        for item in "${batch[@]}"; do
            rate_limited_execute "echo 'Processing: $item'" "$rate_strategy" "$ops_per_second"
            ((processed++))
        done

        # Progress
        local progress=$((processed * 100 / total_items))
        echo "[RATE LIMITER] Progress: $processed/$total_items ($progress%)"
    done

    echo "[RATE LIMITER] Batch processing complete: $processed items"
}

# ============================================================================
# 8. CONNECTION POOL MONITORING
# ============================================================================

monitor_connection_pool() {
    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"
    local warning_threshold="${7:-80}"

    local active_connections=0
    local max_connections=100

    case "$db_type" in
        postgresql)
            active_connections=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' ')
            max_connections=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "SHOW max_connections;" 2>/dev/null | tr -d ' ')
            ;;
        mysql|mariadb)
            active_connections=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "SHOW STATUS LIKE 'Threads_connected';" -s -N 2>/dev/null | awk '{print $2}')
            max_connections=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "SHOW VARIABLES LIKE 'max_connections';" -s -N 2>/dev/null | awk '{print $2}')
            ;;
    esac

    if [[ -n "$active_connections" && -n "$max_connections" && "$max_connections" -gt 0 ]]; then
        local usage_percentage=$((active_connections * 100 / max_connections))

        echo "[CONNECTION POOL] Active: $active_connections / $max_connections ($usage_percentage%)"

        if (( usage_percentage > warning_threshold )); then
            echo "[CONNECTION POOL WARNING] Usage above ${warning_threshold}% — consider reducing rate"
        fi
    fi
}

# ============================================================================
# 9. LEAK DETECTION
# ============================================================================

detect_connection_leak() {
    local db_type="${1}"
    local host="${2}"
    local port="${3}"
    local user="${4}"
    local pass="${5}"
    local db_name="${6}"
    local idle_threshold="${7:-300}"  # 5 minutes

    local leaked_connections=()

    case "$db_type" in
        postgresql)
            # Find connections idle in transaction for > threshold
            local idle_conns
            idle_conns=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -t -c "
                SELECT pid, usename, state, EXTRACT(EPOCH FROM (now() - state_change)) as idle_seconds
                FROM pg_stat_activity
                WHERE state = 'idle in transaction'
                AND EXTRACT(EPOCH FROM (now() - state_change)) > $idle_threshold;
            " 2>/dev/null)

            if [[ -n "$idle_conns" ]]; then
                echo "[LEAK DETECTION] Found idle-in-transaction connections > ${idle_threshold}s:"
                echo "$idle_conns"

                # Optional: auto-terminate (requires superuser)
                # PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db_name" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle in transaction' AND EXTRACT(EPOCH FROM (now() - state_change)) > $idle_threshold;"
            else
                echo "[LEAK DETECTION] No connection leaks detected"
            fi
            ;;
        mysql|mariadb)
            # Find long-running processes
            local long_running
            long_running=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "
                SELECT ID, USER, TIME, STATE
                FROM information_schema.PROCESSLIST
                WHERE COMMAND != 'Sleep'
                AND TIME > $idle_threshold;
            " 2>/dev/null)

            if [[ -n "$long_running" ]]; then
                echo "[LEAK DETECTION] Found long-running processes > ${idle_threshold}s:"
                echo "$long_running"
            else
                echo "[LEAK DETECTION] No connection leaks detected"
            fi
            ;;
    esac
}

# ============================================================================
# INITIALIZATION ON SOURCE
# ============================================================================

rate_limiter_init

# ============================================================================
# EXPORTS
# ============================================================================

export -f rate_limiter_init

export -f rate_limit_fixed
export -f rate_limit_token_bucket
export -f rate_limit_adaptive
export -f get_database_load

export -f circuit_breaker_check
export -f circuit_breaker_success
export -f circuit_breaker_failure

export -f exponential_backoff
export -f rate_limited_execute
export -f rate_limited_batch

export -f monitor_connection_pool
export -f detect_connection_leak
