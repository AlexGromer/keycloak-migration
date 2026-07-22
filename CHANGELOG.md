# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — non-root pg-client, DB connection string, non-public schema

- **The sovereign pg-client image runs non-root** (`USER 1000`, `Containerfile.pgclient`) — the KC hop
  images already did; now `psql`/`pg_dump`/`pg_restore` run as uid 1000 inside too, on both the
  Astra and RED OS builds. On rootful docker the tool still passes `--user <caller>` (dumps stay
  caller-owned); on rootless the image UID maps into the caller's user namespace. `astra-pgclient-17`
  / `redos-pgclient-17` rebuilt + re-pushed.
- **`--db-url` connection string** (`migrate_oneshot.sh`): `postgres://[user[:pass]@]host[:port]/db[?currentSchema=S]`
  parsed into the `PROFILE_DB_*` fields. Discrete `--db-host/--db-port/--db-name/--db-user/--db-schema`
  **override** the URL regardless of order (pre-scan). A password in the URL is accepted but warns
  (`PROFILE_DB_PASSWORD` / `--env-file` preferred — a URL password leaks via `ps` and shell history).
- **`--db-schema` (default `public`)** for Keycloak tables in a non-public PostgreSQL schema. Exports
  `PGOPTIONS="-c search_path=<schema>,public"` once — `pg_client` forwards it into the container and a
  host `psql` inherits it, so every query the tool runs (preflight, lock, verify, integrity) resolves
  in the right schema with no per-query change; the migration container gets `KC_DB_SCHEMA`.
  (`--db-port` was already supported.)
- **Rootless container-engine mode** (ADR-015, `docs/ROOTLESS.md`). The tool auto-detects a rootless
  Docker or Podman (`cr_is_rootless`) and adapts: rootless Podman + a bind mount gets
  `--userns=keep-id` (a non-root container writes **caller-owned** dumps); a rootless-Docker +
  loopback DB host is rewritten to `host.docker.internal` via `--add-host=…:host-gateway` (a rootless
  dockerd's `--network=host` is its own namespace, not the machine's). The rootful path is unchanged.
- **Streaming dump/restore** (`pg_client`): single-file archives (`-Fc`, the default) stream through
  the container's std streams — `pg_dump` → stdout → the caller's shell writes the file; `pg_restore`
  / `psql -f` read from stdin — so a **non-root** container produces **caller-owned** backups with **no
  bind mount** on any engine. This is what makes the default autonomous migration back up correctly
  under **rootless Docker** (where a bind-mount write lands as an unwritable subuid). The opt-in
  parallel directory format (`-Fd`) still uses the mount (Podman `--userns=keep-id`, or a writable
  work-dir). Live-validated on rootless **Podman** and rootless **Docker** (dump `rc=0` caller-owned,
  restore round-trip); detection + the stream/mount split covered by hermetic tests.

### Changed — air-gap delivery (ADR-014)

- Air-gap bundle now carries the **sovereign pg-client** image (`kc-<os>-pgclient-<major>.tar`):
  `build_bundle.sh` auto-includes it (optional — a missing one warns, does not fail) and
  `migrate_oneshot.sh --source bundle` loads it, so a fully air-gapped node with no host `psql`
  gets the client from the bundle itself (v3.9.7 autonomy default now reaches truly isolated nodes).
- `.github/workflows/build-images.yml`: builds `--pgclient`, packs one bundle per OS, and publishes
  **two private per-OS prereleases** (`alsebased`/`redosbased`) instead of one combined Release; a
  **2 GiB size-guard** delivers an over-cap bundle out-of-band from the runner's `dist/` (never
  split, never failed). New inputs `pg_client_major` (default `17`), `build_pgclient` (default
  `true`). Tool `VERSION` unchanged (CI/delivery only, no migration-logic change).

### Fixed

- **Preflight network check failed for a container-network DB on the autonomous path**
  (`preflight_checks.sh` `check_network_connectivity`). With no host `psql`, the migration reaches the
  DB through the pg-client **container** — which may sit on a container network the host cannot
  TCP-probe (a DB addressed by container name on a rootless-docker bridge). The host-level `/dev/tcp` /
  `nc` probe then reported `UNREACHABLE` and aborted preflight, even though the DB was perfectly
  reachable the way the migration actually connects. Now, when host psql is absent and a container
  pg-client is available, an unreachable host-probe **warns and defers** to the authoritative
  `pg_client`-based database-connectivity check. The rootful path (host psql present) is unchanged —
  a host-probe failure there is still fatal. This unblocked live rootless-docker / rootless-podman
  migrations against a containerized DB.

