# Project: kk_migration

## Type
devops

## Stack
Bash/Shell, Keycloak, Kubernetes (kubectl), Docker, HashiCorp Vault, Terraform, Helm, Ansible, PostgreSQL

## Domains
- Keycloak migration (16 → 24/26)
- Infrastructure automation (K8s, Helm, Terraform)
- Secrets management (Vault, k8s secrets)
- Security hardening (input validation, rate limiting, audit logging)
- Blue/green + canary deployments
- Multi-tenancy, profile management

## Working Dir
/opt/kk_migration/

## Git
Active development — branch: main. Recent: v3.6.0 (Production Security Hardening).

## Sub-Directories
- scripts/        — main migration scripts (v1, v2, v3)
- scripts/lib/    — modular library components (22 modules)
- tests/          — test suites (unit, integration, security, performance, stress, rollback)
- docs/           — documentation
- examples/       — usage examples (ansible, cloud, helm, monitoring, terraform)
- profiles/       — Keycloak realm profiles
- migration_workspace/ — workspace for active migrations

## Key Files
- scripts/migrate_keycloak_v3.sh — primary migration script v3
- scripts/lib/secrets_manager.sh — secrets handling (Vault + K8s)
- scripts/lib/vault_integration.sh — HashiCorp Vault integration
- scripts/lib/k8s_secrets.sh — Kubernetes secrets management
- scripts/lib/security_checks.sh — security validation
- scripts/lib/input_validator.sh — input sanitization
- scripts/lib/preflight_checks.sh — pre-migration validation
- scripts/lib/audit_logger_v2.sh — structured audit logging
- scripts/lib/database_adapter.sh — DB connection/migration
- scripts/lib/rate_limiter.sh — rate limiting for API calls
- ARCHITECTURE.md — system architecture (see also V3_ARCHITECTURE.md)
- KEYCLOAK_MIGRATION_PLAN.md — migration runbook
- keycloak-16-24-26-upgrade-runbook.md — version-specific runbook

## Decisions
- v3 architecture uses modular lib/ pattern (22 modules, single-responsibility)
- Security hardening completed in v3.5 + v3.6 (rate limiting, input validation, vault)
- Blue/green + canary deployment strategy for zero-downtime migrations
- Audit logging v2 with structured output (SIEM-compatible)
- v3.7 container-hop migration: migration = boot a real KK container per hop; KK runs
  Liquibase (Layer 1) + RealmMigration (Layer 2) on startup. NOT pure-SQL.
- Verified hop path (research, 18 sources): target 26 = 16.x→24.0.5→26.6.3;
  target 25 = 16.x→25.0.6 (EOL warn). Forbidden: 26.6.0/26.6.1 (#48438/#47908). PG≥14 for 26.
- KK containers built FROM Astra/RedOS base images (sovereign OS, offline tar transfer,
  branded/bank image override). KK code is vanilla → no Jakarta recompile concern.
- Runtime abstraction CONTAINER_RUNTIME (podman/docker autodetect). Topologies: run/compose/k8s.
- Layer-2 authoritative gate: MIGRATION_MODEL.version must advance per hop (kc_verify_migration_model).

## In-Progress
- Branch feat/kc-container-hops: v3.7 container-hop feature COMPLETE & verified
  (DRY_RUN smoke green, 16 new tests pass, shellcheck clean, no regressions).
  Checkpoint 3fcd5fd = Tier-1 fixes. Feature commit pending. Unsigned (gpg pinentry timeout) — re-sign at push.
- Deferred Tier-2/Tier-3 + 8 pre-existing failing test suites → BACKLOG.md.
- New files: lib/container_runtime.sh, lib/migration_verify.sh, lib/image_builder.sh,
  build_kc_image.sh, containerfiles/Containerfile.kc + 3 test suites.
