# BACKLOG

## Active

- [ ] Tier-3 architecture refactor: extract scripts/lib/logging.sh (638 log_* calls live only in callers); add source-guards to re-sourced libs; remove/integrate 3 unused libs + ~70 orphan functions (P3) @general-purpose — 2026-06-23
- [ ] [W1] Автоматизация миграции: F1 фикс IMAGE_REF clobber (profile_load env-wins), F4 неинтерактивный режим (--yes/ASSUME_DEFAULTS/_confirm), F3 генератор профиля (profile_save acquisition/runtime + config_wizard run+acquisition), F2 scripts/migrate_oneshot.sh; тесты + docs; ветка feat/migration-automation, PR, CI green, не мержить без ОК (P2) @systems-programmer — 2026-06-26
- [ ] [2] [W2] Поток A: 4 docx поставки (перегенерация HANDOVER с A2 + 3 дока из QUICKSTART/MIGRATION_GUIDE/AIRGAP) + QA-гейт ×4 (P2) @tech-writer — 2026-07-21
- [ ] [3] [W3] Поток C: air-gap релиз — расширить build-images.yml под 2 приватных per-OS prerelease (alsebased/redosbased) + гард размера (P2) @ci-cd-engineer — 2026-07-21
- [ ] [1] [W1.5] Суверенный pg-client образ (ALSE+RED OS база + postgresql-client мажора сервера): containerfiles, per-OS дефолт PROFILE_PG_CLIENT_IMAGE, интеграция в build-images.yml + air-gap бандл, ADR. Собирается на sovereign-раннере (P1) @ci-cd-engineer — 2026-07-21
- [ ] [1] ПУНКТ 3 (Поток C): air-gap per-OS prerelease + суверенный pg-client в бандле (build-images.yml + build_bundle.sh + migrate_oneshot.sh + tests + AIRGAP/ADR-014) (P1) @ci-cd-engineer — 2026-07-22

## Completed Archive

- [x] [1] [W1] Полный паритет лока: контейнеризованный advisory-lock в db_lock.sh (coproc через cr run --rm -i, release через cr rm -f, per-DB container name) — заменяет файловый fallback v1. Требует live-валидации (P1) @systems-programmer — 2026-07-21 ✓ 2026-07-22
- [x] [1] [W1] Поток B: автономность pg-клиента (helper pg_client + PROFILE_PG_CLIENT_IMAGE, маршрутизация call-sites, dep-checks, тесты) → v3.9.7 (P1) @systems-programmer — 2026-07-21 ✓ 2026-07-22
- [x] [W1] docs/MIGRATION_GUIDE.md — пользовательская пошаговая инструкция миграции Keycloak (Path A target 25: 16→25.0.6; Path B target 26: 16→24.0.5→26.6.3), harness dry-run/--go + real migrate --profile, верификация L1/L2/integrity, troubleshooting, rollback; PR на ветке docs/migration-guide, CI green, не мержить без ОК (P2) @tech-writer — 2026-06-26 ✓ 2026-06-26
- [x] Tier-2: db_optimizations.sh bash integer arithmetic on float db_size_gb (use bc); canary.sh validate-before-observe timing; secrets_manager.sh $AZURE_VAULT_NAME without :- default (set -u crash) (P3) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Tier-2: rate_limiter.sh ((failure_count++)) returns 1 under set -e (aborts); use failure_count=$((failure_count+1)) (P2) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Tier-2: security_checks.sh checks $? inside else-branch (always 0, not function rc) — capture rc explicitly (P2) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Triage 8 pre-existing failing test suites (blue_green, canary, multi_tenant, preflight_checks, input_validator, rate_limiter, secrets_manager, security_checks) — failing since before container-hop feature; classify env-dependency vs logic bug (P2) @test-writer — 2026-06-23 ✓ 2026-06-24

## Deferred

_No deferred tasks._