- **Containerized advisory-lock release could hang the whole run** (`scripts/lib/db_lock.sh`,
  `_kc_db_lock_release`). When the lock is held by a `docker run -i … psql` coproc (autonomy path, no
  host psql), `kill "$pid"` does not reliably terminate the `docker run` client, so a `wait "$pid"`
  placed *before* the container removal blocked until an external timeout — and `cr rm -f`, the line
  that actually drops the connection and releases the lock, was never reached. An autonomous
  migration reached its target version and printed "Migration Complete", then hung ~13 min on
  teardown (intermittent). Fix: force-remove the lock container **first** (releases the lock and makes
  the client exit), then reap with a bounded SIGTERM → SIGKILL → `wait` (can never hang). Live-proven:
  an autonomous `16 → 24 → 26` run went from a 900 s hang (rc=124) to a clean **rc=0 in ~108 s**. Host
  psql path unchanged. New regression guards in `tests/test_db_lock.sh` (removal-before-wait order +
  SIGKILL escalation).

### Planned
- AWS RDS / GCP Cloud SQL / Azure Database migration examples
- Ansible playbook wrapper
- Terraform module
- Helm chart
- Sovereign KC16 runtime datasource validation (harness live run)
- Live validation of the blue-green and multi-tenant paths on a real k8s cluster (the leak/hang/
  safe-default fixes landed; only structural tests cover them so far — no cluster to run them on)

---

## [3.9.7] - 2026-07-22

### Added

- **pg-client autonomy — the migration no longer requires host `psql`/`pg_dump`/`pg_restore`.**
  Every client call routes through a new `pg_client` helper (`scripts/lib/container_runtime.sh`): if
  the tool is on the host it runs there (byte-identical fast path, keeping `-Fd`/`-j` parallelism);
  otherwise it runs inside `$PROFILE_PG_CLIENT_IMAGE` (default `postgres:16`) over `--network=host`,
  with `PGPASSWORD` forwarded and host files bind-mounted (`PG_CLIENT_MOUNT`, same path, `:z` SELinux
  relabel) so `-Fd`/`-j` still work; `--user` is added only on a positively-rootful engine. Dependency
  gates use `pg_client_available` (host binary OR `cr image inspect`). New `tests/test_pg_client.sh`.
  (ADR-012)
- **Full-parity database advisory lock without host `psql`.** When host `psql` is absent, the ADR-011
  session advisory lock is held by a persistent psql running inside the pg-client container (coproc
  over `docker`/`podman run --rm -i`), released by force-removing the container. No more silent
  degradation to the per-workspace file lock — cross-host / cross-work-dir protection is preserved on
  autonomous nodes. Crash-release (SIGKILL → stdin-EOF → container exits → lock freed) and normal-exit
  release were live-validated on docker.
- **Sovereign pg-client image (decision, ADR-013).** `PROFILE_PG_CLIENT_IMAGE` is overridable; the
  default is intended to become a per-OS image built FROM the ALSE / RED OS base + `postgresql-client`
  of the server major (build tracked separately). The client major must be `>=` the DB server major.

### Fixed

- Preflight DB connectivity probe wrapped `pg_client` (a shell function) in the external `timeout`,
  which cannot exec a function — every PostgreSQL/CockroachDB migration aborted at preflight. Now
  invoked via `timeout bash -c '... pg_client ...'`; `PROFILE_PG_CLIENT_IMAGE` is exported so the
  child shell inherits it (else the container path built `cr run ... "" psql` with an empty image).

### Known limitations

- Containerized advisory lock: a 2nd CONCURRENT acquire against the same database can stall, then
  fail CLOSED (it still refuses), because `docker run -i` does not reliably return psql's answer
  through the coproc pipe under concurrent attach. Fail-safe; single-run lock is unaffected;
  re-validate on podman/conmon.

### Validation

