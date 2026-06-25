#!/usr/bin/env bash
# Distribution Mode Handler for Keycloak v3.0
# Handles download, predownloaded, container, and helm distribution modes

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://github.com/keycloak/keycloak/releases/download}"
ARCHIVE_DIR="${ARCHIVE_DIR:-./keycloak_archives}"
EXTRACT_DIR="${EXTRACT_DIR:-./keycloak_installations}"
AIRGAP_MODE="${AIRGAP_MODE:-false}"

# Locate sibling libraries (derive from BASH_SOURCE — this file had no LIB_DIR).
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR}"

# Container runtime abstraction (podman/docker) — provides cr(), cr_compose,
# cr_detect, cr_available. All container engine calls below route through cr().
# shellcheck source=/dev/null
[[ -f "$LIB_DIR/container_runtime.sh" ]] && source "$LIB_DIR/container_runtime.sh"

# ============================================================================
# Image Reference — single source of truth for container image refs
# ============================================================================

dist_image_ref() {
    # Echo the full image ref for a Keycloak version.
    #   PROFILE_CONTAINER_IMAGE_REF set → use it, replacing literal {version}
    #   else ${PROFILE_CONTAINER_REGISTRY:-quay.io}/${PROFILE_CONTAINER_IMAGE:-keycloak/keycloak}:<version>
    local v="$1"

    if [[ -n "${PROFILE_CONTAINER_IMAGE_REF:-}" ]]; then
        printf '%s\n' "${PROFILE_CONTAINER_IMAGE_REF//\{version\}/$v}"
    else
        local registry="${PROFILE_CONTAINER_REGISTRY:-quay.io}"
        local image="${PROFILE_CONTAINER_IMAGE:-keycloak/keycloak}"
        printf '%s\n' "${registry}/${image}:${v}"
    fi
}

# ============================================================================
# Airgap Mode — Validate Offline Readiness
# ============================================================================

dist_validate_airgap() {
    # Called at startup to verify all required artifacts are available offline
    local migration_path=("$@")

    log_info "Airgap mode: validating local artifacts..."

    local mode="${PROFILE_KC_DISTRIBUTION_MODE:-download}"
    local missing=0

    case "$mode" in
        download|predownloaded)
            # Check all archives exist locally
            for version in "${migration_path[@]}"; do
                local archive="${ARCHIVE_DIR}/keycloak-${version}.tar.gz"
                local archive_zip="${ARCHIVE_DIR}/keycloak-${version}.zip"
                if [[ -f "$archive" || -f "$archive_zip" ]]; then
                    log_success "Archive available: keycloak-${version}"
                else
                    log_error "Archive missing: keycloak-${version} (need $archive)"
                    missing=$((missing + 1))
                fi
            done
            ;;
        container)
            # If a saved-image tar is configured for offline load, it must exist.
            if [[ -n "${PROFILE_CONTAINER_IMAGE_TAR:-}" && ! -f "$PROFILE_CONTAINER_IMAGE_TAR" ]]; then
                log_error "Container image tar configured but missing: $PROFILE_CONTAINER_IMAGE_TAR"
                missing=$((missing + 1))
            fi
            # Each image must be present locally, or loadable from the tar.
            for version in "${migration_path[@]}"; do
                local full_image
                full_image="$(dist_image_ref "$version")"
                if cr image inspect "$full_image" &>/dev/null; then
                    log_success "Image available: $full_image"
                elif [[ -n "${PROFILE_CONTAINER_IMAGE_TAR:-}" && -f "$PROFILE_CONTAINER_IMAGE_TAR" ]]; then
                    log_success "Image $full_image not loaded yet — will load from $PROFILE_CONTAINER_IMAGE_TAR"
                else
                    log_error "Image missing: $full_image"
                    missing=$((missing + 1))
                fi
            done
            ;;
        helm)
            if [[ ! -d "${PROFILE_HELM_CHART_PATH:-}" ]]; then
                log_error "Airgap helm: set PROFILE_HELM_CHART_PATH to local chart directory"
                missing=$((missing + 1))
            fi
            ;;
    esac

    if [[ $missing -gt 0 ]]; then
        log_error "Airgap validation failed: $missing artifact(s) missing"
        log_info "Prepare artifacts:"
        log_info "  Archives: place keycloak-VERSION.tar.gz in $ARCHIVE_DIR"
        log_info "  Containers: docker pull and docker save/load"
        return 1
    fi

    log_success "Airgap validation passed: all artifacts available"
    return 0
}

