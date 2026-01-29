#!/bin/bash
#
# Keycloak Provider Transformation Script
# Transforms javax.* → jakarta.* using Eclipse Transformer
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/../tools"
TRANSFORMER_JAR="${TOOLS_DIR}/eclipse-transformer.jar"
TRANSFORMER_VERSION="0.5.0"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#######################################
# Download Eclipse Transformer
#######################################
download_transformer() {
    mkdir -p "$TOOLS_DIR"

    if [[ ! -f "$TRANSFORMER_JAR" ]]; then
        log_info "Downloading Eclipse Transformer ${TRANSFORMER_VERSION}..."

        local url="https://repo1.maven.org/maven2/org/eclipse/transformer/org.eclipse.transformer.cli/${TRANSFORMER_VERSION}/org.eclipse.transformer.cli-${TRANSFORMER_VERSION}.jar"

        if curl -fsSL "$url" -o "$TRANSFORMER_JAR"; then
            log_success "Eclipse Transformer downloaded"
        else
            log_error "Failed to download Eclipse Transformer"
            exit 1
        fi
    else
        log_info "Eclipse Transformer already present"
    fi
}

#######################################
# Transform single JAR
#######################################
transform_jar() {
    local input_jar="$1"
    local output_dir="$2"
    local jar_name=$(basename "$input_jar")
    local output_jar="${output_dir}/${jar_name%.jar}-jakarta.jar"

    log_info "Transforming: $jar_name"

    if java -jar "$TRANSFORMER_JAR" "$input_jar" "$output_jar" -o 2>&1; then
        log_success "Created: $(basename "$output_jar")"

        # Verify transformation
        local javax_refs=$(unzip -p "$output_jar" "*.class" 2>/dev/null | strings | grep -c "javax\.ws\|javax\.persistence\|javax\.servlet" || echo "0")
        local jakarta_refs=$(unzip -p "$output_jar" "*.class" 2>/dev/null | strings | grep -c "jakarta\." || echo "0")

        log_info "  javax.* references: $javax_refs (should be 0)"
        log_info "  jakarta.* references: $jakarta_refs"

        if [[ "$javax_refs" != "0" ]]; then
            log_warn "  Some javax.* references remain - may need manual review"
        fi

        # Add beans.xml if missing
        if ! unzip -l "$output_jar" 2>/dev/null | grep -q "META-INF/beans.xml"; then
            log_info "  Adding beans.xml..."
            local temp_dir=$(mktemp -d)
            mkdir -p "$temp_dir/META-INF"
            echo '<?xml version="1.0" encoding="UTF-8"?><beans xmlns="https://jakarta.ee/xml/ns/jakartaee" bean-discovery-mode="all"></beans>' > "$temp_dir/META-INF/beans.xml"
            (cd "$temp_dir" && jar uf "$output_jar" META-INF/beans.xml)
            rm -rf "$temp_dir"
            log_success "  beans.xml added"
        fi

        return 0
    else
        log_error "Transformation failed for $jar_name"
        return 1
    fi
}

#######################################
# Main
#######################################
main() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║     Keycloak Provider Transformer (javax → jakarta)           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Check for discovery output
    local discovery_dirs=($(ls -d "${SCRIPT_DIR}"/../discovery_* 2>/dev/null | sort -r))

    if [[ ${#discovery_dirs[@]} -eq 0 ]]; then
        log_error "No discovery output found. Run kc_discovery.sh first."
        exit 1
    fi

    local latest_discovery="${discovery_dirs[0]}"
    log_info "Using discovery: $latest_discovery"

    # Find Type B and C providers
    local providers_to_transform=()

    for summary in "${latest_discovery}"/providers/*/summary.json; do
        if [[ -f "$summary" ]]; then
            local mtype=$(grep '"migration_type"' "$summary" | cut -d'"' -f4)
            if [[ "$mtype" == "B" ]] || [[ "$mtype" == "C" ]]; then
                local jar_path=$(grep '"path"' "$summary" | cut -d'"' -f4)
                providers_to_transform+=("$jar_path")
            fi
        fi
    done

    if [[ ${#providers_to_transform[@]} -eq 0 ]]; then
        log_success "No providers need javax→jakarta transformation"
        exit 0
    fi

    log_info "Found ${#providers_to_transform[@]} provider(s) to transform"

    # Download transformer
    download_transformer

    # Create output directory
    local output_dir="${SCRIPT_DIR}/../providers_transformed_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$output_dir"

    # Transform each provider
    local success=0
    local failed=0

    for jar in "${providers_to_transform[@]}"; do
        if transform_jar "$jar" "$output_dir"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    echo ""
    log_info "Transformation complete:"
    log_success "  Success: $success"
    [[ $failed -gt 0 ]] && log_error "  Failed: $failed"
    echo ""
    log_info "Transformed JARs: $output_dir"
    echo ""

    if [[ $failed -gt 0 ]]; then
        log_warn "Some providers failed transformation."
        log_warn "Type C providers (RESTEasy) may require manual code changes."
    fi
}

main "$@"
