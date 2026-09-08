output "api_endpoint" {
  description = "Endereco publico do Gateway (stage $default)."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "api_id" {
  description = "Identificador da HTTP API"
  value       = aws_apigatewayv2_api.api.id
}

output "api_execution_arn" {
  description = "ARN de execucao da API."
  value       = aws_apigatewayv2_api.api.execution_arn
}

output "vpc_link_id" {
  description = "Identificador do VPC Link V2."
  value       = aws_apigatewayv2_vpc_link.vpclink.id
}
