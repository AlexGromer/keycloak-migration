# BACKLOG

## Active

- [ ] Tier-3 architecture refactor: extract scripts/lib/logging.sh (638 log_* calls live only in callers); add source-guards to re-sourced libs; remove/integrate 3 unused libs + ~70 orphan functions (P3) @general-purpose — 2026-06-23
- [ ] [W1] Автоматизация миграции: F1 фикс IMAGE_REF clobber (profile_load env-wins), F4 неинтерактивный режим (--yes/ASSUME_DEFAULTS/_confirm), F3 генератор профиля (profile_save acquisition/runtime + config_wizard run+acquisition), F2 scripts/migrate_oneshot.sh; тесты + docs; ветка feat/migration-automation, PR, CI green, не мержить без ОК (P2) @systems-programmer — 2026-06-26

## Completed Archive

- [x] [W1] docs/MIGRATION_GUIDE.md — пользовательская пошаговая инструкция миграции Keycloak (Path A target 25: 16→25.0.6; Path B target 26: 16→24.0.5→26.6.3), harness dry-run/--go + real migrate --profile, верификация L1/L2/integrity, troubleshooting, rollback; PR на ветке docs/migration-guide, CI green, не мержить без ОК (P2) @tech-writer — 2026-06-26 ✓ 2026-06-26
- [x] Tier-2: db_optimizations.sh bash integer arithmetic on float db_size_gb (use bc); canary.sh validate-before-observe timing; secrets_manager.sh $AZURE_VAULT_NAME without :- default (set -u crash) (P3) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Tier-2: rate_limiter.sh ((failure_count++)) returns 1 under set -e (aborts); use failure_count=$((failure_count+1)) (P2) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Tier-2: security_checks.sh checks $? inside else-branch (always 0, not function rc) — capture rc explicitly (P2) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Triage 8 pre-existing failing test suites (blue_green, canary, multi_tenant, preflight_checks, input_validator, rate_limiter, secrets_manager, security_checks) — failing since before container-hop feature; classify env-dependency vs logic bug (P2) @test-writer — 2026-06-23 ✓ 2026-06-24

## Deferred

_No deferred tasks._
