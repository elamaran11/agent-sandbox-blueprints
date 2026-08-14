# Copy to terraform.tfvars (gitignored) and edit.
#
#   cp example.tfvars terraform.tfvars
#
# Only gitops_repo_url is required — everything else has a working default.

# ── Required ──────────────────────────────────────────────────────────────────

# The repo ArgoCD watches. Use your fork if you plan to change the manifests,
# otherwise point at the upstream blueprint.
gitops_repo_url = "https://github.com/elamaran11/agent-sandbox-blueprints"

# Managed ArgoCD REQUIRES AWS IAM Identity Center — there is no local admin
# password, SSO is the only way to log in. Discover these with:
#   aws sso-admin list-instances --region us-west-2
#   aws identitystore list-groups --identity-store-id <IdentityStoreId> --region us-west-2
# (Or set enable_managed_argocd = false and install ArgoCD via Helm.)
argocd_idc_instance_arn = "arn:aws:sso:::instance/ssoins-REPLACE_ME"
argocd_admin_identities = [
  { id = "REPLACE_ME-group-or-user-id", type = "SSO_GROUP" },
]

# ── Common overrides ──────────────────────────────────────────────────────────

# Pinned to us-west-2 because AWS Lambda MicroVM is only available in select
# regions. The Kata-only path works in any region with nested-virt instances.
region = "us-west-2"

# Prefix for every resource; the cluster becomes "<project_name>-eks".
project_name = "agent-sandbox"

# 1.36+ is required for Karpenter >= 1.13's EC2NodeClass cpuOptions
# .nestedVirtualization, which is how the Kata nodes get nested KVM.
cluster_version = "1.36"

gitops_target_revision = "main"

# ── Optional ──────────────────────────────────────────────────────────────────

# vpc_cidr = "10.0.0.0/16"

# Platform components only (ArgoCD, Karpenter, CoreDNS). Sandboxes never run here.
# system_instance_types = ["m5.large"]

# Extra IAM roles granted cluster-admin (the identity running terraform always is).
# admin_role_arns = ["arn:aws:iam::111122223333:role/YourAdminRole"]

# Set any of these false if the capability is unavailable in your account/region;
# install the equivalent via Helm instead. See capabilities.tf.
# enable_managed_argocd = true
# enable_managed_ack    = true
# enable_managed_kro    = true

# tags = { Owner = "you@example.com", Environment = "demo" }
