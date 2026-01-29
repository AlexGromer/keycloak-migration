# Keycloak Migration Utility v3.0 - Architecture

**Universal Migration Tool for All Environments**

---

## Overview

v3.0 расширяет v2.0 поддержкой различных СУБД, окружений развёртывания, схем дистрибуции и кластерных конфигураций.

---

## Architecture Matrix

### 1. Database Support

| DBMS | Support | Backup Tool | Restore Tool | Connection String |
|------|---------|-------------|--------------|-------------------|
| **PostgreSQL** | ✅ Full | `pg_dump` | `pg_restore` | `jdbc:postgresql://` |
| **MySQL** | ✅ Full | `mysqldump` | `mysql` | `jdbc:mysql://` |
| **MariaDB** | ✅ Full | `mariabackup` / `mysqldump` | `mysql` | `jdbc:mariadb://` |
| **Oracle** | ⚠️ Limited | `expdp` | `impdp` | `jdbc:oracle:thin:@` |
| **MSSQL** | ⚠️ Limited | `sqlcmd` | `sqlcmd` | `jdbc:sqlserver://` |

**Auto-detection:**
```bash
# Via JDBC URL
jdbc:postgresql:// → PostgreSQL
jdbc:mysql://      → MySQL
jdbc:mariadb://    → MariaDB

# Via CLI tools
psql --version     → PostgreSQL
mysql --version    → MySQL/MariaDB (check vendor)
```

---

### 2. Deployment Modes

| Mode | Description | Migration Strategy | Health Check |
|------|-------------|-------------------|--------------|
| **Standalone** | Filesystem, systemd | Direct file operations | `curl localhost:8080` |
| **Docker** | Single/multi container | `docker exec`, volume mounts | `docker exec curl` |
| **Docker Compose** | Multi-service stack | Restart containers | `docker-compose exec` |
| **Kubernetes** | K8s native | Rolling update, pods | `kubectl exec` |
| **Deckhouse** | K8s + Deckhouse modules | Helm charts, moduleconfig | `kubectl exec` |

**Auto-detection:**
```bash
# Check running environment
if docker ps &>/dev/null && pgrep -f "keycloak" | xargs -I {} cat /proc/{}/cgroup | grep -q docker; then
    MODE="docker"
elif kubectl get pods &>/dev/null; then
    MODE="kubernetes"
    if kubectl get moduleconfig &>/dev/null; then
        MODE="deckhouse"
    fi
else
    MODE="standalone"
fi
```

---

### 3. Distribution Modes

| Mode | Source | Pros | Cons |
|------|--------|------|------|
| **Download** | GitHub releases | Always latest | Network required, slow |
| **Pre-downloaded** | Local tar.gz files | Fast, offline | Manual prep needed |
| **Container** | docker.io/keycloak | Standard, immutable | Requires container runtime |
| **Helm** | Helm charts | K8s native, templated | Complex config |

**Configuration:**
```yaml
distribution:
  mode: download | predownloaded | container | helm
  source:
    download: https://github.com/keycloak/keycloak/releases/
    predownloaded: /opt/keycloak_archives/
    container: docker.io/keycloak/keycloak
    helm: codecentric/keycloak
```

---

### 4. Cluster Modes

| Mode | Description | Components | Migration Strategy |
|------|-------------|------------|-------------------|
| **Standalone** | Single instance | KC only | Standard migration |
| **Cluster (Infinispan)** | Multi-node, embedded cache | KC + Infinispan | Rolling update |
| **Cluster (External)** | Multi-node, external cache | KC + Redis/Hazelcast | Blue-green deployment |
| **Cluster (DB)** | Multi-node, shared DB | KC nodes + DB cluster | Coordinated migration |

**Detection:**
```bash
# Check cluster config
if grep -q "cache-stack" keycloak.conf; then
    CLUSTER_MODE="infinispan"
elif kubectl get statefulset -l app=keycloak | grep -q "replicas.*[2-9]"; then
    CLUSTER_MODE="kubernetes_cluster"
else
    CLUSTER_MODE="standalone"
fi
```

---

### 5. Database Location

