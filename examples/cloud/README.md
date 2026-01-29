# Cloud Migration Examples

This directory contains example profiles for migrating Keycloak in major cloud providers.

## 📁 Structure

```
cloud/
├── aws/
│   └── eks-rds-postgresql.yaml      # AWS EKS + RDS PostgreSQL
├── gcp/
│   └── gke-cloudsql-postgresql.yaml # GCP GKE + Cloud SQL
└── azure/
    └── aks-azure-database-postgresql.yaml  # Azure AKS + Azure Database
```

---

## ☁️ AWS (Amazon Web Services)

### EKS + RDS PostgreSQL

**Profile:** `aws/eks-rds-postgresql.yaml`

**Architecture:**
```
┌─────────────────────────────────────────────────────────┐
│  AWS VPC                                                │
│                                                         │
│  ┌──────────────┐         ┌──────────────┐             │
│  │     EKS      │ ─────► │  RDS Postgres│             │
│  │ (Keycloak)   │         │  Multi-AZ    │             │
│  │  3 replicas  │         └──────────────┘             │
│  └──────────────┘                                       │
│       │                                                 │
│       ▼                                                 │
│  ┌──────────────┐                                       │
│  │  ALB / NLB   │                                       │
│  └──────────────┘                                       │
│       │                                                 │
└───────┼─────────────────────────────────────────────────┘
        │
        ▼
   Internet/Users
```

**Prerequisites:**
1. EKS cluster (1.28+)
2. RDS PostgreSQL instance (14+ recommended)
3. VPC with proper security groups
4. IAM roles for EKS → RDS connectivity
5. Kubernetes secret with RDS credentials

**Setup:**
```bash
# 1. Create Kubernetes secret
kubectl create secret generic keycloak-db-secret \
  --from-literal=username=keycloak_admin \
  --from-literal=password=YOUR_PASSWORD \
  -n keycloak

# 2. Verify connectivity
kubectl run -it --rm debug --image=postgres:14 --restart=Never -- \
  psql -h keycloak-db.abc123.us-east-1.rds.amazonaws.com \
       -U keycloak_admin -d keycloak

# 3. Run migration
./scripts/migrate_keycloak_v3.sh migrate --profile examples/cloud/aws/eks-rds-postgresql.yaml
```

**Best Practices:**
- ✅ Use Multi-AZ RDS for high availability
- ✅ Enable automated backups (retain 30 days)
- ✅ Use RDS Proxy for connection pooling
- ✅ Store credentials in AWS Secrets Manager
- ✅ Use VPC endpoints for ECR/S3 (no internet)
- ✅ Enable CloudWatch logs and alarms

**Cost Optimization:**
- Use Reserved Instances for RDS (save 40-60%)
- Enable RDS storage autoscaling
- Use Spot Instances for non-prod EKS nodes

---

## ☁️ GCP (Google Cloud Platform)

### GKE + Cloud SQL PostgreSQL

**Profile:** `gcp/gke-cloudsql-postgresql.yaml`

**Architecture:**
```
┌─────────────────────────────────────────────────────────┐
│  GCP VPC                                                │
│                                                         │
│  ┌──────────────┐         ┌──────────────┐             │
│  │     GKE      │ ─────► │  Cloud SQL   │             │
│  │ (Keycloak)   │ Proxy  │  PostgreSQL  │             │
│  │  3 replicas  │         │  HA config   │             │
│  └──────────────┘         └──────────────┘             │
│       │                                                 │
│       ▼                                                 │
│  ┌──────────────┐                                       │
│  │   GCP LB     │                                       │
│  └──────────────┘                                       │
│       │                                                 │
└───────┼─────────────────────────────────────────────────┘
        │
        ▼
   Internet/Users
```

**Prerequisites:**
1. GKE cluster (1.28+)
2. Cloud SQL PostgreSQL instance (14+ recommended)
3. VPC with Private Service Connection
4. Cloud SQL Proxy (sidecar) OR Private IP
5. Kubernetes secret with Cloud SQL credentials

**Setup Option 1 — Private IP:**
```bash
# 1. Enable Private IP on Cloud SQL
gcloud sql instances patch keycloak-db \
  --network=projects/PROJECT_ID/global/networks/VPC_NAME

# 2. Create Kubernetes secret
kubectl create secret generic keycloak-db-secret \
  --from-literal=username=keycloak-admin \
  --from-literal=password=YOUR_PASSWORD \
  -n keycloak

# 3. Run migration
./scripts/migrate_keycloak_v3.sh migrate --profile examples/cloud/gcp/gke-cloudsql-postgresql.yaml
```