- Live matrix on a real stand (docker, seeded KC16): full 16→24→26 (target 26) and 16→25.0.6
  (target 25), each on the host path AND fully autonomous (host `psql`/`pg_dump`/`pg_restore` hidden);
  backup via containerized `pg_dump`, restore-into-scratch and `CREATE INDEX CONCURRENTLY` via the
  container path; advisory-lock acquire / hold / crash-release / normal-release. Two adversarial
  verification passes closed 1 critical + 3 high; `run_all_tests.sh` 31/31.

## [3.9.6] - 2026-07-21

### Fixed

- **`--apply-indexes` was silently ignored — skipped indexes were captured but never created.**
  The `--apply-indexes` flag exports `PROFILE_APPLY_SKIPPED_INDEXES=true` *before* `profile_load` runs,
  but `profile_load` then **unconditionally** re-read `apply_skipped_indexes` from the profile YAML
  (unset → `false`), clobbering the flag. A migration run with `--apply-indexes` therefore captured the
  skipped-index DDL to `skipped_indexes_<version>.sql` but never applied it, and the index stayed
  missing (`0 rows`). `profile_load` now gives the **environment precedence** over the YAML for
  `PROFILE_APPLY_SKIPPED_INDEXES` — the same rule already used for `image_ref` / `image_tar` /
  `base_image` (env wins, else YAML, else `false`). Verified live: `migrate_oneshot … --apply-indexes
  --go` on a 350 000-row table now creates `IDX_USER_CREATED_TIMESTAMP` (`CONCURRENTLY IF NOT EXISTS`)
  after the hop instead of only logging it. VERSION 3.9.5 -> 3.9.6.

---

## [3.9.5] - 2026-07-20

### Fixed

- **A reused work dir made the tool report a SUCCESSFUL migration that never ran (false success).**
  State reconciliation (ADR-008) correctly reads the database version and rebuilds the hop list, but
  it did not invalidate the per-hop *phase* checkpoints in the work dir. A work dir carried over from
  an earlier run (against a different or rebuilt database) could hold `CHECKPOINT_<hop>=migrated` /
  `health_ok` / `tests_ok` for a hop the current database never reached; the resume logic trusted it,
  skipped `wait_for_migration` + the L2/L3 gates + the index capture, restarted the containers, and
  reported the hop migrated — while the database stayed exactly where it was (e.g. still 16.1.1).
  Reconciliation now treats the database as the fact: any checkpoint claiming a migration the
  database does not have is invalidated, and the stale run state (`migration_state.env`,
  `data_baseline.env` — which would otherwise mis-seed the L3 baseline — and the `.preflight_passed`
  marker) is archived into `<work-dir>/stale_<timestamp>/` (audit trail, not deleted) so the affected
  hops run for real. A legitimate resume — a hop interrupted before `migrated` and consistent with the
  database — is left untouched. Verified live: a fresh 16.1.1 DB with a work dir pre-seeded with stale
  `tests_ok` checkpoints now archives the state and migrates all the way to 26.6.3 instead of
  reporting a false success. VERSION 3.9.4 -> 3.9.5.

---

## [3.9.4] - 2026-07-20

### Fixed

- **`--apply-indexes` double-applied every skipped index and reported a spurious failure.**
  Keycloak 25/26 skips creating an index on a table whose estimated row count (`pg_class.reltuples`)
  exceeds Keycloak's `indexCreationThreshold` (default 300000) and logs the DDL instead — and it does
  so from TWO subsystems: the `CustomCreateIndexChange` Liquibase change during the migration, and the
  `DatabaseIndexChecker` at startup. `kc_check_skipped_indexes` matched both lines, so the same
  `CREATE INDEX` was captured twice; with `--apply-indexes` the second `CREATE INDEX CONCURRENTLY`
  failed with "relation already exists", logging `[ERROR] Failed to apply index` and returning
  non-zero (swallowed by `|| true` at the call site — harmless but alarming) even though the index had
  been created. Captured statements are now deduplicated on a normalised key, and the concurrent form
  is `CREATE INDEX CONCURRENTLY IF NOT EXISTS` so a re-apply — or an index Keycloak created itself — is
  an idempotent no-op. Verified live on a 350 000-row table across the full 16→24.0.5→26.6.3 path.

---

## [3.9.3] - 2026-07-20

### Fixed

