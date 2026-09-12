variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Base project name used for resource names and tags"
  type        = string
  default     = "oficina-mecanica"
}

variable "environment" {
  description = "Environment name used for default tagging"
  type        = string
  default     = "prod-simulated"
}

variable "aws_base_state_bucket" {
  description = "S3 bucket name that stores the infra-base Terraform state"
  type        = string
  default     = "bkt-oficina-mecanica"
}

variable "aws_base_state_key" {
  description = "S3 object key for the infra-base Terraform state (source of vpc_id, vpc_cidr and private_subnet_ids)"
  type        = string
  default     = "infra/prod-simulated/infra-base/terraform.tfstate"
}

variable "aws_base_state_region" {
  description = "AWS region where the infra-base Terraform state bucket is hosted"
  type        = string
  default     = "us-east-1"
}

variable "k8s_state_bucket" {
  description = "S3 bucket name that stores the Kubernetes platform Terraform state"
  type        = string
  default     = "bkt-oficina-mecanica"
}

variable "k8s_state_key" {
  description = "S3 object key for the Kubernetes platform Terraform state (source of api_nlb_listener_arn)"
  type        = string
  default     = "infra/prod-simulated/k8s/terraform.tfstate"
}

variable "k8s_state_region" {
  description = "AWS region where the Kubernetes platform Terraform state bucket is hosted"
  type        = string
  default     = "us-east-1"
}

variable "nlb_listener_port" {
  description = "TCP port of the internal NLB listener provisioned in `oficina-mecanica-infra-k8s`"
  type        = number
  default     = 80
}

variable "customer_auth_function_name" {
  description = "Name of the serverless function for external customer authentication"
  type        = string
  default     = "lbd-oficina-mecanica-customer-auth"
}

variable "stage_throttling_rate_limit" {
  description = "Target requests per second applied to every route of the stage"
  type        = number
  default     = 50
}

variable "stage_throttling_burst_limit" {
  description = "Burst capacity of the default stage throttling"
  type        = number
  default     = 100
}

variable "login_throttling_rate_limit" {
  description = "Target requests per second for the two login routes"
  type        = number
  default     = 5
}

variable "login_throttling_burst_limit" {
  description = "Burst capacity of the throttling for the two login routes"
  type        = number
  default     = 10
}

variable "access_log_retention_in_days" {
  description = "Access log retention in days, aligned with the EKS control plane log group retention"
  type        = number
  default     = 14
}
