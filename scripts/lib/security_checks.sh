#!/usr/bin/env bash
# Security Checks — SAST & Secrets Scanning (v3.6)
# Automated security validation for migration scripts

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly SECURITY_CHECK_VERSION="3.6.0"
readonly SHELLCHECK_MIN_VERSION="0.7.0"
readonly GITLEAKS_MIN_VERSION="8.0.0"

# Severity levels
readonly SEVERITY_CRITICAL=4
readonly SEVERITY_HIGH=3
readonly SEVERITY_MEDIUM=2
readonly SEVERITY_LOW=1
readonly SEVERITY_INFO=0

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_CRITICAL_ISSUES=10
readonly EXIT_TOOL_MISSING=11
readonly EXIT_SCAN_FAILED=12

# ============================================================================
# LOGGING
# ============================================================================

sec_log_info() {
    echo "[SEC INFO] $1"
}

sec_log_success() {
    echo "[✓ SEC] $1"
}

sec_log_warn() {
    echo "[⚠ SEC WARNING] $1" >&2
}

sec_log_error() {
    echo "[✗ SEC ERROR] $1" >&2
}

sec_log_critical() {
    echo "[🔴 SEC CRITICAL] $1" >&2
}

sec_log_section() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

# ============================================================================
# TOOL DETECTION
# ============================================================================

check_shellcheck_available() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        sec_log_warn "ShellCheck not found - install for SAST scanning"
        return 1
    fi

    local version
    version=$(shellcheck --version | grep "^version:" | awk '{print $2}')
    sec_log_info "ShellCheck version: $version"
    return 0
}

