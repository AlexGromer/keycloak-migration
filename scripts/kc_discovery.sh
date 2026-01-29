#!/bin/bash
#
# Keycloak Migration Discovery Script
# Version: 1.1.0
# Description: Automated discovery for KC 16 → 26 migration
#
# Features:
#   --dry-run     : Test mode without real connections
#   --mock        : Use mock data for testing
#   --config FILE : Load settings from config file
#   --help        : Show usage
#

set -euo pipefail

# Version
VERSION="1.1.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Defaults
DRY_RUN=false
USE_MOCK=false
CONFIG_FILE=""
VERBOSE=false
KEYCLOAK_HOME="${KEYCLOAK_HOME:-}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-keycloak}"
PG_USER="${PG_USER:-keycloak}"
PG_PASS="${PG_PASS:-}"

# Output
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR=""
REPORT_FILE=""
LOG_FILE=""

# Counters
PROVIDERS_COUNT=0
TABLES_OVER_THRESHOLD=0
CUSTOM_THEMES_COUNT=0
KC_VERSION="unknown"
KC_DISTRIBUTION="unknown"

#######################################
# Logging
#######################################
log_init() {
    LOG_FILE="${OUTPUT_DIR}/discovery.log"
    echo "=== Keycloak Discovery Log ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
    echo "Version: $VERSION" >> "$LOG_FILE"
    echo "Mode: $(if $DRY_RUN; then echo 'DRY-RUN'; elif $USE_MOCK; then echo 'MOCK'; else echo 'LIVE'; fi)" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO" "$1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
    log "OK" "$1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    log "WARN" "$1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR" "$1"
}

log_debug() {
    if $VERBOSE; then
        echo -e "${MAGENTA}[DEBUG]${NC} $1"
    fi
    log "DEBUG" "$1"
}

log_section() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"
    log "SECTION" "$1"
}

#######################################
# Usage
#######################################
usage() {
    cat << EOF
Keycloak Migration Discovery Tool v${VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help              Show this help message
  -v, --verbose           Enable verbose output
  -d, --dry-run           Dry run mode (validate inputs, no actual scans)
  -m, --mock              Use mock data for testing
  -c, --config FILE       Load configuration from file
  -k, --keycloak-home DIR Keycloak installation directory
  -H, --pg-host HOST      PostgreSQL host (default: localhost)
  -P, --pg-port PORT      PostgreSQL port (default: 5432)
  -D, --pg-database DB    PostgreSQL database (default: keycloak)
  -U, --pg-user USER      PostgreSQL user (default: keycloak)
  -W, --pg-password PASS  PostgreSQL password
  -o, --output DIR        Output directory (default: auto-generated)

Examples:
  # Interactive mode
  ./kc_discovery.sh

  # With parameters
  ./kc_discovery.sh -k /opt/keycloak-16 -H db.example.com -D keycloak_prod

  # Dry run (validate only)
  ./kc_discovery.sh --dry-run -k /opt/keycloak-16

  # Mock mode (test with fake data)
  ./kc_discovery.sh --mock

  # From config file
  ./kc_discovery.sh --config migration.conf

Config file format (migration.conf):
  KEYCLOAK_HOME=/opt/keycloak-16
  PG_HOST=localhost
  PG_PORT=5432
  PG_DB=keycloak
  PG_USER=keycloak
  PG_PASS=secret

EOF
    exit 0
}

#######################################
# Parse arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -m|--mock)
                USE_MOCK=true
                shift
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -k|--keycloak-home)
                KEYCLOAK_HOME="$2"
                shift 2
                ;;
            -H|--pg-host)
                PG_HOST="$2"
                shift 2
                ;;
            -P|--pg-port)
                PG_PORT="$2"
                shift 2
                ;;
            -D|--pg-database)
                PG_DB="$2"
                shift 2
                ;;
            -U|--pg-user)
                PG_USER="$2"
                shift 2
                ;;
            -W|--pg-password)
                PG_PASS="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