**Setup Option 2 — Cloud SQL Proxy:**
```yaml
# Add sidecar to Keycloak deployment
containers:
  - name: cloud-sql-proxy
    image: gcr.io/cloudsql-docker/gce-proxy:latest
    command:
      - "/cloud_sql_proxy"
      - "-instances=PROJECT:REGION:INSTANCE=tcp:5432"
```

**Best Practices:**
- ✅ Use High Availability (HA) configuration
- ✅ Enable automated backups
- ✅ Use Workload Identity (no passwords)
- ✅ Enable Cloud Monitoring and Logging
- ✅ Use GCR/Artifact Registry for images
- ✅ Enable Binary Authorization for security

**Cost Optimization:**
- Use committed use discounts (CUD) for Cloud SQL
- Enable storage autoscaling
- Use Preemptible VMs for dev/test GKE nodes

---

## ☁️ Azure (Microsoft Azure)

### AKS + Azure Database for PostgreSQL

**Profile:** `azure/aks-azure-database-postgresql.yaml`

**Architecture:**
```
┌─────────────────────────────────────────────────────────┐
│  Azure VNet                                             │
│                                                         │
│  ┌──────────────┐         ┌──────────────┐             │
│  │     AKS      │ ─────► │ Azure DB for │             │
│  │ (Keycloak)   │  VNet  │  PostgreSQL  │             │
│  │  3 replicas  │  Link  │  Flexible    │             │
│  └──────────────┘         └──────────────┘             │
│       │                                                 │
│       ▼                                                 │
│  ┌──────────────┐                                       │
│  │  Azure LB /  │                                       │
│  │ App Gateway  │                                       │
│  └──────────────┘                                       │
│       │                                                 │
└───────┼─────────────────────────────────────────────────┘
        │
        ▼
   Internet/Users
```

**Prerequisites:**
1. AKS cluster (1.28+)
2. Azure Database for PostgreSQL Flexible Server (14+ recommended)
3. VNet with proper NSG rules
4. Private endpoint OR public with firewall rules
5. Kubernetes secret with Azure Database credentials

**Setup:**
```bash
# 1. Create Kubernetes secret (note @server-name suffix)
kubectl create secret generic keycloak-db-secret \
  --from-literal=username=keycloak_admin@keycloak-db \
  --from-literal=password=YOUR_PASSWORD \
  -n keycloak

# 2. Verify connectivity
kubectl run -it --rm debug --image=postgres:14 --restart=Never -- \
  psql "host=keycloak-db.postgres.database.azure.com \
        port=5432 \
        dbname=keycloak \
        user=keycloak_admin@keycloak-db \
        sslmode=require"

# 3. Run migration
./scripts/migrate_keycloak_v3.sh migrate --profile examples/cloud/azure/aks-azure-database-postgresql.yaml
```

**Best Practices:**
- ✅ Use zone-redundant HA configuration
- ✅ Enable automated backups (retain 35 days max)
- ✅ Use private endpoint for VNet integration
- ✅ Enable SSL/TLS (enforced by default)
- ✅ Use Azure Workload Identity (no passwords)
- ✅ Enable Azure Monitor and Log Analytics
- ✅ Use ACR for container images

**Cost Optimization:**
- Use Reserved Capacity for Azure Database (save 38-65%)
- Enable storage autoscaling
- Use Spot VMs for dev/test AKS nodes

---

## 🔐 Security Best Practices (All Clouds)

### Secrets Management

**Option 1: Kubernetes Secrets (Basic)**
```bash
kubectl create secret generic keycloak-db-secret \
  --from-literal=username=keycloak_admin \
  --from-literal=password=YOUR_PASSWORD \
  -n keycloak
```

**Option 2: Cloud-Native (Recommended)**

