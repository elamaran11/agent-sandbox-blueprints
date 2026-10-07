# AgentCore Runtime VPC mode

Set `enable_agentcore_vpc = true` in `terraform.tfvars` to create an egress-only
security group for AgentCore Runtime. Terraform always outputs `private_subnet_ids`;
it outputs `agentcore_security_group_id` only when this flag is enabled (otherwise
the value is `null`). The private subnets route outbound traffic through the
existing NAT gateway. Before selecting VPC mode, confirm the configured private
subnets are in AgentCore-supported Availability Zones.