#######################################
# Load config file
#######################################
load_config() {
    if [[ -n "$CONFIG_FILE" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            log_info "Loading config from: $CONFIG_FILE"
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
            log_success "Config loaded"
        else
            log_error "Config file not found: $CONFIG_FILE"
            exit 1
        fi
    fi
}

#######################################
# Initialize output directory
#######################################
init_output() {
    if [[ -z "$OUTPUT_DIR" ]]; then
        local mode_suffix=""
        $DRY_RUN && mode_suffix="_dryrun"
        $USE_MOCK && mode_suffix="_mock"
        OUTPUT_DIR="${SCRIPT_DIR}/../discovery_$(date +%Y%m%d_%H%M%S)${mode_suffix}"
    fi

    mkdir -p "$OUTPUT_DIR"/{providers,db,config}
    REPORT_FILE="${OUTPUT_DIR}/DISCOVERY_REPORT.md"

    log_init
    log_debug "Output directory: $OUTPUT_DIR"
}

#######################################
# Setup mock environment
#######################################
setup_mock() {
    log_section "SETTING UP MOCK ENVIRONMENT"

    # Create mock Keycloak directory
    local mock_kc="${OUTPUT_DIR}/mock_keycloak"
    KEYCLOAK_HOME="$mock_kc"

    mkdir -p "$mock_kc"/{standalone/deployments,standalone/configuration,themes,modules}

    # Create mock version file
    echo "16.1.1" > "$mock_kc/version.txt"

    # Create mock standalone.xml
    cat > "$mock_kc/standalone/configuration/standalone.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<server xmlns="urn:jboss:domain:16.0">
    <subsystem xmlns="urn:jboss:domain:keycloak-server:1.1">
        <spi name="hostname">
            <default-provider>default</default-provider>
        </spi>
        <spi name="eventsListener">
            <provider name="custom-audit" enabled="true">
                <properties>
                    <property name="endpoint" value="https://audit.example.com"/>
                </properties>
            </provider>
        </spi>
    </subsystem>
    <socket-binding-group name="standard-sockets" default-interface="public" port-offset="0">
        <socket-binding name="http" port="8080"/>
        <socket-binding name="https" port="8443"/>
    </socket-binding-group>
</server>
XMLEOF

    # Create mock custom providers
    log_info "Creating mock custom providers..."

    # Provider 1: Simple (Type A) - no javax, no resteasy
    create_mock_provider "$mock_kc/standalone/deployments/simple-theme-provider.jar" \
        "org.keycloak.theme.ThemeProviderFactory" \
        "com.example.SimpleThemeProvider" \
        "" ""

    # Provider 2: Medium (Type B) - has javax imports
    create_mock_provider "$mock_kc/standalone/deployments/custom-authenticator.jar" \
        "org.keycloak.authentication.AuthenticatorFactory" \
        "com.example.CustomAuthenticator" \
        "javax.ws.rs.core.Response javax.persistence.Entity javax.inject.Inject" ""

    # Provider 3: Complex (Type C) - has javax + resteasy
    create_mock_provider "$mock_kc/standalone/deployments/user-storage-ldap-ext.jar" \
        "org.keycloak.storage.UserStorageProviderFactory" \
        "com.example.LdapExtProvider" \
        "javax.ws.rs.core.Context javax.enterprise.context.ApplicationScoped" \
        "org.jboss.resteasy.client.jaxrs.ResteasyClientBuilder"

    # Create mock custom theme
    mkdir -p "$mock_kc/themes/corporate"
    echo "parent=keycloak" > "$mock_kc/themes/corporate/theme.properties"

    log_success "Mock Keycloak environment created at: $mock_kc"
}

create_mock_provider() {
    local jar_path="$1"
    local spi_interface="$2"
    local impl_class="$3"
    local javax_refs="$4"
    local resteasy_refs="$5"

    local temp_dir=$(mktemp -d)
    local jar_name=$(basename "$jar_path")

    # Create SPI registration
    mkdir -p "$temp_dir/META-INF/services"
    echo "$impl_class" > "$temp_dir/META-INF/services/$spi_interface"

    # Create beans.xml (for some providers)
    if [[ "$jar_name" == *"simple"* ]]; then
        echo '<?xml version="1.0"?><beans/>' > "$temp_dir/META-INF/beans.xml"
    fi

    # Create mock class file with embedded strings for detection
    mkdir -p "$temp_dir/com/example"
    {
        echo "MOCK_CLASS_BINARY_DATA"
        for ref in $javax_refs; do echo "$ref"; done
        for ref in $resteasy_refs; do echo "$ref"; done
    } > "$temp_dir/com/example/MockClass.class"

    # Create JAR using zip (more reliable than jar)
    (cd "$temp_dir" && zip -qr "$jar_path" .)

    rm -rf "$temp_dir"
    log_debug "Created mock provider: $jar_name"
}

#######################################
# Configuration (Interactive)
#######################################
configure() {
    log_section "CONFIGURATION"

    if $USE_MOCK; then
        setup_mock
        return
    fi

    # Keycloak Home
    if [[ -z "$KEYCLOAK_HOME" ]]; then
        echo -e "${YELLOW}Enter Keycloak 16 installation path:${NC}"
        read -r -p "> " KEYCLOAK_HOME
    fi

    if $DRY_RUN; then
        log_info "DRY-RUN: Would validate KEYCLOAK_HOME: $KEYCLOAK_HOME"
        if [[ ! -d "$KEYCLOAK_HOME" ]]; then
            log_warn "Directory does not exist (will fail in live mode)"
        fi
    else
        if [[ ! -d "$KEYCLOAK_HOME" ]]; then
            log_error "Directory not found: $KEYCLOAK_HOME"
            exit 1
        fi
    fi

    log_success "KEYCLOAK_HOME: $KEYCLOAK_HOME"

    # PostgreSQL connection
    if [[ -z "$PG_PASS" ]]; then
        echo -e "\n${YELLOW}PostgreSQL connection settings:${NC}"

        [[ "$PG_HOST" == "localhost" ]] && read -r -p "Host [localhost]: " input && PG_HOST="${input:-localhost}"
        [[ "$PG_PORT" == "5432" ]] && read -r -p "Port [5432]: " input && PG_PORT="${input:-5432}"
        [[ "$PG_DB" == "keycloak" ]] && read -r -p "Database [keycloak]: " input && PG_DB="${input:-keycloak}"
        [[ "$PG_USER" == "keycloak" ]] && read -r -p "Username [keycloak]: " input && PG_USER="${input:-keycloak}"

        read -r -s -p "Password: " PG_PASS
        echo ""
    fi

    export PGPASSWORD="$PG_PASS"

    # Test PostgreSQL connection
    if $DRY_RUN; then
        log_info "DRY-RUN: Would test PostgreSQL connection to $PG_HOST:$PG_PORT/$PG_DB"
    else
        if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
            log_success "PostgreSQL connection: OK"
        else
            log_error "Cannot connect to PostgreSQL"
            exit 1
        fi
    fi
}

#######################################
# Keycloak Version Detection
#######################################
detect_keycloak_version() {
    log_section "KEYCLOAK VERSION"

    if $USE_MOCK; then
        KC_VERSION="16.1.1 (MOCK)"
        KC_DISTRIBUTION="WildFly (MOCK)"
        log_success "Detected version: $KC_VERSION"
        log_info "Distribution: $KC_DISTRIBUTION"
        return
    fi

    if $DRY_RUN && [[ ! -d "$KEYCLOAK_HOME" ]]; then
        KC_VERSION="unknown (dry-run)"
        KC_DISTRIBUTION="unknown (dry-run)"
        log_info "DRY-RUN: Version detection skipped"
        return
    fi

    local version="unknown"

    # Method 1: version.txt
    if [[ -f "$KEYCLOAK_HOME/version.txt" ]]; then
        version=$(cat "$KEYCLOAK_HOME/version.txt")
    fi

    # Method 2: JAR filename
    if [[ "$version" == "unknown" ]]; then
        local jar=$(find "$KEYCLOAK_HOME" -name "keycloak-server-spi-*.jar" 2>/dev/null | head -1)
        if [[ -n "$jar" ]]; then
            version=$(basename "$jar" | sed 's/keycloak-server-spi-\(.*\)\.jar/\1/')
        fi
    fi

    # Method 3: standalone.xml presence
    if [[ "$version" == "unknown" ]]; then
        if [[ -f "$KEYCLOAK_HOME/standalone/configuration/standalone.xml" ]]; then
            version="16.x (WildFly detected)"
        fi
    fi

    KC_VERSION="$version"
    log_success "Detected version: $KC_VERSION"

    # Detect distribution type
    if [[ -d "$KEYCLOAK_HOME/standalone" ]]; then
        KC_DISTRIBUTION="WildFly"
    elif [[ -f "$KEYCLOAK_HOME/bin/kc.sh" ]]; then
        KC_DISTRIBUTION="Quarkus"
    else
        KC_DISTRIBUTION="Unknown"
    fi

    log_info "Distribution: $KC_DISTRIBUTION"

    # Validate version for migration
    if [[ "$KC_DISTRIBUTION" == "Quarkus" ]]; then
        log_warn "This appears to be a Quarkus-based Keycloak (17+)"
        log_warn "This tool is designed for WildFly-based KC 16 migration"
    fi
}

#######################################
# Custom Providers Discovery
#######################################
discover_providers() {
    log_section "CUSTOM PROVIDERS DISCOVERY"

    if $DRY_RUN && [[ ! -d "$KEYCLOAK_HOME" ]]; then
        log_info "DRY-RUN: Provider discovery skipped (no KEYCLOAK_HOME)"
        PROVIDERS_COUNT=0
        return
    fi

    local providers_found=0

    # Search locations
    local search_paths=(
        "$KEYCLOAK_HOME/standalone/deployments"
        "$KEYCLOAK_HOME/providers"
        "$KEYCLOAK_HOME/modules"
    )

    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            log_info "Scanning: $search_path"

            # Use simple for loop instead of while read with find -print0
            for jar in "$search_path"/*.jar; do
                # Skip if no files match
                [[ ! -f "$jar" ]] && continue

                local jar_name=$(basename "$jar")

                # Skip obvious Keycloak core JARs
                if [[ "$jar_name" == keycloak-* ]] && [[ "$jar_name" != *custom* ]]; then
                    if ! unzip -l "$jar" 2>/dev/null | grep -q "META-INF/services/org.keycloak"; then
                        log_debug "Skipping core JAR: $jar_name"
                        continue
                    fi
                fi

                # Check if it's a custom provider (has Keycloak SPI registration)
                if unzip -l "$jar" 2>/dev/null | grep -q "META-INF/services/org.keycloak"; then
                    analyze_provider "$jar"
                    ((providers_found++)) || true
                else
                    log_debug "No Keycloak SPI in: $jar_name"
                fi
            done
        fi
    done

    PROVIDERS_COUNT=$providers_found
    log_success "Found $providers_found custom provider(s)"

    # Check for WAR files
    local wars_found=0
    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            for war in "$search_path"/*.war; do
                [[ ! -f "$war" ]] && continue
                log_warn "Found WAR deployment: $(basename "$war")"
                ((wars_found++)) || true
            done
        fi
    done

    if [[ $wars_found -gt 0 ]]; then
        log_warn "WAR deployments ($wars_found) require special attention during migration"
    fi
}

analyze_provider() {
    local jar="$1"
    local jar_name=$(basename "$jar")
    local provider_dir="${OUTPUT_DIR}/providers/${jar_name%.jar}"

    mkdir -p "$provider_dir"

    log_info "Analyzing: $jar_name"

    local report="${provider_dir}/analysis.txt"

    echo "=== Provider Analysis: $jar_name ===" > "$report"
    echo "Path: $jar" >> "$report"
    echo "Size: $(du -h "$jar" 2>/dev/null | cut -f1 || echo 'unknown')" >> "$report"
    echo "Analyzed: $(date)" >> "$report"
    echo "" >> "$report"

    # 1. SPI registrations
    echo "--- SPI Registrations ---" >> "$report"
    local spi_types=""
    local spi_list=$(unzip -l "$jar" 2>/dev/null | grep "META-INF/services/org.keycloak" | awk '{print $4}')

    for spi_file in $spi_list; do
        if [[ -n "$spi_file" ]]; then
            local spi_name=$(basename "$spi_file")
            echo "SPI: $spi_name" >> "$report"
            unzip -p "$jar" "$spi_file" 2>/dev/null >> "$report" || true
            spi_types+="${spi_name},"
        fi
    done
    echo "" >> "$report"

    # 2. Extract to temp dir
    local temp_dir=$(mktemp -d)
    unzip -q "$jar" -d "$temp_dir" 2>/dev/null || true

    # Initialize counters
    local javax_count=0
    local resteasy_count=0
    local has_beans_xml="NO"

    # Check beans.xml first (fast check)
    echo "--- CDI Configuration ---" >> "$report"
    if [[ -f "$temp_dir/META-INF/beans.xml" ]]; then
        has_beans_xml="YES"
        echo "beans.xml: Present" >> "$report"
    else
        echo "beans.xml: MISSING (needs to be added for Quarkus)" >> "$report"
    fi
    echo "" >> "$report"

    # Check javax imports - simple grep with timeout
    echo "--- javax.* Dependencies ---" >> "$report"
    local javax_refs=""

    # Use timeout and limit file size to prevent hanging
    javax_refs=$(timeout 5 grep -r -l "javax\." "$temp_dir" 2>/dev/null | head -20 || true)
    if [[ -n "$javax_refs" ]]; then
        # Get actual patterns
        javax_refs=$(timeout 5 grep -r -h -o "javax\.[a-z.]*" "$temp_dir" 2>/dev/null | sort -u | head -50 || true)
        if [[ -n "$javax_refs" ]]; then
            echo "$javax_refs" >> "$report"
            javax_count=$(echo "$javax_refs" | grep -c "javax\." || echo 0)
            echo "$javax_refs" > "${provider_dir}/javax_imports.txt"
        fi
    fi

    if [[ $javax_count -eq 0 ]]; then
        echo "None found" >> "$report"
    fi
    echo "" >> "$report"

    # Check RESTEasy - simple grep with timeout
    echo "--- RESTEasy Usage ---" >> "$report"
    local resteasy_refs=""

    resteasy_refs=$(timeout 5 grep -r -i -l "resteasy" "$temp_dir" 2>/dev/null | head -10 || true)
    if [[ -n "$resteasy_refs" ]]; then
        resteasy_refs=$(timeout 5 grep -r -h -i -o "[A-Za-z]*[Rr]esteasy[A-Za-z]*" "$temp_dir" 2>/dev/null | sort -u | head -20 || true)
        if [[ -n "$resteasy_refs" ]]; then
            echo "$resteasy_refs" >> "$report"
            resteasy_count=$(echo "$resteasy_refs" | wc -l)
        fi
    fi

    if [[ $resteasy_count -eq 0 ]]; then
        echo "None found" >> "$report"
    fi
    echo "" >> "$report"

    # Cleanup
    rm -rf "$temp_dir"

    # Determine migration type
    local complexity="LOW"
    local migration_type="A"

    if [[ $javax_count -gt 0 ]] && [[ $resteasy_count -gt 0 ]]; then
        complexity="HIGH"
        migration_type="C"
    elif [[ $javax_count -gt 0 ]]; then
        complexity="MEDIUM"
        migration_type="B"
    fi

    echo "--- Migration Assessment ---" >> "$report"
    echo "javax.* references: $javax_count" >> "$report"
    echo "RESTEasy references: $resteasy_count" >> "$report"
    echo "Complexity: $complexity" >> "$report"
    echo "Migration Type: $migration_type" >> "$report"

    # Save JSON summary
    cat > "${provider_dir}/summary.json" << EOF
{
    "name": "$jar_name",
    "path": "$jar",
    "spi_types": "$(echo -e "$spi_types" | tr '\n' ',' | sed 's/,$//')",
    "javax_count": $javax_count,
    "resteasy_count": $resteasy_count,
    "has_beans_xml": "$has_beans_xml",
    "complexity": "$complexity",
    "migration_type": "$migration_type",
    "analyzed_at": "$(date -Iseconds)"
}
EOF

    # Copy JAR
    cp "$jar" "${provider_dir}/" 2>/dev/null || true

    log_debug "  Type: $migration_type, Complexity: $complexity, javax: $javax_count, resteasy: $resteasy_count"
}

#######################################
# PostgreSQL Analysis
#######################################
analyze_postgresql() {
    log_section "POSTGRESQL ANALYSIS"

    local db_report="${OUTPUT_DIR}/db/postgresql_analysis.txt"

    if $USE_MOCK; then
        generate_mock_db_data
        return
    fi

    if $DRY_RUN; then
        log_info "DRY-RUN: PostgreSQL analysis skipped"
        echo "DRY-RUN: No database analysis performed" > "$db_report"
        TABLES_OVER_THRESHOLD=0
        return
    fi

    echo "=== PostgreSQL Analysis ===" > "$db_report"
    echo "Host: $PG_HOST:$PG_PORT" >> "$db_report"
    echo "Database: $PG_DB" >> "$db_report"
    echo "Date: $(date)" >> "$db_report"
    echo "" >> "$db_report"

    # Database size
    log_info "Checking database size..."
    echo "--- Database Size ---" >> "$db_report"
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c \
        "SELECT pg_size_pretty(pg_database_size('$PG_DB')) as database_size;" >> "$db_report" 2>/dev/null || echo "Could not determine size" >> "$db_report"
    echo "" >> "$db_report"

    # Critical tables
    log_info "Counting rows in critical tables..."
    echo "--- Critical Tables (threshold: 300,000) ---" >> "$db_report"

    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -A -F',' << 'EOSQL' > "${OUTPUT_DIR}/db/table_counts.csv" 2>/dev/null || true
SELECT 'table_name,row_count,status'
UNION ALL
SELECT 'user_attribute', COUNT(*)::text,
       CASE WHEN COUNT(*) > 300000 THEN 'MANUAL INDEX REQUIRED' ELSE 'OK' END
FROM user_attribute
UNION ALL
SELECT 'fed_user_attribute', COUNT(*)::text,
       CASE WHEN COUNT(*) > 300000 THEN 'MANUAL INDEX REQUIRED' ELSE 'OK' END
FROM fed_user_attribute
UNION ALL
SELECT 'client_attributes', COUNT(*)::text,
       CASE WHEN COUNT(*) > 300000 THEN 'MANUAL INDEX REQUIRED' ELSE 'OK' END
FROM client_attributes
UNION ALL
SELECT 'group_attribute', COUNT(*)::text,
       CASE WHEN COUNT(*) > 300000 THEN 'MANUAL INDEX REQUIRED' ELSE 'OK' END
FROM group_attribute
UNION ALL
SELECT 'user_entity', COUNT(*)::text, 'INFO' FROM user_entity
UNION ALL
SELECT 'credential', COUNT(*)::text, 'INFO' FROM credential
UNION ALL
SELECT 'realm', COUNT(*)::text, 'INFO' FROM realm
UNION ALL
SELECT 'client', COUNT(*)::text, 'INFO' FROM client;
EOSQL

    if [[ -f "${OUTPUT_DIR}/db/table_counts.csv" ]]; then
        cat "${OUTPUT_DIR}/db/table_counts.csv" >> "$db_report"
        TABLES_OVER_THRESHOLD=$(grep -c "MANUAL INDEX REQUIRED" "${OUTPUT_DIR}/db/table_counts.csv" 2>/dev/null || echo "0")
    fi
    echo "" >> "$db_report"

    if [[ "$TABLES_OVER_THRESHOLD" -gt 0 ]]; then
        log_warn "Found $TABLES_OVER_THRESHOLD table(s) exceeding 300k rows"
    else
        log_success "All critical tables under threshold"
    fi

    # Permissions
    log_info "Checking permissions..."
    echo "--- Permission Check ---" >> "$db_report"
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c \
        "SELECT has_table_privilege(current_user, 'pg_class', 'SELECT') as pg_class_access,
                has_table_privilege(current_user, 'pg_namespace', 'SELECT') as pg_namespace_access;" >> "$db_report" 2>/dev/null || echo "Could not check" >> "$db_report"
    echo "" >> "$db_report"

    # Indexes
    log_info "Documenting indexes..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -A -F',' -c \
        "SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename;" \
        > "${OUTPUT_DIR}/db/existing_indexes.csv" 2>/dev/null || true

    # Realms
    log_info "Collecting realms..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -A -F',' -c \
        "SELECT name, enabled FROM realm ORDER BY name;" \
        > "${OUTPUT_DIR}/db/realms.csv" 2>/dev/null || true

    log_success "PostgreSQL analysis complete"
}

generate_mock_db_data() {
    log_info "Generating mock database data..."

    local db_report="${OUTPUT_DIR}/db/postgresql_analysis.txt"

    cat > "$db_report" << 'EOF'
=== PostgreSQL Analysis (MOCK DATA) ===
Host: localhost:5432
Database: keycloak_mock
Date: MOCK

--- Database Size ---
 database_size
---------------
 2.4 GB

--- Critical Tables (threshold: 300,000) ---
EOF

    # Mock table counts - simulate one table over threshold
    cat > "${OUTPUT_DIR}/db/table_counts.csv" << 'EOF'
table_name,row_count,status
user_attribute,450000,MANUAL INDEX REQUIRED
fed_user_attribute,125000,OK
client_attributes,89000,OK
group_attribute,12000,OK
user_entity,150000,INFO
credential,150000,INFO
realm,5,INFO
client,250,INFO
EOF

    cat "${OUTPUT_DIR}/db/table_counts.csv" >> "$db_report"
    TABLES_OVER_THRESHOLD=1

    # Mock realms
    cat > "${OUTPUT_DIR}/db/realms.csv" << 'EOF'
master,t
production,t
staging,t
development,f
EOF

    # Mock indexes
    cat > "${OUTPUT_DIR}/db/existing_indexes.csv" << 'EOF'
user_entity,idx_user_email,CREATE INDEX idx_user_email ON user_entity(email)
user_entity,idx_user_realm,CREATE INDEX idx_user_realm ON user_entity(realm_id)
client,idx_client_realm,CREATE INDEX idx_client_realm ON client(realm_id)
EOF

    log_success "Mock database data generated"
}

#######################################
# Configuration Analysis
#######################################
analyze_configuration() {
    log_section "CONFIGURATION ANALYSIS"

    local config_report="${OUTPUT_DIR}/config/configuration_analysis.txt"

    if $DRY_RUN && [[ ! -d "$KEYCLOAK_HOME" ]]; then
        log_info "DRY-RUN: Configuration analysis skipped"
        echo "DRY-RUN: No configuration analysis" > "$config_report"
        return
    fi

    echo "=== Configuration Analysis ===" > "$config_report"
    echo "" >> "$config_report"

    # standalone.xml
    local standalone_xml="$KEYCLOAK_HOME/standalone/configuration/standalone.xml"
    if [[ -f "$standalone_xml" ]]; then
        log_info "Analyzing standalone.xml..."

        cp "$standalone_xml" "${OUTPUT_DIR}/config/"

        echo "--- SPI Configurations ---" >> "$config_report"
        grep -A10 "<spi " "$standalone_xml" 2>/dev/null >> "$config_report" || echo "No custom SPI configs" >> "$config_report"
        echo "" >> "$config_report"

        echo "--- Datasource ---" >> "$config_report"
        grep -A20 "KeycloakDS" "$standalone_xml" 2>/dev/null >> "$config_report" || echo "Default" >> "$config_report"
        echo "" >> "$config_report"

        log_success "Configuration analysis complete"
    else
        log_warn "standalone.xml not found"
    fi

    # Custom themes
    log_info "Checking for custom themes..."
    echo "--- Custom Themes ---" >> "$config_report"

    CUSTOM_THEMES_COUNT=0
    if [[ -d "$KEYCLOAK_HOME/themes" ]]; then
        for theme_dir in "$KEYCLOAK_HOME/themes"/*; do
            [[ ! -d "$theme_dir" ]] && continue
            local theme_name=$(basename "$theme_dir")
            # Skip standard themes
            if [[ "$theme_name" != "base" ]] && [[ "$theme_name" != "keycloak" ]]; then
                echo "$theme_name" >> "${OUTPUT_DIR}/config/custom_themes.txt"
                ((CUSTOM_THEMES_COUNT++)) || true
            fi
        done
    fi

    if [[ $CUSTOM_THEMES_COUNT -gt 0 ]]; then
        log_info "Found $CUSTOM_THEMES_COUNT custom theme(s)"
        cat "${OUTPUT_DIR}/config/custom_themes.txt" >> "$config_report" 2>/dev/null || true
    else
        echo "No custom themes found" >> "$config_report"
    fi

    log_success "Theme analysis complete"
}

#######################################
# Generate Report
#######################################
generate_report() {
    log_section "GENERATING REPORT"

    # Count by complexity
    local type_a=0
    local type_b=0
    local type_c=0

    for summary in "${OUTPUT_DIR}"/providers/*/summary.json; do
        [[ ! -f "$summary" ]] && continue
        local mtype=$(grep '"migration_type"' "$summary" 2>/dev/null | cut -d'"' -f4)
        case "$mtype" in
            A) type_a=$((type_a + 1)) ;;
            B) type_b=$((type_b + 1)) ;;
            C) type_c=$((type_c + 1)) ;;
        esac
    done

    log_info "Provider types: A=$type_a, B=$type_b, C=$type_c"

    # Determine overall complexity
    local overall="LOW"
    local overall_emoji="✅"
    if [[ $type_c -gt 0 ]] || [[ $TABLES_OVER_THRESHOLD -gt 2 ]]; then
        overall="HIGH"
        overall_emoji="🔴"
    elif [[ $type_b -gt 0 ]] || [[ $TABLES_OVER_THRESHOLD -gt 0 ]]; then
        overall="MEDIUM"
        overall_emoji="⚠️"
    fi

    # Mode indicator
    local mode_badge=""
    $DRY_RUN && mode_badge=" [DRY-RUN]"
    $USE_MOCK && mode_badge=" [MOCK DATA]"

    # Generate report
    cat > "$REPORT_FILE" << EOF
