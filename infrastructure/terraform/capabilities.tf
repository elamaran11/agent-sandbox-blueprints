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
  # capabilityName is lowercase (that is what the API returns and expects).
  capabilities = {
    ARGOCD = { enabled = var.enable_managed_argocd, name = "argocd", role_suffix = "ArgoCDCapabilityRole" }
    ACK    = { enabled = var.enable_managed_ack, name = "ack", role_suffix = "ACKCapabilityRole" }
    KRO    = { enabled = var.enable_managed_kro, name = "kro", role_suffix = "KROCapabilityRole" }
  }

  enabled_capabilities = { for type, c in local.capabilities : type => c if c.enabled }
}

# Each capability assumes a role you own, so AWS-run controllers act with
# permissions you control. The trust principal is the capabilities service.
resource "aws_iam_role" "capability" {
  for_each = local.enabled_capabilities

  name = "${local.cluster_name}-${each.value.role_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "capabilities.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.tags
}

# ArgoCD and KRO need no AWS permissions — they only act inside the cluster.
# ACK does: its controllers create real AWS resources. Scope this to what the
# blueprint actually uses (the Lambda MicroVM graph creates IAM roles + an S3
# artifact bucket) rather than granting broad access.
resource "aws_iam_role_policy" "ack_capability" {
  count = var.enable_managed_ack ? 1 : 0

  name = "ack-blueprint-resources"
  role = aws_iam_role.capability["ACK"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactBucket"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:DeleteBucket", "s3:GetBucket*", "s3:PutBucket*",
          "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListAllMyBuckets",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::*-microvm-artifacts",
        "arn:${data.aws_partition.current.partition}:s3:::*-microvm-artifacts/*"]
      },
      {
        Sid    = "MicroVMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:UpdateAssumeRolePolicy",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/*-microvm-*"
      },
      {
        Sid      = "PassMicroVMRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/*-microvm-*"
      },
    ]
  })
}

resource "null_resource" "eks_capability" {
  for_each = local.enabled_capabilities

  triggers = {
    cluster = module.eks.cluster_name
    region  = var.region
    type    = each.key
    name    = each.value.name
    role    = aws_iam_role.capability[each.key].arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CLUSTER="${module.eks.cluster_name}"
      REGION="${var.region}"
      TYPE="${each.key}"
      NAME="${each.value.name}"
      ROLE="${aws_iam_role.capability[each.key].arn}"

      if aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
           --query "capabilities[?type=='$TYPE'].type" --output text 2>/dev/null | grep -q "$TYPE"; then
        echo "capability $TYPE already enabled on $CLUSTER"
        exit 0
      fi

      echo "enabling capability $TYPE (name=$NAME) on $CLUSTER ..."
      # RETAIN is the only supported deletion policy: Kubernetes resources the
      # capability created are kept if the capability is removed.
      if ! aws eks create-capability \
             --cluster-name "$CLUSTER" \
             --region "$REGION" \
             --type "$TYPE" \
             --capability-name "$NAME" \
             --role-arn "$ROLE" \
             --delete-propagation-policy RETAIN; then
        echo ""
        echo "ERROR: could not enable the $TYPE capability."
        echo "  It may not be available in $REGION or for this account."
        echo "  Set enable_managed_$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')=false in terraform.tfvars"
        echo "  and install the equivalent via Helm instead."
        exit 1
      fi

      # Creation is asynchronous; wait for ACTIVE so dependent resources do not
      # race the controllers coming up.
      for i in $(seq 1 60); do
        S=$(aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
              --query "capabilities[?type=='$TYPE'].status" --output text 2>/dev/null || echo "")
        [ "$S" = "ACTIVE" ] && { echo "capability $TYPE is ACTIVE"; exit 0; }
        echo "  $TYPE status=$${S:-pending} ..."; sleep 10
      done
      echo "ERROR: $TYPE did not reach ACTIVE within 10 minutes"; exit 1
    EOT
  }

  # Removing a capability is a deliberate, destructive act (it deletes the
  # AWS-managed controllers). Do it explicitly with the CLI rather than as a
  # side effect of `terraform destroy` reordering.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "echo 'NOTE: EKS capability ${self.triggers.type} left enabled on ${self.triggers.cluster}; remove with: aws eks delete-capability --cluster-name ${self.triggers.cluster} --region ${self.triggers.region} --capability-name ${self.triggers.name}'"
  }

  depends_on = [module.eks]
}

# Wait for the managed ArgoCD control plane to have registered its CRDs before
# the root Application is applied.
#
# REPEATABILITY: this must NOT depend on the operator's local kubeconfig or
# current-context — on a fresh machine neither exists yet. So it writes a
# throwaway kubeconfig from the cluster we just created and uses only that.
resource "null_resource" "wait_for_argocd" {
  count = var.enable_managed_argocd ? 1 : 0

  triggers = {
    cluster = module.eks.cluster_name
    region  = var.region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CLUSTER="${module.eks.cluster_name}"
      REGION="${var.region}"

      KUBECONFIG_TMP="$(mktemp)"
      trap 'rm -f "$KUBECONFIG_TMP"' EXIT
      aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" \
        --kubeconfig "$KUBECONFIG_TMP" >/dev/null

      echo "waiting for the ArgoCD capability to register its CRDs ..."
      for i in $(seq 1 60); do
        if KUBECONFIG="$KUBECONFIG_TMP" kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
          echo "ArgoCD is ready"; exit 0
        fi
        sleep 10
      done
      echo "ERROR: ArgoCD CRDs did not appear within 10 minutes"; exit 1
    EOT
  }

  depends_on = [null_resource.eks_capability]
}
