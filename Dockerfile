# Keycloak Migration Tool — Docker Image
# Containerized migration tool for CI/CD and cloud environments

FROM ubuntu:22.04

LABEL maintainer="AlexGromer <alexei.pape@yandex.ru>"
LABEL description="Keycloak Migration Tool v3.0 — Universal migration framework"
LABEL version="3.0.0"

# ============================================================================
# Install Dependencies
# ============================================================================

RUN apt-get update && apt-get install -y \
    bash \
    curl \
    git \
    jq \
    postgresql-client \
    mysql-client \
    python3 \
    python3-pip \
    openjdk-11-jre \
    openjdk-17-jre \
    openjdk-21-jre \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Install kubectl (for Kubernetes deployments)
# ============================================================================

RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

# ============================================================================
# Install Helm (for Helm-based deployments)
# ============================================================================

RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ============================================================================
# Copy Migration Tool
# ============================================================================

WORKDIR /opt/keycloak-migration

# Copy scripts and libraries
COPY scripts/ ./scripts/
COPY profiles/ ./profiles/
COPY tests/ ./tests/

# Copy documentation
COPY README.md CONTRIBUTING.md CHANGELOG.md LICENSE SECURITY.md ./
COPY V3_*.md QUICK_START.md AUTO_DISCOVERY_DEMO.md ./ 2>/dev/null || true

# Set executable permissions
RUN chmod +x scripts/*.sh scripts/lib/*.sh tests/*.sh

# ============================================================================
# Environment Variables
# ============================================================================

ENV PATH="/opt/keycloak-migration/scripts:${PATH}"
ENV WORK_DIR="/data"
ENV AUDIT_ENABLED="true"
ENV AUDIT_LOG_FILE="/data/migration_audit.jsonl"

# ============================================================================
# Create Data Volume
# ============================================================================

RUN mkdir -p /data
VOLUME ["/data"]

# ============================================================================
# Healthcheck
# ============================================================================

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD bash --version || exit 1

# ============================================================================
# Default Entrypoint
# ============================================================================

ENTRYPOINT ["/opt/keycloak-migration/scripts/migrate_keycloak_v3.sh"]
CMD ["--help"]
