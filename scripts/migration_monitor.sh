#!/bin/bash
#
# Live Migration Monitor
# Real-time display of migration progress, metrics, and status
#

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Unicode symbols
CHECK="✓"
CROSS="✗"
ARROW="→"
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# Monitor state
MONITOR_PID=""
STATE_FILE=""
LOG_FILE=""
CURRENT_STEP=""
START_TIME=""
REFRESH_INTERVAL=2

#######################################
# Initialize monitor
#######################################
init_monitor() {
    local work_dir="$1"

    STATE_FILE="${work_dir}/migration_state.env"
    LOG_FILE="${work_dir}/logs/migration_$(date +%Y%m%d_%H%M%S).log"
    START_TIME=$(date +%s)

    # Clear screen and hide cursor
    clear
    tput civis

    # Trap exit to restore cursor
    trap cleanup EXIT INT TERM
}

cleanup() {
    tput cnorm  # Show cursor
    echo ""
}

#######################################
# Draw progress bar
#######################################
draw_progress_bar() {
    local current="$1"
    local total="$2"
    local width=50

    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    # Color based on progress
    local color="$YELLOW"
    [[ $percent -ge 75 ]] && color="$GREEN"
    [[ $percent -lt 25 ]] && color="$RED"

    printf "${color}["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' '-'
    printf "]${NC} %3d%%" "$percent"
}

#######################################
# Format time duration
#######################################
format_duration() {
    local seconds="$1"

    local hours=$((seconds / 3600))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))

    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

#######################################
# Get system metrics
#######################################
get_system_metrics() {
    # CPU usage
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)

    # Memory usage
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local mem_used=$(free -m | awk '/^Mem:/{print $3}')
    local mem_percent=$((mem_used * 100 / mem_total))

    # Disk I/O (if iostat available)
    local disk_io="N/A"
    if command -v iostat >/dev/null 2>&1; then
        disk_io=$(iostat -d -x 1 2 | tail -1 | awk '{print $4}')
    fi

    echo "${cpu_usage}:${mem_used}/${mem_total}:${mem_percent}:${disk_io}"
}

#######################################
# Get Keycloak process info
#######################################
get_kc_process_info() {
    local kc_version="$1"
    local pid_file="${WORK_DIR}/kc_${kc_version}.pid"

    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            # Get process CPU and memory
            local ps_info=$(ps -p "$pid" -o %cpu,%mem,vsz,rss --no-headers)
            echo "RUNNING:${pid}:${ps_info}"
            return 0
        fi
    fi

    echo "NOT_RUNNING:0:0:0:0:0"
}

#######################################
# Parse migration state
#######################################
parse_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "UNKNOWN:0:0:"
        return
    fi

    source "$STATE_FILE" 2>/dev/null || true

    local current_ver="${CURRENT_VERSION:-16}"
    local last_success="${LAST_SUCCESSFUL:-}"
    local current_step="${CURRENT_STEP:-init}"

    echo "${current_ver}:${last_success}:${current_step}"
}

#######################################
# Get log tail
#######################################
get_log_tail() {
    local lines="${1:-5}"

    if [[ -f "$LOG_FILE" ]]; then
        tail -n "$lines" "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    else
        echo "  No logs yet..."
    fi
}

#######################################
# Calculate ETA
#######################################
calculate_eta() {
    local current_step="$1"
    local total_steps=4  # 17, 22, 25, 26

    # Map version to step number
    local step_num=0
    case "$current_step" in
        17) step_num=1 ;;
        22) step_num=2 ;;
        25) step_num=3 ;;
        26) step_num=4 ;;
    esac

    if [[ $step_num -eq 0 ]]; then
        echo "Calculating..."
        return
    fi

    local elapsed=$(($(date +%s) - START_TIME))
    local avg_per_step=$((elapsed / step_num))
    local remaining_steps=$((total_steps - step_num))
    local eta=$((remaining_steps * avg_per_step))

    format_duration "$eta"
}

