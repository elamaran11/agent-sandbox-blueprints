variable "region" {
  description = "AWS region. Pinned to us-west-2 by default because AWS Lambda MicroVM is only available in select regions; the Kata-only path works anywhere nested-virt instances exist."
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Prefix for all resource names (cluster becomes <project_name>-eks)"
  type        = string
  default     = "agent-sandbox"
}

variable "cluster_version" {
  description = "Kubernetes version. 1.36+ is required for Karpenter >= 1.13's EC2NodeClass spec.cpuOptions.nestedVirtualization, which is how the Kata nodes get nested KVM."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API endpoint is publicly reachable. Keep true for a laptop-driven blueprint; set false and use a bastion/VPN for anything real."
  type        = bool
  default     = true
}

variable "system_instance_types" {
  description = "Instance types for the system managed node group (ArgoCD, Karpenter, CoreDNS). Sandboxes never run here."
  type        = list(string)
  default     = ["m5.large"]
}

variable "admin_role_arns" {
  description = "Additional IAM role ARNs granted cluster-admin via EKS access entries (auditable via CloudTrail). The creating identity is always granted admin."
  type        = list(string)
  default     = []
}

# ── GitOps ────────────────────────────────────────────────────────────────────

variable "gitops_repo_url" {
  description = "HTTPS URL of the repo ArgoCD watches for the app-of-apps (this repo, or your fork)"
  type        = string
}

variable "gitops_target_revision" {
  description = "Git branch/tag ArgoCD tracks"
  type        = string
  default     = "main"
}

variable "gitops_platform_path" {
  description = "Path in the repo to the platform Helm chart whose templates are ArgoCD Applications (app-of-apps as a chart, so one values file gates each addon)"
  type        = string
  default     = "infrastructure/gitops/platform"
}

# ── EKS Managed capabilities ───────────────────────────────────────────────────
# See capabilities.tf. Disable any of these if your account/region does not have
# the capability available, and install the equivalent yourself via Helm.

variable "enable_managed_argocd" {
  description = "Enable the EKS Managed ArgoCD capability (AWS runs the ArgoCD control plane). REQUIRES AWS IAM Identity Center — see argocd_idc_* below."
  type        = bool
  default     = true
}

# ── Managed ArgoCD ⇒ AWS IAM Identity Center is REQUIRED ──────────────────────
# The CreateCapability API rejects an ARGOCD capability without a configuration
# block, and that configuration must name an Identity Center instance plus at
# least one identity mapped to the ADMIN role — that is how you log in to the
# AWS-managed ArgoCD (there is no local admin password).
#
# Discover these values with:
#   aws sso-admin list-instances --region <region>
#   aws identitystore list-groups --identity-store-id <IdentityStoreId> --region <region>

variable "argocd_idc_instance_arn" {
  description = "IAM Identity Center instance ARN for Managed ArgoCD SSO (e.g. arn:aws:sso:::instance/ssoins-xxxx). Required when enable_managed_argocd=true."
  type        = string
  default     = ""

  validation {
    condition     = var.argocd_idc_instance_arn == "" || can(regex("^arn:aws[a-z-]*:sso:::instance/", var.argocd_idc_instance_arn))
    error_message = "argocd_idc_instance_arn must be an Identity Center instance ARN (arn:aws:sso:::instance/ssoins-...)."
  }
}

variable "argocd_idc_region" {
  description = "Region the Identity Center instance lives in. Defaults to var.region."
  type        = string
  default     = ""
}

variable "argocd_namespace" {
  description = "Namespace the Managed ArgoCD capability runs its in-cluster components in"
  type        = string
  default     = "argocd"
}

