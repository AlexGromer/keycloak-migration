# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

Every fix below is in a deployment mode **other than `run`**. The v3.9.1 work was developed and
live-tested only on `run`; the other five modes (`standalone`, `docker`/`podman`, `docker-compose`,
`kubernetes`, `deckhouse`) never received it, and carried the defects live.

- **CRITICAL — a health probe rolled back a migration that had already SUCCEEDED.** The probe
  hardcoded `http://localhost:8080/health`. Keycloak 24+ serves that only with
  `KC_HEALTH_ENABLED=true`, and from KC 25 health moved to the management port 9000 — so the probe
  404'd on *every* supported hop. A 404 counted as "unhealthy", and an unhealthy check restored the
  pre-hop backup over a migration `MIGRATION_MODEL` had already confirmed. Worse, it did so
  silently: the prompt `_confirm "Rollback to last backup?" "Y"` auto-answers its **default** in any
  non-TTY (CI, cron, pipe) and under `--yes`, which `migrate_oneshot.sh` always passes.
  Health is now diagnostic only (ADR-009): it returns OK / NOT_SERVED / UNCONFIRMED, probes the port
  the version actually serves, and never gates a hop. The rollback offer moved to the L2 gate — the
  only place the database itself says the migration failed — and defaults to **N**.
- **CRITICAL — checkpoints outlived the rollback that undid them.** `CHECKPOINT_<v>=migrated` was
  written before the health check and survived the restore, so the next run skipped backup/stop/start
  for a migration the restore had just erased. `cmd_rollback_auto` now derives the hop from the
  backup filename and clears its checkpoints (`clear_checkpoint`).
- **CRITICAL — the docker/podman image update destroyed the container it could not rebuild.** On
  insufficient `inspect` data it ran `cr stop` + `cr rm` on the user's Keycloak, logged "please
  update your run command manually" over the wreckage, and returned 0. It is now fail-closed:
  nothing is removed until a full recreate set is in hand. Published ports and networks are captured
  too (the replacement previously came up with neither, unreachable from host and database alike),
  and `PROFILE_KC_RUN_CONTAINER_NAME` — the *transient* `run`-mode container — no longer leaks into
  docker/podman mode and gets the wrong container recreated.
- **Backup rotation never found a single backup.** Hop backups were written flat into `$WORK_DIR`
  while rotation swept `$WORK_DIR/backups` — a different directory. Every run logged
  `Found 0 backup(s)` and deleted nothing; a four-hop migration of a large database left four dumps
  on disk forever. Both now go through `kc_backup_dir()`. Safety backups stay outside it: rotation
  globs `*.dump` and would prune the emergency copy taken moments before a restore.
- **Ctrl-C left production down.** Non-`run` modes stop the real Keycloak at Step 2 and restart it
  at Step 5. An interrupt in that window exited without undoing the stop — `systemctl stop keycloak`
  left standing, or `kubectl scale --replicas=0` left standing, i.e. production scaled to zero with
  nobody putting it back. The interrupt handler now restarts what it stopped, and if it cannot, says
  so loudly with the exact command to run by hand.

### Planned
- AWS RDS / GCP Cloud SQL / Azure Database migration examples
- Ansible playbook wrapper
- Terraform module
- Helm chart
- Sovereign KC16 runtime datasource validation (harness live run)

---

## [3.9.1] - 2026-06-29

### Fixed
- **CRITICAL — `migrate_oneshot.sh` could delete a caller-supplied work dir.** The EXIT trap ran
  `rm -rf "$ONESHOT_WORK_DIR"` unconditionally, so e.g. `ONESHOT_WORK_DIR=/data migrate_oneshot.sh
  --help` would wipe `/data`. Now only a scratch dir the script itself created (`mktemp`) is ever
  removed; a caller-supplied `--work-dir` / `ONESHOT_WORK_DIR` is **never** deleted. Regression
  tests added.

- **CRITICAL — a stale checkpoint made the tool skip starting the container, then wait 15 minutes
  for logs from a container that was never created.** Checkpoints live in `WORK_DIR`, which
  survives between runs, so after a failed attempt the next run read `CHECKPOINT=started`, logged
  `Skipping start (already running)` and never ran `cr run` — even though the container had been
  removed. A checkpoint is a **claim, not a fact**: in `run` mode it is now verified against the
  actual container state and the hop is (re)started if the container is not really running. New
  `--no-resume` flag (also `migrate_oneshot.sh --no-resume`) ignores checkpoints outright.
- **The fail-fast container check never fired.** `docker inspect -f` on a **missing** container
  prints an empty line to stdout and exits 1, so `$(… || echo "missing")` produced `$'\nmissing'`
  and the `== "missing"` comparison never matched (the same class of bug as the `grep -c` one).
  It now strips whitespace and simply requires `running` — anything else (missing/exited/created/
  dead/paused) fails immediately — guarded with `|| true` so `set -o pipefail` cannot abort the run.
