# Helm Chart for Keycloak Migration

Kubernetes-native deployment of Keycloak Migration Tool v3.0 using Helm.

## Features

✅ **Kubernetes-native** — Runs as Kubernetes Job with RBAC
✅ **Profile-based** — ConfigMap-driven configuration
✅ **Secure** — Credentials via Kubernetes Secrets
✅ **Persistent** — Optional PVC for workspace/logs
✅ **Flexible** — Supports all migration modes (migrate/rollback/validate/dry-run)
✅ **Automated** — Full integration with Keycloak deployments

---

## Prerequisites

- Kubernetes cluster (1.19+)
- Helm 3.0+
- kubectl configured
- Existing Keycloak deployment
- Database accessible from cluster

---

## Quick Start

### 1. Install Helm Chart

```bash
# Add repository (when published)
helm repo add keycloak-migration https://alexgromer.github.io/keycloak-migration/charts
helm repo update

# Install
helm install my-migration keycloak-migration/keycloak-migration \
  --set migration.currentVersion=16.1.1 \
  --set migration.targetVersion=26.0.7 \
  --set database.host=keycloak-db \
  --set database.password=changeme
```

### 2. Local Installation (from repository)

```bash
cd examples/helm/keycloak-migration

# Install
helm install my-migration . \
  --values values.yaml
```

### 3. Monitor Job

```bash
# Watch job
kubectl get job -w

# Get logs
POD=$(kubectl get pods -l job-name=my-migration-keycloak-migration-migrate -o jsonpath='{.items[0].metadata.name}')
kubectl logs -f $POD
```

---

## Configuration

### Example: Production Migration

```yaml
# production-values.yaml

migration:
  mode: migrate
  currentVersion: "16.1.1"
  targetVersion: "26.0.7"
  strategy: rolling_update
  autoRollback: true
  dryRun: false

database:
  type: postgresql
  host: keycloak-db.prod.svc.cluster.local
  port: 5432
  name: keycloak
  adminUser: postgres
  user: keycloak_admin
  existingSecret: keycloak-db-credentials  # Pre-created secret
  sslMode: require

keycloak:
  deploymentMode: kubernetes
  namespace: keycloak
  deployment: keycloak
  replicas: 3
  clusterMode: infinispan

persistence:
  enabled: true
  storageClass: fast-ssd
  size: 20Gi

audit:
  enabled: true
  format: json
  stdout: true

job:
  resources:
    requests:
      memory: "1Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"
  activeDeadlineSeconds: 7200
  nodeSelector:
    workload: migration
```

**Deploy:**

```bash
helm install prod-migration . -f production-values.yaml
```

---

## Migration Modes

### Migrate (Default)

```bash
helm install my-migration . --set migration.mode=migrate
```

### Dry-Run (Plan Only)

```bash
helm install my-migration . \
  --set migration.mode=dry-run \
  --set migration.dryRun=true
```

### Rollback

```bash
helm upgrade my-migration . \
  --set migration.mode=rollback \
  --reuse-values
```

### Validate

```bash
helm install my-migration . --set migration.mode=validate
```

---

## Database Credentials

### Option 1: Values File (Development Only)

```yaml
database:
  user: keycloak_admin
  password: changeme
```

**⚠️ NOT RECOMMENDED FOR PRODUCTION**

### Option 2: Existing Secret (Recommended)

```bash
# Create secret
kubectl create secret generic keycloak-db-creds \
  --from-literal=DB_USER=keycloak_admin \
  --from-literal=DB_PASSWORD=secure_password \
  --from-literal=DB_ADMIN_PASSWORD=admin_password
```

```yaml
database:
  existingSecret: keycloak-db-creds
```

### Option 3: External Secrets Operator

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: keycloak-db-external
spec:
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: keycloak-db-creds
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: prod/keycloak/db-password
```

```yaml
database:
  existingSecret: keycloak-db-creds
```

---

## Airgap Mode

For air-gapped environments:

```yaml
migration:
  airgapMode: true

distribution:
  mode: airgap
  localPath: /opt/keycloak/dist

persistence:
  enabled: true
  size: 50Gi  # Larger for all versions