check_gitleaks_available() {
    if ! command -v gitleaks >/dev/null 2>&1; then
        sec_log_warn "gitleaks not found - install for secrets scanning"
        return 1
    fi

    local version
    version=$(gitleaks version 2>&1 | grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    sec_log_info "gitleaks version: $version"
    return 0
}

check_security_tools() {
    sec_log_section "Security Tools Detection"

    local tools_available=true

    if check_shellcheck_available; then
        sec_log_success "ShellCheck: Available"
    else
        sec_log_warn "ShellCheck: Not available"
        tools_available=false
    fi

    if check_gitleaks_available; then
        sec_log_success "gitleaks: Available"
    else
        sec_log_warn "gitleaks: Not available"
        tools_available=false
    fi

    if ! $tools_available; then
        sec_log_warn "Some security tools are missing - install for full coverage"
        sec_log_info "Install: apt-get install shellcheck && go install github.com/gitleaks/gitleaks/v8@latest"
        return 1
    fi

    return 0
}

# ============================================================================
# SHELLCHECK SCANNING
# ============================================================================

run_shellcheck_single() {
    local script_file="$1"
    local severity="${2:-warning}"  # error, warning, info, style

    if [[ ! -f "$script_file" ]]; then
        sec_log_error "File not found: $script_file"
        return 1
    fi

    sec_log_info "Scanning: $script_file"

    # Run shellcheck
    local output
    local exit_code=0

    output=$(shellcheck -s bash -S "$severity" -f gcc "$script_file" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        sec_log_success "ShellCheck: No issues in $script_file"
        return 0
    else
        # Parse output
        local critical_count=0
        local high_count=0
        local medium_count=0

        # Count issues by severity (ShellCheck SC codes)
        critical_count=$(echo "$output" | grep -c "SC1" || echo "0")  # Syntax errors
        high_count=$(echo "$output" | grep -c "SC2" || echo "0")      # Semantic issues
        medium_count=$(echo "$output" | grep -c "SC3\|SC4" || echo "0") # Style issues

        sec_log_warn "ShellCheck found issues in $script_file:"
        echo "$output" | head -20

        if [[ $critical_count -gt 0 ]]; then
            sec_log_critical "Critical issues: $critical_count (syntax errors)"
            return $SEVERITY_CRITICAL
        elif [[ $high_count -gt 0 ]]; then
            sec_log_error "High severity issues: $high_count"
            return $SEVERITY_HIGH
        else
            sec_log_warn "Medium/Low issues: $medium_count"
            return $SEVERITY_MEDIUM
        fi
    fi
}

run_shellcheck_directory() {
    local dir="$1"
    local severity="${2:-warning}"
    local fail_on_issues="${3:-true}"

    sec_log_section "ShellCheck: Scanning Directory"
    sec_log_info "Directory: $dir"
    sec_log_info "Severity: $severity"

    if [[ ! -d "$dir" ]]; then
        sec_log_error "Directory not found: $dir"
        return 1
    fi

    # Find all bash scripts
    local scripts=()
    while IFS= read -r -d '' file; do
        scripts+=("$file")
    done < <(find "$dir" -type f -name "*.sh" -print0)

    if [[ ${#scripts[@]} -eq 0 ]]; then
        sec_log_warn "No bash scripts found in $dir"
        return 0
    fi

    sec_log_info "Found ${#scripts[@]} bash script(s)"

    # Scan each script
    local total_issues=0
    local critical_issues=0
    local failed_scripts=()

    for script in "${scripts[@]}"; do
        local result=0
        run_shellcheck_single "$script" "$severity" || result=$?

        if [[ $result -ge $SEVERITY_HIGH ]]; then
            ((critical_issues++))
            failed_scripts+=("$script")
        fi

        if [[ $result -gt 0 ]]; then
            ((total_issues++))
        fi
    done

    # Summary
    sec_log_section "ShellCheck Summary"
    echo "Scripts scanned: ${#scripts[@]}"
    echo "Scripts with issues: $total_issues"
    echo "Critical/High issues: $critical_issues"

    if [[ $critical_issues -gt 0 ]]; then
        sec_log_critical "ShellCheck found critical issues in ${critical_issues} script(s):"
        for script in "${failed_scripts[@]}"; do
            sec_log_error "  - $script"
        done

        if [[ "$fail_on_issues" == "true" ]]; then
            return $EXIT_CRITICAL_ISSUES
        fi
    elif [[ $total_issues -gt 0 ]]; then
        sec_log_warn "ShellCheck found issues in $total_issues script(s) (non-critical)"
    else
        sec_log_success "ShellCheck: All scripts passed"
    fi

    return 0
}

# ============================================================================
# SECRETS SCANNING
# ============================================================================

run_gitleaks_scan() {
    local repo_dir="${1:-.}"
    local config_file="${2:-}"
    local fail_on_secrets="${3:-true}"

    sec_log_section "Secrets Scanning (gitleaks)"
    sec_log_info "Repository: $repo_dir"

    if [[ ! -d "$repo_dir/.git" ]]; then
        sec_log_warn "Not a git repository: $repo_dir"
        return 0
    fi

    # Build gitleaks command
    local gitleaks_cmd="gitleaks detect --source $repo_dir --report-format json --report-path /tmp/gitleaks-report.json --no-git"

    if [[ -n "$config_file" && -f "$config_file" ]]; then
        gitleaks_cmd="$gitleaks_cmd --config $config_file"
    fi

    # Run gitleaks
    local exit_code=0
    if eval "$gitleaks_cmd" 2>/dev/null; then
        sec_log_success "gitleaks: No secrets detected"
        return 0
    else
        exit_code=$?

        if [[ $exit_code -eq 1 ]]; then
            # Secrets found
            if [[ -f /tmp/gitleaks-report.json ]]; then
                local secret_count
                secret_count=$(jq '. | length' /tmp/gitleaks-report.json 2>/dev/null || echo "unknown")

                sec_log_critical "gitleaks detected $secret_count secret(s)!"
                sec_log_error "Report: /tmp/gitleaks-report.json"

                # Show first 5 findings
                sec_log_info "First 5 findings:"
                jq -r '.[0:5] | .[] | "  - \(.File):\(.StartLine) [\(.RuleID)]"' /tmp/gitleaks-report.json 2>/dev/null || true

                if [[ "$fail_on_secrets" == "true" ]]; then
                    sec_log_critical "Secrets detected - BLOCKING OPERATION"
                    return $EXIT_CRITICAL_ISSUES
                fi
            else
                sec_log_error "gitleaks found issues but report not generated"
            fi

            return 1
        else
            # Other error
            sec_log_error "gitleaks scan failed with exit code $exit_code"
            return $EXIT_SCAN_FAILED
        fi
    fi
}

run_secrets_scan_history() {
    local repo_dir="${1:-.}"

    sec_log_section "Secrets Scanning (Git History)"
    sec_log_info "Scanning entire git history..."

    if [[ ! -d "$repo_dir/.git" ]]; then
        sec_log_warn "Not a git repository: $repo_dir"
        return 0
    fi

    # Scan git history (slower but thorough)
    local exit_code=0
    if gitleaks detect --source "$repo_dir" --report-format json --report-path /tmp/gitleaks-history.json 2>/dev/null; then
        sec_log_success "gitleaks history scan: No secrets in git history"
        return 0
    else
        exit_code=$?

        if [[ $exit_code -eq 1 && -f /tmp/gitleaks-history.json ]]; then
            local secret_count
            secret_count=$(jq '. | length' /tmp/gitleaks-history.json 2>/dev/null || echo "unknown")

            sec_log_critical "gitleaks found $secret_count secret(s) in git history!"
            sec_log_error "Report: /tmp/gitleaks-history.json"

            # Show summary
            sec_log_info "Secrets by file:"
            jq -r 'group_by(.File) | .[] | "\(.length) secrets in \(.[0].File)"' /tmp/gitleaks-history.json 2>/dev/null || true

            return 1
        else
            sec_log_error "gitleaks history scan failed"
            return $EXIT_SCAN_FAILED
        fi
    fi
}

# ============================================================================
# HARDCODED SECRETS CHECK (Simple Patterns)
# ============================================================================

check_hardcoded_secrets() {
    local dir="${1:-.}"

    sec_log_section "Hardcoded Secrets Check (Pattern Matching)"

    local patterns=(
        "password\s*=\s*['\"][^'\"]{3,}"
        "secret\s*=\s*['\"][^'\"]{3,}"
        "api[_-]?key\s*=\s*['\"][^'\"]{3,}"
        "token\s*=\s*['\"][^'\"]{3,}"
        "aws[_-]?access[_-]?key"
        "private[_-]?key"
    )

    local found_issues=false

    for pattern in "${patterns[@]}"; do
        local matches
        matches=$(grep -rni -E "$pattern" "$dir" --include="*.sh" --include="*.yaml" --include="*.yml" 2>/dev/null || true)

        if [[ -n "$matches" ]]; then
            found_issues=true
            sec_log_warn "Found pattern: $pattern"
            echo "$matches" | head -5
            echo ""
        fi
    done

    if $found_issues; then
        sec_log_warn "Hardcoded secrets patterns found - review manually"
        return 1
    else
        sec_log_success "No hardcoded secrets patterns found"
        return 0
    fi
}

# ============================================================================
# COMPREHENSIVE SECURITY SCAN
# ============================================================================

run_comprehensive_security_scan() {
    local project_dir="${1:-.}"
    local fail_on_critical="${2:-true}"

    sec_log_section "Comprehensive Security Scan v$SECURITY_CHECK_VERSION"
    sec_log_info "Project: $project_dir"
    sec_log_info "Fail on critical: $fail_on_critical"

    local scan_start_ts
    scan_start_ts=$(date +%s)

    # Track results
    local critical_issues=0
    local warnings=0
    local passed_checks=0
    local total_checks=0

    # 1. Tool detection
    ((total_checks++))
    if check_security_tools; then
        ((passed_checks++))
    else
        ((warnings++))
    fi

    # 2. ShellCheck scan
    ((total_checks++))
    if check_shellcheck_available; then
        if run_shellcheck_directory "$project_dir/scripts" "warning" "false"; then
            ((passed_checks++))
        else
            if [[ $? -eq $EXIT_CRITICAL_ISSUES ]]; then
                ((critical_issues++))
            else
                ((warnings++))
            fi
        fi
    else
        sec_log_warn "Skipping ShellCheck (not available)"
        ((warnings++))
    fi

    # 3. Secrets scan (current files)
    ((total_checks++))
    if check_gitleaks_available; then
        if run_gitleaks_scan "$project_dir" "" "false"; then
            ((passed_checks++))
        else
            if [[ $? -eq $EXIT_CRITICAL_ISSUES ]]; then
                ((critical_issues++))
            else
                ((warnings++))
            fi
        fi
    else
        sec_log_warn "Skipping gitleaks (not available)"
        ((warnings++))
    fi

    # 4. Hardcoded secrets check
    ((total_checks++))
    if check_hardcoded_secrets "$project_dir/scripts"; then
        ((passed_checks++))
    else
        ((warnings++))
    fi

    # Summary
    local scan_duration=$(($(date +%s) - scan_start_ts))

    sec_log_section "Security Scan Summary"
    echo "Total checks: $total_checks"
    echo "Passed: $passed_checks"
    echo "Warnings: $warnings"
    echo "Critical issues: $critical_issues"
    echo "Duration: ${scan_duration}s"
    echo ""

    if [[ $critical_issues -gt 0 ]]; then
        sec_log_critical "Security scan found $critical_issues CRITICAL issue(s)"

        if [[ "$fail_on_critical" == "true" ]]; then
            sec_log_critical "BLOCKING: Fix critical issues before proceeding"
            return $EXIT_CRITICAL_ISSUES
        else
            sec_log_warn "Critical issues detected but not blocking (fail_on_critical=false)"
            return 1
        fi
    elif [[ $warnings -gt 0 ]]; then
        sec_log_warn "Security scan completed with $warnings warning(s)"
        return 0
    else
        sec_log_success "Security scan PASSED - No issues detected"
        return 0
    fi
}

# ============================================================================
# EXPORTS
# ============================================================================

export -f sec_log_info
export -f sec_log_success
export -f sec_log_warn
export -f sec_log_error
export -f sec_log_critical

export -f check_shellcheck_available
export -f check_gitleaks_available
export -f check_security_tools

export -f run_shellcheck_single
export -f run_shellcheck_directory

export -f run_gitleaks_scan
export -f run_secrets_scan_history
export -f check_hardcoded_secrets

export -f run_comprehensive_security_scan
