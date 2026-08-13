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

  # Always pin the repo/revision to what Terraform was given, so a fork works
  # without editing any committed file.
  platform_values = <<-YAML
    repo:
      url: ${var.gitops_repo_url}
      revision: ${var.gitops_target_revision}
    ${indent(4, local.gitops_values)}
  YAML
}

resource "kubectl_manifest" "platform_root" {
  count = var.enable_managed_argocd ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: platform-addons
      namespace: argocd
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: ${var.gitops_repo_url}
        targetRevision: ${var.gitops_target_revision}
        path: ${var.gitops_platform_path}
        helm:
          releaseName: platform
          values: |
            ${indent(12, local.platform_values)}
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 5
          backoff:
            duration: 15s
            factor: 2
            maxDuration: 5m
  YAML

  depends_on = [null_resource.wait_for_argocd]
}
