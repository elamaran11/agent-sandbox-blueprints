# ── ArgoCD root Application (app-of-apps) ─────────────────────────────────────
#
# This is the ONLY thing Terraform creates inside the cluster. Everything else
# in-cluster is owned by ArgoCD, so the seam between the two tools stays clean:
#
#   Terraform  → things that must exist before Kubernetes (VPC, EKS, IAM, ECR,
#                capabilities)
#   ArgoCD     → everything running on Kubernetes
#
# The substrates (kata/, lambda-microvm/) and examples/ are deliberately NOT
# wired in here. They are opt-in: `task kata`, `task lambda`, `task demo-*`
# apply them. A fresh `task up` gives you a working platform and nothing
# expensive or surprising.

locals {
  # Your non-secret overrides, injected INLINE below so they reach the cluster
  # without being committed to git (the file is gitignored). ArgoCD reads the
  # committed defaults from platform/values.yaml and these win over them.
  #
  # This is the piece that resolves the GitOps/values tension: ArgoCD can only
  # read manifests from git, so a gitignored values file is invisible to it —
  # unless something puts the content into the Application itself. That is here.
  #
  # Secrets never travel this path. Manifests reference Secret NAMES; you create
  # the Secrets out-of-band (see each example's secrets.md).
  gitops_values_file = "${path.module}/../gitops/values.yaml"
  gitops_values      = fileexists(local.gitops_values_file) ? file(local.gitops_values_file) : ""

  # Decode YOUR values into a map and merge, rather than concatenating YAML text.
  #
  # WHY: the previous version built this string with a heredoc and nested indent()
  # calls. Terraform's <<- stripping and indent() both operate on the same block, so
  # the result was misaligned — `repo:` at column 0 with its children at 6 — and
  # ArgoCD failed every reconcile with
  #   failed to parse /tmp/...: error converting YAML to JSON: yaml: line 3: did
  #   not find expected key
  # which reads like a chart bug, not a Terraform formatting bug. yamlencode does
  # the layout, so there is no indentation arithmetic left to get wrong.
  #
  # Merge order matters: your file first, then the values Terraform must own. The
  # repo, revision and destination cluster always come from Terraform so a fork
  # works without editing a committed file.
  # A file that is present but all-comments (the common result of copying
  # values.example.yaml and not uncommenting anything) decodes to null, not {} —
  # and merge(null, ...) is an error. Treat missing, empty, comments-only and
  # unparseable alike: fall back to no overrides.
  gitops_values_decoded = local.gitops_values != "" ? try(yamldecode(local.gitops_values), null) : null
  gitops_values_map     = local.gitops_values_decoded == null ? {} : local.gitops_values_decoded

  platform_values = yamlencode(merge(local.gitops_values_map, {
    repo = {
      url      = var.gitops_repo_url
      revision = var.gitops_target_revision
    }
    destinationCluster = module.eks.cluster_name
    # The AWS Load Balancer Controller cannot auto-discover its VPC, and the chart
    # has no default. Passed here so a fork needs no committed edit.
    awsLbc = {
      vpcId  = module.vpc.vpc_id
      region = var.region
    }
  }))
}

# ── Register this cluster with the managed ArgoCD ─────────────────────────────
#
# Managed ArgoCD runs its control plane OUTSIDE the cluster, so it does not have
# an implicit "in-cluster" destination — the in-cluster address is explicitly
# disabled. Applications must target a cluster BY NAME, and a cluster only exists
# once it is registered.
#
# Registration is a Secret in the host cluster's argocd namespace, labelled
# argocd.argoproj.io/secret-type=cluster. Two non-obvious details, both verified
# against a working managed-ArgoCD cluster in this account:
#   * `server` is the EKS cluster **ARN**, not an https:// URL
#   * `name` is what Application.spec.destination.name must match
#
# Without this, every Application sits Unknown/Unknown with
#   InvalidSpecError: there are no clusters with this name: <cluster>
resource "kubernetes_secret" "argocd_cluster" {
  count = var.enable_managed_argocd ? 1 : 0

  metadata {
    name      = module.eks.cluster_name
    namespace = var.argocd_namespace

    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = module.eks.cluster_name
    server = module.eks.cluster_arn
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }

  type = "Opaque"

  depends_on = [null_resource.wait_for_argocd]
}

resource "kubectl_manifest" "platform_root" {
  count = var.enable_managed_argocd ? 1 : 0

  # Built with yamlencode for the same reason as platform_values above: embedding a
  # multi-line YAML string inside a YAML heredoc means indenting it correctly by
  # hand, and getting that wrong fails at reconcile time with a parse error that
  # points at the chart instead of at this file.
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "platform-addons"
      namespace  = var.argocd_namespace
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_target_revision
        path           = var.gitops_platform_path
        helm = {
          releaseName = "platform"
          values      = local.platform_values
        }
      }
      destination = {
        # Managed ArgoCD registers the cluster BY NAME and disables the in-cluster
        # address, so `server: https://kubernetes.default.svc` is rejected with
        # 'cluster ... is disabled'. Target the name instead.
        name      = module.eks.cluster_name
        namespace = var.argocd_namespace
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
        retry = {
          limit   = 5
          backoff = { duration = "15s", factor = 2, maxDuration = "5m" }
        }
      }
    }
  })

  depends_on = [
    null_resource.wait_for_argocd,
    kubernetes_secret.argocd_cluster,
  ]
}
