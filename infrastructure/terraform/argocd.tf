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
        path: ${var.gitops_addons_path}
        directory:
          recurse: true
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