dist_check_network() {
    # Quick network reachability check before attempting download
    if [[ "${AIRGAP_MODE}" == "true" ]]; then
        log_warn "Airgap mode: skipping network check"
        return 1  # Signal: no network
    fi

    if curl -sf --max-time 5 --head https://github.com &>/dev/null; then
        return 0  # Network available
    else
        return 1  # No network
    fi
}

# ============================================================================
# Download Mode — Fetch from GitHub Releases
# ============================================================================

dist_download() {
    local version="$1"
    local install_path="$2"

    # Airgap guard: force fallback to predownloaded
    if [[ "${AIRGAP_MODE}" == "true" ]]; then
        log_warn "Airgap mode active: falling back to predownloaded"
        dist_predownloaded "$version" "$install_path"
        return $?
    fi

    # Network check before attempting download
    if ! dist_check_network; then
        log_warn "Network unreachable — attempting fallback to local archive"
        local local_archive="${ARCHIVE_DIR}/keycloak-${version}.tar.gz"
        if [[ -f "$local_archive" ]]; then
            log_info "Found local archive: $local_archive"
            dist_predownloaded "$version" "$install_path"
            return $?
        else
            log_error "No network and no local archive for Keycloak $version"
            log_info "Either restore network or place archive in: $ARCHIVE_DIR"
            return 1
        fi
    fi

    log_info "Download mode: Fetching Keycloak $version from GitHub"

    # Determine major version for URL format
    local major_version=$(echo "$version" | cut -d. -f1)

    local archive_name="keycloak-${version}.tar.gz"
    local download_url="${DOWNLOAD_BASE_URL}/${version}/${archive_name}"

    # For Keycloak 17+, use different archive naming
    if [[ "$major_version" -ge 17 ]]; then
        archive_name="keycloak-${version}.tar.gz"
    else
        # Keycloak 16 and earlier
        archive_name="keycloak-${version}.tar.gz"
    fi

    download_url="${DOWNLOAD_BASE_URL}/${version}/${archive_name}"

    log_info "URL: $download_url"

    # Download
    local tmp_archive="${ARCHIVE_DIR}/${archive_name}"
    mkdir -p "$ARCHIVE_DIR"

    if [[ -f "$tmp_archive" ]]; then
        log_warn "Archive already exists: $tmp_archive (reusing)"
    else
        log_info "Downloading to: $tmp_archive"

        if command -v wget &>/dev/null; then
            wget -q --show-progress "$download_url" -O "$tmp_archive" || {
                log_error "Download failed with wget"
                return 1
            }
        elif command -v curl &>/dev/null; then
            curl -L --progress-bar "$download_url" -o "$tmp_archive" || {
                log_error "Download failed with curl"
                return 1
            }
        else
            log_error "Neither wget nor curl available for download"
            return 1
        fi

        log_success "Downloaded: $tmp_archive"
    fi

    # Extract
    log_info "Extracting to: $install_path"
    mkdir -p "$install_path"

    tar -xzf "$tmp_archive" -C "$install_path" --strip-components=1 || {
        log_error "Extraction failed"
        return 1
    }

    log_success "Keycloak $version installed to: $install_path"
    return 0
}

# ============================================================================
# Predownloaded Mode — Use Local Archives
# ============================================================================

