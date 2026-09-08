# O egress e restrito, e nao `0.0.0.0/0`: o unico destino que estas ENIs
# precisam alcancar e o listener do NLB interno, dentro da VPC.
resource "aws_security_group" "secgrp_vpclink" {
  name        = local.secgrp_vpclink_name
  description = "Egress-only security group for the API Gateway VPC Link ENIs reaching the internal API NLB"
  vpc_id      = local.vpc_id

  egress {
    description = "Allow the VPC Link ENIs to reach the internal API NLB listener inside the VPC"
    from_port   = var.nlb_listener_port
    to_port     = var.nlb_listener_port
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = {
    Name = local.secgrp_vpclink_name
  }
}
