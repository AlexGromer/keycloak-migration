#!/usr/bin/env bash
# Backup Rotation Policy — Automatic Cleanup (v3.5)
# Manages backup retention and automatic cleanup

set -euo pipefail

# ============================================================================
# ROTATION POLICIES
# ============================================================================

# 1. Keep Last N: Retain only the N most recent backups
# 2. Time-Based: Delete backups older than X days
# 3. Size-Based: Delete oldest when total size exceeds limit
# 4. GFS (Grandfather-Father-Son): Daily/Weekly/Monthly retention

# ============================================================================
# CONSTANTS
# ============================================================================

readonly DEFAULT_KEEP_COUNT=5
readonly DEFAULT_MAX_AGE_DAYS=30
readonly DEFAULT_MAX_SIZE_GB=100

# ============================================================================
# LOGGING
# ============================================================================

rotation_log_info() {
    echo "[ROTATION INFO] $1"
}

rotation_log_success() {
    echo "[✓ ROTATION] $1"
}

rotation_log_warn() {
    echo "[⚠ ROTATION] $1" >&2
}

rotation_log_error() {
    echo "[✗ ROTATION ERROR] $1" >&2
}

# ============================================================================
# 1. KEEP LAST N BACKUPS
# ============================================================================

rotate_keep_last_n() {
    local backup_dir="${1}"
    local keep_count="${2:-$DEFAULT_KEEP_COUNT}"
    local pattern="${3:-*.dump}"

    rotation_log_info "Policy: Keep last $keep_count backups"
    rotation_log_info "Directory: $backup_dir"
    rotation_log_info "Pattern: $pattern"

    if [[ ! -d "$backup_dir" ]]; then
        rotation_log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi

    # Find all backups matching pattern, sorted by modification time (newest first)
    local backups=()
    while IFS= read -r -d '' file; do
        backups+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -printf '%T@ %p\0' | sort -zrn | cut -zd' ' -f2-)

    local total_backups="${#backups[@]}"
    rotation_log_info "Found $total_backups backup(s)"

    if (( total_backups <= keep_count )); then
        rotation_log_success "No rotation needed (total: $total_backups <= keep: $keep_count)"
        return 0
    fi

    # Delete old backups
    local deleted_count=0
    local deleted_size=0

    for ((i = keep_count; i < total_backups; i++)); do
        local backup_file="${backups[$i]}"
        local file_size
        file_size=$(du -b "$backup_file" 2>/dev/null | awk '{print $1}' || echo "0")

        rotation_log_info "Deleting old backup: $backup_file"
        rm -f "$backup_file"

        ((deleted_count++))
        deleted_size=$((deleted_size + file_size))
    done

    local deleted_size_mb=$((deleted_size / 1024 / 1024))
    rotation_log_success "Deleted $deleted_count backup(s), freed ${deleted_size_mb}MB"
}

# ============================================================================
# 2. TIME-BASED ROTATION
# ============================================================================

rotate_by_age() {
    local backup_dir="${1}"
    local max_age_days="${2:-$DEFAULT_MAX_AGE_DAYS}"
    local pattern="${3:-*.dump}"

    rotation_log_info "Policy: Delete backups older than $max_age_days days"
    rotation_log_info "Directory: $backup_dir"

    if [[ ! -d "$backup_dir" ]]; then
        rotation_log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi

    # Find backups older than max_age_days
    local deleted_count=0
    local deleted_size=0

    while IFS= read -r -d '' file; do
        local file_size
        file_size=$(du -b "$file" 2>/dev/null | awk '{print $1}' || echo "0")

        rotation_log_info "Deleting old backup: $file"
        rm -f "$file"

        ((deleted_count++))
        deleted_size=$((deleted_size + file_size))
    done < <(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -mtime +"$max_age_days" -print0)

    if (( deleted_count > 0 )); then
        local deleted_size_mb=$((deleted_size / 1024 / 1024))
        rotation_log_success "Deleted $deleted_count backup(s), freed ${deleted_size_mb}MB"
    else
        rotation_log_success "No old backups to delete"
    fi
}

# ============================================================================
# 3. SIZE-BASED ROTATION
# ============================================================================

