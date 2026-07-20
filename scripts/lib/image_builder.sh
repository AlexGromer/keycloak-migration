#!/usr/bin/env bash
# image_builder.sh — Build & save Keycloak container images for the migration
# tool (the `build` acquisition mode). Engine calls go through cr() and image
# refs through dist_image_ref() so podman/docker and registry layout stay in one
# place.
#
# Exports:
#   img_build <version> <base_image> <jdk> [containerfile]
#       Build an image tagged "$(dist_image_ref <version>)" from the given base
#       image and JDK using the Containerfile (default containerfiles/Containerfile.kc).
#   img_save  <ref> <tar>
#       Export an image ref to a tar (for air-gapped transfer / `load`).

# Include guard
[[ -n "${_IMAGE_BUILDER_SH:-}" ]] && return 0
_IMAGE_BUILDER_SH=1

# ----------------------------------------------------------------------------
# Logging fallbacks (orchestrator normally provides these).
# ----------------------------------------------------------------------------
declare -F log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
declare -F log_warn    >/dev/null 2>&1 || log_warn()    { echo "[WARN] $*"; }
declare -F log_error   >/dev/null 2>&1 || log_error()   { echo "[ERROR] $*" >&2; }
declare -F log_success >/dev/null 2>&1 || log_success() { echo "[OK] $*"; }

# ----------------------------------------------------------------------------
# Defensive sourcing of dependencies (cr from container_runtime.sh,
# dist_image_ref from distribution_handler.sh). Include guards make this cheap
# if the orchestrator already sourced them.
# ----------------------------------------------------------------------------
_IMG_LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
# shellcheck source=/dev/null
[[ -f "$_IMG_LIB_DIR/container_runtime.sh" ]] && source "$_IMG_LIB_DIR/container_runtime.sh"
# shellcheck source=/dev/null
[[ -f "$_IMG_LIB_DIR/distribution_handler.sh" ]] && source "$_IMG_LIB_DIR/distribution_handler.sh"

# ----------------------------------------------------------------------------
# img_build <version> <base_image> <jdk> [containerfile]
# ----------------------------------------------------------------------------
img_build() {
    local v="$1"
    local base="$2"
    local jdk="$3"
    local cf="${4:-containerfiles/Containerfile.kc}"

    if [[ -z "$v" || -z "$base" || -z "$jdk" ]]; then
        log_error "img_build: usage: img_build <version> <base_image> <jdk> [containerfile]"
        return 2
    fi

    if ! declare -F dist_image_ref >/dev/null 2>&1; then
        log_error "img_build: dist_image_ref not available (distribution_handler.sh not sourced)"
        return 1
    fi

    local ref
    ref="$(dist_image_ref "$v")"

    # Reuse an image that is already on the host instead of rebuilding it from a base OS.
    #
    # The harness was Phase-1 build-only: every hop rebuilt FROM the sovereign base (Astra/RED OS).
    # That base is licensed and not always present — in this repo it is a placeholder ref that does
    # not exist — so a live harness run against images that were ALREADY built and loaded died at
    # the build step. When IMG_SKIP_IF_PRESENT=true and the target image is present, use it.
    if [[ "${IMG_SKIP_IF_PRESENT:-false}" == "true" ]] && cr image inspect "$ref" >/dev/null 2>&1; then
        log_info "Reusing image already present: $ref (IMG_SKIP_IF_PRESENT=true, no rebuild)"
        return 0
    fi

    log_info "Building Keycloak image: $ref (base=$base, jdk=$jdk, containerfile=$cf)"

    cr build \
        --build-arg KC_BASE_IMAGE="$base" \
        --build-arg KC_VERSION="$v" \
        --build-arg JDK_VERSION="$jdk" \
        -t "$ref" \
        -f "$cf" \
        . || {
        log_error "Image build failed: $ref"
        return 1
    }

    log_success "Image built: $ref"
}

# ----------------------------------------------------------------------------
# img_save <ref> <tar>
# ----------------------------------------------------------------------------
img_save() {
    local ref="$1"
    local tar="$2"

    if [[ -z "$ref" || -z "$tar" ]]; then
        log_error "img_save: usage: img_save <ref> <tar>"
        return 2
    fi

    log_info "Saving image $ref -> $tar"
    cr save -o "$tar" "$ref" || {
        log_error "Image save failed: $ref -> $tar"
        return 1
    }
    log_success "Image saved: $tar"
}

# Make functions available to subshells when sourced.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f img_build
    export -f img_save
fi
