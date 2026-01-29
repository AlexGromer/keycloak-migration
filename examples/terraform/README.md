# Terraform Integration

Automate Keycloak infrastructure provisioning and migration using Terraform.

## 📁 Structure

```
terraform/
├── modules/
│   └── keycloak-migration/      # Reusable migration module
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── templates/
│           └── profile.yaml.tpl
└── aws/                         # AWS EKS + RDS example
    ├── main.tf
    ├── variables.tf
    └── terraform.tfvars.example
```

## 🚀 Quick Start

### 1. Install Terraform

```bash
# Download from https://www.terraform.io/downloads
# Or via package manager:
brew install terraform  # macOS
sudo apt-get install terraform  # Debian/Ubuntu
```

### 2. Configure AWS Example

```bash
cd examples/terraform/aws

# Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

### 3. Run Migration

```bash
# Initialize Terraform
terraform init

# Plan (dry-run)
terraform plan

# Apply
terraform apply
```

## 📋 Module Usage

### Basic Example

```hcl
module "keycloak_migration" {
  source = "./modules/keycloak-migration"

  # Database
  database_type     = "postgresql"
  database_host     = "keycloak-db.region.rds.amazonaws.com"
  database_port     = 5432
  database_name     = "keycloak"
  database_user     = "keycloak_admin"
  database_password = var.db_password

  # Keycloak
  deployment_mode    = "kubernetes"
  cluster_mode       = "infinispan"
  migration_strategy = "rolling_update"

  # Versions
  current_keycloak_version = "16.1.1"
  target_keycloak_version  = "26.0.7"

  # Options
  auto_rollback = true
  dry_run       = false
}
```

### With AWS Secrets Manager

```hcl
data "aws_secretsmanager_secret_version" "keycloak_db" {
  secret_id = "keycloak/database"
}

locals {
  db_credentials = jsondecode(data.aws_secretsmanager_secret_version.keycloak_db.secret_string)
}

module "keycloak_migration" {
  source = "./modules/keycloak-migration"

  database_password = local.db_credentials.password
  # ... other configuration
}
```

### Airgap Mode

```hcl
module "keycloak_migration" {
  source = "./modules/keycloak-migration"

  airgap_mode = true