- **The shipped entry-point scripts were not executable, so the documented direct invocation
  failed.** `migrate_keycloak_v3.sh` (and `smoke_test.sh`, and the legacy `migrate_keycloak*.sh`)
  were mode `100644` in git, and the release tar copies `scripts/` as-is — so a recipient running the
  commands as `docs/MIGRATION_GUIDE.md` and QUICKSTART show them (`scripts/migrate_keycloak_v3.sh
  migrate/plan/rollback/verify`) got `Permission denied`. The tool worked *internally* only because
  `migrate_oneshot.sh` (which was executable) hands off via `exec bash …/migrate_keycloak_v3.sh`,
  where the execute bit is irrelevant. The entry scripts are now `100755`, and the release workflow
  `chmod +x`s them into the tar as a belt-and-suspenders. Library files under `scripts/lib` stay
  non-executable — they are sourced, not run. (v3.9.2 shipped with the wrong modes; run those via
  `bash scripts/…` or upgrade to 3.9.3.)

---

## [3.9.2] - 2026-07-20

### Fixed (surfaced by a full live 16→26 run on the new code)

- **The competing-process scan flagged the DB-lock coproc and aborted every `--go`.** ADR-011 holds
  the advisory lock through `coproc { … psql; }`; a brace-group coproc keeps a bash WRAPPER carrying
  our own argv (a pid that is neither `$$` nor `$BASHPID`), so the scan detected itself. Exclusion is
  now by PROCESS GROUP — the main process, its command-substitution subshells, the coproc and any
  children all share our pgid; a genuinely separate invocation has its own. This also subsumes the
  earlier `$$`/`$BASHPID` special-casing.
- **A second, older preflight still hardcoded 15 GB of disk.** Wave 3 rewrote the *library* check to
  measure backup space, but `migrate_keycloak_v3.sh`'s own `run_preflight_checks` carried a duplicate
  `MIN_DISK_GB:-15` gate that ran first and refused an 11 GB host for a migration needing ~24 MB. It
  never surfaced because earlier runs skipped preflight via the `.preflight_passed` marker. Reduced
  to a 512 MB working-space floor (`MIN_DISK_FREE_MB`); the measured backup check remains the real
  gate.
- **`verify` could not start its container, then could not pass its smoke test.** Three faults, all
  from assuming health can be turned on at runtime: (1) `verify --profile` never loaded the profile,
  so it had no target version; (2) the verify container forced `KC_HEALTH_ENABLED=true`, a BUILD-time
  option that makes an optimized sovereign image refuse to start (exit 2) — dropped, with readiness
  now taken from the startup log; (3) `smoke_test.sh` waited on `/health` (never served on an
  optimized image) and its `((counter++))` increments aborted the whole script under `set -e` on the
  first success. Smoke now probes `/realms/master` for readiness, treats a missing `/health` as
  informational, and increments with assignments. Verified end-to-end: `verify` boots the target
  sovereign image, confirms readiness from the log, and passes all 7 Admin-API smoke tests.

- **A failed hop leaked its transient container, and cleanup ran only on the happy path or Ctrl-C.**
  The transient `kc-migrate-<version>-<token>` container was removed at the end of a successful hop
  and by the interrupt handler, but a hop that failed at wait/L2/L3/health returned before that and
  left the container running; the EXIT trap released the locks but not the container. The run now
  records the live container in `_KC_ACTIVE_RUN_CONTAINER` and the EXIT handler removes it on ANY
  exit — success, error, or interrupt. (Both locks were already released on every exit; this closes
  the container half.)
- **`verify --profile` now resolves the sovereign image without an env var (sidecar).** The
  `:`-bearing tag (`ghcr.io/ns/img:astra-{version}`) cannot live in the flat-YAML profile, so
  `profile_save` writes it to a `<profile>.image-ref` sidecar and `profile_load` reads it back. A
  pre-set `PROFILE_CONTAINER_IMAGE_REF` still wins. `verify --profile <name>` — the documented
  post-migration step — works out of the box; before, it fell back to `registry/image:version` and
  could not find the os-prefixed image.
