# ── AWS Load Balancer Controller ──────────────────────────────────────────────
#
# The webhook Service requires an AWS Load Balancer Controller on EKS 1.36.
#
# The Dark Factory is event-driven: labelling a GitHub issue posts a webhook to the
# Argo Events EventSource, which submits the Workflow. That needs a public address,
# and on EKS 1.36 there is NO in-tree cloud LoadBalancer support left — a plain
# `type: LoadBalancer` Service sits at `EnsuringLoadBalancer` with no address
# forever. Nothing in the Service events says "install a controller".
#
# Without it the pipeline still works, but only if a human submits the Workflow by
# hand. That makes the demo "watch the agent work" instead of "label an issue and
# walk away" — the whole point of the pattern. So this is part of the platform.
#
# The IAM policy is VENDORED (policies/aws-load-balancer-controller.json) rather
# than fetched at apply time: a `curl` in the apply path makes the build depend on
# GitHub being up and silently drifts when upstream edits the file. Refresh it
# deliberately with the version pinned in the platform chart.
resource "aws_iam_role" "aws_lbc" {
  count = var.enable_aws_lbc ? 1 : 0

  name = "${local.cluster_name}-aws-lbc"

  # Pod Identity, consistent with the rest of this blueprint (Karpenter, ESO,
  # bifrost) — no OIDC/IRSA annotation plumbing, no static keys.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "aws_lbc" {
  count = var.enable_aws_lbc ? 1 : 0

  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.aws_lbc[0].id
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_eks_pod_identity_association" "aws_lbc" {
  count = var.enable_aws_lbc ? 1 : 0

  cluster_name = module.eks.cluster_name
  # Must match the namespace + serviceAccount the platform chart installs the
  # controller with. Pod Identity is keyed on that pair, and a mismatch shows up as
  # the controller failing to describe subnets rather than as a naming error.
  namespace       = "kube-system"
  service_account = var.aws_lbc_service_account
  role_arn        = aws_iam_role.aws_lbc[0].arn
}

# The controller discovers where to put load balancers from SUBNET TAGS. Without
# them it logs "couldn't auto-discover subnets" and provisions nothing — another
# failure that never mentions tags. vpc.tf applies them through the VPC module
# (public_subnet_tags / private_subnet_tags: kubernetes.io/role/elb and
# kubernetes.io/role/internal-elb). Do NOT add aws_ec2_tag resources keyed on
# module.vpc.*_subnets here: the IDs are unknown at plan time on a fresh account,
# and `for_each` over them fails with "Invalid for_each argument" before anything
# is created.