| Location | Description | Connection | Backup Strategy |
|----------|-------------|------------|-----------------|
| **Standalone** | Local PostgreSQL | localhost:5432 | Standard pg_dump |
| **Docker** | Container DB | container_name:5432 | `docker exec pg_dump` |
| **Kubernetes** | K8s service | svc/postgres:5432 | `kubectl exec pg_dump` |
| **External** | Managed DB (RDS, etc) | external.host:5432 | Cloud-native backup |
| **Cluster** | DB cluster (Patroni, etc) | vip:5432 | Cluster-aware backup |

---

## v3.0 Features

### Configuration Profiles

**Example: `production.yaml`**
```yaml
profile:
  name: production
  environment: kubernetes

database:
  type: postgresql
  location: kubernetes  # standalone | docker | kubernetes | external | cluster
  host: postgres-postgresql.database.svc.cluster.local
  port: 5432
  name: keycloak
  user: keycloak
  credentials_source: secret  # env | file | secret | vault

keycloak:
  deployment_mode: kubernetes
  distribution_mode: container
  cluster_mode: infinispan

  current_version: 16.1.1
  target_version: 26.0.7

  kubernetes:
    namespace: keycloak
    deployment: keycloak
    service: keycloak-http
    replicas: 3

  container:
    registry: docker.io
    image: keycloak/keycloak
    pull_policy: IfNotPresent

migration:
  strategy: rolling_update  # inplace | rolling_update | blue_green
  parallel_jobs: 4
  timeout_per_version: 900
  run_smoke_tests: true
  backup_before_step: true
```

---

### Interactive Wizard

```bash
./scripts/migrate_keycloak_v3.sh --wizard

┌─────────────────────────────────────────────────────────────────┐
│   Keycloak Migration Configuration Wizard v3.0                  │
└─────────────────────────────────────────────────────────────────┘

[1/7] Database Type
  1) PostgreSQL (detected: psql 15.6)
  2) MySQL
  3) MariaDB
  4) Oracle

Your choice [1]: 1

[2/7] Database Location
  1) Standalone (localhost)
  2) Docker container (detected: postgres_container)
  3) Kubernetes service (detected: postgres-postgresql.database.svc)
  4) External (RDS, Cloud SQL, etc.)
  5) Database cluster (Patroni, PgPool, etc.)

Your choice [3]: 3

[3/7] Keycloak Deployment Mode
  1) Standalone (systemd/filesystem)
  2) Docker (single container)
  3) Docker Compose (detected: docker-compose.yml)
  4) Kubernetes (detected: deployment/keycloak)
  5) Deckhouse (detected: moduleconfig)

Your choice [4]: 4

[4/7] Keycloak Distribution
  1) Download from GitHub
  2) Use pre-downloaded archives (/opt/keycloak_archives/)
  3) Container images (docker.io/keycloak)
  4) Helm charts

Your choice [3]: 3

[5/7] Keycloak Cluster Mode
  1) Standalone (single instance)
  2) Cluster with Infinispan (detected: 3 replicas)
  3) Cluster with external cache (Redis/Hazelcast)

Your choice [2]: 2

[6/7] Migration Strategy
  1) In-place (stop → migrate → start)
  2) Rolling update (one pod at a time) - RECOMMENDED for clusters
  3) Blue-green (new deployment alongside old)

Your choice [2]: 2

[7/7] Additional Options
  Run smoke tests after each version? [Y/n]: y
  Create backups before each step? [Y/n]: y
  Parallel jobs for backup (1-8) [4]: 4
  Timeout per version (seconds) [900]: 900

Configuration Summary:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Profile:           kubernetes-cluster-production
  Database:          PostgreSQL (Kubernetes service)
  Deployment:        Kubernetes (3 replicas)
  Distribution:      Container images
  Cluster Mode:      Infinispan
  Strategy:          Rolling update
  Smoke Tests:       Enabled
  Backups:           Enabled
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Save this profile? [Y/n]: y
Profile saved to: profiles/kubernetes-cluster-production.yaml

Start migration now? [y/N]: y
```

---

### Multi-Database Adapter Pattern

