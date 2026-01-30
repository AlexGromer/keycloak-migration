# Keycloak Migration Tool v3.5

**One-command Keycloak migration utility** with auto-detection, multi-tenant support, clustered deployments, real-time monitoring, production hardening, and support for all Keycloak-supported databases.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-90%2B-success)](tests/)
[![Bash](https://img.shields.io/badge/bash-5.0%2B-green.svg)](scripts/)
[![Databases](https://img.shields.io/badge/databases-7-blue.svg)](scripts/lib/database_adapter.sh)
[![Version](https://img.shields.io/badge/version-v3.5-blue.svg)](ROADMAP.md)

---

## 🚀 Quick Start (90% of cases)

### 1. Clone Repository

```bash
git clone https://github.com/AlexGromer/keycloak-migration
cd keycloak-migration
```

### 2. Run Migration Wizard

```bash
./scripts/config_wizard.sh
```

The wizard will:
1. **Auto-detect** existing Keycloak installation
2. **Auto-detect** current version from database/deployment
3. **Prompt** for target version selection
4. **Generate** migration profile
5. **Execute** migration with one command

### 3. Or Use Direct Command

If you already have a profile:

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=my-profile.yaml
```

**That's it!** The tool handles everything automatically.

---

## 🎯 Features

### Auto-Detection
- **Current Version** — Detects from JAR manifest, database, Docker image, or Kubernetes deployment
- **Database Type** — Auto-detects from JDBC URL or CLI tools
- **Deployment Mode** — Identifies Standalone, Docker, Kubernetes automatically
- **Target Version** — Interactive selection with Java requirements shown

### Multi-Database Support
- ✅ **PostgreSQL** (recommended)
- ✅ **MySQL / MariaDB**
- ✅ **CockroachDB** (v18+)
- ✅ **Oracle Database**
- ✅ **Microsoft SQL Server**
- ✅ **H2** (dev only, with warnings)

### Multi-Deployment Support
- ✅ **Standalone** (systemd, init.d, manual)
- ✅ **Docker** (single container)
- ✅ **Docker Compose** (multi-container)
- ✅ **Kubernetes** (Deployment, StatefulSet)
- ✅ **Custom** (bring your own scripts)

### Production-Ready
- ✅ **Extended Pre-flight Checks** — 15 comprehensive checks (disk, memory, network, DB health, Keycloak status, dependencies, credentials) (v3.5)
- ✅ **Rate Limiting** — Prevents production database overload with adaptive throttling (v3.5)
- ✅ **Backup Rotation** — Automatic cleanup with multiple policies (keep-last-N, time-based, size-based, GFS) (v3.5)
- ✅ **Connection Leak Detection** — Auto-detect and report idle connections (v3.5)
- ✅ **Circuit Breaker** — Automatic failure protection with retry logic (v3.5)
- ✅ **Atomic Checkpoints** — Resume from any step if interrupted
- ✅ **Auto-Rollback** — Automatic rollback on failure
- ✅ **Airgap Mode** — Pre-validate all artifacts available
- ✅ **JSON Audit Logging** — Full traceability
- ✅ **Real-Time Monitoring** — Prometheus metrics + Grafana dashboards (v3.1)
- ✅ **Multi-Tenant Support** — Parallel migration of isolated instances (v3.2)
- ✅ **Clustered Deployments** — Zero-downtime rolling updates (v3.2)
- ✅ **Test Coverage** — 90+ unit tests, ~96% pass rate

### Migration Path
Supports Keycloak **16.1.1 → 26.0.7** via safe intermediate versions:
```
16.1.1 → 17.0.1 → 22.0.5 → 25.0.6 → 26.0.7
```

Java requirements automatically validated per version (11 → 11 → 17 → 17 → 21).

---

## 📖 How It Works

This tool **migrates** your Keycloak installation, not deploys it. You need an existing Keycloak instance to migrate.

**The tool works by:**
1. Detecting your current Keycloak version and environment
2. Backing up the database
3. Stopping Keycloak service
4. Downloading/building the target version
5. Updating the database schema
6. Restarting with new version
7. Validating health and rollback if needed

**What it doesn't do:**
- ❌ Install Keycloak from scratch
- ❌ Provision infrastructure
- ❌ Configure networking/DNS

For infrastructure provisioning, see [Advanced Deployment Options](#advanced-deployment-options).

---

## 📦 Installation

### Prerequisites

- Bash 5.0+
- Existing Keycloak installation (16.1.1+)
- Database client (`psql`, `mysql`, `cockroach`, etc.)
- Java (version per Keycloak requirements)
- For Kubernetes: `kubectl`

### Clone and Run

```bash
git clone https://github.com/AlexGromer/keycloak-migration
cd keycloak-migration
./scripts/config_wizard.sh
```

---

## 🎮 Usage Examples

### 1. Interactive Wizard (Recommended)
```bash
./scripts/config_wizard.sh
```

Auto-discovers existing installations and generates YAML profile.

### 2. Non-Interactive (CI/CD)
```bash
export PROFILE_DB_TYPE=postgresql
export PROFILE_KC_DEPLOYMENT_MODE=kubernetes
export PROFILE_KC_CURRENT_VERSION=16.1.1
export PROFILE_KC_TARGET_VERSION=26.0.7

./scripts/config_wizard.sh --non-interactive --profile-name ci-migration
./scripts/migrate_keycloak_v3.sh migrate --profile ci-migration
```

### 3. Auto-Discovery Only
```bash
./scripts/kc_discovery.sh
```

Scans environment and creates profile automatically.

---

## 🚁 Advanced Usage

### Multi-Tenant Migration (v3.2)

**Scenario:** SaaS platform with multiple isolated Keycloak instances.

**Profile Example:** `profiles/multi-tenant-example.yaml`

```yaml
profile:
  name: multi-tenant-saas
  mode: multi-tenant  # Enable multi-tenant mode

migration:
  strategy: rolling_update
  parallel: true  # Migrate all tenants simultaneously

tenants:
  # Tenant 1: Enterprise customer
  - name: enterprise-corp
    database:
      host: db1.example.com
      name: keycloak_enterprise
    deployment:
      mode: kubernetes
      namespace: keycloak-enterprise
      replicas: 3

  # Tenant 2: SMB customer
  - name: smb-startup
    database:
      host: db2.example.com
      name: keycloak_smb
    deployment:
      mode: kubernetes
      namespace: keycloak-smb
      replicas: 2

rollout:
  type: parallel  # Options: parallel, sequential
  max_concurrent: 3  # Maximum tenants migrated simultaneously
```

**Execute:**

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=multi-tenant-saas.yaml
```

**Live Monitoring:**
```
┌─ MIGRATION PROGRESS (3/3 tenants) ────────────────────────────┐
│ enterprise-corp  |  87% [████████████████████░░░░░░] 16→26    │
│ smb-startup      |  92% [██████████████████████░░░] 16→26    │
│ trial-demo       | 100% [████████████████████████] 16→26 ✓   │
└────────────────────────────────────────────────────────────────┘
```

**Features:**
- ✅ Parallel or sequential execution
- ✅ Per-tenant checkpoints and rollback
- ✅ Aggregated audit logging
- ✅ Real-time progress monitoring for all tenants
- ✅ Independent failure handling (one fails, others continue)

---

### Clustered Deployment Migration (v3.2)

**Scenario:** 4 Keycloak standalone instances in cluster (bare-metal servers).

**Profile Example:** `profiles/clustered-bare-metal-example.yaml`

```yaml
profile:
  name: clustered-bare-metal
  mode: clustered  # Enable clustered mode

migration:
  strategy: rolling_update  # One node at a time
  auto_rollback: true

database:
  type: postgresql
  host: db-cluster.example.com  # Shared database
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

    - name: kc-node-2
      host: 192.168.1.102
      ssh_user: keycloak
      keycloak_home: /opt/keycloak

    - name: kc-node-3
      host: 192.168.1.103
      ssh_user: keycloak
      keycloak_home: /opt/keycloak

    - name: kc-node-4
      host: 192.168.1.104
      ssh_user: keycloak
      keycloak_home: /opt/keycloak

rollout:
  type: sequential  # Rolling update (recommended)
  nodes_at_once: 1  # Migrate one node at a time
  drain_timeout: 60  # Seconds to wait for connection drain
  startup_timeout: 120  # Seconds to wait for node health
```

**Execute:**

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=clustered-bare-metal.yaml
```

**Rolling Update Process:**
1. **Drain** node from load balancer (HAProxy)
2. **Wait** for active connections to finish
3. **Migrate** node to new version
4. **Health check** new version
5. **Enable** node in load balancer
6. **Repeat** for next node

**Features:**
- ✅ Zero-downtime rolling update
- ✅ Load balancer integration (HAProxy, Nginx)
- ✅ Connection draining before migration
- ✅ Health checks before re-enabling
- ✅ Automatic rollback on failure
- ✅ Per-node monitoring

---

### Advanced Migration Strategies (v3.3)

#### Blue-Green Deployment

**Scenario:** Zero-downtime migration with instant traffic switch.

**Profile Example:** `profiles/blue-green-k8s-istio.yaml`

```yaml
profile:
  name: blue-green-k8s-istio
  strategy: blue_green  # Enable Blue-Green mode

migration:
  current_version: "16.1.1"
  target_version: "26.0.7"

blue_green:
  old_environment: "blue"   # Current production
  new_environment: "green"  # New version deployment

  deployment:
    type: kubernetes
    namespace: keycloak
    replicas: 3

  traffic_router:
    type: istio  # Supports: istio, nginx, haproxy
    virtualservice: keycloak-vs
    namespace: keycloak
    subset_blue: v16
    subset_green: v26

  readiness_timeout: 600  # seconds
  keep_old: false  # Destroy blue after successful switch
  cleanup_delay: 300  # Wait 5 minutes before cleanup

database:
  type: postgresql
  host: postgres.keycloak.svc.cluster.local
  name: keycloak
```

**Execute:**

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=blue-green-k8s-istio.yaml
```

**Blue-Green Process:**
1. **Deploy** green environment (new version) alongside blue
2. **Wait** for green to be fully ready
3. **Validate** green environment (smoke tests, health checks)
4. **Switch** traffic from blue (100% → 0%) to green (0% → 100%)
5. **Cleanup** old blue environment (optional, configurable delay)

**Benefits:**
- ✅ Instant traffic switch (zero downtime)
- ✅ Easy rollback (switch back to blue)
- ✅ Full validation before cutover
- ✅ No database migration conflicts (both versions use same DB)

---

#### Canary Deployment

**Scenario:** Progressive rollout with validation at each phase.

**Profile Example:** `profiles/canary-k8s-istio.yaml`

```yaml
profile:
  name: canary-k8s-istio
  strategy: canary  # Enable Canary mode

migration:
  current_version: "16.1.1"
  target_version: "26.0.7"

canary:
  deployment:
    namespace: keycloak
    deployment: keycloak
    replicas: 10  # Total replicas

  traffic_router:
    type: istio
    virtualservice: keycloak-vs
    subset_old: v16
    subset_new: v26

  # Progressive rollout phases
  phases:
    - name: phase-1-initial
      percentage: 10       # 10% traffic to canary
      replicas: 1          # 1 canary replica
      duration: 3600       # 1 hour observation
      validation:
        error_rate_threshold: 0.01    # Max 1% errors
        latency_p99_threshold: 500    # Max 500ms p99
        min_requests: 100             # Min requests to evaluate

    - name: phase-2-half
      percentage: 50
      replicas: 5
      duration: 7200  # 2 hours
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 500

    - name: phase-3-full
      percentage: 100
      replicas: 10
      duration: 1800  # 30 min final check
      validation:
        error_rate_threshold: 0.01
        latency_p99_threshold: 500
        min_requests: 1000

  auto_rollback: true  # Auto-rollback on validation failure

validation:
  prometheus_url: http://prometheus.monitoring.svc.cluster.local:9090
```

**Execute:**

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=canary-k8s-istio.yaml
```

**Canary Process:**
1. **Phase 1:** Deploy 1 canary replica (10% traffic)
   - Migrate 1 replica to new version
   - Route 10% traffic to canary
   - **Validate:** error rate, latency, minimum requests
   - **Observe:** 1 hour
2. **Phase 2:** Scale to 5 replicas (50% traffic)
   - Migrate 4 more replicas
   - Route 50% traffic to canary
   - **Validate:** same metrics
   - **Observe:** 2 hours
3. **Phase 3:** Full rollout (100% traffic)
   - Migrate remaining replicas
   - Route 100% traffic to new version
   - **Validate:** final check
   - **Observe:** 30 minutes

**Auto-Rollback Triggers:**
- Error rate > threshold
- p99 latency > threshold
- Insufficient requests (unreliable metrics)
- 3 consecutive validation failures

**Benefits:**
- ✅ Risk mitigation through gradual rollout
- ✅ Automated validation at each phase (Prometheus metrics)
- ✅ Early detection of issues (10% exposure first)
- ✅ Automatic rollback on failure
- ✅ Continuous monitoring during observation periods

---

### Database-Specific Optimizations (v3.4)

#### Automatic Performance Tuning

**Features:**
- ✅ Auto-tuned parallel jobs (PostgreSQL backup/restore)
- ✅ Database size-aware optimization
- ✅ Post-migration VACUUM ANALYZE (PostgreSQL)
- ✅ Connection pool recommendations
- ✅ Percona XtraBackup integration (MySQL)
- ✅ MariaDB mariabackup support
- ✅ CockroachDB zone-aware backup
- ✅ Migration time estimation

**Usage:**

All optimizations are **automatic** — no configuration needed. The tool detects database type and applies appropriate optimizations.

**PostgreSQL:**

```bash
# Parallel backup/restore auto-tuned based on:
# - CPU cores available
# - Database size
# - Formula: min(cpu_cores, max(1, db_size_gb / 2))

# Example output during migration:
# [INFO] Auto-tuned parallel jobs: 4 (based on CPU cores and DB size)
# [INFO] Using parallel backup with 4 jobs
# [INFO] Database size: 12.5GB
# [INFO] Estimated backup time: 4 minutes (at 50MB/s)

# Post-migration optimizations:
# [INFO] Running VACUUM ANALYZE on database: keycloak
# [✓] VACUUM ANALYZE completed in 45s

# Configuration recommendations:
# [INFO] Recommended postgresql.conf settings:
#   max_connections = 208
#   shared_buffers = 2048MB
#   work_mem = 8MB
#   maintenance_work_mem = 512MB
#   effective_cache_size = 6144MB
```

**MySQL/MariaDB:**

```bash
# Percona XtraBackup (if available):
# [INFO] Using Percona XtraBackup for hot backup
# [✓] XtraBackup completed: /opt/backups/keycloak

# MariaDB mariabackup:
# [INFO] Using MariaDB mariabackup for hot backup

# InnoDB recommendations:
# [INFO] Recommended my.cnf settings:
#   innodb_buffer_pool_size = 6144M  # 75% of RAM
#   innodb_buffer_pool_instances = 6
#   innodb_log_file_size = 512M
#   innodb_flush_log_at_trx_commit = 2
#   innodb_flush_method = O_DIRECT

# Binary log management:
# [INFO] Purging old binary logs...
```

**CockroachDB:**

```bash
# Cluster information:
# [INFO] Cluster nodes: 3
# [INFO] Regions: us-east-1, us-west-1

# Native backup (zone-aware, multi-region):
# [INFO] Using CockroachDB native backup (zone-aware)
# [✓] Zone-aware backup completed

# Node draining (for rolling update):
# [INFO] Draining CockroachDB node 1...
# [✓] Node 1 drained
```

**Manual Override:**

If you want to disable auto-tuning and use specific values:

```yaml
# In profile YAML:
database:
  type: postgresql
  backup:
    parallel_jobs: 8  # Override auto-tuning (default: auto)
    verify: true      # Verify backup integrity (default: true)

  optimization:
    vacuum_analyze: true  # Run after migration (default: true)
    show_recommendations: true  # Show config tips (default: true)
```

**Benefits:**
- ⚡ **2-4x faster backups** (PostgreSQL parallel jobs)
- ⚡ **Up to 10x faster** (MySQL XtraBackup vs mysqldump)
- 🎯 **Optimized query performance** (VACUUM ANALYZE)
- 📊 **Right-sized configuration** (automatic recommendations)
- 🔒 **Backup verification** (integrity checks)
- ⏱️ **Accurate time estimates** (before starting migration)

---

### Production Hardening (v3.5)

#### Comprehensive Preflight Checks

**15 Production Safety Checks** run automatically before migration:

**System Resources:**
- ✅ Disk space (backup directory + minimum requirements)
- ✅ Memory availability
- ✅ Network connectivity

**Database Health:**
- ✅ Database connectivity
- ✅ Database version detection
- ✅ Database size calculation
- ✅ Replication status (PRIMARY vs REPLICA warning)

**Keycloak Health:**
- ✅ Keycloak service status
- ✅ Admin API credentials validation

**Backup Validation:**
- ✅ Backup space availability (3x database size)
- ✅ Backup directory permissions

**Dependencies:**
- ✅ Required tools (psql, mysql, cockroach, etc.)
- ✅ Java version compatibility

**Configuration:**
- ✅ Profile YAML syntax
- ✅ Credentials validation

**Usage:**

Preflight checks run **automatically** before every migration:

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=prod.yaml

# Output:
# ═══════════════════════════════════════════════════════════════
#   PREFLIGHT CHECKS — PRODUCTION SAFETY v3.5
# ═══════════════════════════════════════════════════════════════
#
# 1. DISK SPACE CHECK
# [INFO] Checking disk space on: /opt/backups
# [INFO] Required: 10GB minimum
# [INFO] Available space: 250GB
# [✓ PREFLIGHT] Disk space: 250GB (OK)
#
# 2. MEMORY CHECK
# [INFO] Required free memory: 2GB minimum
# [INFO] Available memory: 16GB
# [✓ PREFLIGHT] Memory: 16GB (OK)
#
# 3. NETWORK CONNECTIVITY CHECK
# [INFO] Testing connectivity to: postgres.keycloak.svc:5432
# [✓ PREFLIGHT] Network: postgres.keycloak.svc:5432 (reachable)
#
# 4. DATABASE CONNECTIVITY CHECK
# [INFO] Database: postgresql at postgres.keycloak.svc:5432/keycloak
# [✓ PREFLIGHT] PostgreSQL: Connected
#
# 5. DATABASE VERSION CHECK
# [INFO] PostgreSQL Version: PostgreSQL 15.4
# [✓ PREFLIGHT] Database version: OK
#
# 6. DATABASE SIZE CHECK
# [INFO] Database size: 12.50GB
# [✓ PREFLIGHT] Database size check: OK
#
# 7. DATABASE REPLICATION CHECK
# [✓ PREFLIGHT] Database is PRIMARY instance: OK
#
# ... (15 checks total)
#
# PREFLIGHT SUMMARY
# Total checks: 15
# Passed: 15
# Failed: 0
# Warnings: 0
#
# [✓ PREFLIGHT] PREFLIGHT PASSED — All checks successful
```

**Blocking Failures:**

If critical checks fail, migration is **blocked**:

```bash
# Example: Insufficient disk space
[✗ PREFLIGHT ERROR] Insufficient disk space: 5GB < 10GB
[✗ PREFLIGHT ERROR] Free up space or specify different backup location

PREFLIGHT SUMMARY
Passed: 12
Failed: 3
Warnings: 0

[✗ PREFLIGHT ERROR] PREFLIGHT FAILED — Cannot proceed with migration
[✗ PREFLIGHT ERROR] Failure reasons:
  - Disk space
  - Database connectivity
  - Missing dependencies

# Migration does NOT proceed until issues are fixed
```

#### Rate Limiting & Database Protection

**Prevents production database overload** during migration with intelligent throttling:

**Features:**
- ✅ **Fixed Rate:** Simple N ops/sec throttling
- ✅ **Token Bucket:** Burst handling with smoothing
- ✅ **Adaptive:** Monitors database load, adjusts rate dynamically
- ✅ **Circuit Breaker:** Stops on consecutive failures (5 threshold)
- ✅ **Exponential Backoff:** Retry logic with increasing delays
- ✅ **Connection Pool Monitoring:** Warns when usage > 80%
- ✅ **Leak Detection:** Finds idle-in-transaction connections

**Automatic Rate Limiting:**

All database operations are rate-limited automatically:

```bash
# Example output during migration:
[RATE LIMITER] Processing backup operations with adaptive strategy
[RATE LIMITER] DB load: 45%, rate adjusted: 10 → 7 ops/sec
[CONNECTION POOL] Active: 45 / 100 (45%)
[RATE LIMITER] Progress: 1250/5000 (25%)

# If database is overloaded (>80% connections):
[RATE LIMITER] DB load: 85%, rate adjusted: 10 → 2 ops/sec
[CONNECTION POOL WARNING] Usage above 80% — reducing rate

# Circuit breaker protection:
[CIRCUIT BREAKER] Failure count: 3/5
[CIRCUIT BREAKER] State: OPEN (too many failures: 5)
[RATE LIMITER ERROR] Circuit breaker OPEN, blocking operations for 30s
```

**Configuration:**

```yaml
# In profile YAML (optional):
migration:
  rate_limiting:
    enabled: true
    strategy: adaptive  # fixed | token_bucket | adaptive
    ops_per_second: 10  # Base rate (adaptive adjusts this)
    circuit_breaker:
      threshold: 5      # Failures before circuit opens
      timeout: 30       # Seconds before retry
```

#### Backup Rotation Policies

**Automatic cleanup** of old backups with multiple strategies:

**Policies:**
1. **Keep Last N:** Retain only the N most recent backups
2. **Time-Based:** Delete backups older than X days
3. **Size-Based:** Delete oldest when total size exceeds limit
4. **GFS (Grandfather-Father-Son):** Daily/Weekly/Monthly retention
5. **Combined:** Mix of all policies

**Usage:**

Backup rotation runs **automatically** after successful migration:

```bash
# Output:
═══════════════════════════════════════════════════════════════
  BACKUP ROTATION (PRODUCTION SAFETY v3.5)
═══════════════════════════════════════════════════════════════

[ROTATION INFO] Policy: Keep last 5 backups
[ROTATION INFO] Directory: /opt/migration_workspace/backups
[ROTATION INFO] Pattern: *.dump
[ROTATION INFO] Found 8 backup(s)
[ROTATION INFO] Deleting old backup: backup_20260110_120000.dump
[ROTATION INFO] Deleting old backup: backup_20260111_120000.dump
[ROTATION INFO] Deleting old backup: backup_20260112_120000.dump
[✓ ROTATION] Deleted 3 backup(s), freed 45120MB

Backup Statistics for: /opt/migration_workspace/backups
[ROTATION INFO] Total backups: 5
[ROTATION INFO] Total size: 75.50GB
[ROTATION INFO] Oldest backup: backup_20260120_120000.dump (10 days old)
[ROTATION INFO] Newest backup: backup_20260130_120000.dump (1 hours ago)
[ROTATION INFO] Average backup size: 15100MB
[ROTATION INFO] Available disk space: 175GB
[✓ ROTATION] Disk space: OK (175GB available)
```

**Configuration:**

```yaml
# In profile YAML:
backup:
  rotation:
    policy: keep_last_n  # keep_last_n | time_based | size_based | gfs | combined
    keep_count: 5        # For keep_last_n
    max_age_days: 30     # For time_based
    max_size_gb: 100     # For size_based

    # For GFS (Grandfather-Father-Son):
    # policy: gfs
    # daily_keep: 7      # 7 daily backups
    # weekly_keep: 4     # 4 weekly backups (Sundays)
    # monthly_keep: 12   # 12 monthly backups (1st of month)
```

**Manual Rotation:**

```bash
# Run rotation manually
cd /opt/kk_migration
source scripts/lib/backup_rotation.sh

# Keep last 5 backups
rotate_keep_last_n /opt/backups 5

# Delete backups older than 30 days
rotate_by_age /opt/backups 30

# Keep total size under 100GB
rotate_by_size /opt/backups 100

# GFS policy (7 daily, 4 weekly, 12 monthly)
rotate_gfs /opt/backups 7 4 12

# Get statistics
get_backup_statistics /opt/backups
```

**Benefits:**
- 💾 **Automatic cleanup** — No manual backup management
- 📊 **Multiple policies** — Choose strategy that fits your needs
- 🔒 **Configurable retention** — Keep what you need, delete the rest
- 📈 **Disk space monitoring** — Warns when space is low
- 🎯 **GFS support** — Industry-standard enterprise retention

---

### Monitoring Integration (v3.1)

Enable real-time monitoring during migration:

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile=prod.yaml --enable-monitoring
```

**Start monitoring stack:**

```bash
cd examples/monitoring
docker-compose up -d
```

**Access dashboards:**
- **Grafana:** http://localhost:3000 (7 panels, auto-refresh 5s)
- **Prometheus:** http://localhost:9091 (metrics endpoint)
- **Alertmanager:** http://localhost:9093 (11 alert rules)

**Metrics exported:**
- `keycloak_migration_progress` — Progress percentage (0.0 to 1.0)
- `keycloak_migration_checkpoint_status` — Checkpoint states
- `keycloak_migration_duration_seconds` — Total migration time
- `keycloak_migration_errors_total` — Error counter
- `keycloak_migration_database_size_bytes` — DB size before/after
- `keycloak_migration_java_heap_bytes` — Java memory usage
- `keycloak_migration_last_success_timestamp` — Last successful migration

**Multi-instance labels:**
- `tenant="enterprise-corp"` — Per-tenant metrics
- `node="kc-node-3"` — Per-node metrics

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    KEYCLOAK MIGRATION v3.0                      │
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

### Adapters

**Database Adapter** (`scripts/lib/database_adapter.sh`)
- `db_validate_type()` — Validate database type
- `db_detect_type()` — Auto-detect from JDBC URL
- `db_build_jdbc_url()` — Generate JDBC connection string
- `db_backup()` / `db_restore()` — Database operations

**Deployment Adapter** (`scripts/lib/deployment_adapter.sh`)
- `deploy_validate_mode()` — Validate deployment mode
- `deploy_detect_mode()` — Auto-detect (systemd/docker/k8s)
- `kc_start()` / `kc_stop()` — Lifecycle management
- `kc_health_check()` — Health verification

**Distribution Handler** (`scripts/lib/distribution_handler.sh`)
- `dist_download()` — Fetch Keycloak distribution
- `dist_validate_airgap()` — Validate offline artifacts
- `dist_check_network()` — Network reachability

---

## 📋 Usage Examples

### Standalone → Kubernetes Migration
```bash
# 1. Create profile
./scripts/config_wizard.sh

# 2. Plan (dry-run)
./scripts/migrate_keycloak_v3.sh plan --profile standalone-postgresql

# 3. Migrate
./scripts/migrate_keycloak_v3.sh migrate --profile standalone-postgresql

# 4. Rollback (if needed)
./scripts/migrate_keycloak_v3.sh rollback
```

### Kubernetes Rolling Update
```yaml
# profiles/k8s-production.yaml
profile:
  name: k8s-production

database:
  type: postgresql
  location: external
  host: postgres.prod.svc.cluster.local
  port: 5432
  name: keycloak
  user: keycloak

keycloak:
  deployment_mode: kubernetes
  cluster_mode: infinispan
  current_version: 16.1.1
  target_version: 26.0.7

  kubernetes:
    namespace: keycloak
    deployment: keycloak
    replicas: 3

migration:
  strategy: rolling_update  # Zero-downtime
  run_smoke_tests: true
  backup_before_step: true
```

```bash
./scripts/migrate_keycloak_v3.sh migrate --profile k8s-production
```

### Airgap Migration
```bash
# 1. Pre-download all artifacts
./scripts/migrate_keycloak_v3.sh download --profile airgap-migration

# 2. Transfer to airgap environment
scp -r ./dist/ airgap-server:/opt/keycloak-migration/

# 3. Run migration in airgap mode
./scripts/migrate_keycloak_v3.sh migrate --profile airgap-migration --airgap
```

---

## 🧪 Testing

```bash
# Run all tests
./tests/run_all_tests.sh

# Run specific suite
./tests/test_database_adapter.sh
./tests/test_deployment_adapter.sh
./tests/test_profile_manager.sh
./tests/test_migration_logic.sh
```

**Test Results:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SUITES: 4 | PASSED: 4 | FAILED: 0
  TOTAL:  137 tests
  PASSED: 137
  FAILED: 0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 📁 Project Structure

```
kk_migration/
├── scripts/
│   ├── migrate_keycloak_v3.sh      # Main migration script
│   ├── config_wizard.sh            # Interactive configuration
│   ├── kc_discovery.sh             # Auto-discovery
│   └── lib/
│       ├── database_adapter.sh     # DB abstraction (5 databases)
│       ├── deployment_adapter.sh   # Deployment abstraction (5 modes)
│       ├── profile_manager.sh      # YAML profile handling
│       ├── distribution_handler.sh # Artifact management
│       ├── keycloak_discovery.sh   # Environment scanning
│       └── audit_logger.sh         # JSON audit logging
│
├── profiles/                       # YAML configuration profiles
│   ├── standalone-postgresql.yaml
│   ├── standalone-mysql.yaml
│   ├── docker-compose-dev.yaml
│   └── kubernetes-cluster-production.yaml
│
├── tests/                          # Unit tests (137 tests, 100% pass)
│   ├── test_framework.sh
│   ├── test_database_adapter.sh
│   ├── test_deployment_adapter.sh
│   ├── test_profile_manager.sh
│   ├── test_migration_logic.sh
│   └── run_all_tests.sh
│
└── README.md
```

---

## 🔧 Configuration

### YAML Profile Example
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
  distribution_mode: download
  cluster_mode: standalone

  current_version: 16.1.1
  target_version: 26.0.7

migration:
  strategy: inplace
  parallel_jobs: 4
  timeout_per_version: 900
  run_smoke_tests: true
  backup_before_step: true
```

### Environment Variables
```bash
# Database credentials
export KC_DB_PASSWORD="secret"

# Non-interactive mode
export NON_INTERACTIVE=true
export PROFILE_DB_TYPE=postgresql
export PROFILE_KC_DEPLOYMENT_MODE=kubernetes

# Migration options
export AIRGAP_MODE=true
export AUTO_ROLLBACK=true
export SKIP_PREFLIGHT=false
```

---

## 🚀 Advanced Features

### Atomic Checkpoints
Resume migration from any step:
```
backup_done → stopped → downloaded → built →
started → migrated → health_ok → tests_ok
```

If migration fails at `health_ok`, fix the issue and resume:
```bash
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
# Automatically resumes from last checkpoint
```

### Auto-Rollback
```bash
# Enable auto-rollback on health check failure
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --auto-rollback
```

### Audit Logging
All operations logged to `migration_audit.jsonl`:
```json
{"ts":"2026-01-29T21:15:00Z","level":"INFO","event":"migration_start","msg":"Migration started","host":"kali","user":"admin","profile":"k8s-prod","from_version":"16.1.1","to_version":"26.0.7"}
{"ts":"2026-01-29T21:16:32Z","level":"INFO","event":"backup_created","msg":"Backup for 17.0.1","version":"17.0.1","backup_path":"/opt/backup_17.0.1.dump","size_bytes":"458123456"}
{"ts":"2026-01-29T21:18:45Z","level":"INFO","event":"migration_step","msg":"Step migrated: 17.0.1","version":"17.0.1","status":"migrated","duration_s":"133"}
{"ts":"2026-01-29T21:35:12Z","level":"INFO","event":"migration_end","msg":"Migration success","profile":"k8s-prod","status":"success","total_duration_s":"1212"}
```

---

## 🛠️ CLI Reference

```bash
# Migration commands
./scripts/migrate_keycloak_v3.sh migrate --profile <name>
./scripts/migrate_keycloak_v3.sh plan --profile <name>
./scripts/migrate_keycloak_v3.sh rollback [--force]

# Flags
--airgap              # Offline mode (validate artifacts first)
--auto-rollback       # Auto-rollback on failure
--skip-preflight      # Skip pre-flight checks (not recommended)
--dry-run             # Show plan without executing

# Profile management
./scripts/migrate_keycloak_v3.sh profile list
./scripts/migrate_keycloak_v3.sh profile validate <name>

# Auto-discovery
./scripts/kc_discovery.sh [--output <profile-name>]
```

---

## 📊 System Requirements

- **OS:** Linux (tested on Debian, Ubuntu, RHEL, Kali)
- **Bash:** 5.0+
- **Disk Space:** 15GB free (for backups + distributions)
- **Memory:** 4GB+ recommended
- **Java:** 11, 17, 21 (auto-validated per version)

### Optional Tools
- `kubectl` — for Kubernetes deployments
- `docker` / `docker-compose` — for Docker deployments
- `helm` — for Helm-based deployments
- `gitleaks` / `trufflehog` — for secrets scanning
- `jq` — for JSON parsing (audit logs)

---

## 🐛 Troubleshooting

### Common Issues

**Issue:** `Java version insufficient`
```bash
# Solution: Set JAVA_HOME for specific version
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
```

**Issue:** Migration fails at checkpoint
```bash
# Solution: Resume from last checkpoint
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
# Automatically continues from where it stopped
```

**Issue:** Health check fails
```bash
# Solution: Check logs and rollback
./scripts/migrate_keycloak_v3.sh rollback

# Or enable auto-rollback
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile --auto-rollback
```

**Issue:** Airgap validation fails
```bash
# Solution: Pre-download all artifacts
./scripts/migrate_keycloak_v3.sh download --profile my-profile
# Then run migration in airgap mode
```

---

## 🔧 Advanced Usage Options

For specific infrastructure setups, the migration tool supports integration with automation platforms. **Note:** These are ways to RUN the migration tool, not deploy Keycloak itself.

### Docker (CI/CD & Isolation)

**When to use:** GitLab CI, GitHub Actions, or when you need isolated dependencies.

```bash
docker run --rm \
  -v $(pwd)/profiles:/data \
  -v ~/.kube:/root/.kube \
  alexgromer/keycloak-migration:3.0.0 \
  --profile=/data/production.yaml
```

**Use case:** Clean environment with pre-installed Java/kubectl/helm.

See: [Dockerfile](Dockerfile)

---

### Helm (Kubernetes-Native)

**When to use:** Keycloak deployed in Kubernetes, need integration with K8s Secrets/ConfigMaps.

```bash
helm install my-migration ./examples/helm/keycloak-migration \
  --set database.host=keycloak-db \
  --set migration.targetVersion=26.0.7
```

**Use case:** Migration as Kubernetes Job with RBAC, automatic retry, kubectl logs.

See: [examples/helm/README.md](examples/helm/README.md)

---

### Ansible (Multi-Server Orchestration)

**When to use:** Multiple servers (>3) need migration, centralized configuration management.

```bash
ansible-playbook -i inventory examples/ansible/keycloak-migration.yml \
  --limit production-servers
```

**Use case:** Migrate 10+ Keycloak instances with one command.

See: [examples/ansible/README.md](examples/ansible/README.md)

---

### Terraform (IaC Integration)

**When to use:** Migration as part of infrastructure code, idempotent deployment.

```hcl
module "keycloak_migration" {
  source = "./examples/terraform/modules/keycloak-migration"

  database_host = aws_db_instance.keycloak.endpoint
  target_version = "26.0.7"
}
```

**Use case:** Create infrastructure + migrate in one `terraform apply`.

See: [examples/terraform/README.md](examples/terraform/README.md)

---

### Cloud-Specific Examples

Pre-configured examples for major cloud providers:

- **AWS:** EKS + RDS ([examples/cloud/aws/](examples/cloud/))
- **GCP:** GKE + Cloud SQL ([examples/cloud/gcp/](examples/cloud/))
- **Azure:** AKS + Azure Database ([examples/cloud/azure/](examples/cloud/))

---

## 📜 License

MIT License

---

## 🤝 Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `./tests/run_all_tests.sh`
5. Submit a pull request

---

## 📚 Documentation

- [Architecture](V3_ARCHITECTURE.md) — Detailed design documentation
- [Quick Start](QUICK_START.md) — Step-by-step guide
- [Auto-Discovery](AUTO_DISCOVERY_DEMO.md) — Auto-discovery examples
- [Improvements](scripts/IMPROVEMENTS_APPLIED.md) — v2.0 → v3.0 changelog

---

## 🏆 Credits

Built with ❤️ by [AlexGromer](https://github.com/AlexGromer)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>

---

**Repository:** https://github.com/AlexGromer/keycloak-migration
