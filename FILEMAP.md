# FILEMAP — kk_migration

<!-- Auto-generated and manually maintained file map.
     Purpose: avoid redundant file searches, provide context to subagents.
     Update: on file create/delete/major refactor. -->

## Quick Reference

| Path | Purpose | Key Exports / Contents |
|------|---------|----------------------|
| scripts/migrate_keycloak_v3.sh | Primary migration entry point (v3) | main(), migrate(), validate() |
| scripts/migrate_keycloak_v2.sh | Migration script v2 (legacy reference) | — |
| scripts/migrate_keycloak.sh | Migration script v1 (legacy reference) | — |
| scripts/pre_flight_check.sh | Standalone preflight runner | run_checks() |
| scripts/backup_keycloak.sh | Keycloak backup utility | backup(), restore() |
| scripts/security_scan.sh | Security scanning runner | scan_all() |
| scripts/smoke_test.sh | Post-migration smoke tests | run_smoke_tests() |
| scripts/migration_monitor.sh | Migration progress monitoring | monitor_loop() |
| scripts/lib/audit_logger_v2.sh | Structured audit logging (SIEM-compatible) | log_event(), log_security() |
| scripts/lib/audit_logger.sh | Audit logging v1 (legacy) | log() |
| scripts/lib/backup_rotation.sh | Backup rotation management | rotate_backups() |
| scripts/lib/blue_green.sh | Blue/green deployment logic | switch_traffic(), rollback() |
| scripts/lib/canary.sh | Canary release management | deploy_canary(), promote() |
| scripts/lib/database_adapter.sh | DB connection + migration adapter | connect_db(), run_migration() |
| scripts/lib/db_optimizations.sh | Database query optimizations | optimize_indexes() |
| scripts/lib/deployment_adapter.sh | Generic deployment abstraction | deploy(), undeploy() |
| scripts/lib/distribution_handler.sh | KK image/dist acquisition: pull/load(tar)/preloaded/build + image-ref resolver | dist_image_ref(), dist_container(), handle_distribution() |
| scripts/lib/input_validator.sh | Input sanitization + validation | validate_input(), sanitize() |
| scripts/lib/k8s_secrets.sh | Kubernetes secrets management | get_secret(), set_secret() |
| scripts/lib/keycloak_discovery.sh | Keycloak endpoint/version discovery | discover_kc(), get_version() |
| scripts/lib/multi_tenant.sh | Multi-tenant realm management | create_tenant(), list_tenants() |
| scripts/lib/preflight_checks.sh | Pre-migration environment checks | check_prereqs(), validate_env() |
| scripts/lib/profile_manager.sh | Keycloak realm profile management | load_profile(), save_profile() |
| scripts/lib/prometheus_exporter.sh | Prometheus metrics export | export_metrics() |
| scripts/lib/rate_limiter.sh | API rate limiting | check_rate(), reset_rate() |
| scripts/lib/secrets_manager.sh | Secrets abstraction (Vault + K8s) | get_secret(), store_secret() |
| scripts/lib/security_checks.sh | Security posture validation | run_security_checks() |
| scripts/lib/traffic_switcher.sh | Traffic switching for blue/green | switch_to(), switch_back() |
| scripts/lib/validation.sh | Generic validation utilities | validate_json(), validate_url() |
| scripts/lib/vault_integration.sh | HashiCorp Vault integration | vault_read(), vault_write() |
| tests/test_rate_limiter.sh | Rate limiter tests | — |
| tests/test_secrets_manager.sh | Secrets manager tests | — |
| tests/test_security_checks.sh | Security checks tests | — |
| tests/test_database_adapter.sh | DB adapter tests | — |
| tests/test_input_validator.sh | Input validator tests | — |
| tests/test_preflight_checks.sh | Preflight check tests | — |
| tests/test_migration_logic.sh | Migration flow tests | — |
| tests/run_all_tests.sh | Test runner entry point | — |
| tests/test_framework.sh | Shared test utilities | assert_eq(), setup(), teardown() |
| ARCHITECTURE.md | System architecture overview | — |
| V3_ARCHITECTURE.md | v3-specific architecture details | — |
| KEYCLOAK_MIGRATION_PLAN.md | Migration runbook and plan | — |
| keycloak-16-24-26-upgrade-runbook.md | Version-specific upgrade steps | — |
| BACKLOG.md | Task backlog | — |
| CHANGELOG.md | Version history | — |
| SECURITY.md | Security policy | — |
| Dockerfile | Container image for migration runner | — |

