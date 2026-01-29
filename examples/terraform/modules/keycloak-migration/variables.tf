variable "migration_tool_repo" {
  description = "Git repository URL for migration tool"
  type        = string
  default     = "https://github.com/AlexGromer/keycloak-migration.git"
}

variable "migration_tool_version" {
  description = "Version tag of migration tool"
  type        = string
  default     = "v3.0.0"
}

variable "migration_tool_path" {
  description = "Local path where migration tool will be cloned"
  type        = string
  default     = "/tmp/keycloak-migration"
}

variable "profile_name" {
  description = "Name of the migration profile"
  type        = string
  default     = "terraform-generated"
}

# ============================================================================
# Database Configuration
# ============================================================================

variable "database_type" {
  description = "Database type (postgresql, mysql, mariadb, oracle, mssql)"
  type        = string
  default     = "postgresql"

  validation {
    condition     = contains(["postgresql", "mysql", "mariadb", "oracle", "mssql"], var.database_type)
    error_message = "Database type must be one of: postgresql, mysql, mariadb, oracle, mssql"
  }
}

variable "database_host" {
  description = "Database hostname or IP"
  type        = string
}

variable "database_port" {
  description = "Database port"
  type        = number
  default     = 5432
}

variable "database_name" {
  description = "Database name"
  type        = string
  default     = "keycloak"
}

variable "database_user" {
  description = "Database username"
  type        = string
  default     = "keycloak"
}

variable "database_password" {
  description = "Database password (sensitive)"
  type        = string
  sensitive   = true
}

# ============================================================================
# Keycloak Configuration
# ============================================================================

variable "deployment_mode" {
  description = "Deployment mode (standalone, docker, docker-compose, kubernetes, deckhouse)"
  type        = string
  default     = "kubernetes"

  validation {
    condition     = contains(["standalone", "docker", "docker-compose", "kubernetes", "deckhouse"], var.deployment_mode)
    error_message = "Deployment mode must be one of: standalone, docker, docker-compose, kubernetes, deckhouse"
  }
}

variable "cluster_mode" {
  description = "Cluster mode (standalone, infinispan, external)"
  type        = string
  default     = "infinispan"

  validation {
    condition     = contains(["standalone", "infinispan", "external"], var.cluster_mode)
    error_message = "Cluster mode must be one of: standalone, infinispan, external"
  }
}

variable "current_keycloak_version" {
  description = "Current Keycloak version"
  type        = string
  default     = "16.1.1"
}

variable "target_keycloak_version" {
  description = "Target Keycloak version"
  type        = string
  default     = "26.0.7"
}

# ============================================================================
# Migration Strategy
# ============================================================================

variable "migration_strategy" {
  description = "Migration strategy (inplace, rolling_update, blue_green)"
  type        = string
  default     = "rolling_update"

  validation {
    condition     = contains(["inplace", "rolling_update", "blue_green"], var.migration_strategy)
    error_message = "Migration strategy must be one of: inplace, rolling_update, blue_green"
  }
}

# ============================================================================
# Kubernetes Configuration (if deployment_mode = kubernetes)
# ============================================================================

variable "kubernetes_namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "keycloak"
}

variable "kubernetes_deployment" {
  description = "Kubernetes deployment name"
  type        = string
  default     = "keycloak"
}

variable "kubernetes_replicas" {
  description = "Number of Keycloak replicas"
  type        = number
  default     = 3
}

# ============================================================================
# Migration Options
# ============================================================================

variable "skip_preflight" {
  description = "Skip pre-flight checks"
  type        = bool
  default     = false
}

variable "airgap_mode" {
  description = "Enable airgap mode"
  type        = bool
  default     = false
}

variable "auto_rollback" {
  description = "Enable auto-rollback on failure"
  type        = bool
  default     = true
}

variable "dry_run" {
  description = "Dry-run mode (plan only, no execution)"
  type        = bool
  default     = false
}