- **The blue-green and multi-tenant paths had the same leak/hang/unsafe-default classes; fixed
  too.** `blue_green.sh` and `canary.sh` themselves spawn nothing, but the blue-green PATH in
  `migrate_keycloak_v3.sh` runs a `kubectl port-forward` for the green smoke test that was killed on
  the happy paths but never reaped and never in a trap — a Ctrl-C during the test leaked it (and its
  port). And its two "Delete green/blue deployment?" prompts defaulted to **Y** (unattended deletion
  under `--yes`/non-TTY — the ADR-009 class). `multi_tenant.sh`'s parallel workers were reaped only
  on the happy path (an interrupt before the wait loop left N migrations running) and `wait` had no
  timeout (a hung worker hung the whole run). The port-forward and the worker pids are now recorded
  and killed+reaped by the single EXIT/interrupt teardown; the multi-tenant wait is deadline-bounded
  (a worker past its timeout is killed and counted failed); the delete prompts default to N.
  Structural tests added (these k8s/multi-tenant paths still await a live cluster run).
- **Process lifecycle: no orphans, no zombies, no leaked ports on any exit.** The run spawns two
  long-lived children — the DB-lock connection and (with `--monitor`) the metrics exporter — and
  neither was torn down cleanly. The DB-lock coproc was a bash wrapper around psql: killing it left
  psql to die later on EOF, and nothing reaped it. It now `exec`s psql, so the coproc process IS the
  connection — killed directly, then `wait`ed to reap. The exporter's `prom_stop_exporter` was
  **never called from anywhere**, so `--monitor` leaked a background subshell and its `nc` child
  (holding the port) on every run; it is now wired into the single EXIT teardown, kills the `nc`
  child (`pkill -P`) as well as the subshell, and reaps both. Verified against real processes: after
  teardown no psql, no exporter, no `nc` on the port, the advisory lock free, and zero zombies in
  the process tree. Bounded waits everywhere (`read -t`, migration/verify timeouts) mean no hangs.
- **`/auth` is a per-instance runtime setting, and the tool no longer assumes it.** The HTTP
  relative path is `/auth` on KC16 (WildFly) and `/` on KC17+ (Quarkus), freely changeable via
  `KC_HTTP_RELATIVE_PATH`. `smoke_test.sh`'s default `KC_URL` dropped its stale `/auth` suffix (the
  tool targets 25/26, which serve at the root); pass `KC_URL=.../auth` for an instance configured
  that way.

### Added

- **One migration per database, isolated — not just detected (ADR-011).** The per-workspace file
  lock only caught a re-run from the *same* work dir; two runs against one database from different
  work dirs (or hosts) migrated its schema concurrently and corrupted it, and the transient
  container name `kc-migrate-<version>` was global to the container daemon so even runs against
  *different* databases fought over it.
  - **DB advisory lock** (`scripts/lib/db_lock.sh`): a PostgreSQL session-level
    `pg_try_advisory_lock`, keyed to the database and held for the whole run by a persistent psql
    connection. A second run against the same database is refused immediately with a clear message;
    the lock auto-releases if the run crashes (the connection drops). Cross-host, unlike a lock
    file. Degrades to the file lock with a warning when `psql` is absent.
  - **Per-database container names**: the transient container is now
    `kc-migrate-<version>-<db-token>`. Runs against different databases get different names and
    proceed in parallel without one's cleanup removing the other's container. Still matches the
    `kc-migrate-*` cleanup glob; an explicit `PROFILE_KC_RUN_CONTAINER_NAME` still wins.

### Fixed

- **Competing-process detection flagged the run as its own competitor and aborted every `--go`**
  (even a lone dry-run), while `ps` showed nothing. The `$(...)` scan subshell inherits the script's
  argv and has a pid ≠ `$$`, so the scan detected *itself*; `pgrep -f` matched any command line
  *mentioning* the script (the launching `zsh -c` wrapper, a `grep`, an editor); and the PPID
  ancestry walk broke when a launcher was reparented to init. Rewritten to match only processes with
  the script as an actual argv element, excluding both `$$` and `$BASHPID`, with no PPID walk. The
  single-instance lock remains the authoritative concurrent-run guard.
