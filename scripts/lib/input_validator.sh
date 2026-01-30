#!/usr/bin/env bash
# Input Validation & Sanitization Library (v3.6)
# Prevents SQL injection, command injection, path traversal, YAML injection, log injection

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly INPUT_VALIDATOR_VERSION="3.6.0"

# Validation modes
readonly VALIDATION_STRICT="strict"     # Reject invalid input
readonly VALIDATION_SANITIZE="sanitize" # Clean and return safe input
readonly VALIDATION_WARN="warn"         # Log warning but allow

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_VALIDATION_FAILED=20
readonly EXIT_DANGEROUS_INPUT=21

# ============================================================================
# LOGGING
# ============================================================================

val_log_info() {
    echo "[VAL INFO] $1"
}

val_log_warn() {
    echo "[⚠ VAL WARNING] $1" >&2
}

val_log_error() {
    echo "[✗ VAL ERROR] $1" >&2
}

val_log_critical() {
    echo "[🔴 VAL CRITICAL] $1" >&2
}

# ============================================================================
# SQL INJECTION PREVENTION
# ============================================================================

# Check if string contains SQL injection patterns
is_sql_injection_attempt() {
    local input="$1"

    # SQL injection patterns (case-insensitive)
    local patterns=(
        "';.*--"                    # Comment injection
        ".*OR.*=.*"                 # OR 1=1
        ".*UNION.*SELECT"           # UNION-based injection
        ".*DROP.*TABLE"             # DROP TABLE
        ".*DELETE.*FROM"            # DELETE FROM
        ".*INSERT.*INTO"            # INSERT INTO
        ".*UPDATE.*SET"             # UPDATE SET
        ".*EXEC.*\("                # EXEC(
        ".*EXECUTE.*\("             # EXECUTE(
        ".*xp_.*"                   # xp_cmdshell
        ".*sp_.*"                   # sp_executesql
        ".*WAITFOR.*DELAY"          # Time-based blind
        ".*SLEEP\("                 # MySQL SLEEP
        ".*PG_SLEEP\("              # PostgreSQL pg_sleep
        ".*BENCHMARK\("             # MySQL BENCHMARK
        ".*DBMS_PIPE"               # Oracle DBMS_PIPE
        ".*UTL_HTTP"                # Oracle UTL_HTTP
    )

    local input_upper
    input_upper=$(echo "$input" | tr '[:lower:]' '[:upper:]')

    for pattern in "${patterns[@]}"; do
        if echo "$input_upper" | grep -qiE "$pattern"; then
            return 0  # True - SQL injection detected
        fi
    done

    return 1  # False - no SQL injection detected
}

# Escape single quotes for SQL (safe for parameterized queries)
escape_sql_string() {
    local input="$1"

    # Replace single quote with two single quotes (SQL standard)
    echo "${input//\'/\'\'}"
}

# Validate SQL identifier (table/column name)
validate_sql_identifier() {
    local identifier="$1"
    local mode="${2:-$VALIDATION_STRICT}"

    # Valid SQL identifier: alphanumeric + underscore, starts with letter
    if ! [[ "$identifier" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_error "Invalid SQL identifier: $identifier"
                return 1
                ;;
            "$VALIDATION_SANITIZE")
                # Remove invalid characters
                local sanitized
                sanitized=$(echo "$identifier" | sed 's/[^a-zA-Z0-9_]//g')
                echo "$sanitized"
                return 0
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Potentially unsafe SQL identifier: $identifier"
                echo "$identifier"
                return 0
                ;;
        esac
    fi

    echo "$identifier"
    return 0
}

# Validate SQL value and prevent injection
validate_sql_value() {
    local value="$1"
    local mode="${2:-$VALIDATION_STRICT}"

    if is_sql_injection_attempt "$value"; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_critical "SQL injection attempt detected: $value"
                return $EXIT_DANGEROUS_INPUT
                ;;
            "$VALIDATION_SANITIZE")
                # Escape single quotes
                local sanitized
                sanitized=$(escape_sql_string "$value")
                val_log_warn "SQL value sanitized from '$value' to '$sanitized'"
                echo "$sanitized"
                return 0
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Suspicious SQL value: $value"
                echo "$value"
                return 0
                ;;
        esac
    fi

    echo "$value"
    return 0
}

# ============================================================================
# COMMAND INJECTION PREVENTION
# ============================================================================

