resource "aws_apigatewayv2_vpc_link" "vpclink" {
  name               = local.vpclink_name
  subnet_ids         = local.private_subnet_ids
  security_group_ids = [aws_security_group.secgrp_vpclink.id]

  tags = {
    Name = local.vpclink_name
  }
}

resource "aws_apigatewayv2_api" "api" {
  name          = local.api_name
  description   = "API Gateway da Oficina Mecânica"
  protocol_type = "HTTP"

  body = templatefile("${path.module}/../openapi/gateway.yaml", {
    api_name                      = local.api_name
    vpc_link_id                   = aws_apigatewayv2_vpc_link.vpclink.id
    nlb_listener_arn              = local.api_nlb_listener_arn
    customer_auth_integration_uri = local.customer_auth_integration_uri
  })

  fail_on_warnings = true

  tags = {
    Name = local.api_name
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit    = var.stage_throttling_rate_limit
    throttling_burst_limit   = var.stage_throttling_burst_limit
    detailed_metrics_enabled = true
  }

  route_settings {
    route_key                = "POST /customer-auth/login"
    throttling_rate_limit    = var.login_throttling_rate_limit
    throttling_burst_limit   = var.login_throttling_burst_limit
    detailed_metrics_enabled = true
  }

  route_settings {
    route_key                = "POST /api/auth/login"
    throttling_rate_limit    = var.login_throttling_rate_limit
    throttling_burst_limit   = var.login_throttling_burst_limit
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.cw_lg_api_access.arn

    # Sem corpo, sem query string, sem URL crua e sem cabecalho de autorizacao:
    # nenhuma credencial pode acabar aqui, em nenhum status.
    #
    # `identity.sourceIp` e onde o endereco de origem do cliente passa a ser
    # atribuido -- a aplicacao nao o enxerga (ver `docs/observability.md`).
    format = jsonencode({
      requestId          = "$context.requestId"
      sourceIp           = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integration.latency"
      integrationStatus  = "$context.integration.integrationStatus"
      integrationError   = "$context.integration.error"
    })
  }

  tags = {
    Name = local.api_name
  }
}