variable "argocd_admin_identities" {
  description = <<-EOT
    Identity Center principals granted the ArgoCD ADMIN role. At least one is
    required when enable_managed_argocd=true — without it nobody can log in.
    Example:
      [{ id = "78b1f3c0-...", type = "SSO_GROUP" }]
  EOT
  type = list(object({
    id   = string
    type = string # SSO_GROUP | SSO_USER
  }))
  default = []

  validation {
    condition     = alltrue([for i in var.argocd_admin_identities : contains(["SSO_GROUP", "SSO_USER"], i.type)])
    error_message = "argocd_admin_identities[].type must be SSO_GROUP or SSO_USER."
  }
}

variable "enable_managed_ack" {
  description = "Enable the EKS Managed ACK capability (AWS-run controllers for GA services: iam, s3, eks, ...). The pre-GA lambdamicrovms controller is NOT covered and is installed self-managed by the lambda-microvm blueprint."
  type        = bool
  default     = true
}

variable "enable_managed_kro" {
  description = "Enable the EKS Managed KRO capability. NOTE: the managed KRO controller only watches the kro.run API group, so any ResourceGraphDefinition must declare schema.group: kro.run."
  type        = bool
  default     = true
}

# ── In-cluster LLM gateway (Kata path) ────────────────────────────────────────
# The Kata agent reaches models through this gateway so calls can be traced
# centrally (Langfuse). The Lambda MicroVM agent bypasses it and calls Bedrock
# directly, because it runs outside the cluster network.

variable "llm_gateway_namespace" {
  description = "Namespace of the in-cluster LLM gateway that gets Bedrock access via Pod Identity"
  type        = string
  default     = "bifrost"
}

variable "llm_gateway_service_account" {
  description = "ServiceAccount of the in-cluster LLM gateway"
  type        = string
  default     = "bifrost"
}

# ── Substrate toggles ─────────────────────────────────────────────────────────

variable "create_coder_ecr_repos" {
  description = "Create ECR repositories for the agent (coder) container images used by the Dark Factory examples"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource"
  type        = map(string)
  default     = {}
}

# ── External Secrets (GitHub PAT distribution) ────────────────────────────────
variable "enable_external_secrets" {
  description = "Create the Secrets Manager container, Pod Identity, and ClusterSecretStore that distribute the GitHub PAT into the cluster. The examples ship ExternalSecret objects, so leaving this off means creating those Secrets by hand."
  type        = bool
  default     = true
}

variable "github_secret_name" {
  description = "Secrets Manager secret id holding the GitHub PAT + webhook HMAC. Must match github.externalSecret.secretsManagerKey in the example values. Terraform creates the container but NEVER the value. Namespaced under the project so it cannot be shared with — or destroyed by — another stack in the same account."
  type        = string
  default     = "agent-sandbox/github"
}

variable "external_secrets_namespace" {
  description = "Namespace the External Secrets controller runs in. Must match externalSecrets.namespace in the platform values."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_service_account" {
  description = "ServiceAccount of the External Secrets controller. Must match externalSecrets.serviceAccount in the platform values — Pod Identity is keyed on (namespace, serviceAccount)."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_store_name" {
  description = "ClusterSecretStore name the ExternalSecrets reference. Must match github.externalSecret.clusterSecretStore in the example values."
  type        = string
  default     = "aws-secrets-manager"
}

variable "create_github_secret" {
  description = "Create the Secrets Manager secret container. Set false to ADOPT an existing secret (read-only) — required when other clusters share the same credential, so `terraform destroy` here cannot delete it."
  type        = bool
  default     = true
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────
variable "enable_aws_lbc" {
  description = "Create the AWS Load Balancer Controller's IAM role, Pod Identity, and ELB subnet tags. Required for the GitHub webhook to have a public address — without it the Dark Factory can only be triggered by submitting a Workflow by hand."
  type        = bool
  default     = true
}

variable "aws_lbc_service_account" {
  description = "ServiceAccount the AWS Load Balancer Controller runs as. Must match the platform chart's awsLbc.serviceAccount — Pod Identity is keyed on (namespace, serviceAccount)."
  type        = string
  default     = "aws-load-balancer-controller"
}