# Check if string contains command injection patterns
is_command_injection_attempt() {
    local input="$1"

    # Command injection patterns
    local patterns=(
        '.*[;&|`].*'                # Command separators and backticks
        '.*\$\(.*\).*'              # Command substitution
        '.*\$\{.*\}.*'              # Variable expansion
        '.*>.*'                     # Redirection
        '.*<.*'                     # Input redirection
        '.*\.\./.*'                 # Path traversal
        '.*~.*'                     # Home directory expansion
    )

    for pattern in "${patterns[@]}"; do
        if [[ "$input" =~ $pattern ]]; then
            return 0  # True - command injection detected
        fi
    done

    return 1  # False - no command injection detected
}

# Sanitize command argument (remove dangerous characters)
sanitize_command_arg() {
    local input="$1"

    # Remove dangerous characters: ; & | ` $ ( ) < > ~ \ '
    local sanitized
    sanitized=$(echo "$input" | tr -d ';& |'"'"'`$()<>~\"')

    echo "$sanitized"
}

# Validate command argument
validate_command_arg() {
    local arg="$1"
    local mode="${2:-$VALIDATION_STRICT}"

    if is_command_injection_attempt "$arg"; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_critical "Command injection attempt detected: $arg"
                return $EXIT_DANGEROUS_INPUT
                ;;
            "$VALIDATION_SANITIZE")
                local sanitized
                sanitized=$(sanitize_command_arg "$arg")
                val_log_warn "Command argument sanitized from '$arg' to '$sanitized'"
                echo "$sanitized"
                return 0
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Suspicious command argument: $arg"
                echo "$arg"
                return 0
                ;;
        esac
    fi

    echo "$arg"
    return 0
}

# Safe command execution with argument validation
safe_execute() {
    local command="$1"
    shift
    local args=("$@")

    # Validate all arguments
    local safe_args=()
    for arg in "${args[@]}"; do
        local validated
        if ! validated=$(validate_command_arg "$arg" "$VALIDATION_SANITIZE"); then
            val_log_error "Cannot execute: argument validation failed for '$arg'"
            return $EXIT_VALIDATION_FAILED
        fi
        safe_args+=("$validated")
    done

    # Execute with validated arguments
    val_log_info "Executing: $command ${safe_args[*]}"
    "$command" "${safe_args[@]}"
}

# ============================================================================
# PATH TRAVERSAL PREVENTION
# ============================================================================

# Normalize path and check for traversal attempts
normalize_path() {
    local path="$1"

    # Remove . and .. components
    # Convert to absolute path
    if [[ -e "$path" ]]; then
        realpath "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || echo "$path"
    else
        # For non-existent paths, normalize manually
        echo "$path" | sed 's#/\./#/#g' | sed 's#/\.$##' | sed 's#//*#/#g'
    fi
}

# Check if path contains traversal attempts
is_path_traversal_attempt() {
    local path="$1"

    # Path traversal patterns
    if [[ "$path" =~ \.\. ]]; then
        return 0  # Contains ..
    fi

    if [[ "$path" =~ ^/ ]]; then
        # Absolute path - check if it's trying to escape allowed directories
        # (This check is contextual - implement based on your allowed paths)
        return 1  # For now, allow absolute paths
    fi

    return 1  # Safe
}

# Validate file path and prevent traversal
validate_file_path() {
    local path="$1"
    local allowed_base="${2:-.}"  # Default: current directory
    local mode="${3:-$VALIDATION_STRICT}"

    if is_path_traversal_attempt "$path"; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_critical "Path traversal attempt detected: $path"
                return $EXIT_DANGEROUS_INPUT
                ;;
            "$VALIDATION_SANITIZE")
                local normalized
                normalized=$(normalize_path "$path")
                val_log_warn "Path normalized from '$path' to '$normalized'"
                echo "$normalized"
                return 0
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Suspicious path: $path"
                echo "$path"
                return 0
                ;;
        esac
    fi

    # Normalize path
    local normalized
    normalized=$(normalize_path "$path")

    # Check if normalized path is within allowed base
    local normalized_base
    normalized_base=$(normalize_path "$allowed_base")

    if [[ "$normalized" != "$normalized_base"* ]]; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_error "Path outside allowed directory: $normalized - allowed:$normalized_base"
                return $EXIT_VALIDATION_FAILED
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Path outside allowed directory: $normalized - allowed:$normalized_base"
                echo "$normalized"
                return 0
                ;;
        esac
    fi

    echo "$normalized"
    return 0
}

# Safe file read with path validation
safe_read_file() {
    local file_path="$1"
    local allowed_base="${2:-.}"

    local validated
    if ! validated=$(validate_file_path "$file_path" "$allowed_base" "$VALIDATION_STRICT"); then
        val_log_error "Cannot read file: path validation failed for '$file_path'"
        return $EXIT_VALIDATION_FAILED
    fi

    if [[ ! -f "$validated" ]]; then
        val_log_error "File not found: $validated"
        return 1
    fi

    cat "$validated"
}

