#!/bin/bash
#
# Analyze Type C providers - find patterns that need manual migration
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Type C Provider Analysis ==="
echo ""

# Find latest discovery
discovery_dir=$(ls -dt "${SCRIPT_DIR}"/../discovery_* 2>/dev/null | head -1)

if [[ -z "$discovery_dir" ]]; then
    echo "ERROR: No discovery found. Run kc_discovery.sh first."
    exit 1
fi

echo "Using: $discovery_dir"
echo ""

# Find Type C providers
type_c_found=false

for summary in "$discovery_dir"/providers/*/summary.json; do
    [[ ! -f "$summary" ]] && continue

    mtype=$(grep '"migration_type"' "$summary" | cut -d'"' -f4)
    [[ "$mtype" != "C" ]] && continue

    type_c_found=true
    provider_dir=$(dirname "$summary")
    jar_name=$(grep '"name"' "$summary" | cut -d'"' -f4)

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Provider: $jar_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Find the JAR
    jar_file=$(find "$provider_dir" -name "*.jar" | head -1)

    if [[ -z "$jar_file" ]]; then
        echo "  JAR not found in $provider_dir"
        continue
    fi

    # Extract to temp
    temp_dir=$(mktemp -d)
    unzip -q "$jar_file" -d "$temp_dir" 2>/dev/null || true

    echo ""
    echo "PATTERNS TO FIX:"
    echo ""

    # Pattern 1: @Context injection
    echo "1. @Context injection (MUST REMOVE):"
    context_refs=$(grep -r -n "@Context" "$temp_dir" 2>/dev/null | grep -v ".class:" || true)
    if [[ -n "$context_refs" ]]; then
        echo "$context_refs" | head -10
        echo ""
        echo "   FIX: Remove @Context, use KeycloakSession instead:"
        echo "   ────────────────────────────────────────────────"
        echo "   // BEFORE"
        echo "   @Context private HttpServletRequest request;"
        echo ""
        echo "   // AFTER"
        echo "   KeycloakSession session = context.getSession();"
        echo "   HttpRequest request = session.getContext().getHttpRequest();"
        echo ""
    else
        echo "   (not found in source, may be in compiled .class)"
        # Check in .class files
        class_refs=$(grep -r -l "Context" "$temp_dir" --include="*.class" 2>/dev/null | wc -l || echo 0)
        echo "   Found in $class_refs .class files - decompile to verify"
    fi
    echo ""

    # Pattern 2: ResteasyClientBuilder
    echo "2. ResteasyClientBuilder (MUST REPLACE):"
    resteasy_refs=$(grep -r -n "ResteasyClientBuilder\|ResteasyClient" "$temp_dir" 2>/dev/null | grep -v ".class:" || true)
    if [[ -n "$resteasy_refs" ]]; then
        echo "$resteasy_refs" | head -10
        echo ""
        echo "   FIX: Replace with Jakarta ClientBuilder:"
        echo "   ────────────────────────────────────────────────"
        echo "   // BEFORE"
        echo "   ResteasyClientBuilder builder = new ResteasyClientBuilder();"
        echo "   ResteasyClient client = builder.build();"
        echo ""
        echo "   // AFTER"
        echo "   Client client = ClientBuilder.newClient();"
        echo ""
    else
        echo "   (not found in source)"
    fi
    echo ""

    # Pattern 3: javax.ws.rs imports
    echo "3. javax.ws.rs imports (AUTO-TRANSFORMABLE with Eclipse Transformer):"
    javax_ws=$(grep -r -h "javax\.ws\.rs" "$temp_dir" 2>/dev/null | sort -u | head -5 || true)
    if [[ -n "$javax_ws" ]]; then
        echo "$javax_ws"
        echo ""
        echo "   FIX: Run transform_providers.sh (automatic)"
    else
        echo "   (none found)"
    fi
    echo ""

    # Pattern 4: javax.servlet
    echo "4. javax.servlet (AUTO-TRANSFORMABLE):"
    javax_servlet=$(grep -r -h "javax\.servlet" "$temp_dir" 2>/dev/null | sort -u | head -5 || true)
    if [[ -n "$javax_servlet" ]]; then
        echo "$javax_servlet"
    else
        echo "   (none found)"
    fi
    echo ""

    # Summary
    echo "MIGRATION STEPS FOR THIS PROVIDER:"
    echo "───────────────────────────────────"
    echo "1. Get source code (decompile if needed: cfr, procyon, jadx)"
    echo "2. Fix @Context injection → KeycloakSession"
    echo "3. Fix ResteasyClientBuilder → ClientBuilder"
    echo "4. Run transform_providers.sh for javax→jakarta"
    echo "5. Rebuild with Keycloak 22+ dependencies"
    echo "6. Test on KC 22 staging"
    echo ""

    rm -rf "$temp_dir"
done

if [[ "$type_c_found" == "false" ]]; then
    echo "No Type C providers found. Good news!"
fi