# Keycloak Migration Discovery Report${mode_badge}

**Generated**: $(date)
**Tool Version**: $VERSION
**Source System**: $KEYCLOAK_HOME
**Keycloak Version**: $KC_VERSION
**Distribution**: $KC_DISTRIBUTION

---

## Executive Summary

| Metric | Value | Status |
|--------|-------|--------|
| **Overall Complexity** | **$overall** | $overall_emoji |
| Custom Providers | $PROVIDERS_COUNT | $(if [[ $PROVIDERS_COUNT -eq 0 ]]; then echo "✅"; else echo "⚠️"; fi) |
| ├─ Type A (repackage) | $type_a | $(if [[ $type_a -gt 0 ]]; then echo "✅ Easy"; else echo "-"; fi) |
| ├─ Type B (javax→jakarta) | $type_b | $(if [[ $type_b -gt 0 ]]; then echo "⚠️ Medium"; else echo "-"; fi) |
| └─ Type C (code changes) | $type_c | $(if [[ $type_c -gt 0 ]]; then echo "🔴 Complex"; else echo "-"; fi) |
| Tables >300k rows | $TABLES_OVER_THRESHOLD | $(if [[ $TABLES_OVER_THRESHOLD -gt 0 ]]; then echo "⚠️ Manual indexes"; else echo "✅ OK"; fi) |
| Custom Themes | $CUSTOM_THEMES_COUNT | $(if [[ $CUSTOM_THEMES_COUNT -gt 0 ]]; then echo "ℹ️ Review"; else echo "✅"; fi) |

