# Terraform Example — AWS EKS + RDS PostgreSQL Keycloak Migration

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================================
# Data Sources
# ============================================================================

data "aws_eks_cluster" "keycloak" {
  name = var.eks_cluster_name
}

data "aws_db_instance" "keycloak" {
  db_instance_identifier = var.rds_instance_identifier
}

# ============================================================================
# Keycloak Migration Module
# ============================================================================

module "keycloak_migration" {
  source = "../modules/keycloak-migration"

  # Migration tool configuration
  migration_tool_version = "v3.0.0"
  migration_tool_path    = "/tmp/keycloak-migration"

  # Database configuration (from RDS)
  database_type     = "postgresql"
  database_host     = data.aws_db_instance.keycloak.address
  database_port     = data.aws_db_instance.keycloak.port
  database_name     = data.aws_db_instance.keycloak.db_name
  database_user     = var.database_user
  database_password = var.database_password # From tfvars or secrets manager

  # Keycloak configuration
  deployment_mode    = "kubernetes"
  cluster_mode       = "infinispan"
  migration_strategy = "rolling_update"

  # Kubernetes configuration
  kubernetes_namespace  = var.kubernetes_namespace
  kubernetes_deployment = var.kubernetes_deployment
  kubernetes_replicas   = var.kubernetes_replicas

  # Version configuration
  current_keycloak_version = var.current_keycloak_version
  target_keycloak_version  = var.target_keycloak_version

  # Migration options
  skip_preflight = false
  auto_rollback  = true
  dry_run        = var.dry_run
}

# ============================================================================
# Outputs
# ============================================================================

output "migration_status" {
  value = module.keycloak_migration.migration_status
}

output "profile_path" {
  value = module.keycloak_migration.profile_path
}

output "audit_log_path" {
  value = module.keycloak_migration.audit_log_path
}
