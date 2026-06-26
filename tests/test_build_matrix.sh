#!/usr/bin/env bash
# Tests: build_matrix.sh — dry-run plan + config/USE override + non-mutation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_framework.sh"

WORK="$(mktemp -d)"

# Source the driver (its main is guarded -> not executed on source). This also
# sources container_runtime.sh (defining cr). Define record-and-fail stubs AFTER,
# so they shadow the real engines: any real call in dry-run fails the suite.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/build_matrix.sh"

CALL_LOG="$WORK/calls.log"; : > "$CALL_LOG"
cr()       { echo "cr $*"       >> "$CALL_LOG"; }
sha256sum() { echo "sha256sum $*" >> "$CALL_LOG"; }

# ============================================================================
describe "default dry-run plan (8 cells, build lines, no push)"
# ============================================================================
PLAN="$(build_matrix_main 2>&1)"
assert_equals "8" "$(echo "$PLAN" | grep -c 'DRY-RUN: build_kc_image.sh')" "8 build lines"
assert_equals "0" "$(echo "$PLAN" | grep -c 'DRY-RUN: cr push')"           "no push without --publish"
assert_contains "$PLAN" "ubi17:1.7"                  "astra KC16 base = ubi17:1.7"
assert_contains "$PLAN" "ubi18:1.8"                  "astra Quarkus base = ubi18:1.8"
assert_contains "$PLAN" "red-soft.ru"                "redos cells use RED OS registry"
assert_contains "$PLAN" "jdk=11"                     "KC16 builds with JDK 11"
assert_contains "$PLAN" "jdk=21"                     "Quarkus builds with JDK 21"
assert_contains "$PLAN" "Containerfile.kc16"         "KC16 uses the WildFly Containerfile"
assert_contains "$PLAN" "kc-astra-26.6.3.tar"        "saves per-cell tar"
assert_contains "$PLAN" "sha256sum dist/kc-astra-26.6.3.tar" "checksums the tar"

# JDK 11 only co-occurs with 16.1.1 (grep the 16.x build lines)
assert_true  "echo \"\$PLAN\" | grep '16.1.1' | grep -q 'jdk=11'"  "16.1.1 -> jdk=11"
assert_false "echo \"\$PLAN\" | grep '26.6.3' | grep -q 'jdk=11'"  "26.6.3 not jdk=11"

# ============================================================================
describe "--publish (still dry-run) adds push lines"
# ============================================================================
PUB="$(build_matrix_main --publish 2>&1)"
assert_equals "8" "$(echo "$PUB" | grep -c 'DRY-RUN: cr push ghcr.io/')" "8 GHCR push lines"
assert_contains "$PUB" "DRY-RUN (incl. publish)" "mode reflects publish scope, still dry-run"

# ============================================================================
describe "migration-safety guard"
# ============================================================================
assert_false "build_matrix_main --versions 26.6.0 >/dev/null 2>&1" "26.6.0 FORBIDDEN -> non-zero"
assert_false "build_matrix_main --versions 26.6.1 >/dev/null 2>&1" "26.6.1 FORBIDDEN -> non-zero"
assert_true  "build_matrix_main --versions 26.6.3 >/dev/null 2>&1" "26.6.3 allowed"

# ============================================================================
describe "config file overrides base; CLI overrides config"
# ============================================================================
cat > "$WORK/i.conf" <<'EOF'
ASTRA_BASE="registry.custom/astra:9.9"
EOF
CFG="$(build_matrix_main --config "$WORK/i.conf" 2>&1)"
assert_contains "$CFG" "registry.custom/astra:9.9" "config ASTRA_BASE applied"
CLI="$(build_matrix_main --config "$WORK/i.conf" --astra-base registry.cli/astra:1.0 2>&1)"
assert_contains "$CLI" "registry.cli/astra:1.0" "CLI --astra-base overrides config"

# ============================================================================
describe "USE_IMAGE override switches a cell to branded consume"
# ============================================================================
cat > "$WORK/use.conf" <<'EOF'
USE_IMAGE_astra_26_6_3="registry.local/kk-branded:26.6.3-astra"
EOF
USE="$(build_matrix_main --config "$WORK/use.conf" 2>&1)"
assert_contains "$USE" "mode=USE  branded=registry.local/kk-branded:26.6.3-astra" "cell flips BUILD->USE"
assert_contains "$USE" "DRY-RUN: cr pull registry.local/kk-branded:26.6.3-astra"  "USE cell consumes branded ref"

# ============================================================================
describe "non-mutation guarantee"
# ============================================================================
assert_true "[[ ! -s '$CALL_LOG' ]]" "dry-run invoked ZERO real cr/sha256sum calls"

# ============================================================================
rm -rf "$WORK"
test_report