- **CRITICAL — the migrating container never started: Keycloak 24+ refuses to boot without a
  hostname setting.** `kc_run_migrating_container` passed only the `KC_DB*` env, so `start
  --optimized` died instantly with `Strict hostname resolution configured but no hostname setting
  provided` / `Failed to start quarkus` (exit 1) — Liquibase never ran, and the caller then waited
  out its 900s timeout. The transient migration container now gets `KC_HOSTNAME_STRICT=false` and
  `KC_HTTP_ENABLED=true` (nobody connects to it; it exists only to run L1+L2), overridable via
  `PROFILE_KC_RUN_HOSTNAME_STRICT` / `PROFILE_KC_RUN_HTTP_ENABLED` / `PROFILE_KC_RUN_HOSTNAME`.
  This affected **every** hop and target, and the harness too (same function).
- **CRITICAL — the post-hop health check would roll back a SUCCESSFUL migration.** In `run` mode it
  probed `http://localhost:8080/health` (KC 24+ does not expose it unless `KC_HEALTH_ENABLED=true`)
  and looked up `PROFILE_KC_CONTAINER_NAME` (the docker/compose name — empty here), so it failed and
  `migration_step` triggered a rollback of a migration that had just succeeded. Health check is now
  skipped in `run` mode: the container is transient and Layer 2 (`MIGRATION_MODEL`) is the
  authoritative gate (ADR-005).
- The standalone preflight DB-connectivity check now honours `PROFILE_DB_PASSWORD` too.
- `mysqldump`: exit code and empty-file are now checked (same data-safety rule as PostgreSQL).
- **CRITICAL — a FAILED backup was reported as SUCCESS and the migration proceeded anyway.**
  `db_backup()` ignored `pg_dump`'s exit code and downgraded a **failed** integrity check to a
  `Backup verification skipped` warning. The live run printed `Backup file is corrupted or invalid
  format` → `Backup verification skipped` → `[✓] Backup created` → `Backup size: 0`, and then
  migrated the database **holding a 0-byte backup**. Now the exit code is checked, an empty backup
  is fatal, and a failed verification is fatal (`ALLOW_UNVERIFIED_BACKUP=true` to override).
- **CRITICAL — every run-mode migration hung until the 900s timeout.** `wait_for_migration` read
  the container name from `PROFILE_KC_CONTAINER_NAME` (the YAML `container_name`, used by the
  docker/compose modes) while the transient container is actually named by
  `PROFILE_KC_RUN_CONTAINER_NAME` (default `kc-migrate-<version>`). `kc_logs` therefore fell back to
  the literal `keycloak`, found no container and returned no logs — so the Liquibase marker was
  never matched. It now derives the run-mode name and, if the container is exited/dead/missing,
  **fails immediately** with the container's last 30 log lines instead of spinning for 15 minutes.
- **Ctrl-C did not abort the migration** — there was no signal trap at all. `SIGINT`/`SIGTERM` now
  stop the transient container and exit 130, prompting the operator to check `MIGRATION_MODEL`.
- `migrate_oneshot.sh`: each hop now gets its own `kc-migrate-<version>` container.
- **CRITICAL — the pre-hop DB backup (and the rollback restore) never got the password.**
  `db_backup_keycloak` / `db_restore_keycloak` read only `PGPASSWORD` / `DB_PASSWORD` — **not**
  `PROFILE_DB_PASSWORD`, which is what the rest of the tool (container run, `_mv_psql`, PG-version
  gate) and the docs use. So `$pass` arrived empty and `pg_dump` fell back to its interactive
  `Password:` prompt, **hanging a non-interactive (`--yes`) migration forever** — and the same on
  the rollback path. Both now honour `PROFILE_DB_PASSWORD`, fail fast with an actionable message
  when it is unset, and `pg_dump`/`pg_restore` run with `-w` so they can never prompt at all.
- **The security scan no longer runs on every migration.** It is static analysis of *this tool's
  own source* (ShellCheck + gitleaks over `scripts/`) — it says nothing about the user's database,
  took ~20s, flooded the migration log, and reported "17 scripts with CRITICAL issues" that were
  merely **SC2155** style findings which the project's own CI explicitly excludes. Now **opt-in**:
  `--security-scan` / `ENABLE_SECURITY_SCAN=true`. When run, it uses CI's exclusion list.
- `security_checks.sh`: `$(grep -c … || echo "0")` yielded `"0\n0"` (grep -c already prints `0`
  *and* exits 1), so the next comparison died with
  `[[: 0\n0: arithmetic syntax error (error token is "0")`. Fixed.