# Safe file write with path validation
safe_write_file() {
    local file_path="$1"
    local content="$2"
    local allowed_base="${3:-.}"

    local validated
    if ! validated=$(validate_file_path "$file_path" "$allowed_base" "$VALIDATION_STRICT"); then
        val_log_error "Cannot write file: path validation failed for '$file_path'"
        return $EXIT_VALIDATION_FAILED
    fi

    # Create directory if needed
    local dir
    dir=$(dirname "$validated")
    mkdir -p "$dir"

    echo "$content" > "$validated"
    val_log_info "File written: $validated"
}

# ============================================================================
# YAML INJECTION PREVENTION
# ============================================================================

# Check if YAML content contains dangerous constructs
is_yaml_injection_attempt() {
    local yaml_content="$1"

    # YAML injection patterns
    local patterns=(
        ".*!!python.*"              # Python object deserialization
        ".*!!ruby.*"                # Ruby object deserialization
        ".*!!java.*"                # Java object deserialization
        ".*!!php.*"                 # PHP object deserialization
        ".*exec\(.*\).*"            # Exec calls
        ".*eval\(.*\).*"            # Eval calls
        ".*system\(.*\).*"          # System calls
        ".*import.*os.*"            # OS module import
        ".*import.*subprocess.*"    # Subprocess import
    )

    for pattern in "${patterns[@]}"; do
        if echo "$yaml_content" | grep -qiE "$pattern"; then
            return 0  # Dangerous YAML construct detected
        fi
    done

    return 1  # Safe
}

# Validate YAML content
validate_yaml_content() {
    local yaml_content="$1"
    local mode="${2:-$VALIDATION_STRICT}"

    if is_yaml_injection_attempt "$yaml_content"; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_critical "Dangerous YAML construct detected"
                return $EXIT_DANGEROUS_INPUT
                ;;
            "$VALIDATION_SANITIZE")
                val_log_warn "YAML sanitization not implemented - rejecting"
                return $EXIT_VALIDATION_FAILED
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Suspicious YAML content detected"
                echo "$yaml_content"
                return 0
                ;;
        esac
    fi

    echo "$yaml_content"
    return 0
}

# Safe YAML parsing (requires yq)
safe_parse_yaml() {
    local yaml_file="$1"
    local query="${2:-.}"  # Default: return entire document

    if ! command -v yq >/dev/null 2>&1; then
        val_log_error "yq not found - install for safe YAML parsing"
        return 1
    fi

    # Read file
    local content
    if ! content=$(cat "$yaml_file"); then
        val_log_error "Cannot read YAML file: $yaml_file"
        return 1
    fi

    # Validate content
    if ! validate_yaml_content "$content" "$VALIDATION_STRICT" >/dev/null; then
        val_log_error "YAML validation failed for: $yaml_file"
        return $EXIT_VALIDATION_FAILED
    fi

    # Parse with yq
    yq eval "$query" "$yaml_file"
}

# ============================================================================
# LOG INJECTION PREVENTION
# ============================================================================

# Sanitize log message (remove control characters and newlines)
sanitize_log_message() {
    local message="$1"

    # Remove newlines, carriage returns, tabs, and other control characters
    local sanitized
    sanitized=$(echo "$message" | tr -d '\n\r\t' | tr -cd '[:print:]')

    echo "$sanitized"
}

# Safe logging with injection prevention
safe_log() {
    local level="$1"
    local message="$2"
    local log_file="${3:-/dev/stdout}"

    # Sanitize message
    local sanitized
    sanitized=$(sanitize_log_message "$message")

    # Format log entry
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local log_entry="[$timestamp] [$level] $sanitized"

    # Write to log
    if [[ "$log_file" == "/dev/stdout" ]]; then
        echo "$log_entry"
    else
        echo "$log_entry" >> "$log_file"
    fi
}

# ============================================================================
# EMAIL INJECTION PREVENTION
# ============================================================================

# Validate email address format
validate_email() {
    local email="$1"
    local mode="${2:-$VALIDATION_STRICT}"

    # RFC 5322 simplified email regex
    local email_regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    if ! [[ "$email" =~ $email_regex ]]; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_error "Invalid email format: $email"
                return $EXIT_VALIDATION_FAILED
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Suspicious email format: $email"
                echo "$email"
                return 0
                ;;
        esac
    fi

    # Check for email header injection (newlines, CRLF)
    if [[ "$email" =~ $'\n' || "$email" =~ $'\r' ]]; then
        val_log_critical "Email injection attempt detected: $email"
        return $EXIT_DANGEROUS_INPUT
    fi

    echo "$email"
    return 0
}

