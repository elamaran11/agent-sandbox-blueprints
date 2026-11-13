module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # >= 20.31 for cluster_compute_config (EKS Auto Mode).
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = var.cluster_endpoint_public_access

  # EKS Auto Mode, for the Nitro Sandbox substrate only (enable_auto_mode). It
  # runs NEXT TO the system node group and the self-managed Karpenter below:
  # nitro-sandbox/nodepools defines the only Auto Mode NodePool, so no built-in
  # node pools are enabled and nothing else moves onto Auto Mode nodes.
  # The module also attaches the extra cluster-role policies Auto Mode needs and
  # creates the Auto Mode node role (see auto-mode.tf for its access entry). EKS
  # turns Auto Mode's block storage (ebs.csi.eks.amazonaws.com) and load balancing
  # (eks.amazonaws.com/nlb and /alb classes) on with compute. They run beside the
  # EBS CSI add-on and the AWS Load Balancer Controller. Each side manages the
  # objects carrying its provisioner or class, but Auto Mode also registers
  # eks.amazonaws.com/nlb as the cluster default for CLASSLESS LoadBalancer
  # Services, so anything meant for the LBC must pin loadBalancerClass (the
  # webhook Service does).
  cluster_compute_config = var.enable_auto_mode ? { enabled = true } : {}
  # Pinned to true while Auto Mode is on. The module otherwise defaults it to
  # false for Auto Mode clusters, and changing it forces a NEW cluster: flipping
  # enable_auto_mode on an existing deployment would destroy and recreate the
  # cluster. Left null when Auto Mode is off, so nothing changes for anyone else.
  bootstrap_self_managed_addons = var.enable_auto_mode ? true : null

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # One small managed node group for platform components only: ArgoCD, Karpenter,
  # CoreDNS, the Argo Workflows/Events controllers.
  #
  # Sandboxes NEVER run here. Kata sandboxes land on Karpenter-provisioned
  # nested-virt nodes (see kata/), and Lambda MicroVM sandboxes do not run on
  # cluster nodes at all — they are remote AWS-managed VMs.
  #
  # Not using EKS Auto Mode for this group: Kata needs a nested-virtualization
  # launch config and control over containerd (kata-deploy owns it), which Auto
  # Mode and Bottlerocket do not provide. Auto Mode is only switched on, for
  # Nitro Sandbox nodes, by enable_auto_mode above.
  eks_managed_node_groups = {
    system = {
      instance_types = var.system_instance_types
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      ami_type       = "AL2023_x86_64_STANDARD"
      labels         = { role = "system" }
    }
  }

  cluster_addons = {
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # Pod Identity is how in-cluster components get AWS credentials in this
    # blueprint (the Lambda MicroVM shim and the pipeline both rely on it).
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # EBS CSI backs persistent sandbox workspaces (Kata) and the devmapper
    # StorageClass that Kata + Firecracker requires.
    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = aws_iam_role.ebs_csi.arn
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  # EKS Access Entries API — auditable via CloudTrail, no aws-auth ConfigMap.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for idx, arn in var.admin_role_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = local.tags
}