- `audit_logger_v2.sh`: `jq --argjson` aborted with `invalid JSON text passed to --argjson` when
  the metadata/details value was empty; it now defaults to `{}`.
- `database_adapter.sh`: a stray `0` printed before each backup — `pg_estimate_backup_time()` logs
  to stdout *and* echoes its numeric result, which leaked to the console.
- **Preflight NETWORK check gave a FALSE "UNREACHABLE".** It grepped `nc`'s *message* for
  `succeeded|open`, but ncat (nmap) prints `Ncat: Connected to ...` — so on any host where `nc`
  is ncat/netcat-traditional the check failed even though `psql` connected to the very same
  `host:port` (the next check over). Now probes with bash's own `/dev/tcp` redirection
  (implementation-independent) and falls back to `nc -z` judged purely by **exit code**.
- **Preflight BACKUP SPACE crashed on a fractional DB size:**
  `((: .03: arithmetic syntax error: operand expected` — a small DB reports `.01` GB and bash
  arithmetic is integer-only. The comparison is now done in **megabytes** (awk does the float math).

### Added
- **State reconciliation (ADR-008) — the state is a FACT, not a journal.** `kc_reconcile_state()`
  now runs before the hop chain is planned and reads the **actual** system state instead of
  trusting claims about the past:
  - the version the database is really at (`SELECT version FROM MIGRATION_MODEL …`) — it **wins**
    over the profile's `current_version`, so **hops the DB has already passed are skipped** and a
    restart after a failure is idempotent;
  - a **stale Liquibase lock** (`DATABASECHANGELOGLOCK`, all of Keycloak's lock ids) left by a
    crashed migration — previously never checked, and it silently blocks every later Keycloak.
    Reported with the holder/time; `--force-unlock` releases it;
  - **leftover `kc-migrate-*` containers** from a failed attempt are listed and removed (they
    would otherwise clash on name);
  - if the DB is already at the target, the run is a clean no-op instead of a migration attempt.
- `--no-resume` (also `migrate_oneshot.sh --no-resume`) — ignore checkpoints entirely.
- `--force-unlock` (also `migrate_oneshot.sh --force-unlock`).
- `migrate_oneshot.sh --work-dir DIR` (safe — never deleted) and `--skip-preflight` passthrough.
  The banner now prints the work dir, its free space, and the preflight threshold.
- `MIN_DISK_GB` env override for the preflight free-space threshold (was hardcoded 15GB).

### Changed
- Preflight disk failure now reports **which** path was checked (`WORK_DIR`), **why** the space is
  needed (pre-hop DB dumps ≈ DB size × 3 — not container images), and **how** to fix it
  (`--work-dir` / `WORK_DIR` / `MIN_DISK_GB` / `--skip-preflight`). Previously it printed only
  "Disk space: NGB < 15GB required" with no path and no remedy.
- `docs/MIGRATION_GUIDE.md`: new "Свободное место на диске" section in the prerequisites.

---

## [3.9.0] - 2026-06-27

### Added
- **One-shot migration wrapper** `scripts/migrate_oneshot.sh`: acquire images (pull/bundle/preloaded)
  → generate a run+container profile → run the full migration non-interactively. Default dry-run;
  `--go` for live. Path A (target 25) / Path B (target 26). (ADR-007)
- **Non-interactive mode** for `migrate_keycloak_v3.sh`: `--yes`/`-y` flag + `ASSUME_DEFAULTS` env +
  a `_confirm` helper across confirmation prompts. The main gate is **fail-closed**: no TTY and no
  `--yes` → refuse (never migrate a real DB silently). Interactive behaviour unchanged. (ADR-007)
- `config_wizard.sh`: deployment-mode **Run (container-hop)**, image **acquisition** choice
  (pull/load/preloaded/build), target presets (25.0.6 / 26.6.3), env-honoring non-interactive mode.
- Tests: env-precedence, profile_save container block, non-interactive `_confirm`/gate, wizard
  run-profile, and `migrate_oneshot` dry-run/validation suites (24 suites total, all green).

### Changed
- **`profile_load` env precedence (ADR-007):** a pre-set `PROFILE_CONTAINER_IMAGE_REF` /
  `PROFILE_CONTAINER_IMAGE_TAR` / `PROFILE_CONTAINER_BASE_IMAGE` now WINS over YAML (the flat parser
  cannot store ':' refs). Real migrations consume the `<os>-<version>` sovereign tags **directly —
  no re-tag**. Backward compatible (empty env → YAML as before; harness unaffected).
- `profile_save` now emits `acquisition` and `runtime` in the container block.
- `docs/MIGRATION_GUIDE.md`: one-shot path, env-driven image ref (re-tag no longer required),
  `--yes`, wizard run support.

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