#######################################
# Draw main screen
#######################################
draw_screen() {
    local spinner_idx="$1"

    # Parse state
    local state_info=$(parse_state)
    IFS=':' read -r current_ver last_success current_step <<< "$state_info"

    # Map current version to step number
    local completed_steps=0
    case "$current_ver" in
        17) completed_steps=1 ;;
        22) completed_steps=2 ;;
        25) completed_steps=3 ;;
        26) completed_steps=4 ;;
    esac

    local total_steps=4

    # Get metrics
    local metrics=$(get_system_metrics)
    IFS=':' read -r cpu_usage mem_usage mem_percent disk_io <<< "$metrics"

    # Get KC process info (if running)
    local kc_info=$(get_kc_process_info "$current_ver")
    IFS=':' read -r kc_status kc_pid kc_cpu kc_mem kc_vsz kc_rss <<< "$kc_info"

    # Time info
    local elapsed=$(($(date +%s) - START_TIME))
    local eta=$(calculate_eta "$current_ver")

    # Clear screen
    tput home

    # Header
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                    ${BOLD}KEYCLOAK MIGRATION MONITOR${NC}                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                        KC 16 → 17 → 22 → 25 → 26                            ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Progress overview
    echo -e "${BOLD}Migration Progress:${NC}"
    echo -ne "  "
    draw_progress_bar "$completed_steps" "$total_steps"
    echo -e "  (Step $completed_steps/$total_steps)"
    echo ""

    # Migration path
    echo -e "${BOLD}Migration Path:${NC}"
    echo -ne "  KC 16 "

    for ver in 17 22 25 26; do
        if [[ "$ver" -le "$current_ver" ]] && [[ -n "$last_success" ]] && [[ "$ver" -le "$last_success" ]]; then
            echo -ne "${GREEN}${CHECK}${NC} → KC ${ver} "
        elif [[ "$ver" == "$current_ver" ]]; then
            echo -ne "${YELLOW}${SPINNER[$spinner_idx]}${NC} → KC ${ver} "
        else
            echo -ne "${DIM}○${NC} → KC ${ver} "
        fi
    done
    echo ""
    echo ""

    # Current step
    echo -e "${BOLD}Current Step:${NC} ${MAGENTA}${current_step}${NC}"
    echo ""

    # Time info
    echo -e "${BOLD}Time:${NC}"
    printf "  Elapsed: %s\n" "$(format_duration "$elapsed")"
    printf "  ETA:     %s\n" "$eta"
    echo ""

    # System resources
    echo -e "${BOLD}System Resources:${NC}"
    printf "  CPU:    %5.1f%%\n" "$cpu_usage"
    printf "  Memory: %s MB (%d%%)\n" "$mem_usage" "$mem_percent"
    printf "  Disk I/O: %s MB/s\n" "${disk_io:-N/A}"
    echo ""

    # Keycloak process
    echo -e "${BOLD}Keycloak Process:${NC}"
    if [[ "$kc_status" == "RUNNING" ]]; then
        printf "  ${GREEN}Status: RUNNING${NC} (PID: %s)\n" "$kc_pid"
        printf "  CPU:    %5.1f%%\n" "$kc_cpu"
        printf "  Memory: %5.1f%% (%s KB)\n" "$kc_mem" "$kc_rss"
    else
        printf "  ${DIM}Status: NOT RUNNING${NC}\n"
    fi
    echo ""

    # Recent logs
    echo -e "${BOLD}Recent Logs:${NC}"
    get_log_tail 8
    echo ""

    # Footer
    echo -e "${DIM}Press Ctrl+C to exit monitor | Refresh: ${REFRESH_INTERVAL}s${NC}"
}

#######################################
# Monitor loop
#######################################
monitor_loop() {
    local spinner_idx=0

    while true; do
        draw_screen "$spinner_idx"

        # Update spinner
        spinner_idx=$(( (spinner_idx + 1) % ${#SPINNER[@]} ))

        # Check if migration finished
        if [[ -f "$STATE_FILE" ]]; then
            source "$STATE_FILE" 2>/dev/null || true
            if [[ "$CURRENT_VERSION" == "26" ]] && [[ "$LAST_SUCCESSFUL" == "26" ]]; then
                # Migration complete
                draw_screen 0
                echo ""
                echo -e "${GREEN}${BOLD}${CHECK} MIGRATION COMPLETE!${NC}"
                echo ""
                break
            fi
        fi

        sleep "$REFRESH_INTERVAL"
    done
}

#######################################
# Compact mode (one-line status)
#######################################
compact_monitor() {
    while true; do
        local state_info=$(parse_state)
        IFS=':' read -r current_ver last_success current_step <<< "$state_info"

        local elapsed=$(($(date +%s) - START_TIME))
        local time_str=$(format_duration "$elapsed")

        # One-line status
        printf "\r${CYAN}[%s]${NC} Step: ${MAGENTA}%-15s${NC} | Ver: ${YELLOW}KC %s${NC} | Time: %s " \
            "$(date '+%H:%M:%S')" "$current_step" "$current_ver" "$time_str"

        sleep 1
    done
}

#######################################
# Main
#######################################
main() {
    local work_dir="${1:-../migration_workspace}"
    local mode="${2:-full}"  # full or compact

    WORK_DIR="$work_dir"

    init_monitor "$work_dir"

    if [[ "$mode" == "compact" ]]; then
        compact_monitor
    else
        monitor_loop
    fi
}

# If sourced, export functions; if executed, run
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