  # ... other configuration
}
```

## 📊 Module Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `migration_tool_repo` | string | GitHub URL | Migration tool repository |
| `migration_tool_version` | string | `v3.0.0` | Version tag |
| `migration_tool_path` | string | `/tmp/keycloak-migration` | Local clone path |
| `database_type` | string | `postgresql` | Database type |
| `database_host` | string | — | Database hostname |
| `database_port` | number | `5432` | Database port |
| `database_name` | string | `keycloak` | Database name |
| `database_user` | string | `keycloak` | Database username |
| `database_password` | string (sensitive) | — | Database password |
| `deployment_mode` | string | `kubernetes` | Deployment mode |
| `cluster_mode` | string | `infinispan` | Cluster mode |
| `current_keycloak_version` | string | `16.1.1` | Current version |
| `target_keycloak_version` | string | `26.0.7` | Target version |
| `migration_strategy` | string | `rolling_update` | Migration strategy |
| `kubernetes_namespace` | string | `keycloak` | K8s namespace |
| `kubernetes_deployment` | string | `keycloak` | K8s deployment name |
| `kubernetes_replicas` | number | `3` | Number of replicas |
| `skip_preflight` | bool | `false` | Skip pre-flight checks |
| `airgap_mode` | bool | `false` | Enable airgap mode |
| `auto_rollback` | bool | `true` | Auto-rollback on failure |
| `dry_run` | bool | `false` | Plan-only mode |

## 📤 Module Outputs

| Output | Description |
|--------|-------------|
| `profile_path` | Path to generated profile |
| `profile_content` | Content of generated profile (sensitive) |
| `audit_log_path` | Path to audit log |
| `audit_log_content` | Audit log content (sensitive) |
| `migration_status` | Migration execution status |

## 🔐 Security Best Practices

### 1. Use Remote State with Encryption

```hcl
terraform {
  backend "s3" {
    bucket         = "terraform-state"
    key            = "keycloak/migration.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

### 2. Store Secrets in Cloud Secret Managers

**AWS Secrets Manager:**
```hcl
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "keycloak/db"
}

locals {
  db_password = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string).password
}
```

**GCP Secret Manager:**
```hcl
data "google_secret_manager_secret_version" "db" {
  secret = "keycloak-db-password"
}

locals {
  db_password = data.google_secret_manager_secret_version.db.secret_data
}
```

**Azure Key Vault:**
```hcl
data "azurerm_key_vault_secret" "db" {
  name         = "keycloak-db-password"
  key_vault_id = var.key_vault_id
}

locals {
  db_password = data.azurerm_key_vault_secret.db.value
}
```

### 3. Never Commit Secrets

```bash
# Add to .gitignore
echo "terraform.tfvars" >> .gitignore
echo ".terraform/" >> .gitignore
echo "*.tfstate" >> .gitignore
echo "*.tfstate.backup" >> .gitignore
```

### 4. Use Environment Variables

```bash
export TF_VAR_database_password="secret"
terraform apply
```

## 🛠️ Advanced Usage

### Multi-Environment Setup

```
terraform/
├── modules/keycloak-migration/
├── environments/
│   ├── production/
│   │   ├── main.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   ├── staging/
│   │   ├── main.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   └── development/
│       ├── main.tf
│       ├── terraform.tfvars
│       └── backend.tf
```

### With Terragrunt

```hcl
# terragrunt.hcl
terraform {
  source = "../../modules/keycloak-migration"
}

inputs = {
  database_type     = "postgresql"
  database_host     = dependency.rds.outputs.endpoint
  database_password = dependency.secrets.outputs.db_password
  # ... other inputs
}
```

### Conditional Migration (Production Only)

```hcl
module "keycloak_migration" {
  count  = var.environment == "production" ? 1 : 0
  source = "./modules/keycloak-migration"
  # ... configuration
}
```

## 🔗 Integration with CI/CD

### Terraform Cloud/Enterprise

```yaml
# .github/workflows/terraform.yml
name: Terraform Migration

on:
  push:
    branches: [main]

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.5.0

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan
        run: terraform plan

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main'
        run: terraform apply -auto-approve
```

### GitLab CI

```yaml
stages:
  - validate
  - plan
  - apply

terraform-validate:
  stage: validate
  image: hashicorp/terraform:1.5
  script:
    - terraform init
    - terraform validate

terraform-plan:
  stage: plan
  image: hashicorp/terraform:1.5
  script:
    - terraform init
    - terraform plan -out=plan.tfplan
  artifacts:
    paths:
      - plan.tfplan

terraform-apply:
  stage: apply
  image: hashicorp/terraform:1.5
  script:
    - terraform init
    - terraform apply plan.tfplan
  when: manual
  only:
    - main
```

## 🐛 Troubleshooting

### Issue: Migration tool not found

```
Error: Failed to execute migration script
```

**Solution:**
Ensure git is installed on the Terraform execution environment:
```bash
which git
```

### Issue: Permission denied

```
Error: Permission denied when running migration script
```

**Solution:**
Check file permissions in `migration_tool_path`:
```bash
chmod +x /tmp/keycloak-migration/scripts/*.sh
```

### Issue: Database connection failed

```
Error: Could not connect to database
```

**Solution:**
Verify security groups/firewall rules allow Terraform host → Database.

## 📚 Examples by Cloud

### AWS (Current)

See [aws/](aws/) directory for complete example with EKS + RDS.

### GCP (Coming Soon)

Example with GKE + Cloud SQL.

### Azure (Coming Soon)

Example with AKS + Azure Database.

## 📖 References

- [Terraform Documentation](https://www.terraform.io/docs)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Terraform Best Practices](https://www.terraform-best-practices.com/)
- [Terraform Security](https://www.terraform.io/docs/language/state/sensitive-data.html)
