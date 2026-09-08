aws_region   = "us-east-1"
project_name = "oficina-mecanica"
environment  = "prod-simulated"

aws_base_state_bucket = "bkt-oficina-mecanica"
aws_base_state_key    = "infra/prod-simulated/infra-base/terraform.tfstate"
aws_base_state_region = "us-east-1"

k8s_state_bucket = "bkt-oficina-mecanica"
k8s_state_key    = "infra/prod-simulated/k8s/terraform.tfstate"
k8s_state_region = "us-east-1"

nlb_listener_port           = 80
customer_auth_function_name = "lbd-oficina-mecanica-customer-auth"

stage_throttling_rate_limit  = 50
stage_throttling_burst_limit = 100
login_throttling_rate_limit  = 5
login_throttling_burst_limit = 10

access_log_retention_in_days = 14