dist_predownloaded() {
    local version="$1"
    local install_path="$2"
    local archive_dir="${3:-$ARCHIVE_DIR}"

    log_info "Predownloaded mode: Using local archives from $archive_dir"

    # Find archive
    local archive_name="keycloak-${version}.tar.gz"
    local archive_path="${archive_dir}/${archive_name}"

    if [[ ! -f "$archive_path" ]]; then
        # Try alternative names
        archive_path="${archive_dir}/keycloak-${version}.zip"
    fi

    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive not found: $archive_path"
        log_error "Please ensure archive exists in $archive_dir"
        return 1
    fi

    log_info "Found archive: $archive_path"

    # Extract
    log_info "Extracting to: $install_path"
    mkdir -p "$install_path"

    if [[ "$archive_path" == *.tar.gz ]]; then
        tar -xzf "$archive_path" -C "$install_path" --strip-components=1
    elif [[ "$archive_path" == *.zip ]]; then
        if command -v unzip &>/dev/null; then
            unzip -q "$archive_path" -d "$install_path"
            # Move files up one level if extracted to subfolder
            # shellcheck disable=SC2012 # ls -d glob + head -1 preserves exact selection semantics; find would change behavior
            local extracted_dir=$(ls -d "$install_path"/keycloak-* 2>/dev/null | head -1)
            if [[ -d "$extracted_dir" ]]; then
                mv "$extracted_dir"/* "$install_path"/
                rmdir "$extracted_dir"
            fi
        else
            log_error "unzip not available for .zip extraction"
            return 1
        fi
    else
        log_error "Unsupported archive format: $archive_path"
        return 1
    fi

    log_success "Keycloak $version installed to: $install_path"
    return 0
}

# ============================================================================
# Container Mode — Pull/Update Container Image
# ============================================================================

dist_container() {
    local version="$1"
    local acquisition="${PROFILE_CONTAINER_ACQUISITION:-}"
    local pull_policy="${PROFILE_CONTAINER_PULL_POLICY:-IfNotPresent}"

    local full_image
    full_image="$(dist_image_ref "$version")"

    log_info "Container mode: Image $full_image (acquisition: ${acquisition:-pull}, policy: $pull_policy)"

    # Is the image already present locally?
    local image_exists=false
    if cr image inspect "$full_image" &>/dev/null; then
        image_exists=true
        log_info "Image exists locally: $full_image"
    fi

    case "$acquisition" in
        ""|pull|Always|IfNotPresent)
            # Acquire via registry pull, honoring pull policy. An explicit
            # acquisition of Always/IfNotPresent overrides PROFILE_CONTAINER_PULL_POLICY.
            local effective_policy="$pull_policy"
            case "$acquisition" in
                Always|IfNotPresent) effective_policy="$acquisition" ;;
            esac

            case "$effective_policy" in
                Always)
                    log_info "Pull policy: Always — pulling image..."
                    cr pull "$full_image" || {
                        log_error "Failed to pull image: $full_image"
                        return 1
                    }
                    log_success "Image pulled: $full_image"
                    ;;

                IfNotPresent)
                    if ! $image_exists; then
                        log_info "Pull policy: IfNotPresent — image not found, pulling..."
                        cr pull "$full_image" || {
                            log_error "Failed to pull image: $full_image"
                            return 1
                        }
                        log_success "Image pulled: $full_image"
                    else
                        log_info "Pull policy: IfNotPresent — using existing image"
                    fi
                    ;;

                Never)
                    if ! $image_exists; then
                        log_error "Pull policy: Never — image not found locally and pull disabled"
                        return 1
                    fi
                    log_info "Pull policy: Never — using existing image"
                    ;;

                *)
                    log_error "Unknown pull policy: $effective_policy"
                    return 1
                    ;;
            esac
            ;;

        load)
            # Air-gapped: load the image from a saved tar if not already present.
            if $image_exists; then
                log_info "Acquisition: load — image already present, skipping load"
            elif [[ -n "${PROFILE_CONTAINER_IMAGE_TAR:-}" && -f "$PROFILE_CONTAINER_IMAGE_TAR" ]]; then
                log_info "Acquisition: load — loading image from $PROFILE_CONTAINER_IMAGE_TAR"
                cr load -i "$PROFILE_CONTAINER_IMAGE_TAR" || {
                    log_error "Failed to load image tar: $PROFILE_CONTAINER_IMAGE_TAR"
                    return 1
                }
                if ! cr image inspect "$full_image" &>/dev/null; then
                    log_error "Image $full_image not found after loading $PROFILE_CONTAINER_IMAGE_TAR"
                    return 1
                fi
                log_success "Image loaded: $full_image"
            else
                log_error "Acquisition: load — image absent and PROFILE_CONTAINER_IMAGE_TAR unset/missing"
                return 1
            fi
            ;;

        preloaded|Never)
            # Image must already exist locally; never touch the network.
            if ! cr image inspect "$full_image" &>/dev/null; then
                log_error "Acquisition: preloaded — image not present locally: $full_image"
                return 1
            fi
            log_info "Acquisition: preloaded — using existing image: $full_image"
            ;;

        build)
            # Build the image locally from an Astra/RedOS base image.
            local base_image="${PROFILE_CONTAINER_BASE_IMAGE:-}"
            if [[ -z "$base_image" ]]; then
                log_error "Acquisition: build — PROFILE_CONTAINER_BASE_IMAGE is required"
                return 1
            fi

            # JDK per hop facts: 21 for KC 26.x, otherwise 17.
            local jdk
            if [[ "$version" == 26* ]]; then jdk=21; else jdk=17; fi

            log_info "Acquisition: build — building $full_image from base $base_image (jdk=$jdk)"

            if ! declare -F img_build >/dev/null 2>&1; then
                # shellcheck source=/dev/null
                [[ -f "$LIB_DIR/image_builder.sh" ]] && source "$LIB_DIR/image_builder.sh"
            fi
            if ! declare -F img_build >/dev/null 2>&1; then
                log_error "img_build not available (image_builder.sh missing)"
                return 1
            fi

            img_build "$version" "$base_image" "$jdk" || {
                log_error "Build failed for $full_image"
                return 1
            }
            log_success "Image built: $full_image"
            ;;

        *)
            log_error "Unknown container acquisition mode: $acquisition (expected pull|load|preloaded|build)"
            return 1
            ;;
    esac

    # For container mode, "installation" means image is ready
    log_success "Container image ready: $full_image"
    return 0
}

# ============================================================================
# Container Update — Update Container/Deployment to New Version
# ============================================================================

dist_container_update() {
    local version="$1"
    local mode="${PROFILE_KC_DEPLOYMENT_MODE}"

    local full_image
    full_image="$(dist_image_ref "$version")"

    log_info "Updating container to version: $version (image: $full_image)"

    case "$mode" in
        run)
            # Ephemeral run mode: the migration tool boots the container itself
            # at service-start time. Nothing to update here — avoid double-boot.
            log_info "Deployment mode 'run': boot deferred to service start (no container update needed)"
            ;;

        docker|podman)
            local container_name="${PROFILE_KC_RUN_CONTAINER_NAME:-${PROFILE_KC_CONTAINER_NAME:-keycloak}}"

            # Capture current env and mounts so the replacement keeps its config.
            local env_args=() mount_args=()
            local captured=false
            if cr inspect "$container_name" &>/dev/null; then
                local env_lines mount_lines line
                env_lines="$(cr inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null || true)"
                mount_lines="$(cr inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}}{{println}}{{end}}' "$container_name" 2>/dev/null || true)"

                while IFS= read -r line; do
                    [[ -n "$line" ]] && env_args+=(-e "$line")
                done <<< "$env_lines"
                while IFS= read -r line; do
                    [[ "$line" == *:* ]] && mount_args+=(-v "$line")
                done <<< "$mount_lines"

                if [[ ${#env_args[@]} -gt 0 || ${#mount_args[@]} -gt 0 ]]; then
                    captured=true
                fi
            fi

            if $captured; then
                log_info "Captured $(( ${#env_args[@]} / 2 )) env var(s) and $(( ${#mount_args[@]} / 2 )) mount(s) from $container_name"

                cr stop "$container_name" 2>/dev/null || true
                cr rm "$container_name" 2>/dev/null || true

                cr run -d --name "$container_name" \
                    "${env_args[@]}" \
                    "${mount_args[@]}" \
                    "$full_image" || {
                    log_error "Failed to start replacement container with image: $full_image"
                    return 1
                }
                log_success "Container $container_name updated to image: $full_image"
                log_warn "Note: published ports/networks are NOT auto-captured — verify reachability"
            else
                # Inspect data insufficient — fall back to manual guidance.
                cr stop "$container_name" 2>/dev/null || true
                cr rm "$container_name" 2>/dev/null || true
                log_warn "Container mode update requires manual run with preserved config"
                log_info "Please update your run command to use image: $full_image"
            fi
            ;;

        docker-compose)
            local compose_file="${PROFILE_KC_COMPOSE_FILE:-docker-compose.yml}"

            # Update image in docker-compose.yml (in-place sed)
            log_warn "Updating $compose_file to use image: $full_image"

            # Backup compose file
            cp "$compose_file" "${compose_file}.bak"

            # Update image tag (simple sed replacement)
            # This assumes image line is like: image: keycloak/keycloak:16.1.1
            sed -i "s|image:.*keycloak.*:.*|image: $full_image|" "$compose_file"

            local compose_cmd="docker-compose"
            declare -F cr_compose >/dev/null 2>&1 && compose_cmd="$(cr_compose)"

            log_success "Updated $compose_file"
            log_info "Restart with: $compose_cmd up -d"
            ;;

        kubernetes|deckhouse)
            local namespace="${PROFILE_K8S_NAMESPACE:-keycloak}"
            local deployment="${PROFILE_K8S_DEPLOYMENT:-keycloak}"

            # Use kubectl set image
            kubectl set image deployment/"$deployment" \
                keycloak="$full_image" \
                -n "$namespace" || {
                log_error "Failed to update Kubernetes deployment image"
                return 1
            }

            log_success "Deployment updated to: $full_image"
            log_info "Rollout will start automatically"
            ;;

        *)
            log_error "Container update not supported for mode: $mode"
            return 1
            ;;
    esac

    return 0
}

# ============================================================================
# Helm Mode — Upgrade via Helm Chart
# ============================================================================

dist_helm() {
    local version="$1"
    local release_name="${PROFILE_HELM_RELEASE:-keycloak}"
    local namespace="${PROFILE_K8S_NAMESPACE:-keycloak}"
    local chart="${PROFILE_HELM_CHART:-codecentric/keycloak}"

    log_info "Helm mode: Upgrading release $release_name to version $version"

    if ! command -v helm &>/dev/null; then
        log_error "Helm not found. Please install Helm."
        return 1
    fi

    # Upgrade release
    helm upgrade "$release_name" "$chart" \
        --namespace "$namespace" \
        --set image.tag="$version" \
        --wait \
        --timeout 10m || {
        log_error "Helm upgrade failed"
        return 1
    }

    log_success "Helm release upgraded to version: $version"
    return 0
}

# ============================================================================
# Unified Distribution Handler
# ============================================================================

handle_distribution() {
    local version="$1"
    local mode="${PROFILE_KC_DISTRIBUTION_MODE:-download}"
    local install_path="${2:-${EXTRACT_DIR}/keycloak-${version}}"

    log_section "Distribution: $mode mode for Keycloak $version"

    case "$mode" in
        download)
            dist_download "$version" "$install_path"
            ;;

        predownloaded)
            dist_predownloaded "$version" "$install_path" "${ARCHIVE_DIR}"
            ;;

        container)
            # Pull image first
            dist_container "$version"

            # Then update deployment
            dist_container_update "$version"
            ;;

        helm)
            dist_helm "$version"
            ;;

        *)
            log_error "Unknown distribution mode: $mode"
            log_error "Supported: download, predownloaded, container, helm"
            return 1
            ;;
    esac

    return $?
}

# ============================================================================
# Export Functions
# ============================================================================

# Make functions available when sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f dist_image_ref
    export -f dist_download
    export -f dist_predownloaded
    export -f dist_container
    export -f dist_container_update
    export -f dist_helm
    export -f handle_distribution
fi
