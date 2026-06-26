# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- AWS RDS / GCP Cloud SQL / Azure Database migration examples
- Ansible playbook wrapper
- Terraform module
- Helm chart
- Sovereign KC16 runtime datasource validation (harness live run)

---

## [3.8.0] - 2026-06-26

### Added
- **Container-hop migration (v3.7):** boots a real Keycloak container per hop (16→24.0.5→26.6.3 / 16→25.0.6) and verifies Layer-1 (Liquibase / DATABASECHANGELOG) + Layer-2 (MIGRATION_MODEL advance). Container-runtime abstraction (podman/docker autodetect), single-host `run` topology, image acquisition (pull/load/preloaded/build), build helper. (ADR-001..005)
- **Migration test harness** (`scripts/harness/`): default dry-run walking the full chain (fresh PG → base KC16 → random kcadm seed → hops) with L1/L2 + per-hop row-count integrity; provably non-mutating.
- **Sovereign air-gap packaging:** build the Keycloak × {Astra Linux SE, RED OS} image matrix (`scripts/build_matrix.sh`, `containerfiles/Containerfile.kc{,16}`) → private GHCR + air-gap tarballs; file config `config/images.conf` (build-base + branded-image overrides). Runbook `docs/AIRGAP.md`, `build-images.yml` (workflow_dispatch, self-hosted). (ADR-006)
- CI: ShellCheck pinned to static 0.11.0 (local==CI).

### Changed
- **Quarkus images: multistage + non-root (uid 1000)** with `kc.sh build --db=postgres` baked at build time — KC_DB is a build-time option in KC 26, required for `start --optimized` against PostgreSQL. ~30% smaller (1.08GB → ~0.7GB). KC16 (WildFly) reuses official keycloak-containers 16.1.1 tooling.
- ShellCheck-clean across the tree; Tier-2 static-analysis fixes (rate_limiter, security_checks, db_optimizations, canary); yq flavor-agnostic profile checks.

### Fixed
- Empty-secret retrieval bug; `${AZURE_VAULT_NAME:-}` `set -u` guard; broken test assertions; build_matrix silent-success on failed builds (failure propagation); per-OS build JDK (Astra 17 / RED OS 21); GHCR image-name lowercasing; headless JDK (resolves RED OS dnf transaction conflict).

---

## [3.0.0] - 2026-01-29

### Added

**Core Architecture:**
- Multi-DBMS support: PostgreSQL, MySQL, MariaDB, Oracle, MSSQL
- Multi-deployment modes: Standalone, Docker, Docker Compose, Kubernetes, Deckhouse
- Profile-based YAML configuration system
- Auto-discovery engine for existing installations
- Distribution handler (download/predownloaded/container/helm)

**Adapter Pattern:**
- Database adapter abstraction layer (5 databases)
- Deployment adapter abstraction layer (5 deployment modes)
- Profile manager with YAML parsing
- Keycloak discovery module
- Audit logger with JSON structured logging

**Migration Strategies:**
- In-place migration (stop → migrate → start)
- Rolling update (zero-downtime for Kubernetes)
- Blue-green deployment (parallel environments)

**Production Features:**
- Pre-flight checks (disk, tools, Java versions, network, database)
- Atomic checkpoints with 8-step resume capability
- Auto-rollback on health check failure
- Airgap mode with artifact validation
- Non-interactive wizard for CI/CD
- Docker Compose section parsing
- Per-version Java validation with JAVA_HOME hints

**Testing:**
- Complete test framework (137 unit tests, 100% pass rate)
- Test suites: database_adapter, deployment_adapter, profile_manager, migration_logic
- Automated test runner with colored output

**CI/CD:**
- GitHub Actions workflow with 6 jobs
- Syntax check, ShellCheck linting, unit tests
- Secrets scan (Gitleaks), security audit, profile validation
- Branch protection for main branch
- Auto-merge configuration

**Documentation:**
- Comprehensive README with quick start, examples, architecture
- CONTRIBUTING.md with development standards
- Branch protection setup guide
- Auto-discovery demo
- Architecture documentation

**Profiles:**
- 4 example profiles: standalone-postgresql, standalone-mysql, docker-compose-dev, kubernetes-cluster-production
- YAML validation and loading tests

### Migration Path
- Keycloak 16.1.1 → 17.0.1 → 22.0.5 → 25.0.6 → 26.0.7
- Java requirements: 11 → 11 → 17 → 17 → 21 (auto-validated)

### Technical Details
- **Language:** Bash 5.0+
- **Total Lines:** 18,138 (code + tests + docs)
- **Scripts:** 16 bash scripts
- **Libraries:** 7 adapter modules
- **Profiles:** 4 YAML configurations
- **Tests:** 137 unit tests in 4 suites
- **Documentation:** 10+ markdown files

---

## [2.0.0] - Previous Version

### Added
- Basic migration workflow
- PostgreSQL support
- Standalone deployment mode
- Manual configuration

### Changed
- Improved error handling
- Enhanced backup procedures

---

## [1.0.0] - Initial Release

### Added
- Initial Keycloak migration script
- Basic database backup/restore
- Simple version upgrade logic

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
