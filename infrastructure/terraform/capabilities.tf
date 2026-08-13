# ── EKS Managed Capabilities ──────────────────────────────────────────────────
#
# This blueprint prefers AWS-operated controllers over ones we run ourselves:
#
#   ARGOCD  — AWS runs the ArgoCD control plane (GitOps engine)
#   ACK     — AWS runs the AWS Controllers for Kubernetes for GA services
#             (iam, s3, eks, ...). Used by the Lambda MicroVM blueprint to
#             create its IAM roles and artifact bucket declaratively.
#   KRO     — AWS runs Kube Resource Orchestrator, which composes those ACK
#             resources into one high-level CRD.
#
# WHY local-exec instead of a resource:
#   There is no `aws_eks_capability` resource in the Terraform AWS provider yet.
#   Until there is, these are created with the AWS CLI. Each call is made
#   idempotent by checking first, so `terraform apply` can be re-run safely.
#   Swap these for the native resource when the provider ships it — nothing else
#   in this blueprint depends on how the capability got enabled.
#
# TWO CONSTRAINTS THAT MATTER DOWNSTREAM:
#   1. Managed ACK only bundles controllers whose service is GA upstream. The
#      `lambdamicrovms` controller is PRE-GA, so it is NOT available here and is
#      installed self-managed by lambda-microvm/ack-controller. That is the only
#      controller this blueprint runs itself.
#   2. The Managed KRO controller only watches the `kro.run` API group. A
#      ResourceGraphDefinition whose schema.group is anything else will sit at
#      state=Inactive with a cache-sync timeout. lambda-microvm/kro-rgd therefore
#      declares `schema.group: kro.run`.

locals {
  capabilities = {
    ARGOCD = var.enable_managed_argocd
    ACK    = var.enable_managed_ack
    KRO    = var.enable_managed_kro
  }

  enabled_capabilities = [for name, enabled in local.capabilities : name if enabled]
}

resource "null_resource" "eks_capability" {
  for_each = toset(local.enabled_capabilities)

  triggers = {
    cluster = module.eks.cluster_name
    region  = var.region
    type    = each.key
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CLUSTER="${module.eks.cluster_name}"
      REGION="${var.region}"
      TYPE="${each.key}"

      if aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
           --query "capabilities[?type=='$TYPE'].type" --output text 2>/dev/null | grep -q "$TYPE"; then
        echo "capability $TYPE already enabled on $CLUSTER"
        exit 0
      fi

      echo "enabling capability $TYPE on $CLUSTER ..."
      if ! aws eks create-capability --cluster-name "$CLUSTER" --region "$REGION" --type "$TYPE"; then
        echo ""
        echo "ERROR: could not enable the $TYPE capability."
        echo "  This capability may not be available in $REGION or for this account."
        echo "  Set enable_managed_$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')=false in terraform.tfvars"
        echo "  and install the equivalent via Helm instead."
        exit 1
      fi
    EOT
  }

  # Removing a capability is a deliberate, destructive act (it deletes the
  # AWS-managed controllers). Do it explicitly with the CLI rather than as a
  # side effect of `terraform destroy` reordering.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "echo 'NOTE: EKS capability ${self.triggers.type} left enabled on ${self.triggers.cluster}; remove with: aws eks delete-capability --cluster-name ${self.triggers.cluster} --region ${self.triggers.region} --type ${self.triggers.type}'"
  }

  depends_on = [module.eks]
}

# Wait for the managed ArgoCD control plane to be serving before the root
# Application is applied, otherwise the CRDs may not exist yet.
resource "null_resource" "wait_for_argocd" {
  count = var.enable_managed_argocd ? 1 : 0

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "waiting for ArgoCD CRDs to be registered ..."
      for i in $(seq 1 60); do
        if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
          echo "ArgoCD is ready"; exit 0
        fi
        sleep 10
      done
      echo "ERROR: ArgoCD CRDs did not appear within 10 minutes"; exit 1
    EOT
  }

  depends_on = [null_resource.eks_capability]
}
