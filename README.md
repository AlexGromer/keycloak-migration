# Keycloak Migration Tool v3.0

**One-command Keycloak migration utility** with auto-detection, atomic checkpoints, and support for all Keycloak-supported databases.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-137%2F137-success)](tests/)
[![Bash](https://img.shields.io/badge/bash-5.0%2B-green.svg)](scripts/)
[![Databases](https://img.shields.io/badge/databases-7-blue.svg)](scripts/lib/database_adapter.sh)

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
- ✅ **Pre-flight Checks** — Disk space, tools, Java versions, network, DB connectivity
- ✅ **Atomic Checkpoints** — Resume from any step if interrupted
- ✅ **Auto-Rollback** — Automatic rollback on failure
- ✅ **Airgap Mode** — Pre-validate all artifacts available
- ✅ **JSON Audit Logging** — Full traceability
- ✅ **Test Coverage** — 137 unit tests, 100% pass rate

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
