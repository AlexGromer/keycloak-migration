output "profile_path" {
  description = "Path to the generated migration profile"
  value       = local_file.migration_profile.filename
}

output "profile_content" {
  description = "Content of the generated migration profile"
  value       = local_file.migration_profile.content
  sensitive   = true
}

output "audit_log_path" {
  description = "Path to the migration audit log"
  value       = "${var.migration_tool_path}/migration_audit.jsonl"
}

output "audit_log_content" {
  description = "Content of the migration audit log (if migration ran)"
  value       = var.dry_run ? null : try(data.local_file.audit_log[0].content, null)
  sensitive   = true
}

output "migration_status" {
  description = "Migration execution status"
  value = {
    dry_run          = var.dry_run
    profile_name     = var.profile_name
    current_version  = var.current_keycloak_version
    target_version   = var.target_keycloak_version
    strategy         = var.migration_strategy
    deployment_mode  = var.deployment_mode
  }
}
