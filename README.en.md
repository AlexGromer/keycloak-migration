> LANGUAGE: [🇷🇺 Русский](README.md) | 🇬🇧 English

# Keycloak Migration Tool v3.9.7

**A "single-command" Keycloak migration utility** with environment auto-detection, support for multi-tenant and clustered deployments, real-time monitoring, production hardening, **security hardening** (SAST, secret scanning, input validation, audit logging), **containerized step-by-step migration** (container-hop — at every step a real Keycloak container is brought up and the advancement of the MIGRATION_MODEL level is verified, Layer-2), **sovereign OS images** (Astra Linux SE / RED OS) with **air-gap** offline distribution and support for all databases officially supported by Keycloak.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-31%20suites-success)](tests/)
[![Bash](https://img.shields.io/badge/bash-5.0%2B-green.svg)](scripts/)
[![Databases](https://img.shields.io/badge/databases-6-blue.svg)](scripts/lib/database_adapter.sh)
[![Version](https://img.shields.io/badge/version-v3.9.7-blue.svg)](CHANGELOG.md)
[![Images](https://img.shields.io/badge/sovereign%20images-Astra%20SE%20%7C%20RED%20OS-blue.svg)](docs/AIRGAP.md)

---

## 🚀 Quick start (90% of cases)

### 1. Clone the repository

```bash
git clone https://github.com/AlexGromer/keycloak-migration
cd keycloak-migration
```

### 2. Run the configuration wizard

```bash
./scripts/config_wizard.sh
```

The wizard:
1. **Auto-detects** an existing Keycloak installation;
2. **Determines** the current version from the DB / deployment;
3. **Asks** for the target version;
4. **Generates** a migration profile;
5. **Runs** the migration with a single command.

### 3. Or call directly with a ready-made profile

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=my-profile.yaml
```

### 4. Container-hop in one command (sovereign images, v3.9)

For chains `16.1.1 → 24.0.5 → 26.6.3` (target 26) or `16.1.1 → 25.0.6` (target 25) the
`migrate_oneshot.sh` script does everything non-interactively — obtains images → generates the run and
container profile → migrates. Dry-run by default; for a live run add `--go`:

```bash
export CONTAINER_RUNTIME=docker
# Plan only (changes nothing):
scripts/migrate_oneshot.sh --target 26 --os astra --db-host <pg-host> --dry-run
# Live run (target 26 = 16.1.1 → 24.0.5 → 26.6.3):
export PROFILE_DB_PASSWORD=...
scripts/migrate_oneshot.sh --target 26 --os astra --db-host <pg-host> --source pull --go
```

The full runbook (both paths, air-gap, verification, rollback) is in **`docs/MIGRATION_GUIDE.md`**.

**Done!** The tool handles the rest automatically.

---

## 🧩 pg-client autonomy (new in v3.9.7)

Starting from **v3.9.7** the migration node **no longer needs installed `psql` / `pg_dump` /
`pg_restore`**. Every PostgreSQL-client invocation goes through the `pg_client` helper
(`scripts/lib/container_runtime.sh`):

- if the binary is present on the host — it runs on the host (the previous fast path, preserving `-Fd`/`-j`);
- if the binary is absent — the invocation is executed **inside a container image** (the
  `PROFILE_PG_CLIENT_IMAGE` variable, `postgres:16` by default) over the host network `--network=host`, with
  the DB password passed through (`PGPASSWORD`) and backup files bind-mounted at the same path
  (`PG_CLIENT_MOUNT`, relabel `:z` for SELinux). The `--user` flag is added only on an explicitly
  rootful engine.

**The per-DB advisory lock has also become autonomous.** The cross-host "one migration per one
database" lock (ADR-011) is now held via a container when `psql` is absent on the host — **without
degradation** to the weaker per-file lock of the work directory. The long-lived `psql` lives
in the pg-client container as a coproc over `docker/podman run --rm -i` and is released by force-
removing the container (both emergency and normal release were verified).

Compatibility requirement: **the client major must be ≥ the DB server major** (`pg_dump` refuses
to work with a newer server). `PROFILE_PG_CLIENT_IMAGE` is overridable; the decisions are recorded in
**ADR-012** (autonomy) and **ADR-013** (sovereign per-OS default pg-client image, built
FROM the ALSE / RED OS base) — see `ARCHITECTURE.md`.

**Example of a fully autonomous run** (only a container engine on the node, `postgresql-client` not
installed):

```bash
export PROFILE_DB_PASSWORD='...'
export PROFILE_PG_CLIENT_IMAGE=postgres:17   # major ≥ DB server major
scripts/migrate_oneshot.sh --target 26 --os astra --source preloaded \
  --image-ns ghcr.io/<you>/keycloak-migration \
  --db-host <db-host> --db-port 5432 --db-name keycloak --db-user keycloak --go
```

Backup, reconcile queries and the advisory lock — everything runs inside the pg-client container automatically.

---

## 📦 Sovereign container images (GHCR + Air-gap)

Keycloak hop images are built FROM sovereign OS bases (**Astra Linux SE / RED OS**), published to a
**private GHCR** and delivered as **air-gap tar archives**. Multistage + non-root (uid 1000);
Quarkus images bake `--db=postgres` at build time.

| Image tag | KC version | OS |
|---|---|---|
| `ghcr.io/<owner>/keycloak-migration:astra-26.6.3` | 26.6.3 (Quarkus) | Astra SE |
| `…:redos-26.6.3` | 26.6.3 (Quarkus) | RED OS |
| `…:{astra,redos}-{16.1.1,24.0.5,25.0.6}` | chain links (16→24→26 / 16→25) | both |

```bash
# Online (private GHCR):
docker login ghcr.io && docker pull ghcr.io/<owner>/keycloak-migration:redos-26.6.3
# Offline (air-gap):
docker load -i kc-redos-26.6.3.tar.xz
```

**Build the matrix yourself** (on your own licensed bases): edit `config/images.conf`
→ `scripts/build_matrix.sh --build [--publish]`. The full build → export → transfer →
consume runbook: **[docs/AIRGAP.md](docs/AIRGAP.md)**.

---

## 🧪 Test matrix

Live run on `docker` with a seeded Keycloak 16 database:

| Path | 16→24→26 (target 26) | 16→25.0.6 (target 25) |
|---|---|---|
| `psql` present on host | PASS (Complete) | PASS (Complete) |
| autonomous (host clients hidden) | PASS (Complete) | PASS (Complete) |

Additionally, the container path was verified: backup via a containerized `pg_dump` + integrity check,
restore-into-scratch, `CREATE INDEX CONCURRENTLY`; advisory lock — acquire / hold / emergency
release (`SIGKILL → EOF on stdin → container terminates → lock is released
automatically`) / normal release.

**Quality control:** 31/31 test suites; two independent adversarial verification passes closed
1 critical and 3 high defects before the release.

> **Known limitation (honestly):** a second **concurrent** acquisition of the container lock may
> "hang" and then fail **fail-closed** (that is, it still refuses — correctness is
> preserved) under `docker run -i`. A single run is not affected. It is recommended to
> re-check on `podman`.

---

## 🎯 Capabilities

### Auto-detection
- **Current version** — from the JAR manifest, DB, Docker image or Kubernetes deployment;
- **DB type** — from the JDBC URL or CLI tools;
- **Deployment mode** — Standalone / Docker / Kubernetes is detected automatically;
- **Target version** — interactive selection showing the Java requirements.

### Multi-database support
- ✅ **PostgreSQL** (recommended)
- ✅ **MySQL / MariaDB**
- ✅ **CockroachDB** (v18+)
- ✅ **Oracle Database**
- ✅ **Microsoft SQL Server**
- ✅ **H2** (dev only, with warnings)

### Multi-deployment-mode support
- ✅ **Standalone** (systemd, init.d, manual)
- ✅ **Docker** (single container)
- ✅ **Docker Compose** (multi-container)
- ✅ **Kubernetes** (Deployment, StatefulSet)
- ✅ **Custom** (your own scripts)

### Production-Ready
- ✅ **Extended preflight checks** — 15 checks (disk, memory, network, DB health, Keycloak status, dependencies, credentials) (v3.5)
- ✅ **Rate Limiting** — protects the production DB from overload with adaptive throttling (v3.5)
- ✅ **Backup rotation** — auto-cleanup by policies (keep-last-N, time-based, size-based, GFS) (v3.5)
- ✅ **Connection-leak detection** — detects idle-in-transaction (v3.5)
- ✅ **Circuit Breaker** — protection from cascading failures with retry logic (v3.5)
- ✅ **SAST** — ShellCheck on pre-commit (v3.6)
- ✅ **Secret scanning** — gitleaks (v3.6)
- ✅ **Input validation** — protection against SQL/command/path injection (v3.6)
- ✅ **Secrets management** — a unified interface for Vault, K8s, AWS, Azure (v3.6)
- ✅ **HMAC audit logging** — cryptographic signatures against tampering (v3.6)
- ✅ **Atomic checkpoints** — resume from any step
- ✅ **Auto-rollback** on failure
- ✅ **Airgap mode** — pre-validation of artifacts
- ✅ **JSON audit logging** — full traceability
- ✅ **Real-time monitoring** — Prometheus + Grafana (v3.1)
- ✅ **Multi-tenancy** — parallel migration of isolated instances (v3.2)
- ✅ **Clustered deployments** — rolling update with no downtime (v3.2)
- ✅ **Container-hop migration** — at every step a real Keycloak container is brought up, verifying Layer-1 (`DATABASECHANGELOG`) and Layer-2 (`MIGRATION_MODEL`)
- ✅ **verify** — post-migration acceptance: L2+L3+readiness+Admin API (ADR-010)
- ✅ **Layer-3 data-integrity gate** at every step (realm/user/client/role counters) (ADR-010)
- ✅ **Per-DB advisory lock** — one migration per one database, cross-host (ADR-011)
- ✅ **`--apply-indexes`** — create indexes skipped by Keycloak, via `CONCURRENTLY` (v3.9.4/3.9.6)
- ✅ **pg-client autonomy** — `psql`/`pg_dump`/`pg_restore` on the host are not required (v3.9.7, ADR-012/013)
- ✅ **Test coverage** — 31 test suites (`tests/run_all_tests.sh`)

### Migration strategies
in-place, rolling update (K8s), blue-green, canary (v3.3).

### DB-specific optimizations (v3.4)
Parallel jobs, `VACUUM ANALYZE`, XtraBackup / mariabackup, zone-aware backup for CockroachDB, migration-
time estimation.

### Migration path (real chains)
The tool raises Keycloak versions through verified intermediate links:

```
target 26:  16.1.1 → 24.0.5 → 26.6.3
target 25:  16.1.1 → 25.0.6
```

Java requirements are checked automatically at each link (Java 11 / 17 / 21). Target versions are
fixed in **ADR-002** (target 26 = **26.6.3**; versions 26.6.0 / 26.6.1 are forbidden).

---

## 📖 How it works

The tool **migrates** an existing Keycloak installation rather than deploying it from scratch. An already
running Keycloak instance is required.

**What the tool does:**
1. Determines the current Keycloak version and environment;
2. Backs up the DB;
3. Stops the Keycloak service;
4. Downloads / builds the target version;
5. Updates the DB schema;
6. Restarts on the new version;
7. Validates and rolls back if necessary.

**What the tool does NOT do:**
- ❌ Does not install Keycloak from scratch;
- ❌ Does not provision infrastructure;
- ❌ Does not configure network / DNS.

---

## 📦 Installation

### Requirements
- Bash 5.0+;
- an existing Keycloak installation (16.1.1+);
- a DB client (`psql`, `mysql`, `cockroach`, …) — **or** a container engine (see pg-client autonomy);
- Java (version per Keycloak requirements);
- for Kubernetes — `kubectl`.

### Clone and run

```bash
git clone https://github.com/AlexGromer/keycloak-migration
cd keycloak-migration
./scripts/config_wizard.sh
```

---

## 🎮 Usage examples

### 1. Interactive wizard (recommended)
```bash
./scripts/config_wizard.sh
```
Auto-discovery of installations and generation of a YAML profile.

### 2. Non-interactive mode (CI/CD)
```bash
export PROFILE_DB_TYPE=postgresql
export PROFILE_KC_DEPLOYMENT_MODE=kubernetes
export PROFILE_KC_CURRENT_VERSION=16.1.1
export PROFILE_KC_TARGET_VERSION=26.6.3

./scripts/config_wizard.sh --non-interactive --profile-name ci-migration
./scripts/migrate_keycloak_v3.sh migrate --profile ci-migration
```

### 3. Auto-discovery only
```bash
./scripts/kc_discovery.sh
```
Scans the environment and creates a profile automatically.

---

## 🚁 Advanced scenarios

> Below are condensed examples. Full profiles are in the `profiles/` directory, detailed runbooks are
> in **[docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md)** and **[docs/AIRGAP.md](docs/AIRGAP.md)**.

### Multi-tenant migration (v3.2)

**Scenario:** a SaaS platform with several isolated Keycloak instances.
**Profile:** `profiles/multi-tenant-example.yaml`

```yaml
profile:
  name: multi-tenant-saas
  mode: multi-tenant

migration:
  strategy: rolling_update
  parallel: true

tenants:
  - name: enterprise-corp
    database:
      host: db1.example.com
      name: keycloak_enterprise
    deployment:
      mode: kubernetes
      namespace: keycloak-enterprise
      replicas: 3
  - name: smb-startup
    database:
      host: db2.example.com
      name: keycloak_smb
    deployment:
      mode: kubernetes
      namespace: keycloak-smb
      replicas: 2

rollout:
  type: parallel        # parallel | sequential
  max_concurrent: 3
```

Live per-tenant progress:
```
┌─ MIGRATION PROGRESS (3/3 tenants) ────────────────────────────┐
│ enterprise-corp  |  87% [████████████████████░░░░░░] 16→26    │
│ smb-startup      |  92% [██████████████████████░░░]  16→26    │
│ trial-demo       | 100% [████████████████████████]   16→26 ✓ │
└────────────────────────────────────────────────────────────────┘
```

**Capabilities:** parallel/sequential execution, per-tenant checkpoints and rollback,
aggregated audit, per-tenant progress, independent failure handling (one fails — the rest
continue).

### Clustered deployment (v3.2)

**Scenario:** 4 standalone Keycloak nodes on bare-metal behind HAProxy with a shared DB.
**Profile:** `profiles/clustered-bare-metal-example.yaml`

```yaml
profile:
  name: clustered-bare-metal
  mode: clustered

migration:
  strategy: rolling_update
  auto_rollback: true

database:
  type: postgresql
  host: db-cluster.example.com
  name: keycloak

cluster:
  load_balancer:
    type: haproxy
    host: lb.example.com
    admin_socket: /var/run/haproxy/admin.sock
    backend_name: keycloak_backend
  nodes:
    - name: kc-node-1
      host: 192.168.1.101
      ssh_user: keycloak
      keycloak_home: /opt/keycloak
    # kc-node-2..4 likewise

rollout:
  type: sequential
  nodes_at_once: 1
  drain_timeout: 60      # sec to drain connections
  startup_timeout: 120   # sec for node health
```

**Rolling update process:** drain the node from the LB → wait for active connections to finish → migrate the node →
health check → return to the LB → next node.
**Capabilities:** zero-downtime, LB integration (HAProxy / Nginx), connection draining, health check
before returning, auto-rollback, per-node monitoring.

### Blue-Green and Canary strategies (v3.3)

**Blue-Green** (`profiles/blue-green-k8s-istio.yaml`) — a no-downtime migration with instant
traffic switching. Both environments (blue v16 / green v26) use one DB, so there are no schema-
migration conflicts; rollback is an instant switch back.

```yaml
profile:
  name: blue-green-k8s-istio
  strategy: blue_green

migration:
  current_version: "16.1.1"
  target_version: "26.6.3"

blue_green:
  old_environment: "blue"
  new_environment: "green"
  deployment:
    type: kubernetes
    namespace: keycloak
    replicas: 3
  traffic_router:
    type: istio          # istio | nginx | haproxy
    virtualservice: keycloak-vs
    subset_blue: v16
    subset_green: v26
  readiness_timeout: 600
  keep_old: false
  cleanup_delay: 300
```

**Canary** (`profiles/canary-k8s-istio.yaml`) — progressive rollout with validation via
Prometheus at every phase (10% → 50% → 100%). Auto-rollback by thresholds: `error_rate` > 0.01, `p99` >
500 ms, insufficient requests, or 3 consecutive failed validations.

```yaml
migration:
  current_version: "16.1.1"
  target_version: "26.6.3"

canary:
  deployment:
    namespace: keycloak
    deployment: keycloak
    replicas: 10
  traffic_router:
    type: istio
    virtualservice: keycloak-vs
    subset_old: v16
    subset_new: v26
  phases:
    - name: phase-1-initial
      percentage: 10
      replicas: 1
      duration: 3600
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 100
    - name: phase-2-half
      percentage: 50
      replicas: 5
      duration: 7200
    - name: phase-3-full
      percentage: 100
      replicas: 10
      duration: 1800
  auto_rollback: true

validation:
  prometheus_url: http://prometheus.monitoring.svc.cluster.local:9090
```

### DB-specific optimizations (v3.4)

All optimizations are **automatic**, no configuration needed — the tool detects the DB type and applies
the appropriate settings:
- PostgreSQL: auto-selection of parallel jobs by the formula `min(cpu_cores, max(1, db_size_gb / 2))`,
  accounting for DB size, `VACUUM ANALYZE` after migration, connection-pool recommendations;
- MySQL: Percona **XtraBackup** (hot backup, up to 10× faster than `mysqldump`);
- MariaDB: **mariabackup**;
- CockroachDB: zone-aware backup (multi-region);
- migration-time estimation before the start.

Manually override the auto-tuning:
```yaml
database:
  type: postgresql
  backup:
    parallel_jobs: 8      # override the auto-selection
    verify: true          # backup integrity check
  optimization:
    vacuum_analyze: true
    show_recommendations: true
```

Gain: 2–4× faster PostgreSQL backups, up to 10× with MySQL XtraBackup, optimized queries after
`VACUUM ANALYZE`, right-sized configuration, backup verification, accurate time estimates.

### Production hardening (v3.5)

**(A) 15 preflight checks** run automatically before every migration and are grouped as:
*System Resources* (disk, memory, network), *Database Health* (availability, version, size, PRIMARY/REPLICA
replication status), *Keycloak Health* (service status, Admin API credentials), *Backup
Validation* (space for the backup, directory permissions), *Dependencies* (required utilities, Java version),
*Configuration* (YAML syntax, credentials). If critical checks fail, the migration is
**blocked**.

**(B) Rate Limiting and DB protection:** `fixed` / `token_bucket` / `adaptive` strategies, circuit breaker
(threshold of 5 failures), exponential backoff, connection-pool monitoring (warning above 80%),
leak detection.

```yaml
migration:
  rate_limiting:
    enabled: true
    strategy: adaptive        # fixed | token_bucket | adaptive
    ops_per_second: 10
    circuit_breaker:
      threshold: 5
      timeout: 30
```

**(C) Backup rotation:** `keep_last_n`, time-based, size-based, GFS
(Grandfather-Father-Son), combined policies.

```yaml
backup:
  rotation:
    policy: keep_last_n       # keep_last_n | time_based | size_based | gfs | combined
    keep_count: 5
    max_age_days: 30
    max_size_gb: 100
    # for GFS: daily_keep: 7 / weekly_keep: 4 / monthly_keep: 12
```

Manual invocation (`source scripts/lib/backup_rotation.sh`): `rotate_keep_last_n`, `rotate_by_age`,
`rotate_by_size`, `rotate_gfs`, `get_backup_statistics`.

### Monitoring integration (v3.1)

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=prod.yaml --enable-monitoring
# Bring up the stack:
cd examples/monitoring && docker-compose up -d
```

Access: **Grafana** `http://localhost:3000` (7 panels, auto-refresh 5 s), **Prometheus**
`http://localhost:9091`, **Alertmanager** `http://localhost:9093` (11 alert rules).

Exported metrics: `keycloak_migration_progress`, `_checkpoint_status`, `_duration_seconds`,
`_errors_total`, `_database_size_bytes`, `_java_heap_bytes`, `_last_success_timestamp`.
Labels for multi-instance: `tenant="…"`, `node="…"`.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  KEYCLOAK MIGRATION v3.9.7                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐  │
│  │   Profile    │──────│  Discovery   │──────│  Migration   │  │
│  │   Manager    │      │   Engine     │      │   Engine     │  │
│  └──────────────┘      └──────────────┘      └──────────────┘  │
│         │                      │                      │         │
│         ▼                      ▼                      ▼         │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐  │
│  │   Database   │      │  Deployment  │      │ Distribution │  │
│  │   Adapter    │      │   Adapter    │      │   Handler    │  │
│  └──────────────┘      └──────────────┘      └──────────────┘  │
│         │                      │                      │         │
│         └──────────────────────┴──────────────────────┘         │
│                                │                                │
│                                ▼                                │
│                      ┌──────────────────┐                       │
│                      │  State Manager   │                       │
│                      │  + Checkpoints   │                       │
│                      └──────────────────┘                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Database Adapter** (`scripts/lib/database_adapter.sh`): `db_validate_type`, `db_detect_type`,
`db_build_jdbc_url`, `db_backup` / `db_restore`.
**Deployment Adapter** (`scripts/lib/deployment_adapter.sh`): `deploy_validate_mode`,
`deploy_detect_mode`, `kc_start` / `kc_stop`, `kc_health_check`.
**Distribution Handler** (`scripts/lib/distribution_handler.sh`): `dist_download`,
`dist_validate_airgap`, `dist_check_network`.

The decisions are recorded in `ARCHITECTURE.md` (ADR-001 … ADR-013).

---

## 📋 Typical flows

### Standalone → Kubernetes
```bash
./scripts/config_wizard.sh
./scripts/migrate_keycloak_v3.sh plan     --profile standalone-postgresql   # dry-run
./scripts/migrate_keycloak_v3.sh migrate  --profile standalone-postgresql
./scripts/migrate_keycloak_v3.sh rollback                                    # if necessary
```

### Kubernetes Rolling Update
```yaml
# profiles/k8s-production.yaml
keycloak:
  deployment_mode: kubernetes
  cluster_mode: infinispan
  current_version: 16.1.1
  target_version: 26.6.3
  kubernetes:
    namespace: keycloak
    deployment: keycloak
    replicas: 3

migration:
  strategy: rolling_update   # zero-downtime
  run_smoke_tests: true
  backup_before_step: true
```

### Air-gap migration
```bash
# 1. On a CONNECTED host: build a bundle of sovereign images
scripts/build_matrix.sh --build           # -> dist/kc-<os>-<ver>.tar (+ .sha256)
#    (or use a ready-made combined bundle dist/kc-<os>-bundle.tar.xz)
# 2. Transfer dist/*.tar(.xz) + .sha256 into the isolated network and verify the checksum
sha256sum -c kc-astra-bundle.tar.xz.sha256
# 3. IN AIR-GAP: migrate from the offline bundle (images are loaded from the tar; a host psql is not required — v3.9.7)
scripts/migrate_oneshot.sh --target 26 --os astra --source bundle \
  --bundle dist/kc-astra-bundle.tar.xz \
  --db-host <db-host> --db-port 5432 --db-name keycloak --db-user keycloak --go
#    (or --source preloaded, if the images are already loaded into the runtime)
```
> Full offline-delivery runbook: [docs/AIRGAP.md](docs/AIRGAP.md).

---

## 🧪 Testing

```bash
# All tests
./tests/run_all_tests.sh

# Individual suites
./tests/test_database_adapter.sh
./tests/test_deployment_adapter.sh
./tests/test_profile_manager.sh
./tests/test_migration_logic.sh
./tests/test_pg_client.sh          # pg-client autonomy (v3.9.7)
```

Current authoritative result: **`run_all_tests.sh` — 31/31**.

---

## 📁 Project structure

```
kk_migration/
├── scripts/
│   ├── migrate_keycloak_v3.sh      # main migration script
│   ├── migrate_oneshot.sh          # "single-command" container-hop
│   ├── config_wizard.sh            # interactive configuration
│   ├── kc_discovery.sh             # auto-discovery
│   ├── build_matrix.sh             # build the sovereign-image matrix
│   └── lib/
│       ├── database_adapter.sh     # DB abstraction (6 engines)
│       ├── deployment_adapter.sh   # deployment abstraction (5 modes)
│       ├── container_runtime.sh    # container engine + pg_client (v3.9.7)
│       ├── db_lock.sh              # per-DB advisory lock (ADR-011)
│       ├── migration_verify.sh     # verify: L2+L3+readiness+Admin API (ADR-010)
│       ├── data_integrity.sh       # Layer-3 integrity gate (ADR-010)
│       ├── profile_manager.sh      # working with YAML profiles
│       ├── distribution_handler.sh # artifact management
│       ├── keycloak_discovery.sh   # environment scanning
│       └── audit_logger.sh         # JSON audit logging
│
├── profiles/                       # YAML profiles (multi-tenant, clustered, blue-green, canary, …)
├── tests/                          # test suites (run_all_tests.sh — 31/31)
├── docs/                           # MIGRATION_GUIDE.md, AIRGAP.md
└── README.md
```

---

## 🔧 Configuration

### Example YAML profile
```yaml
profile:
  name: standalone-postgresql
  environment: standalone

database:
  type: postgresql
  location: standalone
  host: localhost
  port: 5432
  name: keycloak
  user: keycloak
  credentials_source: env

keycloak:
  deployment_mode: standalone
  distribution_mode: container
  cluster_mode: standalone
  current_version: 16.1.1
  target_version: 26.6.3

migration:
  strategy: inplace
  parallel_jobs: 4
  timeout_per_version: 900
  run_smoke_tests: true
  backup_before_step: true
```

### Environment variables
```bash
# DB credentials
export KC_DB_PASSWORD="secret"
export PROFILE_DB_PASSWORD="secret"       # for a live container-hop

# Non-interactive mode
export NON_INTERACTIVE=true
export PROFILE_DB_TYPE=postgresql
export PROFILE_KC_DEPLOYMENT_MODE=kubernetes

# Container-hop / pg-client autonomy (v3.9.7)
export CONTAINER_RUNTIME=docker
export PROFILE_PG_CLIENT_IMAGE=postgres:16   # major ≥ DB server major
# PG_CLIENT_MOUNT — bind-mount path for backup files into the pg-client container

# Migration options
export AIRGAP_MODE=true
export AUTO_ROLLBACK=true
export SKIP_PREFLIGHT=false
```

---

## 🚀 Advanced features

### Atomic checkpoints
Resume the migration from any step:
```
backup_done → stopped → downloaded → built →
started → migrated → health_ok → tests_ok
```
If it fails at `health_ok` — fix the cause and run again; the tool will continue from the last
checkpoint. **Important:** do not reuse the same `--work-dir` between different runs (otherwise
stale checkpoints may distort state reconciliation).

### verify and the data-integrity gate (ADR-010)
The `verify` subcommand performs post-migration acceptance: Layer-2 advancement (`MIGRATION_MODEL`),
Layer-3 (realm / user / client / role counters), readiness and Admin API calls. The Layer-3 integrity
gate runs at **every** hop.

### Per-DB advisory lock (ADR-011)
Only **one** migration runs on one database at a time — cross-host. In v3.9.7 the lock is
held via the pg-client container if `psql` is absent on the host (see the "pg-client
autonomy" section).

### Auto-rollback (clarification per ADR-009)
The migration gate is **Layer-2 advancement** (`MIGRATION_MODEL`), and the health check is now **diagnostic**
(ADR-009) rather than decisive. Auto-rollback triggers on a **migration failure**, not "on a failed health
check":
```bash
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --auto-rollback
```

### `--apply-indexes` (v3.9.4/3.9.6)
Creates indexes that Keycloak skipped (threshold), via `CREATE INDEX CONCURRENTLY IF NOT EXISTS`.
The flag takes priority over the value from the profile (env-wins).

### Audit logging
All operations are written to `migration_audit.jsonl`:
```json
{"ts":"2026-07-22T21:15:00Z","level":"INFO","event":"migration_start","profile":"k8s-prod","from_version":"16.1.1","to_version":"26.6.3"}
{"ts":"2026-07-22T21:16:32Z","level":"INFO","event":"backup_created","version":"24.0.5","backup_path":"/opt/backup_24.0.5.dump","size_bytes":"458123456"}
{"ts":"2026-07-22T21:18:45Z","level":"INFO","event":"migration_step","version":"24.0.5","status":"migrated","duration_s":"133"}
{"ts":"2026-07-22T21:35:12Z","level":"INFO","event":"migration_end","profile":"k8s-prod","status":"success","total_duration_s":"1212"}
```

---

## 🛠️ CLI reference

```bash
# Subcommands
./scripts/migrate_keycloak_v3.sh migrate  --profile <name>
./scripts/migrate_keycloak_v3.sh plan     --profile <name>
./scripts/migrate_keycloak_v3.sh verify   --profile <name>    # post-migration acceptance (ADR-010)
./scripts/migrate_keycloak_v3.sh rollback [--force]
#   Offline image acquisition (air-gap) is NOT a migrate_keycloak_v3.sh subcommand;
#   see `migrate_oneshot.sh --source bundle|preloaded` below and docs/AIRGAP.md.

# Flags
--airgap                 # offline mode (validate artifacts first)
--auto-rollback          # auto-rollback on migration failure
--skip-preflight         # skip preflight checks (not recommended)
--dry-run                # show the plan without executing
--apply-indexes          # create skipped indexes via CONCURRENTLY (v3.9.4/3.9.6)
--no-resume              # ignore existing checkpoints, start over
--force-unlock           # release a "stuck" advisory lock (ADR-011)
--security-scan          # run security scanning (ShellCheck / gitleaks)

# One-shot container-hop (migrate_oneshot.sh flags — NOT migrate_keycloak_v3.sh)
scripts/migrate_oneshot.sh --target <25|26> --os <astra|redos> --db-host <host> \
  --source <pull|bundle|preloaded> [--bundle <file>] [--dry-run | --go]
#   --env-file <path>        # load environment variables from a file
#   --wizard                 # launch the interactive wizard
#   --image-ref-template <t> # image-reference template for container-hop

# Profile management
./scripts/migrate_keycloak_v3.sh profile list
./scripts/migrate_keycloak_v3.sh profile validate <name>

# Auto-discovery
./scripts/kc_discovery.sh [--output <profile-name>]
```

---

## 📊 System requirements

- **OS:** Linux (verified on Debian, Ubuntu, RHEL, Kali; sovereign — Astra Linux SE, RED OS);
- **Bash:** 5.0+;
- **Disk:** space for the backup is checked **measurably** (real DB size × margin) with a lower threshold
  of 512 MB — the hard "15 GB" requirement is gone (see CHANGELOG [3.9.1]/[3.9.2]);
- **Memory:** 4 GB+ recommended;
- **Java:** 11 / 17 / 21 (auto-validated per link).

### Optional tools
`kubectl` (Kubernetes), `docker` / `docker-compose` (containers and pg-client autonomy), `helm`,
`gitleaks` / `trufflehog` (secrets), `jq` (JSON audit).

---

## 🐛 Troubleshooting

**Problem:** `Java version insufficient`
```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
```

**Problem:** the migration failed at a checkpoint
```bash
# Resume from the last checkpoint (same profile, same --work-dir):
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
```

**Problem:** the health check does not pass
```bash
# Health is diagnostic (ADR-009). Roll back manually:
./scripts/migrate_keycloak_v3.sh rollback
# Or enable auto-rollback on migration failure:
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --auto-rollback
```

**Problem:** the advisory lock is "stuck" after a crashed run
```bash
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --force-unlock
```

**Problem:** air-gap validation does not pass
```bash
# Verify the bundle checksum and rebuild it if necessary:
sha256sum -c kc-astra-bundle.tar.xz.sha256
scripts/build_matrix.sh --build
# Then run from the bundle (see "Air-gap migration" above and docs/AIRGAP.md):
scripts/migrate_oneshot.sh --target 26 --os astra --source bundle --bundle dist/kc-astra-bundle.tar.xz --db-host <db-host> --go
```

---

## 🔧 Ways to run the tool (integrations)

> **Note:** these are ways to **run the migration tool itself**, not to deploy Keycloak.
> The Docker/Helm/Ansible/Terraform integrations and cloud examples are currently listed in the CHANGELOG as
> **[Unreleased] Planned** — documented but not yet shipped.

### Docker (CI/CD and isolation)
```bash
docker run --rm \
  -v $(pwd)/profiles:/data \
  -v ~/.kube:/root/.kube \
  ghcr.io/<owner>/keycloak-migration:redos-26.6.3 \
  --profile=/data/production.yaml
```

### Helm (K8s-native Job with RBAC)
```bash
helm install my-migration ./examples/helm/keycloak-migration \
  --set database.host=keycloak-db \
  --set migration.targetVersion=26.6.3
```

### Ansible (orchestration of >3 servers)
```bash
ansible-playbook -i inventory examples/ansible/keycloak-migration.yml \
  --limit production-servers
```

### Terraform (IaC)
```hcl
module "keycloak_migration" {
  source        = "./examples/terraform/modules/keycloak-migration"
  database_host = aws_db_instance.keycloak.endpoint
  target_version = "26.6.3"
}
```

### Cloud examples
AWS (EKS + RDS), GCP (GKE + Cloud SQL), Azure (AKS + Azure Database) — `examples/cloud/`.

---

## 📜 License

MIT License.

## 🤝 Contributing

1. Fork the repository;
2. Create a feature branch;
3. Add tests;
4. Make sure all tests pass: `./tests/run_all_tests.sh`;
5. Open a pull request.

## 📚 Documentation

- **[QUICKSTART.md](QUICKSTART.md)** — start here: every parameter, image sources, what
  happens at each step and what to do on failure;
- [docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md) — the full runbook;
- [docs/AIRGAP.md](docs/AIRGAP.md) — offline / sovereign delivery;
- [ARCHITECTURE.md](ARCHITECTURE.md) — accepted decisions (ADR-001 … ADR-013);
- [CHANGELOG.md](CHANGELOG.md) — what changed and what broke before it was fixed.

## 🏆 Authors

Developed by [AlexGromer](https://github.com/AlexGromer) with support from Claude Code.

---

**Repository:** https://github.com/AlexGromer/keycloak-migration
