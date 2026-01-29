variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "eks_cluster_name" {
  description = "EKS cluster name where Keycloak is deployed"
  type        = string
}

variable "rds_instance_identifier" {
  description = "RDS instance identifier for Keycloak database"
  type        = string
}

variable "database_user" {
  description = "Database username"
  type        = string
  default     = "keycloak_admin"
}

variable "database_password" {
  description = "Database password (use AWS Secrets Manager in production)"
  type        = string
  sensitive   = true
}

variable "kubernetes_namespace" {
  description = "Kubernetes namespace for Keycloak"
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

variable "current_keycloak_version" {
  description = "Current Keycloak version"
  type        = string
}

variable "target_keycloak_version" {
  description = "Target Keycloak version"
  type        = string
  default     = "26.0.7"
}

variable "dry_run" {
  description = "Dry-run mode (plan only)"
  type        = bool
  default     = false
}