| Cloud | Service | Integration |
|-------|---------|-------------|
| AWS | AWS Secrets Manager | [External Secrets Operator](https://external-secrets.io/) |
| GCP | Secret Manager | [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) |
| Azure | Key Vault | [Azure Workload Identity](https://azure.github.io/azure-workload-identity/) |

**Example — AWS Secrets Manager:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets
  namespace: keycloak
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: keycloak-db-secret
  namespace: keycloak
spec:
  secretStoreRef:
    name: aws-secrets
  target:
    name: keycloak-db-secret
  data:
    - secretKey: username
      remoteRef:
        key: keycloak/db
        property: username
    - secretKey: password
      remoteRef:
        key: keycloak/db
        property: password
```

### Network Security

| Cloud | Feature | Purpose |
|-------|---------|---------|
| AWS | Security Groups | Control EKS → RDS traffic |
| AWS | VPC Endpoints | Private ECR/S3 access |
| GCP | Private Service Connection | VPC-native Cloud SQL |
| GCP | VPC Firewall Rules | Control GKE → Cloud SQL |
| Azure | NSG (Network Security Groups) | Control AKS → Azure DB |
| Azure | Private Endpoint | VNet-only database access |

### SSL/TLS

All cloud databases **require** SSL/TLS:

```yaml
# Add to JDBC URL
database:
  jdbc_params: "?sslmode=require"
  # OR for stricter validation
  jdbc_params: "?sslmode=verify-full&sslrootcert=/path/to/ca.crt"
```

---

## 🚀 Migration Workflow

### Pre-Migration Checklist

- [ ] Database backup created
- [ ] Secrets configured (Kubernetes or cloud-native)
- [ ] Network connectivity verified (EKS↔RDS, GKE↔Cloud SQL, AKS↔Azure DB)
- [ ] SSL/TLS certificates configured
- [ ] Firewall rules / security groups configured
- [ ] Kubernetes cluster healthy (`kubectl get nodes`)
- [ ] Keycloak pods running (`kubectl get pods -n keycloak`)

### Migration Steps

```bash
# 1. Verify profile
./scripts/migrate_keycloak_v3.sh profile validate examples/cloud/<cloud>/profile.yaml

# 2. Plan migration (dry-run)
./scripts/migrate_keycloak_v3.sh plan --profile examples/cloud/<cloud>/profile.yaml

# 3. Run migration
./scripts/migrate_keycloak_v3.sh migrate --profile examples/cloud/<cloud>/profile.yaml

# 4. Monitor progress
kubectl logs -f -n keycloak deployment/keycloak
```

### Post-Migration

- [ ] Verify all pods running: `kubectl get pods -n keycloak`
- [ ] Check health endpoint: `curl http://keycloak-http/health`
- [ ] Run smoke tests
- [ ] Verify database schema version
- [ ] Check audit logs

---

## 📊 Performance Tuning

### Database Connection Pooling

**For high-traffic environments:**

| Cloud | Solution | Configuration |
|-------|----------|---------------|
| AWS | RDS Proxy | Max 1000 connections, auto-scaling |
| GCP | Cloud SQL Proxy | Built-in connection pooling |
| Azure | Azure Database HA | Connection pooling in Keycloak config |

**Keycloak connection pool settings:**
```yaml
# Add to Keycloak deployment env vars
- name: KC_DB_POOL_INITIAL_SIZE
  value: "5"
- name: KC_DB_POOL_MIN_SIZE
  value: "5"
- name: KC_DB_POOL_MAX_SIZE
  value: "20"
```

### Replica Scaling

```bash
# Auto-scale based on CPU
kubectl autoscale deployment keycloak \
  --cpu-percent=70 \
  --min=3 \
  --max=10 \
  -n keycloak
```

---

## 🛠️ Troubleshooting

### Common Issues

**Issue 1: Connection timeout**
```
Error: Connection to database timed out
```
**Solution:**
- Check security groups/firewall rules
- Verify VPC peering/private endpoint
- Test connectivity: `kubectl run debug --image=postgres:14 -- psql -h <db-host>`

**Issue 2: SSL certificate error**
```
Error: SSL connection failed
```
**Solution:**
- Download cloud provider CA certificate
- Add to JDBC URL: `?sslmode=require&sslrootcert=/path/to/ca.crt`
- For testing only: `sslmode=disable` (not recommended)

**Issue 3: Authentication failed (Azure)**
```
Error: password authentication failed for user "keycloak_admin"
```
**Solution:**
- Azure requires `@server-name` suffix: `keycloak_admin@keycloak-db`
- Verify username format in Kubernetes secret

---

## 📚 References

### AWS
- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [RDS PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html)
- [RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)

### GCP
- [GKE Best Practices](https://cloud.google.com/kubernetes-engine/docs/best-practices)
- [Cloud SQL](https://cloud.google.com/sql/docs/postgres)
- [Cloud SQL Proxy](https://cloud.google.com/sql/docs/postgres/sql-proxy)

### Azure
- [AKS Best Practices](https://learn.microsoft.com/en-us/azure/aks/best-practices)
- [Azure Database for PostgreSQL](https://learn.microsoft.com/en-us/azure/postgresql/)
- [Workload Identity](https://azure.github.io/azure-workload-identity/)

---

**For more examples, see:**
- [Ansible Integration](../ansible/)
- [Terraform Modules](../terraform/)