# ============================================================================
# URL INJECTION PREVENTION
# ============================================================================

# Validate URL format and prevent SSRF
validate_url() {
    local url="$1"
    local mode="${2:-$VALIDATION_STRICT}"
    local allowed_schemes="${3:-https http}"  # Default: allow https and http

    # Extract scheme
    local scheme
    scheme=$(echo "$url" | grep -oP '^[a-z]+(?=:)' || echo "")

    if [[ -z "$scheme" ]]; then
        val_log_error "URL missing scheme: $url"
        return $EXIT_VALIDATION_FAILED
    fi

    # Check if scheme is allowed
    if [[ ! " $allowed_schemes " =~ " $scheme " ]]; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_error "Disallowed URL scheme: $scheme - allowed:$allowed_schemes"
                return $EXIT_VALIDATION_FAILED
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Potentially unsafe URL scheme: $scheme"
                echo "$url"
                return 0
                ;;
        esac
    fi

    # Check for SSRF patterns (localhost, internal IPs)
    if [[ "$url" =~ localhost|127\.0\.0\.1|0\.0\.0\.0|::1|169\.254\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\. ]]; then
        case "$mode" in
            "$VALIDATION_STRICT")
                val_log_error "SSRF attempt detected - internal address: $url"
                return $EXIT_DANGEROUS_INPUT
                ;;
            "$VALIDATION_WARN")
                val_log_warn "Suspicious URL - internal address: $url"
                echo "$url"
                return 0
                ;;
        esac
    fi

    echo "$url"
    return 0
}

# ============================================================================
# INTEGER VALIDATION
# ============================================================================

# Validate integer input
validate_integer() {
    local input="$1"
    local min="${2:-}"
    local max="${3:-}"

    # Check if input is integer
    if ! [[ "$input" =~ ^-?[0-9]+$ ]]; then
        val_log_error "Not an integer: $input"
        return $EXIT_VALIDATION_FAILED
    fi

    # Check min
    if [[ -n "$min" ]] && (( input < min )); then
        val_log_error "Integer below minimum value: $input, minimum: $min"
        return $EXIT_VALIDATION_FAILED
    fi

    # Check max
    if [[ -n "$max" ]] && (( input > max )); then
        val_log_error "Integer above maximum value: $input, maximum: $max"
        return $EXIT_VALIDATION_FAILED
    fi

    echo "$input"
    return 0
}

# ============================================================================
# COMPREHENSIVE INPUT VALIDATION
# ============================================================================

# Validate input by type
validate_input() {
    local input="$1"
    local type="$2"            # sql_value, sql_identifier, command_arg, file_path, yaml, email, url, integer
    local mode="${3:-$VALIDATION_STRICT}"
    local extra="${4:-}"       # Extra parameter (e.g., allowed_base for file_path)

    case "$type" in
        "sql_value")
            validate_sql_value "$input" "$mode"
            ;;
        "sql_identifier")
            validate_sql_identifier "$input" "$mode"
            ;;
        "command_arg")
            validate_command_arg "$input" "$mode"
            ;;
        "file_path")
            validate_file_path "$input" "${extra:-.}" "$mode"
            ;;
        "yaml")
            validate_yaml_content "$input" "$mode"
            ;;
        "email")
            validate_email "$input" "$mode"
            ;;
        "url")
            validate_url "$input" "$mode" "$extra"
            ;;
        "integer")
            validate_integer "$input" "$extra"
            ;;
        *)
            val_log_error "Unknown validation type: $type"
            return $EXIT_VALIDATION_FAILED
            ;;
    esac
}

# ============================================================================
# EXPORTS
# ============================================================================

# SQL injection prevention
export -f is_sql_injection_attempt
export -f escape_sql_string
export -f validate_sql_identifier
export -f validate_sql_value

# Command injection prevention
export -f is_command_injection_attempt
export -f sanitize_command_arg
export -f validate_command_arg
export -f safe_execute

# Path traversal prevention
export -f normalize_path
export -f is_path_traversal_attempt
export -f validate_file_path
export -f safe_read_file
export -f safe_write_file

# YAML injection prevention
export -f is_yaml_injection_attempt
export -f validate_yaml_content
export -f safe_parse_yaml

# Log injection prevention
export -f sanitize_log_message
export -f safe_log

# Email/URL validation
export -f validate_email
export -f validate_url

# Integer validation
export -f validate_integer

# Comprehensive validation
export -f validate_input

# Logging
export -f val_log_info
export -f val_log_warn
export -f val_log_error
export -f val_log_critical