### Complexity Assessment

$overall_emoji **Overall: $overall**

$(case $overall in
    LOW) echo "This migration should be straightforward with standard procedures." ;;
    MEDIUM) echo "This migration requires moderate effort. javax→jakarta transformation and/or manual index creation needed." ;;
    HIGH) echo "This migration requires significant preparation. Type C providers need code changes, source code access required." ;;
esac)

---

## Custom Providers

EOF

    if [[ $PROVIDERS_COUNT -gt 0 ]]; then
        cat >> "$REPORT_FILE" << 'EOF'
| Provider | SPI Type | javax.* | RESTEasy | beans.xml | Type | Complexity |
|----------|----------|---------|----------|-----------|------|------------|
EOF

        for summary in "${OUTPUT_DIR}"/providers/*/summary.json; do
            if [[ -f "$summary" ]]; then
                local name=$(grep '"name"' "$summary" | cut -d'"' -f4)
                local spi=$(grep '"spi_types"' "$summary" | cut -d'"' -f4 | cut -c1-25)
                local javax=$(grep '"javax_count"' "$summary" | grep -o '[0-9]*')
                local resteasy=$(grep '"resteasy_count"' "$summary" | grep -o '[0-9]*')
                local beans=$(grep '"has_beans_xml"' "$summary" | cut -d'"' -f4)
                local mtype=$(grep '"migration_type"' "$summary" | cut -d'"' -f4)
                local complexity=$(grep '"complexity"' "$summary" | cut -d'"' -f4)

                echo "| $name | $spi | $javax | $resteasy | $beans | $mtype | $complexity |" >> "$REPORT_FILE"
            fi
        done

        cat >> "$REPORT_FILE" << 'EOF'

### Migration Types Legend

- **Type A**: Repackage only (add `beans.xml` if missing)
- **Type B**: Requires `javax.*` → `jakarta.*` transformation (Eclipse Transformer)
- **Type C**: Requires source code changes (RESTEasy Classic → Reactive)

EOF
    else
        echo "*No custom providers found.*" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" << 'EOF'
---

## Database Analysis

### Table Row Counts

EOF

    if [[ -f "${OUTPUT_DIR}/db/table_counts.csv" ]]; then
        echo "| Table | Rows | Status |" >> "$REPORT_FILE"
        echo "|-------|------|--------|" >> "$REPORT_FILE"
        tail -n +2 "${OUTPUT_DIR}/db/table_counts.csv" 2>/dev/null | while IFS=',' read -r table count status; do
            local icon="✅"
            [[ "$status" == "MANUAL INDEX REQUIRED" ]] && icon="⚠️"
            [[ "$status" == "INFO" ]] && icon="ℹ️"
            echo "| $table | $count | $icon $status |" >> "$REPORT_FILE"
        done
    else
        echo "*No database analysis available.*" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" << 'EOF'

### Realms

EOF

    if [[ -f "${OUTPUT_DIR}/db/realms.csv" ]] && [[ -s "${OUTPUT_DIR}/db/realms.csv" ]]; then
        echo "| Realm | Enabled |" >> "$REPORT_FILE"
        echo "|-------|---------|" >> "$REPORT_FILE"
        while IFS=',' read -r name enabled; do
            local status="Yes"
            [[ "$enabled" == "f" ]] && status="No"
            echo "| $name | $status |" >> "$REPORT_FILE"
        done < "${OUTPUT_DIR}/db/realms.csv"
    else
        echo "*No realm data available.*" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" << EOF

---

## Recommended Actions

### Before Migration

EOF

    local action_num=1

    if [[ $type_c -gt 0 ]]; then
        echo "$action_num. 🔴 **Obtain source code** for Type C providers — code migration required" >> "$REPORT_FILE"
        ((action_num++))
    fi

    if [[ $type_b -gt 0 ]]; then
        echo "$action_num. ⚠️ **Run transformer script** — \`./transform_providers.sh\`" >> "$REPORT_FILE"
        ((action_num++))
    fi

    if [[ $TABLES_OVER_THRESHOLD -gt 0 ]]; then
        echo "$action_num. ⚠️ **Generate index SQL** — \`./generate_manual_indexes.sh\`" >> "$REPORT_FILE"
        ((action_num++))
    fi

    cat >> "$REPORT_FILE" << EOF
$action_num. 📦 **Create full PostgreSQL backup**
$((action_num+1)). 🖥️ **Prepare staging environment** (KC 17, 22, 25, 26)
$((action_num+2)). ☕ **Install OpenJDK 21**

### Migration Path

\`\`\`
KC 16 (WildFly) ─┬─► Backup DB + Export realms
                 │
                 ▼
KC 17 (Quarkus) ─── Architecture change, test basic functions
                 │
                 ▼
KC 22 (Jakarta) ─── Deploy migrated providers, test all integrations
                 │
                 ▼
KC 25 ─────────── Enable persistent sessions (REQUIRED!)
                 │
                 ▼
KC 26 ─────────── Target version
\`\`\`

---

## Output Files

\`\`\`
${OUTPUT_DIR}/
├── DISCOVERY_REPORT.md          # This report
├── discovery.log                # Execution log
├── providers/
│   └── [name]/
│       ├── analysis.txt         # Detailed analysis
│       ├── summary.json         # Machine-readable
│       └── *.jar                # Original JAR
├── db/
│   ├── postgresql_analysis.txt
│   ├── table_counts.csv
│   ├── existing_indexes.csv
│   └── realms.csv
└── config/
    ├── standalone.xml
    └── custom_themes.txt
\`\`\`

---

## Next Steps

1. Review this report
2. Run \`./transform_providers.sh\` (if Type B/C providers exist)
3. Run \`./generate_manual_indexes.sh\` (if tables >300k)
4. Follow KEYCLOAK_MIGRATION_PLAN.md

---

*Generated by kc_discovery.sh v${VERSION}*
EOF

    log_success "Report: $REPORT_FILE"
}

#######################################
# Main
#######################################
main() {
    parse_args "$@"
    load_config
    init_output

    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Migration Discovery Tool v${VERSION}                     ║"
    echo "║     Migration Path: KC 16 → KC 26                                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if $DRY_RUN; then
        echo -e "${YELLOW}>>> DRY-RUN MODE: No actual operations will be performed${NC}\n"
    fi

    if $USE_MOCK; then
        echo -e "${MAGENTA}>>> MOCK MODE: Using simulated data for testing${NC}\n"
    fi

    configure
    detect_keycloak_version
    discover_providers
    analyze_postgresql
    analyze_configuration
    generate_report

    echo ""
    log_section "DISCOVERY COMPLETE"
    echo -e "${GREEN}${BOLD}Output:${NC} $OUTPUT_DIR"
    echo -e "${GREEN}${BOLD}Report:${NC} $REPORT_FILE"
    echo -e "${GREEN}${BOLD}Log:${NC}    $LOG_FILE"
    echo ""
    echo -e "View: ${CYAN}cat $REPORT_FILE${NC}"
    echo ""

    if $USE_MOCK; then
        echo -e "${YELLOW}Note: This was a MOCK run. For real discovery, run without --mock${NC}"
    fi
}

main "$@"
