#!/usr/bin/env bash
# Manual Security Scan Wrapper (v3.6)
# Run comprehensive security checks on demand

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Source security checks library
if [[ -f "$LIB_DIR/security_checks.sh" ]]; then
    source "$LIB_DIR/security_checks.sh"
else
    echo "[ERROR] security_checks.sh not found: $LIB_DIR/security_checks.sh"
    exit 1
fi

# ============================================================================
# USAGE
# ============================================================================

usage() {
    cat <<EOF
Manual Security Scan v3.6
Runs comprehensive security checks on Keycloak Migration project

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -d, --directory DIR     Scan specific directory (default: project root)
    -f, --fail-on-critical  Exit with error code if critical issues found
    --shellcheck-only       Run only ShellCheck
    --secrets-only          Run only secrets scanning
    --quick                 Quick scan (skip time-consuming checks)
    --verbose               Enable debug output

EXAMPLES:
    # Full scan
    $0

    # Scan specific directory
    $0 --directory scripts/

    # Quick scan (no git history)
    $0 --quick

    # ShellCheck only
    $0 --shellcheck-only

EXIT CODES:
    0  - Success (no issues or warnings only)
    10 - Critical security issues found
    11 - Security tools missing
    12 - Scan failed

EOF
    exit 0
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

SCAN_DIR="$PROJECT_ROOT"
FAIL_ON_CRITICAL="false"
SHELLCHECK_ONLY="false"
SECRETS_ONLY="false"
QUICK="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -d|--directory)
            SCAN_DIR="$2"
            shift 2
            ;;
        -f|--fail-on-critical)
            FAIL_ON_CRITICAL="true"
            shift
            ;;
        --shellcheck-only)
            SHELLCHECK_ONLY="true"
            shift
            ;;
        --secrets-only)
            SECRETS_ONLY="true"
            shift
            ;;
        --quick)
            QUICK="true"
            shift
            ;;
        --verbose)
            VERBOSE="true"
            export DEBUG=1
            shift
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

# ============================================================================
# MAIN SCAN
# ============================================================================

sec_log_section "Manual Security Scan v3.6"
sec_log_info "Scan directory: $SCAN_DIR"
sec_log_info "Mode: $([ "$QUICK" == "true" ] && echo "Quick" || echo "Full")"
echo ""

# Track results
CRITICAL_ISSUES=0
WARNINGS=0
PASSED_CHECKS=0

# 1. Tool detection
sec_log_section "Step 1: Tool Detection"

if check_security_tools; then
    ((PASSED_CHECKS++))
else
    ((WARNINGS++))
fi

# 2. ShellCheck scan
if [[ "$SECRETS_ONLY" != "true" ]]; then
    sec_log_section "Step 2: ShellCheck (Static Analysis)"

    if check_shellcheck_available; then
        if run_shellcheck_directory "$SCAN_DIR/scripts" "warning" "false"; then
            ((PASSED_CHECKS++))
        else
            exit_code=$?
            if [[ $exit_code -eq $EXIT_CRITICAL_ISSUES ]]; then
                ((CRITICAL_ISSUES++))
            else
                ((WARNINGS++))
            fi
        fi
    else
        sec_log_warn "ShellCheck not available — skipping"
        ((WARNINGS++))
    fi
fi

if [[ "$SHELLCHECK_ONLY" == "true" ]]; then
    sec_log_info "ShellCheck-only mode — skipping remaining checks"
    exit 0
fi

# 3. Secrets scan (current files)
if [[ "$SHELLCHECK_ONLY" != "true" ]]; then
    sec_log_section "Step 3: Secrets Scan (Current Files)"

    if check_gitleaks_available; then
        if run_gitleaks_scan "$SCAN_DIR" "" "false"; then
            ((PASSED_CHECKS++))
        else
            exit_code=$?
            if [[ $exit_code -eq $EXIT_CRITICAL_ISSUES ]]; then
                ((CRITICAL_ISSUES++))
            else
                ((WARNINGS++))
            fi
        fi
    else
        sec_log_warn "gitleaks not available — skipping"
        ((WARNINGS++))
    fi
fi

# 4. Secrets scan (git history) — only in full mode
if [[ "$QUICK" != "true" ]] && [[ "$SHELLCHECK_ONLY" != "true" ]]; then
    sec_log_section "Step 4: Secrets Scan (Git History)"

    if check_gitleaks_available; then
        if [[ -d "$SCAN_DIR/.git" ]]; then
            if run_secrets_scan_history "$SCAN_DIR"; then
                ((PASSED_CHECKS++))
            else
                exit_code=$?
                if [[ $exit_code -eq $EXIT_CRITICAL_ISSUES ]]; then
                    sec_log_warn "Secrets found in git history (historical — may be already rotated)"
                    ((WARNINGS++))
                else
                    ((WARNINGS++))
                fi
            fi
        else
            sec_log_info "Not a git repository — skipping git history scan"
        fi
    fi
fi

# 5. Hardcoded secrets pattern check
if [[ "$SHELLCHECK_ONLY" != "true" ]]; then
    sec_log_section "Step 5: Hardcoded Secrets Pattern Check"

    if check_hardcoded_secrets "$SCAN_DIR/scripts"; then
        ((PASSED_CHECKS++))
    else
        ((WARNINGS++))
    fi
fi

# ============================================================================
# SUMMARY
# ============================================================================

sec_log_section "Security Scan Summary"
echo "Passed checks:   $PASSED_CHECKS"
echo "Warnings:        $WARNINGS"
echo "Critical issues: $CRITICAL_ISSUES"
echo ""

if [[ $CRITICAL_ISSUES -gt 0 ]]; then
    sec_log_critical "$CRITICAL_ISSUES CRITICAL security issue(s) found!"
    echo ""
    sec_log_error "Recommendations:"
    sec_log_error "  1. Review security_scan.log for details"
    sec_log_error "  2. Remove hardcoded secrets from code"
    sec_log_error "  3. Rotate any exposed credentials"
    sec_log_error "  4. Use secrets manager (Vault, K8s Secrets, etc.)"
    echo ""

    if [[ "$FAIL_ON_CRITICAL" == "true" ]]; then
        sec_log_critical "Exiting with error code (--fail-on-critical)"
        exit $EXIT_CRITICAL_ISSUES
    else
        sec_log_warn "Critical issues found but not failing (use --fail-on-critical to fail)"
        exit 0
    fi
elif [[ $WARNINGS -gt 0 ]]; then
    sec_log_warn "Security scan completed with $WARNINGS warning(s)"
    sec_log_info "Review warnings and consider addressing them"
    exit 0
else
    sec_log_success "Security scan PASSED — No issues detected!"
    exit 0
fi
