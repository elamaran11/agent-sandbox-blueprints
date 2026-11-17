# ── EKS Auto Mode node access (Nitro Sandbox substrate) ───────────────────────
#
# Only exists when enable_auto_mode = true. The EKS module creates the Auto Mode
# node role, but EKS creates an access entry for that role only when it is the
# nodeRoleArn of a BUILT-IN node pool. This blueprint enables none:
# nitro-sandbox/nodepools brings its own NodeClass, so the entry is created here.
#
# Without it the failure is quiet. Auto Mode launches the instance, the kubelet is
# refused by the API server, and the node never registers, so the sandbox pod stays
# Pending and nothing in the cluster names the missing access entry as the cause.
# The policy must be AmazonEKSAutoNodePolicy, and the entry type EC2 rather than
# EC2_LINUX.

resource "aws_eks_access_entry" "auto_mode_node" {
  count = var.enable_auto_mode ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks.node_iam_role_arn
  type          = "EC2"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "auto_mode_node" {
  count = var.enable_auto_mode ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks.node_iam_role_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.auto_mode_node]
}