```

**Pre-populate artifacts:**

```bash
# On internet-connected machine
mkdir -p keycloak-dist
cd keycloak-dist
wget https://github.com/keycloak/keycloak/releases/download/16.1.1/keycloak-16.1.1.tar.gz
wget https://github.com/keycloak/keycloak/releases/download/17.0.1/keycloak-17.0.1.tar.gz
# ... download all versions ...

# Transfer to air-gapped cluster
kubectl cp keycloak-dist/ my-migration-pod:/opt/keycloak/dist/
```

---

## Monitoring

### Prometheus Metrics (via logs)

The migration tool generates structured JSON logs. Use Promtail/Loki or Fluentd to scrape:

```yaml
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/path: "/metrics"
  prometheus.io/port: "8080"
```

### Grafana Dashboard

Import dashboard from `examples/observability/grafana-dashboard.json`

---

## Advanced Configuration

### Blue-Green Strategy

```yaml
migration:
  strategy: blue_green

keycloak:
  # Requires custom setup with two deployments
  deployment: keycloak-green
```

### Canary Strategy

```yaml
migration:
  strategy: canary

keycloak:
  # Requires Flagger or Argo Rollouts
  deployment: keycloak
```

### Custom Resource Limits

```yaml
job:
  resources:
    requests:
      memory: "2Gi"
      cpu: "2000m"
      ephemeral-storage: "10Gi"
    limits:
      memory: "8Gi"
      cpu: "4000m"
      ephemeral-storage: "20Gi"
```

### Node Affinity

```yaml
job:
  nodeSelector:
    workload: migration
    zone: us-east-1a

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node.kubernetes.io/instance-type
            operator: In
            values:
            - m5.2xlarge
            - m5.4xlarge
```

---

## Troubleshooting

### Job Failed

```bash
# Check job status
kubectl describe job my-migration-keycloak-migration-migrate