- **The harness base KC16 never created a schema — JGroups could not bind.** The WildFly-based
  `astra-16.1.1` boots an HA profile whose JGroups subsystem binds UDP to the auto-detected private
  interface; in a container that resolves to the bridge/gateway address (e.g. `172.x.0.1`) and fails
  with "not a valid address on any local network interface". The failure cascaded — dozens of
  services stayed down and Keycloak never reached its Liquibase step, so the database came up empty
  and the seeder had nothing to attach to. The harness now boots KC16 with
  `JAVA_OPTS_APPEND=-Djboss.bind.address.private=127.0.0.1 -Djgroups.bind_addr=127.0.0.1`
  (overridable via `HARNESS_KC16_JAVA_OPTS`); the schema initialises and the kcadm seed runs. The
  same env fixes a manual KC16 seed boot — see QUICKSTART.
- **The harness no longer aborts if the base KC16 exits before seeding anyway.** Seeding is
  best-effort: it warns, dumps the base container's logs to explain the exit, and continues — the
  integrity gate still checks the default realm across every hop.

### Release and packaging

- **The release artifact was not usable by its recipient.** It shipped stale `V3_*.md` status dumps
  and a `QUICK_START.md` describing a hop chain that does not exist (16→17→22→25→26; the real one is
  16→24.0.5→26.6.3), while omitting `docs/MIGRATION_GUIDE.md` — the only real runbook — and
  `containerfiles/`, without which the sovereign images cannot be rebuilt. The archive now contains
  what someone needs to *perform a migration* and nothing else: `scripts/`, `profiles/`,
  `containerfiles/`, the config examples, `QUICKSTART.md`, `docs/`, `LICENSE`. No tests, no
  contributor docs — those are for people working on the tool, in the repo.
- **The release workflow used GitHub Actions that GitHub archived in 2021** (`actions/create-release`,
  `actions/upload-release-asset`). Replaced with `softprops/action-gh-release`. It now also refuses
  to publish a tag whose version disagrees with the code, and refuses to publish without release
  notes in the changelog.
- **`docker build .` did not work.** `COPY V3_*.md QUICK_START.md ... ./ 2>/dev/null || true` — there
  is no shell in a Dockerfile, so `2>/dev/null`, `||` and `true` were parsed as three more source
  paths. No workflow builds this image, so nobody found out.
- **The version had drifted to four different answers** (code `3.0.0`, README `v3.8`, Dockerfile
  `3.0.0`, changelog `3.9.1`) with no 3.9 tag existing at all. `VERSION` in
  `scripts/migrate_keycloak_v3.sh` is now the single source of truth, and the release workflow
  enforces it.
- **`scripts/build_bundle.sh`** — the air-gap bundle had no build step. `dist/kc-<os>-bundle.tar.xz`,
  the file every offline migration consumes, was packed by hand and its structure survived only in a
  sentence of prose. Now a script: it refuses to pack an incomplete set, lists the archive back to
  prove what is in it, writes a checksum, and warns when a bundle approaches GitHub's 2 GiB asset
  limit.
- **`QUICKSTART.md`** — the instruction for someone who has just been handed this. Every parameter,
  the three ways to configure it, the three ways to supply images (including from a company's own
  registry under its own naming), what happens at each step, how to try it safely first, how to
  verify the result, and what each failure means.
- Removed 2,358 lines of dead documentation (`V3_*.md`, `README_V2.md`, `STATUS.txt`,
  `COMPLETE_V2.txt`, `RELEASE_NOTES_v3.6.0.md`, `AUTO_DISCOVERY_DEMO.md`, and the misleading
  `QUICK_START.md`).

### Changed

- **Backup space is now MEASURED, not guessed.** Two checks disagreed with each other: a hardcoded
  `MIN_DISK_SPACE_GB=10` gate that fired *before* the database had even been sized (so an 8 GB host
  refused to migrate a 50 MB database), and a `db_size × 3` calculation where `db_size` was
  `pg_database_size()` — which **includes indexes**. `pg_dump` does not dump indexes; it dumps the
  `CREATE INDEX` statements (kilobytes) and the heap, then compresses it. For a 200 GB database with
  80 GB of indexes that demanded 600 GB for a dump that would have been ~30 GB. Sizing now comes
  from the table data (`sum(pg_relation_size)` over ordinary tables) with a 1.2× cushion, **times
  the number of hops** — a factor that did not exist at all, so the check sized for one dump while
  the migration wrote three, filling the disk on exactly the large databases where it mattered. The
  hardcoded number survives only as a 512 MB floor for logs and temp files.