```bash
# Database abstraction layer
case "$DB_TYPE" in
    postgresql)
        db_backup()   { pg_dump -h $HOST -U $USER -d $DB -F c -f "$1"; }
        db_restore()  { pg_restore -h $HOST -U $USER -d $DB --clean "$1"; }
        db_test()     { psql -h $HOST -U $USER -d $DB -c "SELECT 1"; }
        db_version()  { psql -h $HOST -U $USER -d $DB -t -c "SHOW server_version;"; }
        jdbc_url="jdbc:postgresql://$HOST:$PORT/$DB"
        ;;

    mysql|mariadb)
        db_backup()   { mysqldump -h $HOST -u $USER -p$PASS $DB > "$1"; }
        db_restore()  { mysql -h $HOST -u $USER -p$PASS $DB < "$1"; }
        db_test()     { mysql -h $HOST -u $USER -p$PASS -e "SELECT 1"; }
        db_version()  { mysql -h $HOST -u $USER -p$PASS -e "SELECT VERSION();"; }
        jdbc_url="jdbc:$DB_TYPE://$HOST:$PORT/$DB"
        ;;

    oracle)
        db_backup()   { expdp $USER/$PASS@$HOST:$PORT/$DB directory=BACKUP_DIR dumpfile="$1"; }
        db_restore()  { impdp $USER/$PASS@$HOST:$PORT/$DB directory=BACKUP_DIR dumpfile="$1"; }
        db_test()     { echo "SELECT 1 FROM DUAL;" | sqlplus -S $USER/$PASS@$HOST:$PORT/$DB; }
        db_version()  { echo "SELECT * FROM V\$VERSION;" | sqlplus -S $USER/$PASS@$HOST:$PORT/$DB; }
        jdbc_url="jdbc:oracle:thin:@$HOST:$PORT:$DB"
        ;;
esac
```

---

### Deployment Mode Adapter Pattern

```bash
# Deployment abstraction layer
case "$DEPLOY_MODE" in
    standalone)
        kc_start()    { systemctl start keycloak; }
        kc_stop()     { systemctl stop keycloak; }
        kc_status()   { systemctl status keycloak; }
        kc_logs()     { journalctl -u keycloak -f; }
        kc_exec()     { "$@"; }
        ;;

    docker)
        kc_start()    { docker start $CONTAINER_NAME; }
        kc_stop()     { docker stop $CONTAINER_NAME; }
        kc_status()   { docker ps -f name=$CONTAINER_NAME; }
        kc_logs()     { docker logs -f $CONTAINER_NAME; }
        kc_exec()     { docker exec $CONTAINER_NAME "$@"; }
        ;;

    kubernetes)
        kc_start()    { kubectl scale deployment/$DEPLOYMENT --replicas=$REPLICAS -n $NAMESPACE; }
        kc_stop()     { kubectl scale deployment/$DEPLOYMENT --replicas=0 -n $NAMESPACE; }
        kc_status()   { kubectl get pods -l app=keycloak -n $NAMESPACE; }
        kc_logs()     { kubectl logs -f deployment/$DEPLOYMENT -n $NAMESPACE; }
        kc_exec()     { kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -- "$@"; }
        ;;

    deckhouse)
        kc_start()    { kubectl patch moduleconfig keycloak --type=merge -p '{"spec":{"enabled":true}}'; }
        kc_stop()     { kubectl patch moduleconfig keycloak --type=merge -p '{"spec":{"enabled":false}}'; }
        kc_status()   { kubectl get moduleconfig keycloak -o jsonpath='{.status.state}'; }
        kc_logs()     { kubectl logs -f -l app=keycloak -n d8-keycloak; }
        kc_exec()     { kubectl exec -n d8-keycloak deployment/keycloak -- "$@"; }
        ;;
esac
```

---

### Rolling Update Strategy (Kubernetes)

```bash
rolling_update_kubernetes() {
    local target_version="$1"

    log_section "ROLLING UPDATE TO KC $target_version"

    # 1. Update image in deployment
    kubectl set image deployment/$DEPLOYMENT \
        keycloak=$REGISTRY/$IMAGE:$target_version \
        -n $NAMESPACE

    # 2. Wait for rollout
    kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=${MIGRATION_TIMEOUT}s

    # 3. Monitor pods one by one
    local replicas=$(kubectl get deployment/$DEPLOYMENT -n $NAMESPACE -o jsonpath='{.spec.replicas}')

    for i in $(seq 1 $replicas); do
        log_info "Waiting for pod $i/$replicas to become ready..."

        # Wait for pod to be ready
        kubectl wait --for=condition=ready pod \
            -l app=keycloak -n $NAMESPACE \
            --timeout=300s

        # Run smoke tests on this pod
        local pod=$(kubectl get pods -l app=keycloak -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')

        if run_smoke_tests_pod "$pod"; then
            log_success "Pod $i/$replicas migrated successfully"
        else
            log_error "Pod $i/$replicas smoke tests failed"

            # Rollback
            kubectl rollout undo deployment/$DEPLOYMENT -n $NAMESPACE
            return 1
        fi
    done

    log_success "Rolling update to KC $target_version completed"
}
```

