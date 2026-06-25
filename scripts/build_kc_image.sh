#!/usr/bin/env bash
# build_kc_image.sh — Operator pre-step: build (and optionally save) a Keycloak
# container image for a given hop version, FROM an Astra/RedOS base image.
#
# This is meant to be run BEFORE an air-gapped / build-mode migration, to stage
# the image the migration tool will later boot.
#
# Usage:
#   build_kc_image.sh --version VER --base-image IMG [options]
#
# Options:
#   --version VER         Keycloak version to build (required), e.g. 24.0.5
#   --base-image IMG      Base image (Astra/RedOS) for FROM (required)
#   --jdk N               OpenJDK major version (default: 21 if VER starts 26, else 17)
#   --save TAR            Also export the built image to TAR (docker/podman save)
#   --containerfile FILE  Containerfile to use (default: containerfiles/Containerfile.kc)
#   -h, --help            Show this help and exit
#
# Make executable with:  chmod +x scripts/build_kc_image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
[[ -f "$LIB_DIR/container_runtime.sh" ]] && source "$LIB_DIR/container_runtime.sh"
# shellcheck source=/dev/null
[[ -f "$LIB_DIR/distribution_handler.sh" ]] && source "$LIB_DIR/distribution_handler.sh"
# shellcheck source=/dev/null
[[ -f "$LIB_DIR/image_builder.sh" ]] && source "$LIB_DIR/image_builder.sh"

usage() {
    cat <<'EOF'
build_kc_image.sh — build a Keycloak container image from an Astra/RedOS base.

Usage:
  build_kc_image.sh --version VER --base-image IMG [options]

Options:
  --version VER         Keycloak version to build (required), e.g. 24.0.5
  --base-image IMG      Base image (Astra/RedOS) for FROM (required)
  --jdk N               OpenJDK major version (default: 21 if VER starts 26, else 17)
  --save TAR            Also export the built image to TAR (docker/podman save)
  --containerfile FILE  Containerfile to use (default: containerfiles/Containerfile.kc)
  -h, --help            Show this help and exit

JDK note: Keycloak 26.x requires JDK 21; <= 25.x uses JDK 17.
EOF
}

main() {
    local version="" base_image="" jdk="" save_tar="" containerfile=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)       version="${2:-}"; shift 2 ;;
            --base-image)    base_image="${2:-}"; shift 2 ;;
            --jdk)           jdk="${2:-}"; shift 2 ;;
            --save)          save_tar="${2:-}"; shift 2 ;;
            --containerfile) containerfile="${2:-}"; shift 2 ;;
            -h|--help)       usage; return 0 ;;
            *)
                log_error "Unknown argument: $1"
                usage
                return 2
                ;;
        esac
    done

    if [[ -z "$version" || -z "$base_image" ]]; then
        log_error "--version and --base-image are required"
        usage
        return 2
    fi

    # Default JDK by hop facts: 21 for KC 26.x, otherwise 17.
    if [[ -z "$jdk" ]]; then
        if [[ "$version" == 26* ]]; then jdk=21; else jdk=17; fi
    fi

    if ! cr_available; then
        log_error "No container runtime (podman/docker) found"
        return 1
    fi

    if ! declare -F img_build >/dev/null 2>&1; then
        log_error "img_build not available (image_builder.sh not sourced)"
        return 1
    fi

    log_info "Building Keycloak ${version} image (base=${base_image}, jdk=${jdk})"

    if [[ -n "$containerfile" ]]; then
        img_build "$version" "$base_image" "$jdk" "$containerfile"
    else
        img_build "$version" "$base_image" "$jdk"
    fi

    local ref
    ref="$(dist_image_ref "$version")"
    log_success "Built image: $ref"

    if [[ -n "$save_tar" ]]; then
        img_save "$ref" "$save_tar"
    fi
}

main "$@"
