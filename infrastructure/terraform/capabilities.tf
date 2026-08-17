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
  # ARGOCD requires a configuration block naming an Identity Center instance and
  # at least one ADMIN identity — the API rejects the capability without it, and
  # there is no local admin password for AWS-managed ArgoCD, so SSO is the only
  # way in. Built here and passed to the CLI as a file (see below).
  argocd_configuration = {
    argoCd = {
      namespace = var.argocd_namespace
      awsIdc = {
        idcInstanceArn = var.argocd_idc_instance_arn
        idcRegion      = var.argocd_idc_region != "" ? var.argocd_idc_region : var.region
      }
      rbacRoleMappings = [{
        role       = "ADMIN"
        identities = var.argocd_admin_identities
      }]
    }
  }

  # capabilityName is lowercase (that is what the API returns and expects).
  capabilities = {
    ARGOCD = {
      enabled     = var.enable_managed_argocd
      name        = "argocd"
      role_suffix = "ArgoCDCapabilityRole"
      config      = jsonencode(local.argocd_configuration)
    }
    ACK = {
      enabled     = var.enable_managed_ack
      name        = "ack"
      role_suffix = "ACKCapabilityRole"
      config      = ""
    }
    KRO = {
      enabled     = var.enable_managed_kro
      name        = "kro"
      role_suffix = "KROCapabilityRole"
      config      = ""
    }
  }

  enabled_capabilities = { for type, c in local.capabilities : type => c if c.enabled }
}

