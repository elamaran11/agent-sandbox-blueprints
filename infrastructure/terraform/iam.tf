# ── EBS CSI driver (IRSA) ─────────────────────────────────────────────────────
# Backs sandbox workspace volumes and the devmapper StorageClass that Kata +
# Firecracker requires.

resource "aws_iam_role" "ebs_csi" {
  name = "${local.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── Bedrock access for the in-cluster LLM gateway (Pod Identity) ───────────────
# The Kata agent reaches models through the in-cluster gateway (Bifrost), which
# needs Bedrock. The Lambda MicroVM agent does NOT use this — it is outside the
# cluster network and calls Bedrock directly with its own execution role (see
# lambda-microvm/iam).

resource "aws_iam_role" "llm_gateway_bedrock" {
  name = "${local.cluster_name}-llm-gateway-bedrock"

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

resource "aws_iam_role_policy" "llm_gateway_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.llm_gateway_bedrock.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      # Scoped to Anthropic foundation models and the cross-region inference
      # profiles the agent uses. Widen deliberately if you switch model families.
      Resource = [
        "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/anthropic.*",
        "arn:${data.aws_partition.current.partition}:bedrock:*:${local.account_id}:inference-profile/us.anthropic.*",
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "llm_gateway" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.llm_gateway_namespace
  service_account = var.llm_gateway_service_account
  role_arn        = aws_iam_role.llm_gateway_bedrock.arn

  tags = local.tags
}