| FILEMAP.md | Documentation | — |
| scripts/lib/container_runtime.sh | Container runtime abstraction (podman/docker autodetect) | cr(), cr_compose(), cr_detect(), cr_available() |
| containerfiles/Containerfile.kc | Multistage non-root (uid 1000) Quarkus KC image FROM Astra/RedOS base; builder runs `kc.sh build --db=postgres`, runtime = JRE-headless only | — |
| scripts/lib/image_builder.sh | Build KK-on-base images + save to tar | img_build(), img_save() |
| scripts/build_kc_image.sh | CLI helper to build/save a KK image (operator pre-step) | — |
| scripts/lib/migration_verify.sh | Layer-2 verification (MIGRATION_MODEL) + skipped-index recovery | kc_verify_migration_model(), kc_check_skipped_indexes() |
| tests/test_migration_verify.sh | Tests: Layer-2 verify + skipped indexes | — |
| tests/test_container_runtime.sh | Tests: runtime abstraction | — |
| tests/test_dist_image_ref.sh | Tests: image-ref resolution + override | — |
| scripts/harness/run_migration_harness.sh | Harness orchestrator: fresh PG → KC16 → seed → full hop chain (default dry-run) | harness_main(), harness_run_hop() |
| scripts/harness/lib/harness_runtime.sh | Harness: _step dry-run/live chokepoint + PG/KC16/network lifecycle | _step(), harness_pg_up(), harness_boot_base16() |
| scripts/harness/lib/harness_seed.sh | Harness: random kcadm seeder (realms/users/clients) | harness_seed() |
| scripts/harness/lib/harness_integrity.sh | Harness: per-hop row-count data-integrity gate | _harness_integrity_eval(), harness_baseline(), harness_integrity_check() |
| profiles/test-harness-sovereign.yaml | Profile: run+build topology for the migration harness | — |
| tests/test_migration_harness.sh | Tests: harness dry-run plan + non-mutation + integrity policy | — |
| config/images.conf.example | Operator-editable image config template (build bases, GHCR, USE/branded overrides); real images.conf gitignored | — |
| scripts/build_matrix.sh | Build/save/sha256/GHCR-publish the 4×2 KC×sovereign-OS matrix; default dry-run; reads config/images.conf | build_matrix_main() |
| tests/test_build_matrix.sh | Tests: build_matrix dry-run plan + config/USE override + non-mutation | — |
| containerfiles/Containerfile.kc16 | Multistage non-root (uid 1000) WildFly KC16 image; reuses official keycloak-containers 16.1.1 tooling (build-keycloak.sh installs postgres JDBC module; official change-database entrypoint wires datasource at boot) | — |
| .github/workflows/build-images.yml | workflow_dispatch self-hosted build+publish (private GHCR + Release tar.xz) | — |
| docs/AIRGAP.md | Air-gap runbook: configure → plan → build/export → transfer → consume (load/pull/preloaded) | — |
| docs/AIRGAP.md | Documentation | — |
| docs/MIGRATION_GUIDE.md | Documentation | — |
| scripts/migrate_oneshot.sh | Shell script | — |
| tests/test_profile_env_precedence.sh | Tests | — |
| tests/test_profile_save_container.sh | Tests | — |
| tests/test_noninteractive.sh | Tests | — |
| tests/test_config_wizard_run.sh | Tests | — |
| tests/test_migrate_oneshot.sh | Tests | — |
| tests/test_state_reconciliation.sh | Tests | — |
| tests/test_health_not_a_gate.sh | Tests | — |
| scripts/lib/data_integrity.sh | Shell script | — |
| tests/test_data_integrity.sh | Tests | — |
| tests/test_config_entrypoints.sh | Tests | — |
## Directory Structure

