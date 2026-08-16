# ── GitHub credential: Secrets Manager → cluster, via External Secrets ────────
#
# ANSWERING THE OBVIOUS QUESTION: why isn't the PAT just in values/GitOps?
#
# Because it is a credential. It can never be in git, and a values file is in git.
# What CAN be automated is everything after the credential exists: which namespaces
# it lands in, under which key names, how often it refreshes, and how it is
# recreated when the cluster is rebuilt. That is what this wires up.
#
#   you, ONCE   ──▶ Secrets Manager secret (var.github_secret_name)
#                      │  read via Pod Identity — no static keys anywhere
#                      ▼
#                   ClusterSecretStore ──▶ ExternalSecret ×3 ──▶ k8s Secrets in
#                   argo / argo-events / agent-sandbox-system
#
# So the irreducible manual step is one `aws secretsmanager put-secret-value`.
# Everything downstream is values + GitOps, and git only ever holds the REFERENCE
# (secret id and key names), never the value.
#
# Terraform deliberately does NOT create or hold the secret VALUE: putting it in a
# tfvars file or a resource argument would write the PAT into terraform state in
# plaintext. Terraform creates the empty container and the read permission; you put
# the value in out-of-band (see examples/_shared/SECRETS.md).

resource "aws_secretsmanager_secret" "github" {
  count = var.enable_external_secrets ? 1 : 0

  name        = var.github_secret_name
  description = "GitHub PAT + webhook HMAC for the Dark Factory. Value set out-of-band, never by Terraform."

  # A demo cluster gets torn down repeatedly, and a 7-day deletion window means the
  # name is still reserved on the next `task up` ("already scheduled for deletion").
  recovery_window_in_days = 0

  tags = local.tags
}

# Pod Identity for the External Secrets controller: no IRSA annotation, no static
# keys. Scoped to exactly the one secret it must read.
resource "aws_iam_role" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name = "${local.cluster_name}-external-secrets"

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

resource "aws_iam_role_policy" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name = "read-github-secret"
  role = aws_iam_role.external_secrets[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      # Read-only, and only this secret — not all of Secrets Manager.
      Resource = "${aws_secretsmanager_secret.github[0].arn}*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  cluster_name = module.eks.cluster_name
  # Must match the namespace + serviceAccount the platform chart installs ESO with
  # (externalSecrets.namespace / .serviceAccount). A mismatch shows up as the
  # ClusterSecretStore reporting an auth error, not as a naming problem.
  namespace       = var.external_secrets_namespace
  service_account = var.external_secrets_service_account
  role_arn        = aws_iam_role.external_secrets[0].arn
}

# The ClusterSecretStore is a Kubernetes object, but it is created here rather than
# by ArgoCD for ORDERING: the ExternalSecrets in the examples reference it by name,
# and a store that appears after them leaves each one in SecretSyncedError until the
# next reconcile. Terraform runs before any Application exists.
resource "kubectl_manifest" "aws_secrets_store" {
  count = var.enable_external_secrets ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    # Name must match github.externalSecret.clusterSecretStore in the example values.
    metadata = { name = var.external_secrets_store_name }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth    = {} # empty = use the controller's ambient (Pod Identity) creds
        }
      }
    }
  })

  depends_on = [
    aws_eks_pod_identity_association.external_secrets,
    null_resource.wait_for_argocd,
  ]
}
