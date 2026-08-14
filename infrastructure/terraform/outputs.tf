output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = module.eks.cluster_version
}

output "region" {
  description = "AWS region the cluster runs in"
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (for IRSA roles added by the substrate blueprints)"
  value       = module.eks.oidc_provider_arn
}

# The substrate blueprints (kata/, lambda-microvm/) are applied by `task kata` and
# `task lambda`, not by Terraform. Their Applications need these three values, and
# hardcoding them in a committed manifest breaks as soon as someone forks the repo
# or changes project_name — so the Taskfile reads them from here and substitutes.
output "karpenter_node_role" {
  description = "IAM role name Karpenter attaches to nodes (kata/ nodepools need this)"
  value       = aws_iam_role.karpenter_node.name
}

output "gitops_repo_url" {
  description = "Git repo ArgoCD reads manifests from"
  value       = var.gitops_repo_url
}

output "gitops_target_revision" {
  description = "Git revision ArgoCD tracks"
  value       = var.gitops_target_revision
}

output "kubeconfig_cmd" {
  description = "Command to point kubectl at this cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "enabled_capabilities" {
  description = "EKS Managed capabilities this blueprint enabled"
  value       = local.enabled_capabilities
}

output "coder_ecr_urls" {
  description = "ECR repository URLs for the agent images (empty if create_coder_ecr_repos=false)"
  value       = { for k, r in aws_ecr_repository.coder : k => r.repository_url }
}

output "argocd_ui_cmd" {
  description = "Port-forward to reach the ArgoCD UI"
  value       = "kubectl port-forward -n argocd svc/argocd-server 8080:443"
}

output "next_steps" {
  description = "What to run after the platform is up"
  value       = <<-EOT
    Platform is ready. Next:
      task kata          # add the Kata micro-VM substrate (clh + qemu + fc)
      task lambda        # add the AWS Lambda MicroVM substrate
      task status        # watch ArgoCD applications reconcile
  EOT
}
