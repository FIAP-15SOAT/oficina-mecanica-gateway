terraform {
  required_version = ">= 1.11.0"

  backend "s3" {
    bucket       = "bkt-oficina-mecanica"
    key          = "infra/prod-simulated/gateway/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