rotate_by_size() {
    local backup_dir="${1}"
    local max_size_gb="${2:-$DEFAULT_MAX_SIZE_GB}"
    local pattern="${3:-*.dump}"

    rotation_log_info "Policy: Keep total size under ${max_size_gb}GB"
    rotation_log_info "Directory: $backup_dir"

    if [[ ! -d "$backup_dir" ]]; then
        rotation_log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi

    # Calculate current total size
    local current_size_bytes
    current_size_bytes=$(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -exec du -b {} + 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
    local current_size_gb
    current_size_gb=$(echo "scale=2; $current_size_bytes / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")

    rotation_log_info "Current total size: ${current_size_gb}GB"

    if (( $(echo "$current_size_gb <= $max_size_gb" | bc -l 2>/dev/null || echo "1") )); then
        rotation_log_success "No rotation needed (${current_size_gb}GB <= ${max_size_gb}GB)"
        return 0
    fi

    # Find backups sorted by age (oldest first)
    local backups=()
    while IFS= read -r -d '' file; do
        backups+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -printf '%T@ %p\0' | sort -zn | cut -zd' ' -f2-)

    # Delete oldest backups until size is under limit
    local deleted_count=0
    local total_size_bytes="$current_size_bytes"
    local max_size_bytes
    max_size_bytes=$(echo "$max_size_gb * 1024 * 1024 * 1024" | bc -l 2>/dev/null || echo "0")

    for backup_file in "${backups[@]}"; do
        if (( total_size_bytes <= max_size_bytes )); then
            break
        fi

        local file_size
        file_size=$(du -b "$backup_file" 2>/dev/null | awk '{print $1}' || echo "0")

        rotation_log_info "Deleting oldest backup: $backup_file"
        rm -f "$backup_file"

        ((deleted_count++))
        total_size_bytes=$((total_size_bytes - file_size))
    done

    local final_size_gb
    final_size_gb=$(echo "scale=2; $total_size_bytes / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")

    rotation_log_success "Deleted $deleted_count backup(s), size: ${current_size_gb}GB → ${final_size_gb}GB"
}

# ============================================================================
# 4. GFS (GRANDFATHER-FATHER-SON) ROTATION
# ============================================================================

rotate_gfs() {
    local backup_dir="${1}"
    local daily_keep="${2:-7}"       # Keep 7 daily backups
    local weekly_keep="${3:-4}"      # Keep 4 weekly backups
    local monthly_keep="${4:-12}"    # Keep 12 monthly backups
    local pattern="${5:-*.dump}"

    rotation_log_info "Policy: GFS (Daily: $daily_keep, Weekly: $weekly_keep, Monthly: $monthly_keep)"
    rotation_log_info "Directory: $backup_dir"

    if [[ ! -d "$backup_dir" ]]; then
        rotation_log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi

    # Create subdirectories for GFS
    mkdir -p "$backup_dir/daily" "$backup_dir/weekly" "$backup_dir/monthly"

    # Get current date info
    local today_day
    local today_week
    local today_month
    today_day=$(date +%u)    # Day of week (1=Monday, 7=Sunday)
    today_week=$(date +%V)   # Week number
    today_month=$(date +%d)  # Day of month

    # Find all backups
    local backups=()
    while IFS= read -r -d '' file; do
        backups+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -print0)

    # Classify backups
    for backup_file in "${backups[@]}"; do
        local file_day
        local file_week
        local file_month
        file_day=$(date -r "$backup_file" +%u 2>/dev/null || echo "1")
        file_week=$(date -r "$backup_file" +%V 2>/dev/null || echo "1")
        file_month=$(date -r "$backup_file" +%d 2>/dev/null || echo "1")

        # Monthly: First day of month
        if [[ "$file_month" == "01" ]]; then
            mv "$backup_file" "$backup_dir/monthly/"
            rotation_log_info "Moved to monthly: $(basename "$backup_file")"
        # Weekly: Sunday (day 7)
        elif [[ "$file_day" == "7" ]]; then
            mv "$backup_file" "$backup_dir/weekly/"
            rotation_log_info "Moved to weekly: $(basename "$backup_file")"
        # Daily: All others
        else
            mv "$backup_file" "$backup_dir/daily/"
            rotation_log_info "Moved to daily: $(basename "$backup_file")"
        fi
    done

    # Rotate each category
    rotate_keep_last_n "$backup_dir/daily" "$daily_keep" "$pattern"
    rotate_keep_last_n "$backup_dir/weekly" "$weekly_keep" "$pattern"
    rotate_keep_last_n "$backup_dir/monthly" "$monthly_keep" "$pattern"

    rotation_log_success "GFS rotation complete"
}

# ============================================================================
# 5. COMBINED ROTATION (Multiple Policies)
# ============================================================================

rotate_combined() {
    local backup_dir="${1}"
    local keep_count="${2:-$DEFAULT_KEEP_COUNT}"
    local max_age_days="${3:-$DEFAULT_MAX_AGE_DAYS}"
    local max_size_gb="${4:-$DEFAULT_MAX_SIZE_GB}"
    local pattern="${5:-*.dump}"

    rotation_log_info "Combined rotation policy:"
    rotation_log_info "  - Keep last $keep_count backups"
    rotation_log_info "  - Delete backups older than $max_age_days days"
    rotation_log_info "  - Keep total size under ${max_size_gb}GB"

    # Apply policies in order
    rotate_by_age "$backup_dir" "$max_age_days" "$pattern"
    rotate_by_size "$backup_dir" "$max_size_gb" "$pattern"
    rotate_keep_last_n "$backup_dir" "$keep_count" "$pattern"

    rotation_log_success "Combined rotation complete"
}

