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
