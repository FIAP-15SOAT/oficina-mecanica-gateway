locals {
  api_name                      = "apigw-${var.project_name}"
  vpclink_name                  = "vpclink-${var.project_name}"
  secgrp_vpclink_name           = "secgrp-vpclink-${var.project_name}"
  cw_lg_api_access_name         = "/aws/apigateway/apigw-${var.project_name}/access-logs"
  cw_lg_api_access_tag_name     = "cw-lg-apigw-access-${var.project_name}"
  vpc_id                        = data.terraform_remote_state.aws_base.outputs.vpc_id
  vpc_cidr                      = data.terraform_remote_state.aws_base.outputs.vpc_cidr
  private_subnet_ids            = data.terraform_remote_state.aws_base.outputs.private_subnet_ids
  api_nlb_listener_arn          = data.terraform_remote_state.k8s.outputs.api_nlb_listener_arn
  customer_auth_function_arn    = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.customer_auth_function_name}"
  customer_auth_integration_uri = "arn:aws:apigateway:${data.aws_region.current.region}:lambda:path/2015-03-31/functions/${local.customer_auth_function_arn}/invocations"
}
