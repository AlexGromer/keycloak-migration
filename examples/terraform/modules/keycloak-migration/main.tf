terraform {
  required_version = ">= 1.5"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ============================================================================
# Clone Migration Tool
# ============================================================================

resource "null_resource" "clone_migration_tool" {
  provisioner "local-exec" {
    command = <<-EOT
      if [ ! -d "${var.migration_tool_path}" ]; then
        git clone ${var.migration_tool_repo} ${var.migration_tool_path}
        cd ${var.migration_tool_path}
        git checkout ${var.migration_tool_version}
      fi
    EOT
  }

  triggers = {
    version = var.migration_tool_version
  }
}

# ============================================================================
# Generate Profile from Template
# ============================================================================

resource "local_file" "migration_profile" {
  filename = "${var.migration_tool_path}/profiles/terraform-generated.yaml"
  content  = templatefile("${path.module}/templates/profile.yaml.tpl", {
    profile_name        = var.profile_name
    db_type             = var.database_type
    db_host             = var.database_host
    db_port             = var.database_port
    db_name             = var.database_name
    db_user             = var.database_user
    deployment_mode     = var.deployment_mode
    cluster_mode        = var.cluster_mode
    current_version     = var.current_keycloak_version
    target_version      = var.target_keycloak_version
    migration_strategy  = var.migration_strategy
    k8s_namespace       = var.kubernetes_namespace
    k8s_deployment      = var.kubernetes_deployment
    k8s_replicas        = var.kubernetes_replicas
  })

  depends_on = [null_resource.clone_migration_tool]
}

# ============================================================================
# Run Migration Plan
# ============================================================================

resource "null_resource" "migration_plan" {
  count = var.dry_run ? 1 : 0

  provisioner "local-exec" {
    command     = "./scripts/migrate_keycloak_v3.sh plan --profile terraform-generated"
    working_dir = var.migration_tool_path
    environment = {
      KC_DB_PASSWORD = var.database_password
    }
  }

  depends_on = [local_file.migration_profile]
}

# ============================================================================
# Run Migration
# ============================================================================

resource "null_resource" "migration_execute" {
  count = var.dry_run ? 0 : 1

  provisioner "local-exec" {
    command = <<-EOT
      ./scripts/migrate_keycloak_v3.sh migrate \
        --profile terraform-generated \
        ${var.skip_preflight ? "--skip-preflight" : ""} \
        ${var.airgap_mode ? "--airgap" : ""} \
        ${var.auto_rollback ? "--auto-rollback" : ""}
    EOT

    working_dir = var.migration_tool_path

    environment = {
      KC_DB_PASSWORD = var.database_password
      AUDIT_ENABLED  = "true"
      AUDIT_LOG_FILE = "${var.migration_tool_path}/migration_audit.jsonl"
    }
  }

  depends_on = [local_file.migration_profile]

  triggers = {
    profile_checksum = sha256(local_file.migration_profile.content)
    version          = var.target_keycloak_version
  }
}

# ============================================================================
# Fetch Audit Log
# ============================================================================

data "local_file" "audit_log" {
  count      = var.dry_run ? 0 : 1
  filename   = "${var.migration_tool_path}/migration_audit.jsonl"
  depends_on = [null_resource.migration_execute]
}