---

### Blue-Green Deployment Strategy

```bash
blue_green_deployment() {
    local target_version="$1"

    log_section "BLUE-GREEN DEPLOYMENT TO KC $target_version"

    # 1. Create green deployment (new version)
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak-green
  namespace: $NAMESPACE
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      app: keycloak
      version: green
  template:
    metadata:
      labels:
        app: keycloak
        version: green
    spec:
      containers:
      - name: keycloak
        image: $REGISTRY/$IMAGE:$target_version
        # ... rest of config
EOF

    # 2. Wait for green to be ready
    kubectl wait --for=condition=available deployment/keycloak-green -n $NAMESPACE --timeout=600s

    # 3. Run smoke tests on green
    if run_smoke_tests_deployment "keycloak-green"; then
        log_success "Green deployment smoke tests passed"
    else
        log_error "Green deployment smoke tests failed"
        kubectl delete deployment keycloak-green -n $NAMESPACE
        return 1
    fi

    # 4. Switch service to green
    kubectl patch service keycloak -n $NAMESPACE -p '{"spec":{"selector":{"version":"green"}}}'

    log_info "Traffic switched to green deployment"
    sleep 30  # Grace period

    # 5. Delete blue deployment
    kubectl delete deployment keycloak-blue -n $NAMESPACE

    # 6. Rename green → blue
    kubectl patch deployment keycloak-green -n $NAMESPACE --type=json \
        -p='[{"op":"replace","path":"/metadata/name","value":"keycloak-blue"}]'

    log_success "Blue-green deployment completed"
}
```

---

## Implementation Plan

### Phase 1: Core Abstraction (Week 1)
- [ ] Database adapter interface
- [ ] Deployment mode adapter interface
- [ ] Configuration profile system
- [ ] Auto-detection logic

### Phase 2: Database Support (Week 2)
- [ ] PostgreSQL adapter (existing)
- [ ] MySQL/MariaDB adapter
- [ ] Oracle adapter (basic)
- [ ] Database migration tests

### Phase 3: Deployment Modes (Week 3)
- [ ] Standalone adapter (existing)
- [ ] Docker adapter
- [ ] Kubernetes adapter
- [ ] Deckhouse adapter

### Phase 4: Advanced Features (Week 4)
- [ ] Rolling update strategy
- [ ] Blue-green deployment
- [ ] Cluster mode support
- [ ] Configuration wizard

### Phase 5: Testing & Documentation (Week 5)
- [ ] Test matrix (all combinations)
- [ ] Migration guides per environment
- [ ] Troubleshooting playbooks
- [ ] Video tutorials

---

## Testing Matrix

| DB | Deploy | Dist | Cluster | Status |
|----|--------|------|---------|--------|
| PostgreSQL | Standalone | Download | No | ✅ v2.0 |
| PostgreSQL | Docker | Container | No | 🔄 v3.0 |
| PostgreSQL | Kubernetes | Container | Yes | 🔄 v3.0 |
| MySQL | Standalone | Download | No | 🔄 v3.0 |
| MySQL | Kubernetes | Container | Yes | 🔄 v3.0 |
| MariaDB | Docker | Container | No | 🔄 v3.0 |
| Oracle | Standalone | Download | No | 🔄 v3.0 |

**Target: 20+ tested combinations**

---

## Backward Compatibility

v3.0 maintains 100% backward compatibility with v2.0:

```bash
# v2.0 style (still works)
./scripts/migrate_keycloak_v3.sh migrate -W password

# v3.0 style (new)
./scripts/migrate_keycloak_v3.sh migrate --profile production.yaml
```

If no `--profile` specified, defaults to v2.0 behavior (PostgreSQL standalone).

---

**Status**: 📋 Architecture designed, ready for implementation
**ETA**: 5 weeks (phased rollout)
**Complexity**: High (multi-environment support)
**Value**: Universal tool for all KC deployments