# Fail early with a clear message rather than letting the API reject the
# capability minutes into an apply.
resource "null_resource" "validate_argocd_idc" {
  count = var.enable_managed_argocd ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.argocd_idc_instance_arn != "" && length(var.argocd_admin_identities) > 0
      error_message = <<-EOT
        Managed ArgoCD requires AWS IAM Identity Center.

        Set both of these in terraform.tfvars:
          argocd_idc_instance_arn = "arn:aws:sso:::instance/ssoins-..."
          argocd_admin_identities = [{ id = "<group-or-user-id>", type = "SSO_GROUP" }]

        Discover them with:
          aws sso-admin list-instances --region ${var.region}
          aws identitystore list-groups --identity-store-id <IdentityStoreId> --region ${var.region}

        Or set enable_managed_argocd = false and install ArgoCD via Helm instead.
      EOT
    }
  }
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
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:UpdateAssumeRolePolicy",
          # Tag actions are NOT optional even if you set no tags. ACK reads tags back
          # after create to decide whether observed state matches desired, so without
          # ListRoleTags the Role never leaves ACK.ResourceSynced=Unknown — it creates
          # the role in AWS successfully and then fails on the readback.
          "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
        ]
        # THREE distinct name shapes, and missing any one of them stalls the whole
        # substrate. `*-microvm-*` alone looks like it covers everything and does
        # not: the controller role is "<cluster>-ack-lambdamicrovms-controller",
        # where the substring is "amicrovms-", so the wildcard never matches. The
        # symptom is remote from the cause — the ACK Role sits ACK.Recoverable with
        # AccessDenied on iam:GetRole, and the Application reports only
        # "waiting for healthy state of iam.services.k8s.aws/Role/...".
        Resource = [
          # The lambdamicrovms controller's own role (templates/iam).
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${local.cluster_name}-ack-lambdamicrovms-controller",
          # Roles the KRO MicrovmSandbox graph creates: <name>-microvm-build / -exec.
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/*-microvm-build",
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/*-microvm-exec",
        ]
      },
      {
        Sid    = "PassMicroVMRoles"
        Effect = "Allow"
        Action = "iam:PassRole"
        # Lambda MicroVM assumes build + exec. The controller role is ALSO passed —
        # not by Lambda, but by the eks controller when it creates the three
        # PodIdentityAssociations below, which hand that role to a ServiceAccount.
        Resource = [
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/*-microvm-build",
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/*-microvm-exec",
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${local.cluster_name}-ack-lambdamicrovms-controller",
        ]
      },
      {
        Sid    = "PodIdentityAssociations"
        Effect = "Allow"
        # The lambda-microvm substrate binds three ServiceAccounts (the ACK
        # controller, the bridge, the lifecycle controller) to their AWS role via
        # ACK-managed eks.services.k8s.aws PodIdentityAssociations. The policy
        # previously had NO eks: actions at all, so all three sat at
        # ACK.ResourceSynced=Unknown and never appeared in
        # `aws eks list-pod-identity-associations` — while the Application reported
        # only "waiting for healthy state of ... and 3 more resources".
        Action = [
          "eks:CreatePodIdentityAssociation",
          "eks:DescribePodIdentityAssociation",
          "eks:ListPodIdentityAssociations",
          "eks:UpdatePodIdentityAssociation",
          "eks:DeletePodIdentityAssociation",
          "eks:TagResource", "eks:UntagResource", "eks:ListTagsForResource",
        ]
        # Scoped to THIS cluster and the associations under it, not every cluster.
        Resource = [
          module.eks.cluster_arn,
          "arn:${data.aws_partition.current.partition}:eks:${var.region}:${local.account_id}:podidentityassociation/${local.cluster_name}/*",
        ]
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
    config  = sha256(each.value.config)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      # Passed via env (not interpolated into the command) so JSON quoting cannot
      # be mangled by the shell.
      CAPABILITY_CONFIG = each.value.config
    }
    command = <<-EOT
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

      ARGS=(--cluster-name "$CLUSTER" --region "$REGION" --type "$TYPE"
            --capability-name "$NAME" --role-arn "$ROLE"
            --delete-propagation-policy RETAIN)

      # ARGOCD carries a configuration block (Identity Center + RBAC mappings).
      # Write it to a temp file and pass file:// so no JSON survives the shell.
      if [ -n "$${CAPABILITY_CONFIG:-}" ]; then
        CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT
        printf '%s' "$CAPABILITY_CONFIG" > "$CFG"
        ARGS+=(--configuration "file://$CFG")
      fi

      echo "enabling capability $TYPE (name=$NAME) on $CLUSTER ..."
      # RETAIN is the only supported deletion policy: Kubernetes resources the
      # capability created are kept if the capability is removed.
      #
      # RETRY: the capability role is created moments earlier in this same apply,
      # and IAM is eventually consistent — CreateCapability then rejects it with
      # "The trust policy for the provided role is invalid" even though the trust
      # policy is correct. Retry until IAM has propagated.
      OK=0
      for attempt in $(seq 1 12); do
        if OUT=$(aws eks create-capability "$${ARGS[@]}" 2>&1); then OK=1; break; fi
        echo "$OUT" | sed 's/^/    /'
        if echo "$OUT" | grep -q 'trust policy for the provided role is invalid'; then
          echo "  attempt $attempt: IAM role not propagated yet, retrying in 10s ..."
          sleep 10
          continue
        fi
        # Any other error is not a propagation delay — stop immediately.
        break
      done

      if [ "$OK" -ne 1 ]; then
        echo ""
        echo "ERROR: could not enable the $TYPE capability."
        if echo "$${OUT:-}" | grep -q 'Configuration is required'; then
          echo "  $TYPE needs a configuration block. For ARGOCD that means AWS IAM"
          echo "  Identity Center: set argocd_idc_instance_arn and argocd_admin_identities."
        else
          echo "  It may not be available in $REGION or for this account."
          echo "  Set enable_managed_$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')=false in terraform.tfvars"
          echo "  and install the equivalent via Helm instead."
        fi
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

  depends_on = [module.eks, null_resource.validate_argocd_idc]
}

# ── Kubernetes access for the Managed ArgoCD capability ────────────────────────
#
# WITHOUT THIS, NOTHING SYNCS. Enabling the ARGOCD capability creates an EKS access
# entry for your capability role with exactly two managed policies, and neither one
# grants access to workloads:
#
#   AmazonEKSArgoCDClusterPolicy   namespaces, Argo CRDs, API discovery
#   AmazonEKSArgoCDPolicy          secrets/configmaps/events + Argo CRs, argocd ns
#
# So the AWS-run control plane can create Applications but cannot read or write
# anything they describe. Two failures follow, in order:
#
#  1. ArgoCD's cluster cache lists every type registered in the cluster, and ONE
#     forbidden type aborts the entire sync. Every Application then sits at
#     sync=Unknown with zero managed resources:
#
#       ComparisonError: failed to load initial state of resource
#       Integration.apigateway.services.k8s.aws: ... is forbidden: User
#       ".../<cluster>-ArgoCDCapabilityRole/..." cannot list resource
#       "integrations" ... at the cluster scope
#
#     (Which type appears is arbitrary — it is simply the first one it reaches.
#     Managed ACK registers ~250 CRDs, so this is immediate and unavoidable.)
#
#  2. Even with a healthy cache, syncing an addon needs write access to the kinds
#     its chart contains: Deployments, Services, RBAC, CRDs, webhooks.
#
# WHY cluster-admin, stated plainly: a GitOps engine running with prune + selfHeal
# over platform addons has to create ClusterRoles and CRDs, and anything that can
# write RBAC can escalate itself. An enumerated allow-list would look tighter while
# granting the same effective power, and it would break every time someone adds an
# addon with a new API group. So this grants cluster-admin explicitly rather than
# implying a limit that isn't real.
#
# THE PRACTICAL CONSEQUENCE: write access to the GitOps repo is equivalent to
# cluster-admin on this cluster. Protect the branch ArgoCD tracks accordingly.
#
# The access ENTRY already exists (the capability created it); this only associates
# an additional policy with it.
resource "aws_eks_access_policy_association" "argocd_cluster_admin" {
  count = var.enable_managed_argocd ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.capability["ARGOCD"].arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [null_resource.eks_capability]
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
