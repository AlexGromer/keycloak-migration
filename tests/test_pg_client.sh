#!/usr/bin/env bash
# Tests: pg_client / pg_client_available — PostgreSQL client autonomy (v3.9.7).
#
# Hermetic: the container engine is stubbed (cr / cr_available are overridden after
# sourcing), so nothing shells out to a real docker/podman, and the "host" tool is a
# throwaway script on a temp PATH. Proves:
#   - host fast path runs the host binary directly (unchanged behaviour);
#   - the autonomous path uses `cr run --rm -i --network=host`, forwards PGPASSWORD,
#     bind-mounts PG_CLIENT_MOUNT at the same path, and maps --user only on Docker;
#   - pg_client_available is true when EITHER the host binary OR the image is present.
#
# shellcheck disable=SC2329  # cr/cr_available are engine stubs invoked indirectly (by name) from pg_client
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_framework.sh"

LIB="$PROJECT_ROOT/scripts/lib/container_runtime.sh"

# Fixed-string membership as yes/no, safe for needles that start with '-'.
grepq() { printf '%s' "$1" | grep -qF -- "$2" && echo yes || echo no; }

describe "pg_client / pg_client_available (container_runtime.sh)"

if [[ ! -f "$LIB" ]]; then
    skip_test "container_runtime.sh not present"
    test_report
    exit $?
fi

TMPBIN="$(mktemp -d)"
trap 'rm -rf "$TMPBIN"' EXIT

# Source under a stubbed Docker runtime so nothing shells out to a real engine.
export CONTAINER_RUNTIME=docker
# shellcheck source=/dev/null
source "$LIB"

if ! declare -F pg_client >/dev/null 2>&1; then
    skip_test "pg_client() not defined (contract pending)"
    test_report
    exit $?
fi

# Stub the engine accessors so the container path never invokes a real engine.
cr() { echo "CR:$*"; }
cr_available() { return 0; }

# ---------------------------------------------------------------------------
# 1) HOST FAST PATH — a tool present on the host runs directly (not in a container).
# ---------------------------------------------------------------------------
cat > "$TMPBIN/pgc_faketool" <<'EOF'
#!/usr/bin/env bash
echo "HOST:$*"
EOF
chmod +x "$TMPBIN/pgc_faketool"
export PATH="$TMPBIN:$PATH"

assert_equals "HOST:hello world" "$(pg_client pgc_faketool hello world)" \
    "host fast path runs the host binary directly"

# ---------------------------------------------------------------------------
# 2) CONTAINER PATH — an absent tool routes through cr run with the right flags.
# ---------------------------------------------------------------------------
absent="pgc_absent_$$"
out="$(PGPASSWORD=secretpw PG_CLIENT_MOUNT=/var/backups pg_client "$absent" -h localhost -d keycloak -Fc)"
assert_equals "yes" "$(grepq "$out" 'run --rm -i --network=host')"       "container path: cr run --rm -i --network=host"
assert_equals "yes" "$(grepq "$out" '-e PGPASSWORD=secretpw')"           "container path: forwards inline PGPASSWORD"
assert_equals "yes" "$(grepq "$out" '-v /var/backups:/var/backups')"     "container path: bind-mounts PG_CLIENT_MOUNT at same path"
assert_equals "yes" "$(grepq "$out" "postgres:16 $absent -h localhost -d keycloak -Fc")" "container path: image, tool and args pass through"
assert_equals "yes" "$(grepq "$out" '--user ')"                          "container path: maps --user on rootful Docker"

# ---------------------------------------------------------------------------
# 3) Rootless Podman must NOT add --user (container-root already maps to caller).
# ---------------------------------------------------------------------------
CONTAINER_RUNTIME=podman
out_podman="$(pg_client "$absent" -h localhost)"
assert_equals "no" "$(grepq "$out_podman" '--user ')" "podman path omits --user"
CONTAINER_RUNTIME=docker

# ---------------------------------------------------------------------------
# 4) PROFILE_DB_PASSWORD fallback when no inline PGPASSWORD is set.
# ---------------------------------------------------------------------------
out_fb="$(PROFILE_DB_PASSWORD=fallbackpw pg_client "$absent")"
assert_equals "yes" "$(grepq "$out_fb" '-e PGPASSWORD=fallbackpw')" "falls back to PROFILE_DB_PASSWORD"

# ---------------------------------------------------------------------------
# 5) PROFILE_PG_CLIENT_NETWORK override.
# ---------------------------------------------------------------------------
out_net="$(PROFILE_PG_CLIENT_NETWORK=kc-net pg_client "$absent")"
assert_equals "yes" "$(grepq "$out_net" '--network=kc-net')" "honors PROFILE_PG_CLIENT_NETWORK override"

# ---------------------------------------------------------------------------
# 6) pg_client_available — host binary present -> true.
# ---------------------------------------------------------------------------
assert_true "pg_client_available pgc_faketool" "available: true when the tool is on the host"

# ---------------------------------------------------------------------------
# 7) pg_client_available — absent host tool but the image has it (cr image inspect ok) -> true.
# ---------------------------------------------------------------------------
cr() { [[ "${1:-} ${2:-}" == "image inspect" ]] && return 0; echo "CR:$*"; }
assert_true "pg_client_available $absent" "available: true when only the container image provides it"

# ---------------------------------------------------------------------------
# 8) pg_client_available — absent host tool AND no runtime -> false.
# ---------------------------------------------------------------------------
cr_available() { return 1; }
assert_false "pg_client_available $absent" "available: false when neither host nor container runtime has it"

test_report
exit $?