# ============================================================================
# 6. DISK SPACE MONITORING
# ============================================================================

monitor_backup_disk_space() {
    local backup_dir="${1}"
    local warning_threshold_gb="${2:-10}"

    if [[ ! -d "$backup_dir" ]]; then
        rotation_log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi

    # Get available space
    local available_space_gb
    available_space_gb=$(df -BG "$backup_dir" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')

    rotation_log_info "Available disk space: ${available_space_gb}GB"

    if (( available_space_gb < warning_threshold_gb )); then
        rotation_log_warn "Low disk space: ${available_space_gb}GB < ${warning_threshold_gb}GB"
        rotation_log_warn "Consider running backup rotation or increasing disk space"
        return 1
    else
        rotation_log_success "Disk space: OK (${available_space_gb}GB available)"
        return 0
    fi
}

# ============================================================================
# 7. BACKUP STATISTICS
# ============================================================================

get_backup_statistics() {
    local backup_dir="${1}"
    local pattern="${2:-*.dump}"

    if [[ ! -d "$backup_dir" ]]; then
        rotation_log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi

    rotation_log_info "Backup Statistics for: $backup_dir"

    # Count backups
    local backup_count
    backup_count=$(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f | wc -l)

    rotation_log_info "Total backups: $backup_count"

    # Total size
    local total_size_bytes
    total_size_bytes=$(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -exec du -b {} + 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
    local total_size_gb
    total_size_gb=$(echo "scale=2; $total_size_bytes / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")

    rotation_log_info "Total size: ${total_size_gb}GB"

    # Oldest backup
    local oldest_backup
    oldest_backup=$(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-)

    if [[ -n "$oldest_backup" ]]; then
        local oldest_age_days
        oldest_age_days=$(( ($(date +%s) - $(stat -c %Y "$oldest_backup")) / 86400 ))
        rotation_log_info "Oldest backup: $(basename "$oldest_backup") (${oldest_age_days} days old)"
    fi

    # Newest backup
    local newest_backup
    newest_backup=$(find "$backup_dir" -maxdepth 1 -name "$pattern" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [[ -n "$newest_backup" ]]; then
        local newest_age_hours
        newest_age_hours=$(( ($(date +%s) - $(stat -c %Y "$newest_backup")) / 3600 ))
        rotation_log_info "Newest backup: $(basename "$newest_backup") (${newest_age_hours} hours ago)"
    fi

    # Average backup size
    if (( backup_count > 0 )); then
        local avg_size_mb
        avg_size_mb=$(echo "scale=2; ($total_size_bytes / $backup_count) / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
        rotation_log_info "Average backup size: ${avg_size_mb}MB"
    fi
}

# ============================================================================
# 8. AUTOMATED ROTATION (Based on Profile)
# ============================================================================

auto_rotate_backups() {
    local backup_dir="${1}"
    local policy="${2:-keep_last_n}"
    local param1="${3:-$DEFAULT_KEEP_COUNT}"
    local param2="${4:-$DEFAULT_MAX_AGE_DAYS}"
    local param3="${5:-$DEFAULT_MAX_SIZE_GB}"
    local pattern="${6:-*.dump}"

    rotation_log_info "Automatic backup rotation starting..."
    rotation_log_info "Policy: $policy"

    case "$policy" in
        keep_last_n)
            rotate_keep_last_n "$backup_dir" "$param1" "$pattern"
            ;;
        time_based)
            rotate_by_age "$backup_dir" "$param1" "$pattern"
            ;;
        size_based)
            rotate_by_size "$backup_dir" "$param1" "$pattern"
            ;;
        gfs)
            rotate_gfs "$backup_dir" "$param1" "$param2" "$param3" "$pattern"
            ;;
        combined)
            rotate_combined "$backup_dir" "$param1" "$param2" "$param3" "$pattern"
            ;;
        *)
            rotation_log_warn "Unknown policy: $policy, using keep_last_n"
            rotate_keep_last_n "$backup_dir" "$DEFAULT_KEEP_COUNT" "$pattern"
            ;;
    esac

    # Show statistics after rotation
    get_backup_statistics "$backup_dir" "$pattern"

    # Monitor disk space
    monitor_backup_disk_space "$backup_dir"
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f rotation_log_info
export -f rotation_log_success
export -f rotation_log_warn
export -f rotation_log_error

export -f rotate_keep_last_n
export -f rotate_by_age
export -f rotate_by_size
export -f rotate_gfs
export -f rotate_combined

export -f monitor_backup_disk_space
export -f get_backup_statistics
export -f auto_rotate_backups
