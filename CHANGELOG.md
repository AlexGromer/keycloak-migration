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

## [3.9.1] - 2026-06-29

### Fixed
- **CRITICAL — `migrate_oneshot.sh` could delete a caller-supplied work dir.** The EXIT trap ran
  `rm -rf "$ONESHOT_WORK_DIR"` unconditionally, so e.g. `ONESHOT_WORK_DIR=/data migrate_oneshot.sh
  --help` would wipe `/data`. Now only a scratch dir the script itself created (`mktemp`) is ever
  removed; a caller-supplied `--work-dir` / `ONESHOT_WORK_DIR` is **never** deleted. Regression
  tests added.

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