```
kk_migration/
├── scripts/              # Migration and utility scripts
│   ├── lib/              # Modular library components (22 modules)
│   ├── migrate_keycloak_v3.sh  # Primary entry point
│   └── *.sh              # Utility scripts
├── tests/                # Test suites
│   ├── integration/      # Integration tests
│   ├── security/         # Security-focused tests
│   ├── performance/      # Performance + stress tests
│   ├── rollback/         # Rollback scenario tests
│   └── benchmark/        # Benchmarks
├── docs/                 # Documentation
├── examples/             # Usage examples
│   ├── ansible/          # Ansible playbook examples
│   ├── cloud/            # Cloud deployment examples
│   ├── helm/             # Helm chart examples
│   ├── monitoring/       # Monitoring setup examples
│   └── terraform/        # Terraform module examples
├── profiles/             # Keycloak realm profiles
├── migration_workspace/  # Active migration working directory
└── memory/               # Claude agent memory
```

## Module Dependency Map

```
migrate_keycloak_v3.sh
  → lib/preflight_checks.sh
  → lib/input_validator.sh
  → lib/secrets_manager.sh
      → lib/vault_integration.sh
      → lib/k8s_secrets.sh
  → lib/database_adapter.sh
  → lib/keycloak_discovery.sh
  → lib/security_checks.sh
  → lib/audit_logger_v2.sh
  → lib/rate_limiter.sh
  → lib/blue_green.sh
      → lib/traffic_switcher.sh
  → lib/canary.sh
  → lib/backup_rotation.sh
  → lib/profile_manager.sh
  → lib/multi_tenant.sh
  → lib/prometheus_exporter.sh
```

## File Categories

### Entry Points
- `scripts/migrate_keycloak_v3.sh` — main migration CLI
- `scripts/pre_flight_check.sh` — standalone environment validator
- `scripts/smoke_test.sh` — post-migration validation
- `tests/run_all_tests.sh` — test suite runner

### Core Logic
- `scripts/lib/database_adapter.sh` — DB migration logic
- `scripts/lib/keycloak_discovery.sh` — KC API interaction
- `scripts/lib/profile_manager.sh` — realm config management
- `scripts/lib/multi_tenant.sh` — tenant orchestration

### Security & Secrets
- `scripts/lib/secrets_manager.sh` — secrets abstraction layer
- `scripts/lib/vault_integration.sh` — Vault-specific integration
- `scripts/lib/k8s_secrets.sh` — K8s secrets API
- `scripts/lib/security_checks.sh` — security posture validation
- `scripts/lib/input_validator.sh` — input sanitization
- `scripts/lib/rate_limiter.sh` — API rate limiting
- `scripts/lib/audit_logger_v2.sh` — audit trail

### Deployment
- `scripts/lib/blue_green.sh` — blue/green strategy
- `scripts/lib/canary.sh` — canary release
- `scripts/lib/traffic_switcher.sh` — traffic routing
- `scripts/lib/deployment_adapter.sh` — deployment abstraction

### Infrastructure
- `Dockerfile` — migration runner container
- `examples/terraform/` — Terraform modules
- `examples/helm/` — Helm charts
- `examples/ansible/` — Ansible playbooks

### Tests
- `tests/test_*.sh` — individual module tests (mapped 1:1 to lib/ modules)
- `tests/integration/` — end-to-end migration tests
- `tests/security/` — security-specific test scenarios
- `tests/rollback/` — rollback and recovery tests

## Metadata

- Generated: 2026-06-24
- Last updated: 2026-06-24
- File count: ~80+ (scripts, tests, docs)
- Auto-update hook: project-init (on significant changes)
