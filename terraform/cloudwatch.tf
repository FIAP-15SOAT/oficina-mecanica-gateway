resource "aws_cloudwatch_log_group" "cw_lg_api_access" {
  name              = local.cw_lg_api_access_name
  retention_in_days = var.access_log_retention_in_days

  tags = {
    Name = local.cw_lg_api_access_tag_name
  }
}
