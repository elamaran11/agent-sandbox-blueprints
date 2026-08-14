# ── Default StorageClass ──────────────────────────────────────────────────────
#
# WHY THIS IS IN TERRAFORM AND NOT GITOPS
#
# This cluster is NOT EKS Auto Mode (see eks.tf — Kata needs nested
# virtualization, which Auto Mode's Bottlerocket nodes cannot provide). Auto Mode
# would bring its own storage story; here the aws-ebs-csi-driver addon provides
# the provisioner, but an addon alone creates NO StorageClass. EKS ships only
# in-tree `gp2`, and it is NOT marked default.
#
# So without this, every PVC that omits storageClassName stays Pending forever and
# its pod sits unschedulable with:
#
#   0/2 nodes are available: pod has unbound immediate PersistentVolumeClaims
#
# That is exactly how it failed: bifrost-0 sat Pending for an hour reporting a
# scheduling problem, when the real cause was that the cluster had no default
# StorageClass at all. Nothing in the message points at storage config.
#
# It lives in Terraform rather than the platform chart for ORDERING. ArgoCD syncs
# the addons in waves and several of them (bifrost, langfuse) request a PVC
# immediately. A StorageClass delivered by the same ArgoCD that deploys those
# addons is a race; Terraform runs strictly before the root Application exists, so
# the class is always there first.
#
# It was previously defined in kata/runtimeclasses — meaning a cluster only got a
# default StorageClass after `task kata`, and `task up` on its own produced a
# cluster where anything with a PVC hung. Storage is a platform concern, not a
# property of one optional substrate.
resource "kubernetes_storage_class" "ebs_gp3" {
  metadata {
    name = "ebs-gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  # WaitForFirstConsumer, not Immediate: the volume must be created in the same AZ
  # as the pod that binds it. With Immediate, EBS picks an AZ up front and a pod
  # scheduled elsewhere can never attach it.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # The provisioner must exist before workloads rely on the class.
  depends_on = [module.eks]
}
