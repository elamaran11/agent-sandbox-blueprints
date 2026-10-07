# AgentCore Runtime VPC network mode needs private subnets and a security group.
# The runtime only needs outbound access to Bedrock, ECR, and GitHub via the
# existing NAT; it has no inbound listeners in the VPC. AgentCore VPC mode
# requires subnets in AgentCore-supported AZs — check the selected AZs first.
resource "aws_security_group" "agentcore" {
  count = var.enable_agentcore_vpc ? 1 : 0

  name        = "${local.cluster_name}-agentcore-runtime"
  description = "Outbound access for AgentCore Runtime VPC network mode"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Outbound through private subnet NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}
