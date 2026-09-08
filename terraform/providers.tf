terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.46.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

data "terraform_remote_state" "aws_base" {
  backend = "s3"

  config = {
    bucket = var.aws_base_state_bucket
    key    = var.aws_base_state_key
    region = var.aws_base_state_region
  }
}

data "terraform_remote_state" "k8s" {
  backend = "s3"

  config = {
    bucket = var.k8s_state_bucket
    key    = var.k8s_state_key
    region = var.k8s_state_region
  }
}