# Check pod events
POD=$(kubectl get pods -l job-name=my-migration-keycloak-migration-migrate -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD

# Check logs
kubectl logs $POD
```

### Database Connection Failed

```bash
# Test connectivity from job pod
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql -h keycloak-db -U keycloak_admin -d keycloak
```

### RBAC Issues

```bash
# Check service account
kubectl get sa my-migration-keycloak-migration

# Check role binding
kubectl describe rolebinding my-migration-keycloak-migration

# Test permissions
kubectl auth can-i get deployments --as=system:serviceaccount:default:my-migration-keycloak-migration
```

### Persistence Issues

```bash
# Check PVC
kubectl get pvc

# Check PV
kubectl get pv

# Check storage class
kubectl get storageclass
```

---

## Uninstall

```bash
# Delete Helm release
helm uninstall my-migration

# Clean up PVC (if not needed)
kubectl delete pvc my-migration-keycloak-migration-workspace
```

---

## Values Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `migration.mode` | Migration mode (migrate/rollback/validate/dry-run) | `migrate` |
| `migration.currentVersion` | Current Keycloak version | `16.1.1` |
| `migration.targetVersion` | Target Keycloak version | `26.0.7` |
| `migration.strategy` | Migration strategy | `rolling_update` |
| `migration.skipPreflight` | Skip pre-flight checks | `false` |
| `migration.airgapMode` | Enable airgap mode | `false` |
| `migration.autoRollback` | Auto-rollback on failure | `true` |
| `migration.dryRun` | Dry-run mode | `false` |
| `database.type` | Database type | `postgresql` |
| `database.host` | Database host | `keycloak-db` |
| `database.port` | Database port | `5432` |
| `database.name` | Database name | `keycloak` |
| `database.user` | Database user | `keycloak_admin` |
| `database.password` | Database password | `""` |
| `database.existingSecret` | Existing secret name | `""` |
| `keycloak.deploymentMode` | Deployment mode | `kubernetes` |
| `keycloak.namespace` | Keycloak namespace | `keycloak` |
| `keycloak.deployment` | Deployment name | `keycloak` |
| `keycloak.replicas` | Number of replicas | `3` |
| `persistence.enabled` | Enable persistence | `true` |
| `persistence.size` | PVC size | `10Gi` |
| `image.repository` | Image repository | `alexgromer/keycloak-migration` |
| `image.tag` | Image tag | `3.0.0` |
| `job.backoffLimit` | Job backoff limit | `3` |
| `job.activeDeadlineSeconds` | Job timeout | `7200` |
| `audit.enabled` | Enable audit logging | `true` |
| `audit.format` | Audit log format | `json` |

Full values: [values.yaml](keycloak-migration/values.yaml)

---

## Examples

### Production AWS EKS + RDS

```yaml
# aws-production.yaml
migration:
  currentVersion: "16.1.1"
  targetVersion: "26.0.7"
  autoRollback: true

database:
  type: postgresql
  host: keycloak.abc123.us-east-1.rds.amazonaws.com
  port: 5432
  name: keycloak
  existingSecret: keycloak-rds-credentials
  sslMode: require

keycloak:
  namespace: keycloak
  deployment: keycloak
  replicas: 3

persistence:
  enabled: true
  storageClass: gp3
  size: 20Gi

job:
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"
  nodeSelector:
    node.kubernetes.io/instance-type: m5.xlarge
```

### GCP GKE + Cloud SQL

```yaml
# gcp-production.yaml
database:
  type: postgresql
  host: 10.0.0.3  # Cloud SQL proxy IP
  port: 5432
  existingSecret: keycloak-cloudsql-creds

persistence:
  storageClass: pd-ssd

job:
  nodeSelector:
    cloud.google.com/gke-nodepool: migration-pool
```

### Azure AKS + Azure Database

```yaml
# azure-production.yaml
database:
  type: postgresql
  host: keycloak-db.postgres.database.azure.com
  port: 5432
  sslMode: require
  existingSecret: keycloak-azure-db

persistence:
  storageClass: managed-premium
```

---

## CI/CD Integration

### GitLab CI

```yaml
# .gitlab-ci.yml
keycloak-migration:
  stage: deploy
  image: alpine/helm:3.12.0
  script:
    - helm upgrade --install keycloak-migration ./examples/helm/keycloak-migration \
        --set migration.currentVersion=$CURRENT_VERSION \
        --set migration.targetVersion=$TARGET_VERSION \
        --set database.existingSecret=keycloak-db-creds \
        --wait --timeout 2h
  only:
    - main
```

### GitHub Actions

```yaml
# .github/workflows/migrate.yml
name: Keycloak Migration

on:
  workflow_dispatch:
    inputs:
      target_version:
        description: 'Target Keycloak version'
        required: true

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/setup-helm@v3

      - name: Deploy migration
        run: |
          helm upgrade --install keycloak-migration ./examples/helm/keycloak-migration \
            --set migration.targetVersion=${{ github.event.inputs.target_version }} \
            --wait --timeout 2h
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        HELM CHART ARCHITECTURE                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐                                                        │
│  │  Helm Release   │                                                        │
│  └────────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────┐               │
│  │  Kubernetes Resources                                   │               │
│  ├─────────────────────────────────────────────────────────┤               │
│  │  • Job (migration execution)                            │               │
│  │  • ServiceAccount + RBAC                                │               │
│  │  • ConfigMap (migration profile)                        │               │
│  │  • Secret (database credentials)                        │               │
│  │  • PVC (persistent workspace)                           │               │
│  └──────────────┬──────────────────────────────────────────┘               │
│                 │                                                           │
│                 ▼                                                           │
│  ┌─────────────────────────────────────────────────────────┐               │
│  │  Migration Pod                                          │               │
│  ├─────────────────────────────────────────────────────────┤               │
│  │  Container: alexgromer/keycloak-migration:3.0.0         │               │
│  │                                                         │               │
│  │  Mounts:                                                │               │
│  │  • /etc/migration (ConfigMap)                           │               │
│  │  • /data (PVC)                                          │               │
│  │                                                         │               │
│  │  Env:                                                   │               │
│  │  • DB_USER, DB_PASSWORD (from Secret)                   │               │
│  │  • WORK_DIR=/data                                       │               │
│  └──────────────┬──────────────────────────────────────────┘               │
│                 │                                                           │
│                 ├──────────► Database (external)                           │
│                 ├──────────► Keycloak Deployment (in-cluster)              │
│                 └──────────► Audit Log (PVC)                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## License

MIT License - See [LICENSE](../../../LICENSE)

## Contributing

See [CONTRIBUTING.md](../../../CONTRIBUTING.md)

## Support

- GitHub Issues: https://github.com/AlexGromer/keycloak-migration/issues
- Documentation: https://github.com/AlexGromer/keycloak-migration
