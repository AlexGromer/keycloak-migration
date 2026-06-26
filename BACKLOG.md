# BACKLOG

## Active

- [ ] Tier-3 architecture refactor: extract scripts/lib/logging.sh (638 log_* calls live only in callers); add source-guards to re-sourced libs; remove/integrate 3 unused libs + ~70 orphan functions (P3) @general-purpose — 2026-06-23

## Completed Archive

- [x] Tier-2: db_optimizations.sh bash integer arithmetic on float db_size_gb (use bc); canary.sh validate-before-observe timing; secrets_manager.sh $AZURE_VAULT_NAME without :- default (set -u crash) (P3) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Tier-2: rate_limiter.sh ((failure_count++)) returns 1 under set -e (aborts); use failure_count=$((failure_count+1)) (P2) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Tier-2: security_checks.sh checks $? inside else-branch (always 0, not function rc) — capture rc explicitly (P2) @general-purpose — 2026-06-23 ✓ 2026-06-24
- [x] Triage 8 pre-existing failing test suites (blue_green, canary, multi_tenant, preflight_checks, input_validator, rate_limiter, secrets_manager, security_checks) — failing since before container-hop feature; classify env-dependency vs logic bug (P2) @test-writer — 2026-06-23 ✓ 2026-06-24

## Deferred

_No deferred tasks._