- **Large tables are flagged before the migration, not after.** Above roughly 300k rows Keycloak
  skips `CREATE INDEX` at startup and logs the DDL instead. The migration then succeeds *with
  indexes missing*: nothing goes bang, the database is simply slow, and the cause is a log line
  nobody read. Preflight now names the tables over the threshold and tells you to pass
  `--apply-indexes`.

### Added

- **`--apply-indexes`** (`migrate_keycloak_v3.sh` and `migrate_oneshot.sh`) — creates the indexes
  Keycloak skipped, `CONCURRENTLY`, so no table is locked. The capture machinery already existed
  (`kc_check_skipped_indexes` wrote `skipped_indexes_<version>.sql`) but only *applied* it when
  `PROFILE_APPLY_SKIPPED_INDEXES=true`, which nothing set — so the one-shot path's effective default
  was "silently degrade the database".
- **Three ways to configure a migration**, where there was one (flags, and only flags):
  - **`--env-file FILE`** — `KEY=VALUE` lines, so the database password is not in your shell history
    or the process table. Refused unless the file is mode 0600 — a world-readable secrets file
    defeats its own purpose. Template: `config/kc-migration.env.example`.
  - **`--profile NAME`** — reuse a profile written earlier. Hands straight over to the migration and
    regenerates nothing; image acquisition stays the profile's own business (`acquisition:`), so
    there is one source of truth for it rather than two.
  - **`--wizard`** — `config_wizard.sh` has existed all along, fully written, 8 steps with
    auto-discovery, and was wired to nothing. It now writes the profile and the migration runs with
    it.
- **`--image-ref-template 'registry/image:{version}'`** — images from your own registry under your
  own names. The default remains `<image-ns>:<os>-<version>` (our convention), and `--image-ns`
  points that convention at a private registry; but a company whose registry already holds Keycloak
  images named some other way should not have to re-tag it to satisfy this tool. `{version}` is
  substituted per hop, and image *acquisition* resolves the same ref the migration will — otherwise
  the tool pulls one image and runs another.

- **Layer 3 — data integrity on every hop (ADR-010).** L1 (`DATABASECHANGELOG`) proves the
  changesets ran; L2 (`MIGRATION_MODEL`) proves the realm migration ran. Neither says a word about
  whether your realms, users and clients are still there afterwards — a hop that emptied
  `user_entity` passed every check the tool had and reported complete success. `kc_data_baseline`
  now snapshots `COUNT(*)` on `realm` / `user_entity` / `client` / `keycloak_role` **once**, before
  any hop, and `kc_data_verify` re-checks after each one: realm and user counts must be unchanged;
  client and role counts may only grow (migrations add default clients and roles, never remove
  yours). Four queries, no admin credentials, works with Keycloak shut down. A violation stops the
  migration and offers the rollback. The policy is not new — it already guarded the *synthetic*
  harness runs in `scripts/harness/lib/harness_integrity.sh` while the real migrations ran
  unguarded; it is promoted to `scripts/lib/data_integrity.sh` and the harness now delegates to it,
  so the two can never drift.
- **`verify` subcommand — the acceptance test the tool never had.** The migration leaves no running
  Keycloak (the transient container is removed after the last hop so it cannot fight the next one
  for the Liquibase lock), so "is the result any good" had no answer. `verify` boots the **same
  sovereign image that performed the migration** against the migrated database with
  `KC_HEALTH_ENABLED=true`, confirms L2 and L3, waits for `/health/ready`, runs the Admin API smoke
  tests (realms, clients, users, token issuance), and removes the container. Without
  `PROFILE_KC_ADMIN_USER`/`PROFILE_KC_ADMIN_PASSWORD` it reports exactly what it could **not** check
  rather than implying it passed.
- **Backup restore test (opt-in, `PROFILE_VERIFY_BACKUP_RESTORE=true`).** What the tool called
  "verifying" a backup was `pg_restore --list | grep -c "TABLE DATA"` — that proves the dump's table
  of contents parses, and nothing else. The new `kc_backup_restore_test` restores the dump into a
  scratch database, compares row counts against the source, and drops the scratch. A backup that
  will not restore now aborts the migration instead of being discovered during the rollback.

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
