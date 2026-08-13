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

variable "gitops_addons_path" {
  description = "Path in the repo holding the platform addon Applications"
  type        = string
  default     = "infrastructure/gitops/addons"
}

# ── EKS Managed capabilities ───────────────────────────────────────────────────
# See capabilities.tf. Disable any of these if your account/region does not have
# the capability available, and install the equivalent yourself via Helm.

variable "enable_managed_argocd" {
  description = "Enable the EKS Managed ArgoCD capability (AWS runs the ArgoCD control plane)"
  type        = bool
  default     = true
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
